import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:ringer_vault/subscription/entitlement.dart';
import 'package:ringer_vault/subscription/plan.dart';
import 'package:ringer_vault/subscription/redeem_code.dart';
import 'package:ringer_vault/subscription/store.dart';

/// The subscription as the rest of the app sees it.
@immutable
class SubscriptionState {
  final bool subscribed;
  final Entitlement? entitlement;

  /// The offer to show on the subscribe sheet, once Play has described it.
  final StoreOffer? offer;

  /// Something worth saying ("Google Play could not be reached"), or null.
  final String? message;

  /// When the redeem codes running now run out, or null when none is.
  final DateTime? codeUntil;

  const SubscriptionState({
    required this.subscribed,
    this.entitlement,
    this.offer,
    this.message,
    this.codeUntil,
  });

  SubscriptionState copyWith({StoreOffer? offer, String? message, bool clearMessage = false}) => SubscriptionState(
        subscribed: subscribed,
        entitlement: entitlement,
        offer: offer ?? this.offer,
        message: clearMessage ? null : (message ?? this.message),
        codeUntil: codeUntil,
      );
}

/// The subscription: what Google Play says, remembered between runs, and
/// the free plan's limit for everything that adds a login (plan.dart).
///
/// Both vaults, the real one and the decoy, follow the same answer: the
/// subscription belongs to the phone's Google account, not to a vault, so
/// nothing here can tell which vault is open, or that there are two.
class SubscriptionService {
  SubscriptionService._();
  static final SubscriptionService instance = SubscriptionService._();

  /// The subscription's id in Play Console: one product, a monthly base
  /// plan, and a free-trial offer on it (docs/SUBSCRIPTION.md).
  static const String productId = 'ringervault_premium';

  static const _storage = FlutterSecureStorage();
  static const _kEntitlement = 'subscription.entitlement';
  static const _kLatestSeen = 'subscription.latestSeen';
  static const _kCodeGrants = 'subscription.codeGrants';

  /// Where subscriptions are bought; a stand-in in tests. Made on first
  /// use, since connecting to Google Play is not free.
  SubscriptionStore get store => _store ??= PlayStore();
  set store(SubscriptionStore value) => _store = value;
  SubscriptionStore? _store;

  /// Tests that are not about the subscription: every vault unlimited.
  @visibleForTesting
  static bool debugAssumeSubscribed = false;

  /// The phone's clock, replaceable in tests.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// The key redeem codes are checked with; the test key in tests.
  @visibleForTesting
  static String codeKey = RedeemCode.codePublicKey;

  final ValueNotifier<SubscriptionState> state = ValueNotifier(const SubscriptionState(subscribed: false));

  Entitlement? _entitlement;
  DateTime? _latestSeen;
  StreamSubscription<List<StorePurchase>>? _updates;

  /// Every redeem code this phone knows was redeemed, here or (through the
  /// sync file) on another device of the same vault, and when they run out.
  List<CodeGrant> _grants = const [];
  DateTime? _grantsUntil;
  String? _codePlan;
  Timer? _codeEnds;

  /// Whether the free plan's limit is lifted now.
  bool get isSubscribed {
    if (debugAssumeSubscribed) return true;
    final now = _now();
    return _playActiveAt(now) || _codesActiveAt(now);
  }

  bool _playActiveAt(DateTime now) {
    final e = _entitlement;
    return e != null && e.activeAt(now);
  }

  bool _codesActiveAt(DateTime now) {
    final until = _grantsUntil;
    return until != null && now.isBefore(until);
  }

  /// When the redeem codes running now run out, or null when none is.
  DateTime? get codeUntil => _codesActiveAt(_now()) ? _grantsUntil : null;

  /// Whether Google Play's subscription is what makes this phone Premium.
  bool get viaPlay => _playActiveAt(_now());

  /// The plan of the latest code giving Premium ("1 week", "Lifetime"),
  /// while codes are running; null otherwise.
  String? get codePlan => _codesActiveAt(_now()) ? _codePlan : null;

  /// When Premium from codes ended, once it has; null while it runs, or
  /// when no code was ever redeemed.
  DateTime? get codeEndedAt {
    final until = _grantsUntil;
    return until != null && !until.isAfter(_now()) ? until : null;
  }

  /// Whether Google Play says the subscription renews (false once it is
  /// cancelled in the Play Store and runs to the end of the paid month).
  bool get playRenews => _entitlement?.autoRenewing ?? false;

  /// The redeemed codes, for the sync file (FORMATS.md, section 10).
  List<Map<String, Object?>> get syncCodeGrants => [for (final g in _grants) g.toJson()];

  /// Room for new logins in a vault already holding [count].
  int roomFor(int count) => roomLeft(count: count, subscribed: isSubscribed);

