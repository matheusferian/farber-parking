import { assertEquals } from 'jsr:@std/assert@1';
import { ascendDepsFromEnv, type AscendDeps, sendAscendTexts } from './ascend.ts';
import { MockProvider, type SendOutcome } from '../sms/provider.ts';
import { ascendOfRun, ascendOut } from '../makers/sync.ts';
import type { Leg, PaxRow } from '../makers/suite.ts';

// Reserved fictional numbers only.
const A = '+13055550101', B = '+13055550102';
function db(due: unknown, optedOut: string[] = []) {
  const saved: Record<string, unknown>[] = []; let claims = 0;
  // deno-lint-ignore no-explicit-any
  const d: any = {
    rpc: (_f: string) => { claims++; return Promise.resolve({ data: due, error: null }); },
    from: (t: string) => t === 'airvalet_ascend_texts'
      ? { update: (v: Record<string, unknown>) => ({ eq: (_c: string, id: number) => { saved.push({ id, ...v }); return Promise.resolve({}); } }) }
      : { select: () => ({ eq: (_c: string, p: string) => ({ maybeSingle: () => Promise.resolve({ data: optedOut.includes(p) ? { opted_out: true } : null }) }) }) },
  };
  return { d, saved, claims: () => claims };
}
const due = [{ id: 1, phone: A, body: 'x' }, { id: 2, phone: B, body: 'x' }];
const deps = (o: Partial<AscendDeps>): AscendDeps => ({ db: db([]).d, mode: 'live', testList: [], provider: new MockProvider(), ...o });

Deno.test('off: nothing is claimed and nothing is sent', async () => {
  const x = db(due), p = new MockProvider();
  assertEquals(await sendAscendTexts(deps({ db: x.d, mode: 'off', provider: p })), 0);
  assertEquals([x.claims(), p.calls.length], [0, 0]);
  assertEquals(ascendDepsFromEnv(x.d, () => undefined).mode, 'off');
});
Deno.test('test: only the test number', async () => {
  const x = db(due), p = new MockProvider();
  assertEquals(await sendAscendTexts(deps({ db: x.d, mode: 'test', testList: [A], provider: p })), 1);
  assertEquals(p.calls.map((c) => c.to), [A]);
  assertEquals(x.saved.find((s) => s.id === 2)?.error_code, 'TEST_ONLY');
});
Deno.test('live: both; opted out is never texted', async () => {
  const x = db(due, [B]), p = new MockProvider();
  assertEquals(await sendAscendTexts(deps({ db: x.d, provider: p })), 1);
  assertEquals(p.calls.map((c) => c.to), [A]);
  assertEquals(x.saved.find((s) => s.id === 2)?.error_code, 'OPTED_OUT');
});
Deno.test('unknown is never retried; throttled is tried once more', async () => {
  const un: SendOutcome = { kind: 'unknown', errorCode: 'TIMEOUT', errorMessage: '' }, th: SendOutcome = { kind: 'throttled', errorCode: '429', errorMessage: '' };
  const x = db([due[0]]), p = new MockProvider([un]);
  assertEquals(await sendAscendTexts(deps({ db: x.d, provider: p })), 0);
  assertEquals([p.calls.length, x.saved[0].status], [1, 'UNKNOWN']);
  const y = db([due[0]]), q = new MockProvider([th]);
  assertEquals(await sendAscendTexts(deps({ db: y.d, provider: q })), 1);
  assertEquals(q.calls.length, 2);
});
Deno.test('a database error never throws', async () => {
  // deno-lint-ignore no-explicit-any
  assertEquals(await sendAscendTexts(deps({ db: { rpc: () => Promise.reject(new Error('x')) } as any })), 0);
});

const leg = (flight: string, dep: string, to: string, tail: string): Leg => ({ date: '11/25/2026', dep, arr: '10:00', flight, from: 'FXE', to, tail });
const pax = (flight: string, to: string, last: string): PaxRow => ({ date: '11/25/2026', flight, from: 'FXE', to, last, first: 'A', retDate: '' });
Deno.test('Ascend departures: only 9xxx with people, final place by name, one person counted once', () => {
  const L = [leg('9218', '13:00', 'SAQ', 'N310CH'), leg('9948', '08:30', 'NAS', 'N633AH'), leg('954', '09:00', 'ELH', 'N1'), leg('9371', '10:00', 'GHC', 'N2')];
  const P = [pax('9218', 'TYM', 'A'), pax('9218', 'TYM', 'B'), pax('9218', 'SAQ', 'C'), pax('9948', 'NAS', 'D'), pax('9948', 'NAS', 'D'), pax('954', 'ELH', 'E')];
  assertEquals(ascendOut(L, P).map((f) => `${f.time} ${f.dest} ${f.pax} ${f.route}`), ['08:30 Nassau 1 FXE-NAS', '13:00 Staniel Cay 3 FXE-SAQ']);
  assertEquals(ascendOfRun([{ flight: '9948', route: 'FXE-FPO', tail: 'N1', time: '08:30', pax: 2, ascend: true, dests: [] }, { flight: '12', route: 'FXE-NAS', tail: 'N1', time: '08:30', pax: 2, ascend: false }])
    .map((f) => f.dest), ['Freeport']);
});
