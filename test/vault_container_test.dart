import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/services/vault_container.dart';

/// The single file both vaults live in.
void main() {
  final realKeys = SlotKeys(List.filled(32, 1));
  final decoyKeys = SlotKeys(List.filled(32, 2));
  Map<String, dynamic> vault(int entries) => {
        'v': 1,
        'count': 1,
        'entries': [
          for (var i = 0; i < entries; i++)
            {'id': 'e$i', 'title': 'Entry $i', 'password': 'p' * 20, 'notes': 'x' * 200},
        ],
      };

  Future<Uint8List> file(Map<String, dynamic> v, SlotKeys k, int slot, [Uint8List? existing]) async =>
      assemble(existing: existing, own: await sealSlot(v, k, slot), slot: slot);

  test('each vault opens only its own slot', () async {
    var f = await file(vault(3), realKeys, realSlot);
    f = await file(vault(5), decoyKeys, decoySlot, f);
    final (a, b) = splitContainer(f);
    expect((await openSlot(a, realKeys, realSlot))!['entries'], hasLength(3));
    expect((await openSlot(b, decoyKeys, decoySlot))!['entries'], hasLength(5));
    expect(await openSlot(b, realKeys, decoySlot), isNull);
    expect(await openSlot(a, decoyKeys, realSlot), isNull);
  });

  test('the slots cannot be swapped', () async {
    final f = await file(vault(1), realKeys, realSlot);
    final (a, _) = splitContainer(f);
    expect(await openSlot(a, realKeys, decoySlot), isNull);
  });

  test('the size says nothing about entries or a decoy', () async {
    final none = await file(vault(0), realKeys, realSlot);
    final some = await file(vault(40), realKeys, realSlot);
    final withDecoy = await file(vault(40), decoyKeys, decoySlot, some);
    expect(none.length, some.length, reason: 'both fit the smallest bucket');
    expect(withDecoy.length, some.length, reason: 'a decoy adds nothing');
  });

  test('a vault outgrowing its bucket grows both slots, keeping the other', () async {
    var f = await file(vault(2), decoyKeys, decoySlot);
    final small = f.length;
    f = await file(vault(400), realKeys, realSlot, f);
    expect(f.length, greaterThan(small));
    final (a, b) = splitContainer(f);
    expect(a.length, b.length);
    expect((await openSlot(b, decoyKeys, decoySlot))!['entries'], hasLength(2),
        reason: 'carried over byte for byte, then padded');
    expect((await openSlot(a, realKeys, realSlot))!['entries'], hasLength(400));
  });

  test('any changed byte in a slot is caught', () async {
    final f = await file(vault(3), realKeys, realSlot);
    for (final at in [headerBytes + 0, headerBytes + 20, headerBytes + 1000]) {
      final copy = Uint8List.fromList(f);
      copy[at] ^= 1;
      final (a, _) = splitContainer(copy);
      expect(await openSlot(a, realKeys, realSlot), isNull, reason: 'byte $at');
    }
  });

  test('anything that is not a container is refused', () {
    expect(() => splitContainer(Uint8List(10)), throwsA(isA<ContainerError>()));
    final junk = Uint8List(headerBytes + 2 * minSlotBytes);
    expect(() => splitContainer(junk), throwsA(isA<ContainerError>()));
  });

  test('write counts: a slot\'s own, or nothing', () async {
    final sealed = await sealCount(41, realKeys, realSlot);
    expect(await openCount(sealed, realKeys, realSlot), 41);
    expect(await openCount(sealed, decoyKeys, realSlot), isNull);
    expect(await openCount(sealed, realKeys, decoySlot), isNull);
    expect(await openCount(unusedCount(), realKeys, realSlot), isNull);
    expect(base64Decode(unusedCount()).length, base64Decode(sealed).length,
        reason: 'a stand-in looks like a real one');
  });

  test('buckets double to 1 MiB, then grow by 1 MiB', () {
    expect(slotSizeFor(0), 64 * 1024);
    expect(slotSizeFor(64 * 1024), 128 * 1024);
    expect(slotSizeFor(1024 * 1024), 2 * 1024 * 1024);
    expect(slotSizeFor(3 * 1024 * 1024 + 1), 4 * 1024 * 1024);
  });
}