  /// Google's signed record, for the sync file (the extension checks it).
  Map<String, Object?>? get syncRecord => _entitlement?.toJson();

  DateTime _now() {
    final now = ratchetedNow(clock(), _latestSeen);
    _latestSeen = now;
    return now;
  }

  /// Reads what was last known, and starts listening for purchases.
  Future<void> load() async {
    await loadKnown();
    _updates ??= store.updates.listen(_onUpdates, onError: (_) {});
  }

  /// Reads what was last known, without connecting to Google Play: enough
  /// for the free plan's limit where nothing is bought, as on the autofill
  /// screen, which used to count a subscriber as free.
  Future<void> loadKnown() async {
    try {
      final raw = await _storage.read(key: _kEntitlement);
      _entitlement = raw == null ? null : Entitlement.fromJson(jsonDecode(raw));
      _latestSeen = DateTime.tryParse(await _storage.read(key: _kLatestSeen) ?? '');
    } catch (_) {
      _entitlement = null;
    }
    try {
      final raw = await _storage.read(key: _kCodeGrants);
      _grants = raw == null
          ? const []
          : [for (final g in jsonDecode(raw) as List) ?CodeGrant.fromJson(g)];
    } catch (_) {
      _grants = const [];
    }
    await _recountGrants();
    _publish();
  }

  /// Redeems one of Ringer Vault's own codes on this phone: a day, a week,
  /// a month, a year or a lifetime of Premium, or a cancel code, which stops
  /// Premium from codes there and then. Works offline: the code checks
  /// itself. Google Play codes are redeemed in the Play Store instead.
  Future<RedeemOutcome> redeemCode(String text) async {
    final code = RedeemCode.parse(text);
    if (code == null || !await code.isGenuine(publicKey: codeKey)) {
      return const RedeemOutcome.problem(
        'This is not a Ringer Vault code. Check that all of it was copied, '
        'from "RV-" to the end.',
      );
    }
    final now = _now();
    if (_grants.any((g) => g.id == code.id)) {
      return const RedeemOutcome.problem('This code has already been used.');
    }
    if (!code.redeemableAt(now)) {
      // The day the code was made for, as a date: not shifted to this
      // phone's time zone, which could make it read a day later.
      return RedeemOutcome.problem('This code could only be used until '
          '${dayText(code.redeemBy.subtract(const Duration(seconds: 1)), utc: true)}.');
    }
    final play = _playActiveAt(now);
    const playNote = 'A Google Play subscription is cancelled in the Play Store, '
        'under Payments and subscriptions.';
    if (code.kind == CodeKind.cancel) {
      if (!_codesActiveAt(now)) {
        return RedeemOutcome.problem(
          'There is no Premium from a code to stop on this phone.${play ? ' $playNote' : ''}',
        );
      }
      await _setGrants([..._grants, CodeGrant(code: code.text, redeemedAt: now)]);
      return RedeemOutcome.done(
        'Premium from codes has stopped.${play ? ' $playNote' : ''}',
      );
    }
    if (play) {
      return const RedeemOutcome.problem(
        'You already have Ringer Vault Premium through Google Play, so the code '
        'would be wasted. Keep it for later, or give it to someone.',
      );
    }
    await _setGrants([..._grants, CodeGrant(code: code.text, redeemedAt: now)]);
    final until = codeUntil;
    return RedeemOutcome.done(
      until == RedeemCode.lifetimeUntil
          ? 'Ringer Vault Premium is yours for good.'
          : 'Ringer Vault Premium is on until ${until == null ? 'later' : dateTimeText(until)}.',
    );
  }

  /// Takes in the codes the sync file says were redeemed (on this or another
  /// device of the same vault), so each counts here too and none is used twice.
  Future<void> takeSyncCodeGrants(List<Map<String, Object?>> remote) async {
    final incoming = [for (final g in remote) ?CodeGrant.fromJson(g)];
    final merged = unionOfGrants(_grants, incoming);
    if (_sameGrants(merged, _grants)) return;
    await _setGrants(merged);
  }

  static bool _sameGrants(List<CodeGrant> a, List<CodeGrant> b) {
    if (a.length != b.length) return false;
    String key(CodeGrant g) => '${g.code}@${g.redeemedAt.toIso8601String()}';
    return a.map(key).toSet().containsAll(b.map(key));
  }

  Future<void> _setGrants(List<CodeGrant> grants) async {
    _grants = grants;
    try {
      await _storage.write(key: _kCodeGrants, value: jsonEncode([for (final g in grants) g.toJson()]));
      await _storage.write(key: _kLatestSeen, value: _now().toUtc().toIso8601String());
    } catch (_) {
      // Kept in memory for this run.
    }
    await _recountGrants();
    _publish();
  }

