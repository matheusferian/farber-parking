import { assertEquals } from 'jsr:@std/assert@1';
import { forecastDays } from './forecast.ts';

Deno.test('forecast: people per day out of / into FXE, once each, pets excluded, every day filled', async () => {
  const P = (date: string, from: string, to: string, last: string, first = 'A') => ({ date, flight: '1', from, to, last, first, retDate: '' });
  const asked: string[] = [];
  const suite = { passengersRange: async (a: string, b: string) => { asked.push(a + '-' + b); return a === '11/8/2026'
    ? [P('11/8/2026', 'FXE', 'COX', 'X'), P('11/8/2026', 'FXE', 'COX', 'X'), P('11/8/2026', 'FXE', 'COX', 'PET', 'DOG'), P('11/8/2026', 'COX', 'TYM', 'X'), P('11/9/2026', 'COX', 'FXE', 'Y')] : []; } };
  const f = await forecastDays(suite, '2026-11-08', 3, 2);
  assertEquals(asked, ['11/8/2026-11/9/2026', '11/10/2026-11/10/2026']);
  assertEquals(f, [{ day: '2026-11-08', departures: 1, arrivals: 0 }, { day: '2026-11-09', departures: 0, arrivals: 1 }, { day: '2026-11-10', departures: 0, arrivals: 0 }]);
});
