import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/autofill/suggest.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/repository/vault_repository.dart';

import 'support/render_harness.dart';

/// Finding an entry by the website or app it is linked to, in the app's
/// search and in the autofill sheet's search.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final amazon = VaultEntry(
    id: 'amazon',
    title: 'Shopping account',
    username: 'ada',
    password: 'p',
    category: 'Utility',
    autofillTargets: const ['site:amazon.in'],
  );
  final bankApp = VaultEntry(
    id: 'bank',
    title: 'My bank',
    username: 'ada',
    password: 'p',
    category: 'Banking',
    autofillTargets: ['app:com.example.bank:${'a' * 64}'],
  );
  final other = VaultEntry(id: 'other', title: 'Other', username: 'x', password: 'p', category: 'Social');

  group('the autofill sheet', () {
    test('finds an entry by its website, typed in part or pasted whole', () {
      expect(searchMatches(amazon, 'amazon'), isTrue);
      expect(searchMatches(amazon, 'amazon.in'), isTrue);
      expect(searchMatches(amazon, 'https://www.amazon.in/gp/cart?ref=x'), isTrue);
      expect(searchMatches(amazon, 'www.amazon.in'), isTrue);
      expect(searchMatches(other, 'amazon.in'), isFalse);
    });

    test('a different site with the same name is not the same site', () {
      expect(searchMatches(amazon, 'https://amazon.in.evil.example/login'), isFalse);
      expect(searchMatches(amazon, 'amazon.com'), isFalse);
    });

    test('finds an entry by the app it is linked to', () {
      expect(searchMatches(bankApp, 'com.example.bank'), isTrue);
      expect(searchMatches(bankApp, 'example.bank'), isTrue);
    });
  });

  group('the app\'s search', () {
    late RenderHarness harness;
    setUp(() async {
      harness = RenderHarness();
      await harness.setUp(pin: '482916', entries: [amazon, bankApp, other]);
    });
    tearDown(() => harness.tearDown());

    List<String> found(String query) =>
        VaultRepository().searchEntries(query).map((e) => e.id).toList();

    test('a website finds what is linked to it', () {
      expect(found('amazon.in'), ['amazon']);
      expect(found('https://www.amazon.in/your-orders'), ['amazon']);
      expect(found('AMAZON'), ['amazon']);
    });

    test('an app finds what is linked to it', () {
      expect(found('com.example.bank'), ['bank']);
    });

    test('the title still works as before', () {
      expect(found('Other'), ['other']);
    });
  });
}
