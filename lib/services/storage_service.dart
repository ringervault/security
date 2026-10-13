import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/save_inbox.dart';
import 'package:ringer_vault/services/security_guard.dart';
import 'package:ringer_vault/services/vault_cipher.dart';
import 'package:ringer_vault/services/vault_container.dart';
import 'package:ringer_vault/services/vault_lock.dart';
import 'package:ringer_vault/utils/sealed_file.dart';

/// The open vault, held in memory and written whole to the container.
class _OpenVault {
  final int slot;
  final SlotKeys keys;
  final Map<String, VaultEntry> entries;

  /// When each deleted entry was deleted. Sync needs this: without it, an
  /// entry deleted on one device is indistinguishable from one the other
  /// device simply has and this one does not. Only the real vault records
  /// it, since only the real vault syncs.
  final Map<String, DateTime> deleted;

  /// This vault's activity log: see ActivityLogService.
  List<Map<String, dynamic>> log;

  /// How many times this vault has been written. Checked against the copy
  /// in secure storage on every open, which is what catches an older copy
  /// of the file being put back.
  int count;

  /// Facts about the vault kept inside it rather than anywhere readable
  /// without its key: for the real vault, whether a decoy exists.
  final Map<String, dynamic> meta;

  _OpenVault({
    required this.slot,
    required this.keys,
    required this.entries,
    required this.deleted,
    required this.log,
    required this.count,
    Map<String, dynamic>? meta,
  }) : meta = meta ?? {};

  Map<String, dynamic> toJson() => {
        'v': 1,
        'count': count,
        'entries': [for (final e in entries.values) e.toJson()],
        'deleted': {for (final d in deleted.entries) d.key: d.value.toUtc().toIso8601String()},
        'log': log,
        'meta': meta,
      };

  static _OpenVault fromJson(Map<String, dynamic> json, {required int slot, required SlotKeys keys}) {
    try {
      return _OpenVault(
        slot: slot,
        keys: keys,
        entries: {
          for (final raw in json['entries'] as List)
            if (VaultEntry.fromJson(Map<String, dynamic>.from(raw as Map)) case final e) e.id: e,
        },
        deleted: {
          for (final d in (json['deleted'] as Map? ?? const {}).entries)
            if (DateTime.tryParse('${d.value}') case final at?) '${d.key}': at.toUtc(),
        },
        log: [
          for (final l in json['log'] as List? ?? const [])
            Map<String, dynamic>.from(l as Map),
        ],
        count: json['count'] as int,
        meta: Map<String, dynamic>.from(json['meta'] as Map? ?? const {}),
      );
    } catch (_) {
      // It decrypted, so only this app could have written it: a bug, not an
      // attack, but it is still not opened as if it were whole.
      throw VaultTamperedError();
    }
  }
}

