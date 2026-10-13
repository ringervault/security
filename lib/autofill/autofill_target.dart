import 'package:ringer_vault/autofill/registrable_domain.dart';

/// What an entry is allowed to fill into.
///
/// Autofill never matches on an entry's title. The title is a label the user
/// typed and the requesting app controls what it calls itself, so comparing
/// the two compares one attacker-controlled string against another. A target
/// is the only thing a fill is allowed to be decided by.
enum TargetKind {
  /// An installed app, identified by its package and the certificate it was
  /// signed with. The package alone is a claim; the signature is proof.
  app,

  /// A website, stored as the exact address it was saved on, normalised
  /// (lower case, no "www."). Targets saved before exact addresses were kept
  /// hold the bare domain, which still matches its whole site but asks once
  /// for any other address on it.
  site,
}

class AutofillTarget {
  final TargetKind kind;

  /// Package name for [TargetKind.app], normalised host for
  /// [TargetKind.site].
  final String value;

  /// Lowercase hex SHA-256 of the signing certificate, for app targets that
  /// have been pinned. Null means the app has been named but not yet seen,
  /// so the next fill has to be confirmed.
  final String? certificateSha256;

  /// For a pinned app: whether its site listed it, signed with this key,
  /// when it was pinned (Digital Asset Links). An app pinned while that
  /// could not be checked (offline, Strict Offline Mode, a site with no
  /// list) is not, and is asked about again on later fills until it is
  /// confirmed or found unlisted. Pins from before this was recorded count
  /// as not verified.
  final bool verified;

  const AutofillTarget({
    required this.kind,
    required this.value,
    this.certificateSha256,
    this.verified = false,
  });

  /// The same pin, with [verified] as given.
  AutofillTarget withVerified(bool value) => AutofillTarget(
        kind: kind,
        value: this.value,
        certificateSha256: certificateSha256,
        verified: value,
      );

  bool get isPinned => kind == TargetKind.site || certificateSha256 != null;

  /// Stored as one line per target inside the encrypted vault, so no new Hive
  /// type is needed and an older build simply ignores the field.
  String encode() => switch (kind) {
        // The marker comes last: an older build reads the first three
        // parts and ignores it.
        TargetKind.app =>
          'app:$value:${certificateSha256 ?? ''}${verified ? ':verified' : ''}',
        TargetKind.site => 'site:$value',
      };

  /// Returns null for anything malformed. A target that cannot be parsed is
  /// dropped rather than guessed at.
  static AutofillTarget? decode(String raw) {
    final parts = raw.split(':');
    if (parts.length < 2) return null;

    switch (parts.first) {
      case 'app':
        if (parts.length < 2 || parts[1].isEmpty) return null;
        final cert = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null;
        if (cert != null && !_isSha256Hex(cert)) return null;
        return AutofillTarget(
          kind: TargetKind.app,
          value: parts[1],
          certificateSha256: cert?.toLowerCase(),
          verified: cert != null && parts.length > 3 && parts[3] == 'verified',
        );
      case 'site':
        final host = registrableDomain(parts[1]);
        if (!host.isUsable) return null;
        return AutofillTarget(kind: TargetKind.site, value: host.host!);
      default:
        return null;
    }
  }

  @override
  String toString() => encode();

  @override
  bool operator ==(Object other) =>
      other is AutofillTarget &&
      other.kind == kind &&
      other.value == value &&
      other.certificateSha256 == certificateSha256 &&
      other.verified == verified;

  @override
  int get hashCode => Object.hash(kind, value, certificateSha256, verified);
}

bool _isSha256Hex(String value) =>
    RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

/// What the operating system is asking for.
class AutofillRequest {
  /// Package of the app that drew the screen.
  final String packageName;

  /// SHA-256 of that app's signing certificate, read locally.
  final String certificateSha256;

  /// Domain the app claims to be showing, if any.
  final String? claimedWebDomain;

  /// Whether the requesting package is a browser we recognise by signature.
  ///
  /// On Android the web domain is a string set by the app that drew the
  /// screen, so an app with no browser in it can claim to be a bank. It is
  /// only worth believing from a binary that has been verified to be a
  /// browser.
  final bool fromVerifiedBrowser;

  /// Whether the app was installed by the Play Store rather than sideloaded.
  final bool installedFromStore;

  /// Compatibility mode requests carry less trustworthy structure, so a
  /// password is never filled into one without an explicit confirmation.
  final bool compatibilityMode;

