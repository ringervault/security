import 'dart:async';

import 'package:ringer_vault/subscription/subscription_service.dart';

/// Runs before every test file. Tests that are not about the subscription
/// fill vaults freely: the free plan's limit (lib/subscription/plan.dart)
/// is lifted here, and the subscription's own tests put it back.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SubscriptionService.debugAssumeSubscribed = true;
  await testMain();
}
