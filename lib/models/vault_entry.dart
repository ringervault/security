import 'package:hive/hive.dart';
import 'package:ringer_vault/autofill/autofill_target.dart';
import 'package:uuid/uuid.dart';

part 'vault_entry.g.dart'; // Hive generator file

/// One secret held by an entry, ready to display.
///
/// Built on demand rather than stored, so the stored shape stays flat and
/// every screen renders the same list instead of hardcoding which fields
/// exist. Only populated secrets appear.
class EntrySecret {
  final String label;
  final String value;
  final bool isPin;

  const EntrySecret({
    required this.label,
    required this.value,
    required this.isPin,
  });
}

/// How many earlier passwords an entry keeps.
const int kPasswordHistoryLength = 5;

/// A password an entry used to have, and when it was replaced. Kept inside
/// the vault's encryption with the entry, so it is never readable without
/// the vault open, and shown only after the same check as the password.
class PreviousPassword {
  final String password;
  final DateTime replacedAt;

  const PreviousPassword(this.password, this.replacedAt);

  Map<String, dynamic> toJson() => {
        'password': password,
        'replacedAt': replacedAt.toUtc().toIso8601String(),
      };

  /// Null for anything malformed: a bad item is dropped, not fatal.
  static PreviousPassword? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final password = raw['password'];
    final at = DateTime.tryParse('${raw['replacedAt']}');
    if (password is! String || password.isEmpty || at == null) return null;
    return PreviousPassword(password, at);
  }
}

/// [history] with [old] in front, replaced [at]: newest first, no repeats,
/// [kPasswordHistoryLength] at most. The same rule as the extension's
/// withPreviousPassword (extension/src/vault/save.js).
/// Going back to an earlier password ([current]) takes it out of the
/// history.
List<PreviousPassword> withPreviousPassword(
  List<PreviousPassword> history,
  String old,
  DateTime at, {
  String? current,
}) =>
    [
      PreviousPassword(old, at),
      ...history.where((p) => p.password != old && p.password != current),
    ].take(kPasswordHistoryLength).toList();

@HiveType(typeId: 0)
class VaultEntry {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  String username;

  @HiveField(3)
  String password;

  @HiveField(4)
  String category;

  @HiveField(5)
  String? notes;

  @HiveField(6)
  DateTime createdAt;

  @HiveField(7)
  DateTime updatedAt;

  @HiveField(8)
  String email;

  @HiveField(9)
  String pin;

  /// What this entry calls its main password, e.g. "Login password".
  ///
  /// Empty means the generic default. Stored separately from the value so
  /// renaming a label never touches the secret itself.
  @HiveField(10)
  String passwordLabel;

  /// A second password, for accounts that have two, such as a login password
  /// and a transaction password. Empty when unused.
  @HiveField(11)
  String extraPassword;

  @HiveField(12)
  String extraPasswordLabel;

  @HiveField(13)
  String pinLabel;

  /// A second PIN, for cards that have both an ATM PIN and a telephone PIN.
  @HiveField(14)
  String extraPin;

  @HiveField(15)
  String extraPinLabel;

  /// Apps and sites this entry is allowed to fill into, encoded one per
  /// string. Empty means autofill will never offer this entry to anything.
  @HiveField(16)
  List<String> autofillTargets;

  /// Earlier passwords, newest first ([kPasswordHistoryLength] at most),
  /// added whenever the password changes (StorageService.updateEntry, and
  /// the extension when it updates one). Not in the Hive record.
  List<PreviousPassword> passwordHistory;

  /// Fields this version does not know, kept exactly as read and written
  /// back with the entry. A newer app or extension may add an optional field
  /// (a password history, say); an older one rewriting the entry must not
  /// drop it, or the next sync would erase it everywhere. Never shown, never
  /// interpreted. Not in the Hive record (old local files only).
  final Map<String, Object?> extra;

  /// Every key [toJson] writes itself; anything else in a record is [extra].
  static const Set<String> knownKeys = {
    'id', 'title', 'username', 'password', 'category', 'email', 'pin', 'notes',
    'passwordLabel', 'extraPassword', 'extraPasswordLabel', 'pinLabel',
    'extraPin', 'extraPinLabel', 'autofillTargets', 'createdAt', 'updatedAt',
    'passwordHistory',
  };

  VaultEntry({
    String? id,
    required this.title,
    required this.username,
    required this.password,
    required this.category,
    this.email = '',
    this.pin = '',
    this.notes,
    this.passwordLabel = '',
    this.extraPassword = '',
    this.extraPasswordLabel = '',
    this.pinLabel = '',
    this.extraPin = '',
    this.extraPinLabel = '',
    List<String>? autofillTargets,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, Object?>? extra,
    List<PreviousPassword>? passwordHistory,
  })  : id = id ?? const Uuid().v4(),
        passwordHistory = passwordHistory ?? <PreviousPassword>[],
        extra = Map.unmodifiable(extra ?? const {}),
        autofillTargets = autofillTargets ?? <String>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  // ---- Labels --------------------------------------------------------------

  /// Labels fall back to a generic name rather than rendering blank, because
  /// every entry saved before labels existed has none.
  static const String defaultPasswordLabel = 'Password';
  static const String defaultExtraPasswordLabel = 'Second password';
  static const String defaultPinLabel = 'PIN';
  static const String defaultExtraPinLabel = 'Second PIN';

