import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ringer_vault/autofill/asset_links.dart';

const pkg = 'in.amazon.mShop.android.shopping';
const cert = '146de983c5730650ee8bf3a2ff5a2a4cf3e0d0f6c7b3f7e3d3b5b4a1c2d3e4f5';
String colons(String hex) => [
      for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2).toUpperCase(),
    ].join(':');

String statements({
  String relation = 'delegate_permission/common.get_login_creds',
  String package = pkg,
  String fingerprint = cert,
}) =>
    jsonEncode([
      {
        'relation': [relation],
        'target': {
          'namespace': 'android_app',
          'package_name': package,
          'sha256_cert_fingerprints': [colons(fingerprint)],
        },
      },
    ]);

void main() {
  group('reading the file', () {
    test('the app, signed with this key, for sharing logins', () {
      expect(assetLinksAllow(statements(), packageName: pkg, certificateSha256: cert), isTrue);
    });

    test('app links also count: the site vouches for the app', () {
      expect(
        assetLinksAllow(statements(relation: 'delegate_permission/common.handle_all_urls'),
            packageName: pkg, certificateSha256: cert),
        isTrue,
      );
    });

    test('the same package signed by someone else does not', () {
      expect(
        assetLinksAllow(statements(fingerprint: 'ab' * 32), packageName: pkg, certificateSha256: cert),
        isFalse,
      );
    });

    test('another package does not', () {
      expect(
        assetLinksAllow(statements(package: 'com.lookalike.amazon'),
            packageName: pkg, certificateSha256: cert),
        isFalse,
      );
    });

    test('an unrelated relation does not', () {
      expect(
        assetLinksAllow(statements(relation: 'something/else'), packageName: pkg, certificateSha256: cert),
        isFalse,
      );
    });

    test('rubbish is not a yes', () {
      for (final body in ['', 'not json', '{}', '[1, 2]', '[{"target": 3}]']) {
        expect(assetLinksAllow(body, packageName: pkg, certificateSha256: cert), isFalse, reason: body);
      }
    });
  });

  group('asking the site', () {
    test('verified, and asked only once', () async {
      var asked = 0;
      final links = AssetLinks(client: MockClient((request) async {
        asked++;
        expect(request.url.toString(), 'https://amazon.in/.well-known/assetlinks.json');
        return http.Response(statements(), 200);
      }));
      expect(await links.check(site: 'amazon.in', packageName: pkg, certificateSha256: cert),
          LinkCheck.verified);
      expect(await links.check(site: 'amazon.in', packageName: pkg, certificateSha256: cert),
          LinkCheck.verified);
      expect(asked, 1);
    });

    test('a site that answers only on www. is asked there too', () async {
      final links = AssetLinks(client: MockClient((request) async =>
          request.url.host == 'www.example.com'
              ? http.Response(statements(), 200)
              : http.Response('', 404)));
      expect(await links.check(site: 'example.com', packageName: pkg, certificateSha256: cert),
          LinkCheck.verified);
    });

    test('a list without the app is "not listed"', () async {
      final links = AssetLinks(client: MockClient((_) async => http.Response('[]', 200)));
      expect(await links.check(site: 'amazon.in', packageName: pkg, certificateSha256: cert),
          LinkCheck.notListed);
    });

    test('no file, a redirect, or no network is "unknown", never a yes', () async {
      for (final answer in [
        http.Response('', 404),
        http.Response('', 302, headers: {'location': 'https://elsewhere.example/'}),
      ]) {
        final links = AssetLinks(client: MockClient((_) async => answer));
        expect(await links.check(site: 'amazon.in', packageName: pkg, certificateSha256: cert),
            LinkCheck.unknown);
      }
      final offline = AssetLinks(client: MockClient((_) async => throw Exception('offline')));
      expect(await offline.check(site: 'amazon.in', packageName: pkg, certificateSha256: cert),
          LinkCheck.unknown);
    });

    test('a site that sends its file a byte at a time cannot hold the check open', () async {
      // Each byte arrives well inside the timeout; the whole never does.
      Stream<List<int>> drip() async* {
        for (final b in utf8.encode(statements())) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          yield [b];
        }
      }
      final links = AssetLinks(
        client: MockClient.streaming((request, _) async => http.StreamedResponse(drip(), 200)),
        timeout: const Duration(milliseconds: 200),
      );
      final watch = Stopwatch()..start();
      expect(await links.check(site: 'amazon.in', packageName: pkg, certificateSha256: cert),
          LinkCheck.unknown);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a site that never answers gives up', () async {
      final links = AssetLinks(
        client: MockClient((_) => Future.delayed(const Duration(seconds: 30), () => http.Response('[]', 200))),
        timeout: const Duration(milliseconds: 50),
      );
      expect(await links.check(site: 'amazon.in', packageName: pkg, certificateSha256: cert),
          LinkCheck.unknown);
    });
  });
}
