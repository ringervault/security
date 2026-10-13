/// Which entries are likely to fit an app or site that nothing is linked to
/// yet, and finding one by typing.
///
/// None of this decides whether an entry may be filled. It only puts the
/// probable ones first, so the user does not scroll through a whole vault to
/// find "Amazon" on amazon.in. Filling still goes through the confirmation
/// that names the exact destination, which is why loose matching is fine
/// here when it never is in autofill_target.dart.
library;

import 'package:ringer_vault/autofill/autofill_target.dart';
import 'package:ringer_vault/autofill/registrable_domain.dart';
import 'package:ringer_vault/models/vault_entry.dart';

/// Parts of a package name that say nothing about whose app it is.
const _genericPackageParts = {
  'com', 'org', 'net', 'in', 'co', 'io', 'app', 'apps', 'android', 'mobile',
  'client', 'main', 'prod', 'release', 'beta', 'lite', 'www',
};

/// One company, several names people file their logins under.
const _aliases = <String, List<String>>{
  'google': ['gmail', 'youtube'],
  'gmail': ['google'],
  'youtube': ['google'],
  'microsoft': ['outlook', 'hotmail', 'live', 'xbox', 'skype'],
  'outlook': ['microsoft', 'hotmail', 'live'],
  'live': ['microsoft', 'outlook', 'hotmail'],
  'hotmail': ['microsoft', 'outlook', 'live'],
  'apple': ['icloud'],
  'icloud': ['apple'],
  'twitter': ['x'],
  'x': ['twitter'],
};

List<String> _words(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((w) => w.isNotEmpty)
    .toList();

/// The first part of a package name that names the company, such as
/// "amazon" in "in.amazon.mShop.android.shopping".
String? _packageWord(String packageName) {
  for (final part in packageName.toLowerCase().split('.')) {
    if (part.length >= 3 && !_genericPackageParts.contains(part)) return part;
  }
  return null;
}

/// The name of a site without its ending: "amazon" for www.amazon.in.
String? _siteWord(String host) {
  final result = hostOf(host);
  if (!result.isUsable) return null;
  return result.registrable!.split('.').first;
}

/// Words that point at entries likely to belong to [request].
///
/// For a site, its name. For an app, the first word of the name it shows and
/// the company part of its package name, so the Gmail app suggests both
/// "Gmail" and "Google" entries.
Set<String> suggestionTerms(AutofillRequest request, {String? appLabel}) {
  final terms = <String>{};
  final claimed = request.claimedWebDomain;
  if (claimed != null && claimed.isNotEmpty) {
    final site = _siteWord(claimed);
    if (site != null) terms.add(site);
  } else if (!request.knownBrowser) {
    final label = appLabel == null ? const <String>[] : _words(appLabel);
    if (label.isNotEmpty) terms.add(label.first);
    final package = _packageWord(request.packageName);
    if (package != null) terms.add(package);
  }
  return {
    for (final term in terms) ...[term, ...?_aliases[term]],
  };
}

/// Whether [entry] looks like it belongs to one of [terms]: its name, the
/// sites or apps it is already linked to, or the domain of its email.
bool suggests(VaultEntry entry, Set<String> terms) {
  if (terms.isEmpty) return false;

  bool hit(String word) => terms.any(
        (t) => word == t || (t.length >= 3 && word.startsWith(t)),
      );

  if (_words(entry.title).any(hit)) return true;

  for (final target in entry.targets) {
    final word = target.kind == TargetKind.site
        ? _siteWord(target.value)
        : _packageWord(target.value);
    if (word != null && hit(word)) return true;
  }

  for (final address in [entry.email, entry.username]) {
    final at = address.indexOf('@');
    if (at < 0) continue;
    final word = _siteWord(address.substring(at + 1));
    if (word != null && hit(word)) return true;
  }
  return false;
}

/// Whether [entry] matches what the user typed in the search box: its name,
/// username, email, or a site it is linked to.
bool searchMatches(VaultEntry entry, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return [
    entry.title,
    entry.username,
    entry.email,
    ...linkedPlaces(entry),
  ].any((field) => field.toLowerCase().contains(q)) ||
      sameSiteAs(entry, q);
}

/// The websites and apps [entry] is linked to, as searchable text: each
/// site's address and each app's package name.
Iterable<String> linkedPlaces(VaultEntry entry) => [
      for (final t in entry.targets) t.value,
    ];

/// Whether [query] is a web address (typed or pasted, with or without
/// "https://" and a path) on the same site as one [entry] is linked to:
/// "https://www.amazon.in/gp/cart" finds the entry saved for amazon.in.
bool sameSiteAs(VaultEntry entry, String query) {
  final q = query.trim();
  if (q.contains(' ') || !q.contains('.')) return false;
  final site = hostOf(q).registrable;
  if (site == null) return false;
  return entry.targets.any(
    (t) => t.kind == TargetKind.site && registrableDomain(t.value).registrable == site,
  );
}

/// A name for a new entry saved from [request]: "Amazon" for www.amazon.in,
/// or the app's own name.
String newEntryTitle(AutofillRequest request, {String? appLabel}) {
  final claimed = request.claimedWebDomain;
  if (claimed != null && claimed.isNotEmpty) {
    final site = _siteWord(claimed);
    if (site != null) return site[0].toUpperCase() + site.substring(1);
    return claimed;
  }
  if (appLabel != null && appLabel.trim().isNotEmpty) return appLabel.trim();
  final package = _packageWord(request.packageName);
  if (package != null) return package[0].toUpperCase() + package.substring(1);
  return request.packageName;
}

/// Words that point to one of the built-in categories. Only a first guess
/// on the save sheet, which the person can change.
const Map<String, List<String>> _categoryWords = {
  'Banking': ['bank', 'pay', 'paytm', 'phonepe', 'upi', 'card', 'finance', 'money', 'wallet',
    'hdfc', 'icici', 'sbi', 'axis', 'kotak', 'paypal', 'stripe', 'zerodha', 'groww'],
  'Email': ['mail', 'gmail', 'outlook', 'yahoo', 'proton', 'protonmail', 'zoho'],
  'Entertainment': ['netflix', 'prime', 'primevideo', 'hotstar', 'spotify', 'youtube', 'music',
    'video', 'game', 'games', 'steam', 'twitch', 'disney', 'jiocinema', 'sonyliv', 'zee5'],
  'Social': ['facebook', 'instagram', 'twitter', 'linkedin', 'whatsapp', 'snapchat', 'reddit',
    'threads', 'discord', 'telegram', 'pinterest', 'tiktok', 'quora'],
  'Work': ['slack', 'jira', 'atlassian', 'github', 'gitlab', 'bitbucket', 'zoom', 'teams',
    'office', 'microsoft', 'notion', 'figma', 'asana', 'trello', 'salesforce'],
};

/// The built-in category a login saved from [request] most likely belongs
/// in, or "Utility" when nothing points anywhere.
String guessCategory(AutofillRequest request, {String? appLabel}) {
  final terms = suggestionTerms(request, appLabel: appLabel);
  for (final MapEntry(key: category, value: words) in _categoryWords.entries) {
    if (terms.any((t) => words.any((w) => t == w || (w.length >= 4 && t.startsWith(w))))) {
      return category;
    }
  }
  return 'Utility';
}
