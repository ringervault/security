import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// When a website's domain was registered, from its registry (RDAP).
///
/// Scam sites are usually days or weeks old: they are registered for one
/// campaign and abandoned once blocklists catch up. A registry's record of
/// when a domain was first registered cannot be set by whoever runs the
/// site, so "registered 4 days ago" is worth saying before a password goes
/// in. An old domain proves nothing (one can be bought), so age is only
/// ever used to warn, never to reassure.
///
/// Asked only at the moment a login is about to be used or saved on a site
/// it is not linked to, never for ordinary fills, never in Strict Offline
/// Mode, and only once the user has turned it on in Settings (it is off
/// until then). The question goes straight to the registry that runs the
/// domain's ending (found through IANA's public list), which learns which
/// domain was asked about; no third party is in between. Answers are kept
/// in memory only, so no list of asked-about sites is ever written down.
///
/// extension/src/vault/domain_age.js is the same for the browser extension.
class DomainAge {
  DomainAge({http.Client? client, this.timeout = const Duration(seconds: 5)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// IANA's list of which RDAP server answers for which ending.
  static final Uri bootstrapUri = Uri.https('data.iana.org', '/rdap/dns.json');

  Future<Map<String, Uri>?>? _servers;
  final Map<String, Future<DateTime?>> _answers = {};

  /// The largest answer read. Real ones are a few kilobytes; the IANA list
  /// is under 100.
  static const int _maxBytes = 512 * 1024;

  /// When [registrable] (such as "amazon.in") was registered, or null when
  /// the registry does not say: offline, no RDAP for that ending, a
  /// timeout, or a site under a shared ending such as "alice.github.io".
  Future<DateTime?> registered(String registrable) =>
      _answers[registrable] ??= _registered(registrable);

  Future<DateTime?> _registered(String domain) async {
    final servers = await (_servers ??= _loadServers());
    if (servers == null) {
      // Try the list again next time rather than remembering a failure.
      _servers = null;
      _answers.remove(domain);
      return null;
    }
    final ending = domain.substring(domain.lastIndexOf('.') + 1);
    final base = servers[ending];
    if (base == null) return null;
    final body = await _get(base.resolve('domain/$domain'));
    if (body == null) return null;
    return registeredIn(body);
  }

  Future<Map<String, Uri>?> _loadServers() async {
    final body = await _get(bootstrapUri);
    return body == null ? null : rdapServers(body);
  }

  Future<String?> _get(Uri uri) async {
    try {
      // Not followed: registries answer directly, and a redirect could hand
      // the question to anyone.
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Accept'] = 'application/rdap+json, application/json';
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

/// Reads IANA's bootstrap file: each ending to the first https server
/// listed for it.
Map<String, Uri>? rdapServers(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['services'] is! List) return null;
    final out = <String, Uri>{};
    for (final service in decoded['services'] as List) {
      if (service is! List || service.length < 2) continue;
      final endings = service[0];
      final urls = service[1];
      if (endings is! List || urls is! List) continue;
      final url = urls
          .whereType<String>()
          .map(Uri.tryParse)
          .whereType<Uri>()
          .where((u) => u.scheme == 'https')
          .firstOrNull;
      if (url == null) continue;
      // Every base is used as a directory.
      final base = url.path.endsWith('/') ? url : url.replace(path: '${url.path}/');
      for (final ending in endings.whereType<String>()) {
        out[ending.toLowerCase()] = base;
      }
    }
    return out;
  } on FormatException {
    return null;
  }
}

/// The registration date in an RDAP domain answer, or null.
DateTime? registeredIn(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['events'] is! List) return null;
    for (final event in decoded['events'] as List) {
      if (event is Map && event['eventAction'] == 'registration') {
        final date = event['eventDate'];
        if (date is String) return DateTime.tryParse(date)?.toUtc();
      }
    }
    return null;
  } on FormatException {
    return null;
  }
}

/// How worried to be about a domain registered on [registered].
enum AgeConcern {
  /// Under a month old.
  danger,

  /// Under six months old.
  caution,

  /// Old enough to say nothing about.
  none,
}

AgeConcern ageConcern(DateTime registered, DateTime now) {
  final days = now.difference(registered).inDays;
  if (days < 30) return AgeConcern.danger;
  if (days < 182) return AgeConcern.caution;
  return AgeConcern.none;
}

/// The warning in words, or null when the age is not worth a mention.
String? describeAge(String site, DateTime registered, DateTime now) {
  final concern = ageConcern(registered, now);
  if (concern == AgeConcern.none) return null;
  final when = _ago(registered, now);
  return concern == AgeConcern.danger
      ? '$site was registered $when. Scam sites are usually only days old.'
      : '$site was registered $when. New sites deserve a closer look.';
}

/// The warning in a few words, for the record kept when it is overridden:
/// "registered 4 days ago". Null when the age is not worth a mention.
String? ageReason(DateTime registered, DateTime now) =>
    ageConcern(registered, now) == AgeConcern.none
    ? null
    : 'registered ${_ago(registered, now)}';

String _ago(DateTime registered, DateTime now) {
  final days = now.difference(registered).inDays;
  return days <= 0
      ? 'today'
      : days == 1
      ? 'yesterday'
      : days < 14
      ? '$days days ago'
      : days < 60
      ? '${days ~/ 7} weeks ago'
      : '${days ~/ 30} months ago';
}