  String get passwordLabelOrDefault =>
      passwordLabel.trim().isEmpty ? defaultPasswordLabel : passwordLabel.trim();

  String get extraPasswordLabelOrDefault => extraPasswordLabel.trim().isEmpty
      ? defaultExtraPasswordLabel
      : extraPasswordLabel.trim();

  String get pinLabelOrDefault =>
      pinLabel.trim().isEmpty ? defaultPinLabel : pinLabel.trim();

  String get extraPinLabelOrDefault =>
      extraPinLabel.trim().isEmpty ? defaultExtraPinLabel : extraPinLabel.trim();

  /// Targets that survived parsing. Anything malformed is dropped rather
  /// than guessed at, because a bad target is a fill into the wrong place.
  List<AutofillTarget> get targets => autofillTargets
      .map(AutofillTarget.decode)
      .whereType<AutofillTarget>()
      .toList();

  /// Every secret this entry actually holds, in the order they are shown.
  List<EntrySecret> get secrets => [
        if (password.isNotEmpty)
          EntrySecret(
            label: passwordLabelOrDefault,
            value: password,
            isPin: false,
          ),
        if (extraPassword.isNotEmpty)
          EntrySecret(
            label: extraPasswordLabelOrDefault,
            value: extraPassword,
            isPin: false,
          ),
        if (pin.isNotEmpty)
          EntrySecret(label: pinLabelOrDefault, value: pin, isPin: true),
        if (extraPin.isNotEmpty)
          EntrySecret(
            label: extraPinLabelOrDefault,
            value: extraPin,
            isPin: true,
          ),
      ];

  /// Label text that may be searched. Deliberately excludes every value: a
  /// search must never match on a secret.
  String get searchableLabels => [
        if (password.isNotEmpty) passwordLabelOrDefault,
        if (extraPassword.isNotEmpty) extraPasswordLabelOrDefault,
        if (pin.isNotEmpty) pinLabelOrDefault,
        if (extraPin.isNotEmpty) extraPinLabelOrDefault,
      ].join(' ');

  VaultEntry copyWith({
    String? title,
    String? username,
    String? password,
    String? category,
    String? email,
    String? pin,
    String? notes,
    String? passwordLabel,
    String? extraPassword,
    String? extraPasswordLabel,
    String? pinLabel,
    String? extraPin,
    String? extraPinLabel,
    List<String>? autofillTargets,
  }) {
    return VaultEntry(
      id: id,
      title: title ?? this.title,
      username: username ?? this.username,
      password: password ?? this.password,
      category: category ?? this.category,
      email: email ?? this.email,
      pin: pin ?? this.pin,
      notes: notes ?? this.notes,
      passwordLabel: passwordLabel ?? this.passwordLabel,
      extraPassword: extraPassword ?? this.extraPassword,
      extraPasswordLabel: extraPasswordLabel ?? this.extraPasswordLabel,
      pinLabel: pinLabel ?? this.pinLabel,
      extraPin: extraPin ?? this.extraPin,
      extraPinLabel: extraPinLabel ?? this.extraPinLabel,
      autofillTargets: autofillTargets ?? List<String>.from(this.autofillTargets),
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      extra: extra,
      passwordHistory: List.of(passwordHistory),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      // First, so a known field can never be overwritten by one of these.
      ...extra,
      'id': id,
      'title': title,
      'username': username,
      'password': password,
      'category': category,
      'email': email,
      'pin': pin,
      'notes': notes,
      'passwordLabel': passwordLabel,
      'extraPassword': extraPassword,
      'extraPasswordLabel': extraPasswordLabel,
      'pinLabel': pinLabel,
      'extraPin': extraPin,
      'extraPinLabel': extraPinLabel,
      'autofillTargets': autofillTargets,
      // Always UTC, with its "Z": written as local time with no zone, a
      // date read on a phone or computer in another zone meant another
      // moment. Reading accepts both, so older files still open.
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      // Only when there is one: an entry that never changed its password
      // is written exactly as before.
      if (passwordHistory.isNotEmpty)
        'passwordHistory': [for (final p in passwordHistory) p.toJson()],
    };
  }

  /// Every field added after the first release is read defensively: a backup
  /// taken by an older build has none of them, and a restore that threw on a
  /// missing key would make old backups unusable.
  factory VaultEntry.fromJson(Map<String, dynamic> json) {
    return VaultEntry(
      id: json['id'],
      title: json['title'],
      username: json['username'],
      password: json['password'],
      category: json['category'],
      email: json['email'] ?? '',
      pin: json['pin'] ?? '',
      notes: json['notes'],
      passwordLabel: json['passwordLabel'] ?? '',
      extraPassword: json['extraPassword'] ?? '',
      extraPasswordLabel: json['extraPasswordLabel'] ?? '',
      pinLabel: json['pinLabel'] ?? '',
      extraPin: json['extraPin'] ?? '',
      extraPinLabel: json['extraPinLabel'] ?? '',
      autofillTargets:
          (json['autofillTargets'] as List?)?.map((e) => '$e').toList(),
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: DateTime.parse(json['updatedAt']),
      extra: {
        for (final e in json.entries)
          if (!knownKeys.contains(e.key)) e.key: e.value,
      },
      passwordHistory: [
        for (final raw in json['passwordHistory'] as List? ?? const [])
          if (PreviousPassword.fromJson(raw) case final p?) p,
      ].take(kPasswordHistoryLength).toList(),
    );
  }
}
