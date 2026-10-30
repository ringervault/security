import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';

import {
  choosesSomething, cleanSymbols, DEFAULT_SYMBOLS, entropyBits, generatePassword, MAX_LENGTH, MIN_LENGTH,
} from '../src/vault/generator.js';

globalThis.crypto ??= webcrypto;

const special = (password) => password.replace(/[A-Za-z0-9]/g, '');

test('only the special characters a site allows are used, and one is always there', () => {
  for (let i = 0; i < 200; i++) {
    const password = generatePassword({ allowedSymbols: '_.' });
    assert.notEqual(special(password), '');
    assert.match(special(password), /^[_.]+$/, password);
  }
});

test("a site's own list can be pasted as it is", () => {
  assert.equal(cleanSymbols('! @ # $'), '!@#$');
  assert.equal(cleanSymbols('_-.'), '_-.');
  assert.equal(cleanSymbols('!!@@'), '!@');
  assert.equal(cleanSymbols('é€ ¡'), '');
});

test('none usable means no special characters, not the usual set', () => {
  for (let i = 0; i < 50; i++) {
    assert.match(generatePassword({ allowedSymbols: 'abc 123' }), /^[A-Za-z0-9]+$/);
  }
});

test('the usual set when nothing is narrowed, and every chosen kind present', () => {
  for (let i = 0; i < 100; i++) {
    const password = generatePassword({ length: 12 });
    assert.equal(password.length, 12);
    assert.match(password, /[a-z]/);
    assert.match(password, /[A-Z]/);
    assert.match(password, /[2-9]/);
    assert.ok([...special(password)].every((c) => DEFAULT_SYMBOLS.includes(c)), password);
    assert.doesNotMatch(password, /[lI1O0]/, 'no look-alike characters');
  }
});

test('special characters ruled out are never brought back', () => {
  const only = { lowercase: false, uppercase: false, digits: false, symbols: true, allowedSymbols: '' };
  assert.equal(choosesSomething(only), false);
  for (let i = 0; i < 50; i++) assert.match(generatePassword(only), /^[A-Za-z0-9]+$/);
});

test('the length is kept within bounds', () => {
  assert.equal(generatePassword({ length: 2 }).length, MIN_LENGTH);
  assert.equal(generatePassword({ length: 500 }).length, MAX_LENGTH);
});

test('strength counts only the characters allowed', () => {
  assert.ok(entropyBits({ allowedSymbols: '_.' }) < entropyBits());
  assert.equal(entropyBits({ allowedSymbols: '' }), entropyBits({ symbols: false }));
});

test('every character is equally likely', () => {
  // A fixed sequence of numbers, so a lean towards the start of a set
  // (from taking a remainder) would show.
  let next = 0;
  const counts = new Map();
  const random = (array) => { array[0] = (next++ * 2654435761) >>> 0; };
  for (let i = 0; i < 2000; i++) {
    for (const c of generatePassword({ lowercase: false, uppercase: false, symbols: false, length: 8 }, random)) {
      counts.set(c, (counts.get(c) ?? 0) + 1);
    }
  }
  const values = [...counts.values()];
  assert.equal(values.length, 8, 'all eight digits used');
  assert.ok(Math.max(...values) / Math.min(...values) < 1.2, JSON.stringify(Object.fromEntries(counts)));
});
