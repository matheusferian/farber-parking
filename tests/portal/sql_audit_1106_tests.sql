-- 20261106 backend hardening. LOCAL ONLY, one transaction, rolled back.
-- Run: docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres < tests/portal/sql_audit_1106_tests.sql
-- Needs the local test logins (localadmin / localipad / localiphone / localmanager / localtv).
-- A failed check raises 'FAIL: …'. Test rows are tagged 'BKD '.
\set ON_ERROR_STOP 1
begin;

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.act(u text) returns void language plpgsql as $$
declare v_id uuid;
begin
  reset role;
  if u is null then perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; return; end if;
  select id into v_id from public.user_profiles where username = u;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', u || '@airvalet.local')::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.errs(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
-- rows touched by a statement (RLS hides rows silently: 0 = refused)
create function pg_temp.n(q text) returns int language plpgsql as $$
declare v int;
begin execute q; get diagnostics v = row_count; return v; exception when others then return -1; end $$;
create function pg_temp.cnt(q text) returns bigint language plpgsql as $$
declare v bigint;
begin execute 'select count(*) from (' || q || ') x' into v; return v; end $$;

-- ── 1. ADM-09 daily_closing_reports: ops roles (iPhone included), not TV ──
insert into public.daily_closing_reports (id, report_date, status, cash, notes, delivered_verified, hangars_verified)
values ('00000000-0000-0000-0000-00000000b106', date '2001-02-06', 'DRAFT', 0, 'BKD dcr', true, true);
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.daily_closing_reports where report_date = date '2001-02-06'$q$) = 1, 'IPHONE_OPS reads closing reports (daily closing on the phones)');
select pg_temp.check(pg_temp.n($q$update public.daily_closing_reports set notes = 'BKD iphone' where report_date = date '2001-02-06'$q$) = 1, 'IPHONE_OPS updates a draft closing report');
select pg_temp.check(not pg_temp.errs($q$insert into public.daily_closing_reports (report_date, status, cash, delivered_verified, hangars_verified) values (date '2001-02-07', 'DRAFT', 0, true, true)$q$), 'IPHONE_OPS creates a closing report');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.daily_closing_reports where report_date = date '2001-02-06'$q$) = 0, 'ADM-09: TV_ONLY cannot read closing reports');
select pg_temp.check(pg_temp.errs($q$insert into public.daily_closing_reports (report_date, status, cash, delivered_verified, hangars_verified) values (date '2001-02-09', 'DRAFT', 0, true, true)$q$), 'ADM-09: TV_ONLY cannot create a closing report');
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.daily_closing_reports where report_date = date '2001-02-06'$q$) = 1, 'IPAD_OPS still reads closing reports');
select pg_temp.check(pg_temp.n($q$update public.daily_closing_reports set notes = 'BKD ipad' where report_date = date '2001-02-06'$q$) = 1, 'IPAD_OPS still updates a draft');
select pg_temp.check(not pg_temp.errs($q$insert into public.daily_closing_reports (report_date, status, cash, delivered_verified, hangars_verified) values (date '2001-02-08', 'DRAFT', 0, true, true)$q$), 'IPAD_OPS still creates a closing report');
select pg_temp.act('localmanager');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.daily_closing_reports where report_date = date '2001-02-06'$q$) = 1, 'MANAGER still reads closing reports');
select pg_temp.act('localadmin');
select pg_temp.check(pg_temp.n($q$update public.daily_closing_reports set notes = 'BKD admin' where report_date = date '2001-02-06'$q$) = 1, 'ADMIN still updates closing reports');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.daily_closing_reports$q$) = 0, 'TV_ONLY reads no closing reports');
-- data the iPhone still needs
reset role;
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (951201, 'x', now(), 'BKD HIST', '3055551201', 'BKD-1201', 'PENDING');
insert into public.activity_log (ts, action, passenger, ticket, passenger_id, changed_by) values ('x', 'EDIT', 'BKD HIST', 'BKD-1201', 951201, 'x');
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.activity_log where passenger_id = 951201$q$) = 1, 'IPHONE_OPS still reads passenger change history (car panel)');
select pg_temp.check(not pg_temp.errs($q$select count(*) from public.payments$q$), 'IPHONE_OPS still reads payments (Tips KPI realtime)');
reset role;

