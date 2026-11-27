import { assertEquals } from 'jsr:@std/assert@1';
import { buildSlips, dueJob, eposXml, keepFor, printRequestInfo } from './slips.ts';

const pax = [
  { id: 1, name: 'mark burton', return_flight: 'RV', departure_time: '11:00' },
  { id: 2, name: 'JOSEPH MCCALL', return_flight: 'RV', departure_time: '11:00' },
  { id: 3, name: 'JAYSON COLE', return_flight: 'WM', departure_time: '' },
  { id: 4, name: 'EARLY BIRD', return_flight: 'CH', departure_time: '09:15' },
  { id: 5, name: 'NO FLIGHT YET', return_flight: '', departure_time: '' },
];
const matches = [
  { passenger_id: 1, registration: 'N740RV', flight_number: '1534', arrival_time: '11:00', kind: 'exact' },
  { passenger_id: 2, registration: 'N740RV', flight_number: '1534', arrival_time: '11:00', kind: 'exact' },
  { passenger_id: 3, registration: 'N146WM', flight_number: '27', arrival_time: '11:00', kind: 'exact' },
  { passenger_id: 5, registration: 'NXXX', flight_number: '1', arrival_time: '08:00', kind: 'surname_only' },
];

Deno.test('am keeps everything, grouped by flight, sorted by time', () => {
  const s = buildSlips(pax, matches, keepFor('am'));
  assertEquals(s.map((x) => [x.flight, x.time, x.names]), [
    ['CH', '09:15', ['EARLY BIRD']],
    ['N146WM #27', '11:00', ['JAYSON COLE']],
    ['N740RV #1534', '11:00', ['JOSEPH MCCALL', 'MARK BURTON']],
    ['NO FLIGHT', '', ['NO FLIGHT YET']],
  ]);
});
Deno.test('pm keeps only known arrivals before 11 AM (surname-only match ignored)', () => {
  const s = buildSlips(pax, matches, keepFor('pm'));
  assertEquals(s.map((x) => x.ids), [[4]]);
});
Deno.test('due windows', () => {
  assertEquals(dueJob('2026-11-27', '2026-11-28', 7), null);
  assertEquals(dueJob('2026-11-27', '2026-11-28', 8)?.key, 'am-2026-11-27');
  assertEquals(dueJob('2026-11-27', '2026-11-28', 12), null);
  assertEquals(dueJob('2026-11-27', '2026-11-28', 14)?.key, 'pm-2026-11-28');
  assertEquals(dueJob('2026-11-27', '2026-11-28', 20), null);
});
Deno.test('xml escapes names and has one cut per flight', () => {
  const s = buildSlips([{ id: 9, name: 'A & <B>', departure_time: '12:00', return_flight: 'RV' }], [], keepFor('am'));
  const x = printRequestInfo(eposXml(s, 'Fri 11/27', 'Printed'), 'am-2026-11-27~1');
  assertEquals(x.includes('A &amp; &lt;B&gt;'), true);
  assertEquals((x.match(/<cut /g) || []).length, 1);
  assertEquals(x.includes('<printjobid>am-2026-11-27~1</printjobid>'), true);
});
