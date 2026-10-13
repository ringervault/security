import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/autofill/autofill_target.dart';
import 'package:ringer_vault/autofill/suggest.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/repository/decoy_seed.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/services/save_inbox.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_container.dart';

import 'support/render_harness.dart';

/// Saving without an unlock (lib/services/save_inbox.dart): a login sealed
/// while the vault is locked joins it at the next unlock, exactly once, in
/// each vault, and the files never say whether a decoy exists.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pin = '482916';
  const decoyPin = '246801';
  final storage = StorageService();
  late RenderHarness harness;

  const chrome = AutofillRequest(
    packageName: 'com.android.chrome',
    certificateSha256: 'aa',
    claimedWebDomain: 'www.shop.example',
    fromVerifiedBrowser: true,
    webScheme: 'https',
    knownBrowser: true,
  );

  InboxLogin login({
    String username = 'ada@mail.example',
    String password = 'typed-pass',
    AutofillRequest request = chrome,
    String title = 'Shop',
  }) =>
      InboxLogin(
        request: request,
        title: title,
        username: username,
        password: password,
        category: 'Utility',
        savedAt: DateTime.now(),
      );

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp(pin: pin, entries: [
      VaultEntry(
        id: 'bank',
        title: 'Bank',
        username: 'ada',
        password: 'bank-pass',
        category: 'Banking',
        autofillTargets: const ['site:bank.example'],
      ),
    ]);
    await AuthService().logout();
  });
  tearDown(() async {
    if (harness.isUp) await harness.tearDown();
  });

  List<File> inboxFiles() {
    final dir = Directory('${storage.directoryPath}/inbox');
    if (!dir.existsSync()) return const [];
    return dir.listSync().whereType<File>().toList();
  }

  VaultEntry? titled(String title) =>
      storage.getEntries().where((e) => e.title == title).firstOrNull;

  test('ready once a vault has been opened, not before', () async {
    expect(await SaveInbox().isReady, isTrue);
    for (final name in SaveInbox.keyNames) {
      expect(harness.secureStorage[name], isNotNull, reason: 'both slots always have a key');
    }
  });

  test('saved while locked, added at the next unlock, linked to the site', () async {
    await SaveInbox().add(login());
    expect(await AuthService().verifyPin(pin), isTrue);

    final shop = titled('Shop')!;
    expect(shop.password, 'typed-pass');
    expect(shop.email, 'ada@mail.example');
    expect(shop.category, 'Utility');
    expect(shop.autofillTargets, ['site:shop.example']);
    final notices = storage.metaValue(inboxNoticeMeta) as List;
    expect(InboxNotice.fromJson(notices.single)!.title, 'Shop');
  });

  test('taken once: a second unlock adds nothing, and the file stays as it was in size', () async {
    await SaveInbox().add(login());
    final size = inboxFiles().single.lengthSync();
    expect(await AuthService().verifyPin(pin), isTrue);
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);

    expect(storage.getEntries().where((e) => e.title == 'Shop'), hasLength(1));
    expect(inboxFiles().single.lengthSync(), size,
        reason: 'the copy is overwritten, not removed, so the file looks the same');
  });

  test('a new password for an account already linked updates it, keeping the old one', () async {
    await SaveInbox().add(login(
      request: const AutofillRequest(
        packageName: 'com.android.chrome',
        certificateSha256: 'aa',
        claimedWebDomain: 'bank.example',
        fromVerifiedBrowser: true,
        webScheme: 'https',
        knownBrowser: true,
      ),
      username: 'ada',
      password: 'bank-new',
      title: 'Bank',
    ));
    expect(await AuthService().verifyPin(pin), isTrue);

    expect(storage.getEntries(), hasLength(1));
    final bank = titled('Bank')!;
    expect(bank.password, 'bank-new');
    expect(bank.passwordHistory.map((p) => p.password), ['bank-pass']);
    final notice = InboxNotice.fromJson((storage.metaValue(inboxNoticeMeta) as List).single)!;
    expect(notice.updated, isTrue);
  });

  group('a login that only looks like an existing entry', () {
    // An entry named Shop, for the same account, not linked to any site: a
    // locked save from shop.example must not quietly overwrite or link it.
    Future<void> unlinkedShop() async {
      expect(await AuthService().verifyPin(pin), isTrue);
      await storage.addEntry(VaultEntry(
        id: 'shop', title: 'Shop', username: '', email: 'ada@mail.example',
        password: 'shop-old', category: 'Utility',
      ));
      await AuthService().logout();
    }

    VaultEntry shop() => storage.getEntries().firstWhere((e) => e.id == 'shop');

    test('is asked about, and nothing changes until then', () async {
      await unlinkedShop();
      await SaveInbox().add(login(password: 'shop-new'));
      expect(await AuthService().verifyPin(pin), isTrue);

      expect(shop().password, 'shop-old');
      expect(shop().autofillTargets, isEmpty);
      expect(storage.getEntries().where((e) => e.title == 'Shop'), hasLength(1));
      final q = inboxQuestions().single;
      expect(q.entryTitle, 'Shop');
      expect(q.destination, 'shop.example');
    });

    test('answered "update": the password changes, the old one is kept, and it is linked', () async {
      await unlinkedShop();
      await SaveInbox().add(login(password: 'shop-new'));
      expect(await AuthService().verifyPin(pin), isTrue);
      await answerInboxQuestion(inboxQuestions().single, update: true);

      expect(shop().password, 'shop-new');
      expect(shop().passwordHistory.map((p) => p.password), ['shop-old']);
      expect(shop().autofillTargets, ['site:shop.example']);
      expect(inboxQuestions(), isEmpty);
    });

    test('answered "new entry": the existing one is left alone', () async {
      await unlinkedShop();
      await SaveInbox().add(login(password: 'shop-new'));
      expect(await AuthService().verifyPin(pin), isTrue);
      await answerInboxQuestion(inboxQuestions().single, update: false);

      expect(shop().password, 'shop-old');
      expect(shop().autofillTargets, isEmpty);
      final added = storage.getEntries().where((e) => e.id != 'shop' && e.title == 'Shop').single;
      expect(added.password, 'shop-new');
      expect(added.autofillTargets, ['site:shop.example']);
    });

    test('an app named like it is never linked to it without the answer', () async {
      await unlinkedShop();
      await SaveInbox().add(login(
        password: 'typed-in-app',
        request: AutofillRequest(packageName: 'com.fake.shop', certificateSha256: 'b' * 64),
        title: 'Shop',
      ));
      expect(await AuthService().verifyPin(pin), isTrue);
      expect(shop().autofillTargets.where((t) => t.startsWith('app:')), isEmpty);
      expect(shop().password, 'shop-old');
    });
  });

  test('the same password already saved adds nothing', () async {
    await SaveInbox().add(login(
      request: const AutofillRequest(
        packageName: 'com.android.chrome',
        certificateSha256: 'aa',
        claimedWebDomain: 'bank.example',
        fromVerifiedBrowser: true,
        webScheme: 'https',
        knownBrowser: true,
      ),
      username: 'ada',
      password: 'bank-pass',
      title: 'Bank',
    ));
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(storage.getEntries(), hasLength(1));
    expect(storage.metaValue(inboxNoticeMeta), anyOf(isNull, isEmpty));
  });

  test('a site that looks like one of the vault\'s own is said in red at the unlock', () async {
    expect(await AuthService().verifyPin(pin), isTrue);
    await storage.addEntry(VaultEntry(
      title: 'Ringer Bank',
      username: 'ada',
      password: 'p',
      category: 'Banking',
      autofillTargets: const ['site:ringerbank.com'],
    ));
    await AuthService().logout();
    await SaveInbox().add(login(
      request: const AutofillRequest(
        packageName: 'com.android.chrome',
        certificateSha256: 'aa',
        claimedWebDomain: 'r1ngerbank.com',
        fromVerifiedBrowser: true,
        webScheme: 'https',
        knownBrowser: true,
      ),
      title: 'R1ngerbank',
    ));
    expect(await AuthService().verifyPin(pin), isTrue);
    final notice = InboxNotice.fromJson((storage.metaValue(inboxNoticeMeta) as List).single);
    expect(notice?.warning, isNotNull);
    expect(notice?.danger, isTrue);
    final log = storage.vaultLog;
    expect(log.any((l) => l['action'] == 'Autofill save despite warning'), isTrue);
  });

  test('a vault takes its own waiting login however old it is', () async {
    await SaveInbox().add(login(), now: DateTime.now().subtract(const Duration(days: SaveInbox.keepDays + 30)));
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(titled('Shop'), isNotNull);
  });

  test('an old file this vault cannot open (taken, or another vault\'s) is removed', () async {
    await SaveInbox().add(login(), now: DateTime.now().subtract(const Duration(days: SaveInbox.keepDays + 2)));
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(inboxFiles(), hasLength(1), reason: 'taken now, removed only once old and spent');
    await AuthService().logout();
    expect(await AuthService().verifyPin(pin), isTrue);
    expect(inboxFiles(), isEmpty);
  });

  test('a password typed into the save never reaches the inbox file in the clear', () async {
    await SaveInbox().add(login(password: 'very-distinct-secret-123'));
    final bytes = inboxFiles().single.readAsBytesSync();
    final text = String.fromCharCodes(bytes);
    expect(text.contains('very-distinct-secret-123'), isFalse);
    expect(text.contains('ada@mail.example'), isFalse);
    expect(text.contains('shop.example'), isFalse);
  });

  test('erasing everything removes the inbox and its keys', () async {
    await SaveInbox().add(login());
    await storage.destroyAllVaults();
    expect(inboxFiles(), isEmpty);
    for (final name in SaveInbox.keyNames) {
      expect(harness.secureStorage[name], isNull);
    }
    expect(await SaveInbox().isReady, isFalse);
  });

  group('with a decoy', () {
    setUp(() async {
      expect(await AuthService().verifyPin(pin), isTrue);
      await AuthService().setSecondaryPin(decoyPin);
      await AuthService().fillNewDecoy(const DecoyIdentity(name: 'Sam Lee', email: 'sam@example.com'));
      await AuthService().logout();
      // The decoy's key is made the first time it opens.
      expect(await AuthService().verifyPin(decoyPin), isTrue);
      await AuthService().logout();
    });

    test('each vault takes its own copy, once', () async {
      await SaveInbox().add(login());

      expect(await AuthService().verifyPin(decoyPin), isTrue);
      expect(storage.isDecoyMode, isTrue);
      expect(titled('Shop'), isNotNull, reason: 'the decoy gets it too, so it gives nothing away');
      await AuthService().logout();

      expect(await AuthService().verifyPin(pin), isTrue);
      expect(storage.isDecoyMode, isFalse);
      expect(storage.getEntries().where((e) => e.title == 'Shop'), hasLength(1));
      await AuthService().logout();

      expect(await AuthService().verifyPin(decoyPin), isTrue);
      expect(storage.getEntries().where((e) => e.title == 'Shop'), hasLength(1));
    });

    test('the decoy never sees the real vault\'s key, nor can it erase it', () async {
      final realKey = harness.secureStorage[SaveInbox.keyNames[realSlot]];
      expect(await AuthService().verifyPin(decoyPin), isTrue);
      expect(harness.secureStorage[SaveInbox.keyNames[realSlot]], realKey);
      expect(storage.metaValue(inboxKeyMeta), isNotNull);
    });
  });

  group('the category guess', () {
    String guess(String domain) => guessCategory(AutofillRequest(
          packageName: 'com.android.chrome',
          certificateSha256: 'aa',
          claimedWebDomain: domain,
          fromVerifiedBrowser: true,
          knownBrowser: true,
        ));

    test('names the obvious ones, and Utility otherwise', () {
      expect(guess('www.netflix.com'), 'Entertainment');
      expect(guess('mail.google.com'), anyOf('Email', 'Utility'));
      expect(guess('netbanking.hdfcbank.com'), 'Banking');
      expect(guess('www.instagram.com'), 'Social');
      expect(guess('github.com'), 'Work');
      expect(guess('www.amazon.in'), 'Utility');
    });
  });
}