/// Where the vaults live on the phone: one file for both (see
/// vault_container.dart), opened one vault at a time.
class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  // The Hive files the vaults lived in before the container, read once each
  // and deleted: see [_readOldFiles]. A vault's own files can only be read
  // with its key, so each is moved the first time its vault is opened.

  /// AES-256 plus an HMAC on every value (VaultCipher).
  static const String oldRealVaultBoxName = 'vault2a';
  static const String oldDecoyVaultBoxName = 'vault2b';
  static const String oldRealTombstoneBoxName = 'vault2c';

  /// Before VaultCipher: HiveAesCipher (AES-256-CBC and a CRC only).
  static const String legacyRealVaultBoxName = 'vaultBox';
  static const String legacyDecoyVaultBoxName = 'vaultBox_decoy';
  static const String legacyTombstoneBoxName = 'vaultBox_deleted';

  /// Each vault's activity log, which now lives in its slot. The decoy's
  /// file, appearing beside the real one's, gave the decoy away.
  static const String oldRealLogBoxName = 'vault_log_box';
  static const String oldDecoyLogBoxName = 'vault_log_box_decoy';

  /// Each slot's write count, sealed (vault_container.dart). Both always
  /// exist, a random stand-in for a slot nothing has written, so which
  /// keys are present says nothing about whether there is a decoy.
  static const List<String> _countKeys = ['vc_count_a', 'vc_count_b'];

  static const _secure = FlutterSecureStorage();

  _OpenVault? _open;
  String? _dir;

  /// Writes go one after another, each with the vault as it stood when it
  /// was asked for.
  Future<void> _writing = Future.value();

  /// Writes asked for and not yet finished. Closing waits for them, and only
  /// when there are any.
  int _pendingWrites = 0;

  /// Bumped on every change, for screens that redraw with the vault.
  final ValueNotifier<int> _changes = ValueNotifier(0);

  /// The master key of the currently open vault, held only for the lifetime of
  /// the session. Needed to re-wrap on a PIN change and to enrol biometrics,
  /// both of which must be possible only from inside an unlocked vault.
  Uint8List? _activeMasterKey;

  Uint8List? get activeMasterKey => _activeMasterKey;

  /// Whether a vault is open and usable. Callers that can't meaningfully
  /// recover should check this before navigating into the vault UI.
  bool get isReady => _open != null;

  _OpenVault get _require {
    final open = _open;
    if (open == null) throw StateError('Vault storage is not open.');
    return open;
  }

  bool _isDecoyMode = false;
  bool get isDecoyMode => _isDecoyMode;

  /// The open vault's slot in the container, or null with none open.
  int? get openSlot => _open?.slot;

  /// The folder the vault lives in, once [init] has run.
  String? get directoryPath => _dir;

  bool _isInitialized = false;

  /// Whether storage itself came up. Distinct from [isReady], which
  /// additionally requires an unlocked vault: at splash time none is open.
  bool get isInitialized => _isInitialized;

  File get _file => File('$_dir/$containerFileName');

  /// The next version, written and flushed in full before anything else
  /// changes. A crash before the rename leaves the current file as it was.
  File get _newFile => File('$_dir/$containerFileName.new');

  /// The version before the current one, kept whole in the same format: if
  /// this vault's part of the current file is ever unreadable, its last good
  /// state is one write back, not gone.
  File get _prevFile => File('$_dir/$containerFileName.prev');

  /// Called at each step of a write, so tests can stop one there as a
  /// crash or a killed process would. Never set outside tests.
  @visibleForTesting
  static Future<void> Function(String step, File file)? debugFault;

  Future<void> _step(String step, File file) async => debugFault?.call(step, file);

  /// The open vault had to be read from the previous copy: its last change
  /// before the damage may be missing. Read once by the app, to say so.
  bool _restoredFromPrevious = false;

  bool takeRestoredFromPrevious() {
    final was = _restoredFromPrevious;
    _restoredFromPrevious = false;
    return was;
  }

  /// Prepares storage without touching any vault: there is no key to open
  /// one with until a PIN or biometric unlock produces it. Hive is still
  /// set up, for the security log and for moving old vault files.
  /// For tests, on a phone as well as off one: the folder to keep every
  /// file in instead of the app's own, which a test run on a phone must
  /// never touch. Replacing the platform's answer is not enough there:
  /// Android's plugins do not go through the channel tests can intercept.
  @visibleForTesting
  static String? debugDirectory;

  Future<void> init() async {
    // Asked every time rather than once: it costs nothing, and the folder
    // is then always the one the platform names now.
    final forced = debugDirectory;
    _dir = forced ?? (await getApplicationDocumentsDirectory()).path;
    if (_isInitialized) return;

    if (forced != null) {
      Hive.init(forced);
    } else {
      await Hive.initFlutter();
    }
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(VaultEntryAdapter());
    }
    _isInitialized = true;
  }

  /// Opens a vault with an already-recovered master key.
  ///
  /// Throws [VaultTamperedError] when the file has been altered, when this
  /// vault's part of it is missing although it was written before, or when
  /// it is an older copy than the last one written.
  Future<void> openVault({
    required Uint8List masterKey,
    required bool isDecoy,
  }) async {
    await init();

    // Drop whatever was open first, so the two vaults are never both live.
    await _closeVault();

    // Autofill runs in a separate isolate. Two isolates writing one file
    // corrupts it, so only one may hold the vault.
    if (!await VaultLock.acquireOrAsk()) throw VaultBusyException();

    try {
      _open = await _load(SlotKeys(masterKey), masterKey, isDecoy: isDecoy);
    } catch (_) {
      await _closeVault();
      rethrow;
    }
    _activeMasterKey = masterKey;
    _isDecoyMode = isDecoy;
    _changes.value++;

    // Logins saved while it was locked (save_inbox.dart).
    await takeSaveInbox();
  }

  /// Reads [isDecoy]'s vault: from its slot, or from its old files the
  /// first time, or empty for a vault nothing has been written to.
  Future<_OpenVault> _load(SlotKeys keys, Uint8List oldKey, {required bool isDecoy}) async {
    final slot = isDecoy ? decoySlot : realSlot;
    await _finishInterruptedWrite();
    final written = await openCount(await _secure.read(key: _countKeys[slot]), keys, slot);
    final json = await _readSlot(_file, keys, slot);

    if (json != null) {
      final vault = _OpenVault.fromJson(json, slot: slot, keys: keys);
      // An older copy of the file, put back.
      if (vault.count < (written ?? 0)) throw VaultTamperedError();
      // Left over from a move interrupted after its commit.
      await _deleteOldFiles(isDecoy: isDecoy);
      return vault;
    }
    if (written != null && written > 0) {
      // Written before, and now unreadable: the copy kept from one write
      // back, if that is what it is. Anything older is refused like any
      // older copy, so this cannot be used to put one back.
      final previous = await _readSlot(_prevFile, keys, slot);
      if (previous == null) throw VaultTamperedError();
      final vault = _OpenVault.fromJson(previous, slot: slot, keys: keys);
      if (vault.count < written - 1) throw VaultTamperedError();
      _restoredFromPrevious = true;
      // Written straight back into the current file, beside whatever the
      // other vault has there.
      await _write(vault, base: await _readableBase());
      return vault;
    }

    final old = await _readOldFiles(oldKey, isDecoy: isDecoy);
    final vault = _OpenVault(
      slot: slot,
      keys: keys,
      entries: old?.$1 ?? {},
      deleted: old?.$2 ?? {},
      log: old?.$3 ?? [],
      count: 0,
    );
    if (old != null) {
      // The commit is the container write; the old files go only after it.
      await _write(vault);
      await _step('moved', _file);
      await _deleteOldFiles(isDecoy: isDecoy);
    }
    return vault;
  }

  /// This vault's slot in [file], or null when [keys] do not open it (or
  /// there is no such file, or it is not a container at all).
  Future<Map<String, dynamic>?> _readSlot(File file, SlotKeys keys, int slot) async {
    final bytes = await _containerBytes(file);
    if (bytes == null) return null;
    final (a, b) = splitContainer(bytes);
    return compute(_openSlotIsolate, (slot == realSlot ? a : b, keys.slot, keys.count, slot));
  }

  /// [file]'s bytes if it is a whole container, else null.
  Future<Uint8List?> _containerBytes(File file) async {
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      splitContainer(bytes);
      return bytes;
    } on FileSystemException {
      return null;
    } on ContainerError {
      return null;
    }
  }

  /// What a write carries the other vault's slot over from: the current
  /// file if it is whole, else the previous one.
  Future<Uint8List?> _readableBase() async =>
      await _containerBytes(_file) ?? await _containerBytes(_prevFile);

  /// A write stopped between its two renames leaves no current file and a
  /// complete next one (it was flushed before the first rename): that one
  /// becomes current. A next file beside a current one was never committed
  /// and is dropped.
  Future<void> _finishInterruptedWrite() async {
    final next = _newFile;
    if (!await next.exists()) return;
    if (!await _file.exists() && await _containerBytes(next) != null) {
      await next.rename(_file.path);
    } else {
      await next.delete();
    }
  }

  /// The vault's contents from the Hive files it was kept in before, or
  /// null when there are none. Each name is only ever opened with the
  /// cipher it was written with: Hive's crash recovery cuts a file opened
  /// with the wrong one down to nothing.
  Future<(Map<String, VaultEntry>, Map<String, DateTime>, List<Map<String, dynamic>>)?>
      _readOldFiles(Uint8List key, {required bool isDecoy}) async {
    final current = isDecoy ? oldDecoyVaultBoxName : oldRealVaultBoxName;
    final legacy = isDecoy ? legacyDecoyVaultBoxName : legacyRealVaultBoxName;
    final logName = isDecoy ? oldDecoyLogBoxName : oldRealLogBoxName;

    // The oldest file first: it was only ever deleted once its move to the
    // newer one had finished, so while it exists, a newer file beside it
    // may be a move cut short.
    Map<String, VaultEntry>? entries;
    if (await Hive.boxExists(legacy)) {
      final box = await Hive.openBox<VaultEntry>(legacy, encryptionCipher: HiveAesCipher(key));
      entries = {for (final e in box.values) e.id: e};
      await box.close();
    } else if (await Hive.boxExists(current)) {
      final box = await Hive.openBox<VaultEntry>(current, encryptionCipher: VaultCipher(key));
      entries = {for (final e in box.values) e.id: e};
      await box.close();
    }

    final deleted = <String, DateTime>{};
    if (!isDecoy) {
      // The same rule: the oldest record of deletions, if it is still there.
      final (name, cipher) = await Hive.boxExists(legacyTombstoneBoxName)
          ? (legacyTombstoneBoxName, HiveAesCipher(key) as HiveCipher)
          : (oldRealTombstoneBoxName, VaultCipher(key));
      if (await Hive.boxExists(name)) {
        final box = await Hive.openBox<String>(name, encryptionCipher: cipher);
        for (final k in box.keys) {
          final at = DateTime.tryParse(box.get(k) ?? '');
          if (at != null) deleted['$k'] = at.toUtc();
        }
        await box.close();
      }
    }

    final log = <Map<String, dynamic>>[];
    if (await Hive.boxExists(logName)) {
      final box = await Hive.openBox<Map>(logName, encryptionCipher: HiveAesCipher(key));
      log.addAll(box.values.map((m) => Map<String, dynamic>.from(m)));
      await box.close();
    }

    if (entries == null && deleted.isEmpty && log.isEmpty) return null;
    return (entries ?? <String, VaultEntry>{}, deleted, log);
  }

  Future<void> _deleteOldFiles({required bool isDecoy}) async {
    final names = isDecoy
        ? [oldDecoyVaultBoxName, legacyDecoyVaultBoxName, oldDecoyLogBoxName]
        : [
            oldRealVaultBoxName,
            oldRealTombstoneBoxName,
            legacyRealVaultBoxName,
            legacyTombstoneBoxName,
            oldRealLogBoxName,
          ];
    for (final name in names) {
      try {
        if (await Hive.boxExists(name)) await Hive.deleteBoxFromDisk(name);
      } catch (_) {
        // Tried again on the next open.
      }
    }
  }

  /// Saves the open vault, after any save already under way.
  Future<void> _save() {
    final vault = _require;
    _changes.value++;
    return _afterWrites(() => _write(vault));
  }

  /// Runs [job] once every write already asked for has finished. With none
  /// under way it starts a new chain rather than hanging on to the last
  /// finished one, which is only ever extra to wait on.
  ///
  /// The chain runs in the root zone, whoever asked: a write to the vault
  /// has to finish even if what asked for it has gone, and a zone of its own
  /// (a test's simulated clock, say) must not be able to hold it up.
  ///
  /// Its outcome comes back on the caller's own zone: an error cannot cross
  /// from one error zone to another, and would otherwise surface as an
  /// unhandled one instead of reaching whoever asked for the write.
  Future<void> _afterWrites(Future<void> Function() job) {
    final done = Completer<void>();
    Zone.root.run(() {
      final prior = _pendingWrites == 0 ? Future<void>.value() : _writing;
      _pendingWrites++;
      final run = prior.then((_) => job()).whenComplete(() => _pendingWrites--);
      // What later writes and closing wait on: it never fails, so a failed
      // write never stops the next one.
      _writing = run.then((_) {}, onError: (Object _) {});
      run.then((_) => done.complete(), onError: done.completeError);
    });
    return done.future;
  }

  /// Writes [vault] into its slot, in steps that leave a whole vault on disk
  /// whenever they stop:
  ///
  ///  1. the whole next file, to `.new`, flushed;
  ///  2. the current file renamed to `.prev`, kept as the version before;
  ///  3. `.new` renamed to current: the commit;
  ///  4. the write count, which only ever trails the file, so a stop before
  ///     it leaves a count one lower than the file's, which is accepted.
  ///
  /// Stopped in 1, the current file is untouched. Stopped between 2 and 3,
  /// there is no current file and a complete `.new`, which the next open
  /// finishes ([_finishInterruptedWrite]). Renames within one folder are
  /// atomic on Android's file systems.
  ///
  /// [base] is where the other vault's slot comes from: the current file
  /// unless that is the problem being recovered from.
  Future<void> _write(_OpenVault vault, {Uint8List? base}) async {
    vault.count++;
    final existing = base ?? await _readableBase();
    final bytes = await compute(
      _sealIsolate,
      (vault.toJson(), vault.keys.slot, vault.keys.count, vault.slot, existing),
    );
    await _step('sealed', _newFile);
    await _newFile.writeAsBytes(bytes, flush: true);
    await _step('written', _newFile);
    if (await _file.exists()) await _file.rename(_prevFile.path);
    await _step('kept-previous', _file);
    await _newFile.rename(_file.path);
    await _step('committed', _file);

    await _secure.write(
      key: _countKeys[vault.slot],
      value: await sealCount(vault.count, vault.keys, vault.slot),
    );
    // The other slot's stand-in, if it has none yet.
    final other = _countKeys[1 - vault.slot];
    if (await _secure.read(key: other) == null) {
      await _secure.write(key: other, value: unusedCount());
    }
  }

  /// Re-encrypts a vault under [newMasterKey], preserving its contents.
  ///
  /// Used by migration to give the decoy vault a key of its own: before, both
  /// vaults shared one key, so the decoy offered no cryptographic separation
  /// from the real vault at all.
  Future<void> rekeyVault({
    required Uint8List currentMasterKey,
    required Uint8List newMasterKey,
    required bool isDecoy,
  }) async {
    await init();
    await _closeVault();
    if (!await VaultLock.acquireOrAsk()) throw VaultBusyException();
    try {
      final old = await _load(SlotKeys(currentMasterKey), currentMasterKey, isDecoy: isDecoy);
      final vault = _OpenVault(
        slot: old.slot,
        keys: SlotKeys(newMasterKey),
        entries: old.entries,
        deleted: old.deleted,
        log: old.log,
        count: old.count,
        meta: old.meta,
      );
      await _write(vault);
      _open = vault;
    } catch (_) {
      await _closeVault();
      rethrow;
    }
    _activeMasterKey = newMasterKey;
    _isDecoyMode = isDecoy;
    _changes.value++;
  }

  /// Erases one vault: its slot becomes random bytes, the same as a slot
  /// nothing ever used. Safe to call with the other vault open.
  Future<void> destroyVault({required bool isDecoy}) async {
    await init();
    final slot = isDecoy ? decoySlot : realSlot;

    // Only close if the vault being destroyed is the one that is open.
    if (_open != null && _isDecoyMode == isDecoy) await _closeVault();

    await _afterWrites(() async {
      await _finishInterruptedWrite();
      // The previous copy too: it holds the vault one write back.
      for (final file in [_file, _prevFile]) {
        final bytes = await _containerBytes(file);
        if (bytes == null) {
          if (await file.exists()) await file.delete();
          continue;
        }
        final size = splitContainer(bytes).$1.length;
        final out = Uint8List.fromList(bytes)
          ..setRange(headerBytes + slot * size, headerBytes + (slot + 1) * size, noise(size));
        await _newFile.writeAsBytes(out, flush: true);
        await _newFile.rename(file.path);
      }
      await _secure.write(key: _countKeys[slot], value: unusedCount());
    });
    await _deleteOldFiles(isDecoy: isDecoy);
    await SaveInbox().forget(slot);
  }

  /// Permanently destroys both vaults' data.
  Future<void> destroyAllVaults() async {
    await init();
    await _closeVault();
    await _afterWrites(() async {
      for (final f in [_file, _newFile, _prevFile]) {
        if (await f.exists()) await f.delete();
      }
    });
    for (final key in _countKeys) {
      await _secure.write(key: key, value: unusedCount());
    }
    await _deleteOldFiles(isDecoy: false);
    await _deleteOldFiles(isDecoy: true);
    await SaveInbox().destroyAll();
  }

  Future<void> _closeVault() async {
    final wasOpen = _open != null;
    // Anything still being written finishes first.
    if (_pendingWrites > 0) await _writing;
    _open = null;
    _activeMasterKey = null;
    if (wasOpen) _changes.value++;
    if (wasOpen || VaultLock.isHeldByThisIsolate) await VaultLock.release();
  }

  /// Closes the vault while keeping the key, so it can be reopened without
  /// asking again.
  ///
  /// Used when the app goes to the background with a delayed auto-lock. The
  /// vault used to stay open for the whole delay, which held the vault lock
  /// and left it decrypted behind a screen nobody was looking at.
  Future<void> suspend() async {
    final key = _activeMasterKey;
    if (key == null || _open == null) return;

    _suspendedKey = key;
    _suspendedDecoy = _isDecoyMode;
    await _closeVault();
  }

  /// Reopens a suspended vault. Returns false if there was nothing to resume
  /// or another isolate has taken the lock in the meantime.
  Future<bool> resume() async {
    final key = _suspendedKey;
    if (key == null) return false;
    if (isReady) return true;

    try {
      await openVault(masterKey: key, isDecoy: _suspendedDecoy);
      _suspendedKey = null;
      return true;
    } on VaultBusyException {
      return false;
    }
  }

  void forgetSuspended() {
    _suspendedKey = null;
  }

  Uint8List? _suspendedKey;
  bool _suspendedDecoy = false;

  // CRUD Operations
  List<VaultEntry> getEntries() {
    OfflineGuard.ensureOffline(); // Security Check
    final open = _open;
    if (open == null) return [];
    return open.entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// The time to stamp an edit made here with.
  ///
  /// Sync picks the later of two versions by this stamp, so a phone whose
  /// clock runs behind used to lose edits it made after seeing another
  /// device's change. This is a hybrid logical clock: "now", unless the
  /// vault already holds something stamped later (another device's clock
  /// ran ahead), in which case just after that. An edit made after seeing a
  /// change therefore always outranks it, whatever the clocks say. Only two
  /// edits made at the same time on devices that had not synced in between
  /// are still decided by the clocks alone.
  DateTime nextStamp() {
    final now = DateTime.now().toUtc();
    DateTime? known;
    for (final e in _open?.entries.values ?? const <VaultEntry>[]) {
      if (known == null || e.updatedAt.isAfter(known)) known = e.updatedAt.toUtc();
    }
    for (final at in deletions.values) {
      if (known == null || at.isAfter(known)) known = at;
    }
    // Strictly after anything already here, even something stamped this
    // very millisecond.
    if (known == null || known.isBefore(now)) return now;
    return known.add(const Duration(milliseconds: 1));
  }

  Future<void> addEntry(VaultEntry entry) async {
    OfflineGuard.ensureOffline(); // Security Check
    entry.updatedAt = nextStamp();
    _require.entries[entry.id] = entry;
    await _save();
  }

  /// Adds many entries in one write, as an import does: one change for sync
  /// to pick up instead of hundreds, and all or nothing on disk.
  Future<void> addEntries(List<VaultEntry> entries) async {
    OfflineGuard.ensureOffline(); // Security Check
    final at = nextStamp();
    for (final e in entries) {
      e.updatedAt = at;
    }
    _require.entries.addAll({for (final e in entries) e.id: e});
    await _save();
  }

  Future<void> updateEntry(VaultEntry entry) async {
    OfflineGuard.ensureOffline(); // Security Check
    entry.updatedAt = nextStamp();
    // A changed password: the one it replaces goes into the history.
    final before = _require.entries[entry.id];
    if (before != null && before.password.isNotEmpty && before.password != entry.password) {
      entry.passwordHistory = withPreviousPassword(
        entry.passwordHistory.isEmpty ? before.passwordHistory : entry.passwordHistory,
        before.password,
        entry.updatedAt,
        current: entry.password,
      );
    }
    _require.entries[entry.id] = entry;
    await _save();
  }

  Future<void> deleteEntry(String id) async {
    OfflineGuard.ensureOffline(); // Security Check
    final at = nextStamp();
    final open = _require;
    open.entries.remove(id);
    if (!_isDecoyMode) open.deleted[id] = at;
    await _save();
  }

  Future<void> deleteAllEntries() async {
    OfflineGuard.ensureOffline(); // Security Check
    final open = _require;
    final at = nextStamp();
    if (!_isDecoyMode) {
      for (final id in open.entries.keys) {
        open.deleted[id] = at;
      }
    }
    open.entries.clear();
    await _save();
  }

  // Sync. These exist so sync never goes through the ordinary write paths:
  // those stamp the current time, and stamping a copy that arrived from
  // another device with "now" would make it look newer than it is, letting
  // it beat a genuinely later edit made somewhere else.

  /// When each entry in the real vault was deleted. Empty for the decoy.
  Map<String, DateTime> get deletions =>
      _isDecoyMode ? const {} : Map.unmodifiable(_open?.deleted ?? const {});

  /// Writes an entry exactly as another device had it, timestamp included.
  Future<void> applySyncedEntry(VaultEntry entry) async {
    final open = _require;
    open.entries[entry.id] = entry;
    open.deleted.remove(entry.id);
    await _save();
  }

  /// Removes an entry because another device deleted it, keeping the time
  /// that device recorded rather than the time it arrived here.
  Future<void> applySyncedDeletion(String id, DateTime deletedAt) async {
    final open = _require;
    open.entries.remove(id);
    if (!_isDecoyMode) open.deleted[id] = deletedAt.toUtc();
    await _save();
  }

  /// Replaces the deletion record wholesale, used after pruning old ones.
  Future<void> replaceDeletions(Map<String, DateTime> deletions) async {
    if (_isDecoyMode) return;
    final open = _require;
    open.deleted
      ..clear()
      ..addAll({for (final e in deletions.entries) e.key: e.value.toUtc()});
    await _save();
  }

  // The open vault's activity log (ActivityLogService keeps it).

  List<Map<String, dynamic>> get vaultLog => List.unmodifiable(_open?.log ?? const []);

  /// Replaces the log. Nothing happens with no vault open: there is nothing
  /// it could be encrypted under.
  Future<void> setVaultLog(List<Map<String, dynamic>> log) async {
    final open = _open;
    if (open == null) return;
    open.log = log;
    await _save();
  }

  /// Whether a decoy vault exists. Known only inside the real vault: kept
  /// in its slot, so nothing readable without its key says so. False with
  /// the decoy open.
  bool get hasDecoy => !_isDecoyMode && _open?.meta['decoy'] == true;

  Future<void> setHasDecoy(bool value) async {
    final open = _require;
    if (_isDecoyMode) return;
    if (value) {
      open.meta['decoy'] = true;
    } else {
      open.meta.remove('decoy');
    }
    await _save();
  }

  /// A list of names kept inside the open vault (its categories, say), or
  /// null if it has none yet.
  List<String>? metaStrings(String key) {
    final value = _open?.meta[key];
    return value is List ? value.map((v) => '$v').toList() : null;
  }

  Future<void> setMetaStrings(String key, List<String> value) async {
    _require.meta[key] = value;
    await _save();
  }

  /// Any value kept in the open vault's meta, or null.
  Object? metaValue(String key) => _open?.meta[key];

  /// Sets (or, with null, removes) a value in the open vault's meta.
  Future<void> setMetaValue(String key, Object? value) async {
    final open = _require;
    if (value == null) {
      if (open.meta.remove(key) == null) return;
    } else {
      open.meta[key] = value;
    }
    await _save();
  }

  /// Writes [entries] into a vault that is not the open one and has never
  /// been written: a decoy just created, filled while its key is in hand
  /// rather than from something kept about it until it is first opened.
  /// Nothing happens if that vault has been written before.
  Future<void> seedVault({
    required Uint8List masterKey,
    required bool isDecoy,
    required List<VaultEntry> entries,
  }) async {
    final keys = SlotKeys(masterKey);
    final slot = isDecoy ? decoySlot : realSlot;
    final written = await openCount(await _secure.read(key: _countKeys[slot]), keys, slot);
    if ((written ?? 0) > 0 || await _readSlot(_file, keys, slot) != null) return;
    final vault = _OpenVault(
      slot: slot,
      keys: keys,
      entries: {for (final e in entries) e.id: e},
      deleted: {},
      log: [],
      count: 0,
    );
    await _afterWrites(() => _write(vault));
  }

  /// Changes whenever the open vault does.
  ValueListenable<int> listenable() => _changes;

  // Backup & Restore

  /// Encrypts under a passphrase in the format shared by exported backups,
  /// Google Drive sync, and the browser extension: Argon2id and AES-256-GCM,
  /// versioned, described in lib/utils/sealed_file.dart. Three
  /// readers depend on it, and test/extension_interchange_test.dart checks
  /// the JavaScript one against this.
  ///
  /// The key derivation and the encryption both run on a background isolate:
  /// on Android the app's Dart code shares the thread that handles touches,
  /// and a few seconds of key derivation there gets the app reported as not
  /// responding.
  Future<String> encryptData(List<int> plainBytes, String password) =>
      compute(_encryptBackup, (plainBytes, password));

  /// Reverses [encryptData]. Throws when the passphrase is wrong or the bytes
  /// were altered; AES-GCM makes the two indistinguishable on purpose. Runs
  /// on a background isolate, like [encryptData].
  Future<List<int>> decryptDataV2(List<int> bytes, String password) =>
      compute(_decryptBackup, (bytes, password));

  // A sealed file (lib/utils/sealed_file.dart, docs/FORMATS.md): AES-GCM
  // under Argon2id of the backup password (version 3), PBKDF2 on the web.
  Future<String> getEncryptedJson(String password) async {
    final plainJson = getAllEntriesAsJson();
    final plainBytes = utf8.encode(plainJson);
    return await encryptData(plainBytes, password);
  }

  /// Imports a backup produced by [getEncryptedJson].
  ///
  /// AES-GCM only. The legacy "V1" fallback that used to live here derived the
  /// AES key by right-padding the password with '*' and derived the IV from
  /// that same password, over unauthenticated CBC, so the key had only as
  /// much entropy as the password, the IV repeated across every backup made
  /// with the same password, and ciphertext could be tampered with
  /// undetectably. It has been removed rather than kept as a fallback: an
  /// attacker-supplied file must never be able to select the weaker format.
  Future<int> importFromEncryptedJson(
    String encryptedBase64,
    String password,
  ) async {
    final List<int> bytes;
    try {
      bytes = base64Decode(encryptedBase64.trim());
    } on FormatException {
      throw Exception('This file is not a Ringer Vault backup.');
    }

    // salt(16) + nonce(12) + mac(16) must all be present before any ciphertext.
    if (bytes.length <= 44) {
      throw Exception('This file is not a Ringer Vault backup.');
    }

    final List<int> decryptedBytes;
    try {
      decryptedBytes = await decryptDataV2(bytes, password);
    } catch (_) {
      // AES-GCM authenticates, so a MAC failure means either the wrong
      // password or a modified file. The two are indistinguishable by design.
      throw Exception('Incorrect password, or the backup file is damaged.');
    }

    return await importEntriesFromJson(utf8.decode(decryptedBytes));
  }

  String getAllEntriesAsJson() {
    final entries = _require.entries.values.map((e) => e.toJson()).toList();
    return jsonEncode(entries);
  }

  Future<int> importEntriesFromJson(String jsonString) async {
    OfflineGuard.ensureOffline(); // Security Check
    try {
      final List<dynamic> decoded = jsonDecode(jsonString);
      final Map<String, VaultEntry> batch = {};

      // 1. Validate & Prepare Batch (All-or-Nothing parsing)
      for (var item in decoded) {
        final entry = VaultEntry.fromJson(item);
        batch[entry.id] = entry;
      }

      // 2. Merged, not pasted over: an entry changed here since the backup
      // was made keeps the newer version, and one deleted since stays
      // deleted. Re-importing an old backup must never quietly undo a
      // password changed after a breach.
      final open = _require;
      final taken = <String, VaultEntry>{};
      for (final e in batch.values) {
        final here = open.entries[e.id];
        if (here != null && !e.updatedAt.isAfter(here.updatedAt)) continue;
        final deletedAt = open.deleted[e.id];
        if (deletedAt != null && !e.updatedAt.isAfter(deletedAt)) continue;
        taken[e.id] = e;
      }
      if (taken.isEmpty) return 0;
      open.entries.addAll(taken);
      for (final id in taken.keys) {
        open.deleted.remove(id);
      }
      await _save();
      return taken.length;
    } catch (e) {
      // If parsing fails, nothing is written.
      throw Exception('Invalid data format or Import failed: $e');
    }
  }

  Future<void> close() async {
    await _closeVault();
    _isDecoyMode = false;
  }
}

