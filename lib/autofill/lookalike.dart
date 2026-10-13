/// Whether a website is dressed up as one the user already trusts.
///
/// Matching never fills across sites: "amaz0n.in" is simply a different
/// site from "amazon.in" and gets nothing on its own. The risk is the moment
/// a person is asked "fill this here anyway?" and says yes, or types their
/// password in by hand. This names what the page is imitating at exactly
/// that moment.
///
/// The list of real sites is the user's own vault (every site a login is
/// saved for), then the well-known services in brand_map.dart. So it works
/// offline, sends nothing anywhere, and is personal: the bank a person
/// actually uses is in it even though no fixed table would be.
///
/// It is a warning and never a decision. A site already in the vault is
/// never called a look-alike, whatever it resembles.
///
/// extension/src/vault/lookalike.js is the same logic for the browser
/// extension, and test/fixtures/lookalike_cases.json holds cases both must
/// agree on.
library;

import 'package:ringer_vault/autofill/brand_map.dart';
import 'package:ringer_vault/autofill/punycode.dart';
import 'package:ringer_vault/autofill/registrable_domain.dart';

enum LookalikeKind {
  /// Spelled with characters that read the same: "amaz0n", "paypa1",
  /// "rnicrosoft", or letters from another alphabet such as a Cyrillic "а"
  /// in "аmazon" (which arrives as "xn--mazon-3ve").
  confusable,

  /// One letter off, or two for long names: "amazom", "amzaon". Names
  /// under six letters are left out, being a letter away from too many
  /// ordinary words.
  typo,

  /// The real name inside another address: "paypal-login.com",
  /// "paypal.com.secure-check.io".
  embedded,

  /// The same name under a different ending: "amazon.xyz" for "amazon.in".
  /// Companies often own several, so this one only asks for a closer look.
  sameName,

  /// Letters from two alphabets in one part of the address, such as a
  /// Cyrillic "а" among Latin letters. Real sites almost never do this, so
  /// it is said whether or not the address resembles anything known.
  mixedScripts,

  /// Written entirely in letters from another alphabet that all pass for
  /// Latin ones, under an ending in Latin letters: "сосо.com" in Cyrillic
  /// reads as "coco.com". Also said whatever it resembles.
  disguisedScript,
}

class KnownSite {
  /// The registrable domain, such as "amazon.in".
  final String site;

  /// The service's name when it comes from the brand table; null for a site
  /// from the user's own vault.
  final String? brand;

  const KnownSite(this.site, {this.brand});

  bool get fromVault => brand == null;
}

class Lookalike {
  final LookalikeKind kind;

  /// The real site the page resembles; null for [LookalikeKind.mixedScripts]
  /// and [LookalikeKind.disguisedScript], which need nothing to compare
  /// against.
  final KnownSite? like;

  /// The page's registrable domain, or its whole address for the alphabet
  /// checks, since the part mixing alphabets may be in front of the site.
  final String page;

  /// For the alphabet checks, the alphabets found, Latin first: "Latin",
  /// "Cyrillic". Empty otherwise.
  final List<String> alphabets;

  const Lookalike(this.kind, this.like, this.page, {this.alphabets = const []});

  /// Everything except a shared name is a reason to stop.
  bool get isDanger => kind != LookalikeKind.sameName;
}

/// The sites to compare against: [vaultSites] (hosts or addresses saved in
/// entries) first, then the brand table. Duplicates and unusable hosts are
/// dropped.
List<KnownSite> knownSites(Iterable<String> vaultSites) {
  final seen = <String>{};
  final out = <KnownSite>[];
  for (final saved in vaultSites) {
    final site = hostOf(toAsciiHost(saved)).registrable;
    if (site != null && seen.add(site)) out.add(KnownSite(site));
  }
  for (final brand in knownBrands) {
    for (final domain in brand.domains) {
      final site = registrableDomain(domain).registrable;
      if (site != null && seen.add(site)) out.add(KnownSite(site, brand: brand.name));
    }
  }
  return out;
}

