import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ringer_vault/autofill/brand_map.dart';
import 'package:ringer_vault/autofill/domain_age.dart';
import 'package:ringer_vault/autofill/lookalike.dart';
import 'package:ringer_vault/autofill/punycode.dart';

/// The cases in test/fixtures/lookalike_cases.json, which the browser
/// extension's tests run too.
void main() {
  final fixture = jsonDecode(
    File('test/fixtures/lookalike_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final known = knownSites((fixture['vault'] as List).cast<String>());

  group('look-alike cases', () {
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test('${c['page']}: ${c['why']}', () {
        final result = lookalikeOf(c['page'] as String, known);
        if (c['kind'] == null) {
          expect(result, isNull);
        } else {
          expect(result, isNotNull);
          expect(result!.kind.name, c['kind']);
          expect(result.like?.site, c['like']);
          expect(result.like?.fromVault, c['fromVault']);
          if (c['alphabets'] != null) expect(result.alphabets, c['alphabets']);
        }
        if (c['all'] != null) {
          expect([for (final l in lookalikesOf(c['page'] as String, known)) l.kind.name], c['all']);
        }
      });
    }
  });

  test('the warning names the site and whose it is', () {
    final mine = lookalikeOf('amaz0n.in', known)!;
    expect(describeLookalike(mine), contains('amazon.in, where you have a login'));
    final brand = lookalikeOf('paypa1.com', known)!;
    expect(describeLookalike(brand), contains("paypal.com, PayPal's site"));
    expect(lookalikeOf('amazon.xyz', known)!.isDanger, isFalse);
  });

  test('a name in another alphabet is named in the form that cannot pass', () {
    final l = lookalikeOf('xn--mazon-3ve.in', known)!;
    expect(describeLookalike(l), startsWith('xn--mazon-3ve.in is spelled with letters from '
        'another alphabet so it looks exactly like amazon.in'));
    expect(l.isDanger, isTrue);
  });

  test('each warning in a few words, for the record of an override', () {
    String reason(String page) => lookalikeReason(lookalikeOf(page, known)!);
    expect(reason('amaz0n.in'), 'resembles amazon.in');
    expect(reason('xn--mazon-3ve.in'), 'spelled in another alphabet to look like amazon.in');
    expect(reason('amazon-offers.com'), 'uses the name "amazon" but is not amazon.in');
    expect(reason('amazon.xyz'), 'same name as amazon.in, different ending');
    expect(reason('xn--bnkofzanzibar-w1k.com'), 'mixes Latin and Cyrillic letters');
    expect(reason('xn--n1aahb.com'), 'written in Cyrillic letters that pass for English ones');
  });

  test('an address mixing alphabets is named in full, and is a reason to stop', () {
    final l = lookalikeOf('xn--lgin-55d.example.com', known)!;
    expect(describeLookalike(l), startsWith('xn--lgin-55d.example.com mixes Latin and '
        'Cyrillic letters in one name'));
    expect(l.isDanger, isTrue);
    expect(describeLookalike(lookalikeOf('xn--n1aahb.com', known)!),
        startsWith('xn--n1aahb.com is written entirely in Cyrillic letters'));
  });

  group('punycode', () {
    for (final pair in (fixture['punycode'] as List).skip(1).cast<List>()) {
      final shown = pair[0] as String;
      final sent = pair[1] as String;
      test('$shown is $sent', () {
        expect(decodeLabel(sent), shown);
        expect(toAsciiHost('$shown.com'), '$sent.com');
      });
    }

    test('only the host of an address is converted', () {
      expect(toAsciiHost('https://p\u0430ypal.com:8443/log\u0456n?q=\u0430'),
          'https://xn--pypal-4ve.com:8443/log\u0456n?q=\u0430');
      expect(toAsciiHost('amazon.in'), 'amazon.in');
    });

    test('a broken label is left as it is', () {
      expect(decodeLabel('xn--abc-9!'), 'xn--abc-9!');
      expect(decodeLabel('xn--\u0430-abc'), 'xn--\u0430-abc');
      expect(decodeLabel('plain'), 'plain');
    });
  });

  test("the extension's table of letters that pass for others is the same", () {
    // Both files spell it as one line per letter: 'a': '...', or a: '...'.
    Map<String, String> tableIn(String path) {
      final source = File(path).readAsStringSync();
      final block = RegExp(r'_?READS_AS = \{([^}]*)\}|_readsAs = \{([^}]*)\}').firstMatch(source)!;
      final body = block.group(1) ?? block.group(2)!;
      return {
        for (final m in RegExp(r"'?([a-z])'?: '([^']*)'").allMatches(body)) m.group(1)!: m.group(2)!,
      };
    }

    final dart = tableIn('lib/autofill/lookalike.dart');
    expect(dart, isNotEmpty);
    expect(tableIn('extension/src/vault/lookalike.js'), dart);
  });

  test("the extension's brand table lists the same domains", () {
    // extension/src/vault/known_sites.js is a copy; this keeps it one.
    final js = File('extension/src/vault/known_sites.js').readAsStringSync();
    final inJs = RegExp(r"'([a-z0-9.-]+\.[a-z]+)'")
        .allMatches(js)
        .map((m) => m.group(1)!)
        .toSet();
    final inDart = {for (final b in knownBrands) ...b.domains};
    expect(inJs, inDart);
  });

  group('domain age', () {
    const bootstrap = '''
{"services": [
  [["in", "co"], ["https://rdap.registry.in/"]],
  [["com", "net"], ["http://insecure.example/", "https://rdap.verisign.com/com/v1"]]
]}''';

    String answer(String date) => jsonEncode({
          'events': [
            {'eventAction': 'last changed', 'eventDate': '2026-01-01T00:00:00Z'},
            {'eventAction': 'registration', 'eventDate': date},
          ],
        });

    test('reads the bootstrap, preferring https, and adds a slash', () {
      final servers = rdapServers(bootstrap)!;
      expect(servers['in'].toString(), 'https://rdap.registry.in/');
      expect(servers['com'].toString(), 'https://rdap.verisign.com/com/v1/');
      expect(rdapServers('not json'), isNull);
    });

    test('asks the right registry, once', () async {
      final asked = <String>[];
      final client = MockClient((request) async {
        asked.add(request.url.toString());
        if (request.url.host == 'data.iana.org') return http.Response(bootstrap, 200);
        if (request.url.path.endsWith('/domain/amaz0n.in')) {
          return http.Response(answer('2026-10-03T08:00:00Z'), 200);
        }
        return http.Response('', 404);
      });
      final age = DomainAge(client: client);
      final first = await age.registered('amaz0n.in');
      expect(first, DateTime.utc(2026, 10, 3, 8));
      await age.registered('amaz0n.in');
      expect(asked, [
        'https://data.iana.org/rdap/dns.json',
        'https://rdap.registry.in/domain/amaz0n.in',
      ]);
      expect(
        await age.registered('alice.github.io'),
        isNull,
        reason: 'no registry for .io in this list',
      );
      expect(await age.registered('nothere.com'), isNull, reason: '404');
    });

    test('a failed bootstrap is tried again next time', () async {
      var up = false;
      final client = MockClient((request) async {
        if (!up) return http.Response('', 503);
        if (request.url.host == 'data.iana.org') return http.Response(bootstrap, 200);
        return http.Response(answer('2020-01-01T00:00:00Z'), 200);
      });
      final age = DomainAge(client: client);
      expect(await age.registered('mybank.co'), isNull);
      up = true;
      expect(await age.registered('mybank.co'), DateTime.utc(2020));
    });

    test('says how new, only when new', () {
      final now = DateTime.utc(2026, 10, 7);
      expect(ageConcern(DateTime.utc(2026, 10, 3), now), AgeConcern.danger);
      expect(ageConcern(DateTime.utc(2026, 6, 1), now), AgeConcern.caution);
      expect(ageConcern(DateTime.utc(2019, 1, 1), now), AgeConcern.none);
      expect(describeAge('amaz0n.in', DateTime.utc(2026, 10, 3), now),
          'amaz0n.in was registered 4 days ago. Scam sites are usually only days old.');
      expect(describeAge('x.in', DateTime.utc(2026, 10, 5, 12), now), contains('yesterday'));
      expect(describeAge('x.in', DateTime.utc(2026, 8, 20), now), contains('6 weeks ago'));
      expect(describeAge('x.in', DateTime.utc(2019, 1, 1), now), isNull);
    });
  });
}
