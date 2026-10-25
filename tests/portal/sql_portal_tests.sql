-- LOCAL DB tests for 20261026_airvalet_passenger_portal.sql.
-- Run: tests/portal/run_portal_tests.sh (local stack only). Everything runs in
-- ONE transaction that is rolled back. A failed check raises 'FAIL: …'.
-- Needs the local test logins (localadmin / localipad / localiphone / localtv).

\set ON_ERROR_STOP 1
begin;

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;

-- Act as a test login (JWT claims as PostgREST would set them).
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
create function pg_temp.pv(t text) returns jsonb language sql as $$ select public.airvalet_portal_view(t, 'test-' || md5(random()::text)) $$;
create function pg_temp.req(t text, kind text, reason text, d date, tm time, carrier text, note text, ck text) returns jsonb language sql as $$
  select public.airvalet_portal_request(t, 'test-' || md5(random()::text), kind, reason, d, tm, carrier, note, ck) $$;
create function pg_temp.mint(pid bigint) returns text language plpgsql as $$
begin
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  select p.id, coalesce(public.airvalet_sms_normalize_phone(p.phone), '+13050000000'),
         (select d.id from public.airvalet_sms_devices d where d.label = 'Portal Test iPad'), gen_random_uuid()
    from public.passengers p where p.id = pid;
  return public.airvalet_pass_mint(pid);
end $$;
create function pg_temp.d(n int) returns text language sql as $$ select to_char((now() at time zone 'America/New_York')::date + n, 'FMMM/FMDD/YYYY') $$;

-- ── Fixtures ─────────────────────────────────────────────────────────────
insert into public.airvalet_sms_devices (key_hash, label, status)
values (public.airvalet_sms_device_key_hash('portal_test_device_key_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'), 'Portal Test iPad', 'approved'),
       (public.airvalet_sms_device_key_hash('portal_pending_device_key_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'), 'Portal Pending', 'pending');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, ret, car, color, loc, status, return_operator) values
  (900001, 'x', now(), 'JOHN SMITH',   '(305) 555-0142', '1025-91', pg_temp.d(5), 'MERCEDES GLE', 'Black', 'HANGAR 19', 'PENDING', 'MAKERS'),
  (900002, 'x', now(), 'MARY JONES',   '(305) 555-0143', '1025-92', pg_temp.d(1), 'AUDI Q7',      'White', 'HANGAR 18', 'PENDING', 'MAKERS'),
  (900003, 'x', now(), 'RAFAEL ALVAREZ','(305) 555-0144','A-1025-93', pg_temp.d(3), 'RANGE ROVER', 'Gray',  'HANGAR 16', 'PENDING', 'ASCEND'),
  (900004, 'x', now(), 'DIANA PARK',   '(305) 555-0145', '1025-94', pg_temp.d(0), 'TESLA MODEL Y','Blue',  'HANGAR 19', 'PENDING', 'MAKERS'),
  (900005, 'x', now(), 'ARCHIE GONE',  '(305) 555-0146', '1025-95', pg_temp.d(2), 'BMW X5',       'White', 'HANGAR 7',  'PENDING', 'MAKERS'),
  (900006, 'x', now(), 'OTHER PERSON', '(305) 555-0147', '1025-96', pg_temp.d(9), 'FORD F-150',   'Red',   'HH',        'PENDING', 'MAKERS');
select set_config('t.t1', pg_temp.mint(900001), true), set_config('t.t2', pg_temp.mint(900002), true),
       set_config('t.t3', pg_temp.mint(900003), true), set_config('t.t4', pg_temp.mint(900004), true),
       set_config('t.t5', pg_temp.mint(900005), true), set_config('t.t6', pg_temp.mint(900006), true);
insert into public.airvalet_super_admins (user_id) select id from public.user_profiles where username = 'localadmin' on conflict do nothing;

