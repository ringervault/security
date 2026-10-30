import 'dart:math';

import 'package:ringer_vault/utils/eff_words.g.dart';

/// Generates strong passwords.
///
/// The vault scored password strength but had no way to produce a strong one,
/// which is the feature people reach for most in a password manager, and the
/// reason weak passwords get typed in by hand.
class PasswordGenerator {
  PasswordGenerator._();

  static const String _lower = 'abcdefghijkmnopqrstuvwxyz';
  static const String _upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  static const String _digits = '23456789';

  /// The special characters used unless the user narrows them: some sites
  /// refuse a few, so the generator takes the ones a site allows instead.
  static const String defaultSymbols = '!@#\$%^&*-_=+?';

  // Note the omissions above: l, I, 1, O, 0. Ambiguous glyphs are the usual
  // cause of a password that "doesn't work" when read off a screen and typed
  // somewhere else.

  static const int minLength = 8;
  static const int maxLength = 64;
  static const int defaultLength = 20;

  /// Builds a password from the selected character sets.
  ///
  /// Uses [Random.secure]: the generator seeds real credentials, so a
  /// predictable PRNG would undermine every password it produces.
  ///
  /// [allowedSymbols] are the special characters to use, cleaned by
  /// [cleanSymbols]; none left means no special characters at all.
  static String generate({
    int length = defaultLength,
    bool lowercase = true,
    bool uppercase = true,
    bool digits = true,
    bool symbols = true,
    String allowedSymbols = defaultSymbols,
  }) {
    final special = cleanSymbols(allowedSymbols);
    final pools = <String>[
      if (lowercase) _lower,
      if (uppercase) _upper,
      if (digits) _digits,
      if (symbols && special.isNotEmpty) special,
    ];

    // Defence in depth. The UI refuses to let the last set be turned off, so
    // reaching this means nothing usable was asked for. Lowercase only would
    // be far weaker than asked, and special characters may be what the user
    // ruled out, so letters and numbers instead.
    if (pools.isEmpty) {
      pools.addAll([_lower, _upper, _digits]);
    }

    final clamped = length.clamp(minLength, maxLength);
    final random = Random.secure();

    // One character from each pool first, so a "symbols" toggle actually
    // guarantees a symbol rather than merely making one possible.
    final chars = <String>[
      for (final pool in pools) pool[random.nextInt(pool.length)],
    ];

    final all = pools.join();
    while (chars.length < clamped) {
      chars.add(all[random.nextInt(all.length)]);
    }

    // Shuffle, or the guaranteed characters would always sit in pool order at
    // the front.
    for (var i = chars.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final tmp = chars[i];
      chars[i] = chars[j];
      chars[j] = tmp;
    }

    return chars.join();
  }

  /// The special characters in [raw] a password can use: printable ASCII
  /// that is neither a letter, a digit nor a space, each once, in the order
  /// typed. Spaces, letters and digits are dropped rather than refused, so
  /// a site's list can be pasted with its spaces ("! @ # \$").
  static String cleanSymbols(String raw) {
    final seen = <int>{};
    final out = StringBuffer();
    for (final c in raw.codeUnits) {
      final printable = c >= 0x21 && c <= 0x7e;
      final letterOrDigit = (c >= 0x30 && c <= 0x39) ||
          (c >= 0x41 && c <= 0x5a) ||
          (c >= 0x61 && c <= 0x7a);
      if (printable && !letterOrDigit && seen.add(c)) out.writeCharCode(c);
    }
    return out.toString();
  }

  /// Words for passphrase mode: the EFF Large Wordlist (7,776 words, about
  /// 12.9 bits each, chosen to be easy to read and remember). Five of them
  /// and a number come to about 71 bits.
  static const List<String> _words = effWords;

  static const int minWords = 3;
  static const int maxWords = 10;
  static const int defaultWords = 5;

  /// Builds a passphrase: several random words joined by [separator].
  ///
  /// Easier to type and to remember than a random string of the same
  /// strength, which matters for the handful of passwords a person actually
  /// has to reproduce by hand.
  static String generatePassphrase({
    int words = defaultWords,
    String separator = '-',
    bool capitalize = false,
    bool appendNumber = true,
  }) {
    final random = Random.secure();
    final count = words.clamp(minWords, maxWords);

    final picked = List<String>.generate(count, (_) {
      final word = _words[random.nextInt(_words.length)];
      return capitalize
          ? word[0].toUpperCase() + word.substring(1)
          : word;
    });

    if (appendNumber) picked.add('${random.nextInt(90) + 10}');

    return picked.join(separator);
  }

  /// Entropy of a passphrase, counting only the word choices plus the digits.
  static double passphraseEntropyBits({
    required int words,
    bool appendNumber = true,
  }) {
    final bits = words * (log(_words.length) / log(2));
    return bits + (appendNumber ? (log(90) / log(2)) : 0);
  }

  /// Rough entropy in bits, for showing how strong the result actually is.
  static double entropyBits({
    required int length,
    bool lowercase = true,
    bool uppercase = true,
    bool digits = true,
    bool symbols = true,
    String allowedSymbols = defaultSymbols,
  }) {
    var poolSize = 0;
    if (lowercase) poolSize += _lower.length;
    if (uppercase) poolSize += _upper.length;
    if (digits) poolSize += _digits.length;
    if (symbols) poolSize += cleanSymbols(allowedSymbols).length;
    if (poolSize == 0) poolSize = _lower.length;

    return length * (log(poolSize) / log(2));
  }
}
