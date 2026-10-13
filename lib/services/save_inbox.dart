/// Logins saved while the vault is locked, waiting for its next unlock.
///
/// Saving should not need an unlock: the login was just typed, so there is
/// nothing secret to protect from the person typing it. What needs
/// protecting is the vault, and a save never opens it. Each vault has an
/// X25519 key pair: the private half lives inside the vault (its `meta`),
/// the public half in secure storage. A save is sealed to both vaults'
/// public keys and left in its own file; whichever vault opens next takes
/// its copy into its entries (see [takeSaveInbox]).
///
/// One file per login, in `inbox/` beside the vault:
///
///     "RVI1" || version(1) || reserved(3) || day(4)
///     || copy for slot 0 || copy for slot 1
///
/// `day` is the day the login was saved, as whole days since 1970 (UTC),
/// so files can be removed after [keepDays]. Each copy is:
///
///     ephemeral public key(32) || nonce(12) || AES-256-GCM(plain) || tag(16)
///
/// with the key HKDF-SHA256(X25519(ephemeral, vault public key), salt =
/// ephemeral public key || vault public key, info = "RVI1 save inbox"), and
/// the 12 header bytes and the slot number as additional data. The plain
/// text is a 4-byte length, the login as JSON, and zeros up to a multiple
/// of 512 bytes, so the size says little about what was saved.
///
/// Like the vault file, both copies are always there. With no decoy, the
/// second public key is random bytes, which nothing can tell from a real
/// one, so the files say nothing about whether a decoy exists. A vault that
/// has taken its copy overwrites it with random bytes, and nothing deletes
/// a file before [keepDays] whichever vault opened, so the files look the
/// same after an unlock of either vault, decoy or not. A vault always takes
/// its own waiting copy, however old.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ringer_vault/autofill/autofill_target.dart';
import 'package:ringer_vault/autofill/lookalike.dart';
import 'package:ringer_vault/autofill/registrable_domain.dart';
import 'package:ringer_vault/autofill/suggest.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/services/activity_log_service.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/vault_container.dart';

/// A login typed into another app or a website, saved without an unlock.
class InboxLogin {
  /// Who asked, exactly as the save request reported it.
  final AutofillRequest request;

  /// The name the app shows, used only for the entry's name and to suggest.
  final String? appLabel;

  final String title;
  final String username;
  final String password;
  final String category;
  final DateTime savedAt;

  /// Warnings shown on the save sheet and saved anyway, by name.
  final List<String> warned;
  final bool warnedDanger;

  const InboxLogin({
    required this.request,
    this.appLabel,
    required this.title,
    required this.username,
    required this.password,
    required this.category,
    required this.savedAt,
    this.warned = const [],
    this.warnedDanger = false,
  });

  Map<String, dynamic> toJson() => {
        'request': {
          'packageName': request.packageName,
          'certificateSha256': request.certificateSha256,
          'claimedWebDomain': request.claimedWebDomain,
          'fromVerifiedBrowser': request.fromVerifiedBrowser,
          'installedFromStore': request.installedFromStore,
          'compatibilityMode': request.compatibilityMode,
          'webScheme': request.webScheme,
          'knownBrowser': request.knownBrowser,
        },
        'appLabel': appLabel,
        'title': title,
        'username': username,
        'password': password,
        'category': category,
        'savedAt': savedAt.toUtc().toIso8601String(),
        'warned': warned,
        'warnedDanger': warnedDanger,
      };

  static InboxLogin fromJson(Map<String, dynamic> json) {
    final r = Map<String, dynamic>.from(json['request'] as Map);
    return InboxLogin(
      // Rebuilt as it was reported, not through fromPlatform: the
      // correction that applies was applied before it was saved.
      request: AutofillRequest(
        packageName: r['packageName'] as String,
        certificateSha256: r['certificateSha256'] as String,
        claimedWebDomain: r['claimedWebDomain'] as String?,
        fromVerifiedBrowser: r['fromVerifiedBrowser'] as bool? ?? false,
        installedFromStore: r['installedFromStore'] as bool? ?? true,
        compatibilityMode: r['compatibilityMode'] as bool? ?? false,
        webScheme: r['webScheme'] as String?,
        knownBrowser: r['knownBrowser'] as bool? ?? false,
      ),
      appLabel: json['appLabel'] as String?,
      title: json['title'] as String,
      username: json['username'] as String? ?? '',
      password: json['password'] as String,
      category: json['category'] as String,
      savedAt: DateTime.parse(json['savedAt'] as String),
      warned: [for (final w in json['warned'] as List? ?? const []) '$w'],
      warnedDanger: json['warnedDanger'] as bool? ?? false,
    );
  }
}

