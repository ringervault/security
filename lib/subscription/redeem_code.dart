import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Ringer Vault's own redeem codes: Premium given away, never sold (anything
/// paid goes through Google Play), for a day, a week, a month, a year or for
/// good; or a cancel code, which stops Premium from codes there and then.
///
/// A code is made on the developer's computer by tool/codes/make_codes.mjs
/// and signed with a private key only that computer holds. The app and the
/// extension (extension/src/vault/codes.js) check the signature offline with
/// [codePublicKey], so there is no server to ask. With no server, a code can
/// only be kept to one use per phone, and per vault once it is synced
/// (FORMATS.md, section 10). A code is signed, not secret: anyone can read
/// what it says, but only the holder of the private key can make one, or
/// change what one says.
///
///     "RV-" + base64url(version(1) = 1 || id(8) || kind(1) || amount(2)
///             || last day to redeem(2, days since 2020-01-01 UTC)
///             || Ed25519 signature over "ringer-vault-code" || the 14 bytes before)
///
/// kind: 1 days, 2 calendar months, 3 lifetime, 4 cancel (amount 0 for the
/// last two).
enum CodeKind { days, months, lifetime, cancel }

class RedeemCode {
  /// The public half of the signing key (raw Ed25519, base64). Public by
  /// design: it can check a code, never make one. Made 30 October 2026.
  static const String codePublicKey = 'qo65LFf0NHaNuPDZi36fsk/8GMuNMykinexT6Sf32+Y=';

  static const String prefix = 'RV-';
  static final List<int> _context = utf8.encode('ringer-vault-code');
  static final DateTime _epoch = DateTime.utc(2020);

  /// When a lifetime runs out: never, in practice.
  static final DateTime lifetimeUntil = DateTime.utc(9999);

  /// The code's own number, as hex: one use each.
  final String id;

  final CodeKind kind;

  /// How many days or calendar months it gives; 0 for a lifetime or cancel.
  final int amount;

  /// The end of the last day it can be redeemed on (UTC).
  final DateTime redeemBy;

  /// The code as given, without spaces.
  final String text;

  final List<int> _body;
  final List<int> _signature;

  RedeemCode._(this.id, this.kind, this.amount, this.redeemBy, this.text, this._body, this._signature);

  /// Whether [text] is meant as one of these, rather than a Google Play code.
  static bool looksLikeOne(String text) => text.trim().startsWith(prefix);