  /// "https" or "http" for a web page, or null when the browser did not say
  /// (Android before 9 never does).
  final String? webScheme;

  /// Whether the requesting package is a browser at all, verified or not. A
  /// browser asking without a web domain is showing its own screens, such as
  /// its address bar, and nothing should be remembered against it as an app.
  final bool knownBrowser;

  const AutofillRequest({
    required this.packageName,
    required this.certificateSha256,
    this.claimedWebDomain,
    this.fromVerifiedBrowser = false,
    this.installedFromStore = true,
    this.compatibilityMode = false,
    this.webScheme,
    this.knownBrowser = false,
  });

  /// A request as the platform reported it, with one correction: an app
  /// that is not a browser at all does not get a web address.
  ///
  /// Apps such as Amazon's show their sign-in as a web page inside the app,
  /// and Android passes on the address that page reports. Coming from an
  /// app, that address is only the app's word, so it was refused, and the
  /// refusal left nothing to fill. The app itself is still known for certain
  /// (its package and signing certificate), so the request is treated as
  /// that app's, exactly as for a sign-in screen it draws itself: a first
  /// fill is confirmed and remembers the app, and the website's own list of
  /// apps is asked as for any app. Nothing is ever matched by the address
  /// the app reported.
  ///
  /// A browser keeps its address either way: one not verified is refused
  /// rather than treated as an app, since it shows every website there is.
  factory AutofillRequest.fromPlatform({
    required String packageName,
    required String certificateSha256,
    String? claimedWebDomain,
    bool fromVerifiedBrowser = false,
    bool installedFromStore = true,
    bool compatibilityMode = false,
    String? webScheme,
    bool knownBrowser = false,
  }) {
    final appWithPage = !knownBrowser && !fromVerifiedBrowser;
    return AutofillRequest(
      packageName: packageName,
      certificateSha256: certificateSha256,
      claimedWebDomain: appWithPage ? null : claimedWebDomain,
      fromVerifiedBrowser: fromVerifiedBrowser,
      installedFromStore: installedFromStore,
      compatibilityMode: compatibilityMode,
      webScheme: appWithPage ? null : webScheme,
      knownBrowser: knownBrowser,
    );
  }
}

enum MatchOutcome {
  /// Target is pinned and everything agrees. Fill on a tap, no extra prompt.
  trusted,

  /// Plausible, but something has to be confirmed before it is remembered:
  /// a first fill into this app, or a signature that has changed.
  needsConfirmation,

  /// Nothing about this request matches this entry.
  noMatch,
}

/// Why a match came out the way it did, for the text shown to the user and
/// for the line written to the activity log.
enum MatchReason {
  pinnedApp,
  pinnedSite,

  /// Saved for another address on the same site.
  otherPartOfSite,

  /// The site matches but the page came over plain http.
  insecurePage,

  /// Not yet linked to this site; offered under "Other entries".
  firstUseOfSite,

  /// Not yet linked to this app; offered under "Other entries".
  firstUseOfAppUnlinked,

  firstUseOfApp,
  signatureChanged,
  domainNotTrustedSource,
  hostUnusable,
  sideloaded,
  compatibilityMode,
  noTarget,
}

class MatchResult {
  final MatchOutcome outcome;
  final MatchReason reason;

  /// Set when a confirmation should pin something new.
  final AutofillTarget? pendingTarget;

  /// A trusted app pin that its site has never confirmed: worth asking the
  /// site again before filling (see AutofillTarget.verified).
  final bool unverifiedPin;

  const MatchResult(this.outcome, this.reason, {this.pendingTarget, this.unverifiedPin = false});

  bool get canFill => outcome != MatchOutcome.noMatch;
}

