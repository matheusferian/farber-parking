// LOCAL ONLY — service + webhooks end-to-end against the throwaway Postgres
// started by run_local_db_tests.sh (AIRVALET_SMS_TEST_DB_URL). Uses the real
// SQL functions from the migration; MockProvider instead of Twilio.
import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import postgres from 'npm:postgres@3';
import { MockProvider } from '../../supabase/functions/_shared/sms/provider.ts';
import { sendAirValetSms, SmsStore } from '../../supabase/functions/_shared/sms/service.ts';
import { handleInbound, handleStatusCallback, WebhookStore } from '../../supabase/functions/_shared/sms/webhooks.ts';
import { deviceKeyHash } from '../../supabase/functions/_shared/sms/device.ts';
import { computeTwilioSignature } from '../../supabase/functions/_shared/sms/twilio-signature.ts';
import { Template, TEMPLATES } from '../../supabase/functions/_shared/sms/templates.ts';

const url = Deno.env.get('AIRVALET_SMS_TEST_DB_URL');
const TOKEN = 'test_auth_token_not_real_0000000';
const BASE = 'https://example.supabase.co/functions/v1';
const MG = 'MG' + '2'.repeat(32);
const STAFF = '00000000-0000-0000-0000-0000000000a1';
const T: Record<string, Template> = {
  ...TEMPLATES,
  CHECK_IN: { ...TEMPLATES.CHECK_IN, status: 'APPROVED', version: 't1' },
};

