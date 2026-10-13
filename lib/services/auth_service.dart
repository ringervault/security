import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';
import 'package:ringer_vault/services/activity_log_service.dart';
import 'package:ringer_vault/services/lockout_clock.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'dart:math';
import 'package:ringer_vault/repository/decoy_seed.dart';
import 'package:ringer_vault/services/vault_key_service.dart';
import 'package:ringer_vault/services/vault_session.dart';
import 'package:ringer_vault/utils/unlock_secret.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final _secureStorage = const FlutterSecureStorage();
  final _localAuth = LocalAuthentication();
  final _activityLog = ActivityLogService(); // Assume initialized or init async
  final _keys = VaultKeyService();

  // Storage Keys
  static const String _pinKey = 'user_pin';
  static const String _secondaryPinKey = 'secondary_pin';
  static const String _setupKey = 'is_setup_done';
  static const String _biometricKey = 'biometric_enabled';
  static const String _autoLockKey = 'auto_lock_duration';
  static const String _panicModeKey =
      'panic_mode_enabled'; // We might store this here or Settings

  // Lockout Keys
  static const String _failedAttemptsKey = 'failed_attempts';
  static const String _lockoutTimeKey = 'lockout_time';

  // State
  int autoLockDurationSeconds = 0; // 0 = Immediate
  DateTime? lastPausedTime;
  bool isDecoyMode = false;
  bool shouldAutoLock = true; // Defaults to true
  bool _isAuthenticated = false;

  /// Jobs running under [holdAutoLock]. A count rather than a flag, so two
  /// at once cannot switch auto-lock back on while one is still going.
  int _autoLockHolds = 0;

  /// Whether going to the background should lock (or suspend) the vault now.
  bool get autoLockAllowed => shouldAutoLock && _autoLockHolds == 0;

  /// Runs [job] without auto-lock firing if the app goes to the background
  /// meanwhile.
  ///
  /// For work the app itself sends the user out for: Google's account chooser
  /// and permission screens are other apps, so the app is in the background
  /// while they show. With auto-lock set to immediate, signing in to sync
  /// used to lock the vault halfway, the setup failed, and the user came
  /// back to a lock screen with sync not set up. Also held for a sync run,
  /// which must not have the vault closed under it while it writes.
  Future<T> holdAutoLock<T>(Future<T> Function() job) async {
    _autoLockHolds++;
    try {
      return await job();
    } finally {
      _autoLockHolds--;
    }
  }

  /// Which form the unlock secret takes. Cached because nearly every screen
  /// needs it to label a field or a sentence, and it is not itself a secret:
  /// the lock screen shows which kind of input it wants regardless.
  UnlockSecretType _secretType = UnlockSecretType.pin;

  bool get isAuthenticated => _isAuthenticated;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    autoLockDurationSeconds = prefs.getInt(_autoLockKey) ?? 0;
    await loadUnlockSecretType();

    // Hive only. The activity log is deliberately NOT opened here: obtaining
    // its key hits secure storage, which on Android runs on the platform main
    // thread and blocked the first frame for seconds. It opens lazily on
    // first use instead.
    await StorageService().init();
  }

  Future<bool> isSetupDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_setupKey) ?? false;
  }

  // Config setters
  Future<void> setAutoLockDuration(int seconds) async {
    autoLockDurationSeconds = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoLockKey, seconds);
  }

  Future<void> setPanicMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_panicModeKey, enabled);
  }

  Future<bool> isPanicModeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_panicModeKey) ?? false;
  }

  /// Every autofill now asks for the PIN or fingerprint. It used to be a
  /// setting, off by default, with one unlock covering fills for three
  /// minutes; this key is what that setting was stored under.
  static const String _autofillEveryTimeKey = 'autofill_unlock_every_time';
  static const String _autofillGateNoticeKey = 'autofill_gate_notice';

  /// True once, for someone who used autofill under the old three-minute
  /// window, so the main app can say it now asks every time. Never for a
  /// vault set up after the change, or for someone who already had it on.
  Future<bool> takeAutofillGateNotice() async {
    if (await _secureStorage.read(key: _autofillGateNoticeKey) != null) return false;
    final hadItOn = await _secureStorage.read(key: _autofillEveryTimeKey) == 'true';
    await _secureStorage.write(key: _autofillGateNoticeKey, value: 'shown');
    await _secureStorage.delete(key: _autofillEveryTimeKey);
    return !hadItOn;
  }

  /// Whether the autofill screen may ask a domain registry how new a site
  /// is (lib/autofill/domain_age.dart). Off until the user turns it on: it
  /// is the one check that tells someone else which site is open.
  static const String _siteAgeCheckKey = 'site_age_check';

  Future<bool> isSiteAgeCheckEnabled() async =>
      await _secureStorage.read(key: _siteAgeCheckKey) == 'true';

  Future<void> setSiteAgeCheck(bool enabled) =>
      _secureStorage.write(key: _siteAgeCheckKey, value: enabled ? 'true' : 'false');

  /// Whether the new-site check has been offered: asked once, the first
  /// time a login is filled or saved on a site it is not linked to, and
  /// never again whatever the answer (Settings keeps the switch). A device
  /// setting, the same in either vault, so it says nothing about which is
  /// open.
  static const String _siteAgeOfferedKey = 'site_age_check_offered';

  Future<bool> takeSiteAgeCheckOffer() async {
    if (await _secureStorage.read(key: _siteAgeOfferedKey) != null) return false;
    if (await isSiteAgeCheckEnabled()) return false;
    await _secureStorage.write(key: _siteAgeOfferedKey, value: 'asked');
    return true;
  }

  static const String _strictModeKey = 'strict_offline_mode';
  final _strictModeController = StreamController<bool>.broadcast();
  Stream<bool> get strictModeStream => _strictModeController.stream;

  // Cache for synchronous checks
  bool _strictModeCache = false;
  bool get isStrictOfflineModeCached => _strictModeCache;

  Future<void> setStrictOfflineMode(bool enabled) async {
    // Migrate: Write to SecureStorage
    await _secureStorage.write(key: _strictModeKey, value: enabled.toString());
    _strictModeCache = enabled;
    _strictModeController.add(enabled);
  }

  Future<bool> isStrictOfflineModeEnabled() async {
    // Read from SecureStorage
    final val = await _secureStorage.read(key: _strictModeKey);
    // Fallback to Prefs if not found (Migration)?
    if (val == null) {
      final prefs = await SharedPreferences.getInstance();
      final oldVal = prefs.getBool(_strictModeKey);
      if (oldVal != null) {
        // Auto-migrate
        await setStrictOfflineMode(oldVal);
        await prefs.remove(_strictModeKey);
        return oldVal;
      }
      return false;
    }

    final boolVal = val == 'true';
    _strictModeCache = boolVal;
    return boolVal;
  }

  void updateLastPausedTime() {
    // Only track pause time if we are currently authenticated
    if (_isAuthenticated) {
      lastPausedTime = DateTime.now();
    }
  }

  bool shouldLock() {
    // If not authenticated, we are already locked (or fresh start), so yes, we should be locked.
    // However, if we are already on LockScreen, pushing it again is handled by UI logic usually.
    // But for the sake of logic:
    if (!_isAuthenticated) return true;

    // If authenticated but no pause time recorded, we are active.
    if (lastPausedTime == null) return false;

    final diff = DateTime.now().difference(lastPausedTime!).inSeconds;
    if (diff >= autoLockDurationSeconds) {
      _isAuthenticated = false; // Session expired
      lastPausedTime = null;
      return true;
    }

    return false;
  }

  /// Length-independent, early-exit-free comparison, so that a wrong PIN takes
  /// the same time to reject regardless of how many leading digits are correct.
  bool _pinMatches(String? stored, String candidate) {
    if (stored == null ||
        stored.isEmpty ||
        stored == _disabledPin ||
        stored == _decoyConfigured) {
      return false;
    }

    final a = utf8.encode(stored);
    final b = utf8.encode(candidate);

    var diff = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Throws [AuthLockoutException] if a lockout is currently in force.
  Future<void> _assertNotLockedOut() async {
    final end = await _lockoutEnd();
    if (end != null) throw AuthLockoutException(end);
  }

  /// When the lockout in force ends, or null when there is none.
  ///
  /// An ended lockout is cleared, but the count of wrong attempts is not:
  /// only a correct unlock resets it. Otherwise waiting out each short
  /// lockout would start the count again, and the longer lockouts and
  /// self-destruct would never be reached.
  ///
  /// Timed on the time since boot (LockoutClock), so moving the phone's
  /// clock forward does not end it; after a restart it runs its full length
  /// again. A lockout written by an older version (a plain date) is timed
  /// on the wall clock.
  Future<DateTime?> _lockoutEnd() async {
    final stored = await _secureStorage.read(key: _lockoutTimeKey);
    if (stored == null) return null;
    final now = await LockoutClock.now();

    Map<String, dynamic>? record;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is Map) record = Map<String, dynamic>.from(decoded);
    } catch (_) {}

    if (record == null) {
      final end = DateTime.tryParse(stored);
      if (end != null && now.wall.isBefore(end)) return end;
      await _secureStorage.delete(key: _lockoutTimeKey);
      return null;
    }

    final lengthMs = record['ms'] as int? ?? 0;
    final elapsedEnd = record['elapsedEnd'] as int?;
    final boot = record['boot'] as int?;
    if (now.elapsedMs != null && elapsedEnd != null) {
      if (boot != now.boot) {
        // Restarted since: the time since boot started again, so the
        // lockout does too, in full.
        await _writeLockout(Duration(milliseconds: lengthMs), now);
        return now.wall.add(Duration(milliseconds: lengthMs));
      }
      final left = elapsedEnd - now.elapsedMs!;
      if (left > lengthMs) {
        // More left than the lockout's own length: the time since boot went
        // backwards, a restart on a phone that does not say which boot it
        // is. Run it again in full, as for a known restart, not for the
        // whole of the earlier uptime.
        await _writeLockout(Duration(milliseconds: lengthMs), now);
        return now.wall.add(Duration(milliseconds: lengthMs));
      }
      if (left > 0) return now.wall.add(Duration(milliseconds: left));
    } else {
      final end = DateTime.tryParse('${record['until']}');
      if (end != null && now.wall.isBefore(end)) return end;
    }
    await _secureStorage.delete(key: _lockoutTimeKey);
    return null;
  }

  Future<void> _writeLockout(Duration length, LockoutTime now) =>
      _secureStorage.write(
        key: _lockoutTimeKey,
        value: jsonEncode({
          'ms': length.inMilliseconds,
          'until': now.wall.add(length).toUtc().toIso8601String(),
          if (now.elapsedMs != null) 'elapsedEnd': now.elapsedMs! + length.inMilliseconds,
          if (now.boot != null) 'boot': now.boot,
        }),
      );

  static const String _disabledPin = '__DISABLED__';

  /// Shown whenever the real and decoy secrets would collide. One secret that
  /// opens both vaults would make the decoy pointless.
  String get _sameSecretMessage =>
      'Your vault and decoy cannot use the same ${_secretType.noun}.';

  /// Marker written in place of the old plaintext decoy PIN. Records that a
  /// decoy vault exists without storing anything that could open it.
  static const String _decoyConfigured = '__CONFIGURED__';

  // ---- Unlock secret type --------------------------------------------------

  static const String _secretTypeKey = 'unlock_secret_type';

  /// Whether the vault opens with a PIN or a password. Read from cache, which
  /// [init] fills before any screen is built.
  UnlockSecretType get unlockSecretType => _secretType;

  /// Re-reads the stored type. Lives in secure storage rather than
  /// preferences so it cannot drift away from the key envelopes it describes.
  Future<UnlockSecretType> loadUnlockSecretType() async {
    _secretType = UnlockSecretTypeInfo.fromStorage(
      await _secureStorage.read(key: _secretTypeKey),
    );
    return _secretType;
  }

  Future<void> _storeUnlockSecretType(UnlockSecretType type) async {
    _secretType = type;
    await _secureStorage.write(key: _secretTypeKey, value: type.storageValue);
  }

  /// Switches between PIN and password, re-sealing the real vault under
  /// [secret].
  ///
  /// A decoy vault must move to the new form in the same step. Leaving a
  /// 6-digit decoy behind a password-protected real vault would make the two
  /// tell-ably different, and would leave one of them guessable in minutes,
  /// so [decoySecret] is required whenever a decoy is configured. The decoy is
  /// replaced rather than re-sealed: re-sealing needs the old decoy secret,
  /// and no one should have to remember it to change their own password.
  Future<void> switchUnlockSecretType({
    required UnlockSecretType type,
    required String secret,
    String? decoySecret,
  }) async {
    final hasDecoy = await isSecondaryPinSet();
    if (hasDecoy && (decoySecret == null || decoySecret.isEmpty)) {
      throw StateError('A decoy vault exists and needs a new secret too.');
    }
    if (hasDecoy && decoySecret == secret) {
      throw Exception(_sameSecretMessage);
    }

    // Both proposed secrets are checked before anything is written, so a
    // rejection leaves the vault exactly as it was.
    for (final candidate in [secret, if (hasDecoy) decoySecret!]) {
      final problem = validateUnlockSecret(candidate, type);
      if (problem != null) throw WeakSecretException(problem);
    }

    // The old decoy goes first, deliberately. Every later step can fail, and
    // the one state that must never exist is a decoy in the old form behind a
    // real vault in the new one: it would be guessable in minutes and
    // tell-ably different from the real vault. Losing the decoy is recoverable
    // and obvious; a mismatched decoy is neither.
    if (hasDecoy) await setSecondaryPin(_disabledPin);

    await setPin(secret, type: type);
    if (hasDecoy) await setSecondaryPin(decoySecret!);
  }

  // PIN Management

  /// Establishes the primary PIN.
  ///
  /// On first setup this mints the vault's master key. On a later change it
  /// re-wraps the key already in use, so vault contents are untouched and any
  /// enrolled biometric envelope stays valid.
  /// [type] is passed only when the form of the secret is being chosen or
  /// changed; omitted, the current type stands.
  Future<void> setPin(String pin, {UnlockSecretType? type}) async {
    final effectiveType = type ?? _secretType;

    // Defence in depth. Every caller validates before reaching here, but this
    // value becomes the key, and a weak one accepted once stays weak until
    // the user happens to change it.
    final problem = validateUnlockSecret(pin, effectiveType);
    if (problem != null) throw WeakSecretException(problem);

    // Changing the form has to take the decoy with it, which is more than
    // this method does. Route callers to the one place that handles both.
    if (type != null && type != _secretType && await isSecondaryPinSet()) {
      throw StateError(
        'Use switchUnlockSecretType: the decoy vault has to move too.',
      );
    }

    if (await isSecondaryPin(pin)) {
      throw Exception(_sameSecretMessage);
    }

    // Recorded before the re-seal, not after. If the app dies between the
    // two, a stored form of "password" in front of an envelope still holding
    // a PIN is harmless: the text field accepts digits. The other order can
    // leave a keypad in front of a password, which cannot be typed at all.
    if (type != null) await _storeUnlockSecretType(type);

    final existingKey = StorageService().activeMasterKey;
    if (existingKey != null && !isDecoyMode) {
      await _keys.changePin(
        masterKey: existingKey,
        newPin: pin,
        isDecoy: false,
      );
    } else if (await _keys.hasPinEnvelope(isDecoy: false)) {
      // A vault already exists but is not open, so there is no master key to
      // re-seal. Minting a new one here would leave every entry encrypted
      // under a key nothing can produce again, which reads as the vault
      // silently emptying itself. Changing the secret requires it to be open.
      throw StateError('Unlock the vault before changing its secret.');
    } else {
      final masterKey = await _keys.createVault(pin: pin, isDecoy: false);
      await StorageService().openVault(masterKey: masterKey, isDecoy: false);
      _isAuthenticated = true;
    }

    // The plaintext PIN from the pre-envelope format is now dead weight.
    await _secureStorage.delete(key: _pinKey);
    await _recordPinChanged();
    await _resetLockout();
  }

  /// Changes the decoy's own unlock secret, from inside the decoy, keeping
  /// its contents: its master key is re-sealed under [secret], exactly as
  /// [setPin] does for the real vault. Nothing outside the decoy's slot and
  /// its own key records is touched.
  ///
  /// It must never equal the real vault's secret. The refusal reads like
  /// any other unusable secret and counts as a failed unlock (towards the
  /// lockout, never a self-destruct), so this is no better a way to test
  /// guesses at the real secret than the lock screen.
  Future<void> changeDecoySecret(String secret) async {
    if (!isDecoyMode || !StorageService().isReady) {
      throw StateError('Only the open decoy changes its own secret.');
    }
    final problem = validateUnlockSecret(secret, _secretType);
    if (problem != null) throw WeakSecretException(problem);
    if (await isPrimaryPin(secret)) {
      await _onFailure(mayDestroy: false);
      throw WeakSecretException(unusableSecretMessage(_secretType));
    }
    final key = StorageService().activeMasterKey;
    if (key == null) throw StateError('Unlock the vault before changing its secret.');
    await _keys.changePin(masterKey: key, newPin: secret, isDecoy: true);
  }

  /// Whether [pin] opens the real vault. Used to stop the decoy PIN being set
  /// to the same value as the primary.
  Future<bool> isPrimaryPin(String pin) async {
    if (await _keys.hasPinEnvelope(isDecoy: false)) {
      return await _keys.unlockWithPin(pin: pin, isDecoy: false) != null;
    }
    return _pinMatches(await _secureStorage.read(key: _pinKey), pin);
  }

  /// Establishes the decoy PIN, minting a master key that is independent of
  /// the real vault's. Passing [_disabledPin] tears the decoy vault down.
  Future<void> setSecondaryPin(String pin) async {
    if (pin == _disabledPin || pin.isEmpty) {
      await _keys.destroyVaultKeys(isDecoy: true);
      await _keys.ensureDecoyStandIn();
      await _discardDecoyData();
      await _secureStorage.delete(key: _secondaryPinKey);
      if (StorageService().isReady) await StorageService().setHasDecoy(false);
      return;
    }

    final problem = validateUnlockSecret(pin, _secretType);
    if (problem != null) throw WeakSecretException(problem);

    if (await isPrimaryPin(pin)) {
      throw Exception(_sameSecretMessage);
    }

    // A fresh master key is minted below, which leaves anything already in the
    // decoy vault encrypted under a key that no longer exists anywhere. Clear
    // it rather than leave unopenable junk on disk. Callers warn the user
    // first: this is data loss, and it used to happen silently.
    await _discardDecoyData();

    _newDecoyKey = await _keys.createVault(pin: pin, isDecoy: true);
    // Recorded inside the real vault, which is open here: the UI needs to
    // know a decoy exists, and nothing outside the real vault may say so.
    await StorageService().setHasDecoy(true);
  }

  /// The key of a decoy created a moment ago, until [fillNewDecoy] uses it.
  /// In memory only, and dropped when the vault locks.
  Uint8List? _newDecoyKey;

  /// Fills the decoy just created with believable entries carrying
  /// [identity], straight into its part of the vault file. Nothing about
  /// the decoy (not the name it should show) is kept anywhere else waiting
  /// for it to be opened.
  Future<void> fillNewDecoy(DecoyIdentity identity) async {
    final key = _newDecoyKey;
    _newDecoyKey = null;
    if (key == null) return;
    await StorageService().seedVault(
      masterKey: key,
      isDecoy: true,
      entries: buildDecoyEntries(identity, Random.secure()),
    );
  }

  /// Removes the decoy vault's contents and its log. Never touches the real
  /// vault, and safe to call while the real vault is open.
  Future<void> _discardDecoyData() async {
    // Its log goes with it: it is kept in the vault's own slot.
    await StorageService().destroyVault(isDecoy: true);
  }

  /// With the real vault just opened: moves "a decoy exists" from the
  /// readable marker it used to be into the real vault, and gives the
  /// decoy's key records a stand-in when there is no decoy, so their
  /// presence says nothing either. Not while an old-format decoy is still
  /// waiting to be converted, which needs the marker and the old key.
  ///
  /// The decoy's unlock reads the same records without acting on them
  /// ([act] false), so the two take the same time.
  Future<void> _hideDecoyTraces({required bool act}) async {
    if (!StorageService().isReady) return;
    final marker = await _secureStorage.read(key: _secondaryPinKey);
    final legacyPending =
        await _secureStorage.read(key: VaultKeyService.legacyMasterKeyKey) != null;
    final hasStandIn = await _keys.hasPinEnvelope(isDecoy: true);
    if (!act) return;
    if (marker == _decoyConfigured) {
      await StorageService().setHasDecoy(true);
      await _secureStorage.delete(key: _secondaryPinKey);
    } else if (marker == _disabledPin) {
      await _secureStorage.delete(key: _secondaryPinKey);
    }
    if (!legacyPending && !hasStandIn) await _keys.ensureDecoyStandIn();
  }

  Future<bool> isSecondaryPin(String pin) async {
    if (await _keys.hasPinEnvelope(isDecoy: true)) {
      return await _keys.unlockWithPin(pin: pin, isDecoy: true) != null;
    }
    return _pinMatches(await _secureStorage.read(key: _secondaryPinKey), pin);
  }

  /// Whether a decoy exists, as the real vault records it. False with the
  /// decoy open or no vault open: nothing else knows.
  Future<bool> isSecondaryPinSet() async {
    if (isDecoyMode || !StorageService().isReady) return false;
    return StorageService().hasDecoy;
  }

  /// Unlocks the app from a locked state. Accepts either the primary or the
  /// decoy PIN and switches the open vault to match.
  ///
  /// This is for the lock screen ONLY. Anything happening inside an already
  /// unlocked session must use [verifyPinForReAuth] instead: otherwise
  /// entering the decoy PIN at a re-auth prompt would swap the open box out
  /// from under the UI.
  Future<bool> verifyPin(String pin, {bool logSuccess = true}) async {
    await _assertNotLockedOut();

    // Both vaults are tried every time, whatever the PIN and whether or not
    // a decoy exists, before either is opened: the real PIN, the decoy PIN,
    // a wrong one, and "there is no decoy" all cost the same two key
    // derivations (unlockWithPin does the work even with nothing to open),
    // so the time a PIN takes says nothing about which it was. Real first
    // when both open, the pathological case setPin and setSecondaryPin
    // both refuse to create.
    // Side by side, each on its own isolate: the same two derivations, in
    // the time of one. One after the other on a phone short of memory,
    // where two at once could get the app ended mid-unlock; every attempt
    // on that phone is then equally slow, so it says nothing either.
    final Uint8List? real, decoy;
    if (await VaultSession.lowMemory()) {
      real = await _keys.unlockWithPin(pin: pin, isDecoy: false);
      decoy = await _keys.unlockWithPin(pin: pin, isDecoy: true);
    } else {
      try {
        (real, decoy) = await (
          _keys.unlockWithPin(pin: pin, isDecoy: false),
          _keys.unlockWithPin(pin: pin, isDecoy: true),
        ).wait;
      } on ParallelWaitError<(Uint8List?, Uint8List?), (AsyncError?, AsyncError?)> catch (e) {
        // The error itself, as the one-after-the-other path would give it,
        // so callers can tell "newer version" from anything else.
        final (a, b) = e.errors;
        final first = (a ?? b)!;
        Error.throwWithStackTrace(first.error, first.stackTrace);
      }
    }
    for (final (masterKey, isDecoy) in [(real, false), (decoy, true)]) {
      if (masterKey == null) continue;
      await StorageService().openVault(masterKey: masterKey, isDecoy: isDecoy);
      await _onSuccess(isDecoy: isDecoy, byPin: true, logSuccess: logSuccess);
      return true;
    }

    // Vault predates the key envelopes: verify against the stored plaintext
    // PIN this once, then convert.
    if (await _migrateLegacyVault(pin, logSuccess: logSuccess)) return true;

    await _onFailure();
    return false;
  }

  /// Unlocks with biometrics, recovering the master key from the OS-gated
  /// envelope rather than from the PIN.
  Future<bool> unlockWithBiometric() async {
    if (!await canOfferFingerprint()) return false;

    // Present the prompt explicitly. Marking the keystore entry
    // user-authentication-required hardens it at rest, but
    // flutter_secure_storage does not itself raise a BiometricPrompt on read: // so without this the envelope could be fetched, and the vault opened,
    // with no authentication at all.
    if (!await _promptBiometric('Unlock Ringer Vault')) return false;

    final masterKey = await _keys.unlockWithBiometric(isDecoy: false);
    if (masterKey == null) return false;

    await StorageService().openVault(masterKey: masterKey, isDecoy: false);
    await _onSuccess(isDecoy: false, byPin: false, logSuccess: true);
    return true;
  }

  /// Converts a pre-envelope vault on the first successful unlock after
  /// upgrading.
  ///
  /// The real vault keeps the master key it already has: only how that key is
  /// stored changes, so no entry is ever re-encrypted and there is no window
  /// where data could be lost. The decoy is different: it previously shared
  /// the real vault's key, which meant it offered no cryptographic separation
  /// at all, so it is re-keyed onto a key of its own. That is safe to do here
  /// because it is the smaller vault and we hold both keys at this moment.
  Future<bool> _migrateLegacyVault(
    String pin, {
    required bool logSuccess,
  }) async {
    final legacyKeyB64 = await _secureStorage.read(
      key: VaultKeyService.legacyMasterKeyKey,
    );
    if (legacyKeyB64 == null) return false;

    final legacyKey = Uint8List.fromList(base64Url.decode(legacyKeyB64));
    final legacyPrimary = await _secureStorage.read(key: _pinKey);
    final legacySecondary = await _secureStorage.read(key: _secondaryPinKey);

    final isPrimary = _pinMatches(legacyPrimary, pin);
    final isSecondary = !isPrimary && _pinMatches(legacySecondary, pin);
    if (!isPrimary && !isSecondary) return false;

    if (isPrimary) {
      await _keys.adoptExistingKey(
        masterKey: legacyKey,
        pin: pin,
        isDecoy: false,
      );
      await StorageService().openVault(masterKey: legacyKey, isDecoy: false);
      await _secureStorage.delete(key: _pinKey);
    } else {
      final freshKey = await _keys.createVault(pin: pin, isDecoy: true);
      await StorageService().rekeyVault(
        currentMasterKey: legacyKey,
        newMasterKey: freshKey,
        isDecoy: true,
      );
      await _secureStorage.write(
        key: _secondaryPinKey,
        value: _decoyConfigured,
      );
    }

    // The plaintext master key is what made the PIN cosmetic. It goes last, so
    // an interruption mid-migration leaves the old path still working.
    final primaryDone = await _keys.hasPinEnvelope(isDecoy: false);
    final decoyPending =
        legacySecondary != null &&
        legacySecondary != _disabledPin &&
        !await _keys.hasPinEnvelope(isDecoy: true);
    if (primaryDone && !decoyPending) {
      await _secureStorage.delete(key: VaultKeyService.legacyMasterKeyKey);
    }

    await _onSuccess(isDecoy: isSecondary, byPin: true, logSuccess: logSuccess);
    await _activityLog.logActivity(
      action: 'Vault Key Upgraded',
      details: 'Master key re-sealed under secret-derived encryption',
    );
    return true;
  }

  /// Re-authenticates inside an already-unlocked session, for gates such as
  /// revealing a password, deleting an entry, or export/import.
  ///
  /// Accepts ONLY the PIN belonging to the vault that is currently open, and
  /// never switches vault mode. Matching against the active mode (rather than
  /// always demanding the primary PIN) is deliberate: requiring the real PIN
  /// while the decoy vault is open would prove a real vault exists, which is
  /// exactly what the decoy is there to conceal.
  Future<bool> verifyPinForReAuth(String pin) async {
    await _assertNotLockedOut();

    if (await _keys.hasPinEnvelope(isDecoy: isDecoyMode)) {
      // Opening the envelope IS the check: a wrong PIN fails the GCM tag.
      // The recovered key is discarded; the vault is already open.
      if (await _keys.unlockWithPin(pin: pin, isDecoy: isDecoyMode) != null) {
        await _resetLockout();
        return true;
      }
    } else {
      // Vault not yet migrated: fall back to the plaintext PIN.
      final legacyKey = isDecoyMode ? _secondaryPinKey : _pinKey;
      if (_pinMatches(await _secureStorage.read(key: legacyKey), pin)) {
        await _resetLockout();
        return true;
      }
    }

    await _onFailure();
    return false;
  }

  /// When the lockout in force ends, for the lock screen's countdown.
  Future<DateTime?> getLockoutTime() => _lockoutEnd();

  Future<void> _onSuccess({
    required bool isDecoy,
    required bool byPin,
    bool logSuccess = true,
  }) async {
    await _resetLockout();
    isDecoyMode = isDecoy;
    _isAuthenticated = true; // Mark session as active
    lastPausedTime = null; // Clear pause time
    await _hideDecoyTraces(act: !isDecoy);
    await VaultSession.unlocked(decoy: isDecoy, byPin: byPin);

    // The vault is opened by the caller, which is the only place the master
    // key exists. Its log comes with it: the log is kept in the vault.

    if (logSuccess) {
      await _activityLog.logActivity(
        action: isDecoy ? 'Decoy Vault Access' : 'Vault Unlocked',
        details: isDecoy
            ? 'Secondary secret accepted'
            : 'Primary secret accepted',
      );
    }
  }

  /// [mayDestroy] false: counts towards the lockout, never towards a
  /// self-destruct. For a failure inside the decoy, which must never be
  /// able to wipe the real vault.
  Future<void> _onFailure({bool mayDestroy = true}) async {
    int attempts = int.parse(
      await _secureStorage.read(key: _failedAttemptsKey) ?? '0',
    );
    attempts++;
    await _secureStorage.write(
      key: _failedAttemptsKey,
      value: attempts.toString(),
    );

    await _activityLog.logActivity(
      action: 'Auth Failure',
      details: 'Incorrect unlock attempt: $attempts',
      isFailure: true,
      // No vault is open yet, and this reveals nothing about which exist.
      scope: LogScope.security,
    );

    // Self-destruct is checked before the lockout escalation, otherwise the
    // lockout throws first and the threshold could never be reached.
    if (mayDestroy && await isSelfDestructEnabled()) {
      final threshold = await selfDestructThreshold();
      if (attempts >= threshold) {
        await _detonate();
        throw VaultDestroyedException();
      }
    }

    final lockDuration = lockoutAfter(attempts);
    if (lockDuration != null) {
      final now = await LockoutClock.now();
      await _writeLockout(lockDuration, now);
      throw AuthLockoutException(now.wall.add(lockDuration));
    }
  }

  /// How long unlocking is refused after [attempts] wrong ones in a row:
  /// nothing for the first four, then 30 seconds, 5 minutes from the tenth,
  /// 15 from the fifteenth and an hour from the twentieth. The count goes
  /// back to zero only on a correct unlock.
  @visibleForTesting
  static Duration? lockoutAfter(int attempts) {
    if (attempts >= 20) return const Duration(hours: 1);
    if (attempts >= 15) return const Duration(minutes: 15);
    if (attempts >= 10) return const Duration(minutes: 5);
    if (attempts >= 5) return const Duration(seconds: 30);
    return null;
  }

  /// Clears the cooling-off period without clearing the failure count, so a
  /// test can drive attempts past the lockout to reach a destruct threshold.
  @visibleForTesting
  Future<void> eraseLockoutForTest() async {
    await _secureStorage.delete(key: _lockoutTimeKey);
  }

  Future<void> _resetLockout() async {
    await _secureStorage.delete(key: _lockoutTimeKey);
    await _secureStorage.delete(key: _failedAttemptsKey);
  }

  Future<void> completeSetup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_setupKey, true);
    // A new vault never knew the three-minute window, so nothing to tell.
    await _secureStorage.write(key: _autofillGateNoticeKey, value: 'shown');
  }

  // Biometrics

  /// Shows the OS biometric prompt. Returns true only on a positive match.
  ///
  /// Never touches session state, the vault mode, or the PIN failure counter.
  /// Biometric throttling is the operating system's job: it locks the sensor
  /// out after its own run of bad reads. Feeding results back into our PIN
  /// counter would double-count real failures and, worse, would treat a user
  /// tapping "Cancel" as an attack.
  Future<bool> _promptBiometric(String reason) async {
    try {
      final isAvailable = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();

      if (!isAvailable || !isDeviceSupported) return false;

      // Suspend auto-lock: the OS prompt pauses our activity, which would
      // otherwise trip the lifecycle observer and lock the app behind us.
      shouldAutoLock = false;

      return await _localAuth.authenticate(
        localizedReason: reason,
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: 'Authenticate to Ringer Vault',
            cancelButton: 'Cancel',
          ),
          IOSAuthMessages(cancelButton: 'Cancel'),
        ],
        options: const AuthenticationOptions(
          stickyAuth: true,
          // Must stay true. With biometricOnly: false the OS offers the device
          // PIN/pattern as a fallback, which would let the phone's lock-screen
          // code open the vault: a different secret from the vault PIN, and
          // one that is frequently shoulder-surfed or shared.
          biometricOnly: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException catch (e) {
      // Includes the OS's own biometric lockout. Surface it, don't escalate it.
      await _activityLog.logActivity(
        action: 'Biometric Error',
        details: e.message,
        isFailure: true,
        scope: LogScope.security,
      );
      return false;
    } catch (_) {
      return false;
    } finally {
      shouldAutoLock = true;
    }
  }

  /// Unlocks the app from a locked state using biometrics.
  ///
  /// Prefers the key envelope, which is what makes biometric unlock possible
  /// at all now that the vault key is not stored in the open. Falls back to a
  /// bare prompt only for a not-yet-migrated vault, where the legacy key is
  /// still readable without the PIN.
  Future<bool> authenticate({
    bool force = false,
    bool logSuccess = true,
  }) async {
    if (!force && !await isBiometricEnabled()) return false;
    // Not before the real vault's PIN in this run of the app, nor after the
    // decoy: see canOfferFingerprint. Here too, not only in the screens.
    if (!await VaultSession.fingerprintAllowed()) return false;

    if (await _keys.hasBiometricEnvelope(isDecoy: false)) {
      return unlockWithBiometric();
    }

    final success = await _promptBiometric('Scan fingerprint to authenticate');
    if (!success) return false;

    // Legacy path: the master key is still recoverable without a PIN.
    final legacyKeyB64 = await _secureStorage.read(
      key: VaultKeyService.legacyMasterKeyKey,
    );
    if (legacyKeyB64 == null) return false;

    await StorageService().openVault(
      masterKey: Uint8List.fromList(base64Url.decode(legacyKeyB64)),
      isDecoy: false,
    );
    await _onSuccess(isDecoy: false, byPin: false, logSuccess: logSuccess);
    return true;
  }

  /// Biometric re-authentication inside an already-unlocked session.
  ///
  /// Verifies the user without starting a new session or changing which vault
  /// is open. [authenticate] must not be used for this: it hardcodes
  /// `isDecoy: false`, so passing a fingerprint at a re-auth gate while the
  /// decoy vault was open would silently swap in the real vault: exactly the
  /// disclosure the decoy exists to prevent.
  Future<bool> authenticateForReAuth(String reason) async {
    if (!await isBiometricEnabled()) return false;
    return _promptBiometric(reason);
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    await _secureStorage.write(key: _biometricKey, value: enabled.toString());
    if (!enabled) {
      await _keys.disableBiometricUnlock(isDecoy: false);
      await _activityLog.logActivity(action: 'Biometrics Disabled');
    } else {
      await _activityLog.logActivity(action: 'Biometrics Enabled');
    }
  }

  /// Whether to offer the fingerprint to unlock, on the lock screen or at a
  /// fill: turned on, and the real vault's PIN entered in this run of the
  /// app with no decoy opened since (VaultSession). A fresh start asks for
  /// the PIN first, as Android does after a restart.
  Future<bool> canOfferFingerprint() async =>
      await isBiometricEnabled() && await VaultSession.fingerprintAllowed();

  Future<bool> isBiometricEnabled() async {
    final val = await _secureStorage.read(key: _biometricKey);
    return val == 'true';
  }

  /// What this device can actually authenticate with, so the UI stops
  /// promising "Face ID" on hardware that only has a fingerprint reader.
  Future<BiometricKind> availableBiometricKind() async {
    try {
      if (!await _localAuth.isDeviceSupported()) return BiometricKind.none;

      final types = await _localAuth.getAvailableBiometrics();
      if (types.isEmpty) return BiometricKind.none;

      final hasFace =
          types.contains(BiometricType.face) ||
          types.contains(BiometricType.strong) &&
              defaultTargetPlatform == TargetPlatform.iOS &&
              types.contains(BiometricType.face);
      final hasFingerprint = types.contains(BiometricType.fingerprint);

      if (hasFace && hasFingerprint) return BiometricKind.both;
      if (hasFace) return BiometricKind.face;
      if (hasFingerprint) return BiometricKind.fingerprint;

      // `strong`/`weak` without a specific type: Android often reports this.
      return BiometricKind.generic;
    } catch (_) {
      return BiometricKind.none;
    }
  }

  /// Enrols biometric unlock.
  ///
  /// Requires an open real vault, because enrolling means handing the OS a
  /// copy of the master key to hold behind a biometric gate, and the master
  /// key only exists once the PIN has produced it. Enrolling from the decoy
  /// vault is refused: the biometric envelope unlocks the real vault, so
  /// allowing it there would let someone holding only the decoy PIN arrange
  /// real-vault access.
  Future<bool> enableBiometric() async {
    if (isDecoyMode) return false;

    final masterKey = StorageService().activeMasterKey;
    if (masterKey == null) return false;

    // Confirm the sensor works before committing to it.
    if (!await _promptBiometric('Confirm your identity to enable unlock')) {
      return false;
    }

    final stored = await _keys.enableBiometricUnlock(
      masterKey: masterKey,
      isDecoy: false,
    );
    if (!stored) return false;

    await setBiometricEnabled(true);
    return true;
  }

  // ---- PIN age -------------------------------------------------------------

  static const String _pinChangedAtKey = 'pin_changed_at';

  /// When the primary PIN was last set, or null if never recorded.
  Future<DateTime?> pinLastChangedAt() async {
    final raw = await _secureStorage.read(key: _pinChangedAtKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> _recordPinChanged() async {
    await _secureStorage.write(
      key: _pinChangedAtKey,
      value: DateTime.now().toIso8601String(),
    );
  }

  // ---- Verification mode ---------------------------------------------------

  static const String _verificationModeKey = 'verification_mode';

  /// What a sensitive action inside an unlocked session must satisfy.
  Future<VerificationMode> verificationMode() async {
    final raw = await _secureStorage.read(key: _verificationModeKey);
    return VerificationMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => VerificationMode.either,
    );
  }

  Future<void> setVerificationMode(VerificationMode mode) async {
    await _secureStorage.write(key: _verificationModeKey, value: mode.name);
    await _activityLog.logActivity(
      action: 'Security Setting Changed',
      details: 'Verification mode: ${mode.labelFor(_secretType)}',
    );
  }

  // ---- Self-destruct -------------------------------------------------------

  static const String _selfDestructKey = 'self_destruct_enabled';
  static const String _selfDestructThresholdKey = 'self_destruct_threshold';

  /// Selectable thresholds. All sit well above the 10-failure lockout so a
  /// forgetful owner hits the cooling-off period long before the wipe.
  static const List<int> selfDestructChoices = [15, 20, 25, 30];
  static const int defaultSelfDestructThreshold = 20;

  Future<bool> isSelfDestructEnabled() async =>
      await _secureStorage.read(key: _selfDestructKey) == 'true';

  Future<int> selfDestructThreshold() async {
    final raw = await _secureStorage.read(key: _selfDestructThresholdKey);
    return int.tryParse(raw ?? '') ?? defaultSelfDestructThreshold;
  }

  Future<void> setSelfDestruct({required bool enabled, int? threshold}) async {
    await _secureStorage.write(
      key: _selfDestructKey,
      value: enabled.toString(),
    );
    if (threshold != null) {
      await _secureStorage.write(
        key: _selfDestructThresholdKey,
        value: threshold.toString(),
      );
    }
    await _activityLog.logActivity(
      action: 'Security Setting Changed',
      details: enabled
          ? 'Self-destruct armed after ${threshold ?? await selfDestructThreshold()} failures'
          : 'Self-destruct disarmed',
    );
  }

  /// Failed attempts recorded since the last success.
  Future<int> failedAttempts() async =>
      int.tryParse(await _secureStorage.read(key: _failedAttemptsKey) ?? '') ??
      0;

  /// Attempts left before the vault is destroyed, or null when disarmed.
  ///
  /// Surfaced on the lock screen only as the count gets low: a running total
  /// from the first failure would hand an attacker a precise probing budget,
  /// while saying nothing at all would let an owner erase their own vault by
  /// accident.
  Future<int?> attemptsBeforeDestruction() async {
    if (!await isSelfDestructEnabled()) return null;
    final remaining = await selfDestructThreshold() - await failedAttempts();
    return remaining < 0 ? 0 : remaining;
  }

  /// Irreversibly destroys both vaults and every key that could open them.
  Future<void> _detonate() async {
    await _activityLog.logActivity(
      action: 'Vault Destroyed',
      details: 'Self-destruct threshold reached',
      isFailure: true,
      scope: LogScope.security,
    );
    await _wipeDevice();
  }

  /// "Remove data from this phone": the same wipe, asked for on purpose,
  /// leaving the app as it was when first installed.
  ///
  /// Sync must already be logged out (SyncService.logOut) before this runs.
  /// That forgets the sync marks without touching Drive, so nothing here can
  /// ever reach the backup as a deletion.
  Future<void> removeFromThisDevice() async {
    for (final callback in List.of(onLock)) {
      callback();
    }
    await _wipeDevice();
  }

  Future<void> _wipeDevice() async {
    // Keys first: if this is interrupted, the data left behind is already
    // unopenable rather than merely deleted.
    await _keys.destroyVaultKeys(isDecoy: false);
    await _keys.destroyVaultKeys(isDecoy: true);
    await _secureStorage.delete(key: VaultKeyService.legacyMasterKeyKey);

    await StorageService().destroyAllVaults();

    await _secureStorage.delete(key: _pinKey);
    await _secureStorage.delete(key: _secondaryPinKey);
    await _secureStorage.delete(key: _biometricKey);
    await _secureStorage.delete(key: _secretTypeKey);
    _secretType = UnlockSecretType.pin;
    await _resetLockout();

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    _isAuthenticated = false;
    isDecoyMode = false;
  }

  /// Proves the person holding the phone is its owner, using the OS lock
  /// screen (biometric or device passcode).
  ///
  /// This is the one place device credentials are the right check. Everywhere
  /// else the device PIN is explicitly NOT accepted, because it is a different
  /// secret from the vault PIN. But "forgot my PIN" means the vault PIN is
  /// unavailable by definition, so device ownership is the only proof left: /// and without some proof, anyone who picks up an unlocked phone can destroy
  /// the vault in two taps.
  ///
  /// Returns false when the device has no lock screen at all; callers must
  /// then fall back to something else rather than proceeding.
  Future<DeviceOwnerCheck> confirmDeviceOwner(String reason) async {
    try {
      if (!await _localAuth.isDeviceSupported()) {
        return DeviceOwnerCheck.unavailable;
      }

      shouldAutoLock = false;
      final ok = await _localAuth.authenticate(
        localizedReason: reason,
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: 'Confirm it is your device',
            cancelButton: 'Cancel',
          ),
          IOSAuthMessages(cancelButton: 'Cancel'),
        ],
        options: const AuthenticationOptions(
          stickyAuth: true,
          // Deliberately allows the device passcode here: see above.
          biometricOnly: false,
          useErrorDialogs: true,
        ),
      );
      return ok ? DeviceOwnerCheck.confirmed : DeviceOwnerCheck.refused;
    } on PlatformException {
      return DeviceOwnerCheck.unavailable;
    } catch (_) {
      return DeviceOwnerCheck.unavailable;
    } finally {
      shouldAutoLock = true;
    }
  }

  /// User-initiated wipe from the "forgot PIN" sheet. Same destruction, but
  /// logged as a deliberate act rather than an attack.
  Future<void> eraseVault() async {
    await _detonate();
    await _activityLog.logActivity(
      action: 'Vault Erased',
      details: 'Reset from the lock screen',
      scope: LogScope.security,
    );
  }

  static const String _importedHashesKey = 'imported_hashes';

  /// How many import hashes to remember. Without a bound this list grows
  /// forever; 200 is far beyond any realistic restore history.
  static const int _maxRememberedImports = 200;

  /// Backup fingerprints live in secure storage rather than SharedPreferences.
  /// In prefs they were world-readable on a compromised device and trivially
  /// editable, which made the once-only import rule advisory at best.
  Future<List<String>> _importedHashes() async {
    final raw = await _secureStorage.read(key: _importedHashesKey);
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',');
  }

  Future<bool> isImportHashUsed(String hash) async =>
      (await _importedHashes()).contains(hash);

  Future<void> markImportHashUsed(String hash) async {
    final hashes = await _importedHashes()
      ..add(hash);

    // Keep the most recent entries.
    final trimmed = hashes.length > _maxRememberedImports
        ? hashes.sublist(hashes.length - _maxRememberedImports)
        : hashes;

    await _secureStorage.write(
      key: _importedHashesKey,
      value: trimmed.join(','),
    );
  }

  /// Run whenever the session ends, however it ends: timeout, panic lock,
  /// manual lock, or switching vaults. Anything holding secrets derived for
  /// the session (the sync key, for one) registers here to drop them.
  static final List<void Function()> onLock = [];

  Future<void> logout() async {
    for (final callback in List.of(onLock)) {
      callback();
    }
    final wasOpen = _isAuthenticated;
    _isAuthenticated = false;
    isDecoyMode = false;
    lastPausedTime = null;
    _newDecoyKey = null;
    // Only a vault that was open locks. Logging out an already locked one
    // is tidying up (the autofill screen does it after every fill), and
    // must not drop the login just kept for the next page of a sign-in.
    if (wasOpen) await VaultSession.locked();
    // The vault's log is inside it, so closing the vault closes the log too,
    // and the next session, which may be the other vault, cannot read it.
    await StorageService().close();
  }
}

