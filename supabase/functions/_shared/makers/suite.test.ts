// deno test supabase/functions/_shared/makers/  — synthetic HTML shaped like the Makers Air Suite pages.
import { assertEquals } from 'jsr:@std/assert@1';
import { formFields, parsePassengers, parseSchedule, parseTrips, setRadDate, to24 } from './suite.ts';

Deno.test('to24', () => {
  assertEquals(to24('11:01 AM'), '11:01');
  assertEquals(to24('5:41 PM'), '17:41');
  assertEquals(to24('12:45 PM'), '12:45');
  assertEquals(to24('12:10 AM'), '00:10');
  assertEquals(to24('soon'), '');
});

Deno.test('Flight Schedule AG grid → legs (arrival = time at the destination)', () => {
  const html = `<table><tr><th>#</th><th>Flight Date</th><th>Departure</th><th>Arrival</th><th>DOW</th><th>Flight</th><th>From</th><th>To</th><th>Open</th><th>Tail Num</th><th>Captain</th><th>Co</th></tr>
    <tr><td>1</td><td>11/07/2026</td><td>4:15 PM</td><td>5:41 PM</td><td>Sat</td><td>954</td><td>ELH</td><td>FXE</td><td>7</td><td>N740RV</td><td>X</td><td>Y</td></tr>
    <tr><td>2</td><td>11/07/2026</td><td>6:45 AM</td><td>8:10 AM</td><td>Sat</td><td>881</td><td>FXE</td><td>ASD</td><td>2</td><td>N310CH</td><td>X</td><td>Y</td></tr></table>`;
  assertEquals(parseSchedule(html), [
    { date: '11/07/2026', dep: '16:15', arr: '17:41', flight: '954', from: 'ELH', to: 'FXE', tail: 'N740RV' },
    { date: '11/07/2026', dep: '06:45', arr: '08:10', flight: '881', from: 'FXE', to: 'ASD', tail: 'N310CH' },
  ]);
});

Deno.test('Passenger Flight List → names only (no PNR, no return trip)', () => {
  const html = `<table><tr><td>1</td><td>11/7/2026</td><td>1534</td><td>MS1708</td><td>GHC</td><td>FXE</td><td>AMATO, ALFRED</td><td></td><td></td><td></td><td></td><td></td></tr>
    <tr><td>2</td><td>11/7/2026</td><td>9949</td><td>MS1460</td><td>COX</td><td>FXE</td><td>Schaad, Ian</td><td></td><td></td><td></td><td></td><td></td></tr></table>`;
  assertEquals(parsePassengers(html), [
    { date: '11/7/2026', flight: '1534', from: 'GHC', to: 'FXE', last: 'AMATO', first: 'ALFRED' },
    { date: '11/7/2026', flight: '9949', from: 'COX', to: 'FXE', last: 'SCHAAD', first: 'IAN' },
  ]);
});

Deno.test('View Reservation → trips, never the date of birth', () => {
  const html = `<table><tr><th>PNR</th><th>Booked Date</th><th>Last Name</th><th>First Name</th><th>Date Of Birth</th><th>Departure</th><th>Return</th><th></th></tr>
    <tr><td>MT0340</td><td>08/01/2026 12:49</td><td>DOCTOR</td><td>RANDALL</td><td>01/01/1960</td><td>11/01/2026 12:45</td><td>11/13/2026 16:15</td><td>Select</td></tr>
    <tr><td>MT0001</td><td>08/01/2026 12:49</td><td>DOE</td><td>JANE</td><td>01/01/1970</td><td>11/01/2026 12:45</td><td></td><td>Select</td></tr></table>`;
  const t = parseTrips(html);
  assertEquals(t[0], { last: 'DOCTOR', first: 'RANDALL', dep: '2026-11-01', depTime: '12:45', ret: '2026-11-13', retTime: '16:15' });
  assertEquals(t[1].ret, '');
  assertEquals(JSON.stringify(t).includes('1960'), false);
});

Deno.test('form fields + Telerik date', () => {
  const html = `<form><input type="hidden" name="__VIEWSTATE" value="abc"><input name="ctl00$C$RadDate_StartDate" value=""><input name="ctl00$C$RadDate_StartDate$dateInput" value="">
    <input type="hidden" name="ctl00_C_RadDate_StartDate_dateInput_ClientState" value='{"enabled":true}'><input type="submit" name="ctl00$C$btnsearch" value="Search">
    <input type="checkbox" name="ctl00$C$chk"><select name="ctl00$C$s"><option value="A">A</option><option value="B" selected>B</option></select><select name="ctl00$C$ddEmpty"></select></form>`;
  const f = formFields(html);
  assertEquals(f.has('ctl00$C$btnsearch'), false);
  assertEquals(f.has('ctl00$C$chk'), false);
  assertEquals(f.get('ctl00$C$s'), 'B');
  assertEquals(f.has('ctl00$C$ddEmpty'), false);   // browsers do not send an empty list
  setRadDate(f, 'RadDate_StartDate', '11/7/2026');
  assertEquals(f.get('ctl00$C$RadDate_StartDate'), '2026-11-07');
  assertEquals(f.get('ctl00$C$RadDate_StartDate$dateInput'), '11/7/2026');
  assertEquals(JSON.parse(f.get('ctl00_C_RadDate_StartDate_dateInput_ClientState')!).valueAsString, '2026-11-07-00-00-00');
});

Deno.test('grid inside a layout table: header and first row are kept', () => {
  const html = `<table><tr><td>layout<table class="grid"><tr><th>PNR</th><th>Booked Date</th><th>Last Name</th><th>First Name</th><th>Date Of Birth</th><th>Departure</th><th>Return</th><th></th></tr>
    <tr><td>MT1</td><td>x</td><td>DOCTOR</td><td>RANDALL</td><td>01/01/1960</td><td>11/01/2026 12:45</td><td>11/13/2026 16:15</td><td><input type="submit" value="Select"></td></tr></table></td></tr></table>`;
  assertEquals(parseTrips(html).map((t) => t.ret), ['2026-11-13']);
});