-- ── 2a. ADM-07 rental_logs ───────────────────────────────────────────────
select pg_temp.act('localiphone');
select pg_temp.check(not pg_temp.errs($q$insert into public.rental_logs (passenger_name, rental_company, flight_date, logged_by) values ('BKD RENTAL', 'Hertz', current_date, 'x')$q$), 'IPHONE_OPS still adds a rental log');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.rental_logs where passenger_name = 'BKD RENTAL'$q$) = 1, 'IPHONE_OPS still lists rental logs');
select pg_temp.check(pg_temp.n($q$update public.rental_logs set notes = 'BKD edited' where passenger_name = 'BKD RENTAL'$q$) = 0, 'ADM-07: IPHONE_OPS cannot edit a rental log');
select pg_temp.check(pg_temp.n($q$delete from public.rental_logs where passenger_name = 'BKD RENTAL'$q$) = 0, 'ADM-07: IPHONE_OPS cannot delete a rental log');
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.n($q$update public.rental_logs set notes = 'BKD edited' where passenger_name = 'BKD RENTAL'$q$) = 0, 'ADM-07: IPAD_OPS cannot edit a rental log');
select pg_temp.check(pg_temp.n($q$delete from public.rental_logs where passenger_name = 'BKD RENTAL'$q$) = 0, 'ADM-07: IPAD_OPS cannot delete a rental log');
select pg_temp.check(not pg_temp.errs($q$insert into public.rental_logs (passenger_name, rental_company, flight_date) values ('BKD RENTAL 2', 'Avis', current_date)$q$), 'IPAD_OPS still adds a rental log');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$insert into public.rental_logs (passenger_name, rental_company, flight_date) values ('BKD RENTAL TV', 'Avis', current_date)$q$), 'TV_ONLY cannot add a rental log');
select pg_temp.act('localmanager');
select pg_temp.check(pg_temp.n($q$update public.rental_logs set notes = 'BKD manager fix' where passenger_name = 'BKD RENTAL'$q$) = 1, 'MANAGER corrects a rental log');
select pg_temp.act('localadmin');
select pg_temp.check(pg_temp.n($q$delete from public.rental_logs where passenger_name = 'BKD RENTAL 2'$q$) = 1, 'ADMIN deletes a rental log');
reset role;
select pg_temp.check((select notes from public.rental_logs where passenger_name = 'BKD RENTAL') = 'BKD manager fix', 'only the MANAGER edit landed');

