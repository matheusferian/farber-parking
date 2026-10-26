// node --test tests/portal/frontend_ops.test.mjs   (TZ is forced to America/New_York)
// LOCAL ONLY. Loads utils.js + selected functions extracted from index.html
// into a vm sandbox. Network / printer / SMS / DB calls are stubs: nothing
// leaves the machine, no printer is ever contacted.
process.env.TZ = 'America/New_York';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import vm from 'node:vm';

const HTML = readFileSync(new URL('../../index.html', import.meta.url), 'utf8');
const UTILS = readFileSync(new URL('../../utils.js', import.meta.url), 'utf8');

// Extract `[async ]function NAME(...) { ... }` with a brace counter that skips
// string literals and // comments (enough for these functions).
function extract(name) {
  const re = new RegExp('(?:^|\\n)((?:async\\s+)?function\\s+' + name + '\\s*\\()');
  const m = re.exec(HTML);
  if (!m) throw new Error('function not found: ' + name);
  let i = m.index + m[0].indexOf(m[1]);
  const start = i;
  i = HTML.indexOf('{', i);
  let depth = 0, q = null;
  for (; i < HTML.length; i++) {
    const c = HTML[i];
    if (q) { if (c === '\\') { i++; continue; } if (c === q) q = null; continue; }
    if (c === '/' && HTML[i + 1] === '/') { i = HTML.indexOf('\n', i); continue; }
    if (c === "'" || c === '"' || c === '`') { q = c; continue; }
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return HTML.slice(start, i + 1); }
  }
  throw new Error('unbalanced: ' + name);
}
function sourceOf(name) { return extract(name); }

function sandbox(extra = {}) {
  const ctx = { console, Date, ...extra };
  vm.createContext(ctx);
  vm.runInContext(UTILS, ctx);
  return ctx;
}
function load(ctx, names, pre = '') {
  vm.runInContext(pre + '\n' + names.map(extract).join('\n'), ctx);
  return ctx;
}
function wellFormed(xml) {
  try { execFileSync('python3', ['-I', '-c', 'import sys,xml.dom.minidom as m; m.parseString(sys.stdin.read())'], { input: xml, stdio: ['pipe', 'ignore', 'ignore'] }); return true; }
  catch { return false; }
}

// ── Customs gratuity reminder ────────────────────────────────────────────
const REM = ['getValidCustomsEtaMinutes', 'buildReminderDateForRecord', 'getCustomsGratuityReminderTime', 'isCustomsDelivered', 'isCustomsCommEligible', 'isCustomsGratuityReminderDue'];
const remCtx = () => load(sandbox(), REM, "var CUSTOMS_COMM_FEATURE_START=new Date('2026-07-12T09:50:00-04:00');");
const baseCustoms = (o = {}) => ({ status: 'DELIVERED', delivery_type: 'CUSTOMS', checkout_date: '2026-10-25T14:00:00Z', ret: '10/25/2026',
  departure_time: '18:30', customs_welcome_sent: true, customs_gratuity_sent: false, customs_gratuity_dismissed: false, ...o });

test('gratuity reminder time = return day + departure_time + 10 min (ET)', () => {
  const c = remCtx();
  const t = c.getCustomsGratuityReminderTime(baseCustoms());
  assert.equal(t.getFullYear() + '-' + (t.getMonth() + 1) + '-' + t.getDate() + ' ' + t.getHours() + ':' + t.getMinutes(), '2026-10-25 18:40');
  const t12 = c.getCustomsGratuityReminderTime(baseCustoms({ departure_time: '6:30 PM' }));
  assert.equal(t12.getHours() * 60 + t12.getMinutes(), 18 * 60 + 40, '12h format');
  const wrap = c.getCustomsGratuityReminderTime(baseCustoms({ departure_time: '23:55' }));
  assert.equal(wrap.getDate(), 26, '23:55 + 10 → next day 00:05');
  assert.equal(wrap.getHours() * 60 + wrap.getMinutes(), 5);
});
test('gratuity reminder: invalid / missing times never produce a reminder', () => {
  const c = remCtx();
  for (const v of ['', '00:00', '0:00', '12:00 AM', 'HH:MM', '--:--', 'NO ETA', '25:00', '7pm', '18:60']) {
    assert.equal(c.getCustomsGratuityReminderTime(baseCustoms({ departure_time: v })), null, 'departure_time=' + JSON.stringify(v));
  }
  assert.equal(c.getCustomsGratuityReminderTime(baseCustoms({ ret: '' })), null, 'no return date → null');
});
test('isCustomsGratuityReminderDue: exactly at +10 min, not 1 ms before', () => {
  const c = remCtx();
  const at = new Date(2026, 9, 25, 18, 40, 0, 0).getTime();
  assert.equal(c.isCustomsGratuityReminderDue(baseCustoms(), at - 1), false);
  assert.equal(c.isCustomsGratuityReminderDue(baseCustoms(), at), true);
  assert.equal(c.isCustomsGratuityReminderDue(baseCustoms({ customs_welcome_sent: false }), at + 1), false, 'Welcome Back must go first');
  assert.equal(c.isCustomsGratuityReminderDue(baseCustoms({ customs_gratuity_sent: true }), at + 1), false, 'already sent');
  assert.equal(c.isCustomsGratuityReminderDue(baseCustoms({ customs_gratuity_dismissed: true }), at + 1), false, 'dismissed');
  assert.equal(c.isCustomsGratuityReminderDue(baseCustoms({ delivery_type: 'NORMAL' }), at + 1), false, 'not Customs');
  assert.equal(c.isCustomsGratuityReminderDue(baseCustoms({ status: 'PENDING' }), at + 1), false, 'not delivered');
  assert.equal(c.isCustomsGratuityReminderDue(baseCustoms({ checkout_date: '2026-07-01T12:00:00Z' }), at + 1), false, 'delivered before feature start');
});

