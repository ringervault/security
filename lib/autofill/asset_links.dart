import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Whether a website says an Android app is its own.
///
/// A website lists the apps it owns in `/.well-known/assetlinks.json`
/// (Digital Asset Links), naming each by package and signing certificate.
/// It is the check Android itself uses for app links, and the one Bitwarden
/// and 1Password use before offering a website's login to an app.
///
/// It matters here because the autofill list suggests a website's entry to
/// an app by name ("Amazon" for an app called Amazon). A lookalike app can
/// be called anything; it cannot be listed in amazon.in's file, signed with
/// Amazon's key, unless Amazon put it there.
///
/// Only ever a hint, in both directions. Being listed makes the first fill
/// say "verified". Not being listed is common for genuine apps (many sites
/// never publish the file), so it asks for a closer look rather than
/// refusing.
enum LinkCheck {
  /// The site lists this package with this signing certificate.
  verified,

  /// The site answered, and this app is not in its list.
  notListed,

  /// No answer: offline, Strict Offline Mode, a timeout, or no file.
  unknown,
}

/// Relations that say the app speaks for the site. `get_login_creds` is the
/// one meant for sharing logins; `handle_all_urls` (app links) also means
/// the site vouches for the app, and is far more often published.
const Set<String> _relations = {
  'delegate_permission/common.get_login_creds',
  'delegate_permission/common.handle_all_urls',
};

/// Whether [body], an assetlinks.json document, lists [packageName] signed
/// with [certificateSha256] (lowercase hex, no colons) under a relation
/// that vouches for it.
bool assetLinksAllow(String body, {required String packageName, required String certificateSha256}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return false;
  }
  if (decoded is! List) return false;
  final want = certificateSha256.toLowerCase();
  for (final statement in decoded) {
    if (statement is! Map) continue;
    final relation = statement['relation'];
    if (relation is! List || !relation.any(_relations.contains)) continue;
    final target = statement['target'];
    if (target is! Map) continue;
    if (target['namespace'] != 'android_app') continue;
    if (target['package_name'] != packageName) continue;
    final prints = target['sha256_cert_fingerprints'];
    if (prints is! List) continue;
    for (final p in prints) {
      if (p is String && p.replaceAll(':', '').toLowerCase() == want) return true;
    }
  }
  return false;
}

class AssetLinks {
  AssetLinks({http.Client? client, this.timeout = const Duration(seconds: 5)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// Answers already fetched, for the life of the autofill engine. A site's
  /// list changes rarely, and asking again for every fill would tell the
  /// site each time someone signs in.
  final Map<String, Future<LinkCheck>> _answers = {};

  /// The largest file read. Real ones are a few kilobytes.
  static const int _maxBytes = 128 * 1024;

  /// Whether [site] (a host, as an entry stores it) lists the app.
  Future<LinkCheck> check({
    required String site,
    required String packageName,
    required String certificateSha256,
  }) {
    final key = '$site|$packageName|$certificateSha256';
    return _answers[key] ??= _check(site, packageName, certificateSha256);
  }

  Future<LinkCheck> _check(String site, String packageName, String cert) async {
    // Entries keep the address without "www.", and some sites only answer
    // on it, so both are asked.
    final hosts = [site, if (!site.startsWith('www.')) 'www.$site'];
    var answered = false;
    for (final host in hosts) {
      final body = await _fetch(host);
      if (body == null) continue;
      answered = true;
      if (assetLinksAllow(body, packageName: packageName, certificateSha256: cert)) {
        return LinkCheck.verified;
      }
    }
    return answered ? LinkCheck.notListed : LinkCheck.unknown;
  }

  /// The file's text, or null for no usable answer. Never follows a
  /// redirect: the specification forbids them, so a redirected answer could
  /// be some other site speaking.
  Future<String?> _fetch(String host) async {
    try {
      final request = http.Request('GET', Uri.https(host, '/.well-known/assetlinks.json'))
        ..followRedirects = false
        ..headers['Accept'] = 'application/json';
      final response = await _client.send(request).timeout(timeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) return null;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