-- ── 2b. ADM-07 valet_shifts ──────────────────────────────────────────────
select pg_temp.act('localiphone');
select pg_temp.check(not pg_temp.errs($q$insert into public.valet_shifts (valet_name, business_date, clock_in_at, created_by) values ('BKD VALET', date '2001-02-06', timestamptz '2001-02-06 08:00-05', 'x')$q$), 'IPHONE_OPS still clocks a valet in');
select pg_temp.check(pg_temp.errs($q$update public.valet_shifts set clock_in_at = timestamptz '2001-02-06 06:00-05' where valet_name = 'BKD VALET'$q$), 'ADM-07: IPHONE_OPS cannot change a clock-in time');
select pg_temp.check(pg_temp.errs($q$update public.valet_shifts set valet_name = 'BKD OTHER', clock_out_at = timestamptz '2001-02-06 16:00-05' where valet_name = 'BKD VALET'$q$), 'ADM-07: Clock Out cannot rename the valet');
select pg_temp.check(pg_temp.n($q$update public.valet_shifts set clock_out_at = timestamptz '2001-02-06 16:00-05' where valet_name = 'BKD VALET'$q$) = 1, 'IPHONE_OPS still records Clock Out (app PATCH)');
select pg_temp.check(pg_temp.errs($q$update public.valet_shifts set clock_out_at = timestamptz '2001-02-06 20:00-05' where valet_name = 'BKD VALET'$q$), 'ADM-07: a closed shift cannot be changed by ops');
select pg_temp.check(pg_temp.n($q$delete from public.valet_shifts where valet_name = 'BKD VALET'$q$) = 0, 'ops cannot delete a shift');
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.errs($q$update public.valet_shifts set clock_out_at = timestamptz '2001-02-06 20:00-05' where valet_name = 'BKD VALET'$q$), 'ADM-07: IPAD_OPS cannot change a closed shift either');
select pg_temp.act('localmanager');
select pg_temp.check(pg_temp.n($q$update public.valet_shifts set clock_out_at = timestamptz '2001-02-06 17:00-05' where valet_name = 'BKD VALET'$q$) = 1, 'MANAGER corrects a closed shift');
select pg_temp.act('localadmin');
select pg_temp.check(pg_temp.n($q$update public.valet_shifts set clock_in_at = timestamptz '2001-02-06 07:30-05' where valet_name = 'BKD VALET'$q$) = 1, 'ADMIN corrects a clock-in time');
reset role;
select pg_temp.check((select clock_in_at = timestamptz '2001-02-06 07:30-05' and clock_out_at = timestamptz '2001-02-06 17:00-05' from public.valet_shifts where valet_name = 'BKD VALET'), 'shift holds only the ADMIN / MANAGER corrections');

-- ── 3. ADM-06 vehicle_location_history ───────────────────────────────────
select pg_temp.act('localiphone');
select pg_temp.check(not pg_temp.errs($q$insert into public.vehicle_location_history (passenger_id, ticket, passenger_name, from_location, to_location, action, note, created_by) values (951201, 'BKD-1201', 'BKD HIST', '', 'HANGAR 3', 'CHECK-IN', 'BKD', 'forged@x')$q$), 'ADM-06: IPHONE_OPS movement history insert now lands (vlhInsert)');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.vehicle_location_history where passenger_id = 951201$q$) = 0, 'IPHONE_OPS does not read movement history (no Report tab)');
select pg_temp.act('localipad');
select pg_temp.check(not pg_temp.errs($q$insert into public.vehicle_location_history (passenger_id, ticket, to_location, action) values (951201, 'BKD-1201', 'HANGAR 19', 'DELIVERED (NORMAL)')$q$), 'IPAD_OPS movement history insert lands');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.vehicle_location_history where passenger_id = 951201$q$) = 2, 'IPAD_OPS reads movement history (Operations Report)');
select pg_temp.check(pg_temp.n($q$update public.vehicle_location_history set note = 'BKD x' where passenger_id = 951201$q$) = 0, 'movement history cannot be edited');
select pg_temp.check(pg_temp.n($q$delete from public.vehicle_location_history where passenger_id = 951201$q$) = 0, 'movement history cannot be deleted');
select pg_temp.act('localmanager');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.vehicle_location_history where passenger_id = 951201$q$) = 2, 'MANAGER reads movement history');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$insert into public.vehicle_location_history (passenger_id, action) values (951201, 'MOVE')$q$), 'TV_ONLY cannot write movement history');
select pg_temp.act(null);
select pg_temp.check(pg_temp.errs($q$insert into public.vehicle_location_history (passenger_id, action) values (951201, 'MOVE')$q$), 'anon cannot write movement history');
select pg_temp.check(pg_temp.cnt($q$select 1 from public.vehicle_location_history$q$) = 0, 'anon reads no movement history');
reset role;
select pg_temp.check((select created_by from public.vehicle_location_history where passenger_id = 951201 and action = 'CHECK-IN') = 'localiphone@airvalet.local', 'created_by comes from the session');