/// Thrown when a proposed unlock secret fails the rules in
/// [validateUnlockSecret]. Carries wording meant for the person typing.
class WeakSecretException implements Exception {
  final String message;
  WeakSecretException(this.message);

  @override
  String toString() => message;
}

class AuthLockoutException implements Exception {
  final DateTime unlockTime;
  AuthLockoutException(this.unlockTime);

  int get remainingSeconds => unlockTime.difference(DateTime.now()).inSeconds;
}

/// Which biometric hardware is actually enrolled on this device.
enum BiometricKind { none, fingerprint, face, both, generic }

extension BiometricKindLabels on BiometricKind {
  /// Name for the modality, e.g. "Face ID": used in prompts and settings.
  String get label => switch (this) {
    BiometricKind.face => 'Face ID',
    BiometricKind.fingerprint => 'Fingerprint',
    BiometricKind.both => 'Face ID or fingerprint',
    BiometricKind.generic => 'Biometric unlock',
    BiometricKind.none => 'Biometric unlock',
  };

  /// Sentence describing what unlock will use.
  String get description => switch (this) {
    BiometricKind.face => 'Unlock with Face ID',
    BiometricKind.fingerprint => 'Unlock with your fingerprint',
    BiometricKind.both => 'Unlock with Face ID or your fingerprint',
    BiometricKind.generic => 'Unlock with your saved biometrics',
    BiometricKind.none => 'No biometrics are enrolled on this device',
  };

