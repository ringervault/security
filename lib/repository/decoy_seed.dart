import 'dart:math';

import 'package:ringer_vault/models/vault_entry.dart';

/// Who the decoy vault appears to belong to.
///
/// Asked for when the decoy is set up, because the filler is only convincing
/// if it matches the person holding the phone. A vault full of someone else's
/// name is the first thing that gives it away.
class DecoyIdentity {
  final String name;
  final String email;

  const DecoyIdentity({required this.name, required this.email});

  static const DecoyIdentity fallback = DecoyIdentity(
    name: '',
    email: '',
  );

  String get firstName {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.first.isEmpty ? '' : parts.first;
  }

  /// Handle used where an account needs a short login name.
  String get handle {
    final local = email.contains('@') ? email.split('@').first : '';
    if (local.isNotEmpty) return local;
    if (firstName.isNotEmpty) return firstName.toLowerCase();
    return 'me';
  }

  String get mail => email.isEmpty ? '' : email;
}

/// Builds the contents of a decoy vault.
///
/// A decoy is only as good as it is believable, and this code is public, so
/// nothing in it may be a fixed recipe that a decoy could be recognised by.
/// Every vault draws its own: which services (12 to 20 of about 50), which
/// bank and which of its secrets, the owner's password habits (a few of many
/// patterns, from long word lists, reused and varied the way people do,
/// with a share of strong generated ones that differs per person), notes,
/// and dates spread over years. Two decoys share no visible pattern beyond
/// what any real vault has. Entries can be added, edited and deleted from
/// inside the decoy like any other, which makes it the owner's own.
///
/// What it must never contain is anything true. It is read by whoever the
/// real vault is being hidden from.
List<VaultEntry> buildDecoyEntries(DecoyIdentity identity, Random random) {
  // When the setup prompt was skipped there is nothing to go on, so a
  // plausible person is invented. "me@gmail.com" would be worse than a name
  // that does not match: it reads as filler at a glance.
  final invented = _inventedIdentity(random);
  final first = identity.firstName.isEmpty ? invented.firstName : identity.firstName;
  final handle = identity.handle == 'me' ? invented.handle : identity.handle;
  final mail = identity.mail.isEmpty ? invented.mail : identity.mail;
  final phone = '${6 + random.nextInt(4)}${_digits(random, 9)}';
  final habits = _Habits.of(first, random);

  T pick<T>(List<T> list) => list[random.nextInt(list.length)];
  bool chance(double p) => random.nextDouble() < p;

  DateTime ago(int minDays, int maxDays) => DateTime.now().subtract(
        Duration(
          days: minDays + random.nextInt(max(1, maxDays - minDays)),
          hours: random.nextInt(24),
          minutes: random.nextInt(60),
        ),
      );

  final entries = <VaultEntry>[];
  final used = <String>{};

  void add(
    String title,
    String category, {
    String username = '',
    String email = '',
    String password = '',
    String passwordLabel = '',
    String extraPassword = '',
    String extraPasswordLabel = '',
    String pin = '',
    String pinLabel = '',
    String extraPin = '',
    String extraPinLabel = '',
    String? notes,
  }) {
    if (!used.add(title)) return;
    final created = ago(30, 2600);
    entries.add(VaultEntry(
      title: title,
      username: username,
      email: email,
      category: category,
      password: password,
      passwordLabel: passwordLabel,
      extraPassword: extraPassword,
      extraPasswordLabel: extraPasswordLabel,
      pin: pin,
      pinLabel: pinLabel,
      extraPin: extraPin,
      extraPinLabel: extraPinLabel,
      notes: notes,
      createdAt: created,
      // Changed at some point after it was created, often never.
      updatedAt: chance(0.6)
          ? created.add(Duration(days: random.nextInt(400), minutes: random.nextInt(1440)))
          : created,
    ));
  }

  String loginFor(_Service s) => switch (s.login) {
        _Login.mail => mail,
        _Login.phone => phone,
        _Login.handle => chance(0.5) ? handle : '${handle}_${random.nextInt(999)}',
        _Login.number => _digits(random, 8 + random.nextInt(4)),
      };

  // The mailbox that matches the address, always: everyone has one.
  final domain = mail.contains('@') ? mail.split('@').last.toLowerCase() : 'gmail.com';
  add(
    _mailboxes[domain] ?? pick(_mailboxes.values.toList()),
    'Email',
    username: mail,
    email: mail,
    password: habits.next(),
    notes: chance(0.5) ? pick(_mailNotes).replaceAll('#', phone.substring(phone.length - 4)) : null,
  );

  // One bank at least, with some of the secrets a bank account has.
  final banks = [..._banks]..shuffle(random);
  for (final bank in banks.take(1 + (chance(0.45) ? 1 : 0))) {
    final secrets = <String, String>{};
    if (chance(0.6)) secrets['ATM PIN'] = _digits(random, 4);
    if (chance(0.45)) secrets['TPIN'] = _digits(random, 6);
    final pins = secrets.entries.toList();
    final transaction = chance(0.5);
    add(
      chance(0.5) ? '$bank NetBanking' : bank,
      'Banking',
      username: chance(0.7) ? _digits(random, 7 + random.nextInt(4)) : handle,
      password: habits.next(),
      passwordLabel: transaction ? 'Login password' : '',
      extraPassword: transaction ? habits.next() : '',
      extraPasswordLabel: transaction ? 'Transaction password' : '',
      pin: pins.isNotEmpty ? pins[0].value : '',
      pinLabel: pins.isNotEmpty ? pins[0].key : '',
      extraPin: pins.length > 1 ? pins[1].value : '',
      extraPinLabel: pins.length > 1 ? pins[1].key : '',
      notes: chance(0.6) ? pick(_bankNotes).replaceAll('#', _digits(random, 4)) : null,
    );
  }

  // The rest: a different handful of services for every decoy.
  final catalogue = [..._services]..shuffle(random);
  final target = 12 + random.nextInt(9);
  for (final s in catalogue) {
    if (entries.length >= target) break;
    final login = loginFor(s);
    final hasPin = s.pinLabel != null && chance(0.5);
    add(
      s.title,
      s.category,
      username: login,
      email: login.contains('@') ? login : '',
      password: s.noPassword ? '' : habits.next(),
      pin: hasPin || s.noPassword ? _digits(random, s.pinLength) : '',
      pinLabel: hasPin || s.noPassword ? s.pinLabel ?? 'PIN' : '',
      notes: s.notes.isNotEmpty && chance(0.35) ? pick(s.notes) : null,
    );
  }

  // Stored in a jumbled order, as a vault filled in over years would be.
  entries.shuffle(random);
  return entries;
}