/// The most serious of [lookalikesOf], or null when there is nothing to
/// say.
Lookalike? lookalikeOf(String pageHost, List<KnownSite> known) =>
    lookalikesOf(pageHost, known).firstOrNull;

/// Everything [pageHost] gives away about itself, at most one of each kind,
/// most serious first; empty when it looks like nothing known (or is itself
/// known). Within a kind, the user's own sites come before the brand table.
/// All of them are kept, not just the one shown first, so a record of a
/// warning that was overridden can say everything that was known.
List<Lookalike> lookalikesOf(String pageHost, List<KnownSite> known) {
  // A host in other alphabets is put into its "xn--" form first, as a
  // browser would have; most already arrive that way.
  final page = hostOf(toAsciiHost(pageHost));
  final registrable = page.registrable;
  if (registrable == null) return const [];
  if (known.any((k) => k.site == registrable)) return const [];

  final name = _nameOf(registrable);
  final suffix = registrable.substring(name.length + 1);
  final nameSkeleton = _skeleton(name);
  // The words of the address in front of its ending, "secure", "paypal" and
  // "login" in "secure.paypal-login.com", each label decoded first so the
  // hyphens of "xn--" do not split it.
  final host = page.host!;
  final front = host.substring(0, host.length - suffix.length - 1);
  final parts = front
      .split('.')
      .expand((label) => decodeLabel(label).split('-'))
      .where((p) => p.isNotEmpty)
      .toList();

  Lookalike? found(LookalikeKind kind, bool Function(KnownSite k, String kName) test) {
    for (final k in known) {
      final kName = _nameOf(k.site);
      if (kName.length < _minName) continue;
      if (test(k, kName)) return Lookalike(kind, k, registrable);
    }
    return null;
  }

  return [
    found(
        LookalikeKind.confusable,
        (k, kName) => name != kName && nameSkeleton == _skeleton(kName),
      ),
    found(LookalikeKind.typo, (k, kName) {
        final a = nameSkeleton;
        final b = _skeleton(kName);
        if (a == b) return false;
        // Short names are a letter away from ordinary words ("apple",
        // "apply"), so only longer ones count.
        final allowed = kName.length >= 10 ? 2 : (kName.length >= 6 ? 1 : 0);
        return allowed > 0 && _distance(a, b, allowed) <= allowed;
      }),
    found(LookalikeKind.embedded, (k, kName) {
        // The whole real address inside this one, as in
        // "paypal.com.secure-check.io".
        if ('.$host.'.contains('.${k.site}.')) return true;
        // The real name as one word of the address. Only for names long
        // enough not to be ordinary words of other addresses.
        if (kName.length < _minEmbedded) return false;
        // A name that is the word alone ("amazon.xyz") is a shared name,
        // below, not a borrowed one.
        final want = _skeleton(kName);
        return nameSkeleton != want && parts.any((p) => _skeleton(p) == want);
      }),
    ..._scriptsOf(front.split('.'), suffix, host),
    // A shared name only asks for a closer look, so it comes after anything
    // that is a reason to stop.
    found(
      LookalikeKind.sameName,
      (k, kName) => name == kName && suffix != k.site.substring(kName.length + 1),
    ),
  ].nonNulls.toList();
}

/// The checks that need no known site: [labels] (everything in front of
/// the ending) mixing alphabets, or written wholly in letters that pass for
/// Latin ones under an ending in Latin letters. At most one of each.
List<Lookalike> _scriptsOf(List<String> labels, String suffix, String page) {
  final latinEnding = suffix.split('.').every((l) => !l.startsWith('xn--'));
  Lookalike? mixed;
  Lookalike? disguised;
  for (final label in labels) {
    final runes = decodeLabel(label).runes.toList();
    final scripts = {for (final r in runes) ?_scriptOf(r)};
    if (!scripts.any(_passesForLatin.contains)) continue;
    final alphabets = [
      for (final s in _Script.values)
        if (scripts.contains(s)) _alphabetNames[s]!,
    ];
    if (scripts.length > 1) {
      mixed ??= Lookalike(LookalikeKind.mixedScripts, null, page, alphabets: alphabets);
      continue;
    }
    final letters = runes.where((r) => _scriptOf(r) != null);
    if (latinEnding && letters.every(_readsAsLetter.containsKey)) {
      disguised ??= Lookalike(LookalikeKind.disguisedScript, null, page, alphabets: alphabets);
    }
  }
  return [?mixed, ?disguised];
}