-- ── 4. Twilio F4: old trip vs new active ticket ──────────────────────────
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values
  (951211, 'x', now(), 'BKD OLD TRIP', '3055551211', 'BKD-1211', 'DELIVERED'),
  (951212, 'x', now(), 'BKD NEW TRIP', '3055551211', 'BKD-1212', 'PENDING'),
  (951213, 'x', now(), 'BKD ONLY OLD', '3055551213', 'BKD-1213', 'DELIVERED');
insert into public.airvalet_sms_messages (direction, passenger_id, phone_e164, message_type, provider, status, idempotency_key, body, created_at)
values ('outbound', 951211, '+13055551211', 'VEHICLE_DELIVERED', 'mock', 'delivered', 'bkd:f4:1', 'b', now() - interval '1 hour'),
       ('outbound', 951213, '+13055551213', 'VEHICLE_DELIVERED', 'mock', 'delivered', 'bkd:f4:3', 'b', now() - interval '1 hour');
select pg_temp.check((select passenger_id is null and match_method = 'ambiguous' and candidates = '[951212, 951211]'::jsonb from public.airvalet_sms_match_passenger('+13055551211')),
  'F4: reply after an old trip''s text, new active ticket on the phone → review (both candidates)');
select pg_temp.check((select passenger_id = 951213 and match_method = 'last_outbound' from public.airvalet_sms_match_passenger('+13055551213')), 'F4: old trip and no other active ticket → still that trip');
insert into public.airvalet_sms_messages (direction, passenger_id, phone_e164, message_type, provider, status, idempotency_key, body, created_at)
values ('outbound', 951212, '+13055551211', 'CHECK_IN', 'mock', 'delivered', 'bkd:f4:2', 'b', now() - interval '5 minutes');
select pg_temp.check((select passenger_id = 951212 and match_method = 'last_outbound' from public.airvalet_sms_match_passenger('+13055551211')), 'F4: last text to the active ticket → that ticket (unchanged)');

-- ── 5. Twilio F5: SID but no status callback ─────────────────────────────
insert into public.airvalet_sms_messages (direction, passenger_id, phone_e164, message_type, provider, status, idempotency_key, body, provider_message_sid, created_at)
values ('outbound', 951212, '+13055551211', 'RETURN_CONFIRMATION', 'mock', 'queued', 'bkd:f5:1', 'b', 'SM_BKD_F5_1', now() - interval '1 hour'),
       ('outbound', 951212, '+13055551211', 'RETURN_CONFIRMATION', 'mock', 'queued', 'bkd:f5:2', 'b', 'SM_BKD_F5_2', now() - interval '10 minutes'),
       ('outbound', 951212, '+13055551211', 'RETURN_CONFIRMATION', 'mock', 'sent', 'bkd:f5:3', 'b', 'SM_BKD_F5_3', now() - interval '2 hours');
select pg_temp.check(public.airvalet_sms_reconcile() >= 1, 'F5: reconcile flags a send with SID and no callback');
select pg_temp.check((select attention = 'NO_STATUS' and status = 'queued' from public.airvalet_sms_messages where idempotency_key = 'bkd:f5:1'), 'F5: queued 1 h, no callback → NO_STATUS alert (status unchanged)');
select pg_temp.check((select attention is null from public.airvalet_sms_messages where idempotency_key = 'bkd:f5:2'), 'F5: queued 10 min → not flagged yet');
select pg_temp.check((select attention is null from public.airvalet_sms_messages where idempotency_key = 'bkd:f5:3'), 'F5: sent (carrier has it) → not flagged');
select pg_temp.check(exists (select 1 from public.airvalet_sms_alerts where id = (select id from public.airvalet_sms_messages where idempotency_key = 'bkd:f5:1')), 'F5: NO_STATUS shows in Text alerts');
select pg_temp.check(public.airvalet_sms_apply_status('SM_BKD_F5_1', 'delivered', null, null) = 'applied', 'F5: the late callback still applies');
select pg_temp.check((select attention is null and status = 'delivered' from public.airvalet_sms_messages where idempotency_key = 'bkd:f5:1'), 'F5: a real status clears NO_STATUS');

