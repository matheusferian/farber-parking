import { assertEquals } from 'jsr:@std/assert@1';
import { changeLine, DepFlight, diffDepartures, paxKey } from './changes.ts';

const F = (flight: string, dest: string, time: string, tail: string, ids?: string[]): DepFlight =>
  ({ flight, route: `FXE-${dest}`, tail, time, pax: ids ? ids.length : 0, ids });

Deno.test('paxKey: anonymous, stable, case and spacing insensitive, 16 hex; HMAC differs by secret', async () => {
  const a = await paxKey('Doctor', 'Randall'), b = await paxKey(' DOCTOR ', 'randall');
  assertEquals(a, b);
  assertEquals(/^[0-9a-f]{16}$/.test(a), true);
  const h1 = await paxKey('Doctor', 'Randall', 's1'), h2 = await paxKey('DOCTOR', 'RANDALL', 's1'), h3 = await paxKey('Doctor', 'Randall', 's2');
  assertEquals(h1, h2); assertEquals(h1 === h3, false); assertEquals(h1 === a, false);
});

Deno.test('3 left the 6:45 (one went to the 10:00), one new on the 10:00', () => {
  const prev = [F('881', 'ASD', '06:45', 'N310CH', ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']), F('412', 'COX', '10:00', 'N821DD', ['x'])];
  const next = [F('881', 'ASD', '06:45', 'N310CH', ['a', 'b', 'c', 'd', 'e', 'f']), F('412', 'COX', '10:00', 'N821DD', ['x', 'g', 'z'])];
  const c = diffDepartures(prev, next);
  assertEquals(c.length, 2);
  assertEquals(changeLine(c[0]), '6:45 AM Fresh Creek (CH): 2 cancelled or rebooked · 1 moved to 10:00 AM Congo Town · 9 → 6');
  assertEquals(changeLine(c[1]), '10:00 AM Congo Town (DD): 1 moved from 6:45 AM Fresh Creek · 1 added · 1 → 3');
});

Deno.test('tail swap and time change, same passengers', () => {
  const c = diffDepartures([F('1535', 'TYM', '17:42', 'N740RV', ['a'])], [F('1535', 'TYM', '17:57', 'N146WM', ['a'])]);
  assertEquals(changeLine(c[0]), '5:57 PM Staniel Cay (WM): time 5:42 PM → 5:57 PM · aircraft RV → WM');
});

Deno.test('flight gone / new flight / nothing changed', () => {
  assertEquals(diffDepartures([F('1', 'RSD', '06:45', 'N146WM', ['a'])], [F('1', 'RSD', '06:45', 'N146WM', ['a'])]), []);
  const c = diffDepartures([F('1', 'RSD', '06:45', 'N146WM', ['a', 'b'])], [F('2', 'CCZ', '11:00', 'N310CH', ['c'])]);
  assertEquals(c.map(changeLine), ['6:45 AM Rock Sound (WM): flight no longer listed (2 passengers)', '11:00 AM Chub Cay (CH): new flight · 1 passenger']);
});

Deno.test('older readings without keys fall back to counts', () => {
  const prev: DepFlight[] = [{ flight: '881', route: 'FXE-ASD', tail: 'N310CH', time: '06:45', pax: 9 }];
  const next: DepFlight[] = [{ flight: '881', route: 'FXE-ASD', tail: 'N310CH', time: '06:45', pax: 6, ids: ['a'] }];
  assertEquals(changeLine(diffDepartures(prev, next)[0]), '6:45 AM Fresh Creek (CH): 3 cancelled or rebooked · 9 → 6');
});