/// One owner's way of making passwords: a few bases reused with small
/// changes, and some share of strong generated ones.
class _Habits {
  final Random random;
  final List<String> bases;
  final double strongShare;

  _Habits(this.random, this.bases, this.strongShare);

  static _Habits of(String firstName, Random random) {
    final name = firstName.isEmpty ? _firstNames[random.nextInt(_firstNames.length)] : firstName;
    final patterns = [..._patterns]..shuffle(random);
    final count = 2 + random.nextInt(3);
    return _Habits(
      random,
      [for (final p in patterns.take(count)) p(name, random)],
      // From someone who never uses one to someone who mostly does.
      [0.05, 0.15, 0.3, 0.5][random.nextInt(4)],
    );
  }

  /// How often each password has been handed out. The same one twice is
  /// what people do; the same one everywhere reads as generated.
  final Map<String, int> _used = {};

  String next() {
    if (random.nextDouble() < strongShare) return _strong(random);
    final base = bases[random.nextInt(bases.length)];
    var password = switch (random.nextInt(7)) {
      0 => '$base!',
      1 => '$base${random.nextInt(10)}',
      2 => base.toLowerCase(),
      3 => '$base${random.nextInt(90) + 10}',
      _ => base,
    };
    while ((_used[password] ?? 0) >= 2) {
      password = '$base${random.nextInt(900) + 100}';
    }
    _used[password] = (_used[password] ?? 0) + 1;
    return password;
  }
}

