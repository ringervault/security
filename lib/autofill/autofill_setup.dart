import 'package:flutter/services.dart';

/// Whether Ringer Vault is set up to fill, as Android sees it.
class AutofillSetupStatus {
  /// The phone has Android's autofill at all (Android 8 and later).
  final bool supported;

  /// Ringer Vault is the autofill service Android uses.
  final bool ours;

  /// Chrome is installed, so its own setting matters too.
  final bool chrome;

  /// The phone has Credential Manager providers (Android 14 and later).
  final bool credentialSupported;

  /// Ringer Vault is turned on as one (docs/CREDENTIAL_PROVIDER.md).
  final bool credentialOurs;

  const AutofillSetupStatus({
    required this.supported,
    required this.ours,
    required this.chrome,
    this.credentialSupported = false,
    this.credentialOurs = false,
  });

  static const unknown = AutofillSetupStatus(supported: false, ours: false, chrome: false);
}

/// Opens the two settings screens that decide whether Ringer Vault fills:
/// Android's choice of autofill service, and Chrome's "Autofill using
/// another service" (AutofillSetup.kt). Neither can be changed from here;
/// the person chooses on those screens.
class AutofillSetup {
  static const _channel = MethodChannel('ringer_vault/autofill_setup');

  static Future<AutofillSetupStatus> status() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('status');
      if (raw == null) return AutofillSetupStatus.unknown;
      return AutofillSetupStatus(
        supported: raw['supported'] == true,
        ours: raw['ours'] == true,
        chrome: raw['chrome'] == true,
        credentialSupported: raw['credentialSupported'] == true,
        credentialOurs: raw['credentialOurs'] == true,
      );
    } on MissingPluginException {
      return AutofillSetupStatus.unknown;
    } on PlatformException {
      return AutofillSetupStatus.unknown;
    }
  }

  /// Android's autofill service picker. False when it could not be opened.
  static Future<bool> openAndroidSettings() => _open('openAndroid');

  /// Chrome's autofill settings. False when Chrome is missing or too old to
  /// have the option (it arrived in Chrome 135).
  static Future<bool> openChromeSettings() => _open('openChrome');

  /// Android's "Passwords, passkeys and accounts" screen (Android 14 and
  /// later), where Ringer Vault is turned on for the sign-in sheet.
  static Future<bool> openCredentialProviderSettings() => _open('openCredentialProvider');

  static Future<bool> _open(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