class InboxFullException implements Exception {
  @override
  String toString() =>
      'Too many logins are waiting to be added. Open Ringer Vault, then try again.';
}

class SaveInbox {
  static final SaveInbox _instance = SaveInbox._();
  factory SaveInbox() => _instance;
  SaveInbox._();

  /// Each slot's public key, base64. Both always exist once either vault has
  /// been opened, a random stand-in for a vault that has none.
  static const List<String> keyNames = ['vi_key_a', 'vi_key_b'];

  /// A file this vault cannot open (taken already, or another vault's) is
  /// removed once it is older than this. One it can open is always taken.
  static const int keepDays = 90;

  /// At most this many files wait at once.
  static const int maxWaiting = 300;

  static const List<int> _magic = [0x52, 0x56, 0x49, 0x31]; // "RVI1"
  static const int _version = 1;
  static const int _headerBytes = 12;
  static const int _keyBytes = 32;
  static const int _nonceBytes = 12;
  static const int _tagBytes = 16;
  static const int _block = 512;
  static final List<int> _info = utf8.encode('RVI1 save inbox');

  static const _secure = FlutterSecureStorage();
  final _x25519 = X25519();
  final _aes = AesGcm.with256bits();

  Future<Directory> _dir() async {
    await StorageService().init();
    return Directory('${StorageService().directoryPath}/inbox');
  }

  static int _today(DateTime now) =>
      now.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  /// Whether a save can go to the inbox: a vault has been opened since
  /// this version, so at least one real public key exists.
  Future<bool> get isReady async =>
      (await _secure.read(key: keyNames[realSlot])) != null ||
      (await _secure.read(key: keyNames[decoySlot])) != null;

  /// Seals [login] to both vaults and leaves it for the next unlock.
  Future<void> add(InboxLogin login, {DateTime? now}) async {
    final keys = <List<int>>[];
    for (final name in keyNames) {
      var stored = await _secure.read(key: name);
      if (stored == null) {
        stored = base64Encode(noise(_keyBytes));
        await _secure.write(key: name, value: stored);
      }
      keys.add(base64Decode(stored));
    }

    final dir = await _dir();
    if (await dir.exists() && await dir.list().length >= maxWaiting) {
      throw InboxFullException();
    }
    await dir.create(recursive: true);

    final header = Uint8List(_headerBytes)
      ..setRange(0, 4, _magic)
      ..[4] = _version;
    ByteData.sublistView(header).setUint32(8, _today(now ?? DateTime.now()));

    final json = utf8.encode(jsonEncode(login.toJson()));
    final plainSize = ((json.length + 4) / _block).ceil() * _block;
    final plain = Uint8List(plainSize)..setRange(4, 4 + json.length, json);
    ByteData.sublistView(plain).setUint32(0, json.length);

    final out = BytesBuilder(copy: false)..add(header);
    for (var slot = 0; slot < 2; slot++) {
      out.add(await _seal(plain, keys[slot], header, slot));
    }

    final name = _hex(noise(16));
    final temp = File('${dir.path}/$name.tmp');
    await temp.writeAsBytes(out.takeBytes(), flush: true);
    await temp.rename('${dir.path}/$name.rvi');
  }

