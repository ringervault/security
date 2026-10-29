/// Host handling for autofill matching.
///
/// Matching a saved credential to a website is a security decision, not a
/// string convenience, so everything here is deliberately strict and refuses
/// rather than guesses. There is no "contains", no prefix test, and no
/// similarity score anywhere in it: "amaz0n.com" and "amazon.xyz" are simply
/// different sites from "amazon.com".
///
/// extension/src/vault/host.js is the same logic for the browser extension,
/// and test/fixtures/autofill_cases.json holds cases both must agree on.
library;

import 'package:ringer_vault/autofill/public_suffix_data.g.dart';

/// Why a host could not be used for matching.
enum HostRejection {
  /// Empty, or not shaped like a host at all.
  malformed,

  /// Contains characters outside a-z, 0-9 and hyphen.
  ///
  /// Browsers report internationalised hosts in their ASCII (xn--) form, so
  /// in practice a host with Cyrillic or Greek letters in it is an attempt to
  /// look like a different name. Refusing is both simpler and safer than
  /// trying to normalise it.
  nonAscii,

  /// An IP address. Nothing is ever saved against one.
  ipAddress,

  /// A bare public suffix such as "co.uk", which belongs to no one.
  publicSuffixOnly,
}

class HostResult {
  /// The registrable domain, e.g. "chase.com" for "secure.chase.com".
  final String? registrable;

  /// The host itself, normalised: lower case, no trailing dot, and no
  /// leading "www.", which is the same front door as the bare domain.
  final String? host;

  final HostRejection? rejection;

  const HostResult.ok({required String this.registrable, required String this.host})
      : rejection = null;
  const HostResult.rejected(HostRejection this.rejection)
      : registrable = null,
        host = null;

  bool get isUsable => registrable != null;
}

/// Reduces a host to the domain a credential can belong to.
///
/// "secure.chase.com" and "www.chase.com" both reduce to "chase.com". The
/// boundary comes from the Public Suffix List, not from counting dots, which
/// is what makes "bbc.co.uk", "srmist.edu.in" and "alice.github.io" each
/// their own site, rather than every ".edu.in" university or every GitHub
/// Pages user being lumped into one.
HostResult registrableDomain(String rawHost) {
  var host = rawHost.trim().toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);

  if (host.isEmpty || host.contains('/') || host.contains(' ')) {
    return const HostResult.rejected(HostRejection.malformed);
  }
  if (!_asciiHost.hasMatch(host)) {
    return const HostResult.rejected(HostRejection.nonAscii);
  }
  if (_looksLikeIp.hasMatch(host) || host.contains(':')) {
    return const HostResult.rejected(HostRejection.ipAddress);
  }
  // This computer itself: a site of its own, for logins to things being
  // built or run here. Nothing on the network can answer for it.
  if (host == 'localhost') {
    return const HostResult.ok(registrable: 'localhost', host: 'localhost');
  }

  final labels = host.split('.');
  if (labels.length < 2 || labels.any((l) => l.isEmpty)) {
    return const HostResult.rejected(HostRejection.malformed);
  }

  final suffixLength = _PublicSuffixes.suffixLength(labels);
  if (labels.length <= suffixLength) {
    return const HostResult.rejected(HostRejection.publicSuffixOnly);
  }

  final registrable =
      labels.sublist(labels.length - suffixLength - 1).join('.');
  // "www." is dropped only when it is a subdomain in front of the site's
  // name. In "www.ck" it is the name itself, and must stay.
  final isWwwSubdomain =
      labels.first == 'www' && labels.length > suffixLength + 1;
  return HostResult.ok(
    registrable: registrable,
    host: isWwwSubdomain ? labels.sublist(1).join('.') : host,
  );
}

/// Pulls the host out of a URL or a bare host string.
HostResult hostOf(String urlOrHost) {
  final value = urlOrHost.trim();
  if (value.isEmpty) {
    return const HostResult.rejected(HostRejection.malformed);
  }

  if (value.contains('://')) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      return const HostResult.rejected(HostRejection.malformed);
    }
    return registrableDomain(uri.host);
  }

  // A bare "chase.com/login" still has a path to strip.
  final slash = value.indexOf('/');
  return registrableDomain(slash == -1 ? value : value.substring(0, slash));
}

/// How a page relates to the websites an entry was saved for.
enum SiteTier {
  /// Saved for exactly this address. Fills on a tap.
  exact,

  /// Saved for another address on the same site, such as accounts.google.com
  /// when this is docs.google.com. Some sites let anyone publish pages on a
  /// subdomain, so this asks once before it is trusted.
  sameSite,

  /// The site matches, but the page came over plain http, where anyone on
  /// the network can change it. Always asks, and never remembers.
  insecure,

  /// Not saved for this site at all.
  none,
}

/// Compares a page against an entry's saved websites.
///
/// [scheme] is "https", "http", or null when the browser did not say; null is
/// treated as secure, because older Android versions never report it.
SiteTier siteTier({
  required Iterable<String> savedHosts,
  required String pageHost,
  String? scheme,
}) {
  final page = registrableDomain(pageHost);
  if (!page.isUsable) return SiteTier.none;

  var sameSite = false;
  var exact = false;
  for (final saved in savedHosts) {
    final target = registrableDomain(saved);
    if (!target.isUsable || target.registrable != page.registrable) continue;
    sameSite = true;
    if (target.host == page.host) exact = true;
  }

  if (!sameSite) return SiteTier.none;
  if (scheme != null && scheme.toLowerCase() == 'http' && !isLoopback(page.host!)) {
    return SiteTier.insecure;
  }
  return exact ? SiteTier.exact : SiteTier.sameSite;
}

/// "localhost" and names under it ("app.localhost"): this device itself.
/// Browsers never send them to the network, so plain http there cannot be
/// changed on the way.
bool isLoopback(String host) {
  var name = host.toLowerCase();
  if (name.endsWith('.')) name = name.substring(0, name.length - 1);
  return name == 'localhost' || name.endsWith('.localhost');
}

final RegExp _asciiHost = RegExp(r'^[a-z0-9.-]+$');
final RegExp _looksLikeIp = RegExp(r'^[0-9.]+$');

/// The Public Suffix List, loaded on first use.
///
/// Bundled rather than fetched, because a security decision should not
/// depend on a download or on whoever serves it. It is refreshed by running
/// tool/psl/generate.py before a release.
class _PublicSuffixes {
  static final Set<String> _rules = pslRules.split('\n').toSet();
  static final Set<String> _wildcards = pslWildcards.split('\n').toSet();
  static final Set<String> _exceptions = pslExceptions.split('\n').toSet();

  /// How many labels at the end of [labels] form its public suffix, by the
  /// list's own algorithm: an exception rule wins outright and gives up its
  /// leftmost label; otherwise the longest matching rule wins; otherwise the
  /// last label alone.
  static int suffixLength(List<String> labels) {
    for (var i = 0; i < labels.length; i++) {
      if (_exceptions.contains(labels.sublist(i).join('.'))) {
        return labels.length - i - 1;
      }
    }
    for (var i = 0; i < labels.length; i++) {
      if (_rules.contains(labels.sublist(i).join('.'))) {
        return labels.length - i;
      }
      if (i + 1 < labels.length &&
          _wildcards.contains(labels.sublist(i + 1).join('.'))) {
        return labels.length - i;
      }
    }
    return 1;
  }
}
