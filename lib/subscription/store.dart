import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

/// The subscription on sale, as Google Play describes it to this user.
class StoreOffer {
  /// The price after any trial, as Play formats it ("₹99.00").
  final String price;

  /// The free trial this user can still have, as Play states its length
  /// ("P7D"), or null when there is none for them.
  final String? trialPeriod;

  /// What [SubscriptionStore.buy] needs back.
  final Object handle;

  const StoreOffer({required this.price, this.trialPeriod, required this.handle});

  /// "7 days" for "P7D"; null for a period it does not recognise.
  String? get trialText => describePeriod(trialPeriod);
}

/// One purchase as Google Play reports it.
class StorePurchase {
  final String productId;

  /// Google's signed purchase data, and its signature.
  final String purchaseJson;
  final String signature;
  final bool autoRenewing;

  /// Paid for, as against still waiting (a cash payment, say).
  final bool purchased;

  /// Play refunds a purchase not acknowledged within three days.
  final bool needsAcknowledging;

  /// What [SubscriptionStore.acknowledge] needs back.
  final Object handle;

  const StorePurchase({
    required this.productId,
    required this.purchaseJson,
    required this.signature,
    required this.autoRenewing,
    required this.purchased,
    required this.needsAcknowledging,
    required this.handle,
  });
}

/// Where subscriptions are bought and checked: Google Play, or a stand-in in
/// tests. Nothing here goes to a server of ours: the app talks to the Play
/// Store app on the phone, and Play talks to Google.
abstract class SubscriptionStore {
  Future<bool> isAvailable();

  /// The monthly subscription, or null when Play cannot show it now.
  Future<StoreOffer?> offer(String productId);

  /// The subscriptions Play says are active for this phone's Google account.
  Future<List<StorePurchase>> activePurchases();

  /// Opens Play's purchase sheet. The outcome arrives on [updates].
  Future<void> buy(StoreOffer offer);

  /// Purchases as they complete, fail or are restored.
  Stream<List<StorePurchase>> get updates;

  Future<void> acknowledge(StorePurchase purchase);
}

/// [SubscriptionStore] through Google Play Billing.
class PlayStore implements SubscriptionStore {
  // Asked for on first use: reaching for it connects to Google Play.
  InAppPurchase get _iap => InAppPurchase.instance;

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Future<StoreOffer?> offer(String productId) async {
    final response = await _iap.queryProductDetails({productId});
    final offers = response.productDetails.whereType<GooglePlayProductDetails>().toList();
    if (offers.isEmpty) return null;
    // Play lists the base plan and each offer this user may have; one with a
    // free trial is offered first when they can still have it.
    GooglePlayProductDetails pick = offers.first;
    String? trial;
    for (final o in offers) {
      final phases = o.productDetails.subscriptionOfferDetails?[o.subscriptionIndex ?? 0].pricingPhases ?? const [];
      final free = phases.where((p) => p.priceAmountMicros == 0).firstOrNull;
      if (free != null) {
        pick = o;
        trial = free.billingPeriod;
        break;
      }
    }
    final phases = pick.productDetails.subscriptionOfferDetails?[pick.subscriptionIndex ?? 0].pricingPhases ?? const [];
    final recurring = phases.where((p) => p.priceAmountMicros > 0).lastOrNull;
    return StoreOffer(price: recurring?.formattedPrice ?? pick.price, trialPeriod: trial, handle: pick);
  }

  @override
  Future<List<StorePurchase>> activePurchases() async {
    final android = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final response = await android.queryPastPurchases();
    if (response.error != null) throw StateError('Google Play did not answer: ${response.error!.code}');
    return response.pastPurchases.map(_fromPlay).toList();
  }

  @override
  Future<void> buy(StoreOffer offer) async {
    final details = offer.handle as GooglePlayProductDetails;
    await _iap.buyNonConsumable(
      purchaseParam: GooglePlayPurchaseParam(productDetails: details, offerToken: details.offerToken),
    );
  }

  @override
  Stream<List<StorePurchase>> get updates => _iap.purchaseStream.map(
        (list) => list.whereType<GooglePlayPurchaseDetails>().map(_fromPlay).toList(),
      );

  @override
  Future<void> acknowledge(StorePurchase purchase) =>
      _iap.completePurchase(purchase.handle as PurchaseDetails);

  StorePurchase _fromPlay(GooglePlayPurchaseDetails details) {
    final p = details.billingClientPurchase;
    return StorePurchase(
      productId: p.products.isEmpty ? details.productID : p.products.first,
      purchaseJson: p.originalJson,
      signature: p.signature,
      autoRenewing: p.isAutoRenewing,
      purchased: details.status == PurchaseStatus.purchased || details.status == PurchaseStatus.restored,
      needsAcknowledging: details.pendingCompletePurchase,
      handle: details,
    );
  }
}

/// "7 days", "1 week", "1 month" for an ISO 8601 period such as "P7D"; null
/// for anything else.
String? describePeriod(String? period) {
  final match = RegExp(r'^P(\d+)([DWMY])$').firstMatch(period ?? '');
  if (match == null) return null;
  final n = int.parse(match.group(1)!);
  final unit = const {'D': 'day', 'W': 'week', 'M': 'month', 'Y': 'year'}[match.group(2)]!;
  return '$n ${n == 1 ? unit : '${unit}s'}';
}