  /// The code in [text], or null for anything not shaped like one. Spaces and
  /// line breaks, as a pasted code may carry, are ignored. Says nothing about
  /// whether it is genuine: see [isGenuine].
  static RedeemCode? parse(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (!compact.startsWith(prefix)) return null;
    final encoded = compact.substring(prefix.length);
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) return null;
    final List<int> bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(encoded));
    } on FormatException {
      return null;
    }
    if (bytes.length != 78 || bytes[0] != 1) return null;
    if (bytes[9] < 1 || bytes[9] > CodeKind.values.length) return null;
    final kind = CodeKind.values[bytes[9] - 1];
    final amount = (bytes[10] << 8) | bytes[11];
    final timed = kind == CodeKind.days || kind == CodeKind.months;
    if (timed ? amount == 0 : amount != 0) return null;
    final lastDay = (bytes[12] << 8) | bytes[13];
    return RedeemCode._(
      [for (final b in bytes.sublist(1, 9)) b.toRadixString(16).padLeft(2, '0')].join(),
      kind,
      amount,
      _epoch.add(Duration(days: lastDay + 1)),
      compact,
      bytes.sublist(0, 14),
      bytes.sublist(14),
    );
  }

  /// Whether it was signed with [publicKey].
  Future<bool> isGenuine({String publicKey = codePublicKey}) async {
    try {
      return await Ed25519().verify(
        [..._context, ..._body],
        signature: Signature(
          _signature,
          publicKey: SimplePublicKey(base64.decode(publicKey), type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Whether it can still be redeemed at [at].
  bool redeemableAt(DateTime at) => at.isBefore(redeemBy);

  /// What it gives, in a few words: "7 days", "1 month", "Lifetime".
  String get describe => switch (kind) {
        CodeKind.days => amount == 1
            ? '1 day'
            : amount == 7
                ? '1 week'
                : '$amount days',
        CodeKind.months => amount == 12
            ? '1 year'
            : amount % 12 == 0
                ? '${amount ~/ 12} years'
                : amount == 1
                    ? '1 month'
                    : '$amount months',
        CodeKind.lifetime => 'Lifetime',
        CodeKind.cancel => 'Cancel',
      };
}

/// One redeemed code: the code, and when this phone (or another device of
/// the same vault) redeemed it. Kept on the phone, and in the sync file once
/// sync is on, so the extension counts it too.
class CodeGrant {
  final String code;
  final DateTime redeemedAt;

  const CodeGrant({required this.code, required this.redeemedAt});

  Map<String, Object?> toJson() => {
        'code': code,
        'redeemedAt': redeemedAt.toUtc().toIso8601String(),
      };

  /// Null for anything that is not one: a damaged record counts as none.
  static CodeGrant? fromJson(Object? raw) {
    if (raw is! Map || raw['code'] is! String || raw['redeemedAt'] is! String) return null;
    final at = DateTime.tryParse(raw['redeemedAt'] as String);
    return at == null ? null : CodeGrant(code: raw['code'] as String, redeemedAt: at.toUtc());
  }

  /// The code's id, or null when it is not shaped like a code.
  String? get id => RedeemCode.parse(code)?.id;
}

/// The grants that count, each code once and from its first use: genuine,
/// and redeemed by its last day. Checked before anything else, so nothing
/// forged can stand in for a genuine code, or push one out.
Future<List<(RedeemCode, DateTime)>> countedGrants(
  Iterable<CodeGrant> grants, {
  String publicKey = RedeemCode.codePublicKey,
}) async {
  final first = <String, (RedeemCode, DateTime)>{};
  for (final grant in grants) {
    final code = RedeemCode.parse(grant.code);
    if (code == null || !code.redeemableAt(grant.redeemedAt)) continue;
    final earlier = first[code.id];
    if (earlier != null && !grant.redeemedAt.isBefore(earlier.$2)) continue;
    if (!await code.isGenuine(publicKey: publicKey)) continue;
    first[code.id] = (code, grant.redeemedAt);
  }
  return first.values.toList();
}

/// When Premium from [counted] runs out, or null when none counts. In the
/// order they were redeemed: a timed code starts when redeemed, or when the
/// one before runs out if that is later; a lifetime runs until
/// [RedeemCode.lifetimeUntil]; a cancel ends whatever is running at that
/// moment. The same rules as extension/src/vault/codes.js.
DateTime? grantsUntil(List<(RedeemCode, DateTime)> counted) {
  final ordered = [...counted]..sort((a, b) => a.$2.compareTo(b.$2));
  DateTime? until;
  for (final (code, redeemedAt) in ordered) {
    final running = until != null && until.isAfter(redeemedAt);
    switch (code.kind) {
      case CodeKind.cancel:
        if (running) until = redeemedAt;
      case CodeKind.lifetime:
        until = RedeemCode.lifetimeUntil;
      case CodeKind.days || CodeKind.months:
        if (running && until == RedeemCode.lifetimeUntil) continue;
        final start = running ? until : redeemedAt;
        until = code.kind == CodeKind.days
            ? start.add(Duration(days: code.amount))
            // Calendar months, overflowing as JavaScript's Date does: a
            // month from 31 January is 3 March in a short year.
            : DateTime.utc(start.year, start.month + code.amount, start.day, start.hour,
                start.minute, start.second, start.millisecond);
    }
  }
  return until;
}

/// The plan the latest code that gives Premium in [counted] was for ("1
/// week", "Lifetime"), or null when there is none.
String? latestPlan(List<(RedeemCode, DateTime)> counted) {
  final giving = [
    for (final c in counted)
      if (c.$1.kind != CodeKind.cancel) c,
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return giving.isEmpty ? null : giving.last.$1.describe;
}

/// [a] and [b] together, each code once, at its first use. For the sync
/// file, which gathers every device's. Anything not shaped like a code is
/// left out: it could never count.
List<CodeGrant> unionOfGrants(Iterable<CodeGrant> a, Iterable<CodeGrant> b) {
  final byId = <String, CodeGrant>{};
  for (final grant in [...a, ...b]) {
    final id = grant.id;
    if (id == null) continue;
    final known = byId[id];
    if (known == null || grant.redeemedAt.isBefore(known.redeemedAt)) byId[id] = grant;
  }
  return [...byId.values]..sort((x, y) => x.redeemedAt.compareTo(y.redeemedAt));
}