// ── deliverWithTip: Customs never auto-sends the delivered text ──────────
function deliverCtx({ enrolled = true, provider = 'twilio' } = {}) {
  const calls = { send: [], customsModal: [], tipSms: [], updates: [] };
  const ctx = sandbox({
    data: [], calls,
    loading() {}, render() {}, showMsg() {}, vlhInsert() {},
    sbUpdate: async (id, upd) => { calls.updates.push([id, upd]); },
    sbLog: async () => {},
    sendPassengerSms: (o) => { calls.send.push(o); },
    openCustomsCommModal: (id, why) => { calls.customsModal.push([id, why]); },
    openTipSms: (id, tip) => { calls.tipSms.push([id, tip]); },
    formatVehicleLine: () => 'Black Car',
    OFFLINE_PENDING_SYNC_MSG: 'pending', _currentUserEmail: 'local@test',
    SMS_MESSAGE_TYPES: { TIP_NO: 'TIP_NO', TIP_YES: 'TIP_YES' },
  });
  // smsRouteFor (v77) checks the ticket's phone: international numbers never use the server.
  const intlList = /var GUEST_NANP_INTL = (\[[^\]]*\]);/.exec(HTML)[1];
  load(ctx, ['isServerSms', 'paxById', 'guestPhoneIntl', 'smsRouteFor', 'buildTipSms', 'hasPickupAuth', 'pickupReleaseChoice', 'deliverWithTip'], `var SMS_PROVIDER=${JSON.stringify(provider)}; var _smsEnrolled={}; var GUEST_NANP_INTL=${intlList};`);
  if (enrolled) vm.runInContext('_smsEnrolled[7]=true;', ctx);
  ctx.data.push({ id: 7, name: 'JOHN SMITH', phone: '3055550100', ticket: '1025-7', loc: 'CUSTOMS', ret: '10/25/2026', status: 'PENDING' });
  return ctx;
}
test('Customs delivery on a server-SMS ticket: no automatic delivered text, Customs workflow opens', async () => {
  const c = deliverCtx();
  assert.equal(await c.deliverWithTip(7, 'CUSTOMS', null), true);
  assert.equal(c.calls.send.length, 0, 'no sendPassengerSms');
  assert.equal(c.calls.tipSms.length, 0, 'no tip SMS');
  assert.deepEqual(c.calls.customsModal, [[7, 'delivered']]);
  const upd = c.calls.updates[0][1];
  assert.equal(upd.status, 'DELIVERED'); assert.equal(upd.delivery_type, 'CUSTOMS');
  assert.equal('loc' in upd, false, 'Customs keeps the car location (not moved to Hangar 19)');
});
test('Normal delivery on a server-SMS ticket: delivered text sent once automatically (no preview)', async () => {
  const c = deliverCtx();
  assert.equal(await c.deliverWithTip(7, 'NORMAL', null), true);
  assert.equal(c.calls.send.length, 1);
  assert.equal(c.calls.send[0]._previewed, true);
  assert.equal(c.calls.customsModal.length, 0);
  assert.equal(c.calls.updates[0][1].loc, 'HANGAR 19');
});
test('Native (iPhone) ticket: Normal opens the tip SMS composer, Customs opens the Customs workflow', async () => {
  const n = deliverCtx({ enrolled: false });
  await n.deliverWithTip(7, 'NORMAL', null);
  assert.equal(n.calls.send.length, 0); assert.equal(n.calls.tipSms.length, 1);
  const cu = deliverCtx({ enrolled: false });
  await cu.deliverWithTip(7, 'CUSTOMS', null);
  assert.equal(cu.calls.send.length + cu.calls.tipSms.length, 0); assert.equal(cu.calls.customsModal.length, 1);
});
test('a DB failure while delivering sends nothing', async () => {
  const c = deliverCtx();
  c.sbUpdate = async () => { throw new Error('db down'); };
  assert.equal(await c.deliverWithTip(7, 'NORMAL', null), false);
  assert.equal(c.calls.send.length + c.calls.customsModal.length + c.calls.tipSms.length, 0);
});