typedef _Pattern = String Function(String name, Random random);

String _word(Random r, List<String> list) => list[r.nextInt(list.length)];
String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
int _year(Random r) => 1975 + r.nextInt(32);
String _sym(Random r) => '@#!\$*_.'[r.nextInt(7)];

final List<_Pattern> _patterns = [
  (n, r) => '$n${_sym(r)}${_year(r)}',
  (n, r) => '${_cap(n)}${_year(r)}',
  (n, r) => '${n.toLowerCase()}${r.nextInt(900) + 100}',
  (n, r) => '${_word(r, _places)}${_sym(r)}${r.nextInt(90) + 10}',
  (n, r) => '${_cap(_word(r, _pets))}${r.nextInt(9000) + 1000}',
  (n, r) => '${_cap(_word(r, _words))}${_cap(_word(r, _words))}${r.nextInt(99)}',
  (n, r) => '${_word(r, _words)}${_year(r)}',
  (n, r) => '${_cap(_word(r, _pets))}${_sym(r)}${_cap(n)}',
  (n, r) => '${n[0].toUpperCase()}${_word(r, _words)}${_sym(r)}${r.nextInt(100)}',
  (n, r) => '${_cap(_word(r, _places))}${_year(r) % 100}${_sym(r)}',
  (n, r) => 'I${_word(r, ['love', 'like', 'miss'])}${_cap(_word(r, _pets))}${r.nextInt(99)}',
  (n, r) => '${_word(r, _words)}.${_word(r, _words)}${r.nextInt(1000)}',
];

enum _Login { mail, phone, handle, number }

class _Service {
  final String title;
  final String category;
  final _Login login;
  final String? pinLabel;
  final int pinLength;
  final bool noPassword;
  final List<String> notes;

  const _Service(
    this.title,
    this.category,
    this.login, {
    this.pinLabel,
    this.pinLength = 4,
    this.noPassword = false,
    this.notes = const [],
  });
}

