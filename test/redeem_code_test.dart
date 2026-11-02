import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/subscription/entitlement.dart';
import 'package:ringer_vault/subscription/redeem_code.dart';
import 'package:ringer_vault/subscription/store.dart';
import 'package:ringer_vault/subscription/subscription_service.dart';
import 'package:ringer_vault/sync/sync_payload.dart';

import 'support/render_harness.dart';

/// Redeeming codes on the phone, with the test codes in
/// test/fixtures/code_cases.json (redeem_code_cases_test.dart checks the
/// codes themselves).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cases = jsonDecode(File('test/fixtures/code_cases.json').readAsStringSync()) as Map;
  final testKey = cases['publicKey'] as String;
  String codeFor(String why) =>
      (cases['codes'] as List).firstWhere((c) => c['why'] == why)['code'] as String;

  group('redeeming on the phone', () {
    late RenderHarness harness;
    var now = DateTime.utc(2026, 11, 1, 9);
    final service = SubscriptionService.instance;

    setUp(() async {
      harness = RenderHarness();
      await harness.setUp();
      SubscriptionService.debugAssumeSubscribed = false;
      SubscriptionService.codeKey = testKey;
      now = DateTime.utc(2026, 11, 1, 9);
      SubscriptionService.clock = () => now;
      await service.debugReset();
      service.store = _NoPlay();
      await service.load();
    });

    tearDown(() async {
      SubscriptionService.debugAssumeSubscribed = true;
      SubscriptionService.codeKey = RedeemCode.codePublicKey;
      SubscriptionService.clock = DateTime.now;
      await service.debugReset();
      await harness.tearDown();
    });

    test('a week of Premium, then free again', () async {
      final outcome = await service.redeemCode(codeFor('one week'));
      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(outcome.message, contains('until'));
      expect(service.isSubscribed, isTrue);
      expect(service.codeUntil, DateTime.utc(2026, 11, 8, 9));
      expect(service.codePlan, '1 week');
      expect(service.codeEndedAt, isNull);

      now = DateTime.utc(2026, 11, 8, 10);
      expect(service.isSubscribed, isFalse);
      expect(service.codeUntil, isNull);
      expect(service.codePlan, isNull);
      expect(service.codeEndedAt, DateTime.utc(2026, 11, 8, 9), reason: 'said as expired');
    });

    test('kept on the phone between runs', () async {
      await service.redeemCode(codeFor('one month'));
      await service.debugReset();
      await service.load();
      expect(service.isSubscribed, isTrue);
      expect(service.codeUntil, DateTime.utc(2026, 12, 1, 9));
    });

    test('a code works once', () async {
      expect((await service.redeemCode(codeFor('one day'))).ok, isTrue);
      final again = await service.redeemCode(codeFor('one day'));
      expect(again.ok, isFalse);
      expect(again.message, contains('already been used'));
    });

    test('a lifetime, then a cancel stops it at once', () async {
      expect((await service.redeemCode(codeFor('lifetime'))).message, contains('for good'));
      expect(service.codeUntil, RedeemCode.lifetimeUntil);

      now = now.add(const Duration(days: 3));
      final cancelled = await service.redeemCode(codeFor('cancel'));
      expect(cancelled.ok, isTrue);
      expect(cancelled.message, contains('stopped'));
      expect(service.isSubscribed, isFalse);
    });

    test('a cancel with nothing running is not used up', () async {
      final outcome = await service.redeemCode(codeFor('cancel'));
      expect(outcome.ok, isFalse);
      expect(service.syncCodeGrants, isEmpty, reason: 'still there for later');
    });

    test('a code past its last day is refused', () async {
      final outcome = await service.redeemCode(codeFor('to be redeemed by 30 June 2026'));
      expect(outcome.ok, isFalse);
      expect(outcome.message, contains('30 Jun 2026'));
    });

    test('anything else is refused, and says what a code looks like', () async {
      for (final why in ['signed with another key', 'a day turned into a lifetime after signing', 'cut short']) {
        final outcome = await service.redeemCode(codeFor(why));
        expect(outcome.ok, isFalse, reason: why);
        expect(outcome.message, contains('RV-'));
      }
      expect(service.isSubscribed, isFalse);
    });

    test('not wasted while Google Play has a subscription running', () async {
      harness.secureStorage['subscription.entitlement'] = jsonEncode(Entitlement(
        productId: SubscriptionService.productId,
        purchaseJson: '{}',
        signature: 's',
        autoRenewing: true,
        confirmedAt: now,
      ).toJson());
      await service.load();
      final outcome = await service.redeemCode(codeFor('one year'));
      expect(outcome.ok, isFalse);
      expect(outcome.message, contains('Google Play'));
    });

    test('codes another device redeemed count here, and cannot be used again', () async {
      await service.takeSyncCodeGrants([
        {'code': codeFor('one week'), 'redeemedAt': '2026-10-31T09:00:00.000Z'},
      ]);
      expect(service.codeUntil, DateTime.utc(2026, 11, 7, 9));
      expect((await service.redeemCode(codeFor('one week'))).ok, isFalse);
    });

    test('the sync file carries them, and reads them back', () {
      final grants = [
        {'code': codeFor('one day'), 'redeemedAt': '2026-11-01T09:00:00.000Z'},
      ];
      final payload = SyncPayload(records: const {}, writtenBy: 'p', writtenAt: DateTime.utc(2026), codeGrants: grants);
      expect(SyncPayload.parse(payload.toJsonString()).codeGrants, grants);
      final none = SyncPayload(records: const {}, writtenBy: 'p', writtenAt: DateTime.utc(2026));
      expect(none.toJsonString(), isNot(contains('codeGrants')));
      expect(SyncPayload.parse(none.toJsonString()).codeGrants, isNull);
    });
  });
}

/// No Google Play: these tests are about codes.
class _NoPlay implements SubscriptionStore {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<StoreOffer?> offer(String productId) async => null;
  @override
  Future<List<StorePurchase>> activePurchases() async => const [];
  @override
  Future<void> buy(StoreOffer offer) async {}
  @override
  Stream<List<StorePurchase>> get updates => const Stream.empty();
  @override
  Future<void> acknowledge(StorePurchase purchase) async {}
}
