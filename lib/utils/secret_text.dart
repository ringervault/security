import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Passphrases and passwords in one Unicode form.
///
/// "é" can be typed as one character or as "e" plus an accent, and
/// keyboards differ in which they send, so the same passphrase typed on two
/// devices could make two different keys. New keys are made from the
/// composed form (NFC). Opening tries that form first and then the text
/// exactly as typed, so anything sealed before this, or by a device that
/// does not normalise, still opens. Plain ASCII, which every PIN and most
/// passphrases are, is the same in every form and is left as it is.
///
/// Dart has no normaliser of its own, so Android's (java.text.Normalizer)
/// is asked through the session channel; without it the text is used as
/// typed.
class SecretText {
  static const _channel = MethodChannel('ringer_vault/session');

  /// For tests: the normaliser to use instead of Android's.
  @visibleForTesting
  static String Function(String)? debugNfc;

  static bool _isAscii(String s) => s.codeUnits.every((c) => c < 0x80);

  /// [secret] in NFC.
  static Future<String> nfc(String secret) async {
    if (_isAscii(secret)) return secret;
    final forced = debugNfc;
    if (forced != null) return forced(secret);
    try {
      return await _channel.invokeMethod<String>('nfc', secret) ?? secret;
    } catch (_) {
      return secret;
    }
  }

  /// The forms to try when opening something sealed with [secret]: NFC
  /// first, then as typed when that differs.
  static Future<List<String>> forms(String secret) async {
    final composed = await nfc(secret);
    return composed == secret ? [secret] : [composed, secret];
  }
}
