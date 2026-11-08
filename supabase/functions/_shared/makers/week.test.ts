import { assertEquals } from 'jsr:@std/assert@1';
import { nextWeek, weekPeaks, weekText } from './week.ts';

Deno.test('next week: always the next Monday to Sunday', () => {
  assertEquals(nextWeek('2026-11-09')[0], '2026-11-16');   // Monday → the following Monday
  assertEquals(nextWeek('2026-11-08')[0], '2026-11-09');   // Sunday → tomorrow
  assertEquals(nextWeek('2026-11-09').length, 7);
  assertEquals(nextWeek('2026-11-09')[6], '2026-11-22');
});
Deno.test('peaks: 2+ flights with people at 6:45 / 12:45; empty flights and pets do not count', async () => {
  const L = (flight: string, dep: string, to: string, tail: string) => ({ date: '', dep, arr: '', flight, from: 'FXE', to, tail });
  const P = (flight: string, last: string, first = 'A') => ({ date: '', flight, from: 'FXE', to: '', last, first, retDate: '' });
  const suite = {
    schedule: async (mdy: string) => mdy === '11/16/2026' ? [L('1533', '06:45', 'GHC', 'N146WM'), L('2404', '06:45', 'COX', 'N310CH'), L('516', '12:45', 'COX', 'N208JH'), L('675', '12:45', 'GHB', 'N310CH'), L('242', '12:45', 'ATC', 'N740RV')]
      : mdy === '11/17/2026' ? [L('1533', '06:45', 'GHC', 'N146WM'), L('2404', '06:45', 'COX', 'N310CH')] : [],
    passengers: async (mdy: string) => mdy === '11/16/2026'
      ? [P('1533', 'X'), P('1533', 'Y'), P('2404', 'Z'), P('516', 'K'), P('675', 'J'), P('242', 'PET', 'DOG')]
      : [P('1533', 'X')],
  };
  const days = await weekPeaks(suite, ['2026-11-16', '2026-11-17']);
  assertEquals(days[0].am.map((f) => `${f.flight} ${f.pax}`), ['1533 2', '2404 1']);
  assertEquals(days[0].noon.map((f) => f.flight), ['516', '675']);   // 242 has only a pet → empty → not counted
  assertEquals(days[1].am, []);                                       // 2404 empty → only one 6:45 with people
  assertEquals(weekText(days), 'Mon 11/16: 6:45 ×2 (WM GHC 2, CH COX 1) · 12:45 ×2 (JH COX 1, CH GHB 1)');
});
