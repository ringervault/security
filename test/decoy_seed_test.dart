import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/repository/decoy_seed.dart';

/// A decoy that is not believed is worse than no decoy: it tells whoever is
/// holding the phone that there is a real vault worth asking for. The
/// generator is public, so beyond looking real, no decoy may share a fixed
/// pattern with the others that it could be recognised by.
void main() {
  const identity = DecoyIdentity(
    name: 'John Doe',
    email: 'john.doe84@gmail.com',
  );

  final many = [for (var seed = 0; seed < 60; seed++) buildDecoyEntries(identity, Random(seed))];

  test('always a mailbox for the address, and a bank', () {
    for (final entries in many) {
      final mailbox = entries.firstWhere((e) => e.title == 'Gmail');
      expect(mailbox.email, 'john.doe84@gmail.com');
      expect(entries.where((e) => e.category == 'Banking' && e.pin.isNotEmpty || e.title.contains('Bank') || e.title == 'SBI'), isNotEmpty);
    }
  });

  test('no entry or credential is named like a placeholder', () {
    for (final entries in many) {
      for (final entry in entries) {
        expect(RegExp(r'Account \d+$').hasMatch(entry.title), isFalse, reason: entry.title);
        expect(RegExp(r'^user\d+$').hasMatch(entry.username), isFalse, reason: entry.username);
        expect(RegExp(r'^password\d*$', caseSensitive: false).hasMatch(entry.password), isFalse,
            reason: entry.password);
      }
    }
  });

  test('a plausible amount of history, not all created in the same minute', () {
    for (final entries in many) {
      expect(entries.length, inInclusiveRange(12, 20));
      expect(entries.map((e) => e.createdAt.day).toSet().length, greaterThan(3));
      expect(entries.every((e) => !e.updatedAt.isBefore(e.createdAt)), isTrue);
    }
  });

  test('a bank entry has a login and only the secrets banks have', () {
    const labels = {'Login password', 'Transaction password', 'ATM PIN', 'TPIN'};
    for (final entries in many) {
      for (final bank in entries.where((e) => e.title.contains('Bank') || e.title.startsWith('SBI'))) {
        expect(bank.password, isNotEmpty);
        for (final s in bank.secrets) {
          if (s.label.isNotEmpty && s.label != 'Password') expect(labels, contains(s.label));
        }
      }
    }
  });

  test('passwords look human: reused with changes, some strong, not one copied everywhere', () {
    for (final entries in many) {
      final passwords = entries.map((e) => e.password).where((p) => p.isNotEmpty).toList();
      expect(passwords.toSet().length, greaterThanOrEqualTo(passwords.length ~/ 2));
    }
    final strongSomewhere = many.where((entries) => entries.any((e) => e.password.length >= 14)).length;
    expect(strongSomewhere, greaterThan(many.length ~/ 3));
  });

  test('order is not grouped by category', () {
    for (final entries in many.take(20)) {
      final categories = entries.map((e) => e.category).toList();
      var runs = 1;
      for (var i = 1; i < categories.length; i++) {
        if (categories[i] != categories[i - 1]) runs++;
      }
      expect(runs, greaterThan(categories.length ~/ 3));
    }
  });

  test('no service but the mailbox is in most decoys', () {
    final counts = <String, int>{};
    for (final entries in many) {
      for (final title in entries.map((e) => e.title).toSet()) {
        counts[title] = (counts[title] ?? 0) + 1;
      }
    }
    counts.remove('Gmail');
    for (final MapEntry(key: title, value: n) in counts.entries) {
      expect(n / many.length, lessThan(0.6), reason: '$title is in $n of ${many.length}');
    }
    expect(counts.length, greaterThan(40), reason: 'drawn from a wide catalogue');
  });

  test('no password shape is in every decoy', () {
    // The old generator always had "<name>@<year>", "netflix<year>" and
    // "airtel@NNNN". Nothing like that may hold across decoys now.
    bool always(RegExp shape) =>
        many.every((entries) => entries.any((e) => shape.hasMatch(e.password)));
    expect(always(RegExp(r'^John@\d{4}$')), isFalse);
    expect(always(RegExp(r'^netflix\d{4}$')), isFalse);
    expect(always(RegExp(r'^airtel@\d{4}$')), isFalse);
    expect(always(RegExp(r'John', caseSensitive: false)), isFalse);
  });

  test('two decoys for the same person differ', () {
    final a = buildDecoyEntries(identity, Random(100)).map((e) => e.password).toSet();
    final b = buildDecoyEntries(identity, Random(101)).map((e) => e.password).toSet();
    expect(a.intersection(b), isEmpty);
  });

  test('invents a believable person when none was given', () {
    for (var seed = 0; seed < 20; seed++) {
      final entries = buildDecoyEntries(DecoyIdentity.fallback, Random(seed));
      final mailbox = entries.firstWhere((e) => e.category == 'Email');
      expect(mailbox.email, isNot('me@gmail.com'));
      expect(mailbox.email, contains('@'));
      expect(mailbox.email.split('@').first.length, greaterThan(4));
    }
  });
}
