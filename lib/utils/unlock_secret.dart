import 'package:ringer_vault/utils/passphrase_strength.dart';
/// What the user types to open the vault.
///
/// The vault key is derived from this value, so its length is the ceiling on
/// how hard the vault is to break. Argon2id makes each guess expensive, but no
/// KDF can add possibilities that are not there: a 6-digit PIN is 1,000,000
/// of them, while 12 mixed characters is past 10^23. Offering both is a choice
/// of lock, never two doors into the same vault: setting one retires the other.
enum UnlockSecretType {
  /// Six digits, entered on a keypad. Fast, and the weakest option offered.
  pin,

  /// Twelve characters or more, any characters, entered on the keyboard.
  /// Covers a passphrase of several words as well as a random password.
  password,
}

/// Digits in a PIN. Fixed: a variable-length PIN leaks its length through the
/// dot count without buying meaningful strength.
const int kPinLength = 6;

/// Shortest password accepted.
///
/// Twelve is where a password stops being guessable by anyone who has copied
/// the vault off the device, which is the only attack the app's own lockout
/// and self-destruct cannot reach.
const int kMinPasswordLength = 12;

/// Longest accepted. Well past any real passphrase, and short enough that the
/// key derivation cost stays predictable.
const int kMaxPasswordLength = 128;

extension UnlockSecretTypeInfo on UnlockSecretType {
  bool get isPin => this == UnlockSecretType.pin;

  /// Mid-sentence noun: "Enter your PIN", "Enter your password".
  String get noun => isPin ? 'PIN' : 'password';

  /// Sentence-initial noun: "PIN updated", "Password updated".
  String get nounCapitalized => isPin ? 'PIN' : 'Password';

  /// Plural, for counting failures: "wrong PINs", "wrong passwords".
  String get nounPlural => isPin ? 'PINs' : 'passwords';

  /// Name of the choice on the chooser screen.
  String get optionTitle => isPin ? '6-digit PIN' : 'Password or passphrase';

  /// What picking it means, in plain words.
  String get optionSummary => isPin
      ? 'Quick to enter on a keypad. The weaker of the two.'
      : 'At least $kMinPasswordLength characters. A few words work well.';

  /// The honest comparison, stated in full on the chooser.
  String get strengthNote => isPin
      ? 'A million possible PINs. Someone who copies your vault off the '
          'device can work through them.'
      : 'Roughly a trillion times harder to guess than a 6-digit PIN.'
          ' Out of reach even with the vault copied off the device.';

  int get minLength => isPin ? kPinLength : kMinPasswordLength;
  int get maxLength => isPin ? kPinLength : kMaxPasswordLength;

  /// Stored form. Kept stable: it is written to storage.
  String get storageValue => name;

  static UnlockSecretType fromStorage(String? raw) =>
      raw == UnlockSecretType.password.name
          ? UnlockSecretType.password
          : UnlockSecretType.pin;
}

/// The refusal for a secret that cannot be used for a reason not to be
/// spelled out (inside the decoy: that it is the other vault's).
String unusableSecretMessage(UnlockSecretType type) =>
    'That ${type.noun} cannot be used. Choose another.';

/// Checks a candidate secret before it is ever sealed.
///
/// Returns null when the value is acceptable, otherwise the reason, phrased
/// for the person typing. Rejecting here matters more than it looks: the
/// secret becomes the key, so a value accepted once is a weakness that
/// persists until the user changes it, and a mistyped one cannot be recovered.
String? validateUnlockSecret(String value, UnlockSecretType type) {
  if (type.isPin) {
    if (value.length != kPinLength) {
      return 'Enter all $kPinLength digits.';
    }
    if (!RegExp(r'^\d+$').hasMatch(value)) {
      return 'A PIN is digits only.';
    }
    if (_isSingleRepeatedCharacter(value)) {
      return 'Repeating the same digit is the first thing anyone tries.';
    }
    if (_isStraightRun(value)) {
      return 'Digits in order are the first thing anyone tries.';
    }
    return null;
  }

  if (value.length < kMinPasswordLength) {
    final short = kMinPasswordLength - value.length;
    return 'Add $short more ${short == 1 ? 'character' : 'characters'}. '
        'Minimum is $kMinPasswordLength.';
  }
  if (value.length > kMaxPasswordLength) {
    return 'Keep it under $kMaxPasswordLength characters.';
  }
  if (value.trim().length != value.length) {
    // Never silently trimmed: the untrimmed value is what gets sealed, so a
    // stray space from autocorrect would lock the vault forever.
    return 'Remove the space at the start or end.';
  }
  if (_distinctCharacters(value) < 5) {
    return 'Use more variety. A repeated pattern is as weak as a short one.';
  }
  return null;
}

bool _isSingleRepeatedCharacter(String value) =>
    value.split('').toSet().length == 1;

int _distinctCharacters(String value) => value.split('').toSet().length;

/// True for 123456 and 654321, and any other unbroken run.
bool _isStraightRun(String value) {
  if (value.length < 2) return false;
  final step = value.codeUnitAt(1) - value.codeUnitAt(0);
  if (step != 1 && step != -1) return false;

  for (var i = 2; i < value.length; i++) {
    if (value.codeUnitAt(i) - value.codeUnitAt(i - 1) != step) return false;
  }
  return true;
}

/// How strong a typed password looks, as four coarse steps.
///
/// Deliberately coarse, and deliberately not a number of bits. Bits computed
/// from length and character classes would call "Password1234" a 71-bit
/// secret, which is false: it falls to any wordlist attack in seconds. Nothing
/// in the app can detect that without a full cracking dictionary, so the meter
/// reports only what it can defend, and the caution line carries the rest.
enum SecretStrength { tooShort, weak, fair, strong, veryStrong }

extension SecretStrengthInfo on SecretStrength {
  String get label => switch (this) {
        SecretStrength.tooShort => 'Too short',
        SecretStrength.weak => 'Easy to guess',
        SecretStrength.fair => 'Fair',
        SecretStrength.strong => 'Strong',
        SecretStrength.veryStrong => 'Very strong',
      };

  /// How much of the meter to fill, 0 to 1.
  double get fill => switch (this) {
        SecretStrength.tooShort => 0.15,
        SecretStrength.weak => 0.3,
        SecretStrength.fair => 0.5,
        SecretStrength.strong => 0.75,
        SecretStrength.veryStrong => 1.0,
      };
}

/// The rating shown while a password is chosen, from the same guess-based
/// estimate as the sync passphrase (passphrase_strength.dart): common
/// words, names, years, keyboard runs and look-alike swaps count for little,
/// so "Password@12345" is easy to guess however many character kinds it has.
SecretStrength estimateSecretStrength(String value) {
  if (value.length < kMinPasswordLength) return SecretStrength.tooShort;
  final bits = estimateBits(value);
  if (bits < minSyncPassphraseBits) return SecretStrength.weak;
  if (bits < 65) return SecretStrength.fair;
  if (bits < 80) return SecretStrength.strong;
  return SecretStrength.veryStrong;
}