/// [StorageService.encryptData], on a background isolate. Always the
/// current format: see lib/utils/sealed_file.dart.
Future<String> _encryptBackup((List<int>, String) args) async {
  final (plainBytes, password) = args;
  final params = SealParams.fresh();
  final key = await deriveSealKey(password, params);
  return sealWithKey(plainBytes, key, params);
}

/// [StorageService.decryptDataV2], on a background isolate. Reads a backup
/// of any sealed-file version (1, 2 or 3).
Future<List<int>> _decryptBackup((List<int>, String) args) async {
  final (bytes, password) = args;
  final parts = splitSealed(bytes);
  final key = await deriveSealKey(password, parts.params);
  final plain = await openWithKey(parts, key);
  if (plain == null) throw SecretBoxAuthenticationError();
  return plain;
}

/// [openSlot] on a background isolate: trying every bucket against a large
/// file is real work.
Future<Map<String, dynamic>?> _openSlotIsolate((Uint8List, List<int>, List<int>, int) args) {
  final (bytes, slotKey, countKey, slot) = args;
  return openSlot(bytes, SlotKeys.fromParts(slot: slotKey, count: countKey), slot);
}

/// Sealing and assembling the whole file, on a background isolate.
Future<Uint8List> _sealIsolate(
  (Map<String, dynamic>, List<int>, List<int>, int, Uint8List?) args,
) async {
  final (json, slotKey, countKey, slot, existing) = args;
  final own = await sealSlot(json, SlotKeys.fromParts(slot: slotKey, count: countKey), slot);
  return assemble(existing: existing, own: own, slot: slot);
}