enum _Script { latin, greek, cyrillic, armenian, other }

const Map<_Script, String> _alphabetNames = {
  _Script.latin: 'Latin',
  _Script.greek: 'Greek',
  _Script.cyrillic: 'Cyrillic',
  _Script.armenian: 'Armenian',
  _Script.other: 'another alphabet',
};

/// The alphabets with letters that pass for Latin ones.
const Set<_Script> _passesForLatin = {_Script.greek, _Script.cyrillic, _Script.armenian};

/// Which alphabet [r] belongs to, or null for a digit or hyphen, which
/// every alphabet shares.
_Script? _scriptOf(int r) {
  if (r == 0x2d || (r >= 0x30 && r <= 0x39)) return null;
  if ((r >= 0x61 && r <= 0x7a) ||
      (r >= 0xc0 && r <= 0x2af) ||
      (r >= 0x1e00 && r <= 0x1eff)) {
    return _Script.latin;
  }
  if ((r >= 0x370 && r <= 0x3ff) || (r >= 0x1f00 && r <= 0x1fff)) return _Script.greek;
  if ((r >= 0x400 && r <= 0x52f) ||
      (r >= 0x1c80 && r <= 0x1c8f) ||
      (r >= 0x2de0 && r <= 0x2dff) ||
      (r >= 0xa640 && r <= 0xa69f)) {
    return _Script.cyrillic;
  }
  if (r >= 0x530 && r <= 0x58f) return _Script.armenian;
  return _Script.other;
}

/// Shorter names ("bt", "x") match far too much to say anything.
const int _minName = 3;
const int _minEmbedded = 5;

String _nameOf(String registrable) => registrable.substring(0, registrable.indexOf('.'));

/// The name as it reads, rather than as it is spelled: an "xn--" name
/// decoded to what is shown, letters from other alphabets and letters with
/// marks read as the plain letter they pass for, characters people confuse
/// at a glance folded together, and hyphens dropped.
String _skeleton(String name) {
  final read = StringBuffer();
  for (final r in decodeLabel(name).runes) {
    read.write(_readsAsLetter[r] ?? String.fromCharCode(r));
  }
  final s = read
      .toString()
      .replaceAll('-', '')
      .replaceAll('rn', 'm')
      .replaceAll('vv', 'w');
  final out = StringBuffer();
  for (final c in s.split('')) {
    out.write(_confusables[c] ?? c);
  }
  return out.toString();
}

/// Letters from other alphabets that read as a Latin one (from Unicode's
/// list of confusable characters), and Latin letters with marks, under the
/// letter they pass for. extension/src/vault/lookalike.js has the same
/// table, and a test keeps the two alike.
const Map<String, String> _readsAs = {
  'a': 'аɑαàáâãäåāăąǎǟǡǻȁȃȧ',
  'b': 'ƅ',
  'c': 'сϲçćĉċč',
  'd': 'ԁďđ',
  'e': 'еҽèéêëēĕėęěȅȇȩ',
  'g': 'ɡցĝğġģǧǵ',
  'h': 'һհĥȟħ',
  'i': 'іıɩιìíîïĩīĭįǐȉȋ',
  'j': 'јϳĵǰ',
  'k': 'κкķǩ',
  'l': 'ӏĺļľł',
  'n': 'ոñńņňǹ',
  'o': 'оοօσòóôõöōŏőơǒǫǭȍȏȫȭȯȱø',
  'p': 'рρ',
  'q': 'ԛզ',
  'r': 'гŕŗřȑȓ',
  's': 'ѕśŝşšș',
  't': 'ţťțŧ',
  'u': 'սυʋùúûüũūŭůűųưǔǖǘǚǜȕȗ',
  'v': 'νѵ',
  'w': 'ԝѡŵ',
  'x': 'хχ',
  'y': 'уүγýÿŷȳ',
  'z': 'źżž',
};

