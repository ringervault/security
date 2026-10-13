import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ringer_vault/utils/secret_text.dart';

/// Owns the vault's key material.
///
/// ## Design
///
/// Each vault (real and decoy) has a random 32-byte **master key** (MK) from
/// which its slot of vault.rvc is encrypted (docs/FORMATS.md). The MK is
/// never stored in the clear.
/// Instead it is stored wrapped, in up to two independent envelopes:
///
///  * **PIN envelope**: `AES-GCM(Argon2id(pin, salt), MK)`. Opening the vault
///    requires re-deriving the KEK from the entered PIN. A wrong PIN fails the
///    GCM tag check, so the envelope doubles as the PIN verifier and no
///    separate password hash is stored.
///
///  * **Biometric envelope**: the MK held in platform secure storage under a
///    key the OS will only release after a biometric match
///    (`setUserAuthenticationRequired(true)` on Android,
///    `kSecAccessControlBiometryCurrentSet` on Apple). Optional, and only
///    written when the user turns biometric unlock on.
///
/// Both envelopes live inside the platform keystore, so an attacker needs to
/// break out of secure hardware *and* know the PIN. Previously the MK sat in
/// secure storage verbatim and the PIN was a UI check, so a single keystore
/// extraction yielded the whole vault.
///
/// ## The limit of a 6-digit PIN
///
/// A 6-digit PIN is about 20 bits of entropy: 1,000,000 possibilities. No KDF
/// removes that ceiling; Argon2id only makes each guess expensive. The
/// parameters below put a single guess in the ~0.2s range on desktop hardware
/// and around a second on a mid-range phone, and the memory cost is what
/// blunts GPU parallelism. Combined with hardware key storage and the app's
/// own lockout this is a large improvement, but it is not equivalent to a
/// high-entropy passphrase. Supporting a longer PIN or passphrase is the
/// single highest-value follow-up.
class VaultKeyService {
  static final VaultKeyService _instance = VaultKeyService._internal();
  factory VaultKeyService() => _instance;
  VaultKeyService._internal();

  static const int keyLengthBytes = 32;
  static const int _saltLengthBytes = 16;
  static const int _nonceLengthBytes = 12;
  static const int _macLengthBytes = 16;

  /// Argon2id cost on native platforms. Persisted per vault so these can be
  /// raised later without locking anyone out of a vault sealed under the old
  /// cost.
  static const int _defaultMemoryKib = 32 * 1024; // 32 MiB
  static const int _defaultIterations = 3;
  static const int _defaultParallelism = 1;

  /// PBKDF2 cost on web. Far more iterations than the native path uses,
  /// because SubtleCrypto runs this natively: measured at ~86ms in Chrome,
  /// against ~13s for pure-Dart Argon2id at the settings above.
  static const int _defaultWebIterations = 1200000;

  /// Which KDF a new vault is sealed with.
  ///
  /// Argon2id is the better primitive: memory-hardness is what blunts GPU
  /// attacks on a low-entropy PIN, but on web it has no native implementation
  /// and `compute()` has no isolate to run it in, so it would freeze the tab
  /// for 13 seconds on every unlock and every re-auth. PBKDF2 through
  /// WebCrypto is the standard browser compromise. Not memory-hard, but
  /// hardware-accelerated, which allows an iteration count high enough to be
  /// worth something.
  static _KdfAlgorithm get _defaultAlgorithm =>
      kIsWeb ? _KdfAlgorithm.pbkdf2 : _KdfAlgorithm.argon2id;

  static const _storage = FlutterSecureStorage();

