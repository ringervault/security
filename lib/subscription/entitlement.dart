/// What this phone knows about the user's subscription, and how long it
/// believes it without asking Google Play again.
///
/// Play is asked whenever the app comes to the front (not in Strict Offline
/// Mode). Each time it says the subscription is active, [confirmedAt] moves
/// on. Without a new answer the subscription is believed for [believedFor]
/// after the last one: a month of billing and a few days to spare, so a
/// subscriber who stays offline is not cut off early, and one who cancels is
/// not kept on for long. When Play answers that there is no subscription,
/// it ends at once.
///
/// [purchaseJson] and [signature] are Google Play's own signed record of the
/// purchase. The sync file carries them so the browser extension can check
/// Google's signature itself, with no server of ours in between (FORMATS.md).
class Entitlement {
  /// How long a confirmation is believed.
  static const Duration believedFor = Duration(days: 35);

  final String productId;
  final String purchaseJson;
  final String signature;
  final bool autoRenewing;

  /// When Google Play last said this subscription is active.
  final DateTime confirmedAt;

  const Entitlement({
    required this.productId,
    required this.purchaseJson,
    required this.signature,
    required this.autoRenewing,
    required this.confirmedAt,
  });

  /// Whether it is believed at [now].
  bool activeAt(DateTime now) => now.isBefore(confirmedAt.add(believedFor));

  /// The same purchase, confirmed again at [at].
  Entitlement confirmed(DateTime at) => Entitlement(
        productId: productId,
        purchaseJson: purchaseJson,
        signature: signature,
        autoRenewing: autoRenewing,
        confirmedAt: at,
      );

  Map<String, Object?> toJson() => {
        'productId': productId,
        'purchaseJson': purchaseJson,
        'signature': signature,
        'autoRenewing': autoRenewing,
        'confirmedAt': confirmedAt.toUtc().toIso8601String(),
      };

  /// Null for anything that is not one: a damaged record counts as none.
  static Entitlement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final productId = raw['productId'];
    final purchaseJson = raw['purchaseJson'];
    final signature = raw['signature'];
    final confirmedAt = DateTime.tryParse(raw['confirmedAt'] is String ? raw['confirmedAt'] as String : '');
    if (productId is! String || purchaseJson is! String || signature is! String || confirmedAt == null) {
      return null;
    }
    return Entitlement(
      productId: productId,
      purchaseJson: purchaseJson,
      signature: signature,
      autoRenewing: raw['autoRenewing'] == true,
      confirmedAt: confirmedAt,
    );
  }
}

/// The time to judge a subscription by: the phone's clock, but never earlier
/// than the latest time already seen, so turning the clock back does not
/// stretch a subscription that has run out.
DateTime ratchetedNow(DateTime clock, DateTime? latestSeen) =>
    latestSeen != null && clock.isBefore(latestSeen) ? latestSeen : clock;