-- ── 1. Dark launch ───────────────────────────────────────────────────────
update public.airvalet_portal_settings set portal_enabled = false, requests_enabled = false, push_enabled = false where id;
select pg_temp.check(pg_temp.pv(current_setting('t.t1')) = '{"state":"expired"}', 'portal OFF: a valid link looks exactly like an unknown one');
update public.airvalet_portal_settings set portal_enabled = true;

-- ── 2. View: only this passenger, never ticket/phone/key ─────────────────
select set_config('t.v1', pg_temp.pv(current_setting('t.t1'))::text, true);
select pg_temp.check((current_setting('t.v1')::jsonb ->> 'state') = 'ok', 'view ok');
select pg_temp.check((select array_agg(k order by k) from jsonb_object_keys(current_setting('t.v1')::jsonb -> 'pass') k)
  = array['arrival_time','car_wash','car_wash_lead_hours','chat_enabled','contacts','first_name','gratuity_url','lockbox','pending_return','pickup','ready_by_staff','requests_enabled',
          'return_date','return_flight','return_time','status','terms_published','valet_hours','vehicle'], 'view: exact key set (no ticket, phone, ids)');
select pg_temp.check(position('1025-91' in current_setting('t.v1')) = 0 and position('555' in current_setting('t.v1')) = 0
                     and position('900001' in current_setting('t.v1')) = 0, 'view: ticket, phone digits, passenger id absent from the whole JSON');
