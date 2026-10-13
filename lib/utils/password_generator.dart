import 'dart:math';

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
  static const String _symbols = '!@#\$%^&*-_=+?';

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
  static String generate({
    int length = defaultLength,
    bool lowercase = true,
    bool uppercase = true,
    bool digits = true,
    bool symbols = true,
  }) {
    final pools = <String>[
      if (lowercase) _lower,
      if (uppercase) _upper,
      if (digits) _digits,
      if (symbols) _symbols,
    ];

    // Defence in depth. The UI refuses to let the last set be turned off, so
    // reaching this means a programmatic caller passed an impossible request;
    // silently downgrading to lowercase-only would hand back a far weaker
    // password than asked for, so this is the safest set instead.
    if (pools.isEmpty) {
      pools.addAll([_lower, _upper, _digits, _symbols]);
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

  /// Words for passphrase mode.
  ///
  /// Short, unambiguous, and easy to read back off a screen. Kept deliberately
  /// small and offline: a real diceware list would be a bundled asset, and
  /// this app ships no assets.
  static const List<String> _words = [
    'anchor', 'amber', 'apple', 'arrow', 'atlas', 'basin', 'beacon', 'birch',
    'bison', 'blaze', 'bloom', 'bridge', 'cabin', 'canyon', 'cedar', 'cinder',
    'cobalt', 'comet', 'coral', 'cortex', 'crane', 'crest', 'delta', 'dune',
    'ember', 'falcon', 'fern', 'flint', 'forge', 'fossil', 'garnet', 'glacier',
    'granite', 'harbor', 'hazel', 'heron', 'indigo', 'ivory', 'jasper',
    'jungle', 'kernel', 'lantern', 'ledger', 'lichen', 'lunar', 'maple',
    'marble', 'meadow', 'mesa', 'meteor', 'monsoon', 'nectar', 'nimbus',
    'oasis', 'onyx', 'opal', 'orchid', 'otter', 'pepper', 'pewter', 'pilot',
    'pine', 'plateau', 'prism', 'quartz', 'quiver', 'raven', 'reef', 'ridge',
    'river', 'rowan', 'saffron', 'sage', 'sable', 'shale', 'silo', 'slate',
    'solar', 'spruce', 'summit', 'tangent', 'thicket', 'thorn', 'tidal',
    'timber', 'topaz', 'tundra', 'umber', 'valley', 'velvet', 'vertex',
    'walnut', 'willow', 'winter', 'zenith', 'zephyr',
  ];

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
  }) {
    var poolSize = 0;
    if (lowercase) poolSize += _lower.length;
    if (uppercase) poolSize += _upper.length;
    if (digits) poolSize += _digits.length;
    if (symbols) poolSize += _symbols.length;
    if (poolSize == 0) poolSize = _lower.length;

    return length * (log(poolSize) / log(2));
  }
}
