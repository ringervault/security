/// Punycode (RFC 3492): how a domain written in other alphabets travels as
/// plain letters, "xn--pple-43d" for "аpple" with a Cyrillic "а".
///
/// Browsers hand over a host in this form, so a name that looks exactly
/// like "apple" on screen arrives as "xn--pple-43d". The look-alike check
/// decodes it to compare what a person would actually see. Nothing here
/// decides what a site is; registrable_domain.dart still refuses hosts
/// outside plain letters.
///
/// extension/src/vault/punycode.js is the same for the browser extension.
library;

const int _base = 36;
const int _tMin = 1;
const int _tMax = 26;
const int _skew = 38;
const int _damp = 700;
const int _initialBias = 72;
const int _initialN = 128;
const int _maxCodePoint = 0x10FFFF;

/// [label] as a person sees it: "xn--pple-43d" becomes "аpple". Anything
/// not in that form, or not valid, comes back as it was.
String decodeLabel(String label) {
  if (!label.startsWith('xn--')) return label;
  return _decode(label.substring(4)) ?? label;
}

/// [urlOrHost] with any host written in other alphabets put into its
/// "xn--" form, as a browser would. Anything else comes back as it was.
String toAsciiHost(String urlOrHost) {
  if (urlOrHost.runes.every((r) => r < 0x80)) return urlOrHost;
  final scheme = urlOrHost.indexOf('://');
  final start = scheme == -1 ? 0 : scheme + 3;
  var end = urlOrHost.length;
  for (final stop in ['/', '?', '#', ':']) {
    final at = urlOrHost.indexOf(stop, start);
    if (at != -1 && at < end) end = at;
  }
  final host = urlOrHost
      .substring(start, end)
      .toLowerCase()
      .split('.')
      .map((label) => label.runes.every((r) => r < 0x80) ? label : 'xn--${_encode(label)}')
      .join('.');
  return urlOrHost.substring(0, start) + host + urlOrHost.substring(end);
}

String? _decode(String input) {
  final output = <int>[];
  var basic = input.lastIndexOf('-');
  if (basic < 0) basic = 0;
  for (var j = 0; j < basic; j++) {
    final c = input.codeUnitAt(j);
    if (c >= 0x80) return null;
    output.add(c);
  }
  var n = _initialN;
  var i = 0;
  var bias = _initialBias;
  var index = basic > 0 ? basic + 1 : 0;
  while (index < input.length) {
    final oldI = i;
    var w = 1;
    for (var k = _base;; k += _base) {
      if (index >= input.length) return null;
      final digit = _digitOf(input.codeUnitAt(index++));
      if (digit >= _base) return null;
      i += digit * w;
      if (i > _maxCodePoint * 64) return null;
      final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
      if (digit < t) break;
      w *= _base - t;
    }
    final out = output.length + 1;
    bias = _adapt(i - oldI, out, oldI == 0);
    n += i ~/ out;
    i %= out;
    if (n > _maxCodePoint) return null;
    output.insert(i, n);
    i++;
  }
  return String.fromCharCodes(output);
}

String _encode(String label) {
  final input = label.runes.toList();
  final output = StringBuffer();
  for (final c in input) {
    if (c < 0x80) output.writeCharCode(c);
  }
  final b = output.length;
  var h = b;
  if (b > 0) output.write('-');
  var n = _initialN;
  var delta = 0;
  var bias = _initialBias;
  while (h < input.length) {
    final m = input.where((c) => c >= n).reduce((x, y) => x < y ? x : y);
    delta += (m - n) * (h + 1);
    n = m;
    for (final c in input) {
      if (c < n) delta++;
      if (c != n) continue;
      var q = delta;
      for (var k = _base;; k += _base) {
        final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
        if (q < t) break;
        output.writeCharCode(_charOf(t + (q - t) % (_base - t)));
        q = (q - t) ~/ (_base - t);
      }
      output.writeCharCode(_charOf(q));
      bias = _adapt(delta, h + 1, h == b);
      delta = 0;
      h++;
    }
    delta++;
    n++;
  }
  return output.toString();
}

int _digitOf(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30 + 26;
  if (c >= 0x61 && c <= 0x7a) return c - 0x61;
  if (c >= 0x41 && c <= 0x5a) return c - 0x41;
  return _base;
}

int _charOf(int digit) => digit < 26 ? 0x61 + digit : 0x30 + digit - 26;

int _adapt(int delta, int points, bool first) {
  delta = first ? delta ~/ _damp : delta ~/ 2;
  delta += delta ~/ points;
  var k = 0;
  while (delta > ((_base - _tMin) * _tMax) ~/ 2) {
    delta ~/= _base - _tMin;
    k += _base;
  }
  return k + (_base - _tMin + 1) * delta ~/ (delta + _skew);
}