Deno.test({ name: 'db integration (service + SQL + webhooks)', ignore: !url, sanitizeResources: false, sanitizeOps: false }, async (t) => {
  const sql = postgres(url!, { max: 4, onnotice: () => {} });
  // deno-lint-ignore no-explicit-any
  const one = async (q: Promise<any[]>) => (await q)[0];
  const store: SmsStore & WebhookStore = {
    getPassenger: async (id) => (await one(sql`select id::int, name, phone, ticket, ret, car, status, return_operator, delivery_at_customs, customs_exception_requested_at, delivery_type, customs_welcome_sent, tip_received from public.passengers where id = ${id}`)) ?? null,
    claim: (a) => one(sql`select * from public.airvalet_sms_claim(${a.idempotencyKey}, ${a.passengerId}, ${a.ticket}, ${a.phoneE164}, ${a.messageType}, ${a.templateKey}, ${a.templateVersion}, ${a.body}, ${a.segments}, ${a.provider}, ${a.sentBy}, 6, 20, ${a.sentByName}, decode(${a.deviceKeyHash}, 'hex'))`),
    markResult: async (a) => (await one(sql`select public.airvalet_sms_mark_result(${a.messageId}, ${a.status}, ${a.sid}, ${a.messagingServiceSid}, ${a.errorCode}, ${a.errorMessage}, ${a.attempts}) as s`)).s,
    markOptedOut: async (p, s) => { await sql`select public.airvalet_sms_mark_opted_out(${p}, ${s})`; },
    mintPassLink: async (id) => (await one(sql`select public.airvalet_pass_mint(${id}) as t`)).t,
    applyStatus: async (sid, st, c, m, mid) => (await one(sql`select public.airvalet_sms_apply_status(${sid}, ${st}, ${c}, ${m}, ${mid}::uuid) as s`)).s,
    reconcile: async () => (await one(sql`select public.airvalet_sms_reconcile(10) as n`)).n,
    recordInbound: (sid, from, body, svc, kw) => one(sql`select * from public.airvalet_sms_record_inbound(${sid}, ${from}, ${body}, ${svc}, ${kw})`),
  };
  const sign = async (path: string, params: Record<string, string>) =>
    new Request('http://internal/' + path, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': await computeTwilioSignature(TOKEN, `${BASE}/${path}`, Object.entries(params)) },
      body: new URLSearchParams(params),
    });

  try {
    const DEV_KEY = 'integration_device_key_' + 'i'.repeat(40);
    const DEV = (await deviceKeyHash(DEV_KEY))!;
    assertEquals((await one(sql`select encode(public.airvalet_sms_device_key_hash(${DEV_KEY}), 'hex') h`)).h, DEV); // Edge hash == SQL hash
    await sql`update public.airvalet_sms_settings set sending_enabled = true, test_only = false, cutover_at = now() - interval '1 hour', cutover_after_id = 0`;
    await sql`insert into public.airvalet_sms_devices (id, key_hash, label, status) values ('00000000-0000-0000-0000-0000000000d1', decode(${DEV}, 'hex'), 'Integration iPad', 'approved')`;
    // New check-in on the approved device: consent + enrollment (as record_consent does).
    const enroll = async (id: number, e164: string) => {
      await sql`insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method) values (${e164}, ${id}, 'granted', 'checkin_attendant')`;
      await sql`insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id) select ${id}, ${e164}, '00000000-0000-0000-0000-0000000000d1', id from public.airvalet_sms_consents where passenger_id = ${id}`;
    };
    await sql`insert into public.passengers (id, name, phone, ticket, status) values (3001, 'Ana Souza', '(305) 555-3001', '0901-1', 'PENDING')`;
    await enroll(3001, '+13055553001');
    const provider = new MockProvider();
    const deps = { mode: 'live' as const, store, provider, allowlist: [], templates: T, passBaseUrl: 'https://farberos.com/a#' };
    const actor = { userId: STAFF, role: 'IPAD_OPS' as const };
    const manager = { userId: STAFF, role: 'MANAGER' as const };

    await t.step('10 simultaneous taps → one Twilio call, one row', async () => {
      const rs = await Promise.all(Array.from({ length: 10 }, () => sendAirValetSms(deps, { passengerId: 3001, type: 'CHECK_IN', actor, deviceKeyHash: DEV })));
      assertEquals(provider.calls.length, 1);
      assertEquals(rs.filter((r) => !r.duplicate).length, 1);
      assertEquals((await one(sql`select count(*)::int n from public.airvalet_sms_messages where passenger_id = 3001`)).n, 1);
      assertEquals((await one(sql`select count(*)::int n from public.airvalet_pass_links where passenger_id = 3001`)).n, 1);
      const token = provider.calls[0].body.match(/https:\/\/farberos\.com\/a#([A-Za-z0-9]{17}) /)![1];
      const stored = (await one(sql`select body, token_hash = extensions.digest(${token}, 'sha256') as hashed from public.airvalet_sms_messages m, public.airvalet_pass_links l where m.passenger_id = 3001 and l.passenger_id = 3001 and l.revoked_at is null`));
      assertEquals(stored.hashed, true);                 // DB keeps only SHA-256(token)
      assertEquals(stored.body.includes(token), false);  // SMS log keeps the masked link
      assertStringIncludes(stored.body, 'https://farberos.com/a#*****************');
    });

    await t.step('passenger link follows return_operator live (default Makers → Other → Ascend); opens recorded', async () => {
      const token = provider.calls[0].body.match(/https:\/\/farberos\.com\/a#([A-Za-z0-9]{17}) /)![1];
      const v1 = await one(sql`select * from public.airvalet_pass_view(${token})`);
      assertEquals([v1.first_name, v1.return_location], ['Ana', 'HANGAR_19']); // check-in default = departure (Makers)
      await sql`update public.passengers set return_operator = 'OTHER' where id = 3001`;
      const v2 = await one(sql`select * from public.airvalet_pass_view(${token})`);
      assertEquals([v2.return_location, v2.return_other], [null, true]);
      await sql`update public.passengers set return_operator = 'MAKERS' where id = 3001`;
      assertEquals((await one(sql`select open_count from public.airvalet_sms_pass_status where passenger_id = 3001`)).open_count, 2);
    });

    await t.step('VEHICLE READY sent, then return changes: nothing auto-sent, Needs Review, corrected send clears it', async () => {
      const R = { ...T, VEHICLE_READY: { ...TEMPLATES.VEHICLE_READY, status: 'APPROVED' as const, version: 't1' } };
      const d2 = { ...deps, templates: R };
      const a = await sendAirValetSms(d2, { passengerId: 3001, type: 'VEHICLE_READY', actor, deviceKeyHash: DEV });
      assertStringIncludes(provider.calls.at(-1)!.body, 'Hangar 19');
      await sql`update public.airvalet_sms_messages set created_at = now() - interval '2 hours', sent_at = now() - interval '2 hours' where id = ${a.messageId!}`;
      const before = provider.calls.length;
      await sql`update public.passengers set return_operator = 'ASCEND' where id = 3001`;
      assertEquals(provider.calls.length, before); // no automatic message
      assertEquals((await one(sql`select instructions_place, current_place from public.airvalet_return_reviews where passenger_id = 3001`)), { instructions_place: 'HANGAR_19', current_place: 'CUSTOMS' });
      const again = await sendAirValetSms(d2, { passengerId: 3001, type: 'VEHICLE_READY', actor, deviceKeyHash: DEV }); // staff decides to update
      assert(again.ok && !again.duplicate);
      assertStringIncludes(provider.calls.at(-1)!.body, 'ready at Customs');
      assertEquals((await sql`select 1 from public.airvalet_return_reviews where passenger_id = 3001`).length, 0);
      await sql`update public.passengers set return_operator = 'OTHER' where id = 3001`;
      assertEquals((await sendAirValetSms(d2, { passengerId: 3001, type: 'VEHICLE_READY', actor, deviceKeyHash: DEV })).error?.code, 'RETURN_OTHER_MANUAL');
      await sql`update public.passengers set return_operator = 'MAKERS' where id = 3001`;
    });

    const sid = provider.calls.length ? (await one(sql`select provider_message_sid s from public.airvalet_sms_messages where passenger_id = 3001 and message_type = 'CHECK_IN'`)).s : '';

    await t.step('signed status callbacks drive queued → sent → delivered; late "sent" ignored', async () => {
      const deps2 = { authToken: TOKEN, publicUrl: `${BASE}/twilio-status-callback`, store, expectedMessagingServiceSid: MG };
      for (const s of ['sent', 'delivered', 'sent']) {
        const res = await handleStatusCallback(deps2, await sign('twilio-status-callback', { MessageSid: sid, MessageStatus: s, MessagingServiceSid: MG }));
        assertEquals(res.status, 204);
      }
      const row = await one(sql`select status, delivered_at is not null d from public.airvalet_sms_messages where provider_message_sid = ${sid}`);
      assertEquals(row.status, 'delivered'); assert(row.d);
    });

    await t.step('passenger reply → matched to passenger 3001 via conversation context', async () => {
      const res = await handleInbound({ authToken: TOKEN, publicUrl: `${BASE}/twilio-inbound`, store, expectedMessagingServiceSid: MG },
        await sign('twilio-inbound', { MessageSid: 'SM' + 'f'.repeat(32), From: '+13055553001', Body: 'Back Sunday 5pm', MessagingServiceSid: MG }));
      assertEquals(res.status, 200);
      const row = await one(sql`select passenger_id::int p, match_method m, direction d from public.airvalet_sms_messages where provider_message_sid = ${'SM' + 'f'.repeat(32)}`);
      assertEquals(row, { p: 3001, m: 'last_outbound', d: 'inbound' });
    });

    await t.step('STOP reply → further sends blocked before reaching Twilio', async () => {
      await handleInbound({ authToken: TOKEN, publicUrl: `${BASE}/twilio-inbound`, store, expectedMessagingServiceSid: MG },
        await sign('twilio-inbound', { MessageSid: 'SM' + 'e'.repeat(32), From: '+13055553001', Body: 'STOP', OptOutType: 'STOP', MessagingServiceSid: MG }));
      const callsBefore = provider.calls.length;
      const r = await sendAirValetSms(deps, { passengerId: 3001, type: 'CHECK_IN', eventRef: 'resend:abcdef12', actor: manager, deviceKeyHash: DEV });
      assertEquals(r.status, 'blocked'); assertEquals(r.error?.code, 'OPTED_OUT');
      assertEquals(provider.calls.length, callsBefore);
    });

    await t.step('timeout → UNCONFIRMED alert; signed late callback with ?mid= adopts the SID and clears it; no blind resend meanwhile', async () => {
      await sql`insert into public.passengers (id, name, phone, ticket, status) values (3002, 'Bia Reis', '(305) 555-3002', '0901-2', 'PENDING')`;
      await enroll(3002, '+13055553002');
      const slow = new MockProvider([{ kind: 'unknown', errorCode: 'TIMEOUT', errorMessage: 'no response' }]);
      const d3 = { ...deps, provider: slow, statusCallbackUrl: `${BASE}/twilio-status-callback` };
      const r1 = await sendAirValetSms(d3, { passengerId: 3002, type: 'CHECK_IN', actor, deviceKeyHash: DEV });
      assertEquals(r1.status, 'send_unknown');
      const cb = slow.calls[0].statusCallbackUrl!;
      assertEquals(cb, `${BASE}/twilio-status-callback?mid=${r1.messageId}`);
      const alert = await one(sql`select attention from public.airvalet_sms_alerts where id = ${r1.messageId!}`);
      assertEquals(alert?.attention, 'UNCONFIRMED');
      // staff tap again / another device → never a second SMS while unconfirmed
      const r2 = await sendAirValetSms({ ...d3, provider: new MockProvider() }, { passengerId: 3002, type: 'CHECK_IN', actor, deviceKeyHash: DEV });
      assertEquals([r2.ok, r2.error?.code], [false, 'UNCONFIRMED']);
      const r3 = await sendAirValetSms({ ...d3, provider: new MockProvider() }, { passengerId: 3002, type: 'CHECK_IN', eventRef: 'resend:0badc0de', actor: manager, deviceKeyHash: DEV });
      assertEquals(r3.error?.code, 'PREVIOUS_UNCONFIRMED');
      // Twilio did create it: its signed callback (URL incl. ?mid=) arrives late
      const lateSid = 'SM' + '7'.repeat(32);
      const signed = new Request('http://internal/twilio-status-callback?mid=' + r1.messageId, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': await computeTwilioSignature(TOKEN, cb, Object.entries({ MessageSid: lateSid, MessageStatus: 'delivered', MessagingServiceSid: MG })) },
        body: new URLSearchParams({ MessageSid: lateSid, MessageStatus: 'delivered', MessagingServiceSid: MG }),
      });
      assertEquals((await handleStatusCallback({ authToken: TOKEN, publicUrl: `${BASE}/twilio-status-callback`, store, expectedMessagingServiceSid: MG }, signed)).status, 204);
      const row = await one(sql`select status, provider_message_sid sid, attention from public.airvalet_sms_messages where id = ${r1.messageId!}`);
      assertEquals(row, { status: 'delivered', sid: lateSid, attention: null });
      assertEquals((await sql`select 1 from public.airvalet_sms_alerts where id = ${r1.messageId!}`).length, 0);
    });

    await t.step('device authorization, old tickets, test mode + kill switch enforced in SQL (cannot be bypassed by the function)', async () => {
      await sql`insert into public.passengers (id, name, phone, ticket, status) values (3003, 'Caio Dias', '(305) 555-3003', '0901-3', 'PENDING')`;
      const p = new MockProvider();
      // Not enrolled (= ticket from the old system) → never goes through Twilio.
      await sql`insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method) values ('+13055553003', 3003, 'granted', 'checkin_attendant')`;
      assertEquals((await sendAirValetSms({ ...deps, provider: p }, { passengerId: 3003, type: 'CHECK_IN', actor, deviceKeyHash: DEV })).error?.code, 'TICKET_NOT_ELIGIBLE');
      await sql`insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id) select 3003, '+13055553003', '00000000-0000-0000-0000-0000000000d1', id from public.airvalet_sms_consents where passenger_id = 3003`;
      // Same shared login, but no / unknown / revoked device → refused.
      assertEquals((await sendAirValetSms({ ...deps, provider: p }, { passengerId: 3003, type: 'CHECK_IN', actor })).error?.code, 'DEVICE_NOT_AUTHORIZED');
      assertEquals((await sendAirValetSms({ ...deps, provider: p }, { passengerId: 3003, type: 'CHECK_IN', actor, deviceKeyHash: (await deviceKeyHash('tv_key_' + 't'.repeat(40)))! })).error?.code, 'DEVICE_NOT_AUTHORIZED');
      await sql`update public.airvalet_sms_devices set status = 'revoked' where id = '00000000-0000-0000-0000-0000000000d1'`;
      assertEquals((await sendAirValetSms({ ...deps, provider: p }, { passengerId: 3003, type: 'CHECK_IN', actor, deviceKeyHash: DEV })).error?.code, 'DEVICE_NOT_AUTHORIZED');
      await sql`update public.airvalet_sms_devices set status = 'approved' where id = '00000000-0000-0000-0000-0000000000d1'`;
      // Test mode: only the numbers on the test list.
      await sql`update public.airvalet_sms_settings set test_only = true, test_phones = '{+13055550000}'`;
      assertEquals((await sendAirValetSms({ ...deps, provider: p }, { passengerId: 3003, type: 'CHECK_IN', actor, deviceKeyHash: DEV })).error?.code, 'TEST_MODE_NUMBER');
      await sql`update public.airvalet_sms_settings set test_only = false, test_phones = '{}'`;
      await sql`update public.airvalet_sms_settings set sending_enabled = false`;
      assertEquals((await sendAirValetSms({ ...deps, provider: p }, { passengerId: 3003, type: 'CHECK_IN', actor, deviceKeyHash: DEV })).error?.code, 'SMS_PAUSED');
      await sql`update public.airvalet_sms_settings set sending_enabled = true`;
      assertEquals(p.calls.length, 0);
      assertEquals((await sql`select 1 from public.airvalet_pass_links where passenger_id = 3003`).length, 0); // blocked → no link minted
    });
  } finally {
    await sql.end();
  }
});
