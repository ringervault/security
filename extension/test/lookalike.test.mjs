// The cases in test/fixtures/lookalike_cases.json, which the app's Dart tests
// also run, and the domain-age reader.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { domainToASCII } from 'node:url';
import { describeLookalike, knownSites, lookalikeOf, lookalikesOf } from '../src/vault/lookalike.js';
import { decodeLabel, toAsciiHost } from '../src/vault/punycode.js';
import {
  AgeConcern, ageConcern, describeAge, DomainAge, rdapServers,
} from '../src/vault/domain_age.js';

const fixture = JSON.parse(
  readFileSync(new URL('../../test/fixtures/lookalike_cases.json', import.meta.url)),
);
const known = knownSites(fixture.vault);

for (const c of fixture.cases) {
  test(`look-alike: ${c.page}: ${c.why}`, () => {
    const result = lookalikeOf(c.page, known);
    if (c.kind === null) {
      assert.equal(result, null);
    } else {
      assert.ok(result);
      assert.equal(result.kind, c.kind);
      assert.equal(result.like?.site ?? null, c.like);
      assert.equal(result.like === null ? null : result.like.brand === null, c.fromVault);
      if (c.alphabets) assert.deepEqual(result.alphabets, c.alphabets);
    }
    if (c.all) {
      assert.deepEqual(lookalikesOf(c.page, known).map((l) => l.kind), c.all);
    }
  });
}

test('a name in another alphabet is named in the form that cannot pass', () => {
  const l = lookalikeOf('xn--mazon-3ve.in', known);
  assert.ok(describeLookalike(l).startsWith('xn--mazon-3ve.in is spelled with letters from '
    + 'another alphabet so it looks exactly like amazon.in'));
  assert.equal(l.danger, true);
});

test('an address mixing alphabets is named in full, and is a reason to stop', () => {
  const l = lookalikeOf('xn--lgin-55d.example.com', known);
  assert.ok(describeLookalike(l).startsWith('xn--lgin-55d.example.com mixes Latin and '
    + 'Cyrillic letters in one name'));
  assert.equal(l.danger, true);
  assert.ok(describeLookalike(lookalikeOf('xn--n1aahb.com', known))
    .startsWith('xn--n1aahb.com is written entirely in Cyrillic letters'));
});

for (const [shown, sent] of fixture.punycode.slice(1)) {
  test(`punycode: ${shown} is ${sent}`, () => {
    assert.equal(decodeLabel(sent), shown);
    assert.equal(toAsciiHost(`${shown}.com`), `${sent}.com`);
    assert.equal(toAsciiHost(`${shown}.com`), domainToASCII(`${shown}.com`));
  });
}

test('punycode: only the host of an address is converted', () => {
  assert.equal(toAsciiHost('https://p\u0430ypal.com:8443/log\u0456n?q=\u0430'),
    'https://xn--pypal-4ve.com:8443/log\u0456n?q=\u0430');
  assert.equal(toAsciiHost('amazon.in'), 'amazon.in');
});

test('punycode: a broken label is left as it is', () => {
  assert.equal(decodeLabel('xn--abc-9!'), 'xn--abc-9!');
  assert.equal(decodeLabel('xn--\u0430-abc'), 'xn--\u0430-abc');
  assert.equal(decodeLabel('plain'), 'plain');
});

test('the warning names the site and whose it is', () => {
  assert.match(describeLookalike(lookalikeOf('amaz0n.in', known)), /amazon\.in, where you have a login/);
  assert.match(describeLookalike(lookalikeOf('paypa1.com', known)), /paypal\.com, PayPal's site/);
  assert.equal(lookalikeOf('amazon.xyz', known).danger, false);
  assert.equal(lookalikeOf('amaz0n.in', known).danger, true);
});

const bootstrap = JSON.stringify({
  services: [
    [['in', 'co'], ['https://rdap.registry.in/']],
    [['com'], ['http://insecure.example/', 'https://rdap.verisign.com/com/v1']],
  ],
});
const answer = (date) => JSON.stringify({
  events: [
    { eventAction: 'last changed', eventDate: '2026-01-01T00:00:00Z' },
    { eventAction: 'registration', eventDate: date },
  ],
});
const reply = (body, status = 200) => ({ ok: status === 200, text: async () => body });

test('reads the bootstrap, preferring https', () => {
  const servers = rdapServers(bootstrap);
  assert.equal(servers.get('in'), 'https://rdap.registry.in/');
  assert.equal(servers.get('com'), 'https://rdap.verisign.com/com/v1/');
  assert.equal(rdapServers('not json'), null);
});

test('asks the right registry, once, and never follows a redirect', async () => {
  const asked = [];
  const age = new DomainAge(async (url, options) => {
    asked.push(url);
    assert.equal(options.redirect, 'error');
    assert.equal(options.credentials, 'omit');
    if (url.includes('iana.org')) return reply(bootstrap);
    if (url.endsWith('/domain/amaz0n.in')) return reply(answer('2026-10-03T08:00:00Z'));
    return reply('', 404);
  });
  assert.equal((await age.registered('amaz0n.in')).toISOString(), '2026-10-03T08:00:00.000Z');
  await age.registered('amaz0n.in');
  assert.deepEqual(asked, [
    'https://data.iana.org/rdap/dns.json',
    'https://rdap.registry.in/domain/amaz0n.in',
  ]);
  assert.equal(await age.registered('alice.github.io'), null);
  assert.equal(await age.registered('nothere.com'), null);
});

test('a failed bootstrap is tried again next time', async () => {
  let up = false;
  const age = new DomainAge(async (url) => {
    if (!up) return reply('', 503);
    if (url.includes('iana.org')) return reply(bootstrap);
    return reply(answer('2020-01-01T00:00:00Z'));
  });
  assert.equal(await age.registered('mybank.co'), null);
  up = true;
  assert.equal((await age.registered('mybank.co')).getUTCFullYear(), 2020);
});

test('says how new, only when new', () => {
  const now = new Date(Date.UTC(2026, 9, 7));
  assert.equal(ageConcern(new Date(Date.UTC(2026, 9, 3)), now), AgeConcern.danger);
  assert.equal(ageConcern(new Date(Date.UTC(2026, 5, 1)), now), AgeConcern.caution);
  assert.equal(ageConcern(new Date(Date.UTC(2019, 0, 1)), now), AgeConcern.none);
  assert.equal(describeAge('amaz0n.in', new Date(Date.UTC(2026, 9, 3)), now),
    'amaz0n.in was registered 4 days ago. Scam sites are usually only days old.');
  assert.match(describeAge('x.in', new Date(Date.UTC(2026, 9, 5, 12)), now), /yesterday/);
  assert.match(describeAge('x.in', new Date(Date.UTC(2026, 7, 20)), now), /6 weeks ago/);
  assert.equal(describeAge('x.in', new Date(Date.UTC(2019, 0, 1)), now), null);
});
