import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/repository/decoy_seed.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/subscription/entitlement.dart';
import 'package:ringer_vault/subscription/plan.dart';
import 'package:ringer_vault/subscription/store.dart';
import 'package:ringer_vault/subscription/subscription_service.dart';
import 'package:ringer_vault/sync/sync_engine.dart';
import 'package:ringer_vault/sync/sync_payload.dart';

import 'support/render_harness.dart';

/// Google Play, played by the test.
class FakePlay implements SubscriptionStore {
  List<StorePurchase> active = [];
  bool reachable = true;
  int acknowledged = 0;
  final controller = StreamController<List<StorePurchase>>.broadcast();

  @override
  Future<bool> isAvailable() async => reachable;

  @override
  Future<StoreOffer?> offer(String productId) async =>
      const StoreOffer(price: '₹99.00', trialPeriod: 'P7D', handle: 'offer');

  @override
  Future<List<StorePurchase>> activePurchases() async {
    if (!reachable) throw StateError('offline');
    return active;
  }

  @override
  Future<void> buy(StoreOffer offer) async {}

  @override
  Stream<List<StorePurchase>> get updates => controller.stream;

  @override
  Future<void> acknowledge(StorePurchase purchase) async => acknowledged++;
}

StorePurchase purchase({bool acknowledged = true, String id = SubscriptionService.productId}) => StorePurchase(
      productId: id,
      purchaseJson: '{"orderId":"GPA.1","productId":"$id"}',
      signature: 'c2lnbmVk',
      autoRenewing: true,
      purchased: true,
      needsAcknowledging: !acknowledged,
      handle: 'p',
    );

