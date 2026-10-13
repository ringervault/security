import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/autofill/autofill_target.dart';
import 'package:ringer_vault/autofill/suggest.dart';
import 'package:ringer_vault/models/vault_entry.dart';

/// Suggestions only reorder the list; they never let anything fill without
/// the confirmation. So these tests are about being useful, not strict.
void main() {
  final cert = 'ab' * 32;

  AutofillRequest site(String domain) => AutofillRequest(
    packageName: 'com.android.chrome',
    certificateSha256: cert,
    claimedWebDomain: domain,
    fromVerifiedBrowser: true,
    knownBrowser: true,
    webScheme: 'https',
  );

  AutofillRequest app(String package) =>
      AutofillRequest(packageName: package, certificateSha256: cert);

  VaultEntry entry(
    String title, {
    String username = '',
    String email = '',
    List<String> targets = const [],
  }) => VaultEntry(
    title: title,
    username: username,
    email: email,
    password: 'p',
    category: 'Social',
    autofillTargets: targets,
  );

  group('what a destination is called', () {
    test('a site by its name, without the ending', () {
      expect(suggestionTerms(site('www.amazon.in')), {'amazon'});
      expect(suggestionTerms(site('mail.bbc.co.uk')), {'bbc'});
    });

    test('an app by its label and the company in its package name', () {
      expect(
        suggestionTerms(
          app('in.amazon.mShop.android.shopping'),
          appLabel: 'Amazon Shopping',
        ),
        {'amazon'},
      );
    });

    test('one company under several names', () {
      expect(
        suggestionTerms(app('com.google.android.gm'), appLabel: 'Gmail'),
        containsAll(['gmail', 'google', 'youtube']),
      );
    });

    test('a browser\'s own screens suggest nothing', () {
      final request = AutofillRequest(
        packageName: 'com.android.chrome',
        certificateSha256: cert,
        knownBrowser: true,
      );
      expect(suggestionTerms(request, appLabel: 'Chrome'), isEmpty);
    });
  });

  group('which entries are suggested', () {
    test('by a word in the name', () {
      expect(suggests(entry('Amazon'), {'amazon'}), isTrue);
      expect(suggests(entry('Amazon Pay'), {'amazon'}), isTrue);
      expect(suggests(entry('My amazon.in login'), {'amazon'}), isTrue);
    });

    test('by a site it is already linked to elsewhere', () {
      // Saved for amazon.com, now on amazon.in.
      expect(
        suggests(entry('Shopping', targets: ['site:amazon.com']), {'amazon'}),
        isTrue,
      );
    });

    test('by the domain of its email', () {
      expect(
        suggests(entry('Personal', email: 'ada@gmail.com'), {'gmail'}),
        isTrue,
      );
    });

    test('not by a word that merely contains the name', () {
      expect(suggests(entry('Example Bank'), {'x'}), isFalse);
      expect(suggests(entry('Pineapple'), {'apple'}), isFalse);
    });

    test('nothing without a name to go on', () {
      expect(suggests(entry('Amazon'), {}), isFalse);
    });
  });

  group('search', () {
    test('matches name, username, email and linked sites', () {
      final e = entry(
        'Work mail',
        username: 'ada',
        email: 'ada@corp.example',
        targets: ['site:mail.corp.example'],
      );
      expect(searchMatches(e, 'WORK'), isTrue);
      expect(searchMatches(e, 'ada'), isTrue);
      expect(searchMatches(e, 'corp.example'), isTrue);
      expect(searchMatches(e, 'bank'), isFalse);
      expect(searchMatches(e, '  '), isTrue);
    });
  });

  group('a name for a new entry', () {
    test('from a site', () {
      expect(newEntryTitle(site('www.amazon.in')), 'Amazon');
    });

    test('from an app, preferring its label', () {
      expect(
        newEntryTitle(app('in.amazon.mShop.android.shopping'),
            appLabel: 'Amazon Shopping'),
        'Amazon Shopping',
      );
      expect(newEntryTitle(app('in.amazon.mShop.android.shopping')), 'Amazon');
    });
  });
}
