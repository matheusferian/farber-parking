-- LOCAL DB tests for the AirValet SMS + Return/Pickup migrations (full set).
-- Run: tests/sms/run_local_db_tests.sh (applies fixture + migration to a
-- throwaway local container). Everything runs in one transaction that is
-- rolled back. Any failed check raises and aborts with 'FAIL: …'.

\set ON_ERROR_STOP 1
begin;

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;

-- Passenger page read with a fresh client key per call (so the suite never
-- trips the per-client throttle except in the throttle tests themselves).
create function pg_temp.pv(t text) returns table (
  state text, ticket text, first_name text, vehicle text, color text, status text, return_date text,
  return_location text, return_other boolean, customs_exception boolean, customs_request_pending boolean,
  delivered boolean, expires_at timestamptz)
language sql as $$ select * from public.airvalet_pass_view(t, 'test-' || md5(random()::text)) $$;

-- Links exist only for tickets in the Twilio program: this wrapper enrolls
-- the ticket (as a new check-in on the test iPad) before minting. The real
-- refusal for a non-enrolled ticket is tested separately.
create function pg_temp.mint(pid bigint) returns text language plpgsql as $$
begin
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  select p.id, coalesce(public.airvalet_sms_normalize_phone(p.phone), '+13050000000'),
         (select d.id from public.airvalet_sms_devices d where d.label = 'Test iPad'), gen_random_uuid()
    from public.passengers p
   where p.id = pid and not exists (select 1 from public.airvalet_sms_enrollments e where e.passenger_id = pid);
  return public.airvalet_pass_mint(pid);
end $$;

