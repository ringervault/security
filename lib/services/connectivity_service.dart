import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  static ConnectivityService get instance => _instance;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  /// Current state, as something the UI can listen to.
  ///
  /// A plain getter was not enough: the dashboard read it once when it was
  /// built, so the status stayed on whatever it said at the time and only
  /// corrected itself when the screen happened to be rebuilt. Anything
  /// showing connectivity has to follow it, because that indicator is the
  /// app's claim that it is not talking to a network.
  ///
  /// Assumed offline until the first check completes: for a vault that is the
  /// safe default, since Strict Offline Mode blocks on *online*.
  final ValueNotifier<bool> online = ValueNotifier<bool>(false);

  bool get isOnline => online.value;

  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _connectivity.onConnectivityChanged;

  Future<void> initialize() async {
    _apply(await _connectivity.checkConnectivity());

    // Tracks state only. Reacting to it (locking the vault, showing the
    // blocking overlay) belongs to _StrictConnectivityWrapper, which owns the
    // UI and is the single place that responds to changes.
    _subscription = _connectivity.onConnectivityChanged.listen(_apply);
  }

  void _apply(List<ConnectivityResult> results) {
    // ValueNotifier only notifies when the value actually changes, so a burst
    // of identical results costs nothing.
    online.value = !results.contains(ConnectivityResult.none);
  }

  void dispose() {
    _subscription?.cancel();
  }
}
