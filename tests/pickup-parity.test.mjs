// node --test tests/pickup-parity.test.mjs
// The browser helpers in utils.js must give exactly the same pickup place as
// SQL airvalet_pickup_location() / airvalet_departure_operator() for every
// combination (expected table below = the SQL truth table, also asserted in
// tests/sms/sql_tests.sql).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const ctx = {};
vm.createContext(ctx);
vm.runInContext(readFileSync(new URL('../utils.js', import.meta.url), 'utf8'), ctx);

const cases = [
  // ticket, return_operator, delivery_at_customs, requested, not_returning → pickup, exception, pending
  ['0714-3',   'MAKERS', false, null, false, 'HANGAR_19', false, false],
  ['0714-3',   'MAKERS', true,  null, false, 'CUSTOMS',   true,  false],
  ['0714-3',   'MAKERS', false, 'x',  false, 'HANGAR_19', false, true],
  ['0714-3',   'ASCEND', false, null, false, 'CUSTOMS',   false, false],
  ['A-0714-1', 'ASCEND', false, null, false, 'CUSTOMS',   false, false],
  ['A-0714-1', 'MAKERS', false, null, false, 'HANGAR_19', false, false],
  ['A-0714-1', 'MAKERS', true,  null, false, 'CUSTOMS',   true,  false],
  ['0714-3',   'OTHER',  false, null, true,  null,        false, false],
  ['A-0714-1', 'OTHER',  false, null, true,  null,        false, false],
  // legacy rows without return_operator (history)
  ['0714-3',   null,     false, null, false, 'HANGAR_19', false, false],
  ['0714-3',   null,     true,  null, false, 'CUSTOMS',   true,  false],
  ['A-0714-1', null,     false, null, false, 'CUSTOMS',   false, false],
  ['0714-3',   null,     false, null, true,  null,        false, false],
];

test('pickupLocation / exception / pending match the SQL truth table', () => {
  for (const [ticket, ro, dac, req, nr, pickup, exc, pend] of cases) {
    const r = { ticket, return_operator: ro, delivery_at_customs: dac, customs_exception_requested_at: req, not_returning_with_makers_air: nr };
    const label = JSON.stringify(r);
    assert.equal(ctx.pickupLocation(r), pickup, label);
    assert.equal(ctx.isCustomsException(r), exc, label);
    assert.equal(ctx.isCustomsRequestPending(r), pend, label);
  }
});
test('departure operator never depends on the return', () => {
  assert.equal(ctx.departureOperator({ ticket: 'A-1', return_operator: 'MAKERS' }), 'ASCEND');
  assert.equal(ctx.departureOperator({ ticket: '0714-3', return_operator: 'ASCEND' }), 'MAKERS');
});

// Owner's 8 MOVE scenarios (requiredMove = current loc vs pickup location).
test('requiredMove: owner scenarios 1–8 (+ extras)', () => {
  const M = (o) => ctx.requiredMove({ status: 'PENDING', ticket: '1009-1', delivery_at_customs: false, customs_exception_requested_at: null, ...o });
  assert.equal(M({ loc: 'HANGAR 19', return_operator: 'MAKERS' }), null, '1 car H19 + Makers → no move');
  assert.equal(M({ loc: 'HANGAR 19', return_operator: 'ASCEND' }), 'MOVE_TO_CUSTOMS', '2 car H19 + Ascend → MOVE TO CUSTOMS');
  assert.equal(M({ loc: 'CUSTOMS', return_operator: 'ASCEND' }), null, '3 car Customs + Ascend → no move');
  assert.equal(M({ loc: 'CUSTOMS', return_operator: 'MAKERS' }), 'MOVE_TO_HANGAR_19', '4 car Customs + Makers → MOVE TO H19');
  assert.equal(M({ loc: 'HANGAR 19', return_operator: 'MAKERS', customs_exception_requested_at: '2026-10-09T15:00:00Z' }), null, '5 pending exception + car H19 → no move');
  assert.equal(M({ loc: 'HANGAR 19', return_operator: 'MAKERS', delivery_at_customs: true }), 'MOVE_TO_CUSTOMS', '6 approved exception + car H19 → MOVE TO CUSTOMS');
  assert.equal(M({ loc: 'CUSTOMS', return_operator: 'MAKERS', delivery_at_customs: false }), 'MOVE_TO_HANGAR_19', '7 exception revoked + car Customs → MOVE TO H19');
  for (const loc of ['HANGAR 19', 'CUSTOMS', 'HANGAR 18', '']) assert.equal(M({ loc, return_operator: 'OTHER', not_returning_with_makers_air: true }), null, '8 Other → no automatic move (' + loc + ')');
  // extras: other hangars, Ascend departure, delivered / offline
  assert.equal(M({ loc: 'HANGAR 18', return_operator: 'MAKERS' }), 'MOVE_TO_HANGAR_19');
  assert.equal(M({ loc: 'HANGAR 7', return_operator: 'ASCEND', ticket: 'A-1' }), 'MOVE_TO_CUSTOMS');
  assert.equal(M({ loc: 'HANGAR 18', return_operator: 'MAKERS', customs_exception_requested_at: 'x' }), 'MOVE_TO_HANGAR_19', 'pending keeps the Hangar 19 target');
  assert.equal(M({ loc: 'hangar  19', return_operator: 'MAKERS' }), null, 'loc normalised like the rest of the app');
  assert.equal(M({ loc: 'HANGAR 18', return_operator: 'MAKERS', status: 'DELIVERED' }), null);
  assert.equal(M({ loc: 'HANGAR 18', return_operator: 'MAKERS', isOfflinePending: true }), null);
  assert.equal(ctx.requiredMoveLabel('MOVE_TO_CUSTOMS'), 'MOVE TO CUSTOMS');
  assert.equal(ctx.requiredMoveLabel('MOVE_TO_HANGAR_19'), 'MOVE TO H19');
});