const List<_Service> _services = [
  _Service('Facebook', 'Social', _Login.mail),
  _Service('Instagram', 'Social', _Login.handle),
  _Service('LinkedIn', 'Social', _Login.mail),
  _Service('X (Twitter)', 'Social', _Login.handle),
  _Service('Snapchat', 'Social', _Login.handle),
  _Service('Reddit', 'Social', _Login.handle),
  _Service('Pinterest', 'Social', _Login.mail),
  _Service('Telegram', 'Social', _Login.phone, pinLabel: 'Cloud password', noPassword: true, pinLength: 6),
  _Service('WhatsApp', 'Social', _Login.phone, pinLabel: 'Two-step PIN', noPassword: true, pinLength: 6, notes: ['Two-step verification', 'Backup on Drive']),
  _Service('Discord', 'Social', _Login.mail),
  _Service('Quora', 'Social', _Login.mail),
  _Service('Netflix', 'Entertainment', _Login.mail, pinLabel: 'Profile PIN', notes: ['Shared with family', 'Renews on the 5th']),
  _Service('Prime Video', 'Entertainment', _Login.mail),
  _Service('Disney+ Hotstar', 'Entertainment', _Login.phone),
  _Service('Spotify', 'Entertainment', _Login.mail, notes: ['Family plan']),
  _Service('YouTube Premium', 'Entertainment', _Login.mail),
  _Service('JioCinema', 'Entertainment', _Login.phone),
  _Service('SonyLIV', 'Entertainment', _Login.mail),
  _Service('Zee5', 'Entertainment', _Login.mail),
  _Service('BookMyShow', 'Entertainment', _Login.phone),
  _Service('Steam', 'Entertainment', _Login.handle),
  _Service('PlayStation Network', 'Entertainment', _Login.mail),
  _Service('Amazon', 'Utility', _Login.mail, notes: ['Prime till March']),
  _Service('Flipkart', 'Utility', _Login.phone),
  _Service('Myntra', 'Utility', _Login.phone),
  _Service('Swiggy', 'Utility', _Login.phone),
  _Service('Zomato', 'Utility', _Login.phone),
  _Service('Uber', 'Utility', _Login.phone),
  _Service('Ola', 'Utility', _Login.phone),
  _Service('IRCTC', 'Utility', _Login.handle, notes: ['Tatkal at 10 am']),
  _Service('MakeMyTrip', 'Utility', _Login.mail),
  _Service('Airtel', 'Utility', _Login.phone, notes: ['Postpaid, auto pay on the 2nd', 'Broadband account']),
  _Service('Jio', 'Utility', _Login.phone),
  _Service('Vi', 'Utility', _Login.phone),
  _Service('Electricity board', 'Utility', _Login.number, notes: ['Bill on the 20th']),
  _Service('Gas booking', 'Utility', _Login.number),
  _Service('DigiLocker', 'Utility', _Login.phone, pinLabel: 'Security PIN', pinLength: 6),
  _Service('Income Tax portal', 'Utility', _Login.handle),
  _Service('Paytm', 'Banking', _Login.phone, pinLabel: 'UPI PIN'),
  _Service('PhonePe', 'Banking', _Login.phone, pinLabel: 'UPI PIN', noPassword: true),
  _Service('Google Pay', 'Banking', _Login.phone, pinLabel: 'UPI PIN', noPassword: true),
  _Service('Zerodha', 'Banking', _Login.handle, pinLabel: 'PIN', pinLength: 6),
  _Service('Groww', 'Banking', _Login.mail, pinLabel: 'PIN'),
  _Service('Credit card', 'Banking', _Login.mail, pinLabel: 'Card PIN', notes: ['Statement on the 14th', 'Limit raised last year']),
  _Service('Office laptop', 'Work', _Login.handle, notes: ['Changes every 90 days']),
  _Service('Slack', 'Work', _Login.mail),
  _Service('Microsoft Teams', 'Work', _Login.mail),
  _Service('Zoom', 'Work', _Login.mail),
  _Service('Jira', 'Work', _Login.mail),
  _Service('GitHub', 'Work', _Login.handle),
  _Service('Naukri', 'Work', _Login.mail),
  _Service('VPN', 'Work', _Login.handle),
];

const Map<String, String> _mailboxes = {
  'gmail.com': 'Gmail',
  'googlemail.com': 'Gmail',
  'outlook.com': 'Outlook',
  'hotmail.com': 'Outlook',
  'live.com': 'Outlook',
  'yahoo.com': 'Yahoo Mail',
  'yahoo.co.in': 'Yahoo Mail',
  'rediffmail.com': 'Rediffmail',
  'icloud.com': 'iCloud Mail',
  'proton.me': 'Proton Mail',
};

const List<String> _banks = [
  'HDFC Bank', 'SBI', 'ICICI Bank', 'Axis Bank', 'Kotak Bank', 'Canara Bank',
  'Bank of Baroda', 'Punjab National Bank', 'Union Bank', 'IDFC First Bank',
  'Yes Bank', 'IndusInd Bank', 'Federal Bank', 'Indian Bank',
];

const List<String> _bankNotes = [
  'Debit card ending #',
  'Account ending #',
  'Customer care PIN in branch letter',
  'Nominee added',
  'Locker number #',
];

const List<String> _mailNotes = [
  'Recovery number ends #',
  'Recovery email is the old one',
  'Two-step on',
];

