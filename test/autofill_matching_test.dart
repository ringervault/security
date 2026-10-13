import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/autofill/autofill_target.dart';
import 'package:ringer_vault/autofill/brand_map.dart';
import 'package:ringer_vault/autofill/registrable_domain.dart';

/// These are the rules that decide where a stored password is allowed to go.
/// Every case here is an attack that has worked against real password
/// managers, so each one gets a test rather than a comment.
void main() {
  const realCert =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const otherCert =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  group('registrable domain', () {
    test('reduces subdomains to the site', () {
      for (final host in ['chase.com', 'www.chase.com', 'secure.chase.com']) {
        expect(registrableDomain(host).registrable, 'chase.com');
      }
    });

    test('a suffix of the real name is not the real name', () {
      // The classic phishing shape.
      expect(registrableDomain('chase.com.evil.io').registrable, 'evil.io');
      expect(
        registrableDomain('evil-chase.com').registrable,
        'evil-chase.com',
      );
      expect(registrableDomain('chasebank.com').registrable, 'chasebank.com');
    });

    test('refuses a host with lookalike characters', () {
      // The "a" here is Cyrillic. It renders identically and is a different
      // character, so it can never be allowed to compare equal.
      final result = registrableDomain('ch\u0430se.com');
      expect(result.isUsable, isFalse);
      expect(result.rejection, HostRejection.nonAscii);
    });

    test('knows that hosting subdomains are separate sites', () {
      // Without this, a credential saved for one github.io page would be
      // offered to every other page on github.io.
      expect(
        registrableDomain('alice.github.io').registrable,
        'alice.github.io',
      );
      expect(registrableDomain('evil.github.io').registrable,
          isNot('alice.github.io'));
    });

    test('handles two-part country suffixes', () {
      expect(registrableDomain('www.hsbc.co.uk').registrable, 'hsbc.co.uk');
      expect(registrableDomain('secure.icicibank.co.in').registrable,
          'icicibank.co.in');
    });

    test('refuses a bare public suffix, an IP and rubbish', () {
      expect(registrableDomain('co.uk').rejection,
          HostRejection.publicSuffixOnly);
      expect(registrableDomain('192.168.1.1').rejection,
          HostRejection.ipAddress);
      expect(registrableDomain('').rejection, HostRejection.malformed);
    });

    test('pulls the host out of a full URL', () {
      expect(hostOf('https://secure.chase.com/login?a=1').registrable,
          'chase.com');
      expect(hostOf('chase.com/login').registrable, 'chase.com');
    });
  });

  group('target encoding', () {
    test('round-trips an app target with its signature', () {
      const target = AutofillTarget(
        kind: TargetKind.app,
        value: 'com.chase.mobile',
        certificateSha256: realCert,
      );
      expect(AutofillTarget.decode(target.encode()), target);
    });

    test('round-trips a site target', () {
      const target =
          AutofillTarget(kind: TargetKind.site, value: 'chase.com');
      expect(AutofillTarget.decode(target.encode()), target);
    });

    test('drops anything malformed rather than guessing', () {
      for (final raw in [
        '',
        'nonsense',
        'app:',
        'app:com.chase.mobile:not-a-hash',
        'site:co.uk',
        'site:ch\u0430se.com',
      ]) {
        expect(AutofillTarget.decode(raw), isNull, reason: raw);
      }
    });
  });

  group('matching an app', () {
    const pinned = [
      AutofillTarget(
        kind: TargetKind.app,
        value: 'com.chase.mobile',
        certificateSha256: realCert,
      ),
    ];

    AutofillRequest request({
      String package = 'com.chase.mobile',
      String cert = realCert,
      bool fromStore = true,
      bool compat = false,
    }) =>
        AutofillRequest(
          packageName: package,
          certificateSha256: cert,
          installedFromStore: fromStore,
          compatibilityMode: compat,
        );

    test('fills into the app it was pinned to', () {
      final result = matchEntry(targets: pinned, request: request());
      expect(result.outcome, MatchOutcome.trusted);
      expect(result.reason, MatchReason.pinnedApp);
    });

    test('refuses an app the entry was never saved for', () {
      final result = matchEntry(
        targets: pinned,
        request: request(package: 'com.evil.fakebank'),
      );
      expect(result.outcome, MatchOutcome.noMatch);
    });

    test('stops when the same package arrives with a different signature', () {
      // The impersonation case: anyone can call themselves
      // com.chase.mobile, nobody else can sign like Chase.
      final result =
          matchEntry(targets: pinned, request: request(cert: otherCert));
      expect(result.outcome, MatchOutcome.needsConfirmation);
      expect(result.reason, MatchReason.signatureChanged);
    });

    test('says so when the impostor was sideloaded', () {
      final result = matchEntry(
        targets: pinned,
        request: request(cert: otherCert, fromStore: false),
      );
      expect(result.reason, MatchReason.sideloaded);
    });

    test('asks on the first fill and offers the signature to pin', () {
      const unpinned = [
        AutofillTarget(kind: TargetKind.app, value: 'com.chase.mobile'),
      ];
      final result = matchEntry(targets: unpinned, request: request());

      expect(result.outcome, MatchOutcome.needsConfirmation);
      expect(result.reason, MatchReason.firstUseOfApp);
      expect(result.pendingTarget?.certificateSha256, realCert);
    });

    test('never fills silently in compatibility mode', () {
      final result =
          matchEntry(targets: pinned, request: request(compat: true));
      expect(result.outcome, MatchOutcome.needsConfirmation);
      expect(result.reason, MatchReason.compatibilityMode);
    });
  });

  group('matching a website', () {
    const targets = [
      AutofillTarget(kind: TargetKind.site, value: 'chase.com'),
    ];

    AutofillRequest browser(
      String domain, {
      bool verified = true,
      String? scheme,
    }) =>
        AutofillRequest(
          packageName: 'com.android.chrome',
          certificateSha256: realCert,
          claimedWebDomain: domain,
          fromVerifiedBrowser: verified,
          webScheme: scheme,
          knownBrowser: true,
        );

    test('fills into the site it was saved for', () {
      final result =
          matchEntry(targets: targets, request: browser('https://chase.com/'));
      expect(result.outcome, MatchOutcome.trusted);
    });

    test('ignores a domain claimed by something that is not a browser', () {
      // An app with no browser in it can put any string in that field.
      final result = matchEntry(
        targets: targets,
        request: browser('https://chase.com/', verified: false),
      );
      expect(result.outcome, MatchOutcome.noMatch);
      expect(result.reason, MatchReason.domainNotTrustedSource);
    });

    test('refuses lookalike and suffix domains', () {
      for (final domain in [
        'https://chase.com.evil.io/',
        'https://evil-chase.com/',
        'https://ch\u0430se.com/',
      ]) {
        expect(
          matchEntry(targets: targets, request: browser(domain)).outcome,
          MatchOutcome.noMatch,
          reason: domain,
        );
      }
    });

    test('another part of the same site asks once, then remembers it', () {
      // Some sites let anyone publish on a subdomain (Google Forms lives on
      // docs.google.com), so a login saved elsewhere on the site is offered
      // but not trusted until the user says so.
      final result = matchEntry(
        targets: targets,
        request: browser('https://secure.chase.com/login'),
      );
      expect(result.outcome, MatchOutcome.needsConfirmation);
      expect(result.reason, MatchReason.otherPartOfSite);
      expect(result.pendingTarget?.encode(), 'site:secure.chase.com');

      final afterConfirming = matchEntry(
        targets: [...targets, result.pendingTarget!],
        request: browser('https://secure.chase.com/login'),
      );
      expect(afterConfirming.outcome, MatchOutcome.trusted);
    });

    test('www. is the same address as the bare domain', () {
      final result = matchEntry(
        targets: targets,
        request: browser('https://www.chase.com/'),
      );
      expect(result.outcome, MatchOutcome.trusted);
    });

    test('a plain http page always asks and is never remembered', () {
      final result = matchEntry(
        targets: targets,
        request: browser('chase.com', scheme: 'http'),
      );
      expect(result.outcome, MatchOutcome.needsConfirmation);
      expect(result.reason, MatchReason.insecurePage);
      expect(result.pendingTarget, isNull);
    });

    test('a different university on edu.in is a different site', () {
      final result = matchEntry(
        targets: const [
          AutofillTarget(kind: TargetKind.site, value: 'srmist.edu.in'),
        ],
        request: browser('https://annauniv.edu.in/'),
      );
      expect(result.outcome, MatchOutcome.noMatch);
    });

    test('a saved site keeps its exact address', () {
      expect(
        AutofillTarget.decode('site:WWW.Accounts.Google.com')!.value,
        'accounts.google.com',
      );
    });
  });

  group('offering an entry not linked yet', () {
    test('a verified browser on a secure page offers to remember the address',
        () {
      final offer = offerUnlinked(const AutofillRequest(
        packageName: 'com.android.chrome',
        certificateSha256: realCert,
        claimedWebDomain: 'accounts.google.com',
        fromVerifiedBrowser: true,
        webScheme: 'https',
        knownBrowser: true,
      ));
      expect(offer?.reason, MatchReason.firstUseOfSite);
      expect(offer?.pendingTarget?.encode(), 'site:accounts.google.com');
    });

    test('an app offers to remember itself and its signature', () {
      final offer = offerUnlinked(const AutofillRequest(
        packageName: 'com.example.bank',
        certificateSha256: realCert,
      ));
      expect(offer?.reason, MatchReason.firstUseOfAppUnlinked);
      expect(offer?.pendingTarget?.encode(),
          'app:com.example.bank:${realCert.toLowerCase()}');
    });

    test('nothing is offered where nothing trustworthy could be remembered',
        () {
      final cases = {
        'an unverified app claiming a web address': const AutofillRequest(
          packageName: 'com.evil.app',
          certificateSha256: realCert,
          claimedWebDomain: 'chase.com',
        ),
        'a plain http page': const AutofillRequest(
          packageName: 'com.android.chrome',
          certificateSha256: realCert,
          claimedWebDomain: 'chase.com',
          fromVerifiedBrowser: true,
          webScheme: 'http',
        ),
        'a compatibility mode request': const AutofillRequest(
          packageName: 'com.example.bank',
          certificateSha256: realCert,
          compatibilityMode: true,
        ),
        "a browser's own screens": const AutofillRequest(
          packageName: 'com.android.chrome',
          certificateSha256: realCert,
          knownBrowser: true,
        ),
      };
      cases.forEach((what, request) {
        expect(offerUnlinked(request), isNull, reason: what);
      });
    });
  });

  group('an app showing its sign-in as a web page', () {
    // Amazon's app reports amazon.in for its sign-in page, a web page inside
    // the app. It is the app's word, so the request is the app's.
    AutofillRequest amazon({String domain = 'amazon.in'}) => AutofillRequest.fromPlatform(
          packageName: 'in.amazon.mShop.android.shopping',
          certificateSha256: realCert,
          claimedWebDomain: domain,
          webScheme: 'https',
        );

    test('is treated as the app, not the address it reports', () {
      final request = amazon();
      expect(request.claimedWebDomain, isNull);
      expect(request.webScheme, isNull);

      final offer = offerUnlinked(request);
      expect(offer?.reason, MatchReason.firstUseOfAppUnlinked);
      expect(offer?.pendingTarget?.kind, TargetKind.app);
      expect(offer?.pendingTarget?.value, 'in.amazon.mShop.android.shopping');
    });

    test('an entry pinned to the app fills; one linked to the site asks first', () {
      final pinned = matchEntry(
        targets: [
          AutofillTarget(
            kind: TargetKind.app,
            value: 'in.amazon.mShop.android.shopping',
            certificateSha256: realCert,
          ),
        ],
        request: amazon(),
      );
      expect(pinned.outcome, MatchOutcome.trusted);

      final siteOnly = matchEntry(
        targets: const [AutofillTarget(kind: TargetKind.site, value: 'amazon.in')],
        request: amazon(),
      );
      expect(siteOnly.canFill, isFalse, reason: 'offered under Other entries, confirmed first');
    });

    test('the address it reports never matches anything', () {
      // An app claiming to show a bank gets nothing linked to the bank.
      final result = matchEntry(
        targets: const [AutofillTarget(kind: TargetKind.site, value: 'chase.com')],
        request: amazon(domain: 'chase.com'),
      );
      expect(result.outcome, MatchOutcome.noMatch);
      expect(result.reason, MatchReason.noTarget);
    });

    test('a browser keeps its address: unverified, it is still refused', () {
      final request = AutofillRequest.fromPlatform(
        packageName: 'org.mozilla.firefox',
        certificateSha256: realCert,
        claimedWebDomain: 'chase.com',
        knownBrowser: true,
      );
      expect(request.claimedWebDomain, 'chase.com');
      expect(offerUnlinked(request), isNull);
      expect(
        matchEntry(
          targets: const [AutofillTarget(kind: TargetKind.site, value: 'chase.com')],
          request: request,
        ).reason,
        MatchReason.domainNotTrustedSource,
      );
    });
  });

  group('brand names in titles', () {
    test('are matched as whole words, not as letters inside other words', () {
      // Found on a real device: "Example Bank" was warned about as the
      // brand X, because it contains the letter x.
      for (final title in [
        'Example Bank',
        'Xbox Live',
        'Purchase portal',
        'Pineapple Express',
        'Otherwise Cafe',
      ]) {
        expect(brandForTitle(title), isNull, reason: title);
      }
    });

    test('still recognise the brand when it is named', () {
      expect(brandForTitle('X')?.name, 'X');
      expect(brandForTitle('X (Twitter)')?.name, 'X');
      expect(brandForTitle('Chase checking')?.name, 'Chase');
      expect(brandForTitle('my apple id')?.name, 'Apple');
      expect(brandForTitle('Uber Eats')?.name, 'Uber');
      // Its own brand, not X for the x in it.
      expect(brandForTitle('Dropbox')?.name, 'Dropbox');
    });
  });

  group('brand table', () {
    test('recognises the real app for a known name', () {
      expect(
        checkPackageAgainstTitle(
          entryTitle: 'WhatsApp',
          packageName: 'com.whatsapp',
        ),
        BrandVerdict.recognised,
      );
    });

    test('knows a brand\'s regional apps (Amazon India)', () {
      for (final package in [
        'com.amazon.mShop.android.shopping',
        'in.amazon.mShop.android.shopping',
      ]) {
        expect(
          checkPackageAgainstTitle(entryTitle: 'Amazon', packageName: package),
          BrandVerdict.recognised,
          reason: package,
        );
      }
    });

    test('flags an app that is not the one it knows', () {
      // This is what protects the very first fill, before anything is pinned.
      expect(
        checkPackageAgainstTitle(
          entryTitle: 'WhatsApp',
          packageName: 'com.whatsapp.fake',
        ),
        BrandVerdict.mismatch,
      );
    });

    test('says nothing about names it does not know', () {
      expect(
        checkPackageAgainstTitle(
          entryTitle: 'My local library',
          packageName: 'com.library.app',
        ),
        BrandVerdict.unknown,
      );
    });

    test('claims no certificate fingerprints', () {
      // They cannot be obtained offline, and a wrong one blocks the real app.
      for (final brand in knownBrands) {
        expect(brand.domains, isNotEmpty, reason: brand.name);
      }
      expect(brandForDomain('chase.com')?.name, 'Chase');
      expect(brandForPackage('com.instagram.android')?.name, 'Instagram');
    });
  });

  group('whether an app pin was verified', () {
    const pkg = 'com.example.bank';
    final key = 'ab' * 32;

    test('is kept in the stored form, after the parts older builds read', () {
      final pin = AutofillTarget(kind: TargetKind.app, value: pkg, certificateSha256: key, verified: true);
      expect(pin.encode(), 'app:$pkg:$key:verified');
      expect(AutofillTarget.decode(pin.encode()), pin);
    });

    test('a pin from before it was recorded counts as not verified', () {
      final pin = AutofillTarget.decode('app:$pkg:$key')!;
      expect(pin.verified, isFalse);
      expect(pin.certificateSha256, key);
    });

    test('a trusted match says when its pin was never verified', () {
      MatchResult match(List<String> targets) => matchEntry(
            targets: targets.map(AutofillTarget.decode).whereType<AutofillTarget>().toList(),
            request: AutofillRequest(
              packageName: pkg,
              certificateSha256: key,
              fromVerifiedBrowser: false,
              installedFromStore: true,
            ),
          );
      expect(match(['app:$pkg:$key']).outcome, MatchOutcome.trusted);
      expect(match(['app:$pkg:$key']).unverifiedPin, isTrue);
      expect(match(['app:$pkg:$key:verified']).unverifiedPin, isFalse);
    });
  });
}