-- ── Fixture rows ─────────────────────────────────────────────────────────
insert into public.user_profiles (id, username, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin', 'ADMIN'),
  ('00000000-0000-0000-0000-0000000000b1', 'tv', 'TV_ONLY'),
  ('00000000-0000-0000-0000-0000000000c1', 'ipad', 'IPAD_OPS');
-- Program ON with the pre-Etapa-2 caps (6/h, 20/day per phone) so the older
-- tests keep their meaning; the Etapa 2 section below exercises every cap.
update public.airvalet_sms_settings set sending_enabled = true, test_only = false, max_per_phone_hour = 6, max_per_phone_day = 20,
  max_per_device_hour = 500, max_messages_day = 5000, max_segments_day = 10000,
  cutover_at = now() - interval '1 hour', cutover_after_id = 0;   -- every fixture ticket counts as a NEW check-in
-- The test iPad: an APPROVED device (only the SHA-256 of its key is stored).
insert into public.airvalet_sms_devices (key_hash, label, status) values (public.airvalet_sms_device_key_hash('test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), 'Test iPad', 'approved');
-- Generic send tests go through this wrapper: it enrolls the ticket (new
-- check-in) and presents the test iPad's key, so each test keeps exercising
-- its own rule. No passenger → a non-active placeholder passenger for that
-- phone. Device / eligibility / test-mode rules are tested on the REAL claim.
create function pg_temp.claim(k text, pid bigint, tk text, ph text, mt text, tkey text, tver text, body text, seg integer, prov text, sb uuid,
                              mh integer default null, md integer default null, sbn text default null)
returns table (message_id uuid, claimed boolean, status text, provider_message_sid text, error_code text)
language plpgsql as $$
declare v_pid bigint := pid;
begin
  if v_pid is null then
    select p.id into v_pid from public.passengers p where p.name = 'PLACEHOLDER ' || ph;
    if v_pid is null then
      insert into public.passengers (name, phone, ticket, status) values ('PLACEHOLDER ' || ph, ph, 'PH-' || right(ph, 4), 'DELIVERED') returning id into v_pid;
    end if;
  end if;
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  select v_pid, ph, (select d.id from public.airvalet_sms_devices d where d.label = 'Test iPad'), gen_random_uuid()
   where not exists (select 1 from public.airvalet_sms_enrollments e where e.passenger_id = v_pid);
  return query select * from public.airvalet_sms_claim(k, v_pid, tk, ph, mt, tkey, tver, body, seg, prov, sb, mh, md, sbn,
                                                     public.airvalet_sms_device_key_hash('test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'));
end $$;
insert into public.passengers (id, name, phone, ticket, status) values
  (1001, 'Alice',  '(305) 555-0101', '0714-3',   'PENDING'),
  (1002, 'Bob',    '305 555-0202',   'A-0714-1', 'PENDING'),
  (1003, 'Carol',  '3055550303',     '0714-3',   'DELIVERED'), -- reused ticket string
  (1004, 'Dan',    '3055550404',     '0801-1',   'PENDING'),   -- same phone as 1005 (family)
  (1005, 'Dana',   '(305)555-0404',  '0801-2',   'NO DATE'),
  (1006, 'Eve',    '12345',          '0802-1',   'PENDING');
-- Recorded opt-ins (A2P consent) for the phones the send tests use.
insert into public.airvalet_sms_consents (phone_e164, status, method, disclosure_version)
select ph, 'granted', 'checkin_attendant', 'test-v1'
  from unnest(array['+13055550101', '+13055550202', '+13055550303', '+13055550404', '+13055558888']) ph;

-- ── Phone normalization (same rules as utils.js normalizePhoneE164) ──────
select pg_temp.check(public.airvalet_sms_normalize_phone('(305) 555-0101') = '+13055550101', 'normalize (999) 999-9999');
select pg_temp.check(public.airvalet_sms_normalize_phone('1 305 555 0101') = '+13055550101', 'normalize 11 digits leading 1');
select pg_temp.check(public.airvalet_sms_normalize_phone('+44 20 7946 0958') = '+442079460958', 'normalize international with +');
select pg_temp.check(public.airvalet_sms_normalize_phone('44 20 7946 0958') is null, 'no + and not US → null (never guess)');
select pg_temp.check(public.airvalet_sms_normalize_phone('12345') is null, 'too short → null');
select pg_temp.check(public.airvalet_sms_normalize_phone('   ') is null, 'blank → null');
select pg_temp.check(public.airvalet_sms_normalize_phone('+0123456789') is null, '+0… → null');

-- ── Claim / idempotency ──────────────────────────────────────────────────
create temp table r1 as select * from pg_temp.claim('pax:1001:CHECK_IN:checkin', 1001, '0714-3', '+13055550101', 'CHECK_IN', 'CHECK_IN', 'v1', 'body', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
create temp table r2 as select * from pg_temp.claim('pax:1001:CHECK_IN:checkin', 1001, '0714-3', '+13055550101', 'CHECK_IN', 'CHECK_IN', 'v1', 'body', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select claimed from r1) and (select status from r1) = 'pending', 'first claim → claimed, pending');
select pg_temp.check(not (select claimed from r2) and (select message_id from r2) = (select message_id from r1), 'same key again → NOT claimed, same row (double-click safe)');
select pg_temp.check((select count(*) from public.airvalet_sms_messages where idempotency_key = 'pax:1001:CHECK_IN:checkin') = 1, 'exactly one row for the key');

do $$ begin
  perform pg_temp.claim('', 1001, null, '+13055550101', 'X', null, null, null, null, 'mock', '00000000-0000-0000-0000-0000000000a1');
  raise exception 'FAIL: empty idempotency key accepted';
exception when sqlstate '22023' then raise notice 'ok  empty idempotency key rejected';
end $$;

do $$ begin
  insert into public.airvalet_sms_messages (direction, phone_e164, message_type, provider, status, idempotency_key)
  values ('outbound', '305-555-0101', 'X', 'mock', 'pending', 'bad-phone');
  raise exception 'FAIL: non-E.164 phone accepted';
exception when check_violation then raise notice 'ok  non-E.164 phone rejected by constraint';
end $$;

-- Ticket strings repeat across trips (prod has 164) → key is passenger_id:
create temp table r3 as select * from pg_temp.claim('pax:1003:CHECK_IN:checkin', 1003, '0714-3', '+13055550303', 'CHECK_IN', 'CHECK_IN', 'v1', 'body', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select claimed from r3), 'same ticket string, different passenger_id → independent claim');

-- ── Send result + status callbacks (forward-only, terminal sticky) ──────
select pg_temp.check(public.airvalet_sms_mark_result((select message_id from r1), 'queued', 'SM_TEST_1', 'MG_TEST', null, null, 1) = 'queued', 'mark_result pending → queued');
select pg_temp.check(public.airvalet_sms_mark_result((select message_id from r1), 'failed', null, null, 'X', 'x', 1) = 'queued', 'second mark_result ignored once out of pending');
select pg_temp.check(public.airvalet_sms_apply_status('SM_TEST_1', 'sent', null, null) = 'applied', 'callback queued → sent applied');
select pg_temp.check(public.airvalet_sms_apply_status('SM_TEST_1', 'sent', null, null) = 'duplicate', 'duplicate callback ignored');
select pg_temp.check(public.airvalet_sms_apply_status('SM_TEST_1', 'queued', null, null) = 'stale', 'out-of-order (older) callback does not regress');
select pg_temp.check(public.airvalet_sms_apply_status('SM_TEST_1', 'delivered', null, null) = 'applied', 'sent → delivered applied');
select pg_temp.check(public.airvalet_sms_apply_status('SM_TEST_1', 'undelivered', '30003', 'x') = 'stale', 'terminal delivered is sticky');
select pg_temp.check((select status = 'delivered' and sent_at is not null and delivered_at is not null from public.airvalet_sms_messages where provider_message_sid = 'SM_TEST_1'), 'timestamps set (sent_at, delivered_at)');
select pg_temp.check(public.airvalet_sms_apply_status('SM_TEST_1', 'bogus', null, null) = 'ignored_status', 'unknown status ignored');
select pg_temp.check((select count(*) from public.airvalet_sms_status_events where provider_message_sid = 'SM_TEST_1') = 4, 'every distinct callback kept in audit trail');

-- Callback that beats the HTTP response (orphan) is replayed on mark_result:
select pg_temp.check(public.airvalet_sms_apply_status('SM_TEST_3', 'delivered', null, null) = 'orphan', 'callback for unknown SID kept as orphan');
select pg_temp.check(public.airvalet_sms_mark_result((select message_id from r3), 'queued', 'SM_TEST_3', 'MG_TEST', null, null, 1) = 'delivered', 'orphan callback replayed → delivered');
select pg_temp.check((select applied from public.airvalet_sms_status_events where provider_message_sid = 'SM_TEST_3'), 'orphan event marked applied');

-- Timeout → send_unknown; a later callback can still complete it:
create temp table r4 as select * from pg_temp.claim('pax:1002:CHECK_IN:checkin', 1002, 'A-0714-1', '+13055550202', 'CHECK_IN', 'CHECK_IN', 'v1', 'body', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check(public.airvalet_sms_mark_result((select message_id from r4), 'send_unknown', null, null, 'TIMEOUT', 'timeout', 1) = 'send_unknown', 'timeout → send_unknown (no blind retry)');
create temp table r4b as select * from pg_temp.claim('pax:1002:CHECK_IN:checkin', 1002, 'A-0714-1', '+13055550202', 'CHECK_IN', 'CHECK_IN', 'v1', 'body', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check(not (select claimed from r4b) and (select status from r4b) = 'send_unknown', 'retry of an unknown send is NOT re-claimed');

-- Failure path:
create temp table r5 as select * from pg_temp.claim('pax:1004:CHECK_IN:checkin', 1004, '0801-1', '+13055550404', 'CHECK_IN', 'CHECK_IN', 'v1', 'body', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check(public.airvalet_sms_mark_result((select message_id from r5), 'failed', null, null, '21211', 'invalid', 1) = 'failed', 'provider rejection → failed');
select pg_temp.check((select failed_at is not null from public.airvalet_sms_messages where id = (select message_id from r5)), 'failed_at set');

-- ── Opt-out + rate limit ─────────────────────────────────────────────────
select public.airvalet_sms_mark_opted_out('+13055550909', 'twilio_21610');
create temp table r6 as select * from pg_temp.claim('pax:9:CHECK_IN:x', null, null, '+13055550909', 'CHECK_IN', null, null, 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check(not (select claimed from r6) and (select error_code from r6) = 'OPTED_OUT', 'opted-out phone → blocked, never sent');

do $$ declare i int; r record; begin
  for i in 1..6 loop
    select * into r from pg_temp.claim('rl:' || i, null, null, '+13055558888', 'CUSTOM_OPERATIONAL', 't' || i, null, 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
    if not r.claimed then raise exception 'FAIL: claim % unexpectedly blocked (%)', i, r.error_code; end if;
    perform public.airvalet_sms_mark_result(r.message_id, 'queued', 'SM_RL_' || i, 'MG', null, null, 1); -- provider answered
  end loop;
  select * into r from pg_temp.claim('rl:7', null, null, '+13055558888', 'CUSTOM_OPERATIONAL', 't' || i, null, 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
  if r.claimed or r.error_code <> 'RATE_LIMIT_HOUR' then raise exception 'FAIL: 7th message in an hour not rate limited'; end if;
  raise notice 'ok  per-phone hourly rate limit (6) enforced';
end $$;

-- ── Inbound: matching by phone + conversation context ────────────────────
create temp table i1 as select * from public.airvalet_sms_record_inbound('SM_IN_1', '+13055550202', 'Returning Friday 3pm', 'MG_TEST', null);
select pg_temp.check((select inserted and passenger_id = 1002 and match_method = 'last_outbound' from i1), 'reply after our outbound → that passenger (last_outbound)');
create temp table i1b as select * from public.airvalet_sms_record_inbound('SM_IN_1', '+13055550202', 'Returning Friday 3pm', 'MG_TEST', null);
select pg_temp.check((select not inserted and message_id = (select message_id from i1) from i1b), 'Twilio webhook retry of same inbound → idempotent');

update public.airvalet_sms_messages set created_at = now() - interval '5 days' where phone_e164 = '+13055550404';
create temp table i2 as select * from public.airvalet_sms_record_inbound('SM_IN_2', '+13055550404', 'hi', 'MG_TEST', null);
select pg_temp.check((select passenger_id = 1004 and match_method = 'recent_outbound' from i2), 'shared family phone + recent outbound context → that passenger');

create temp table i3 as select * from public.airvalet_sms_record_inbound('SM_IN_3', '+13055550101', 'hi', 'MG_TEST', null);
select pg_temp.check((select passenger_id = 1001 and match_method = 'last_outbound' from i3), 'Alice reply matched (her ticket string is reused by Carol)');

insert into public.passengers (id, name, phone, ticket, status) values (1007, 'Fred', '3055550707', '0805-1', 'PENDING');
create temp table i4 as select * from public.airvalet_sms_record_inbound('SM_IN_4', '+13055550707', 'hi', 'MG_TEST', null);
select pg_temp.check((select passenger_id = 1007 and match_method = 'active_passenger' from i4), 'no outbound yet, one active passenger → match');

insert into public.passengers (id, name, phone, ticket, status) values (1008, 'Gil', '3055550808', '0806-1', 'PENDING'), (1009, 'Gia', '3055550808', '0806-2', 'PENDING');
create temp table i5 as select * from public.airvalet_sms_record_inbound('SM_IN_5', '+13055550808', 'hi', 'MG_TEST', null);
select pg_temp.check((select passenger_id is null and match_method = 'ambiguous' from i5), 'two active passengers, no context → ambiguous (staff assigns)');
select pg_temp.check((select match_candidates = '[1009, 1008]'::jsonb from public.airvalet_sms_messages where provider_message_sid = 'SM_IN_5'), 'ambiguous keeps candidate list');

create temp table i6 as select * from public.airvalet_sms_record_inbound('SM_IN_6', '+15555550000', 'who is this', 'MG_TEST', null);
select pg_temp.check((select passenger_id is null and match_method = 'unmatched' from i6), 'unknown phone → unmatched, still stored');

-- STOP / START
select public.airvalet_sms_record_inbound('SM_IN_7', '+13055550101', 'STOP', 'MG_TEST', 'STOP');
create temp table r7 as select * from pg_temp.claim('pax:1001:VEHICLE_READY:ready', 1001, '0714-3', '+13055550101', 'VEHICLE_READY', null, null, 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select error_code from r7) = 'OPTED_OUT', 'after inbound STOP → next send blocked');
select public.airvalet_sms_record_inbound('SM_IN_8', '+13055550101', 'START', 'MG_TEST', 'START');
create temp table r8 as select * from pg_temp.claim('pax:1001:VEHICLE_READY:ready2', 1001, '0714-3', '+13055550101', 'VEHICLE_READY', null, null, 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select claimed from r8), 'after START → sending allowed again');
select public.airvalet_sms_mark_result((select message_id from r8), 'queued', 'SM_R8', 'MG', null, null, 1);
update public.airvalet_sms_messages set created_at = now() - interval '3 minutes' where id = (select message_id from r8);
create temp table r9 as select * from pg_temp.claim('pax:1001:VEHICLE_READY:ready', 1001, '0714-3', '+13055550101', 'VEHICLE_READY', null, null, 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select claimed from r9) and (select message_id from r9) <> (select message_id from r7), 'after START the SAME key that was blocked by STOP can send (new row)');
select pg_temp.check((select status = 'blocked' and error_code = 'OPTED_OUT' and idempotency_key like 'pax:1001:VEHICLE_READY:ready:blocked:%' from public.airvalet_sms_messages where id = (select message_id from r7)), 'the blocked attempt stays in history under a retired key');
create temp table r10 as select * from pg_temp.claim('pax:1001:VEHICLE_READY:ready', 1001, '0714-3', '+13055550101', 'VEHICLE_READY', null, null, 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check(not (select claimed from r10) and (select message_id from r10) = (select message_id from r9), 'once claimed (not blocked) the key is idempotent again → no double send');

-- ── Consent gate ─────────────────────────────────────────────────────────
create temp table c1 as select * from pg_temp.claim('pax:1006:CHECK_IN:checkin', null, null, '+13055550606', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check(not (select claimed from c1) and (select error_code from c1) = 'NO_CONSENT', 'no recorded opt-in → NO_CONSENT, never sent');
select public.airvalet_sms_record_inbound('SM_IN_C1', '+13055550606', 'Is my car ready?', 'MG_TEST', null);
create temp table c2 as select * from pg_temp.claim('reply:c2', null, null, '+13055550606', 'REPLY', null, null, 'Yes, it is.', 1, 'mock', '00000000-0000-0000-0000-0000000000a1', 6, 20, 'Ana (staff)');
select pg_temp.check((select claimed from c2), 'REPLY within 24 h of passenger''s own text allowed without prior opt-in');
select pg_temp.check((select sent_by_name from public.airvalet_sms_messages where id = (select message_id from c2)) = 'Ana (staff)', 'staff name snapshot stored on reply');
create temp table c3 as select * from pg_temp.claim('pax:x:CHECK_IN:c3', null, null, '+13055550606', 'CHECK_IN', null, null, 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select error_code from c3) = 'NO_CONSENT', 'conversational exception covers REPLY only, not templates');
select pg_temp.check((select count(*) from public.airvalet_sms_consents where phone_e164 = '+13055550101' and method = 'keyword_stop') = 1, 'STOP also writes a revoked consent row');
select pg_temp.check((select status from public.airvalet_sms_consents where phone_e164 = '+13055550101' order by seq desc limit 1) = 'granted', 'START re-grants consent (latest row)');

-- ── Staff functions (authenticated, role-checked) ────────────────────────
insert into public.passengers (id, name, phone, ticket, status) values (1010, 'Hal', '3055551010', '0810-1', 'PENDING');
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
create temp table k1 as select * from public.airvalet_sms_record_consent(1010, 'airvalet-optin-v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'Ana');
select pg_temp.check((select enrolled and reason = 'ENROLLED' and phone_e164 = '+13055551010' and not opted_out from k1), 'attendant records consent on an approved device → ticket enrolled; phone taken from passenger row');
select pg_temp.check((select staff_name = 'Ana' and device_id = (select id from public.airvalet_sms_devices where label = 'Test iPad') from public.airvalet_sms_enrollments where passenger_id = 1010), 'enrollment records the device and the staff member picked in the UI');
select pg_temp.check((select recorded_by = '00000000-0000-0000-0000-0000000000a1' and method = 'checkin_attendant' and disclosure_version = 'airvalet-optin-v1' from public.airvalet_sms_consents where id = (select consent_id from k1)), 'consent row records who/how/which disclosure');
select pg_temp.check((select not enrolled and reason = 'INVALID_PHONE' from public.airvalet_sms_record_consent(1006, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')), 'consent refused for passenger with invalid phone (nothing recorded)');
create temp table k2 as select * from public.airvalet_sms_record_consent(1001, 'airvalet-optin-v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
select pg_temp.check(not (select opted_out from k2), 'consent for previously STOP-then-START phone reports not opted out');
select pg_temp.check((select unread_count from public.airvalet_sms_conversations where passenger_id = 1002) = 1, 'conversation view: unread inbound counted');
select pg_temp.check((select has_consent from public.airvalet_sms_conversations where passenger_id = 1002), 'conversation view: consent flag');
select pg_temp.check(public.airvalet_sms_mark_read(1002, null) = 1, 'mark_read marks the passenger''s unread inbound');
select pg_temp.check((select unread_count from public.airvalet_sms_conversations where passenger_id = 1002) = 0, 'unread badge cleared');
select pg_temp.check((select count(*) from public.airvalet_sms_review_queue) = 3, 'review queue lists ambiguous/unmatched inbound');
do $$ begin
  perform public.airvalet_sms_assign_inbound((select id from public.airvalet_sms_messages where provider_message_sid = 'SM_IN_5'), 1001);
  raise exception 'FAIL: assigned to passenger with a different phone';
exception when sqlstate '22023' then raise notice 'ok  assign refused when passenger phone ≠ sender';
end $$;
select public.airvalet_sms_assign_inbound((select id from public.airvalet_sms_messages where provider_message_sid = 'SM_IN_5'), 1009);
select pg_temp.check((select passenger_id = 1009 and match_method = 'manual' and assigned_by is not null from public.airvalet_sms_messages where provider_message_sid = 'SM_IN_5'), 'ambiguous inbound assigned manually by staff');
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
do $$ begin
  perform public.airvalet_sms_record_consent(1010, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  raise exception 'FAIL: TV_ONLY can record consent';
exception when insufficient_privilege then raise notice 'ok  TV_ONLY cannot record consent';
end $$;
do $$ begin
  perform public.airvalet_sms_mark_read(1001, null);
  raise exception 'FAIL: TV_ONLY can mark read';
exception when insufficient_privilege then raise notice 'ok  TV_ONLY cannot mark read';
end $$;
select pg_temp.check((select count(*) from public.airvalet_sms_conversations) = 0, 'TV_ONLY sees no conversations');
reset role;

set local role anon;
do $$ begin
  perform public.airvalet_sms_record_consent(1010, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  raise exception 'FAIL: anon can record consent';
exception when insufficient_privilege then raise notice 'ok  anon cannot record consent';
end $$;
do $$ begin
  perform 1 from public.airvalet_sms_conversations;
  raise exception 'FAIL: anon can read conversations';
exception when insufficient_privilege then raise notice 'ok  anon cannot read conversations';
end $$;
reset role;

-- ── Enrollment at check-in: only NEW tickets, approved device, within 2h ──
insert into public.passengers (id, name, phone, ticket, status) values
  (1011, 'Ivy', '3055551011', '0810-2', 'PENDING'), (1012, 'Jo', '3055551012', '0810-3', 'PENDING'),
  (1013, 'Kai', '3055551013', '0810-4', 'DELIVERED'), (1014, 'Lu', '3055551014', '0810-5', 'PENDING');
update public.passengers set created_at = now() - interval '2 hours' where id = 1012;     -- before the cutover
update public.passengers set created_at = now() - interval '3 hours' where id = 1014;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}';
select pg_temp.check((select not enrolled and reason = 'DEVICE_NOT_AUTHORIZED' from public.airvalet_sms_record_consent(1011, 'v1', null)), 'enroll without a device key → DEVICE_NOT_AUTHORIZED');
select pg_temp.check((select not enrolled and reason = 'DEVICE_NOT_AUTHORIZED' from public.airvalet_sms_record_consent(1011, 'v1', 'pending_device_key_' || repeat('b', 40))), 'enroll from a pending (unapproved) device → refused');
select pg_temp.check((select not enrolled and reason = 'TICKET_NOT_ELIGIBLE' from public.airvalet_sms_record_consent(1012, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')), 'ticket created BEFORE the cutover can never join (stays on the old system)');
select pg_temp.check((select not enrolled and reason = 'TICKET_NOT_ELIGIBLE' from public.airvalet_sms_record_consent(1013, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')), 'delivered ticket cannot join');
reset role;
update public.airvalet_sms_settings set cutover_at = now() - interval '5 hours';
set local role authenticated;
select pg_temp.check((select not enrolled and reason = 'CHECKIN_WINDOW_CLOSED' from public.airvalet_sms_record_consent(1014, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')), 'only at check-in: ticket older than 2h cannot join later');
reset role;
update public.airvalet_sms_settings set cutover_at = now() - interval '1 hour', cutover_after_id = 1011;
set local role authenticated;
select pg_temp.check((select not enrolled and reason = 'TICKET_NOT_ELIGIBLE' from public.airvalet_sms_record_consent(1011, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')), 'ticket id ≤ cutover id cannot join even if its timestamp looks new');
reset role;
update public.airvalet_sms_settings set cutover_after_id = 0, sending_enabled = false;
set local role authenticated;
select pg_temp.check((select not enrolled and reason = 'TICKET_NOT_ELIGIBLE' from public.airvalet_sms_record_consent(1011, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')), 'program paused → no new enrollments (check-in keeps working on iPhone SMS)');
reset role;
update public.airvalet_sms_settings set sending_enabled = true;
set local role authenticated;
select pg_temp.check((select enrolled and reason = 'ENROLLED' from public.airvalet_sms_record_consent(1011, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'Bo')), 'new check-in on approved device after cutover → enrolled');
select pg_temp.check((select enrolled and reason = 'ALREADY_ENROLLED' from public.airvalet_sms_record_consent(1011, 'v1', 'test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'Bo')), 'repeat enrollment is idempotent (no duplicate consent)');
select pg_temp.check((select count(*) from public.airvalet_sms_enrollments where passenger_id = 1011) = 1 and (select count(*) from public.airvalet_sms_consents where passenger_id = 1011) = 1, 'exactly one enrollment + one consent row');
select pg_temp.check((select count(*) from public.airvalet_sms_enrollments where passenger_id in (1012, 1013, 1014)) = 0, 'refused tickets left no enrollment');
reset role;
select pg_temp.check(public.airvalet_pass_mint(1012) is null and not exists (select 1 from public.airvalet_pass_links where passenger_id = 1012), 'no passenger link for a ticket outside the Twilio program');
set local role authenticated;
reset role;
-- Cutover phrase / ADMIN path (state restored afterwards).
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
do $$ begin
  perform public.airvalet_sms_set_cutover('START NEW CHECK-INS');
  raise exception 'FAIL: cutover moved while already set';
exception when sqlstate '22023' then raise notice 'ok  cutover cannot be silently moved once set';
end $$;
select pg_temp.check((select cutover_at is null and cutover_after_id is null from public.airvalet_sms_set_cutover('STOP NEW CHECK-INS')), 'ADMIN STOP NEW CHECK-INS closes enrollment');
select pg_temp.check((select cutover_at = now() and cutover_after_id = (select max(id) from public.passengers) from public.airvalet_sms_set_cutover('START NEW CHECK-INS')), 'ADMIN START NEW CHECK-INS → cutover = now + current max ticket id');
reset role;
update public.airvalet_sms_settings set cutover_at = now() - interval '1 hour', cutover_after_id = 0;

-- ── Return operator: departure (ticket) and return are independent ───────
select pg_temp.check(public.airvalet_departure_operator('A-0714-1') = 'ASCEND' and public.airvalet_departure_operator('0714-3') = 'MAKERS', 'departure operator = existing ticket-prefix rule');
select pg_temp.check(public.airvalet_return_location('MAKERS') = 'HANGAR_19' and public.airvalet_return_location('ASCEND') = 'CUSTOMS'
  and public.airvalet_return_location('OTHER') is null and public.airvalet_return_location(null) is null, 'place derived from return only; OTHER → no place');
select pg_temp.check((select string_agg(id || '=' || coalesce(return_operator, 'null'), ',' order by id) from public.passengers where id between 9001 and 9005)
  = '9001=OTHER,9002=MAKERS,9003=ASCEND,9004=MAKERS,9005=null', 'backfill: Other Boat→OTHER, else departure (Delivery at Customs is NOT a return operator); delivered untouched');
do $$ begin
  update public.passengers set return_operator = 'BOAT' where id = 1001;
  raise exception 'FAIL: invalid return operator accepted';
exception when check_violation then raise notice 'ok  return operator limited to MAKERS/ASCEND/OTHER';
end $$;

create function pg_temp.place(p_id bigint) returns text language sql as $$
  select coalesce(public.airvalet_return_location(return_operator), '-') from public.passengers where id = p_id $$;
create function pg_temp.dep(p_id bigint) returns text language sql as $$
  select public.airvalet_departure_operator(ticket) from public.passengers where id = p_id $$;

insert into public.passengers (id, name, phone, ticket, status) values
  (5001, 'S ONE',   '3055555001', '1001-1',   'PENDING'),
  (5002, 'S TWO',   '3055555002', '1001-2',   'PENDING'),
  (5003, 'S THREE', '3055555003', 'A-1001-3', 'PENDING'),
  (5004, 'S FOUR',  '3055555004', 'A-1001-4', 'PENDING'),
  (5005, 'S FIVE',  '3055555005', '1001-5',   'PENDING'),
  (5006, 'S SIX',   '3055555006', 'A-1001-6', 'PENDING');
select pg_temp.check((select bool_and(return_operator = public.airvalet_departure_operator(ticket)) from public.passengers where id between 5001 and 5006), 'check-in default: return = departure');
-- 1 Makers → Makers
select pg_temp.check(pg_temp.dep(5001) = 'MAKERS' and pg_temp.place(5001) = 'HANGAR_19', 'scenario 1  Makers → Makers = Hangar 19');
-- 2 Makers → Ascend
update public.passengers set return_operator = 'ASCEND' where id = 5002;
select pg_temp.check(pg_temp.dep(5002) = 'MAKERS' and pg_temp.place(5002) = 'CUSTOMS', 'scenario 2  Makers → Ascend = Customs, departure unchanged');
-- 3 Ascend → Ascend
select pg_temp.check(pg_temp.dep(5003) = 'ASCEND' and pg_temp.place(5003) = 'CUSTOMS', 'scenario 3  Ascend → Ascend = Customs');
-- 4 Ascend → Makers
update public.passengers set return_operator = 'MAKERS' where id = 5004;
select pg_temp.check(pg_temp.dep(5004) = 'ASCEND' and pg_temp.place(5004) = 'HANGAR_19', 'scenario 4  Ascend → Makers = Hangar 19');
-- 5 Makers → Other
update public.passengers set return_operator = 'OTHER' where id = 5005;
select pg_temp.check(pg_temp.dep(5005) = 'MAKERS' and pg_temp.place(5005) = '-', 'scenario 5  Makers → Other = no place (manual)');
-- 6 Ascend → Other
update public.passengers set return_operator = 'OTHER' where id = 5006;
select pg_temp.check(pg_temp.dep(5006) = 'ASCEND' and pg_temp.place(5006) = '-', 'scenario 6  Ascend → Other = no place (manual)');
-- 7 Ascend initially → later Makers (mid-trip change)
select pg_temp.check(pg_temp.place(5003) = 'CUSTOMS', 'scenario 7a Ascend planned → Customs');
update public.passengers set return_operator = 'MAKERS' where id = 5003;
select pg_temp.check(pg_temp.place(5003) = 'HANGAR_19' and pg_temp.dep(5003) = 'ASCEND', 'scenario 7b changed to Makers → Hangar 19 immediately; departure still Ascend');
-- 8 Makers initially → later Ascend
update public.passengers set return_operator = 'ASCEND' where id = 5001;
select pg_temp.check(pg_temp.place(5001) = 'CUSTOMS' and pg_temp.dep(5001) = 'MAKERS', 'scenario 8  Makers planned → changed to Ascend → Customs');
-- 9 Ascend → Other → Makers
update public.passengers set return_operator = 'OTHER' where id = 5006;
select pg_temp.check(pg_temp.place(5006) = '-', 'scenario 9a Ascend → Other');
update public.passengers set return_operator = 'MAKERS' where id = 5006;
select pg_temp.check(pg_temp.place(5006) = 'HANGAR_19' and pg_temp.dep(5006) = 'ASCEND', 'scenario 9b Other → Makers = Hangar 19');
-- 10 manual value never rewritten from the departure
update public.passengers set ticket = 'A-1001-2', name = 'S TWO EDITED', status = 'NO DATE' where id = 5002;
select pg_temp.check((select return_operator from public.passengers where id = 5002) = 'ASCEND', 'scenario 10a later edits (even ticket/departure) never rewrite return');
update public.passengers set ticket = '1001-2' where id = 5002;
select pg_temp.check((select return_operator from public.passengers where id = 5002) = 'ASCEND', 'scenario 10b departure changed back: return still the manual value');
insert into public.passengers (id, name, phone, ticket, status, return_operator) values (5007, 'S SEVEN', '3055555007', 'A-1001-7', 'PENDING', 'OTHER');
select pg_temp.check((select return_operator from public.passengers where id = 5007) = 'OTHER', 'scenario 10c explicit value at check-in is kept (default only fills blanks)');

-- 11 change AFTER a return instruction was sent → Needs Review, nothing sent
insert into public.airvalet_sms_consents (phone_e164, status, method) values ('+13055555004', 'granted', 'checkin_attendant');
create temp table rv as select * from pg_temp.claim('pax:5004:VEHICLE_READY:ready:HANGAR_19', 5004, 'A-1001-4', '+13055555004', 'VEHICLE_READY', 'HANGAR19_WELCOME_BACK', 'v1', 'b', 2, 'mock', '00000000-0000-0000-0000-0000000000a1');
select public.airvalet_sms_mark_result((select message_id from rv), 'sent', 'SM_RV_1', null, null, null, 1);
update public.airvalet_sms_messages set created_at = now() - interval '3 hours', sent_at = now() - interval '3 hours' where id = (select message_id from rv); -- sent earlier today
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 5004) = 0, 'scenario 11a instructions match current return → no review');
create temp table out_before as select count(*) n from public.airvalet_sms_messages where direction = 'outbound';
update public.passengers set return_operator = 'ASCEND' where id = 5004;
select pg_temp.check((select instructions_place = 'HANGAR_19' and current_place = 'CUSTOMS' and reason = 'Return changed - passenger may have old instructions'
                       from public.airvalet_return_reviews where passenger_id = 5004), 'scenario 11b return changed after Hangar 19 instructions → Needs Review');
select pg_temp.check((select count(*) from public.airvalet_sms_messages where direction = 'outbound') = (select n from out_before), 'scenario 11c no message created automatically');
update public.passengers set return_operator = 'OTHER' where id = 5004;
select pg_temp.check((select current_place is null from public.airvalet_return_reviews where passenger_id = 5004), 'scenario 11d → OTHER after instructions still in review (no place now)');
update public.passengers set return_operator = 'MAKERS' where id = 5004;
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 5004) = 0, 'scenario 11e changed back to the instructed return → review clears itself');
update public.passengers set return_operator = 'ASCEND' where id = 5004;
create temp table rv2 as select * from pg_temp.claim('pax:5004:VEHICLE_READY:ready:CUSTOMS', 5004, 'A-1001-4', '+13055555004', 'VEHICLE_READY', 'CUSTOMS_WELCOME', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select claimed from rv2), 'scenario 11f staff can send the corrected instruction (new place = new key, not a duplicate)');
select public.airvalet_sms_mark_result((select message_id from rv2), 'sent', 'SM_RV_2', null, null, null, 1);
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 5004) = 0, 'scenario 11g corrected instruction sent → review clears');
-- legacy iOS Messages Welcome Back counts as instructions too; the place is
-- captured at send time (flags follow the return afterwards)
update public.passengers set return_operator = 'MAKERS' where id = 5001;
update public.passengers set welcome_back_sent_at = now() - interval '1 hour' where id = 5001;  -- iOS Welcome Back: Hangar 19 text
select pg_temp.check((select place from public.airvalet_return_instructions where passenger_id = 5001 and source = 'legacy_welcome_back') = 'HANGAR_19', 'scenario 11h legacy iOS send captured with the place told (Hangar 19)');
update public.passengers set return_operator = 'ASCEND' where id = 5001;
select pg_temp.check((select instructions_source = 'legacy_ios' and instructions_place = 'HANGAR_19' and current_place = 'CUSTOMS' from public.airvalet_return_reviews where passenger_id = 5001), 'scenario 11i legacy iOS Welcome Back + later change → Needs Review');
insert into public.passengers (id, name, phone, ticket, status) values (6005, 'UNDO TEST', '3055556005', '1101-5', 'PENDING');
update public.passengers set welcome_back_sent_at = now() where id = 6005;
update public.passengers set return_operator = 'OTHER' where id = 6005;
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 6005) = 1, 'legacy Welcome Back then change → in review');
update public.passengers set welcome_back_sent_at = null where id = 6005;  -- staff pressed Undo (message was never really sent)
select pg_temp.check((select count(*) from public.airvalet_return_instructions where passenger_id = 6005) = 0
  and (select count(*) from public.airvalet_return_reviews where passenger_id = 6005) = 0, 'Undo clears the captured instruction and the review');

-- 12 change BEFORE any return instruction → no review, no message
create temp table out_before12 as select count(*) n from public.airvalet_sms_messages where direction = 'outbound';
update public.passengers set return_operator = 'ASCEND' where id = 5005;
update public.passengers set return_operator = 'MAKERS' where id = 5005;
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id in (5002, 5003, 5005, 5006)) = 0, 'scenario 12a changes before any instruction → no Needs Review');
select pg_temp.check((select count(*) from public.airvalet_sms_messages where direction = 'outbound') = (select n from out_before12), 'scenario 12b changes never create messages');

-- Acknowledge (staff, role-checked)
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 5001) = 1, 'ADMIN sees the review');
select public.airvalet_return_review_ack(5001, 'NO_UPDATE_NEEDED');
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 5001) = 0, 'acknowledged → leaves Needs Review');
reset role;
update public.passengers set return_operator = 'OTHER' where id = 5001;
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 5001) = 1, 'a NEW change after the ack shows up again');
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
do $$ begin
  perform public.airvalet_return_review_ack(5001, 'NO_UPDATE_NEEDED');
  raise exception 'FAIL: TV_ONLY can acknowledge';
exception when insufficient_privilege then raise notice 'ok  TV_ONLY cannot acknowledge reviews';
end $$;
select pg_temp.check((select count(*) from public.airvalet_return_reviews) = 0, 'TV_ONLY sees no reviews');
reset role;

-- ── Legacy flags are derived from Returning with and can never diverge ────
create function pg_temp.flags_consistent() returns boolean language sql as $$
  select not exists (select 1 from public.passengers p where p.return_operator is not null
    and (coalesce(p.not_returning_with_makers_air, false) <> (p.return_operator = 'OTHER')
         or (p.return_operator <> 'MAKERS' and p.delivery_at_customs)
         or (p.customs_exception_requested_at is not null and (p.return_operator <> 'MAKERS' or p.delivery_at_customs)))) $$;
create function pg_temp.flags(p_id bigint) returns text language sql as $$
  select return_operator || '/customs=' || delivery_at_customs || '/otherboat=' || coalesce(not_returning_with_makers_air, false)
    from public.passengers where id = p_id $$;

select pg_temp.check(pg_temp.flags(9001) = 'OTHER/customs=false/otherboat=true' and pg_temp.flags(9002) = 'MAKERS/customs=true/otherboat=false'
  and pg_temp.flags(9003) = 'ASCEND/customs=false/otherboat=false' and pg_temp.flags(9004) = 'MAKERS/customs=false/otherboat=false', 'flags after backfill match Returning with');
insert into public.passengers (id, name, phone, ticket, status) values (6001, 'FLAG TEST', '3055556001', '1101-1', 'PENDING');
select pg_temp.check(pg_temp.flags(6001) = 'MAKERS/customs=false/otherboat=false', 'flags at check-in default');
update public.passengers set return_operator = 'ASCEND' where id = 6001;
select pg_temp.check(pg_temp.flags(6001) = 'ASCEND/customs=false/otherboat=false', 'toggle 1 Makers → Ascend (Customs from the return, flag stays false)');
update public.passengers set return_operator = 'OTHER' where id = 6001;
select pg_temp.check(pg_temp.flags(6001) = 'OTHER/customs=false/otherboat=true', 'toggle 2 Ascend → Other');
update public.passengers set return_operator = 'MAKERS' where id = 6001;
select pg_temp.check(pg_temp.flags(6001) = 'MAKERS/customs=false/otherboat=false', 'toggle 3 Other → Makers');
update public.passengers set ticket = 'A-1101-1' where id = 6001;
select pg_temp.check(pg_temp.flags(6001) = 'MAKERS/customs=false/otherboat=false', 'edit ticket (even to Ascend prefix): return and flags unchanged');
update public.passengers set return_operator = 'ASCEND', name = 'FLAG TEST' where id = 6001;
update public.passengers set return_operator = 'ASCEND', name = 'FLAG TEST' where id = 6001;
select pg_temp.check(pg_temp.flags(6001) = 'ASCEND/customs=false/otherboat=false', 'save twice: identical result');
update public.passengers set delivery_at_customs = true where id = 6001;  -- old client writes the legacy Customs flag only
select pg_temp.check(pg_temp.flags(6001) = 'ASCEND/customs=false/otherboat=false', 'legacy Customs flag cannot contradict an Ascend return (re-derived)');
update public.passengers set delivery_at_customs = false, not_returning_with_makers_air = true where id = 6001;  -- old client ticks "Other Boat"
select pg_temp.check(pg_temp.flags(6001) = 'OTHER/customs=false/otherboat=true', 'old client "Other Boat" toggle is honoured (→ OTHER), flags consistent');
update public.passengers set obs = 'NOTE', loc = 'HANGAR 7' where id = 6001;
select pg_temp.check(pg_temp.flags(6001) = 'OTHER/customs=false/otherboat=true', 'unrelated edit keeps flags consistent');
update public.passengers set not_returning_with_makers_air = false where id = 6001;  -- old client unticks it
select pg_temp.check(pg_temp.flags(6001) = 'ASCEND/customs=false/otherboat=false', 'old client unticks "Other Boat" → departure operator (ticket is A- now)');
insert into public.passengers (id, name, phone, ticket, status, not_returning_with_makers_air) values (6002, 'OLD CLIENT', '3055556002', '1101-2', 'PENDING', true);
select pg_temp.check(pg_temp.flags(6002) = 'OTHER/customs=false/otherboat=true', 'old client check-in with "Other Boat" → OTHER');
insert into public.passengers (id, name, phone, ticket, status, delivery_at_customs) values (6003, 'OLD CLIENT 2', '3055556003', '1101-3', 'PENDING', true);
select pg_temp.check(pg_temp.flags(6003) = 'MAKERS/customs=true/otherboat=false', 'old client check-in with "Delivery at Customs" → Makers return + Customs exception kept');
insert into public.passengers (id, name, phone, ticket, status, return_operator, not_returning_with_makers_air, delivery_at_customs) values (6004, 'NEW CLIENT', '3055556004', 'A-1101-4', 'PENDING', 'MAKERS', true, true);
select pg_temp.check(pg_temp.flags(6004) = 'MAKERS/customs=true/otherboat=false', 'explicit Returning with wins over stale "Other Boat"; Customs on Makers = exception');
select pg_temp.check(pg_temp.flags_consistent(), 'invariant: NO row anywhere has flags contradicting Returning with');
select pg_temp.check(exists (select 1 from pg_constraint where conname = 'passengers_return_flags_consistent' and convalidated), 'CHECK constraint backstop present and validated');
select pg_temp.check((select delivery_at_customs from public.passengers where id = 9005) = false and (select return_operator is null from public.passengers where id = 9005), 'delivered history (NULL return) left untouched');

-- ── Makers return + Customs EXCEPTION (existing delivery_at_customs) ──────
create function pg_temp.pick(p_id bigint) returns text language sql as $$
  select coalesce(public.airvalet_pickup_location(return_operator, delivery_at_customs), '-') || '/' || return_operator
         || case when customs_exception_requested_at is not null then '/requested' else '' end
    from public.passengers where id = p_id $$;
insert into public.passengers (id, name, phone, ticket, status) values (7001, 'EXC ONE', '3055557001', '1201-1', 'PENDING');
-- 1 Makers → Makers, no exception
select pg_temp.check(pg_temp.pick(7001) = 'HANGAR_19/MAKERS', 'exception 1  Makers → Makers, no exception → Hangar 19');
-- 2 passenger asks for Customs; staff have not approved
update public.passengers set customs_exception_requested_at = now() where id = 7001;
select pg_temp.check(pg_temp.pick(7001) = 'HANGAR_19/MAKERS/requested', 'exception 2  requested, not approved → still Hangar 19');
select pg_temp.check((select return_location = 'HANGAR_19' and customs_request_pending and not customs_exception from pg_temp.pv(pg_temp.mint(7001))), 'exception 2b passenger page: Hangar 19 + neutral "under review"');
-- 3 approved (staff action) → Customs; request settled; return untouched
update public.passengers set delivery_at_customs = true where id = 7001;
select pg_temp.check(pg_temp.pick(7001) = 'CUSTOMS/MAKERS', 'exception 3  approved → Customs, Returning with still Makers, request cleared');
select pg_temp.check((select return_location = 'CUSTOMS' and customs_exception from pg_temp.pv(pg_temp.mint(7001))), 'exception 3b passenger page: Customs confirmed');
-- 4 revoked → Hangar 19
update public.passengers set delivery_at_customs = false where id = 7001;
select pg_temp.check(pg_temp.pick(7001) = 'HANGAR_19/MAKERS', 'exception 4  approved then revoked → Hangar 19');
-- 5 switched to Ascend → Customs is the rule, not an exception
update public.passengers set delivery_at_customs = true where id = 7001;
update public.passengers set return_operator = 'ASCEND' where id = 7001;
select pg_temp.check(pg_temp.pick(7001) = 'CUSTOMS/ASCEND' and not (select customs_exception from pg_temp.pv(pg_temp.mint(7001))), 'exception 5  → Ascend: Customs by rule, no longer an exception');
-- 6 Ascend → Makers → Hangar 19 unless approved again
update public.passengers set return_operator = 'MAKERS' where id = 7001;
select pg_temp.check(pg_temp.pick(7001) = 'HANGAR_19/MAKERS', 'exception 6  Ascend → Makers → Hangar 19 (old Customs not carried over)');
update public.passengers set delivery_at_customs = true where id = 7001;
select pg_temp.check(pg_temp.pick(7001) = 'CUSTOMS/MAKERS', 'exception 6b new approval → Customs');
-- 7 changing the pickup override never changes Returning with
update public.passengers set delivery_at_customs = false where id = 7001;
update public.passengers set delivery_at_customs = true where id = 7001;
select pg_temp.check((select return_operator from public.passengers where id = 7001) = 'MAKERS', 'exception 7  approve/revoke/approve never touches Returning with');
insert into public.passengers (id, name, phone, ticket, status, return_operator) values (7002, 'EXC TWO', '3055557002', 'A-1201-2', 'PENDING', 'ASCEND');
update public.passengers set delivery_at_customs = false, customs_exception_requested_at = now() where id = 7002;
select pg_temp.check(pg_temp.pick(7002) = 'CUSTOMS/ASCEND', 'exception 7b override/request on an Ascend return is invalid → ignored, Returning with unchanged');
-- 8 changing Returning with recomputes pickup and clears invalid overrides
update public.passengers set return_operator = 'OTHER' where id = 7001;   -- was Makers + approved Customs
select pg_temp.check(pg_temp.pick(7001) = '-/OTHER' and (select not delivery_at_customs from public.passengers where id = 7001), 'exception 8a Makers+Customs → Other: override cleared, manual');
update public.passengers set return_operator = 'MAKERS' where id = 7001;
select pg_temp.check(pg_temp.pick(7001) = 'HANGAR_19/MAKERS', 'exception 8b Other → Makers: default Hangar 19, nothing carried over');
update public.passengers set customs_exception_requested_at = now() where id = 7001;
update public.passengers set return_operator = 'ASCEND' where id = 7001;
select pg_temp.check(pg_temp.pick(7001) = 'CUSTOMS/ASCEND', 'exception 8c pending request dropped when return becomes Ascend');
-- review: exception instruction sent, then revoked → Needs Review (nothing auto-sent)
insert into public.passengers (id, name, phone, ticket, status, delivery_at_customs) values (7003, 'EXC THREE', '3055557003', '1201-3', 'PENDING', true);
insert into public.airvalet_sms_consents (phone_e164, status, method) values ('+13055557003', 'granted', 'checkin_attendant');
create temp table ex1 as select * from pg_temp.claim('pax:7003:VEHICLE_READY:ready:CUSTOMS_EXCEPTION', 7003, '1201-3', '+13055557003', 'VEHICLE_READY', 'CUSTOMS_EXCEPTION', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select public.airvalet_sms_mark_result((select message_id from ex1), 'sent', 'SM_EX_1', null, null, null, 1);
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 7003) = 0, 'exception instruction matches → no review');
update public.passengers set delivery_at_customs = false where id = 7003;
select pg_temp.check((select instructions_place = 'CUSTOMS' and current_place = 'HANGAR_19' from public.airvalet_return_reviews where passenger_id = 7003), 'exception revoked after Customs instruction → Needs Review');
select pg_temp.check(pg_temp.flags_consistent(), 'invariant holds after all exception scenarios');

-- ── Owner's 8 explicit tests (delivery_at_customs = Makers exception only) ─
create function pg_temp.st(p_id bigint) returns text language sql as $$
  select return_operator || '/dac=' || delivery_at_customs || '/req=' || (customs_exception_requested_at is not null)
         || '/pickup=' || coalesce(public.airvalet_pickup_location(return_operator, delivery_at_customs), '-')
    from public.passengers where id = p_id $$;
insert into public.passengers (id, name, phone, ticket, status) values (8001, 'OWNER EIGHT', '3055558001', '1301-1', 'PENDING');
update public.passengers set delivery_at_customs = true where id = 8001;                      -- staff approve
update public.passengers set delivery_at_customs = true, name = 'OWNER EIGHT' where id = 8001; -- saved again (full form)
update public.passengers set name = 'OWNER EIGHT' where id = 8001;                            -- saved again (other field)
select pg_temp.check(pg_temp.st(8001) = 'MAKERS/dac=true/req=false/pickup=CUSTOMS', 'owner 1  Makers + approved exception → saved again → still approved');
update public.passengers set ticket = '1301-9' where id = 8001;
update public.passengers set ticket = 'A-1301-9' where id = 8001;
select pg_temp.check(pg_temp.st(8001) = 'MAKERS/dac=true/req=false/pickup=CUSTOMS', 'owner 2  ticket edited (even to an Ascend prefix), return untouched → exception kept');
update public.passengers set return_operator = 'ASCEND' where id = 8001;
select pg_temp.check(pg_temp.st(8001) = 'ASCEND/dac=false/req=false/pickup=CUSTOMS', 'owner 3  Makers → Ascend → Makers exception cleared (Customs now by rule)');
update public.passengers set return_operator = 'MAKERS' where id = 8001;
select pg_temp.check(pg_temp.st(8001) = 'MAKERS/dac=false/req=false/pickup=HANGAR_19', 'owner 4  Ascend → Makers → Hangar 19, no automatic exception');
update public.passengers set customs_exception_requested_at = now() where id = 8001;            -- passenger asked
update public.passengers set name = 'OWNER EIGHT', loc = 'HANGAR 7' where id = 8001;            -- saved again
select pg_temp.check(pg_temp.st(8001) = 'MAKERS/dac=false/req=true/pickup=HANGAR_19', 'owner 5  Makers pending request → saved → still pending (pickup Hangar 19)');
update public.passengers set delivery_at_customs = true where id = 8001;                       -- approve
select pg_temp.check(pg_temp.st(8001) = 'MAKERS/dac=true/req=false/pickup=CUSTOMS', 'owner 6  approve → requested_at cleared, delivery_at_customs = true');
update public.passengers set delivery_at_customs = false where id = 8001;                      -- back to Hangar 19
update public.passengers set customs_exception_requested_at = now() where id = 8001;            -- asked again
update public.passengers set customs_exception_requested_at = null where id = 8001;             -- deny
select pg_temp.check(pg_temp.st(8001) = 'MAKERS/dac=false/req=false/pickup=HANGAR_19', 'owner 7  deny → requested_at null, delivery_at_customs false, Hangar 19');
insert into public.passengers (id, name, phone, ticket, status, return_operator) values (8002, 'OLD APP ASCEND', '3055558002', 'A-1301-2', 'PENDING', 'ASCEND');
update public.passengers set delivery_at_customs = true where id = 8002;                        -- old app ticks "Delivery at Customs"
insert into public.passengers (id, name, phone, ticket, status, delivery_at_customs) values (8003, 'OLD APP ASCEND 2', '3055558003', 'A-1301-3', 'PENDING', true);
select pg_temp.check(pg_temp.st(8002) = 'ASCEND/dac=false/req=false/pickup=CUSTOMS' and pg_temp.st(8003) = 'ASCEND/dac=false/req=false/pickup=CUSTOMS', 'owner 8  old app cannot turn an Ascend return into delivery_at_customs = true (update or insert)');
do $$ begin
  -- the CHECK backstop rejects the invalid state even if the trigger were bypassed
  alter table public.passengers disable trigger passengers_sync_return_operator;
  begin
    update public.passengers set delivery_at_customs = true where id = 8002;
    raise exception 'FAIL: Ascend + delivery_at_customs accepted without trigger';
  exception when check_violation then raise notice 'ok  CHECK backstop rejects Ascend + delivery_at_customs even with the trigger off';
  end;
  alter table public.passengers enable trigger passengers_sync_return_operator;
end $$;
select pg_temp.check(pg_temp.flags_consistent(), 'invariant holds after the owner tests');

-- ── Etapa 2: activation, kill switch, caps, duplicates, unconfirmed, alerts ──
insert into public.passengers (id, name, phone, ticket, status) values
  (6101, 'Hana Two', '3055556101', '1501-1', 'PENDING'), (6102, 'Ivo Two', '3055556102', '1501-2', 'PENDING');
insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method, disclosure_version)
select '+1305555' || x, null, 'granted', 'checkin_attendant', 'test-v1' from unnest(array['6101','6102','6103','6104','6105','6106']) x;

-- Kill switch (DB) — paused program blocks everything, nothing reaches Twilio.
update public.airvalet_sms_settings set sending_enabled = false;
select pg_temp.check((select error_code from pg_temp.claim('e2:pause', 6101, null, '+13055556101', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'SMS_PAUSED', 'program paused (settings) → SMS_PAUSED, never sent');
update public.airvalet_sms_settings set sending_enabled = true;
-- Device authorization + ticket eligibility + test mode — on the REAL claim.
insert into public.airvalet_sms_devices (key_hash, label, status) values (public.airvalet_sms_device_key_hash('pending_device_key_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'), 'Phone not approved', 'pending');
insert into public.passengers (id, name, phone, ticket, status) values (6190, 'Old Ticket', '3055556190', '1001-9', 'PENDING');
insert into public.airvalet_sms_consents (phone_e164, status, method, disclosure_version) values ('+13055556190', 'granted', 'checkin_attendant', 't');
create temp table rc_args as select public.airvalet_sms_device_key_hash('test_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') ok_key, public.airvalet_sms_device_key_hash('pending_device_key_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb') pend_key;
select pg_temp.check((select error_code from public.airvalet_sms_claim('e2:nodev', 6101, null, '+13055556101', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1', null, null, null, null)) = 'DEVICE_NOT_AUTHORIZED', 'no device key → DEVICE_NOT_AUTHORIZED (server-side)');
select pg_temp.check((select error_code from public.airvalet_sms_claim('e2:pend', 6101, null, '+13055556101', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1', null, null, null, (select pend_key from rc_args))) = 'DEVICE_NOT_AUTHORIZED', 'device requested but not approved → DEVICE_NOT_AUTHORIZED');
select pg_temp.check((select error_code from public.airvalet_sms_claim('e2:fake', 6101, null, '+13055556101', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1', null, null, null, extensions.digest('guess', 'sha256'))) = 'DEVICE_NOT_AUTHORIZED', 'guessed / forged key → DEVICE_NOT_AUTHORIZED');
select pg_temp.check((select error_code from public.airvalet_sms_claim('e2:old', 6190, null, '+13055556190', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1', null, null, null, (select ok_key from rc_args))) = 'TICKET_NOT_ELIGIBLE', 'ticket NOT enrolled (old system) → TICKET_NOT_ELIGIBLE even with consent + approved device');
select pg_temp.check((select error_code from public.airvalet_sms_claim('e2:nopax', null, null, '+13055556190', 'REPLY', null, null, 'hi', 1, 'mock', '00000000-0000-0000-0000-0000000000a1', null, null, null, (select ok_key from rc_args))) = 'TICKET_NOT_ELIGIBLE', 'no passenger → TICKET_NOT_ELIGIBLE');
update public.airvalet_sms_settings set test_only = true, test_phones = array['+13055556101'];
select pg_temp.check((select error_code from pg_temp.claim('e2:tm1', 6102, null, '+13055556102', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'TEST_MODE_NUMBER', 'test mode: number not on the test list → TEST_MODE_NUMBER');
select pg_temp.check((select claimed from pg_temp.claim('e2:tm2', 6101, null, '+13055556101', 'RETURN_CONFIRMATION', 'RCT', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')), 'test mode: the authorized test number → allowed');
update public.airvalet_sms_settings set test_only = false, test_phones = '{}';
-- Message size cap.
select pg_temp.check((select error_code from pg_temp.claim('e2:long', 6101, null, '+13055556101', 'REPLY', null, null, 'x', 4, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'TOO_LONG', '4 segments > max 3 → TOO_LONG');

-- Duplicates: same REPLY text / same template to the same phone < 2 min.
create temp table e2r1 as select * from pg_temp.claim('e2:r1', 6101, null, '+13055556101', 'REPLY', null, null, 'On our way', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select claimed from e2r1), 'first reply claimed');
select pg_temp.check((select error_code from pg_temp.claim('e2:r1b', 6101, null, '+13055556101', 'REPLY', null, null, 'On our way', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'PREVIOUS_UNCONFIRMED', 'same words while the first is still in flight → held (PREVIOUS_UNCONFIRMED)');
select pg_temp.check((select claimed from pg_temp.claim('e2:r1c', 6101, null, '+13055556101', 'REPLY', null, null, 'See you soon', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')), 'a DIFFERENT reply is not held up by the in-flight one');
select public.airvalet_sms_mark_result((select message_id from e2r1), 'queued', 'SM_E2R1', 'MG', null, null, 1);
select pg_temp.check((select error_code from pg_temp.claim('e2:r2', 6101, null, '+13055556101', 'REPLY', null, null, 'On our way', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'DUPLICATE_RECENT', 'same reply text again with a NEW draft id → DUPLICATE_RECENT');
select pg_temp.check((select claimed from pg_temp.claim('e2:r3', 6101, null, '+13055556101', 'REPLY', null, null, 'Parked at H19', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')), 'different text → allowed');
create temp table e2v1 as select * from pg_temp.claim('e2:v1', 6102, null, '+13055556102', 'VEHICLE_READY', 'HANGAR19_WELCOME_BACK', 'v1', 'b', 2, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check((select claimed from e2v1), 'vehicle-ready (Hangar 19) claimed');
select public.airvalet_sms_mark_result((select message_id from e2v1), 'queued', 'SM_E2V1', 'MG', null, null, 1);
select pg_temp.check((select error_code from pg_temp.claim('e2:v2', 6102, null, '+13055556102', 'VEHICLE_READY', 'HANGAR19_WELCOME_BACK', 'v1', 'b', 2, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'DUPLICATE_RECENT', 'same template, new key, < 2 min → DUPLICATE_RECENT');
select pg_temp.check((select claimed from pg_temp.claim('e2:v3', 6102, null, '+13055556102', 'VEHICLE_READY', 'CUSTOMS_WELCOME', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')), 'CORRECTED template (Customs) → allowed');

-- Unconfirmed (timeout): blocks a blind resend until staff resolve it.
create temp table u1 as select * from pg_temp.claim('e2:u:CHECK_IN', 6101, null, '+13055556101', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.check(public.airvalet_sms_mark_result((select message_id from u1), 'send_unknown', null, null, 'TIMEOUT', 't', 1) = 'send_unknown', 'timeout → send_unknown');
select pg_temp.check((select attention = 'UNCONFIRMED' from public.airvalet_sms_messages where id = (select message_id from u1)), 'send_unknown raises an UNCONFIRMED alert');
update public.airvalet_sms_messages set created_at = now() - interval '5 minutes' where phone_e164 = '+13055556101';
select pg_temp.check((select error_code from pg_temp.claim('e2:u:CHECK_IN:resend', 6101, null, '+13055556101', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'PREVIOUS_UNCONFIRMED', 'another CHECK_IN while the last one is unconfirmed → PREVIOUS_UNCONFIRMED');
select pg_temp.check((select not claimed and status = 'send_unknown' from pg_temp.claim('e2:u:CHECK_IN', 6101, null, '+13055556101', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')), 'retry with the SAME key → existing unconfirmed row, never re-sent');
-- Late status callback carries ?mid → the unconfirmed row adopts its SID and the alert clears.
select pg_temp.check(public.airvalet_sms_apply_status('SM_E2_MID', 'sent', null, null, (select message_id from u1)) = 'applied', 'status callback with ?mid= adopts the SID of an unconfirmed send');
select pg_temp.check((select provider_message_sid = 'SM_E2_MID' and status = 'sent' and attention is null from public.airvalet_sms_messages where id = (select message_id from u1)), 'unconfirmed → sent, alert cleared automatically');
select pg_temp.check(public.airvalet_sms_apply_status('SM_E2_OTHER', 'sent', null, null, (select message_id from u1)) = 'orphan', 'a mid cannot re-bind a row that already has a SID');
-- Reconciliation: pending with no answer for > 10 min → UNCONFIRMED alert.
create temp table u2 as select * from pg_temp.claim('e2:u2', 6102, null, '+13055556102', 'RETURN_CONFIRMATION', 'RC', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
update public.airvalet_sms_messages set created_at = now() - interval '15 minutes' where id = (select message_id from u2);
select set_config('request.jwt.claims', '', true); -- back to a direct DB session (no app user)
select pg_temp.check(public.airvalet_sms_reconcile() >= 1, 'reconcile flags stale pending sends');
select pg_temp.check((select status = 'send_unknown' and attention = 'UNCONFIRMED' and error_code = 'NO_PROVIDER_ANSWER' from public.airvalet_sms_messages where id = (select message_id from u2)), 'stale pending → send_unknown + UNCONFIRMED');
select pg_temp.check(public.airvalet_sms_reconcile() = 0, 'reconcile is idempotent');
-- Carrier outcomes become alerts.
create temp table u3 as select * from pg_temp.claim('e2:u3', null, null, '+13055556103', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select public.airvalet_sms_mark_result((select message_id from u3), 'queued', 'SM_E2_30007', 'MG', null, null, 1);
select public.airvalet_sms_apply_status('SM_E2_30007', 'undelivered', '30007', 'filtered');
create temp table u4 as select * from pg_temp.claim('e2:u4', null, null, '+13055556104', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1');
select public.airvalet_sms_mark_result((select message_id from u4), 'queued', 'SM_E2_30003', 'MG', null, null, 1);
select public.airvalet_sms_apply_status('SM_E2_30003', 'undelivered', '30003', 'unreachable');
select pg_temp.check((select attention from public.airvalet_sms_messages where id = (select message_id from u3)) = 'CARRIER_FILTERED'
  and (select attention from public.airvalet_sms_messages where id = (select message_id from u4)) = 'UNREACHABLE', 'carrier 30007 → CARRIER_FILTERED, 30003 → UNREACHABLE alerts');

-- Alerts + resolution through the app (role checks).
grant select on u1, u2, u3, u4 to authenticated; -- test temp tables only
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
select pg_temp.check((select count(*) from public.airvalet_sms_alerts) = 0, 'TV_ONLY sees no alerts');
do $$ begin
  perform public.airvalet_sms_resolve_alert((select message_id from u2), 'acknowledged');
  raise exception 'FAIL: TV_ONLY resolved an alert';
exception when insufficient_privilege then raise notice 'ok  TV_ONLY cannot resolve alerts';
end $$;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}';
select pg_temp.check((select count(*) >= 3 from public.airvalet_sms_alerts), 'ops see the open alerts (unconfirmed + carrier)');
do $$ begin
  perform public.airvalet_sms_resolve_alert((select message_id from u3), 'marked_not_sent');
  raise exception 'FAIL: delivered-failure marked as not sent';
exception when sqlstate '22023' then raise notice 'ok  only an UNCONFIRMED send can be marked "not sent"';
end $$;
select pg_temp.check(public.airvalet_sms_resolve_alert((select message_id from u3), 'acknowledged') = 'acknowledged', 'carrier alert acknowledged by ops');
select pg_temp.check(public.airvalet_sms_resolve_alert((select message_id from u2), 'marked_not_sent') = 'marked_not_sent', 'unconfirmed send marked NOT received by ops');
-- Devices: request from an ops device; only ADMIN approves; status per key.
create temp table dr1 as select * from public.airvalet_sms_device_request('phone_device_key_dddddddddddddddddddddddddddddddddddddddd', 'iPhone Ana', 'Mozilla/5.0 (iPhone)');
select pg_temp.check((select status = 'pending' from dr1), 'ops device requests texting → pending (not usable yet)');
select pg_temp.check((select status = 'pending' and label = 'iPhone Ana' and not sending_enabled is null from public.airvalet_sms_device_status('phone_device_key_dddddddddddddddddddddddddddddddddddddddd')), 'device_status: this device is pending');
select pg_temp.check((select status = 'unknown' from public.airvalet_sms_device_status('never_seen_key_' || repeat('e', 40))), 'device_status: unknown key → unknown (nothing revealed)');
do $$ begin
  perform public.airvalet_sms_device_decide((select device_id from dr1), 'approved');
  raise exception 'FAIL: IPAD_OPS approved a device';
exception when insufficient_privilege then raise notice 'ok  only ADMIN can approve devices';
end $$;
do $$ begin
  perform public.airvalet_sms_set_settings(p_sending_enabled => true);
  raise exception 'FAIL: IPAD_OPS changed settings';
exception when insufficient_privilege then raise notice 'ok  only ADMIN can change the kill switch / caps';
end $$;
do $$ begin
  perform public.airvalet_sms_set_cutover('START NEW CHECK-INS');
  raise exception 'FAIL: IPAD_OPS set the cutover';
exception when insufficient_privilege then raise notice 'ok  only ADMIN can open new check-ins to Twilio';
end $$;
do $$ begin
  perform key_hash from public.airvalet_sms_devices limit 1;
  raise exception 'FAIL: key hash readable';
exception when insufficient_privilege then raise notice 'ok  device key hashes are never readable';
end $$;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
select public.airvalet_sms_device_decide((select device_id from dr1), 'approved', 'iPhone Ana (ops)');
select pg_temp.check((select status = 'approved' and label = 'iPhone Ana (ops)' and decided_by = '00000000-0000-0000-0000-0000000000a1' from public.airvalet_sms_devices where id = (select device_id from dr1)), 'ADMIN approves the device (who/when recorded)');
select pg_temp.check((select max_per_device_hour = 500 from public.airvalet_sms_set_settings()), 'ADMIN reads/keeps settings (no-op update)');
do $$ begin
  perform public.airvalet_sms_set_settings(p_test_phones => array['3055550101']);
  raise exception 'FAIL: non-E.164 test phone accepted';
exception when sqlstate '22023' then raise notice 'ok  test phones must be +1XXXXXXXXXX';
end $$;
do $$ begin
  perform public.airvalet_sms_set_cutover('yes');
  raise exception 'FAIL: cutover without the phrase';
exception when sqlstate '22023' then raise notice 'ok  cutover needs the explicit confirmation phrase';
end $$;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
do $$ begin
  perform public.airvalet_sms_device_request('tv_device_key_cccccccccccccccccccccccccccccccccccccccc', 'Living room TV');
  raise exception 'FAIL: TV_ONLY requested a device';
exception when insufficient_privilege then raise notice 'ok  the TV login cannot even request texting';
end $$;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}';
select pg_temp.check((select status = 'approved' from public.airvalet_sms_device_status('phone_device_key_dddddddddddddddddddddddddddddddddddddddd')), 'device_status: approved after ADMIN decision');
reset role;
select pg_temp.check((select status = 'failed' and error_code = 'STAFF_MARKED_NOT_SENT' and resolution = 'marked_not_sent' and resolved_by = '00000000-0000-0000-0000-0000000000c1'
                        from public.airvalet_sms_messages where id = (select message_id from u2)), 'marked-not-sent row: failed, who/when recorded');
select pg_temp.check((select claimed from pg_temp.claim('e2:u2', 6102, null, '+13055556102', 'RETURN_CONFIRMATION', 'RC', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')), 'after "not received" the SAME message can be sent again (deliberate)');

-- Volume caps (per device / daily total).
update public.airvalet_sms_settings set max_per_device_hour = (select count(*) from public.airvalet_sms_messages m where m.device_id = (select id from public.airvalet_sms_devices where label = 'Test iPad') and m.status <> 'blocked' and m.created_at > now() - interval '1 hour') + 1;
select pg_temp.check((select claimed from pg_temp.claim('e2:s1', null, null, '+13055556105', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')), 'device under hourly cap → sent');
select pg_temp.check((select error_code from pg_temp.claim('e2:s2', null, null, '+13055556106', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'DEVICE_RATE_LIMIT', 'device over hourly cap → DEVICE_RATE_LIMIT');
update public.airvalet_sms_settings set max_per_device_hour = 500,
  max_messages_day = (select count(*) from public.airvalet_sms_messages where direction = 'outbound' and status <> 'blocked' and created_at > now() - interval '24 hours');
select pg_temp.check((select error_code from pg_temp.claim('e2:d1', null, null, '+13055556106', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 1, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'DAILY_CAP', 'daily message total reached → DAILY_CAP');
update public.airvalet_sms_settings set max_messages_day = 5000,
  max_segments_day = (select coalesce(sum(segments), 0) from public.airvalet_sms_messages where direction = 'outbound' and status <> 'blocked' and created_at > now() - interval '24 hours') + 1;
select pg_temp.check((select error_code from pg_temp.claim('e2:d2', null, null, '+13055556106', 'CHECK_IN', 'CHECK_IN', 'v1', 'b', 2, 'mock', '00000000-0000-0000-0000-0000000000a1')) = 'DAILY_CAP', 'daily segment budget reached → DAILY_CAP');
update public.airvalet_sms_settings set max_segments_day = 10000;
do $$ begin
  update public.airvalet_sms_settings set max_segments_message = 9;
  raise exception 'FAIL: absurd per-message cap accepted';
exception when check_violation then raise notice 'ok  settings bounded by CHECK constraints';
end $$;

-- A conversational "Yes" (no keyword) is never consent / never re-subscribes.
select public.airvalet_sms_record_inbound('SM_IN_STOP_YES', '+13055556105', 'STOP', 'MG_TEST', 'STOP');
create temp table cy as select count(*) n from public.airvalet_sms_consents where phone_e164 = '+13055556105';
select public.airvalet_sms_record_inbound('SM_IN_YES', '+13055556105', 'Yes', 'MG_TEST', null);
select pg_temp.check((select count(*) from public.airvalet_sms_consents where phone_e164 = '+13055556105') = (select n from cy)
  and (select opted_out from public.airvalet_sms_opt_outs where phone_e164 = '+13055556105'), '"Yes" after STOP: no consent row, still opted out');
select pg_temp.check((select message_type = 'INBOUND' from public.airvalet_sms_messages where provider_message_sid = 'SM_IN_YES'), '"Yes" stored as a normal inbound message');

-- ── Passenger link v2 (https://farberos.com/a#<token>) ──────────────────
-- Token: 17 base62 chars (≈101 bits), uniform, unique, only SHA-256 stored.
create temp table toks as select pg_temp.mint(1004) as t from generate_series(1, 200);
select pg_temp.check((select bool_and(t ~ '^[A-Za-z0-9]{17}$') and count(distinct t) = 200 from toks), 'pass tokens: 17 base62 chars, 200 mints → 200 distinct');
create temp table tok_chars as select substr(t, i, 1) c from toks, generate_series(1, 17) i;
select pg_temp.check((select count(distinct c) = 62 and max(n) < 110 and min(n) > 20
                        from (select c, count(*) n from tok_chars group by c) x), 'token symbols uniform: all 62 used, no symbol over/under-represented (3400 draws)');
select pg_temp.check(17 * log(2, 62) >= 96, 'entropy 17·log2(62) ≥ 96 bits');
select pg_temp.check(not exists (select 1 from information_schema.columns where table_name = 'airvalet_pass_links' and data_type in ('text', 'character varying') and column_name <> 'revoke_reason'),
  'no plaintext token column in airvalet_pass_links');
select pg_temp.check((select count(*) = 1 from public.airvalet_pass_links where passenger_id = 1004 and revoked_at is null), 'each mint rotates: exactly one active link per passenger');
select pg_temp.check((select count(*) from public.airvalet_pass_links where passenger_id = 1004 and revoke_reason = 'rotated') = 199, 'previous links revoked as rotated');

create temp table pl as select pg_temp.mint(1001) as t;
select pg_temp.check((select token_hash = extensions.digest((select t from pl), 'sha256') from public.airvalet_pass_links where passenger_id = 1001 and revoked_at is null), 'stored value is SHA-256(token), never the token');
create temp table pv as select * from pg_temp.pv((select t from pl));
select pg_temp.check((select state = 'ok' and first_name = 'Alice' and status = 'PARKED' and return_location = 'HANGAR_19' and not return_other and expires_at is null from pv), 'open service: page ok (name, status, Hangar 19), no expiry yet');
select pg_temp.check((select open_count = 1 and first_opened_at is not null from public.airvalet_pass_links where passenger_id = 1001 and revoked_at is null), 'opening the link is recorded (inbox "link opened")');
select pg_temp.check((select ticket from pv) = '0714-3', 'page shows the operational ticket number exactly as printed');
select pg_temp.check((select ticket from pg_temp.pv(pg_temp.mint(1002))) = 'A-0714-1', 'ticket prefix kept (A-0714-1, not 0714-1)');
select pg_temp.check((select bool_and(state = 'expired' and ticket is null and first_name is null) from (
    select * from pg_temp.pv('0714-3') union all select * from pg_temp.pv('A-0714-1') union all select * from pg_temp.pv('07143')) x),
  'ticket number is NOT a key: a ticket instead of the token returns nothing');
select pg_temp.check(not exists (select 1 from pg_proc where proname like 'airvalet_pass%' and pg_get_function_arguments(oid) ilike '%ticket%'), 'no pass function accepts a ticket argument');
select pg_temp.check(pg_temp.mint(1003) is null, 'no link for a service already DELIVERED');
select pg_temp.check(pg_temp.mint(999999) is null, 'no link for an unknown passenger');
update public.passengers set return_operator = 'ASCEND' where id = 1001;
select pg_temp.check((select return_location from pg_temp.pv((select t from pl))) = 'CUSTOMS', 'page follows the changed return immediately (Ascend → Customs)');
update public.passengers set return_operator = 'OTHER' where id = 1001;
select pg_temp.check((select return_location is null and return_other from pg_temp.pv((select t from pl))), 'page for OTHER: no place, "team will coordinate"');
update public.passengers set return_operator = 'MAKERS' where id = 1001;

-- One identical answer for unknown / malformed / revoked / expired (no oracle).
create temp table uni as select to_jsonb(x) j from pg_temp.pv('AAAAAAAAAAAAAAAAA') x;
select pg_temp.check((select bool_and(to_jsonb(y) = (select j from uni)) from (
    select * from pg_temp.pv('bad token') union all select * from pg_temp.pv('') union all select * from pg_temp.pv(null)
    union all select * from pg_temp.pv('AAAAAAAAAAAA') union all select * from pg_temp.pv((select t from toks where extensions.digest(t, 'sha256') <> (select token_hash from public.airvalet_pass_links where passenger_id = 1004 and revoked_at is null) limit 1))) y)
  and (select j->>'state' from uni) = 'expired', 'unknown / malformed / empty / old-format / rotated → the same "expired" answer');

-- Validity: first DELIVERED fixes expires_at = delivery + 3h, ONCE.
insert into public.passengers (id, name, phone, ticket, status) values
  (9101, 'Val One', '3055559101', '1401-1', 'PENDING'),
  (9102, 'Val Two', '3055559102', '1401-2', 'NO DATE'),
  (9103, 'Val Three', '3055559103', '1401-3', 'PENDING'),
  (9104, 'Val Four', '3055559104', '1401-4', 'PENDING');
create temp table vt as select id, pg_temp.mint(id) t from unnest(array[9101, 9102, 9103, 9104]) id;
select pg_temp.check((select bool_and(state = 'ok') from vt, pg_temp.pv(vt.t)), 'PENDING and NO DATE services: link active');
create temp table d1 as select now() - interval '2 hours 59 minutes' as at;
update public.passengers set status = 'DELIVERED', checkout_date = (select at from d1) where id = 9101;
select pg_temp.check((select expires_at = (select at from d1) + interval '3 hours' from public.airvalet_pass_links where passenger_id = 9101 and revoked_at is null), 'DELIVERED → expires_at = delivery time + exactly 3 hours');
select pg_temp.check((select state = 'ok' and delivered and expires_at is not null from pg_temp.pv((select t from vt where id = 9101))), 'within 3 hours after delivery: page still available (delivered view)');
update public.passengers set status = 'DELIVERED', checkout_date = now() - interval '3 hours 1 second' where id = 9102;
select pg_temp.check((select state from pg_temp.pv((select t from vt where id = 9102))) = 'expired', '3 hours + 1 second after delivery → "This valet link has expired."');
create temp table e1 as select expires_at from public.airvalet_pass_links where passenger_id = 9101 and revoked_at is null;
update public.passengers set status = 'PENDING', checkout_date = null where id = 9101;              -- undo delivery
update public.passengers set status = 'DELIVERED', checkout_date = now() where id = 9101;          -- delivered again later
update public.passengers set ret = '12/31/2026', return_operator = 'ASCEND' where id = 9101;        -- later edits
select pg_temp.check((select expires_at from public.airvalet_pass_links where passenger_id = 9101 and revoked_at is null) = (select expires_at from e1),
  'undo / re-deliver / later edits never move the 3-hour deadline');
update public.passengers set status = 'PENDING', checkout_date = null where id = 9102;              -- undo after expiry
select pg_temp.check((select state from pg_temp.pv((select t from vt where id = 9102))) = 'expired', 'undo after expiry does NOT revive the link');
update public.passengers set status = 'DELIVERED', checkout_date = now() + interval '5 days' where id = 9103;
select pg_temp.check((select expires_at <= now() + interval '3 hours' from public.airvalet_pass_links where passenger_id = 9103 and revoked_at is null), 'future checkout_date cannot extend the window (anchored at now)');
select pg_temp.check(pg_temp.mint(9101) is null, 'no new link can be minted after delivery');

-- Immediate kills: archive, phone change, staff revoke.
update public.passengers set status = 'ARCHIVED' where id = 9103;
select pg_temp.check((select state from pg_temp.pv((select t from vt where id = 9103))) = 'expired'
  and exists (select 1 from public.airvalet_pass_links where passenger_id = 9103 and revoke_reason = 'archived'), 'archive → link revoked immediately');
update public.passengers set phone = '3055559199' where id = 9104;
select pg_temp.check((select state from pg_temp.pv((select t from vt where id = 9104))) = 'expired'
  and exists (select 1 from public.airvalet_pass_links where passenger_id = 9104 and revoke_reason = 'phone_changed'), 'phone corrected → old link (maybe sent to a wrong number) revoked');
create temp table plrv as select pg_temp.mint(1006) t;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
do $$ begin
  perform public.airvalet_pass_revoke(1006);
  raise exception 'FAIL: TV_ONLY can revoke links';
exception when insufficient_privilege then raise notice 'ok  TV_ONLY cannot revoke links';
end $$;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
select pg_temp.check(public.airvalet_pass_revoke(1006) = 1, 'authorized staff (ADMIN) revokes the link');
do $$ begin
  perform token_hash from public.airvalet_pass_links limit 1;
  raise exception 'FAIL: staff can read token hashes';
exception when insufficient_privilege then raise notice 'ok  staff cannot read token_hash (column privilege)';
end $$;
select pg_temp.check((select count(*) >= 1 from public.airvalet_sms_pass_status), 'staff see link state (opened / expires / active) without the hash');
reset role;
select pg_temp.check((select state from pg_temp.pv((select t from plrv))) = 'expired'
  and exists (select 1 from public.airvalet_pass_links where passenger_id = 1006 and revoke_reason = 'staff' and revoked_by = '00000000-0000-0000-0000-0000000000a1'),
  'revoked by staff → expired at once; who revoked is recorded');

-- Throttling (server-side, per client key + global brake on failures).
do $$ declare i int; begin
  for i in 1..8 loop
    if (select state from public.airvalet_pass_view('ZZZZZZZZZZZZZZZZZ', 'rl-a')) <> 'expired' then raise exception 'FAIL: failed lookup % not answered', i; end if;
  end loop;
  raise notice 'ok  8 failed lookups from one client → still answered';
end $$;
select pg_temp.check((select state from public.airvalet_pass_view((select t from pl), 'rl-a')) = 'limited', '9th request from that client is limited even with a VALID token');
select pg_temp.check((select state from public.airvalet_pass_view((select t from pl), 'rl-b')) = 'ok', 'other clients unaffected');
do $$ declare i int; begin
  for i in 1..29 loop
    if (select state from public.airvalet_pass_view((select t from pl), 'rl-c')) <> 'ok' then raise exception 'FAIL: request % limited too early', i; end if;
  end loop;
end $$;
select pg_temp.check((select state from public.airvalet_pass_view((select t from pl), 'rl-c')) = 'ok'
  and (select state from public.airvalet_pass_view((select t from pl), 'rl-c')) = 'limited', 'max 30 requests per client per 10 minutes, then limited');
insert into public.airvalet_pass_rate (bucket, window_start, hits) values ('f:*', date_bin('10 minutes', now(), timestamptz '2000-01-01'), 2000)
  on conflict (bucket, window_start) do update set hits = 2000;
select pg_temp.check((select state from public.airvalet_pass_view('YYYYYYYYYYYYYYYYY', 'rl-d')) = 'limited', 'global brake: under a failed-lookup flood, failing requests are limited');
select pg_temp.check((select state from public.airvalet_pass_view((select t from pl), 'rl-e')) = 'ok', 'global brake never blocks a valid token');
delete from public.airvalet_pass_rate;
select pg_temp.check(not exists (select 1 from public.airvalet_pass_rate where bucket ~ '\d+\.\d+\.\d+\.\d+'), 'rate table holds no raw IP addresses');

-- ── RLS / privileges ─────────────────────────────────────────────────────
set local role anon;
do $$ begin
  perform public.airvalet_pass_view('AAAAAAAAAAAA');
  raise exception 'FAIL: anon can call pass view directly';
exception when insufficient_privilege then raise notice 'ok  anon cannot call pass view (only via Edge Function)';
end $$;
do $$ begin
  perform 1 from public.airvalet_pass_links limit 1;
  raise exception 'FAIL: anon can read pass links';
exception when insufficient_privilege then raise notice 'ok  anon cannot read pass links';
end $$;
do $$ begin
  perform pg_temp.mint(1001);
  raise exception 'FAIL: anon can mint links';
exception when insufficient_privilege then raise notice 'ok  anon cannot mint links';
end $$;
do $$ begin
  perform 1 from public.airvalet_pass_rate limit 1;
  raise exception 'FAIL: anon can read throttle table';
exception when insufficient_privilege then raise notice 'ok  anon cannot read throttle table';
end $$;
do $$ begin
  perform 1 from public.airvalet_sms_messages limit 1;
  raise exception 'FAIL: anon can read SMS log';
exception when insufficient_privilege then raise notice 'ok  anon cannot read SMS log';
end $$;
do $$ begin
  perform public.airvalet_sms_claim('anon', null, null, '+13055550101', 'X', null, null, null, null, 'mock', '00000000-0000-0000-0000-0000000000a1');
  raise exception 'FAIL: anon can execute claim';
exception when insufficient_privilege then raise notice 'ok  anon cannot execute claim';
end $$;
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
select pg_temp.check((select count(*) from public.airvalet_sms_messages) > 0, 'ADMIN can read SMS log');
do $$ begin
  insert into public.airvalet_sms_messages (direction, phone_e164, message_type, provider, status, idempotency_key)
  values ('outbound', '+13055550101', 'X', 'mock', 'delivered', 'forged');
  raise exception 'FAIL: authenticated can insert SMS rows';
exception when insufficient_privilege then raise notice 'ok  authenticated cannot insert (no forged rows)';
end $$;
do $$ begin
  update public.airvalet_sms_messages set status = 'delivered';
  raise exception 'FAIL: authenticated can update SMS rows';
exception when insufficient_privilege then raise notice 'ok  authenticated cannot update';
end $$;
do $$ begin
  perform public.airvalet_sms_apply_status('SM_TEST_1', 'failed', null, null);
  raise exception 'FAIL: authenticated can execute apply_status';
exception when insufficient_privilege then raise notice 'ok  authenticated cannot fake a status callback';
end $$;
do $$ begin
  perform 1 from public.airvalet_sms_status_events limit 1;
  raise exception 'FAIL: authenticated can read raw status events';
exception when insufficient_privilege then raise notice 'ok  authenticated cannot read raw status events';
end $$;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
select pg_temp.check((select count(*) from public.airvalet_sms_messages) = 0, 'TV_ONLY sees zero SMS rows');
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000ff","role":"authenticated"}';
select pg_temp.check((select count(*) from public.airvalet_sms_messages) = 0, 'user without profile sees zero SMS rows');
reset role;

select pg_temp.check((select bool_and(relrowsecurity) and count(*) = 4 from pg_class where relname in ('airvalet_sms_messages', 'airvalet_sms_status_events', 'airvalet_sms_opt_outs', 'airvalet_sms_consents')), 'RLS enabled on all 4 tables');
select pg_temp.check(not exists (
  select 1 from information_schema.columns
   where table_name like 'airvalet_sms_%' and column_name ~* '(token|secret|password|api_key|auth)'), 'no credential-like columns');

select pg_temp.check(pg_temp.flags_consistent(), 'invariant holds at the end of the whole suite');
\echo ALL_SQL_TESTS_PASSED
rollback;