const List<String> _places = [
  'pune', 'delhi', 'chennai', 'kochi', 'jaipur', 'shimla', 'mysore', 'goa',
  'mumbai', 'kolkata', 'indore', 'nagpur', 'surat', 'madurai', 'ooty', 'manali',
  'udaipur', 'agra', 'vizag', 'patna', 'lucknow', 'bhopal', 'nashik', 'trichy',
  'london', 'dubai', 'paris', 'sydney', 'boston', 'tokyo',
];

const List<String> _pets = [
  'tommy', 'bruno', 'rocky', 'simba', 'coco', 'max', 'leo', 'luna', 'milo',
  'tiger', 'snowy', 'buddy', 'jimmy', 'pepper', 'oreo', 'kitty', 'bella',
  'shadow', 'chikoo', 'motu', 'golu', 'pinky', 'ginger', 'honey',
];

const List<String> _words = [
  'sunshine', 'rainbow', 'blue', 'sky', 'happy', 'dragon', 'master', 'star',
  'moon', 'silver', 'golden', 'royal', 'dream', 'magic', 'river', 'ocean',
  'thunder', 'falcon', 'cricket', 'football', 'music', 'guitar', 'coffee',
  'mango', 'lotus', 'phoenix', 'ninja', 'rocket', 'winter', 'summer',
];

String _digits(Random random, int count) =>
    List.generate(count, (_) => random.nextInt(10)).join();

String _strong(Random random) {
  const alphabets = [
    'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789#\$%&',
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*-_',
  ];
  final alphabet = alphabets[random.nextInt(alphabets.length)];
  final length = 12 + random.nextInt(9);
  return List.generate(length, (_) => alphabet[random.nextInt(alphabet.length)]).join();
}

const List<String> _firstNames = [
  'Arun', 'Neha', 'Vikram', 'Priya', 'Rahul', 'Divya', 'Sanjay', 'Anjali',
  'Karthik', 'Meera', 'Rohan', 'Sneha', 'Aditya', 'Pooja', 'Suresh', 'Kavya',
  'Manoj', 'Lakshmi', 'Nikhil', 'Shreya', 'Varun', 'Deepa', 'Harish', 'Asha',
  'Ajay', 'Ritu', 'Gautam', 'Swati', 'Imran', 'Fatima', 'Joseph', 'Mary',
  'Ravi', 'Geeta', 'Siddharth', 'Nandini', 'Amit', 'Kiran', 'Tarun', 'Isha',
];

const List<String> _lastNames = [
  'Mehta', 'Sharma', 'Nair', 'Iyer', 'Rao', 'Kulkarni', 'Bose', 'Reddy',
  'Patel', 'Singh', 'Gupta', 'Menon', 'Pillai', 'Joshi', 'Das', 'Chopra',
  'Verma', 'Shetty', 'Banerjee', 'Krishnan', 'Khan', 'Thomas', 'Desai', 'Malhotra',
  'Agarwal', 'Mishra', 'Naidu', 'Hegde', 'Saxena', 'Ghosh',
];

DecoyIdentity _inventedIdentity(Random random) {
  final first = _firstNames[random.nextInt(_firstNames.length)];
  final last = _lastNames[random.nextInt(_lastNames.length)];
  final f = first.toLowerCase();
  final l = last.toLowerCase();
  final local = switch (random.nextInt(5)) {
    0 => '$f.$l${random.nextInt(99)}',
    1 => '$f$l',
    2 => '${f[0]}$l${_year(random) % 100}',
    3 => '${f}_$l',
    _ => '$f${_year(random)}',
  };
  const domains = ['gmail.com', 'gmail.com', 'gmail.com', 'outlook.com', 'yahoo.com', 'rediffmail.com'];
  return DecoyIdentity(
    name: '$first $last',
    email: '$local@${domains[random.nextInt(domains.length)]}',
  );
}
