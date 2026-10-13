import 'package:flutter/services.dart';
import 'package:ringer_vault/autofill/autofill_target.dart';

/// A login the user typed into another app and asked to save.
class AutofillSaveRequest {
  final String? username;
  final String password;

  const AutofillSaveRequest({this.username, required this.password});
}

/// What the Android service asked for, as data.
class AutofillFillRequest {
  final AutofillRequest identity;
  final bool hasUsernameField;
  final bool hasPasswordField;

  /// The name the app shows under its icon. Only ever used to suggest
  /// entries and to label the screen, never to decide a fill: any app can
  /// call itself anything.
  final String? appLabel;

  /// Set when this is a save, not a fill.
  final AutofillSaveRequest? save;

  /// A username or email address already typed by hand, on this screen or
  /// the step before. Only decides which logins are listed first.
  final String? typedUsername;

  const AutofillFillRequest({
    required this.identity,
    required this.hasUsernameField,
    required this.hasPasswordField,
    this.appLabel,
    this.save,
    this.typedUsername,
  });
}

/// Bridge to the Android autofill service.
///
/// Deliberately thin. The platform side reports facts (who is asking, what
/// they were signed with, what they claim to be showing) and this side makes
/// every decision, because the decision needs the vault and the vault only
/// exists in Dart.
class AutofillChannel {
  static const MethodChannel _channel =
      MethodChannel('ringer_vault/autofill');

  static Future<AutofillFillRequest?> request() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getRequest');
      if (raw == null) return null;

      final package = raw['packageName'] as String?;
      final certificate = raw['certificateSha256'] as String?;
      if (package == null || certificate == null) return null;

      return AutofillFillRequest(
        identity: AutofillRequest.fromPlatform(
          packageName: package,
          certificateSha256: certificate,
          claimedWebDomain: raw['webDomain'] as String?,
          fromVerifiedBrowser: raw['fromVerifiedBrowser'] as bool? ?? false,
          installedFromStore: raw['installedFromStore'] as bool? ?? true,
          compatibilityMode: raw['compatibilityMode'] as bool? ?? false,
          webScheme: raw['webScheme'] as String?,
          knownBrowser: raw['knownBrowser'] as bool? ?? false,
        ),
        hasUsernameField: raw['hasUsernameField'] as bool? ?? false,
        hasPasswordField: raw['hasPasswordField'] as bool? ?? false,
        appLabel: raw['appLabel'] as String?,
        save: _saveFrom(raw['save']),
        typedUsername: (raw['typedUsername'] as String?)?.trim().isEmpty ?? true
            ? null
            : (raw['typedUsername'] as String).trim(),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Hands the chosen credential back to the system and closes the screen.
  static Future<void> fill({
    required String label,
    String? username,
    String? password,
  }) async {
    await _channel.invokeMethod<bool>('fill', {
      'label': label,
      'username': username,
      'password': password,
    });
  }

  static AutofillSaveRequest? _saveFrom(Object? raw) {
    if (raw is! Map) return null;
    final password = raw['password'];
    if (password is! String || password.isEmpty) return null;
    final username = raw['username'];
    return AutofillSaveRequest(
      username: username is String && username.isNotEmpty ? username : null,
      password: password,
    );
  }

  /// Closes the screen after a save.
  static Future<void> saved() async {
    await _channel.invokeMethod<bool>('saved');
  }

  static Future<void> cancel() async {
    await _channel.invokeMethod<bool>('cancel');
  }

  /// Listens for what the platform side can ask of a running screen.
  ///
  /// [onNewRequest] runs when a second login screen reuses the engine that is
  /// already running. Without it the screen would keep showing the previous
  /// app's request, which is the one way this feature could fill the wrong
  /// thing.
  ///
  /// [onRelease] runs when the main app wants the vault and this engine may
  /// still have it open. The reply is sent only once it has finished, so the
  /// main app can open the vault straight after.
  static void listen({
    required void Function() onNewRequest,
    required Future<void> Function() onRelease,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'newRequest':
          onNewRequest();
          return null;
        case 'release':
          await onRelease();
          return true;
      }
      return null;
    });
  }
}