  Future<List<int>> _seal(List<int> plain, List<int> publicKey, List<int> header, int slot) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
    final key = await _key(ephemeral, ephemeralPublic, publicKey);
    final box = await _aes.encrypt(
      plain,
      secretKey: key,
      nonce: _aes.newNonce(),
      aad: [...header, slot],
    );
    return [...ephemeralPublic, ...box.nonce, ...box.cipherText, ...box.mac.bytes];
  }

  Future<SecretKey> _key(KeyPair own, List<int> ownPublic, List<int> otherPublic, {bool ownIsEphemeral = true}) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: own,
      remotePublicKey: SimplePublicKey(otherPublic, type: KeyPairType.x25519),
    );
    final ephemeralPublic = ownIsEphemeral ? ownPublic : otherPublic;
    final vaultPublic = ownIsEphemeral ? otherPublic : ownPublic;
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: [...ephemeralPublic, ...vaultPublic],
      info: _info,
    );
  }

  /// A new private key for a vault: 32 random bytes, kept inside it.
  static List<int> newPrivateKey() => noise(_keyBytes);

  /// Makes sure [slot]'s public key is the one for [privateKey], and that
  /// the other slot has one too (random, if nothing has set it).
  Future<void> publish(List<int> privateKey, int slot) async {
    final pair = await _x25519.newKeyPairFromSeed(privateKey);
    final public = base64Encode((await pair.extractPublicKey()).bytes);
    if (await _secure.read(key: keyNames[slot]) != public) {
      await _secure.write(key: keyNames[slot], value: public);
    }
    final other = keyNames[1 - slot];
    if (await _secure.read(key: other) == null) {
      await _secure.write(key: other, value: base64Encode(noise(_keyBytes)));
    }
  }

  /// The logins waiting for [slot]'s vault, oldest first, each with its
  /// file. Files too old are removed first; files that are not inbox files,
  /// or whose copy for this slot does not open, are left alone.
  Future<List<(File, InboxLogin)>> open(List<int> privateKey, int slot, {DateTime? now}) async {
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final pair = await _x25519.newKeyPairFromSeed(privateKey);
    final public = (await pair.extractPublicKey()).bytes;
    final today = _today(now ?? DateTime.now());

    final found = <(File, InboxLogin, int)>[];
    await for (final item in dir.list()) {
      if (item is! File) continue;
      if (item.path.endsWith('.tmp')) {
        // A save interrupted before its rename.
        await item.delete().catchError((_) => item);
        continue;
      }
      if (!item.path.endsWith('.rvi')) continue;
      final bytes = await item.readAsBytes();
      final copy = _copyOf(bytes, slot);
      if (copy == null) continue;
      final day = ByteData.sublistView(bytes).getUint32(8);
      final login = await _openCopy(copy, bytes.sublist(0, _headerBytes), slot, pair, public);
      if (login != null) {
        // This vault's own login, waiting: taken however old it is, so a
        // save is never lost for want of an unlock in time.
        found.add((item, login, day));
      } else if (today - day > keepDays) {
        // Taken already, or another vault's, and old: removed.
        await item.delete().catchError((_) => item);
      }
    }
    found.sort((a, b) => a.$2.savedAt.compareTo(b.$2.savedAt));
    return [for (final f in found) (f.$1, f.$2)];
  }

  /// [slot]'s copy in [bytes], or null if this is not an inbox file.
  static Uint8List? _copyOf(Uint8List bytes, int slot) {
    if (bytes.length < _headerBytes) return null;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    if (bytes[4] != _version) return null;
    final size = (bytes.length - _headerBytes) ~/ 2;
    if (size < _keyBytes + _nonceBytes + _tagBytes + _block ||
        (bytes.length - _headerBytes).isOdd) {
      return null;
    }
    return Uint8List.sublistView(bytes, _headerBytes + slot * size, _headerBytes + (slot + 1) * size);
  }

  Future<InboxLogin?> _openCopy(
    Uint8List copy,
    List<int> header,
    int slot,
    SimpleKeyPair pair,
    List<int> public,
  ) async {
    try {
      final ephemeralPublic = copy.sublist(0, _keyBytes);
      final key = await _key(pair, public, ephemeralPublic, ownIsEphemeral: false);
      final nonce = copy.sublist(_keyBytes, _keyBytes + _nonceBytes);
      final body = copy.sublist(_keyBytes + _nonceBytes, copy.length - _tagBytes);
      final mac = Mac(copy.sublist(copy.length - _tagBytes));
      final plain = await _aes.decrypt(
        SecretBox(body, nonce: nonce, mac: mac),
        secretKey: key,
        aad: [...header, slot],
      );
      final p = Uint8List.fromList(plain);
      final length = ByteData.sublistView(p).getUint32(0);
      final json = jsonDecode(utf8.decode(p.sublist(4, 4 + length)));
      return InboxLogin.fromJson(Map<String, dynamic>.from(json as Map));
    } catch (_) {
      // Another vault's copy, one already taken, or not ours at all.
      return null;
    }
  }

  /// Overwrites [slot]'s copy in [file] with random bytes: taken.
  Future<void> spend(File file, int slot) async {
    final bytes = await file.readAsBytes();
    final copy = _copyOf(bytes, slot);
    if (copy == null) return;
    final size = copy.length;
    final out = Uint8List.fromList(bytes)
      ..setRange(_headerBytes + slot * size, _headerBytes + (slot + 1) * size, noise(size));
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(out, flush: true);
    await temp.rename(file.path);
  }

  /// [slot]'s vault has been erased: its public key becomes random, the
  /// same as a vault that never existed, and nothing more is sealed to it.
  Future<void> forget(int slot) async {
    await _secure.write(key: keyNames[slot], value: base64Encode(noise(_keyBytes)));
  }

  /// Everything removed: both keys and every waiting login.
  Future<void> destroyAll() async {
    for (final name in keyNames) {
      await _secure.delete(key: name);
    }
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// What a vault took from the inbox when it opened, kept in it until the
/// app has shown it.
class InboxNotice {
  final String title;
  final bool updated;

  /// Why the site looked wrong, when it did.
  final String? warning;
  final bool danger;

  const InboxNotice({required this.title, required this.updated, this.warning, this.danger = false});

  Map<String, dynamic> toJson() => {
        'title': title,
        'updated': updated,
        if (warning != null) 'warning': warning,
        if (danger) 'danger': true,
      };

  static InboxNotice? fromJson(Object? raw) {
    if (raw is! Map || raw['title'] is! String) return null;
    return InboxNotice(
      title: raw['title'] as String,
      updated: raw['updated'] == true,
      warning: raw['warning'] as String?,
      danger: raw['danger'] == true,
    );
  }
}

/// A login saved while locked that looks like an existing entry not linked
/// to the app or site it came from: asked about at the unlock rather than
/// written over that entry. Updating it would also link the entry to where
/// the login was typed, and an app named like a bank could otherwise get
/// itself linked to the bank's entry without anyone agreeing to it.
class InboxQuestion {
  final String entryId;
  final String entryTitle;
  final InboxLogin login;

  /// Where it was typed, as the dialog names it.
  final String destination;

  /// Why the site looked wrong, when it did.
  final String? warning;
  final bool danger;

  const InboxQuestion({
    required this.entryId,
    required this.entryTitle,
    required this.login,
    required this.destination,
    this.warning,
    this.danger = false,
  });

  Map<String, dynamic> toJson() => {
        'entryId': entryId,
        'entryTitle': entryTitle,
        'login': login.toJson(),
        'destination': destination,
        if (warning != null) 'warning': warning,
        if (danger) 'danger': true,
      };

  static InboxQuestion? fromJson(Object? raw) {
    try {
      if (raw is! Map) return null;
      return InboxQuestion(
        entryId: raw['entryId'] as String,
        entryTitle: raw['entryTitle'] as String,
        login: InboxLogin.fromJson(Map<String, dynamic>.from(raw['login'] as Map)),
        destination: raw['destination'] as String,
        warning: raw['warning'] as String?,
        danger: raw['danger'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The meta key a vault keeps its inbox private key under.
const String inboxKeyMeta = 'inboxKey';

/// The meta key for what was taken and not yet shown.
const String inboxNoticeMeta = 'inboxNotice';

/// The meta key for logins waiting for an answer (InboxQuestion).
const String inboxQuestionMeta = 'inboxQuestions';

/// Takes the open vault's waiting logins into it: a new password for an
/// account already linked to that app or site updates it (the old one goes
/// into its history); one that only looks like an existing entry waits as a
/// question (InboxQuestion); anything else becomes a new entry. Never
/// throws: a vault that cannot take them now leaves them for next time.
Future<void> takeSaveInbox() async {
  final storage = StorageService();
  final slot = storage.openSlot;
  if (slot == null) return;
  try {
    final stored = storage.metaValue(inboxKeyMeta);
    List<int> privateKey = stored is String ? base64Decode(stored) : const [];
    if (privateKey.length != 32) {
      privateKey = SaveInbox.newPrivateKey();
      await storage.setMetaValue(inboxKeyMeta, base64Encode(privateKey));
    }
    final inbox = SaveInbox();
    await inbox.publish(privateKey, slot);

    final waiting = await inbox.open(privateKey, slot);
    if (waiting.isEmpty) return;

    final notices = [
      for (final raw in storage.metaValue(inboxNoticeMeta) as List? ?? const [])
        if (InboxNotice.fromJson(raw) case final n?) n,
    ];
    final questions = inboxQuestions();
    for (final (file, login) in waiting) {
      switch (await _take(storage, login)) {
        case final InboxNotice notice:
          notices.add(notice);
        case final InboxQuestion question:
          questions.add(question);
      }
      await inbox.spend(file, slot);
    }
    await storage.setMetaValue(inboxNoticeMeta, [for (final n in notices) n.toJson()]);
    await storage.setMetaValue(
      inboxQuestionMeta,
      questions.isEmpty ? null : [for (final q in questions) q.toJson()],
    );
  } catch (_) {
    // Left in the inbox for the next unlock.
  }
}

/// The open vault's logins waiting for an answer.
List<InboxQuestion> inboxQuestions() => [
      for (final raw in StorageService().metaValue(inboxQuestionMeta) as List? ?? const [])
        if (InboxQuestion.fromJson(raw) case final q?) q,
    ];

/// Answers [question]: [update] puts the password into the entry it looks
/// like (and links that entry to where it was typed, which the question
/// named); otherwise the login becomes a new entry of its own.
Future<void> answerInboxQuestion(InboxQuestion question, {required bool update}) async {
  final storage = StorageService();
  final login = question.login;
  final target = offerUnlinked(login.request)?.pendingTarget;
  final entry = storage.getEntries().where((e) => e.id == question.entryId).firstOrNull;
  final updated = update && entry != null && entry.password != login.password;
  if (updated) {
    await _update(storage, entry, login, target);
  } else if (!update || entry == null) {
    await _addNew(storage, login, target);
  }
  await _logSave(
    title: updated ? entry.title : login.title,
    updated: updated,
    destination: question.destination,
    warned: login.warned,
    danger: login.warnedDanger || question.danger,
    extra: question.warning,
  );
  final rest = [
    for (final q in inboxQuestions())
      if (!(q.entryId == question.entryId && q.login.savedAt == login.savedAt)) q,
  ];
  await storage.setMetaValue(inboxQuestionMeta, rest.isEmpty ? null : [for (final q in rest) q.toJson()]);
}

/// [targets] with [target] added: an app replaces its earlier record (a new
/// signature supersedes the old one); a site address is added alongside.
List<String> _withTarget(List<String> targets, AutofillTarget? target) {
  if (target == null) return targets;
  final kept = targets.where(
    (t) => target.kind == TargetKind.app ? !t.startsWith('app:${target.value}:') : t != target.encode(),
  );
  return [...kept, target.encode()];
}

Future<void> _update(StorageService storage, VaultEntry into, InboxLogin login, AutofillTarget? target) {
  final typedUser = login.username.trim();
  final hasUser = into.username.isNotEmpty || into.email.isNotEmpty;
  return storage.updateEntry(into.copyWith(
    password: login.password,
    username: !hasUser && !typedUser.contains('@') ? typedUser : null,
    email: !hasUser && typedUser.contains('@') ? typedUser : null,
    autofillTargets: target == null ? null : _withTarget(into.autofillTargets, target),
  ));
}

Future<void> _addNew(StorageService storage, InboxLogin login, AutofillTarget? target) {
  final typedUser = login.username.trim();
  return storage.addEntry(VaultEntry(
    title: login.title,
    username: typedUser.contains('@') ? '' : typedUser,
    email: typedUser.contains('@') ? typedUser : '',
    password: login.password,
    category: login.category,
    autofillTargets: [if (target != null) target.encode()],
  ));
}

Future<void> _logSave({
  required String title,
  required bool updated,
  required String destination,
  required List<String> warned,
  required bool danger,
  String? extra,
}) {
  final all = {...warned, ?extra}.toList();
  return ActivityLogService().logActivity(
    action: danger ? 'Autofill save despite warning' : 'Autofill save',
    details: [
      '${updated ? 'Updated $title' : title} from $destination, saved while locked',
      if (all.isNotEmpty) '${danger ? 'Despite' : 'Warned'}: ${all.join('; ')}',
    ].join('. '),
    isWarning: all.isNotEmpty,
  );
}

/// Adds one waiting [login] to the open vault: an [InboxNotice] of what was
/// done, an [InboxQuestion] when it has to be asked, or null when it was
/// already saved exactly.
Future<Object?> _take(StorageService storage, InboxLogin login) async {
  final request = login.request;
  final entries = storage.getEntries();
  final unlinked = offerUnlinked(request);
  final terms = suggestionTerms(request, appLabel: login.appLabel);

  // Linked: an entry already confirmed for exactly this app or site.
  // Likely: one that may be this account, but is not linked here.
  final linked = <VaultEntry>[];
  final likely = <VaultEntry>[];
  for (final entry in entries) {
    final result = matchEntry(targets: entry.targets, request: request);
    if (result.canFill && result.outcome == MatchOutcome.trusted) {
      linked.add(entry);
    } else if (result.canFill ||
        (unlinked != null && result.reason == MatchReason.noTarget && suggests(entry, terms))) {
      likely.add(entry);
    }
  }

  final typed = login.username.isEmpty ? null : login.username.toLowerCase();
  bool sameUser(VaultEntry e) =>
      typed != null && [e.username, e.email].any((u) => u.toLowerCase() == typed);
  final into = linked.where(sameUser).firstOrNull ??
      (typed == null && linked.length == 1 ? linked.single : null);
  final lookingLike = into == null ? likely.where(sameUser).firstOrNull : null;

  final target = unlinked?.pendingTarget;

  // Look-alikes of the vault's own sites could only be checked now.
  final page = request.claimedWebDomain == null || request.claimedWebDomain!.isEmpty
      ? null
      : hostOf(request.claimedWebDomain!).host ?? request.claimedWebDomain;
  final lookalikes = page == null
      ? const <Lookalike>[]
      : lookalikesOf(page, knownSites([
          for (final e in entries)
            for (final t in e.targets)
              if (t.kind == TargetKind.site) t.value,
        ]));
  final warning = lookalikes.isEmpty ? null : describeLookalike(lookalikes.first);
  final danger = lookalikes.any((l) => l.isDanger);
  final destination = page ?? login.appLabel ?? request.packageName;

  if (lookingLike != null) {
    if (lookingLike.password == login.password) return null;
    return InboxQuestion(
      entryId: lookingLike.id,
      entryTitle: lookingLike.title,
      login: login,
      destination: destination,
      warning: warning,
      danger: danger,
    );
  }

  if (into != null) {
    if (into.password == login.password) return null;
    await _update(storage, into, login, target);
  } else {
    await _addNew(storage, login, target);
  }
  await _logSave(
    title: into?.title ?? login.title,
    updated: into != null,
    destination: destination,
    warned: [...login.warned, for (final l in lookalikes) lookalikeReason(l)],
    danger: login.warnedDanger || danger,
  );
  return InboxNotice(
    title: into?.title ?? login.title,
    updated: into != null,
    warning: warning,
    danger: danger,
  );
}
