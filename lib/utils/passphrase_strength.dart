import 'dart:math';

import 'package:ringer_vault/utils/common_words.g.dart';
import 'package:ringer_vault/utils/eff_words.g.dart';
import 'package:ringer_vault/utils/unlock_secret.dart';

/// How many guesses a passphrase would take, in bits, counted the way an
/// attacker guesses rather than by length and character classes.
///
/// The sync passphrase is the one secret here that can be attacked without
/// the phone: the file sits in Google Drive, and a copy of it can be guessed
/// at offline, as fast as the attacker's hardware allows. So a passphrase is
/// split into the pieces people build them from, and each piece costs only
/// what it is worth to someone guessing: a common word or password (from
/// tool/common_words.txt, after undoing look-alikes such as 0 for o and @
/// for a) costs about log2 of its rank; a keyboard run, a sequence, a repeat
/// or a year costs a few bits; anything left over costs per character.
/// "Password@12345" comes to about 13 bits, not the 85 its length suggests.
///
/// A word from the passphrase word list (the EFF list the generator draws
/// from) costs log2 of the list's size, about 12.9 bits, whatever its length.
///
/// Still an estimate, and generous where it cannot see a pattern: it only
/// knows the words in its lists. extension/src/vault/passphrase.js is the same,
/// and test/fixtures/passphrase_cases.json holds cases both must agree on.
double estimateBits(String value) {
  final lower = value.toLowerCase();
  final norm = lower.split('').map((c) => _lookAlikes[c] ?? c).join();
  var bits = 0.0;
  var i = 0;
  while (i < value.length) {
    final (length, cost) = _bestPiece(value, lower, norm, i);
    bits += cost;
    i += length;
  }
  return bits;
}

/// Below this a sync passphrase is refused.
const double minSyncPassphraseBits = 50;

/// What is wrong with [value] as a sync passphrase, or null.
String? syncPassphraseProblem(String value) {
  final basic = validateUnlockSecret(value, UnlockSecretType.password);
  if (basic != null) return basic;
  final bits = estimateBits(value);
  if (bits < minSyncPassphraseBits) {
    return 'Too easy to guess: about ${bits.round()} bits, and it needs '
        '${minSyncPassphraseBits.round()}. Common words, names, years and '
        'keyboard runs count for little. Try four or five unrelated words.';
  }
  return null;
}

/// The strength as typed, in words, for under the field.
String describeBits(double bits) {
  final label = bits < minSyncPassphraseBits
      ? 'Too easy to guess'
      : bits < 65
          ? 'Fair'
          : bits < 80
              ? 'Strong'
              : 'Very strong';
  return '$label · about ${bits.round()} bits';
}

const Map<String, String> _lookAlikes = {
  '0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't', '8': 'b',
  '@': 'a', r'$': 's', '!': 'i', '+': 't',
};

const List<String> _keyboardRows = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm', '1234567890'];

double _log2(num x) => log(x) / ln2;

final Set<String> _listWords = effWords.toSet();
final int _longestListWord = effWords.fold(0, (m, w) => max(m, w.length));
final double _listWordBits = _log2(effWords.length);

/// The piece starting at [i] that covers the most characters, and what it
/// costs: (length, bits).
(int, double) _bestPiece(String original, String lower, String norm, int i) {
  final options = <(int, double)>[];

  // A common word or password, the longest one that fits.
  for (var rank = 0; rank < commonWords.length; rank++) {
    final w = commonWords[rank];
    if (w.length < 3 || !norm.startsWith(w, i)) continue;
    final piece = original.substring(i, i + w.length);
    final cost = _log2(rank + 1) +
        1 +
        (piece != piece.toLowerCase() ? 1 : 0) +
        (lower.substring(i, i + w.length) != w ? 1 : 0);
    options.add((w.length, cost));
  }

  // A word from the passphrase word list (eff_words.g.dart): what it costs
  // someone guessing from that list, not what its letters would.
  for (var len = min(_longestListWord, lower.length - i); len >= 3; len--) {
    final w = lower.substring(i, i + len);
    if (!_listWords.contains(w)) continue;
    final piece = original.substring(i, i + len);
    options.add((len, _listWordBits + (piece != w ? 1 : 0)));
    break;
  }

  // A run of one character.
  var r = i + 1;
  while (r < lower.length && lower[r] == lower[i]) {
    r++;
  }
  if (r - i >= 3) options.add((r - i, _classBits(original[i]) + _log2(r - i)));

  // A sequence: abc, 987.
  if (i + 2 < lower.length) {
    final step = lower.codeUnitAt(i + 1) - lower.codeUnitAt(i);
    if (step == 1 || step == -1) {
      var s = i + 1;
      while (s + 1 < lower.length && lower.codeUnitAt(s + 1) - lower.codeUnitAt(s) == step) {
        s++;
      }
      if (s - i + 1 >= 3) options.add((s - i + 1, _classBits(original[i]) + _log2(s - i + 1)));
    }
  }

  // A run along the keyboard, either way.
  for (final row in _keyboardRows) {
    for (final line in [row, row.split('').reversed.join()]) {
      for (var len = min(line.length, lower.length - i); len >= 4; len--) {
        if (line.contains(lower.substring(i, i + len))) {
          options.add((len, 4 + _log2(len)));
          break;
        }
      }
    }
  }

  // A year.
  if (i + 4 <= lower.length) {
    final y = int.tryParse(lower.substring(i, i + 4));
    if (y != null && y >= 1900 && y <= 2039 && RegExp(r'^\d{4}$').hasMatch(lower.substring(i, i + 4))) {
      options.add((4, 7));
    }
  }

  // Otherwise, one character on its own.
  options.add((1, _classBits(original[i])));

  options.sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
  return options.first;
}

double _classBits(String c) {
  if (RegExp(r'[a-z]').hasMatch(c)) return 4;
  if (RegExp(r'[A-Z]').hasMatch(c)) return 4.7;
  if (RegExp(r'[0-9]').hasMatch(c)) return _log2(10);
  if (' -_.'.contains(c)) return 2;
  return 5;
}