  /// Reading this must cost a biometric match, enforced by the OS rather than
  /// by us. `biometryCurrentSet` invalidates the key if the enrolled biometrics
  /// change, which stops someone who can unlock the phone from simply adding
  /// their own fingerprint to gain vault access.
  static const _biometricStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(enforceBiometrics: true),
    iOptions: IOSOptions(
      accessControlFlags: [AccessControlFlag.biometryCurrentSet],
    ),
  );

  // ---- Storage keys -------------------------------------------------------

  String _saltKey(bool isDecoy) => _scoped('vk_salt', isDecoy);
  String _kdfParamsKey(bool isDecoy) => _scoped('vk_kdf_params', isDecoy);
  String _pinEnvelopeKey(bool isDecoy) => _scoped('vk_wrapped_pin', isDecoy);
  String _bioEnvelopeKey(bool isDecoy) => _scoped('vk_wrapped_bio', isDecoy);

  /// The second vault's records carry a plain "_2". They are on every
  /// phone (a stand-in where there is no decoy: [ensureDecoyStandIn]), so
  /// their being there says nothing; their name used to say "_decoy".
  String _scoped(String base, bool isDecoy) => isDecoy ? '${base}_2' : base;

  /// Moves records written under the old "_decoy" names to the plain ones,
  /// once per run, before anything here reads or writes them. Lazily, not at
  /// start-up: secure storage blocks the first frame on Android.
  static Future<void>? _renamed;
  Future<void> _ready() => _renamed ??= _renameOldRecords();

  /// For tests, which start over with fresh storage.
  @visibleForTesting
  static void debugForgetRenamed() => _renamed = null;

  Future<void> _renameOldRecords() async {
    for (final base in ['vk_salt', 'vk_kdf_params', 'vk_wrapped_pin']) {
      final old = '${base}_decoy';
      final value = await _storage.read(key: old);
      if (value == null) continue;
      if (await _storage.read(key: _scoped(base, true)) == null) {
        await _storage.write(key: _scoped(base, true), value: value);
      }
      await _storage.delete(key: old);
    }
  }

  /// Pre-existing key, held verbatim. Only read during migration.
  static const String legacyMasterKeyKey = 'hive_encryption_key';

  // ---- Public API ---------------------------------------------------------

  /// Whether [isDecoy]'s vault has been sealed in the current format.
  Future<bool> hasPinEnvelope({required bool isDecoy}) async {
    await _ready();
    return await _storage.read(key: _pinEnvelopeKey(isDecoy)) != null;
  }

  /// Creates key material for a brand-new vault and returns its master key.
  Future<Uint8List> createVault({
    required String pin,
    required bool isDecoy,
  }) async {
    final masterKey = _randomBytes(keyLengthBytes);
    await _sealWithPin(masterKey: masterKey, pin: pin, isDecoy: isDecoy);
    return masterKey;
  }

  /// Adopts an existing plaintext master key into the PIN envelope.
  ///
  /// Used by migration: the vault's data stays encrypted under the key it
  /// already has, so nothing needs re-encrypting: only the way that key is
  /// stored changes.
  Future<void> adoptExistingKey({
    required Uint8List masterKey,
    required String pin,
    required bool isDecoy,
  }) =>
      _sealWithPin(masterKey: masterKey, pin: pin, isDecoy: isDecoy);

  /// Recovers the master key from the PIN envelope.
  ///
  /// Returns null when the PIN is wrong or no envelope exists. The two are
  /// deliberately indistinguishable to the caller.
  Future<Uint8List?> unlockWithPin({
    required String pin,
    required bool isDecoy,
  }) async {
    await _ready();
    final envelopeB64 = await _storage.read(key: _pinEnvelopeKey(isDecoy));
    final saltB64 = await _storage.read(key: _saltKey(isDecoy));
    if (envelopeB64 == null || saltB64 == null) {
      // Nothing to open, but the same work as if there were: how long a
      // PIN takes to refuse must not say whether this vault exists.
      for (final form in await SecretText.forms(pin)) {
        await _deriveKek(pin: form, salt: _randomBytes(_saltLengthBytes), params: _KdfParams.defaults());
      }
      return null;
    }

    final params = await _readKdfParams(isDecoy);
    // Every form is tried, always all of them, whichever opens: stopping at
    // the first would make a right secret quicker than a wrong one.
    Uint8List? opened;
    for (final form in await SecretText.forms(pin)) {
      final kek = await _deriveKek(
        pin: form,
        salt: base64Decode(saltB64),
        params: params,
      );
      try {
        opened ??= await _unseal(base64Decode(envelopeB64), kek);
      } catch (_) {
        // GCM tag mismatch: wrong PIN, or the envelope was tampered with.
      }
    }
    return opened;
  }

  /// Recovers the master key from the biometric envelope.
  ///
  /// The OS shows its own prompt and refuses to return the bytes without a
  /// match, so there is no separate "verify then read" step to race.
  Future<Uint8List?> unlockWithBiometric({required bool isDecoy}) async {
    try {
      final raw = await _biometricStorage.read(key: _bioEnvelopeKey(isDecoy));
      if (raw == null) return null;
      return base64Decode(raw);
    } catch (_) {
      // No match, cancelled, or the enrolled biometrics changed and the OS
      // invalidated the key.
      return null;
    }
  }

  Future<bool> hasBiometricEnvelope({required bool isDecoy}) async {
    try {
      return await _biometricStorage.containsKey(
        key: _bioEnvelopeKey(isDecoy),
      );
    } catch (_) {
      return false;
    }
  }

  /// Adds the biometric envelope. Requires an already-unlocked [masterKey],
  /// so biometrics can only ever be enabled from inside an open vault.
  Future<bool> enableBiometricUnlock({
    required Uint8List masterKey,
    required bool isDecoy,
  }) async {
    try {
      await _biometricStorage.write(
        key: _bioEnvelopeKey(isDecoy),
        value: base64Encode(masterKey),
      );
      return true;
    } catch (_) {
      // Device has no enrolled biometrics, or no secure lock screen.
      return false;
    }
  }

  Future<void> disableBiometricUnlock({required bool isDecoy}) async {
    try {
      await _biometricStorage.delete(key: _bioEnvelopeKey(isDecoy));
    } catch (_) {
      // Nothing to remove.
    }
  }

  /// Re-seals the same master key under a new PIN.
  ///
  /// The MK is unchanged, so vault contents are untouched and the biometric
  /// envelope stays valid.
  Future<void> changePin({
    required Uint8List masterKey,
    required String newPin,
    required bool isDecoy,
  }) =>
      _sealWithPin(masterKey: masterKey, pin: newPin, isDecoy: isDecoy);

  /// A random key scoped to the device rather than to a vault, created on
  /// first use and held in the platform keystore.
  ///
  /// For data that must be readable before any vault is unlocked: currently
  /// only the security event log. Weaker than a PIN-derived key by
  /// construction, since nothing the user knows is involved, so it must never
  /// protect vault contents.
  Future<Uint8List> deviceScopedKey(String purpose) async {
    final storageKey = 'vk_device_$purpose';

    final existing = await _storage.read(key: storageKey);
    if (existing != null) return Uint8List.fromList(base64Decode(existing));

    final key = _randomBytes(keyLengthBytes);
    await _storage.write(key: storageKey, value: base64Encode(key));
    return key;
  }

  /// Destroys every envelope for a vault. The data becomes unrecoverable.
  /// Gives the decoy's key records a stand-in when there is no decoy: a
  /// random salt, the usual settings, and 60 random bytes where the sealed
  /// key would be, the same length as a real one. Every PIN fails against
  /// it exactly as a wrong one does. Without it, the decoy's records
  /// existing at all would say there is a decoy.
  Future<void> ensureDecoyStandIn() async {
    await _ready();
    if (await hasPinEnvelope(isDecoy: true)) return;
    await _storage.write(key: _saltKey(true), value: base64Encode(_randomBytes(_saltLengthBytes)));
    await _storage.write(key: _kdfParamsKey(true), value: jsonEncode(_KdfParams.defaults().toJson()));
    await _storage.write(
      key: _pinEnvelopeKey(true),
      value: base64Encode(_randomBytes(_nonceLengthBytes + keyLengthBytes + _macLengthBytes)),
    );
  }

  Future<void> destroyVaultKeys({required bool isDecoy}) async {
    await _ready();
    await _storage.delete(key: _pinEnvelopeKey(isDecoy));
    await _storage.delete(key: _saltKey(isDecoy));
    await _storage.delete(key: _kdfParamsKey(isDecoy));
    await disableBiometricUnlock(isDecoy: isDecoy);
  }

  // ---- Internals ----------------------------------------------------------

  Future<void> _sealWithPin({
    required Uint8List masterKey,
    required String pin,
    required bool isDecoy,
  }) async {
    await _ready();
    final salt = _randomBytes(_saltLengthBytes);
    final params = _KdfParams.defaults();

    final kek = await _deriveKek(pin: await SecretText.nfc(pin), salt: salt, params: params);
    final envelope = await _seal(masterKey, kek);

    await _storage.write(key: _saltKey(isDecoy), value: base64Encode(salt));
    await _storage.write(
      key: _kdfParamsKey(isDecoy),
      value: jsonEncode(params.toJson()),
    );
    await _storage.write(
      key: _pinEnvelopeKey(isDecoy),
      value: base64Encode(envelope),
    );
  }

  Future<_KdfParams> _readKdfParams(bool isDecoy) async {
    final raw = await _storage.read(key: _kdfParamsKey(isDecoy));
    if (raw == null) return _KdfParams.defaults();
    return _KdfParams.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Key derivations run, for tests that check every unlock costs the same.
  @visibleForTesting
  static int derivations = 0;

  Future<SecretKey> _deriveKek({
    required String pin,
    required List<int> salt,
    required _KdfParams params,
  }) async {
    derivations++;
    if (params.algorithm == _KdfAlgorithm.pbkdf2) {
      // WebCrypto handles this off the Dart thread already; wrapping it in
      // compute() would gain nothing and on web there is no isolate anyway.
      return Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: params.iterations,
        bits: keyLengthBytes * 8,
      ).deriveKeyFromPassword(password: pin, nonce: salt);
    }

    // Argon2id is CPU- and memory-bound and pure Dart, so it is pushed to a
    // background isolate: on the UI isolate it would freeze the unlock
    // animation for the whole derivation.
    final bytes = await compute(
      _deriveKekIsolate,
      _KekRequest(pin: pin, salt: salt, params: params),
    );
    return SecretKey(bytes);
  }

  Future<Uint8List> _seal(Uint8List plaintext, SecretKey kek) async {
    final algorithm = AesGcm.with256bits();
    final secretBox = await algorithm.encrypt(plaintext, secretKey: kek);

    return Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.mac.bytes,
      ...secretBox.cipherText,
    ]);
  }

  Future<Uint8List> _unseal(List<int> envelope, SecretKey kek) async {
    if (envelope.length <= _nonceLengthBytes + _macLengthBytes) {
      throw const FormatException('Key envelope is truncated.');
    }

    final algorithm = AesGcm.with256bits();
    final secretBox = SecretBox(
      envelope.sublist(_nonceLengthBytes + _macLengthBytes),
      nonce: envelope.sublist(0, _nonceLengthBytes),
      mac: Mac(envelope.sublist(
        _nonceLengthBytes,
        _nonceLengthBytes + _macLengthBytes,
      )),
    );

    return Uint8List.fromList(
      await algorithm.decrypt(secretBox, secretKey: kek),
    );
  }

  /// Key material, from the operating system's secure random source: the
  /// same one the rest of the app uses (vault_container.dart, noise).
  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}

