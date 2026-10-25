-- LOCAL ONLY deep tests (check-in, companion phone, Digital Pass statuses,
-- link lifecycle, privacy, request brake). ONE transaction, rolled back.
-- Run: docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres < tests/portal/sql_deep_tests.sql
-- Needs the local test logins (localipad / localtv). A failed check raises 'FAIL: …'.
\set ON_ERROR_STOP 1
begin;

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.note(label text, val text) returns void language plpgsql as $$
begin raise notice 'obs %: %', label, val; end $$;
create function pg_temp.act(u text) returns void language plpgsql as $$
declare v_id uuid;
begin
  reset role;
  if u is null then perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; return; end if;
  select id into v_id from public.user_profiles where username = u;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', u || '@airvalet.local')::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.errs(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.pv(t text) returns jsonb language sql as $$ select public.airvalet_portal_view(t, 'deep-' || md5(random()::text)) $$;
create function pg_temp.st(t text) returns text language sql as $$ select pg_temp.pv(t) #>> '{pass,status}' $$;
create function pg_temp.d(n int) returns text language sql as $$ select to_char((now() at time zone 'America/New_York')::date + n, 'FMMM/FMDD/YYYY') $$;
create function pg_temp.today_mmdd() returns text language sql as $$ select to_char((now() at time zone 'America/New_York')::date, 'MMDD') $$;
create function pg_temp.mint(pid bigint) returns text language plpgsql as $$
begin
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  select p.id, coalesce(public.airvalet_sms_normalize_phone(p.phone), '+13050000000'),
         (select d.id from public.airvalet_sms_devices d where d.label = 'Deep Test iPad'), gen_random_uuid()
    from public.passengers p where p.id = pid
  on conflict do nothing;
  return public.airvalet_pass_mint(pid);
end $$;

-- ── Fixtures ─────────────────────────────────────────────────────────────
insert into public.airvalet_sms_devices (key_hash, label, status, decided_at)
values (public.airvalet_sms_device_key_hash('deep_device_key_ddddddddddddddddddddddddddddddddddddddd'), 'Deep Test iPad', 'approved', now());
update public.airvalet_portal_settings set portal_enabled = true, requests_enabled = true, chat_enabled = true;
delete from public.airvalet_pass_rate;

-- ── A. CHECK-IN ──────────────────────────────────────────────────────────
-- A1 client_key dedupe
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, client_key)
values (931001, 'deep', now(), 'KEY ONE', '3055550701', pg_temp.today_mmdd() || '-901', 'PENDING', 'ck_deep_000000000000001');
select pg_temp.check(pg_temp.errs($q$insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, client_key)
  values (931002, 'deep', now(), 'KEY ONE', '3055550701', '$q$ || pg_temp.today_mmdd() || $q$-901', 'PENDING', 'ck_deep_000000000000001')$q$),
  'A1 same client_key twice → second insert refused');
select pg_temp.check((select count(*) from public.passengers where client_key = 'ck_deep_000000000000001') = 1, 'A1 exactly one row for the client key');
select pg_temp.check(not pg_temp.errs($q$insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, client_key)
  values (931003, 'deep', now(), 'KEY TWO', '3055550702', 'X-DEEP-3', 'PENDING', null)$q$), 'A1 null client_key never collides');
select pg_temp.check(not pg_temp.errs($q$insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, client_key)
  values (931004, 'deep', now(), 'KEY THREE', '3055550703', 'X-DEEP-4', 'PENDING', null)$q$), 'A1 two null client_keys allowed');

-- A2 duplicate name / duplicate phone (two passengers) allowed, distinct tickets
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, ret, loc, status, return_operator)
values (931010, 'deep', now(), 'JOHN DOE', '(305) 555-0710', pg_temp.today_mmdd() || '-910', pg_temp.d(3), 'HANGAR 18', 'PENDING', 'MAKERS'),
       (931011, 'deep', now(), 'JOHN DOE', '305-555-0710',   pg_temp.today_mmdd() || '-910', pg_temp.d(3), 'HANGAR 18', 'PENDING', 'MAKERS');
select pg_temp.check((select count(*) from public.passengers where id in (931010, 931011)) = 2, 'A2 same name + same phone → two passengers saved');
select pg_temp.check((select count(distinct ticket) from public.passengers where id in (931010, 931011)) = 2, 'A2 typed same ticket → second renumbered');
select pg_temp.check((select ticket from public.passengers where id = 931011) = pg_temp.today_mmdd() || '-911', 'A2 renumbered to next free number');

