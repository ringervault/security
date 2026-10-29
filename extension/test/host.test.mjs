// The matching rules, tested as attacks rather than as string cases.
// These must agree with test/autofill_target_test.dart on the Dart side.

import test from 'node:test';
import assert from 'node:assert/strict';
import { registrableDomain, hostOf, HostRejection, isLoopback, isSecurePage } from '../src/vault/host.js';
import { candidatesFor } from '../src/vault/match.js';

test('a subdomain is the same site', () => {
  assert.equal(registrableDomain('secure.chase.com').registrable, 'chase.com');
  assert.equal(registrableDomain('www.chase.com').registrable, 'chase.com');
  assert.equal(registrableDomain('chase.com').registrable, 'chase.com');
});

test('a domain that merely ends in the real name is not the real site', () => {
  // The classic: chase.com.evil.io belongs to evil.io.
  assert.equal(registrableDomain('chase.com.evil.io').registrable, 'evil.io');
  assert.equal(registrableDomain('evil-chase.com').registrable, 'evil-chase.com');
  assert.equal(registrableDomain('chasecom.net').registrable, 'chasecom.net');
});

test('look-alike characters are refused outright', () => {
  // Refusing beats normalising: there is no safe reading of a host that is
  // pretending to be another one.
  const result = registrableDomain('chase.com'.replace('a', 'а'));
  assert.equal(result.isUsable, false);
  assert.equal(result.rejection, HostRejection.nonAscii);
});

test('multi-label suffixes are one site, not two', () => {
  assert.equal(registrableDomain('mail.bbc.co.uk').registrable, 'bbc.co.uk');
  assert.equal(registrableDomain('bbc.co.uk').registrable, 'bbc.co.uk');
});

test('two people on the same host are two different sites', () => {
  // Without this, a credential saved for one github.io page would be offered
  // on everyone else's.
  assert.equal(registrableDomain('alice.github.io').registrable, 'alice.github.io');
  assert.equal(registrableDomain('evil.github.io').registrable, 'evil.github.io');
  assert.notEqual(
    registrableDomain('alice.github.io').registrable,
    registrableDomain('evil.github.io').registrable,
  );
});

test('a bare public suffix belongs to nobody', () => {
  assert.equal(registrableDomain('co.uk').rejection, HostRejection.publicSuffixOnly);
  assert.equal(registrableDomain('github.io').rejection, HostRejection.publicSuffixOnly);
});

test('IP addresses are never matched', () => {
  assert.equal(registrableDomain('192.168.1.1').rejection, HostRejection.ipAddress);
});

test('malformed hosts are rejected rather than guessed at', () => {
  for (const bad of ['', '   ', 'has space.com', '.com', 'a..b']) {
    assert.equal(registrableDomain(bad).isUsable, false, `accepted: "${bad}"`);
  }
});

test('a URL is reduced the same way as a bare host', () => {
  assert.equal(hostOf('https://secure.chase.com/login?x=1').registrable, 'chase.com');
  assert.equal(hostOf('chase.com/login').registrable, 'chase.com');
  assert.equal(hostOf('https://chase.com.evil.io/').registrable, 'evil.io');
});

const entry = (id, title, targets) => ({
  id, title, username: 'u', email: '', password: 'p',
  category: '', notes: '', autofillTargets: targets,
});

test('only an entry saved for the site counts as a match', () => {
  const entries = [
    entry('1', 'Chase', ['site:chase.com']),
    entry('2', 'Other', ['site:example.com']),
  ];
  const result = candidatesFor(entries, 'https://secure.chase.com/login');

  assert.equal(result.domain, 'secure.chase.com', 'the exact address is shown');
  assert.deepEqual(result.matched.map((c) => c.entry.id), ['1']);
  assert.deepEqual(result.others.map((c) => c.entry.id), ['2']);
});

test('an exact address fills; another part of the site asks first', () => {
  // A login saved on accounts.google.com must not be offered as a plain
  // match on docs.google.com, where anyone can publish a form.
  const entries = [
    entry('exact', 'Google', ['site:accounts.google.com']),
  ];
  const onLogin = candidatesFor(entries, 'https://accounts.google.com/signin');
  const onDocs = candidatesFor(entries, 'https://docs.google.com/forms/x');

  assert.equal(onLogin.matched[0].strength, 'saved');
  assert.equal(onDocs.matched[0].strength, 'sameSite');
  assert.deepEqual(onDocs.matched[0].savedFor, ['accounts.google.com']);
});

test('a plain http page is flagged and never a straight match', () => {
  const result = candidatesFor(
    [entry('1', 'Router', ['site:example.com'])],
    'http://example.com/login',
  );
  assert.equal(result.insecure, true);
  assert.equal(result.matched[0].strength, 'insecure');
});

test('pages that are not websites offer nothing', () => {
  for (const url of ['chrome://settings', 'file:///tmp/a.html', 'about:blank']) {
    const result = candidatesFor([entry('1', 'X', ['site:example.com'])], url);
    assert.equal(result.domain, null, url);
    assert.equal(result.matched.length + result.others.length, 0, url);
  }
});

test('a title that looks like the site proves nothing', () => {
  // The user types the title and the attacker owns the page, so a name in
  // common is not evidence of anything.
  const entries = [entry('1', 'chase.com', [])];
  const result = candidatesFor(entries, 'https://chase.com/login');

  assert.equal(result.matched.length, 0);
  assert.equal(result.others.length, 1);
});

test('a look-alike page never gets the real credential', () => {
  // A browser converts a host written in another alphabet into punycode
  // before this code sees it, so the non-ASCII check never fires for a real
  // page. The protection comes from elsewhere and is just as good:
  // "xn--chse-63d.com" is a different registrable domain from "chase.com",
  // so the saved entry is not a match for it.
  const entries = [entry('1', 'Chase', ['site:chase.com'])];
  const result = candidatesFor(entries, `https://${'chase.com'.replace('a', '\u0430')}/`);

  assert.notEqual(result.domain, 'chase.com');
  assert.equal(result.matched.length, 0);
  assert.equal(result.punycode, true, 'the user must be told what this is');
});

test('an ordinary site is not flagged as a look-alike', () => {
  const result = candidatesFor([], 'https://chase.com/');
  assert.equal(result.punycode, false);
});

test('localhost is this computer: its own site, and secure over http', () => {
  assert.equal(hostOf('http://localhost:3000/login').registrable, 'localhost');
  assert.equal(isLoopback('localhost'), true);
  assert.equal(isLoopback('app.localhost'), true);
  assert.equal(isLoopback('localhost.example.com'), false);
  assert.equal(isLoopback('evil-localhost'), false);
  assert.equal(isSecurePage('http://localhost:3000/'), true);
  assert.equal(isSecurePage('http://localhost.example.com/'), false);
  assert.equal(isSecurePage('http://example.com/'), false);
  assert.equal(isSecurePage('https://example.com/'), true);
  // Addresses still belong to nobody.
  assert.equal(hostOf('http://127.0.0.1:3000/').isUsable, false);

  const dev = { id: 'd', title: 'Dev', username: 'u', email: '', password: 'p',
    category: '', notes: '', autofillTargets: ['site:localhost'] };
  const result = candidatesFor([dev], 'http://localhost:3000/login');
  assert.equal(result.insecure, false);
  assert.deepEqual(result.matched.map((c) => c.strength), ['saved']);
  assert.equal(candidatesFor([dev], 'https://example.com/').matched.length, 0);
});