select pg_temp.check(current_setting('t.v1')::jsonb #>> '{pass,first_name}' = 'John', 'first name only, title case');
select pg_temp.check(current_setting('t.v1')::jsonb #>> '{pass,vehicle}' = 'Black MERCEDES GLE', 'vehicle = color + car');
select pg_temp.check(current_setting('t.v1')::jsonb #>> '{pass,status}' = 'PARKED' and current_setting('t.v1')::jsonb #>> '{pass,pickup}' = 'HANGAR_19', 'Makers: parked, Hangar 19');
select pg_temp.check(current_setting('t.v1')::jsonb #> '{pass,return_time}' = 'null'::jsonb, 'P1: no return time invented');
select pg_temp.check(current_setting('t.v1')::jsonb #>> '{pass,car_wash}' = 'REQUEST', 'car wash requestable at 5 days');
select pg_temp.check(not (current_setting('t.v1')::jsonb #> '{pass,contacts}') ? 'reservations_phone', 'P7: unverified reservations number not shown');
select pg_temp.check(current_setting('t.v1')::jsonb #>> '{pass,gratuity_url}' like 'https://buy.stripe.com/%', 'P8: Matt Solutions Payment Link');
select pg_temp.check(current_setting('t.v1')::jsonb #>> '{pass,terms_published}' = 'false', 'P9: terms hidden');
select pg_temp.check((select open_count from public.airvalet_pass_links where passenger_id = 900001 and revoked_at is null) = 1, 'opening counted');
select pg_temp.check(pg_temp.pv(current_setting('t.t2')) #>> '{pass,car_wash}' = 'CONTACT', 'car wash < 48 h → contact the team');

-- ── 3. Bad links: one answer for all ─────────────────────────────────────
select pg_temp.check(pg_temp.pv('short') = '{"state":"expired"}', 'malformed → expired');
select pg_temp.check(pg_temp.pv('AAAAAAAAAAAAAAAAA') = '{"state":"expired"}', 'unknown → expired');
update public.passengers set status = 'ARCHIVED' where id = 900005;
select pg_temp.check(pg_temp.pv(current_setting('t.t5')) = '{"state":"expired"}', 'archived → expired (link revoked)');
select pg_temp.check((select revoke_reason from public.airvalet_pass_links where passenger_id = 900005 order by id desc limit 1) = 'archived', 'archive revokes the link');
select pg_temp.check((select count(*) from generate_series(1, 8) g where (public.airvalet_portal_view('BBBBBBBBBBBBBBBBB', 'brute-1') ->> 'state') = 'expired') = 8, '8 failed guesses answered expired');
select pg_temp.check(public.airvalet_portal_view(current_setting('t.t1'), 'brute-1') ->> 'state' = 'limited', 'after 8 failures the client is limited, even with a valid token');

-- ── 4. Staff-only state: Ready / Customs / Lockbox ───────────────────────
select pg_temp.act(null);
select pg_temp.check(pg_temp.errs($$select public.airvalet_pass_state_set(900001, 'ready', '{"on":true}')$$), 'anon cannot set Ready');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($$select public.airvalet_pass_state_set(900001, 'ready', '{"on":true}')$$), 'TV_ONLY cannot set Ready');
select pg_temp.check(pg_temp.errs($$select * from public.airvalet_pass_state$$), 'no direct table access to pass state');
select pg_temp.act('localiphone');
select pg_temp.check((public.airvalet_pass_state_set(900001, 'ready', '{"on":true}') ->> 'ready')::boolean, 'IPHONE_OPS (staff) sets Ready');
reset role;
select pg_temp.check(pg_temp.pv(current_setting('t.t1')) #>> '{pass,status}' = 'READY', 'portal shows Ready');
select pg_temp.check(pg_temp.pv(current_setting('t.t1')) #>> '{pass,car_wash}' = 'NONE', 'no car wash once Ready');
select pg_temp.check(pg_temp.pv(current_setting('t.t3')) #>> '{pass,pickup}' = 'TO_BE_CONFIRMED', 'P3: Ascend shows no Customs until the team confirms');
select pg_temp.act('localipad');
select public.airvalet_pass_state_set(900003, 'customs_confirmed', '{"on":true}');
reset role;
select pg_temp.check(pg_temp.pv(current_setting('t.t3')) #>> '{pass,pickup}' = 'CUSTOMS_ASCEND' and pg_temp.pv(current_setting('t.t3')) #>> '{pass,status}' = 'PARKED', 'Ascend Customs confirmed, still Parked');
select pg_temp.act('localipad');
select public.airvalet_pass_state_set(900003, 'ready', '{"on":true}');
reset role;
select pg_temp.check(pg_temp.pv(current_setting('t.t3')) #>> '{pass,status}' = 'CUSTOMS_CONFIRMED', 'Ascend + Ready → Customs Confirmed');
update public.passengers set delivery_at_customs = true where id = 900006;
select pg_temp.check(pg_temp.pv(current_setting('t.t6')) #>> '{pass,pickup}' = 'CUSTOMS_EXCEPTION', 'Makers approved exception = Customs (staff decision)');
update public.passengers set delivery_at_customs = false where id = 900006;
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.errs($$select public.airvalet_pass_state_set(900004, 'lockbox', '{"on":true,"code":"bad code!","reveal_on":"2026-10-26"}')$$), 'lockbox code validated');
select public.airvalet_pass_state_set(900004, 'lockbox', jsonb_build_object('on', true, 'code', '4821', 'reveal_on', (now() at time zone 'America/New_York')::date + 1));
reset role;
select pg_temp.check(pg_temp.pv(current_setting('t.t4')) #> '{pass,lockbox,code}' = 'null'::jsonb, 'P5: code hidden before the reveal day');
update public.airvalet_pass_state set lockbox_reveal_on = (now() at time zone 'America/New_York')::date where passenger_id = 900004;
select pg_temp.check(pg_temp.pv(current_setting('t.t4')) #>> '{pass,lockbox,code}' = '4821', 'code shown on the reveal day');
select pg_temp.check(not exists (select 1 from public.activity_log where passenger_id = 900004 and detail like '%4821%'), 'lockbox code never written to the activity log');
select pg_temp.check(pg_temp.pv(current_setting('t.t2')) #> '{pass,lockbox}' = 'null'::jsonb, 'no lockbox without authorization');

-- ── 5. Requests ──────────────────────────────────────────────────────────
select pg_temp.check(pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'NEW_DATE_TIME', current_date + 3, null, null, null, 'ck_aaaaaaaaaaaaaaaaaaaa') ->> 'result' = 'UNAVAILABLE', 'requests OFF → unavailable');
update public.airvalet_portal_settings set requests_enabled = true;
select pg_temp.check(pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'NEW_DATE_TIME', current_date - 2, null, null, null, 'ck_bbbbbbbbbbbbbbbbbbbb') ->> 'result' = 'INVALID', 'past date refused');
select pg_temp.check(pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'OTHER_CARRIER', current_date + 3, null, null, null, 'ck_cccccccccccccccccccc') ->> 'result' = 'INVALID', 'other carrier needs the carrier name');
select pg_temp.check(pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'BOGUS', current_date + 3, null, null, null, 'ck_dddddddddddddddddddd') ->> 'result' = 'INVALID', 'unknown reason refused');
select pg_temp.check(pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'NEW_DATE_TIME', current_date + 3, null, null, null, 'short') ->> 'result' = 'INVALID', 'client key required');
select set_config('t.r1', pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'FLIGHT_CHANGED', (now() at time zone 'America/New_York')::date + 4, '18:00', null, 'Weather delay in Nassau', 'ck_req1_xxxxxxxxxxxxxxx')::text, true);
select pg_temp.check(current_setting('t.r1')::jsonb ->> 'result' = 'OK', 'return change request accepted');
select pg_temp.check(pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'FLIGHT_CHANGED', current_date + 9, null, null, null, 'ck_req1_xxxxxxxxxxxxxxx') ->> 'request_id'
                     = current_setting('t.r1')::jsonb ->> 'request_id', 'same client key (double tap / retry) → same request, nothing new');
select pg_temp.check((select count(*) from public.airvalet_pass_requests where passenger_id = 900002) = 1, 'still exactly one request');
select pg_temp.check((select ret from public.passengers where id = 900002) = pg_temp.d(1) and (select ret_time from public.passengers where id = 900002) is null,
                     'request does NOT change the operational return');
select pg_temp.check(pg_temp.pv(current_setting('t.t2')) #>> '{pass,pending_return,time}' = '18:00', 'portal shows the pending change');
select set_config('t.r2', pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'NEW_DATE_TIME', (now() at time zone 'America/New_York')::date + 6, null, null, null, 'ck_req2_xxxxxxxxxxxxxxx')::text, true);
select pg_temp.check((select status from public.airvalet_pass_requests where id = (current_setting('t.r1')::jsonb ->> 'request_id')::uuid) = 'SUPERSEDED'
                     and (select count(*) from public.airvalet_pass_requests where passenger_id = 900002 and status = 'PENDING') = 1, 'newer request supersedes (one pending, history kept)');
select pg_temp.check(pg_temp.req(current_setting('t.t1'), 'CAR_WASH', null, null, null, null, null, 'ck_wash_ready_xxxxxxxx') ->> 'result' = 'NOT_AVAILABLE', 'no car wash once Ready');
select pg_temp.check(pg_temp.req(current_setting('t.t2'), 'CAR_WASH', null, null, null, null, null, 'ck_wash_soon_xxxxxxxxx') ->> 'result' = 'CONTACT_TEAM', '48 h rule: < 48 h → contact team, no request');
select pg_temp.check(pg_temp.req(current_setting('t.t6'), 'CAR_WASH', null, null, null, null, null, 'ck_wash_ok_xxxxxxxxxxx') ->> 'result' = 'OK', '≥ 48 h → car wash request');
select pg_temp.check((select carwash_status from public.passengers where id = 900006) is null, 'car wash request alone changes nothing operational');
select pg_temp.check((select count(*) from public.airvalet_alert_events e join public.airvalet_pass_requests q on q.id = e.ref_id where e.kind = 'PASS_REQUEST' and q.passenger_id in (900002, 900006)) = 3, 'each request emits one alert signal');

-- ── 6. Decide ────────────────────────────────────────────────────────────
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs(format($$select public.airvalet_pass_request_decide(%L, 'APPROVE')$$, current_setting('t.r2')::jsonb ->> 'request_id')), 'TV_ONLY cannot decide');
select pg_temp.check(pg_temp.errs($$select * from public.airvalet_pass_requests_list()$$), 'TV_ONLY cannot list requests');
select pg_temp.check((select count(*) from public.airvalet_pass_requests) = 0, 'TV_ONLY sees no request rows (RLS)');
select pg_temp.act(null);
select pg_temp.check(pg_temp.errs($$select * from public.airvalet_pass_requests$$), 'anon has no access to requests');
select pg_temp.act('localiphone');
select pg_temp.check((select count(*) from public.airvalet_pass_requests_list() where status = 'PENDING') >= 2, 'staff list shows pending requests');
select pg_temp.check(public.airvalet_pass_request_decide((current_setting('t.r2')::jsonb ->> 'request_id')::uuid, 'APPROVE', 'Confirmed by phone') ->> 'result' = 'APPROVED', 'staff approves');
reset role;
select pg_temp.check((select ret from public.passengers where id = 900002) = pg_temp.d(6), 'approval updates the return date');
select pg_temp.check(exists (select 1 from public.passenger_return_date_changes where passenger_id = 900002 and new_return_date = pg_temp.d(6)
                     and comment like 'Passenger request (new date time)%' and changed_by = 'localiphone@airvalet.local'), 'history row via the existing atomic RPC');
select pg_temp.check(exists (select 1 from public.activity_log where passenger_id = 900002 and action = 'RETURN DATE'), 'activity log row');
select pg_temp.act('localiphone');
select pg_temp.check(public.airvalet_pass_request_decide((current_setting('t.r2')::jsonb ->> 'request_id')::uuid, 'APPROVE') ->> 'result' = 'ALREADY_DECIDED', 'second approval is a no-op');
reset role;
-- time-only change + STALE
select set_config('t.r3', pg_temp.req(current_setting('t.t2'), 'RETURN_CHANGE', 'AFTER_HOURS', (now() at time zone 'America/New_York')::date + 6, '21:30', null, 'Landing late', 'ck_req3_xxxxxxxxxxxxxxx')::text, true);
select pg_temp.act('localipad');
select public.change_passenger_return_date_with_reason(900002, pg_temp.d(7), 'Staff edit meanwhile', false);
select pg_temp.check(public.airvalet_pass_request_decide((current_setting('t.r3')::jsonb ->> 'request_id')::uuid, 'APPROVE') ->> 'result' = 'STALE', 'official return changed since the request → STALE');
select pg_temp.check(public.airvalet_pass_request_decide((current_setting('t.r3')::jsonb ->> 'request_id')::uuid, 'APPROVE', null, true) ->> 'result' = 'APPROVED', 'approve after review (force)');
reset role;
select pg_temp.check((select ret from public.passengers where id = 900002) = pg_temp.d(6) and (select to_char(ret_time, 'HH24:MI') from public.passengers where id = 900002) = '21:30', 'date + optional time applied');
select pg_temp.check(exists (select 1 from public.activity_log where passenger_id = 900002 and action = 'RETURN TIME' and new_value = '21:30'), 'time change logged');
select pg_temp.check((select return_operator from public.passengers where id = 900002) = 'MAKERS' and not (select delivery_at_customs from public.passengers where id = 900002),
                     'after-hours approval never touches Customs / return operator');
-- other carrier: approval never changes return_operator
select set_config('t.r4', pg_temp.req(current_setting('t.t6'), 'RETURN_CHANGE', 'OTHER_CARRIER', (now() at time zone 'America/New_York')::date + 10, null, 'JetBlue', null, 'ck_req4_xxxxxxxxxxxxxxx')::text, true);
select pg_temp.act('localipad');
select public.airvalet_pass_request_decide((current_setting('t.r4')::jsonb ->> 'request_id')::uuid, 'APPROVE');
reset role;
select pg_temp.check((select return_operator from public.passengers where id = 900006) = 'MAKERS', 'other-carrier approval leaves Returning with to staff');
-- car wash approval = existing Send Price
select pg_temp.act('localipad');
select public.airvalet_pass_request_decide((select id from public.airvalet_pass_requests where passenger_id = 900006 and kind = 'CAR_WASH'), 'APPROVE');
reset role;
select pg_temp.check((select carwash_status from public.passengers where id = 900006) = 'SEND_PRICE', 'car wash approval → existing SEND_PRICE status');
select pg_temp.check(pg_temp.pv(current_setting('t.t6')) #>> '{pass,car_wash}' = 'PRICE_PENDING', 'portal: price pending');
-- decline
select set_config('t.r5', pg_temp.req(current_setting('t.t6'), 'RETURN_CHANGE', 'NEW_DATE_TIME', (now() at time zone 'America/New_York')::date + 20, null, null, null, 'ck_req5_xxxxxxxxxxxxxxx')::text, true);
select pg_temp.act('localipad');
select public.airvalet_pass_request_decide((current_setting('t.r5')::jsonb ->> 'request_id')::uuid, 'DECLINE', 'Called passenger');
reset role;
select pg_temp.check((select status from public.airvalet_pass_requests where id = (current_setting('t.r5')::jsonb ->> 'request_id')::uuid) = 'DECLINED'
                     and (select ret from public.passengers where id = 900006) = pg_temp.d(10), 'decline leaves the record as it was');

-- ── 7. Delivered ─────────────────────────────────────────────────────────
update public.passengers set status = 'DELIVERED', checkout_date = now() where id = 900004;
select pg_temp.check(pg_temp.pv(current_setting('t.t4')) #>> '{pass,status}' = 'DELIVERED' and pg_temp.pv(current_setting('t.t4')) #>> '{pass,requests_enabled}' = 'false'
                     and pg_temp.pv(current_setting('t.t4')) #> '{pass,lockbox}' = 'null'::jsonb, 'delivered: read-only, lockbox gone');
select pg_temp.check(pg_temp.req(current_setting('t.t4'), 'RETURN_CHANGE', 'NEW_DATE_TIME', current_date + 2, null, null, null, 'ck_req6_xxxxxxxxxxxxxxx') ->> 'result' = 'NOT_IN_CUSTODY', 'no requests after delivery');
update public.airvalet_pass_links set expires_at = now() - interval '1 minute' where passenger_id = 900004 and revoked_at is null;
select pg_temp.check(pg_temp.pv(current_setting('t.t4')) = '{"state":"expired"}', 'link expires 3 h after delivery');

-- ── 8. Settings: ADMIN only (never IPHONE_OPS / IPAD_OPS / MANAGER) ──────
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.errs($$select public.airvalet_portal_settings_set('{"portal_enabled":false}')$$), 'IPHONE_OPS cannot change settings');
select pg_temp.check(pg_temp.errs($$select public.airvalet_sms_device_decide((select id from public.airvalet_sms_devices where label = 'Portal Pending'), 'approved')$$), 'IPHONE_OPS cannot approve devices');
select pg_temp.check((public.airvalet_portal_settings_get() ->> 'portal_enabled')::boolean, 'staff can read settings');
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.errs($$select public.airvalet_portal_settings_set('{"portal_enabled":false}')$$), 'IPAD_OPS cannot change settings');
select pg_temp.act('localmanager');
select pg_temp.check(pg_temp.errs($$select public.airvalet_portal_settings_set('{"portal_enabled":false}')$$), 'MANAGER cannot change settings');
select pg_temp.act('localadmin');
select pg_temp.check(pg_temp.errs($$select public.airvalet_portal_settings_set('{"evil":1}')$$), 'unknown setting refused');
select pg_temp.check(pg_temp.errs($$select public.airvalet_portal_settings_set('{"gratuity_url":"https://evil.example.com/pay"}')$$), 'gratuity must be a Stripe Payment Link');
select pg_temp.check(public.airvalet_portal_settings_set('{"reservations_phone":"(954) 000-0000"}') ->> 'reservations_phone' = '(954) 000-0000', 'ADMIN changes settings');
reset role;
update public.airvalet_portal_settings set reservations_phone = null;

-- ── 9. Super Admin SMS alerts ────────────────────────────────────────────
select pg_temp.act('localmanager');
select pg_temp.check(pg_temp.errs($$select public.airvalet_admin_alerts_get()$$), 'non-admin cannot read admin alerts');
select pg_temp.act('localadmin');
select pg_temp.check((public.airvalet_admin_alerts_get() ->> 'enabled')::boolean = false, 'super admin reads alerts (OFF by default)');
select pg_temp.check(pg_temp.errs($$select public.airvalet_admin_alerts_set('{"enabled":true}')$$), 'cannot enable before verifying the phone');
reset role;
select pg_temp.check(pg_temp.errs($$select public.airvalet_admin_alerts_start_verify((select id from public.user_profiles where username = 'localipad'), '+17545550101')$$), 'verification only for a super admin');
select set_config('t.code', public.airvalet_admin_alerts_start_verify((select id from public.user_profiles where username = 'localadmin'), '+17545550101'), true);
select pg_temp.act('localadmin');
select pg_temp.check(public.airvalet_admin_alerts_confirm('000000x') ->> 'result' = 'WRONG_CODE', 'wrong code refused');
select pg_temp.check(public.airvalet_admin_alerts_confirm(current_setting('t.code')) ->> 'result' = 'VERIFIED', 'right code verifies');
select pg_temp.check((public.airvalet_admin_alerts_set('{"enabled":true,"daily_cap":2}') ->> 'enabled')::boolean, 'alerts enabled');
reset role;
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', null, '+17545550101', 'admin:GUEST_MESSAGE:px:m0') is null, 'admin phone never alerts about itself (no loop)');
select pg_temp.check(public.airvalet_admin_alert_claim('PASS_REQUEST', 900001, null, 'admin:PASS_REQUEST:p900001:r0') is null, 'pass requests off by default');
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', 900001, '+13055550142', 'admin:GUEST_MESSAGE:p900001:m1') = '+17545550101', 'guest message → admin phone (claimed)');
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', 900002, '+13055550143', 'admin:GUEST_MESSAGE:p900001:m1') is null, 'same event twice → claimed once (dedupe)');
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', 900001, '+13055550142', 'admin:GUEST_MESSAGE:p900001:m9') is null, 'same guest within 10 min → no second alert');
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', 900002, '+13055550143', 'admin:GUEST_MESSAGE:p900002:m2') = '+17545550101', 'another guest → alert');
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', 900003, '+13055550144', 'admin:GUEST_MESSAGE:p900003:m3') is null, 'daily cap (2) reached → no more alerts');
select pg_temp.check(public.airvalet_notify_claim('push:GUEST_MESSAGE:m1', 'push') and not public.airvalet_notify_claim('push:GUEST_MESSAGE:m1', 'push'), 'push claimed once per event');
select pg_temp.check(public.airvalet_is_admin_alert_phone('+17545550101'), 'admin phone recognised (inbound is not a guest message)');

-- ── 10. TV alerts + alert signals ────────────────────────────────────────
insert into public.airvalet_sms_messages (direction, passenger_id, phone_e164, message_type, body, provider, provider_message_sid, status, received_at)
values ('inbound', 900001, '+13055550142', 'INBOUND', 'Hi, my flight is delayed, landing around 6pm', 'twilio', 'SMportaltest000000000000000000001', 'received', now()),
       ('inbound', 900001, '+13055550142', 'INBOUND_STOP', 'STOP', 'twilio', 'SMportaltest000000000000000000002', 'received', now());
select pg_temp.check((select count(*) from public.airvalet_alert_events e join public.airvalet_sms_messages m on m.id = e.ref_id where m.provider_message_sid like 'SMportaltest%') = 1,
                     'guest message emits a signal; STOP does not');
update public.airvalet_sms_settings set sending_enabled = false where id;
select pg_temp.act('localtv');
select pg_temp.check((public.airvalet_tv_alerts() ->> 'enabled')::boolean = false, 'TV shows nothing while AirValet texting is OFF (dark launch)');
reset role;
insert into public.airvalet_sms_settings (id) values (true) on conflict do nothing;
update public.airvalet_sms_settings set sending_enabled = true where id;
select pg_temp.act('localtv');
select set_config('t.tv', public.airvalet_tv_alerts()::text, true);
reset role;
select pg_temp.check((current_setting('t.tv')::jsonb ->> 'unread')::int >= 1, 'TV sees the unread count');
select pg_temp.check(current_setting('t.tv')::jsonb #>> '{latest,0,who}' in ('John S.', 'Mary J.', 'Diana P.', 'Other P.', 'Rafael A.'), 'TV shows first name + initial');
select pg_temp.check(position('555' in current_setting('t.tv')) = 0 and position('+1305' in current_setting('t.tv')) = 0, 'TV payload has no phone number');
select pg_temp.check((select read_at from public.airvalet_sms_messages where provider_message_sid = 'SMportaltest000000000000000000001') is null, 'TV never marks messages read');
select pg_temp.act('localtv');
select pg_temp.check((select count(*) from public.airvalet_alert_events) >= 1, 'TV may read the (anonymous) alert signals');
select pg_temp.check((select count(*) from public.passengers) = 0, 'TV_ONLY still reads no passengers rows (RLS unchanged)');
reset role;

-- ── 11. Push subscriptions ───────────────────────────────────────────────
select pg_temp.act('localipad');
select pg_temp.check(public.airvalet_push_subscribe('portal_pending_device_key_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx', 'https://push.example.com/ep/1', repeat('k', 87), repeat('a', 22)) ->> 'result' = 'DEVICE_NOT_AUTHORIZED', 'unapproved device cannot subscribe');
select pg_temp.check(public.airvalet_push_subscribe('portal_test_device_key_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx', 'https://push.example.com/ep/2', repeat('k', 87), repeat('a', 22)) ->> 'result' = 'OK', 'approved device subscribes');
reset role;
select pg_temp.check((select count(*) from public.airvalet_push_targets()) = 0, 'push targets empty while push is OFF');
update public.airvalet_portal_settings set push_enabled = true;
select pg_temp.check((select count(*) from public.airvalet_push_targets()) = 1, 'push target when ON');
select pg_temp.check((select show_preview from public.airvalet_push_targets()) = false, 'lock-screen preview off by default');
update public.airvalet_sms_devices set status = 'revoked' where label = 'Portal Test iPad';
select pg_temp.check((select count(*) from public.airvalet_push_targets()) = 0, 'revoked device gets no push');

-- ── 12. Publication / grants ─────────────────────────────────────────────
select pg_temp.check((select array_agg(tablename::text order by tablename) from pg_publication_tables where pubname = 'supabase_realtime')
                     = array['airvalet_alert_events','airvalet_pass_requests','airvalet_sms_messages','passengers','payments'], 'realtime publication');
select pg_temp.check(not has_function_privilege('anon', 'public.airvalet_portal_view(text,text)', 'execute')
                     and not has_function_privilege('authenticated', 'public.airvalet_portal_view(text,text)', 'execute'), 'portal view only via the Edge Function');
select pg_temp.check(not has_function_privilege('authenticated', 'public.airvalet_admin_alert_claim(text,bigint,text,text)', 'execute'), 'alert gate service-only');

rollback;