-- A3 Ascend A- prefix shares the sequence
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, return_operator)
values (931012, 'deep', now(), 'ASC ONE', '3055550712', 'A-' || pg_temp.today_mmdd() || '-911', 'PENDING', 'ASCEND');
select pg_temp.check((select ticket from public.passengers where id = 931012) = 'A-' || pg_temp.today_mmdd() || '-912', 'A3 A-<today>-911 taken by Makers → A-…-912 (shared sequence, prefix kept)');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, return_operator)
values (931013, 'deep', now(), 'MK ONE', '3055550713', pg_temp.today_mmdd() || '-912', 'PENDING', 'MAKERS');
select pg_temp.check((select ticket from public.passengers where id = 931013) = pg_temp.today_mmdd() || '-913', 'A3 Makers N taken by Ascend → next number');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status)
values (931014, 'deep', now(), 'SPACES', '3055550714', '  ' || pg_temp.today_mmdd() || '-913  ', 'PENDING');
select pg_temp.check((select ticket from public.passengers where id = 931014) = pg_temp.today_mmdd() || '-914', 'A3 padded duplicate ticket trimmed + renumbered');

-- A4 NO DATE path
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, ret, loc, status, return_operator)
values (931020, 'deep', now(), 'NODATE PAX', '3055550720', pg_temp.today_mmdd() || '-920', '', 'HANGAR 18', 'NO DATE', 'MAKERS');
select set_config('t.nd', pg_temp.mint(931020), true);
select pg_temp.check(current_setting('t.nd') ~ '^[A-Za-z0-9]{17}$', 'A4 NO DATE ticket gets a pass link');
select pg_temp.check(pg_temp.pv(current_setting('t.nd')) #>> '{pass,status}' = 'PARKED', 'A4 NO DATE → Parked');
select pg_temp.check(pg_temp.pv(current_setting('t.nd')) #> '{pass,return_date}' = 'null'::jsonb, 'A4 NO DATE → no return date shown');
select pg_temp.check(pg_temp.pv(current_setting('t.nd')) #>> '{pass,car_wash}' = 'CONTACT', 'A4 NO DATE → car wash: contact the team');
select pg_temp.check((pg_temp.pv(current_setting('t.nd')) #>> '{pass,requests_enabled}')::boolean, 'A4 NO DATE → passenger may request a return date');
select pg_temp.check(public.airvalet_portal_request(current_setting('t.nd'), 'deep-nd', 'RETURN_CHANGE', 'NEW_DATE_TIME',
  (now() at time zone 'America/New_York')::date + 4, '10:00', null, null, 'ck_deep_nodate_00000001') ->> 'result' = 'OK', 'A4 NO DATE return request accepted');

-- ── B. Companion phone (two passengers, one phone) ───────────────────────
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, ret, loc, status, return_operator)
values (931030, 'deep', now(), 'ANNA LEE',  '(305) 555-0730', 'X-DEEP-30', pg_temp.d(2), 'HANGAR 18', 'PENDING', 'MAKERS'),
       (931031, 'deep', now(), 'BRUCE LEE', '3055550730',     'X-DEEP-31', pg_temp.d(2), 'HANGAR 16', 'PENDING', 'MAKERS');
create temp table ib1 as select * from public.airvalet_sms_record_inbound('SMdeep00000000000000000000000001', '+13055550730', 'Landing at 6', 'MG0123456789abcdef0123456789abcdef', null);
select pg_temp.check((select inserted and passenger_id is null and match_method = 'ambiguous' from ib1), 'B1 companion phone, no recent text → ambiguous (no passenger guessed)');
select pg_temp.check((select match_candidates @> '[931030, 931031]'::jsonb from public.airvalet_sms_messages where id = (select message_id from ib1)), 'B1 both passengers kept as candidates');
select set_config('t.ib1', (select message_id::text from ib1), true);
select pg_temp.act('localipad');
select pg_temp.check(exists (select 1 from public.airvalet_sms_review_queue where id = current_setting('t.ib1')::uuid), 'B1 message is in the staff review queue');
select pg_temp.check(pg_temp.errs($q$select public.airvalet_sms_assign_inbound(current_setting('t.ib1')::uuid, 931001)$q$), 'B1 cannot assign to a passenger with another phone');
select public.airvalet_sms_assign_inbound(current_setting('t.ib1')::uuid, 931031);
select pg_temp.check(not exists (select 1 from public.airvalet_sms_review_queue where id = current_setting('t.ib1')::uuid), 'B1 staff assigns → leaves the review queue');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$select public.airvalet_sms_assign_inbound(current_setting('t.ib1')::uuid, 931030)$q$), 'B1 TV_ONLY cannot assign');
reset role;
select pg_temp.check((select passenger_id = 931031 and match_method = 'manual' from public.airvalet_sms_messages where id = (select message_id from ib1)), 'B1 assignment stored as manual');
-- B2 after a welcome text went to the companion (most recent outbound) the reply is attributed to it automatically
insert into public.airvalet_sms_messages (direction, passenger_id, phone_e164, message_type, provider, status, idempotency_key, body, created_at)
values ('outbound', 931030, '+13055550730', 'CHECK_IN', 'mock', 'delivered', 'deep:b2:a', 'welcome', now() - interval '5 minutes');
create temp table ib2 as select * from public.airvalet_sms_record_inbound('SMdeep00000000000000000000000002', '+13055550730', 'Thanks', 'MG0123456789abcdef0123456789abcdef', null);
select pg_temp.check((select passenger_id = 931030 and match_method = 'last_outbound' from ib2), 'B2 companion phone with a text < 72 h → attributed to the last texted passenger (not the review queue)');
select pg_temp.note('B2 behaviour', 'a reply from a shared phone goes to whichever passenger was texted last; candidates kept = ' ||
  (select match_candidates::text from public.airvalet_sms_messages where id = (select message_id from ib2)));
-- B3 chat isolation on a shared phone
select set_config('t.a', pg_temp.mint(931030), true);
select set_config('t.b', pg_temp.mint(931031), true);
select pg_temp.check(public.airvalet_portal_send_message(current_setting('t.a'), 'deep-a', 'Anna private note', 'ck_deep_chat_a_00000001') ->> 'result' = 'OK', 'B3 passenger A sends a chat message');
select pg_temp.check(position('Anna private note' in public.airvalet_portal_messages(current_setting('t.b'), 'deep-b')::text) = 0, 'B3 passenger B (same phone) never sees A''s chat');
select pg_temp.check(position('Thanks' in public.airvalet_portal_messages(current_setting('t.b'), 'deep-b')::text) = 0, 'B3 B does not see the SMS attributed to A');
select pg_temp.check(position('Landing at 6' in public.airvalet_portal_messages(current_setting('t.a'), 'deep-a')::text) = 0, 'B3 A does not see the SMS assigned to B');

-- ── C. Digital Pass statuses ─────────────────────────────────────────────
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, ret, loc, car, color, status, return_operator) values
  (931040, 'deep', now(), 'PARK ER',  '3055550740', 'X-DEEP-40', pg_temp.d(3), 'HANGAR 18', 'BMW X5', 'Black', 'PENDING', 'MAKERS'),
  (931041, 'deep', now(), 'FLY ER',   '3055550741', 'X-DEEP-41', pg_temp.d(3), 'HANGAR 18', 'BMW X5', 'Black', 'PENDING', 'MAKERS'),
  (931042, 'deep', now(), 'HANG ER',  '3055550742', 'X-DEEP-42', pg_temp.d(0), 'HANGAR 19', 'BMW X5', 'Black', 'PENDING', 'MAKERS'),
  (931043, 'deep', now(), 'ASC ER',   '3055550743', 'A-DEEP-43', pg_temp.d(0), 'HANGAR 19', 'BMW X5', 'Black', 'PENDING', 'ASCEND'),
  (931044, 'deep', now(), 'CUST ER',  '3055550744', 'X-DEEP-44', pg_temp.d(0), 'CUSTOMS',   'BMW X5', 'Black', 'PENDING', 'MAKERS'),
  (931045, 'deep', now(), 'ASCDEL ER','3055550745', 'A-DEEP-45', pg_temp.d(0), 'CUSTOMS',   'BMW X5', 'Black', 'PENDING', 'ASCEND');
select set_config('t.p40', pg_temp.mint(931040), true), set_config('t.p41', pg_temp.mint(931041), true), set_config('t.p42', pg_temp.mint(931042), true),
       set_config('t.p43', pg_temp.mint(931043), true), set_config('t.p44', pg_temp.mint(931044), true), set_config('t.p45', pg_temp.mint(931045), true);
select pg_temp.check(pg_temp.st(current_setting('t.p40')) = 'PARKED', 'C1 Makers, Hangar 18, return in 3 days → PARKED');
-- Flying back (pass.js: PARKED + return_flight or arrival_time)
update public.passengers set return_flight = ' n123ab ' where id = 931041;
select pg_temp.check(pg_temp.pv(current_setting('t.p41')) #>> '{pass,return_flight}' = 'N123AB' and pg_temp.st(current_setting('t.p41')) = 'PARKED', 'C2 return_flight set → PARKED + return_flight (portal shows "Flying back")');
update public.passengers set return_flight = null, departure_time = '18:30' where id = 931041;
select pg_temp.check(pg_temp.pv(current_setting('t.p41')) #>> '{pass,arrival_time}' = '18:30', 'C2 departure_time 18:30 → arrival_time (Flying back)');
update public.passengers set departure_time = '6:30 PM' where id = 931041;
select pg_temp.check(pg_temp.pv(current_setting('t.p41')) #> '{pass,arrival_time}' = 'null'::jsonb, 'C2 12-hour text is not exposed as arrival time');
update public.passengers set departure_time = '00:00' where id = 931041;
select pg_temp.note('C2 departure_time 00:00', 'portal arrival_time = ' || coalesce(pg_temp.pv(current_setting('t.p41')) #>> '{pass,arrival_time}', 'null')
  || ' (staff app treats 00:00 as "not set" for the Customs reminder)');
update public.passengers set departure_time = null where id = 931041;
-- READY
insert into public.airvalet_pass_state (passenger_id, ready_at) values (931041, now());
select pg_temp.check(pg_temp.st(current_setting('t.p41')) = 'READY', 'C3 staff Ready (pass_state.ready_at) → READY');
select pg_temp.check(pg_temp.st(current_setting('t.p42')) = 'READY', 'C3 Makers + loc HANGAR 19 on the return day (ET) → READY');
update public.passengers set ret = pg_temp.d(1) where id = 931042;
select pg_temp.check(pg_temp.st(current_setting('t.p42')) = 'PARKED', 'C3 HANGAR 19 but return tomorrow → PARKED');
update public.passengers set ret = pg_temp.d(-1) where id = 931042;
select pg_temp.check(pg_temp.st(current_setting('t.p42')) = 'PARKED', 'C3 HANGAR 19 but return was yesterday → PARKED');
update public.passengers set ret = pg_temp.d(0), loc = ' hangar 19 ' where id = 931042;
select pg_temp.check(pg_temp.st(current_setting('t.p42')) = 'READY', 'C3 loc case/space-insensitive');
select pg_temp.check(pg_temp.st(current_setting('t.p43')) = 'PARKED', 'C3 Ascend return in HANGAR 19 on return day → not READY (Customs not confirmed)');
-- CUSTOMS_CONFIRMED / DELIVERED
update public.passengers set status = 'DELIVERED', delivery_type = 'CUSTOMS', checkout_date = now(), customs_gratuity_sent = false where id = 931044;
select pg_temp.check(pg_temp.st(current_setting('t.p44')) = 'CUSTOMS_CONFIRMED', 'C4 DELIVERED via CUSTOMS + gratuity not sent → CUSTOMS_CONFIRMED (waiting at Customs)');
update public.passengers set customs_gratuity_sent = true where id = 931044;
select pg_temp.check(pg_temp.st(current_setting('t.p44')) = 'DELIVERED', 'C4 gratuity link sent → DELIVERED');
update public.passengers set status = 'DELIVERED', delivery_type = 'NORMAL', checkout_date = now() where id = 931040;
select pg_temp.check(pg_temp.st(current_setting('t.p40')) = 'DELIVERED', 'C4 normal delivery → DELIVERED');
select pg_temp.check((pg_temp.pv(current_setting('t.p40')) #>> '{pass,requests_enabled}')::boolean = false, 'C4 delivered → no requests');
update public.passengers set status = 'DELIVERED', delivery_type = 'CUSTOMS', checkout_date = now() where id = 931045;
select pg_temp.check(pg_temp.st(current_setting('t.p45')) = 'CUSTOMS_CONFIRMED', 'C4 Ascend delivered at Customs → CUSTOMS_CONFIRMED');
select pg_temp.note('C4 Ascend delivered at Customs without "Customs confirmed"', 'pickup = ' || (pg_temp.pv(current_setting('t.p45')) #>> '{pass,pickup}')
  || ' → pass.js shows the Makers-exception line ("reply to our text or call … for your key"), not the Ascend hand-over line');

-- ── D. Link lifecycle ────────────────────────────────────────────────────
select pg_temp.check((select expires_at between now() + interval '6 days 23 hours' and now() + interval '7 days 1 minute'
                        from public.airvalet_pass_links where passenger_id = 931040 and revoked_at is null), 'D1 delivered → link ends 7 days later');
update public.airvalet_pass_links set expires_at = now() - interval '1 second' where passenger_id = 931040 and revoked_at is null;
select pg_temp.check(pg_temp.pv(current_setting('t.p40')) ->> 'state' = 'expired', 'D1 after 7 days → expired');
update public.passengers set status = 'ARCHIVED' where id = 931044;
select pg_temp.check(pg_temp.pv(current_setting('t.p44')) ->> 'state' = 'expired', 'D2 archive → link revoked (expired)');
select pg_temp.check((select revoke_reason from public.airvalet_pass_links where passenger_id = 931044 order by id desc limit 1) = 'archived', 'D2 revoke reason archived');
update public.passengers set phone = '3055550799' where id = 931043;
select pg_temp.check(pg_temp.pv(current_setting('t.p43')) ->> 'state' = 'expired', 'D3 phone change → old link revoked');
select pg_temp.check((select revoke_reason from public.airvalet_pass_links where passenger_id = 931043 order by id desc limit 1) = 'phone_changed', 'D3 revoke reason phone_changed');
update public.passengers set phone = '(305) 555-0742' where id = 931042;  -- same number, new formatting
select pg_temp.note('D3 formatting-only phone edit (3055550742 → (305) 555-0742)', 'link state = ' || (pg_temp.pv(current_setting('t.p42')) ->> 'state'));

-- ── E. Privacy of the portal JSON ────────────────────────────────────────
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, ret, loc, car, color, status, return_operator, obs)
values (931050, 'deep', now(), 'PRIVA CY', '(786) 413-2798', 'Q-7319-46', pg_temp.d(5), 'HANGAR 16', 'VOLVO XC90', 'Gray', 'PENDING', 'MAKERS', 'SECRET OBS NOTE');
select set_config('t.p50', pg_temp.mint(931050), true);
select set_config('t.p50v', pg_temp.pv(current_setting('t.p50'))::text || public.airvalet_portal_messages(current_setting('t.p50'), 'deep-50')::text, true);
select pg_temp.check(position('7319' in current_setting('t.p50v')) = 0, 'E1 no ticket in portal JSON');
select pg_temp.check(position('4132798' in current_setting('t.p50v')) = 0 and position('786' in current_setting('t.p50v')) = 0, 'E1 no phone digits in portal JSON');
select pg_temp.check(position('931050' in current_setting('t.p50v')) = 0, 'E1 no passenger id in portal JSON');
select pg_temp.check(position((select id::text from public.airvalet_pass_links where passenger_id = 931050 and revoked_at is null) in current_setting('t.p50v')) = 0
                     or (select id from public.airvalet_pass_links where passenger_id = 931050 and revoked_at is null) < 10, 'E1 no link id in portal JSON');
select pg_temp.check(position('SECRET OBS' in current_setting('t.p50v')) = 0 and position('PRIVA CY' in current_setting('t.p50v')) = 0, 'E1 no staff notes, no full name');
select pg_temp.check(pg_temp.pv(current_setting('t.p50')) #>> '{pass,first_name}' = 'Priva', 'E1 first name only');

-- ── F. Request brake + invalid token throttle ────────────────────────────
do $$
declare i int; v text; ok_n int := 0; lim boolean := false;
begin
  for i in 1..14 loop
    v := public.airvalet_portal_request(current_setting('t.p50'), 'deep-f-' || i, 'RETURN_CHANGE', 'NEW_DATE_TIME',
           (now() at time zone 'America/New_York')::date + 6, '09:00', null, null, 'ck_deep_brake_' || lpad(i::text, 8, '0')) ->> 'result';
    if v = 'OK' then ok_n := ok_n + 1; elsif v = 'LIMITED' then lim := true; end if;
  end loop;
  perform pg_temp.check(ok_n = 12 and lim, 'F1 per-link request brake: 12 accepted then LIMITED (got ' || ok_n || ' OK)');
end $$;
select pg_temp.check((select count(*) from public.airvalet_pass_requests where passenger_id = 931050 and status = 'PENDING') = 1, 'F1 only one pending return change (older ones superseded)');
select pg_temp.check(public.airvalet_portal_request(current_setting('t.p50'), 'deep-f-dup', 'RETURN_CHANGE', 'NEW_DATE_TIME',
  (now() at time zone 'America/New_York')::date + 6, '09:00', null, null, 'ck_deep_brake_00000001') ->> 'result' = 'OK', 'F1 retry of an already-stored client key still answers OK (idempotent, not limited)');
do $$
declare i int;
begin
  for i in 1..8 loop perform public.airvalet_portal_view('ZZZZZZZZZZZZZZZZ' || i, 'deep-brute'); end loop;
  perform pg_temp.check(public.airvalet_portal_view(current_setting('t.p41'), 'deep-brute') ->> 'state' = 'limited', 'F2 8 bad tokens from one client → even a valid token is limited');
  perform pg_temp.check(public.airvalet_portal_view(current_setting('t.p41'), 'deep-other') ->> 'state' = 'ok', 'F2 another client is not affected');
end $$;

rollback;