  Future<void> _recountGrants() async {
    final counted = await countedGrants(_grants, publicKey: codeKey);
    _grantsUntil = grantsUntil(counted);
    _codePlan = latestPlan(counted);
    // Said again when the codes run out, so screens showing it move on.
    _codeEnds?.cancel();
    final until = _grantsUntil;
    if (until != null && until.isAfter(_now())) {
      _codeEnds = Timer(until.difference(_now()), _publish);
    }
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "31 Dec 2026", on this phone's calendar, or as the UTC date.
  static String dayText(DateTime at, {bool utc = false}) {
    final local = utc ? at.toUtc() : at.toLocal();
    return '${local.day} ${_months[local.month - 1]} ${local.year}';
  }

  /// "31 Dec 2026, 14:05", on this phone's clock.
  static String dateTimeText(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dayText(local)}, ${two(local.hour)}:${two(local.minute)}';
  }

  /// Asks Google Play what is active now. Not in Strict Offline Mode: the
  /// last answer is believed for its month instead (Entitlement).
  Future<void> refresh() async {
    if (AuthService().isStrictOfflineModeCached) return;
    try {
      if (!await store.isAvailable()) return;
      final mine = (await store.activePurchases())
          .where((p) => p.productId == productId && p.purchased)
          .toList();
      if (mine.isEmpty) {
        // Play answered, and there is no subscription: it has ended.
        await _set(null);
        return;
      }
      await _accept(mine.first);
    } catch (_) {
      // Play could not be asked: keep what is known.
    }
  }

  /// Fetches the offer to show, if Play can describe it.
  Future<StoreOffer?> loadOffer() async {
    try {
      if (!await store.isAvailable()) return null;
      final offer = await store.offer(productId);
      if (offer != null) state.value = state.value.copyWith(offer: offer);
      return offer;
    } catch (_) {
      return null;
    }
  }

  /// Opens Google Play's purchase sheet. Returns a reason it could not, fit
  /// to show, or null once the sheet is open (the result comes later).
  Future<String?> subscribe() async {
    if (AuthService().isStrictOfflineModeCached) {
      return 'Strict Offline Mode is on. Turn it off to subscribe through Google Play.';
    }
    final offer = state.value.offer ?? await loadOffer();
    if (offer == null) {
      return 'Google Play could not show the subscription. Check that you are '
          'signed in to Google Play and online, then try again.';
    }
    try {
      await store.buy(offer);
      return null;
    } catch (_) {
      return 'Google Play could not start the purchase. Try again in a moment.';
    }
  }

  /// "Restore purchase": asks Play again. True when a subscription was found.
  Future<bool> restore() async {
    await refresh();
    return isSubscribed;
  }

  Future<void> _onUpdates(List<StorePurchase> purchases) async {
    for (final p in purchases) {
      if (p.productId != productId) continue;
      if (p.needsAcknowledging && p.purchased) {
        try {
          await store.acknowledge(p);
        } catch (_) {
          // Asked again on the next refresh: Play keeps the purchase pending.
        }
      }
      if (p.purchased) await _accept(p);
    }
  }

  Future<void> _accept(StorePurchase p) async {
    if (p.needsAcknowledging) {
      try {
        await store.acknowledge(p);
      } catch (_) {}
    }
    await _set(Entitlement(
      productId: p.productId,
      purchaseJson: p.purchaseJson,
      signature: p.signature,
      autoRenewing: p.autoRenewing,
      confirmedAt: _now(),
    ));
  }

  Future<void> _set(Entitlement? e) async {
    _entitlement = e;
    try {
      if (e == null) {
        await _storage.delete(key: _kEntitlement);
      } else {
        await _storage.write(key: _kEntitlement, value: jsonEncode(e.toJson()));
      }
      await _storage.write(key: _kLatestSeen, value: _now().toUtc().toIso8601String());
    } catch (_) {
      // Kept in memory for this run.
    }
    _publish();
  }

  void _publish() {
    state.value = SubscriptionState(
      subscribed: isSubscribed,
      entitlement: _entitlement,
      offer: state.value.offer,
      codeUntil: codeUntil,
    );
  }

  /// Forgets everything, for tests.
  @visibleForTesting
  Future<void> debugReset() async {
    await _updates?.cancel();
    _updates = null;
    _entitlement = null;
    _latestSeen = null;
    _grants = const [];
    _grantsUntil = null;
    _codePlan = null;
    _codeEnds?.cancel();
    _codeEnds = null;
    state.value = const SubscriptionState(subscribed: false);
  }
}

/// What redeeming a code did: [ok], and what to tell the user either way.
@immutable
class RedeemOutcome {
  final bool ok;
  final String message;

  const RedeemOutcome.done(this.message) : ok = true;
  const RedeemOutcome.problem(this.message) : ok = false;
}