final Map<int, String> _readsAsLetter = {
  for (final e in _readsAs.entries)
    for (final r in e.value.runes) r: e.key,
};

const Map<String, String> _confusables = {
  '0': 'o',
  '1': 'l',
};

/// Edit distance with swapped neighbours counting once ("amzaon"), giving
/// up early once it is past [limit].
int _distance(String a, String b, int limit) {
  if ((a.length - b.length).abs() > limit) return limit + 1;
  final rows = List.generate(a.length + 1, (_) => List<int>.filled(b.length + 1, 0));
  for (var i = 0; i <= a.length; i++) {
    rows[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    rows[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var best = [
        rows[i - 1][j] + 1,
        rows[i][j - 1] + 1,
        rows[i - 1][j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
        best = best < rows[i - 2][j - 2] + 1 ? best : rows[i - 2][j - 2] + 1;
      }
      rows[i][j] = best;
    }
  }
  return rows[a.length][b.length];
}

/// "Latin and Cyrillic", "Latin, Greek and Cyrillic".
String _both(List<String> names) => names.length < 2
    ? names.join()
    : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

/// What tripped the warning, in a few words, for the record kept when it is
/// overridden: "resembles amazon.in", "mixes Latin and Cyrillic letters".
String lookalikeReason(Lookalike l) {
  final like = l.like;
  return switch (l.kind) {
    LookalikeKind.mixedScripts => 'mixes ${_both(l.alphabets)} letters',
    LookalikeKind.disguisedScript =>
      'written in ${l.alphabets.first} letters that pass for English ones',
    LookalikeKind.confusable when _foreignLetters(l.page) =>
      'spelled in another alphabet to look like ${like!.site}',
    LookalikeKind.confusable || LookalikeKind.typo => 'resembles ${like!.site}',
    LookalikeKind.embedded =>
      'uses the name "${_nameOf(like!.site)}" but is not ${like.site}',
    LookalikeKind.sameName => 'same name as ${like!.site}, different ending',
  };
}

/// Whether [site] has a part written in other alphabets ("xn--").
bool _foreignLetters(String site) => site.split('.').any((l) => l.startsWith('xn--'));

/// The warning in words, for the app and (in lookalike.js) the extension.
String describeLookalike(Lookalike l) {
  final like = l.like;
  final whose = like == null
      ? ''
      : like.fromVault
      ? ', where you have a login'
      : ", ${like.brand}'s site";
  switch (l.kind) {
    case LookalikeKind.mixedScripts:
      return '${l.page} mixes ${_both(l.alphabets)} letters in one name. Real '
          'sites almost never do; scam sites do it so an address looks like '
          'one you know.';
    case LookalikeKind.disguisedScript:
      return '${l.page} is written entirely in ${l.alphabets.first} letters '
          'that look like English ones, so it can pass for a different '
          'address. Scam sites do this.';
    case LookalikeKind.confusable when _foreignLetters(l.page):
      // Shown in the form that cannot pass for the real one.
      return '${l.page} is spelled with letters from another alphabet so it '
          'looks exactly like ${like!.site}$whose. It is a different site. '
          'Scam sites copy names this way.';
    case LookalikeKind.confusable:
    case LookalikeKind.typo:
      return '${l.page} looks like ${like!.site}$whose, but it is a different '
          'site. Scam sites copy names this way.';
    case LookalikeKind.embedded:
      return '${l.page} uses the name "${_nameOf(like!.site)}" in its address, '
          'but it is not ${like.site}$whose. Scam sites copy names this way.';
    case LookalikeKind.sameName:
      return '${l.page} has the same name as ${like!.site}$whose, with a '
          'different ending. Companies often own both, but so do scam sites. '
          'Check this is where you meant to sign in.';
  }
}