/// Decides whether an entry may fill into a request.
///
/// Deliberately boring: exact comparisons, no heuristics, no similarity
/// scoring. Every path returns a reason, so the decision can be explained to
/// the user and asserted in a test.
MatchResult matchEntry({
  required List<AutofillTarget> targets,
  required AutofillRequest request,
}) {
  final appTargets = targets.where((t) => t.kind == TargetKind.app);
  final siteTargets = targets.where((t) => t.kind == TargetKind.site);

  // The website route, which only exists when a verified browser is asking.
  final claimed = request.claimedWebDomain;
  if (claimed != null && claimed.isNotEmpty) {
    if (!request.fromVerifiedBrowser) {
      return const MatchResult(
        MatchOutcome.noMatch,
        MatchReason.domainNotTrustedSource,
      );
    }

    final host = hostOf(claimed);
    if (!host.isUsable) {
      return const MatchResult(MatchOutcome.noMatch, MatchReason.hostUnusable);
    }

    final tier = siteTier(
      savedHosts: siteTargets.map((t) => t.value),
      pageHost: host.host!,
      scheme: request.webScheme,
    );
    switch (tier) {
      case SiteTier.none:
        return const MatchResult(MatchOutcome.noMatch, MatchReason.noTarget);
      case SiteTier.insecure:
        // Never remembered: pinning a site from a page anyone could have
        // altered would let that alteration vouch for itself next time.
        return const MatchResult(
          MatchOutcome.needsConfirmation,
          MatchReason.insecurePage,
        );
      case SiteTier.sameSite:
        return MatchResult(
          MatchOutcome.needsConfirmation,
          MatchReason.otherPartOfSite,
          pendingTarget: AutofillTarget(
            kind: TargetKind.site,
            value: host.host!,
          ),
        );
      case SiteTier.exact:
        if (request.compatibilityMode) {
          return const MatchResult(
            MatchOutcome.needsConfirmation,
            MatchReason.compatibilityMode,
          );
        }
        return const MatchResult(MatchOutcome.trusted, MatchReason.pinnedSite);
    }
  }

  // The app route.
  final named =
      appTargets.where((t) => t.value == request.packageName).toList();
  if (named.isEmpty) {
    return const MatchResult(MatchOutcome.noMatch, MatchReason.noTarget);
  }

  final pinned = named.where((t) => t.certificateSha256 != null);
  if (pinned.isEmpty) {
    return MatchResult(
      MatchOutcome.needsConfirmation,
      MatchReason.firstUseOfApp,
      pendingTarget: AutofillTarget(
        kind: TargetKind.app,
        value: request.packageName,
        certificateSha256: request.certificateSha256.toLowerCase(),
      ),
    );
  }

  final fingerprint = request.certificateSha256.toLowerCase();
  final same = pinned.where((t) => t.certificateSha256 == fingerprint);
  if (same.isNotEmpty) {
    // A sideloaded app that matches its pinned signature is still the same
    // binary the user trusted, so this is a note rather than a refusal.
    if (request.compatibilityMode) {
      return const MatchResult(
        MatchOutcome.needsConfirmation,
        MatchReason.compatibilityMode,
      );
    }
    return MatchResult(
      MatchOutcome.trusted,
      MatchReason.pinnedApp,
      unverifiedPin: !same.any((t) => t.verified),
    );
  }

  // Same package name, different signer. Either the app was re-signed or
  // this is not the app the user pinned.
  return MatchResult(
    MatchOutcome.needsConfirmation,
    request.installedFromStore
        ? MatchReason.signatureChanged
        : MatchReason.sideloaded,
    pendingTarget: AutofillTarget(
      kind: TargetKind.app,
      value: request.packageName,
      certificateSha256: fingerprint,
    ),
  );
}


/// For an entry with no link to this destination: whether it may be offered
/// under "Other entries", and what confirming it would remember.
///
/// This is what spares the user from typing a website or picking an app by
/// hand. The first fill anywhere is an explicit choice from the whole vault,
/// behind a confirmation that names the exact destination; after that the
/// destination is remembered and the fill is a single tap.
///
/// Returns null where nothing trustworthy could be remembered, in which case
/// nothing is offered at all:
///
///  * a web address claimed by something not verified to be a browser;
///  * a page over plain http;
///  * a compatibility mode request, whose structure is reconstructed and
///    easier to spoof;
///  * a browser asking without a web page, which is its own screens.
MatchResult? offerUnlinked(AutofillRequest request) {
  final claimed = request.claimedWebDomain;
  if (claimed != null && claimed.isNotEmpty) {
    if (!request.fromVerifiedBrowser || request.compatibilityMode) return null;
    if (request.webScheme?.toLowerCase() == 'http') return null;
    final host = hostOf(claimed);
    if (!host.isUsable) return null;
    return MatchResult(
      MatchOutcome.needsConfirmation,
      MatchReason.firstUseOfSite,
      pendingTarget: AutofillTarget(kind: TargetKind.site, value: host.host!),
    );
  }

  if (request.knownBrowser || request.compatibilityMode) return null;
  return MatchResult(
    MatchOutcome.needsConfirmation,
    MatchReason.firstUseOfAppUnlinked,
    pendingTarget: AutofillTarget(
      kind: TargetKind.app,
      value: request.packageName,
      certificateSha256: request.certificateSha256.toLowerCase(),
    ),
  );
}