-- ── 6. Twilio F7: late delivered after "Not received — allow resend" ─────
insert into public.airvalet_sms_messages (id, direction, passenger_id, phone_e164, message_type, provider, status, idempotency_key, body, attention, attention_at, created_at)
values ('00000000-0000-0000-0000-0000000bd107', 'outbound', 951212, '+13055551211', 'CHECK_IN', 'mock', 'send_unknown', 'bkd:f7:1', 'b', 'UNCONFIRMED', now(), now() - interval '20 minutes'),
       ('00000000-0000-0000-0000-0000000bd108', 'outbound', 951212, '+13055551211', 'CUSTOM_OPERATIONAL', 'mock', 'send_unknown', 'bkd:f7:2', 'b', 'UNCONFIRMED', now(), now() - interval '20 minutes');
select pg_temp.act('localipad');
select pg_temp.check(public.airvalet_sms_resolve_alert('00000000-0000-0000-0000-0000000bd107', 'marked_not_sent') = 'marked_not_sent', 'staff mark the unconfirmed send "not received"');
select pg_temp.check(public.airvalet_sms_resolve_alert('00000000-0000-0000-0000-0000000bd108', 'marked_not_sent') = 'marked_not_sent', 'second unconfirmed send marked "not received"');
reset role;
select pg_temp.check(public.airvalet_sms_apply_status('SM_BKD_F7_1', 'delivered', null, null, '00000000-0000-0000-0000-0000000bd107') = 'applied', 'F7: late delivered callback (?mid=) is adopted, not orphaned');
select pg_temp.check((select status = 'delivered' and provider_message_sid = 'SM_BKD_F7_1' and delivered_at is not null and attention = 'DELIVERED_AFTER_RESEND' and resolved_at is null and error_code = 'STAFF_MARKED_NOT_SENT'
                        from public.airvalet_sms_messages where id = '00000000-0000-0000-0000-0000000bd107'), 'F7: proof of delivery kept, alert reopened as DELIVERED_AFTER_RESEND');
select pg_temp.check(exists (select 1 from public.airvalet_sms_alerts where id = '00000000-0000-0000-0000-0000000bd107'), 'F7: shows in Text alerts');
select pg_temp.check(public.airvalet_sms_apply_status('SM_BKD_F7_2', 'undelivered', '30003', null, '00000000-0000-0000-0000-0000000bd108') = 'stale', 'F7: a late failure only records the SID');
select pg_temp.check((select status = 'failed' and resolved_at is not null and attention = 'UNCONFIRMED' and provider_message_sid = 'SM_BKD_F7_2' from public.airvalet_sms_messages where id = '00000000-0000-0000-0000-0000000bd108'), 'F7: a late failure does not reopen anything');
select pg_temp.act('localiphone');
select pg_temp.check(public.airvalet_sms_resolve_alert('00000000-0000-0000-0000-0000000bd107', 'acknowledged') = 'acknowledged', 'F7: staff acknowledge the reopened alert (OK button)');
reset role;

-- ── 7. ADM-18 verify code ────────────────────────────────────────────────
select pg_temp.check(position('random()' in pg_get_functiondef('public.airvalet_admin_alerts_start_verify(uuid,text)'::regprocedure)) = 0
                     and position('gen_random_bytes' in pg_get_functiondef('public.airvalet_admin_alerts_start_verify(uuid,text)'::regprocedure)) > 0, 'ADM-18: verify code no longer uses random()');
insert into public.airvalet_super_admins (user_id) select id from public.user_profiles where username = 'localadmin' on conflict do nothing;
select pg_temp.check(public.airvalet_admin_alerts_start_verify((select id from public.user_profiles where username = 'localadmin'), '+13055551299') ~ '^[0-9]{6}$', 'ADM-18: code is still 6 digits');
select pg_temp.check(pg_temp.errs($q$select public.airvalet_admin_alerts_start_verify((select id from public.user_profiles where username = 'localipad'), '+13055551299')$q$), 'ADM-18: still super admin only');

\echo AUDIT_1106_TESTS_PASSED
rollback;