// ── Print payload builders (printer stubbed) ─────────────────────────────
function printCtx() {
  const sent = [];
  const ctx = sandbox({ sent });
  load(ctx, ['isAscend', 'hasPickupAuth', 'buildCustomerTicketXml', 'buildKeyTicketXml', 'buildDashboardTicketXml', 'printKeyTicket', 'printDashboardTicket', 'printCustomerTicket']);
  // Stub AFTER loading: the real epsonSend/epsonFetch are never loaded.
  ctx.epsonSend = async (xml, label) => { sent.push({ xml, label }); return true; };
  ctx.fetch = () => { throw new Error('network must not be used'); };
  return ctx;
}
const rec = (o = {}) => ({ ticket: '1025-21', name: 'JOHN SMITH', phone: '3055550100', ret: '10/28/2026', car: 'AUDI Q7', color: 'White', loc: 'HANGAR 18', return_operator: 'MAKERS', delivery_at_customs: false, ...o });

test('printKeyTicket / printDashboardTicket build well-formed ePOS XML (printer stubbed)', async () => {
  const c = printCtx();
  await c.printKeyTicket(rec()); await c.printDashboardTicket(rec());
  assert.deepEqual(c.sent.map((s) => s.label), ['Key', 'Dashboard']);
  for (const s of c.sent) {
    assert.ok(s.xml.startsWith('<s:Envelope') && s.xml.includes('<epos-print') && s.xml.includes('<cut type="feed"/>'), s.label);
    assert.ok(wellFormed(s.xml), s.label + ' XML well-formed');
  }
  const key = c.sent[0].xml, dash = c.sent[1].xml;
  assert.ok(key.includes('KEY COPY / INTERNAL') && key.includes('JOHN SMITH') && key.includes('1025-21') && key.includes('HANGAR 18'));
  assert.ok(dash.includes('DASHBOARD COPY') && dash.includes('1025-21') && dash.includes('WED OCT 28'));
});
test('key ticket: Ascend header, Customs banner, OTHER warning, NO DATE', () => {
  const c = printCtx();
  const a = c.buildKeyTicketXml(rec({ ticket: 'A-1025-3', return_operator: 'ASCEND' }));
  assert.ok(a.includes('>ASCEND&#10;') && a.includes('PRIVATE FLIGHT') && a.includes('[A] ') && a.includes('DELIVER TO CUSTOMS'));
  assert.ok(c.buildKeyTicketXml(rec({ delivery_at_customs: true })).includes('MAKERS EXCEPTION - APPROVED'));
  assert.ok(c.buildKeyTicketXml(rec({ return_operator: 'OTHER' })).includes('RETURNING WITH: OTHER'));
  assert.ok(c.buildKeyTicketXml(rec({ ret: '' })).includes('NO DATE'));
  assert.ok(c.buildDashboardTicketXml(rec({ ret: '' })).includes('NO DATE'));
});
test('print XML with "&" or "<" in typed fields stays well-formed (escaping)', () => {
  const c = printCtx();
  const r = rec({ name: 'SMITH & SONS', car: 'B&W MINI <S>', color: 'Black & White' });
  const keyOk = wellFormed(c.buildKeyTicketXml(r));
  const custOk = wellFormed(c.buildCustomerTicketXml(r));
  assert.ok(keyOk && custOk, `key ticket well-formed=${keyOk}, customer ticket well-formed=${custOk} (typed text is not XML-escaped)`);
});

// ── Save + Print no longer prints the customer copy ──────────────────────
test('saveEntry Save+Print (online and offline paths): key + dashboard only, never the customer copy', () => {
  const src = sourceOf('saveEntry');
  const blocks = [...src.matchAll(/if\(printMode==='both'\)\{([\s\S]*?)\n {6}\}|if\(printMode==='both'\)\{([\s\S]*?)\n {2}\}/g)].map((m) => m[1] || m[2]);
  assert.equal(blocks.length, 2, 'two print blocks (online + offline)');
  for (const b of blocks) {
    assert.match(b, /printKeyTicket\(/); assert.match(b, /printDashboardTicket\(/);
    assert.doesNotMatch(b, /printCustomerTicket|printAllTickets|printBothTickets|printTicket\(/);
  }
  assert.doesNotMatch(src, /printCustomerTicket|printAllTickets|printBothTickets/);
});
