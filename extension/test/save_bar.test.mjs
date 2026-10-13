import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  SAVE_BAR_TICK_MS, SAVE_BAR_VISIBLE_MS, saveBarDue, updateVerdict, withSaveBarSeen,
} from '../src/vault/save_bar.js';

const fresh = () => ({ site: 'example.com', at: Date.now(), seenMs: 0 });

test('a login just sent is owed the bar', () => {
  assert.equal(saveBarDue(fresh()), true);
  // Waiting from a version that did not count yet.
  assert.equal(saveBarDue({ site: 'example.com' }), true);
});

test('a page that moves on after a second brings the bar back on the next', () => {
  // Shown on the login page for one second, then the site redirects.
  const afterRedirect = withSaveBarSeen(fresh(), 1000);
  assert.equal(saveBarDue(afterRedirect), true);
});

test('owed nothing more once on screen for 5 seconds in all', () => {
  let pending = fresh();
  for (let i = 0; i < 4; i++) pending = withSaveBarSeen(pending, SAVE_BAR_TICK_MS);
  assert.equal(saveBarDue(pending), true, '4 seconds is not enough');
  pending = withSaveBarSeen(pending, SAVE_BAR_TICK_MS);
  assert.equal(pending.seenMs, SAVE_BAR_VISIBLE_MS);
  assert.equal(saveBarDue(pending), false);
});

test('time spread over pages adds up', () => {
  // Two seconds on the login page, three on the page after.
  let pending = fresh();
  for (const ms of [1000, 1000, 1000, 1000, 1000]) pending = withSaveBarSeen(pending, ms);
  assert.equal(saveBarDue(pending), false);
});

test('a report counts for one tick at most, and never less than nothing', () => {
  assert.equal(withSaveBarSeen(fresh(), 60_000).seenMs, SAVE_BAR_TICK_MS);
  assert.equal(withSaveBarSeen(fresh(), -5000).seenMs, 0);
  assert.equal(withSaveBarSeen(fresh(), 'lots').seenMs, 0);
});

test('keeps everything else about the waiting login', () => {
  const pending = { ...fresh(), username: 'ada', action: 'create' };
  const next = withSaveBarSeen(pending, 1000);
  assert.equal(next.username, 'ada');
  assert.equal(next.action, 'create');
  assert.equal(pending.seenMs, 0, 'not changed in place');
});

test('a new login is offered whatever the next page shows', () => {
  for (const newPage of [true, false]) {
    for (const passwordBoxShown of [true, false]) {
      assert.equal(updateVerdict({ action: 'create', newPage, passwordBoxShown }), 'show');
    }
  }
});

test('an update is offered once the sign-in is seen to succeed', () => {
  assert.equal(updateVerdict({ action: 'update', newPage: true, passwordBoxShown: false }), 'show');
  assert.equal(updateVerdict({ action: 'update', newPage: false, passwordBoxShown: false }), 'show');
});

test('the sign-in page coming back drops the update', () => {
  assert.equal(updateVerdict({ action: 'update', newPage: true, passwordBoxShown: true }), 'discard');
});

test('the same page, its password box still there, waits', () => {
  assert.equal(updateVerdict({ action: 'update', newPage: false, passwordBoxShown: true }), 'wait');
});