  bool get isAvailable => this != BiometricKind.none;

  IconData get icon => switch (this) {
    BiometricKind.face => Icons.face_outlined,
    BiometricKind.both => Icons.fingerprint,
    _ => Icons.fingerprint,
  };
}

/// What a sensitive action inside an unlocked session must satisfy.
enum VerificationMode { pin, biometric, either }

extension VerificationModeLabels on VerificationMode {
  String get label => switch (this) {
    VerificationMode.pin => 'PIN only',
    VerificationMode.biometric => 'Biometric only',
    VerificationMode.either => 'Either',
  };

  String get shortLabel => switch (this) {
    VerificationMode.pin => 'PIN',
    VerificationMode.biometric => 'BIO',
    VerificationMode.either => 'EITHER',
  };

  /// [VerificationMode.pin] means the thing the user knows, which is a
  /// password when that is what they chose. Labelling it "PIN" regardless
  /// would name a control after something the app is not asking for.
  String labelFor(UnlockSecretType type) => switch (this) {
    VerificationMode.pin => '${type.nounCapitalized} only',
    VerificationMode.biometric => 'Biometric only',
    VerificationMode.either => 'Either',
  };

  String shortLabelFor(UnlockSecretType type) => switch (this) {
    VerificationMode.pin => type.isPin ? 'PIN' : 'PASSWORD',
    VerificationMode.biometric => 'BIO',
    VerificationMode.either => 'EITHER',
  };
}

/// Outcome of a device-ownership check.
enum DeviceOwnerCheck { confirmed, refused, unavailable }

/// Thrown when a failed attempt triggered the self-destruct wipe.
class VaultDestroyedException implements Exception {
  @override
  String toString() => 'VaultDestroyedException';
}
