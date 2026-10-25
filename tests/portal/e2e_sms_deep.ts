// LOCAL ONLY deep end-to-end test of AirValet texting through the real local
// APIs: send-sms (mock provider, AIRVALET_SMS_MODE=mock), twilio-inbound and
// twilio-status-callback (signed with the FAKE local auth token), PostgREST.
//   deno run -A tests/portal/e2e_sms_deep.ts <scratch portal dir>
// Refuses anything but 127.0.0.1. Never contacts Twilio. Cleans its own rows
// (passengers 933000-933099, phones +1305555060x/061x, devices 'DEEP-*').
const DIR = Deno.args[0];
const API = 'http://127.0.0.1:56331';
const DB = 'supabase_db_airvalet-portal-local';
const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const TWILIO_FAKE_TOKEN = '0123456789abcdef0123456789abcdef'; // local functions.env only
const MSID = 'MG0123456789abcdef0123456789abcdef';
if (!API.startsWith('http://127.0.0.1:')) throw new Error('local only');
const PW = (await Deno.readTextFile(`${DIR}/test_password.txt`)).trim();

let pass = 0, fail = 0;
function check(cond: unknown, label: string, extra?: unknown) {
  if (cond) { pass++; console.log('ok  ' + label); } else { fail++; console.log('FAIL ' + label + (extra === undefined ? '' : '  → ' + JSON.stringify(extra))); }
}
async function sql(q: string): Promise<string> {
  const p = new Deno.Command('docker', { args: ['exec', '-i', DB, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', q], stdout: 'piped', stderr: 'piped' });
  const o = await p.output();
  if (!o.success) throw new Error('sql: ' + new TextDecoder().decode(o.stderr));
  return new TextDecoder().decode(o.stdout).trim();
}
async function login(u: string): Promise<string> {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: `${u}@airvalet.local`, password: PW }) });
  return (await r.json()).access_token;
}
async function rpc(jwt: string, fn: string, args: unknown) {
  const r = await fetch(`${API}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const t = await r.text(); let j: any; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
async function send(jwt: string | null, device: string | null, body: Record<string, unknown>) {
  const h: Record<string, string> = { 'Content-Type': 'application/json', apikey: ANON };
  if (jwt) h.Authorization = `Bearer ${jwt}`;
  if (device) h['x-airvalet-device'] = device;
  const r = await fetch(`${API}/functions/v1/send-sms`, { method: 'POST', headers: h, body: JSON.stringify(body) });
  const t = await r.text(); let j: any; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
async function twilioSig(url: string, params: Record<string, string>): Promise<string> {
  const s = url + Object.keys(params).sort().map((k) => k + params[k]).join('');
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(TWILIO_FAKE_TOKEN), { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(s)));
  return btoa(String.fromCharCode(...mac));
}
async function webhook(name: 'twilio-inbound' | 'twilio-status-callback', params: Record<string, string>, opts: { badSig?: boolean; query?: string } = {}) {
  const url = `${API}/functions/v1/${name}${opts.query ?? ''}`;
  const sig = opts.badSig ? 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=' : await twilioSig(url, params);
  const r = await fetch(url, { method: 'POST', headers: { 'X-Twilio-Signature': sig, 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(params).toString() });
  return { status: r.status, text: await r.text() };
}
const sid = () => 'SM' + crypto.randomUUID().replace(/-/g, '');
const inbound = (from: string, body: string, extra: Record<string, string> = {}) =>
  webhook('twilio-inbound', { MessageSid: sid(), AccountSid: 'AC' + '0'.repeat(32), MessagingServiceSid: MSID, From: from, To: '+19545269800', Body: body, NumMedia: '0', ...extra });
const optedOut = async (ph: string) => (await sql(`select coalesce((select opted_out::text from public.airvalet_sms_opt_outs where phone_e164='${ph}'),'none')`));

// ── cleanup + fixtures ──
async function cleanup() {
  await sql(`delete from public.airvalet_sms_status_events where provider_message_sid in (select provider_message_sid from public.airvalet_sms_messages where phone_e164 ~ '^\\+130555506[01][0-9]$');
    delete from public.airvalet_alert_events where ref_id in (select id from public.airvalet_sms_messages where phone_e164 ~ '^\\+130555506[01][0-9]$');
    delete from public.airvalet_sms_messages where phone_e164 ~ '^\\+130555506[01][0-9]$' or passenger_id between 933000 and 933099;
    delete from public.airvalet_pass_links where passenger_id between 933000 and 933099;
    delete from public.airvalet_sms_enrollments where passenger_id between 933000 and 933099;
    delete from public.airvalet_sms_consents where phone_e164 ~ '^\\+130555506[01][0-9]$' or passenger_id between 933000 and 933099;
    delete from public.airvalet_sms_opt_outs where phone_e164 ~ '^\\+130555506[01][0-9]$';
    delete from public.activity_log where passenger_id between 933000 and 933099;
    delete from public.passengers where id between 933000 and 933099;
    delete from public.airvalet_sms_devices d where d.label like 'DEEP-%' and not exists (select 1 from public.airvalet_sms_messages m where m.device_id = d.id);`);
}
await cleanup();
const DEV = 'deep_e2e_' + crypto.randomUUID().replace(/-/g, '') + 'xxxxxxxxxx';
const DEV_PENDING = 'deep_pend_' + crypto.randomUUID().replace(/-/g, '') + 'xxxxxxxxxx';
await sql(`insert into public.airvalet_sms_devices (key_hash, label, status, decided_at) values (public.airvalet_sms_device_key_hash('${DEV}'), 'DEEP-${Date.now()}', 'approved', now());
  insert into public.airvalet_sms_devices (key_hash, label, status) values (public.airvalet_sms_device_key_hash('${DEV_PENDING}'), 'DEEP-P-${Date.now()}', 'pending');
  update public.airvalet_sms_settings set sending_enabled = true, test_only = false, cutover_at = coalesce(cutover_at, now() - interval '1 day'), cutover_after_id = least(coalesce(cutover_after_id, 0), 933000);
  insert into public.passengers (id, ts, checkin_date, name, phone, ticket, ret, loc, car, color, status, return_operator) values
   (933001, 'deep', now(), 'ALICE WALKER', '(305) 555-0601', 'X-SMS-1', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 18', 'AUDI A6', 'Gray', 'PENDING', 'MAKERS'),
   (933002, 'deep', now(), 'NO CONSENT',   '(305) 555-0602', 'X-SMS-2', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 18', 'AUDI A6', 'Gray', 'PENDING', 'MAKERS'),
   (933003, 'deep', now(), 'BAD PHONE',    '12345',          'X-SMS-3', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 18', 'AUDI A6', 'Gray', 'PENDING', 'MAKERS'),
   (933004, 'deep', now(), 'STOP PERSON',  '(305) 555-0604', 'X-SMS-4', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 19', 'AUDI A6', 'Gray', 'PENDING', 'MAKERS'),
   (933005, 'deep', now(), 'COMP ONE',     '(305) 555-0605', 'X-SMS-5', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 18', 'AUDI A6', 'Gray', 'PENDING', 'MAKERS'),
   (933006, 'deep', now(), 'COMP TWO',     '3055550605',     'X-SMS-6', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 16', 'AUDI A6', 'Gray', 'PENDING', 'MAKERS'),
   (933007, 'deep', now(), 'REVOKED CONS', '(305) 555-0607', 'X-SMS-7', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 18', 'AUDI A6', 'Gray', 'PENDING', 'MAKERS'),
   (933008, 'deep', now(), 'STATUS CB',    '(305) 555-0608', 'X-SMS-8', to_char((now() at time zone 'America/New_York')::date + 3, 'FMMM/FMDD/YYYY'), 'HANGAR 18', 'AUDI A6', 'Gray', 'PENDING', 'MAKERS'),
   (933009, 'deep', now(), 'CUSTOMS DEL',  '(305) 555-0609', 'A-SMS-9', to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'CUSTOMS', 'AUDI A6', 'Gray', 'PENDING', 'ASCEND');`);

const ipad = await login('localipad'), tv = await login('localtv');
check(ipad && tv, 'logins (local test users)');

// ── 1. Auth / device / consent / enrollment gates ──
check((await send(null, DEV, { passenger_id: 933001, message_type: 'CHECK_IN' })).status === 401, 'send-sms without a login → 401');
const tvSend = await send(tv, DEV, { passenger_id: 933001, message_type: 'CHECK_IN' });
check(tvSend.body?.error?.code === 'FORBIDDEN', 'TV_ONLY cannot send', tvSend.body);
const notEnrolled = await send(ipad, DEV, { passenger_id: 933001, message_type: 'CHECK_IN' });
check(notEnrolled.body?.status === 'blocked' && notEnrolled.body?.error?.code === 'TICKET_NOT_ELIGIBLE', 'welcome before consent/enrollment → blocked TICKET_NOT_ELIGIBLE', notEnrolled.body);
const consentNoDevice = await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933001, p_disclosure_version: 'deep-v1', p_device_key: 'unknown_device_' + 'z'.repeat(40) });
check(consentNoDevice.body?.[0]?.reason === 'DEVICE_NOT_AUTHORIZED', 'consent from an unknown device → DEVICE_NOT_AUTHORIZED (not enrolled)', consentNoDevice.body);
const consentPending = await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933001, p_disclosure_version: 'deep-v1', p_device_key: DEV_PENDING });
check(consentPending.body?.[0]?.reason === 'DEVICE_NOT_AUTHORIZED', 'consent from a PENDING device → DEVICE_NOT_AUTHORIZED', consentPending.body);
const consent = await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933001, p_disclosure_version: 'deep-v1', p_device_key: DEV, p_staff_name: 'Deep Test' });
check(consent.body?.[0]?.enrolled === true && consent.body?.[0]?.reason === 'ENROLLED', 'consent + approved device → ENROLLED', consent.body);
const badDev = await send(ipad, 'unknown_device_' + 'z'.repeat(40), { passenger_id: 933001, message_type: 'CHECK_IN' });
check(badDev.body?.status === 'blocked' && badDev.body?.error?.code === 'DEVICE_NOT_AUTHORIZED', 'send from an unapproved device → blocked DEVICE_NOT_AUTHORIZED', badDev.body);
const pendDev = await send(ipad, DEV_PENDING, { passenger_id: 933001, message_type: 'CHECK_IN' });
check(pendDev.body?.error?.code === 'DEVICE_NOT_AUTHORIZED', 'send from a pending device → blocked', pendDev.body);
const noDevHdr = await send(ipad, null, { passenger_id: 933001, message_type: 'CHECK_IN' });
check(noDevHdr.body?.error?.code === 'DEVICE_NOT_AUTHORIZED', 'send without device header → blocked', noDevHdr.body);
const preview = await send(ipad, DEV, { passenger_id: 933001, message_type: 'CHECK_IN', preview: true });
check(preview.body && (preview.body.segments === 1 || preview.body.preview?.segments === 1 || JSON.stringify(preview.body).includes('"segments":1')), 'preview: CHECK_IN is 1 segment', preview.body);
check((await sql(`select count(*) from public.airvalet_sms_messages where passenger_id=933001 and status <> 'blocked'`)) === '0', 'preview / blocked attempts never create a sendable row');

// revoked consent (enrolled earlier, latest consent row = revoked, no opt-out row)
await sql(`insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method) values ('+13055550607', 933007, 'granted', 'checkin_attendant');
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id) select 933007, '+13055550607', d.id, c.id from public.airvalet_sms_devices d, public.airvalet_sms_consents c where d.key_hash = public.airvalet_sms_device_key_hash('${DEV}') and c.phone_e164 = '+13055550607';
  insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method) values ('+13055550607', 933007, 'revoked', 'keyword_stop');`);
const revoked = await send(ipad, DEV, { passenger_id: 933007, message_type: 'CHECK_IN' });
check(revoked.body?.status === 'blocked' && revoked.body?.error?.code === 'NO_CONSENT', 'enrolled but consent revoked → blocked NO_CONSENT', revoked.body);

// ── 2. Welcome send + idempotency ──
const w1 = await send(ipad, DEV, { passenger_id: 933001, message_type: 'CHECK_IN', staff_name: 'Deep Test' });
check(w1.body?.ok === true && /^SMMOCK/.test(w1.body?.sid || ''), 'welcome sent through the MOCK provider (SMMOCK sid)', w1.body);
const w2 = await send(ipad, DEV, { passenger_id: 933001, message_type: 'CHECK_IN' });
check(w2.body?.duplicate === true && w2.body?.messageId === w1.body?.messageId, 'same event again → duplicate, same message id, not re-sent', w2.body);
const par = await Promise.all(Array.from({ length: 6 }, () => send(ipad, DEV, { passenger_id: 933001, message_type: 'CHECK_IN' })));
check(par.every((r) => r.body?.duplicate === true), '6 concurrent repeats → all duplicates', par.map((r) => r.body?.status));
check((await sql(`select count(*) from public.airvalet_sms_messages where passenger_id=933001 and message_type='CHECK_IN' and status <> 'blocked'`)) === '1', 'exactly one CHECK_IN row for the passenger');
const stored = await sql(`select body from public.airvalet_sms_messages where id='${w1.body?.messageId}'`);
check(/#\*{17}/.test(stored) && !/#[A-Za-z0-9]{17}/.test(stored), 'stored body masks the pass token');
check((await sql(`select count(*) from public.airvalet_pass_links where passenger_id=933001 and revoked_at is null`)) === '1', 'welcome minted exactly one active pass link');

// ── 3. Invalid phone ──
const cBad = await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933003, p_disclosure_version: 'deep-v1', p_device_key: DEV });
check(cBad.body?.[0]?.reason === 'INVALID_PHONE' && cBad.body?.[0]?.enrolled === false, 'consent with an invalid phone → INVALID_PHONE, not enrolled', cBad.body);
await sql(`insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id) select 933003, '+13050000000', d.id, gen_random_uuid() from public.airvalet_sms_devices d where d.key_hash = public.airvalet_sms_device_key_hash('${DEV}')`);
const sBad = await send(ipad, DEV, { passenger_id: 933003, message_type: 'CHECK_IN' });
check(sBad.status === 200 && sBad.body?.status === 'rejected' && sBad.body?.error?.code === 'INVALID_PHONE', 'send-sms to an invalid phone → rejected INVALID_PHONE (HTTP 200, nothing sent)', sBad.body);
check((await sql(`select count(*) from public.airvalet_sms_messages where passenger_id=933003`)) === '0', 'invalid phone → no message row');

// ── 4. Status callback ──
await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933008, p_disclosure_version: 'deep-v1', p_device_key: DEV });
const s8 = await send(ipad, DEV, { passenger_id: 933008, message_type: 'CHECK_IN' });
const sid8 = s8.body?.sid as string;
const cbBase = { MessageSid: sid8, AccountSid: 'AC' + '0'.repeat(32), MessagingServiceSid: MSID, To: '+13055550608', From: '+19545269800' };
check((await webhook('twilio-status-callback', { ...cbBase, MessageStatus: 'delivered' }, { badSig: true })).status === 403, 'status callback with a bad signature → 403');
check((await sql(`select status from public.airvalet_sms_messages where id='${s8.body?.messageId}'`)) !== 'delivered', '… and nothing changed');
const cbSent = await webhook('twilio-status-callback', { ...cbBase, MessageStatus: 'sent' });
const cbDel = await webhook('twilio-status-callback', { ...cbBase, MessageStatus: 'delivered' });
check(cbSent.status === 204 && cbDel.status === 204, 'signed status callbacks accepted (204)');
check((await sql(`select status || '|' || (delivered_at is not null) from public.airvalet_sms_messages where id='${s8.body?.messageId}'`)) === 'delivered|true', 'status → delivered (delivered_at set)');
const cbLate = await webhook('twilio-status-callback', { ...cbBase, MessageStatus: 'sent' });
check(cbLate.status === 204 && (await sql(`select status from public.airvalet_sms_messages where id='${s8.body?.messageId}'`)) === 'delivered', 'late "sent" after "delivered" does not downgrade');
const cbForeign = await webhook('twilio-status-callback', { ...cbBase, MessagingServiceSid: 'MG' + 'f'.repeat(32), MessageStatus: 'failed' });
check(cbForeign.status === 200 && (await sql(`select status from public.airvalet_sms_messages where id='${s8.body?.messageId}'`)) === 'delivered', 'callback from another Messaging Service ignored');
// failed path on a second message (VEHICLE_DELIVERED after delivery)
await sql(`update public.passengers set status='DELIVERED', delivery_type='NORMAL', checkout_date=now(), deldate=to_char(now(),'FMMM/FMDD/YYYY') where id=933008`);
const d8 = await send(ipad, DEV, { passenger_id: 933008, message_type: 'VEHICLE_DELIVERED' });
check(d8.body?.ok === true, 'VEHICLE_DELIVERED sent after delivery (mock)', d8.body);
check((await sql(`select (expires_at between now() + interval '6 days 23 hours' and now() + interval '7 days 1 minute')::text from public.airvalet_pass_links where passenger_id=933008 and revoked_at is null`)) === 'true', 'delivered text link ends 7 days after delivery');
const cbFail = await webhook('twilio-status-callback', { ...cbBase, MessageSid: d8.body?.sid, MessageStatus: 'undelivered', ErrorCode: '30003', ErrorMessage: 'Unreachable destination handset' });
check(cbFail.status === 204 && (await sql(`select status || '|' || coalesce(error_code,'') from public.airvalet_sms_messages where id='${d8.body?.messageId}'`)) === 'undelivered|30003', 'status → undelivered with carrier error 30003');
const cbUnknown = await webhook('twilio-status-callback', { ...cbBase, MessageSid: sid(), MessageStatus: 'delivered' });
check(cbUnknown.status === 204 || cbUnknown.status === 200, 'callback for an unknown SID is acknowledged (no retry storm)', cbUnknown);

// ── 5. Inbound + STOP / START / HELP ──
await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933004, p_disclosure_version: 'deep-v1', p_device_key: DEV });
const w4 = await send(ipad, DEV, { passenger_id: 933004, message_type: 'CHECK_IN' });
check(w4.body?.ok === true, 'welcome to passenger 933004', w4.body);
check((await inbound('+13055550604', 'Hello', {})).status === 200, 'signed inbound accepted');
check((await sql(`select count(*) || '|' || max(match_method) from public.airvalet_sms_messages where direction='inbound' and phone_e164='+13055550604' and passenger_id=933004 and body='Hello'`)) === '1|last_outbound', 'inbound stored in the Inbox, matched to the passenger');
const inboxRest = await fetch(`${API}/rest/v1/airvalet_sms_messages?passenger_id=eq.933004&direction=eq.inbound&select=body`, { headers: { apikey: ANON, Authorization: `Bearer ${ipad}` } });
check(JSON.stringify(await inboxRest.json()).includes('Hello'), 'staff (IPAD_OPS) sees the inbound via the API');
const tvRest = await fetch(`${API}/rest/v1/airvalet_sms_messages?passenger_id=eq.933004&select=body`, { headers: { apikey: ANON, Authorization: `Bearer ${tv}` } });
check(!JSON.stringify(await tvRest.json()).includes('Hello'), 'TV_ONLY cannot read message bodies');
check((await inbound('+13055550604', 'Bad sig', {}).then(() => webhook('twilio-inbound', { MessageSid: sid(), MessagingServiceSid: MSID, From: '+13055550604', To: '+19545269800', Body: 'forged' }, { badSig: true }))).status === 403, 'inbound with a bad signature → 403');
check((await sql(`select count(*) from public.airvalet_sms_messages where body='forged'`)) === '0', '… forged text not stored');
const dupSid = sid();
const dupParams = { MessageSid: dupSid, AccountSid: 'AC' + '0'.repeat(32), MessagingServiceSid: MSID, From: '+13055550604', To: '+19545269800', Body: 'retry me', NumMedia: '0' };
await webhook('twilio-inbound', dupParams); await webhook('twilio-inbound', dupParams);
check((await sql(`select count(*) from public.airvalet_sms_messages where provider_message_sid='${dupSid}'`)) === '1', 'Twilio retry of the same inbound → stored once');
await inbound('+13055550604', 'HELP');
check((await sql(`select count(*) from public.airvalet_sms_messages where phone_e164='+13055550604' and message_type='INBOUND_HELP'`)) === '1', 'HELP recorded as INBOUND_HELP');
check(await optedOut('+13055550604') === 'none', 'HELP does not opt out');
await inbound('+13055550604', 'Yes', { OptOutType: 'START' });
check((await sql(`select message_type from public.airvalet_sms_messages where phone_e164='+13055550604' and body='Yes'`)) === 'INBOUND', 'a conversational "Yes" labelled START by Twilio is just a message');
await inbound('+13055550604', ' stop. ');
check(await optedOut('+13055550604') === 'true', 'STOP (lower case + punctuation) → opted out');
const rStop = await send(ipad, DEV, { passenger_id: 933004, message_type: 'VEHICLE_READY' });
check(rStop.body?.status === 'blocked' && rStop.body?.error?.code === 'OPTED_OUT', 'send after STOP → blocked OPTED_OUT', rStop.body);
const replyStop = await send(ipad, DEV, { passenger_id: 933004, message_type: 'REPLY', custom_body: 'Are you there?', event_ref: 'compose:' + crypto.randomUUID() });
check(replyStop.body?.error?.code === 'OPTED_OUT', 'even a staff REPLY is blocked after STOP', replyStop.body);
await inbound('+13055550604', 'START');
check(await optedOut('+13055550604') === 'false', 'START → opted back in');
const rStart = await send(ipad, DEV, { passenger_id: 933004, message_type: 'VEHICLE_READY' });
check(rStart.body?.ok === true, 'send after START → allowed (same event key re-evaluated)', rStart.body);
check((await sql(`select template_key from public.airvalet_sms_messages where id='${rStart.body?.messageId}'`)) === 'HANGAR19_WELCOME_BACK', '… Hangar 19 Welcome Back variant');

// ── 6. Companion phone over the API ──
await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933005, p_disclosure_version: 'deep-v1', p_device_key: DEV });
const cc2 = await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933006, p_disclosure_version: 'deep-v1', p_device_key: DEV });
check(cc2.body?.[0]?.enrolled === true, 'second passenger with the same phone can be enrolled', cc2.body);
const ib0 = await inbound('+13055550605', 'Before any text');
check(ib0.status === 200 && (await sql(`select coalesce(passenger_id::text,'null') || '|' || match_method from public.airvalet_sms_messages where body='Before any text'`)) === 'null|ambiguous', 'shared phone, nothing texted yet → ambiguous → review queue');
const c5 = await send(ipad, DEV, { passenger_id: 933005, message_type: 'CHECK_IN' });
const c6 = await send(ipad, DEV, { passenger_id: 933006, message_type: 'CHECK_IN' });
check(c5.body?.ok === true, 'first companion welcome sent', c5.body);
check(c6.body?.ok === true, 'second companion (same phone, own ticket + own pass link) also gets its welcome within 2 min', [c6.body?.status, c6.body?.error]);
await inbound('+13055550605', 'Which car is this about?');
const att = await sql(`select coalesce(passenger_id::text,'null') || '|' || match_method from public.airvalet_sms_messages where body='Which car is this about?'`);
const lastTexted = await sql(`select passenger_id from public.airvalet_sms_messages where direction='outbound' and phone_e164='+13055550605' and status <> 'blocked' order by created_at desc limit 1`);
check(att === lastTexted + '|last_outbound', 'shared phone after both welcomes → attributed to the LAST texted passenger, not the review queue (documented)', att);

// ── 7. Customs delivered: VEHICLE_READY still allowed, VEHICLE_DELIVERED is up to staff ──
await rpc(ipad, 'airvalet_sms_record_consent', { p_passenger_id: 933009, p_disclosure_version: 'deep-v1', p_device_key: DEV });
await sql(`update public.passengers set status='DELIVERED', delivery_type='CUSTOMS', checkout_date=now() where id=933009`);
const cr = await send(ipad, DEV, { passenger_id: 933009, message_type: 'VEHICLE_READY' });
check(cr.body?.ok === true && (await sql(`select template_key from public.airvalet_sms_messages where id='${cr.body?.messageId}'`)) === 'CUSTOMS_WELCOME', 'car delivered at Customs: Customs Welcome Back still sendable', cr.body);

console.log(`\n${pass} passed, ${fail} failed`);
await cleanup();
Deno.exit(fail ? 1 : 0);