enum _KdfAlgorithm { argon2id, pbkdf2 }

/// A vault's key was sealed by a newer version of Ringer Vault, with a key
/// function this version does not know.
class NewerVaultException implements Exception {
  const NewerVaultException();

  @override
  String toString() =>
      'This vault was set up by a newer version of Ringer Vault. Update the app to open it.';
}

class _KdfParams {
  final _KdfAlgorithm algorithm;
  final int memoryKib;
  final int iterations;
  final int parallelism;

  const _KdfParams({
    required this.algorithm,
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
  });

  /// Settings for a vault sealed on this platform right now.
  factory _KdfParams.defaults() {
    final algorithm = VaultKeyService._defaultAlgorithm;
    return _KdfParams(
      algorithm: algorithm,
      memoryKib: VaultKeyService._defaultMemoryKib,
      iterations: algorithm == _KdfAlgorithm.pbkdf2
          ? VaultKeyService._defaultWebIterations
          : VaultKeyService._defaultIterations,
      parallelism: VaultKeyService._defaultParallelism,
    );
  }

  Map<String, dynamic> toJson() => {
        'alg': algorithm.name,
        'm': memoryKib,
        't': iterations,
        'p': parallelism,
      };

  /// `alg` is absent on vaults sealed before the web path existed; those were
  /// all Argon2id. Any other name is a key function this version does not
  /// know: refused as newer, never guessed at (which would look like a
  /// wrong PIN, and count towards the lockout).
  factory _KdfParams.fromJson(Map<String, dynamic> json) {
    final name = json['alg'];
    final algorithm = name == null
        ? _KdfAlgorithm.argon2id
        : _KdfAlgorithm.values.where((a) => a.name == name).firstOrNull;
    if (algorithm == null) throw const NewerVaultException();
    return _KdfParams(
      algorithm: algorithm,
      memoryKib: json['m'] as int,
      iterations: json['t'] as int,
      parallelism: json['p'] as int,
    );
  }
}

class _KekRequest {
  final String pin;
  final List<int> salt;
  final _KdfParams params;

  const _KekRequest({
    required this.pin,
    required this.salt,
    required this.params,
  });
}

/// Top-level so it can cross an isolate boundary.
Future<List<int>> _deriveKekIsolate(_KekRequest request) async {
  final argon2 = Argon2id(
    memory: request.params.memoryKib,
    iterations: request.params.iterations,
    parallelism: request.params.parallelism,
    hashLength: VaultKeyService.keyLengthBytes,
  );

  final key = await argon2.deriveKeyFromPassword(
    password: request.pin,
    nonce: request.salt,
  );
  return key.extractBytes();
}
