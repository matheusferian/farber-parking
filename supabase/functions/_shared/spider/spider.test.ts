import { assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { distNm, headingToFxe, parseTracks } from './spider.ts';

const item = (reg: string, p: Record<string, unknown>) => ({ trackId: 't-' + reg, departedTime: 1793997381000, aircraft: { registration: reg }, points: [p] });

Deno.test('distance FXE → Staniel Cay is about 265 nm; FXE itself ~0', () => {
  const d = distNm(24.17, -76.44);
  assertEquals(d > 230 && d < 280, true);
  assertEquals(distNm(26.195, -80.174) < 0.3, true);
});

Deno.test('heading toward FXE from Andros (west-north-west) is inbound; east is not', () => {
  assertEquals(headingToFxe(24.887, -77.886, 290), true);
  assertEquals(headingToFxe(24.887, -77.886, 110), false);
  assertEquals(headingToFxe(24.887, -77.886, null), false);
});

Deno.test('parseTracks: Makers fleet only, newest point, units, powered off at FXE', () => {
  const out = parseTracks({ items: [
    item('N740RV', { latitude: 24.887, longitude: -77.886, altitude: 8941, altitudeUnit: 'ft', speed: 177, speedUnit: 'knots', heading: 290, timestamp: 1793999634000, trackStatus: 'NORMAL' }),
    item('N310CH', { latitude: 26.195, longitude: -80.174, altitude: 20, altitudeUnit: 'ft', speed: 0, speedUnit: 'knots', heading: 277, timestamp: 1793999008000, trackStatus: 'POWER_OFF' }),
    item('N999XX', { latitude: 1, longitude: 1, timestamp: 1 }),
  ] });
  assertEquals(out.map((p) => p.registration), ['N740RV', 'N310CH']);
  assertEquals(out[0].inbound, true);
  assertEquals(out[0].alt_ft, 8941);
  assertEquals(out[0].speed_kt, 177);
  assertEquals(out[1].track_status, 'POWER_OFF');
  assertEquals(out[1].dist_fxe_nm < 0.5, true);
});

Deno.test('parseTracks: page layout changed → LAYOUT', () => {
  assertThrows(() => parseTracks({ nothing: true }), Error, 'LAYOUT');
});