VaultEntry entry(int i) =>
    VaultEntry(title: 'Site $i', username: 'ada$i', password: 'pw$i', category: 'Utility');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RenderHarness harness;
  late FakePlay play;
  var now = DateTime.utc(2026, 11, 1, 9);
  final service = SubscriptionService.instance;

  setUp(() async {
    harness = RenderHarness();
    await harness.setUp();
    SubscriptionService.debugAssumeSubscribed = false;
    now = DateTime.utc(2026, 11, 1, 9);
    SubscriptionService.clock = () => now;
    await service.debugReset();
    play = FakePlay();
    service.store = play;
    await service.load();
  });

  tearDown(() async {
    SubscriptionService.debugAssumeSubscribed = true;
    SubscriptionService.clock = DateTime.now;
    await service.debugReset();
    await harness.tearDown();
  });

  group('the free plan', () {
    test('holds 20, and room never goes below none', () {
      expect(roomLeft(count: 0, subscribed: false), 20);
      expect(roomLeft(count: 18, subscribed: false), 2);
      expect(roomLeft(count: 47, subscribed: false), 0);
      expect(roomLeft(count: 47, subscribed: true), greaterThan(1000000));
    });

    test('the 21st login is refused, with what was saved and what would fit', () async {
      await StorageService().addEntries([for (var i = 0; i < 20; i++) entry(i)]);
      await expectLater(
        StorageService().addEntry(entry(20)),
        throwsA(isA<FreePlanFull>().having((e) => e.count, 'count', 20).having((e) => e.room, 'room', 0)),
      );
      expect(StorageService().getEntries(), hasLength(20));
    });

    test('an import that does not fit adds nothing at all', () async {
      await StorageService().addEntries([for (var i = 0; i < 15; i++) entry(i)]);
      await expectLater(
        StorageService().addEntries([for (var i = 15; i < 25; i++) entry(i)]),
        throwsA(isA<FreePlanFull>().having((e) => e.wanted, 'wanted', 10).having((e) => e.room, 'room', 5)),
      );
      expect(StorageService().getEntries(), hasLength(15));
    });

    test('over the limit, saved logins can still be edited and deleted', () async {
      SubscriptionService.debugAssumeSubscribed = true;
      await StorageService().addEntries([for (var i = 0; i < 25; i++) entry(i)]);
      SubscriptionService.debugAssumeSubscribed = false;

      final first = StorageService().getEntries().first;
      await StorageService().updateEntry(first.copyWith(password: 'changed'));
      await StorageService().deleteEntry(first.id);
      expect(StorageService().getEntries(), hasLength(24));
      expect(() => StorageService().addEntry(entry(99)), throwsA(isA<FreePlanFull>()));
    });

    test('a subscription lifts it', () async {
      play.active = [purchase()];
      await service.refresh();
      await StorageService().addEntries([for (var i = 0; i < 30; i++) entry(i)]);
      expect(StorageService().getEntries(), hasLength(30));
    });
  });

  group('what Google Play says', () {
    test('an active subscription is believed for 35 days after Play last said so', () async {
      play.active = [purchase()];
      await service.refresh();
      expect(service.isSubscribed, isTrue);

      play.reachable = false; // offline from here on
      now = now.add(const Duration(days: 34));
      await service.refresh();
      expect(service.isSubscribed, isTrue, reason: 'within a month and the grace days');
      now = now.add(const Duration(days: 2));
      expect(service.isSubscribed, isFalse, reason: 'not confirmed for more than 35 days');
    });

    test('Play answering "none" ends it at once', () async {
      play.active = [purchase()];
      await service.refresh();
      play.active = [];
      await service.refresh();
      expect(service.isSubscribed, isFalse);
      expect(service.state.value.entitlement, isNull);
    });

    test('turning the clock back does not stretch it', () async {
      play.active = [purchase()];
      await service.refresh();
      now = now.add(const Duration(days: 40));
      expect(service.isSubscribed, isFalse);
      now = now.subtract(const Duration(days: 39));
      expect(service.isSubscribed, isFalse, reason: 'the latest time seen still counts');
    });

    test('a new purchase is acknowledged, or Play would refund it', () async {
      play.controller.add([purchase(acknowledged: false)]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(play.acknowledged, greaterThanOrEqualTo(1));
      expect(service.isSubscribed, isTrue);
    });

    test('another product is not this subscription', () async {
      play.active = [purchase(id: 'something_else')];
      await service.refresh();
      expect(service.isSubscribed, isFalse);
    });

    test('kept across restarts', () async {
      play.active = [purchase()];
      await service.refresh();
      await service.debugReset();
      service.store = play;
      await service.load();
      expect(service.isSubscribed, isTrue);
    });
  });

  group('the sync file', () {
    test('carries the signed record, and reads it back', () {
      final record = Entitlement(
        productId: SubscriptionService.productId,
        purchaseJson: '{"orderId":"GPA.1"}',
        signature: 'c2ln',
        autoRenewing: true,
        confirmedAt: DateTime.utc(2026, 11, 1),
      ).toJson();
      final payload = SyncPayload(records: const {}, writtenBy: 'p', writtenAt: DateTime.utc(2026), entitlement: record);
      final back = SyncPayload.parse(payload.toJsonString());
      expect(back.entitlement, record);
      expect(Entitlement.fromJson(back.entitlement)!.signature, 'c2ln');
    });

    test('a file without one still reads', () {
      final payload = SyncPayload(records: const {}, writtenBy: 'p', writtenAt: DateTime.utc(2026));
      expect(SyncPayload.parse(payload.toJsonString()).entitlement, isNull);
    });

    test('a newer confirmation is written even with no entry changed', () {
      Map<String, Object?> at(DateTime t) => {'purchaseJson': 'x', 'confirmedAt': t.toIso8601String()};
      final day = DateTime.utc(2026, 11, 1);
      expect(entitlementBehind(null, at(day)), isTrue);
      expect(entitlementBehind(at(day), at(day.add(const Duration(hours: 5)))), isFalse);
      expect(entitlementBehind(at(day), at(day.add(const Duration(days: 3)))), isTrue);
      expect(entitlementBehind(at(day), null), isFalse, reason: 'a phone without one never wipes it');
    });
  });

  test('a decoy seeded on a free phone looks like a free vault', () {
    final seeded = buildDecoyEntries(DecoyIdentity.fallback, Random(7));
    expect(withinPlan(seeded).length, lessThanOrEqualTo(freeLogins));
    SubscriptionService.debugAssumeSubscribed = true;
    expect(withinPlan(seeded), hasLength(seeded.length));
  });

  test('a period reads as words', () {
    expect(describePeriod('P7D'), '7 days');
    expect(describePeriod('P1W'), '1 week');
    expect(describePeriod('P1M'), '1 month');
    expect(describePeriod('bad'), isNull);
  });
}
