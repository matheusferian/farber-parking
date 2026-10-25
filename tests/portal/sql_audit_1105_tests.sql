-- 20261105 audit hardening. LOCAL ONLY, one transaction, rolled back.
-- Run: docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres < tests/portal/sql_audit_1105_tests.sql
-- Needs the local test logins (localadmin / localiphone / localtv). A failed check raises 'FAIL: …'.
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
create function pg_temp.pv(t text) returns jsonb language sql as $$ select public.airvalet_portal_view(t, 'a1105-' || md5(random()::text)) $$;
create function pg_temp.d(n int) returns text language sql as $$ select to_char((now() at time zone 'America/New_York')::date + n, 'FMMM/FMDD/YYYY') $$;
create function pg_temp.mint(pid bigint) returns text language plpgsql as $$
declare v text;
begin
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  select p.id, coalesce(public.airvalet_sms_normalize_phone(p.phone), '+13050000000'),
         (select d.id from public.airvalet_sms_devices d where d.label = 'A1105 iPad'), gen_random_uuid()
    from public.passengers p where p.id = pid
  on conflict do nothing;
  v := public.airvalet_pass_mint(pid);
  update public.airvalet_pass_links set expires_at = now() + interval '3 days' where passenger_id = pid and revoked_at is null;
  return v;
end $$;

insert into public.airvalet_sms_devices (key_hash, label, status, decided_at)
values (public.airvalet_sms_device_key_hash('a1105_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), 'A1105 iPad', 'approved', now());
update public.airvalet_portal_settings set portal_enabled = true, chat_enabled = true;
delete from public.airvalet_pass_rate;

-- ── 1. Lockbox code on the pass ──────────────────────────────────────────
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, delivery_type)
values (951101, 'x', now(), 'LOCK NORMAL', '3055551101', 'A1105-01', 'PENDING', pg_temp.d(0), null),
       (951102, 'x', now(), 'LOCK CUSTOMS', '3055551102', 'A1105-02', 'PENDING', pg_temp.d(0), null),
       (951103, 'x', now(), 'LOCK OLD', '3055551103', 'A1105-03', 'PENDING', pg_temp.d(-2), null),
       (951104, 'x', now(), 'LOCK AUTH', '3055551104', 'A1105-04', 'PENDING', pg_temp.d(0), null);
insert into public.airvalet_pass_state (passenger_id, lockbox_authorized_at, lockbox_reveal_on, lockbox_code)
select id, now(), (now() at time zone 'America/New_York')::date - 3, 'PRT-1105' from public.passengers where id between 951101 and 951104;
select set_config('t.t1', pg_temp.mint(951101), true), set_config('t.t2', pg_temp.mint(951102), true),
       set_config('t.t3', pg_temp.mint(951103), true), set_config('t.t4', pg_temp.mint(951104), true);

select pg_temp.check(pg_temp.pv(current_setting('t.t1')) #>> '{pass,lockbox,code}' = 'PRT-1105', 'lockbox code shown on the return day (unchanged behaviour)');
update public.passengers set status = 'DELIVERED', delivery_type = 'CUSTOMS', customs_gratuity_sent = false where id = 951102;
select pg_temp.check(pg_temp.pv(current_setting('t.t2')) #>> '{pass,status}' = 'CUSTOMS_CONFIRMED', 'Customs delivery still shows At Customs');
select pg_temp.check(pg_temp.pv(current_setting('t.t2')) #> '{pass,lockbox}' = 'null'::jsonb, 'F-1: lockbox hidden after a Customs delivery');
select pg_temp.check(pg_temp.pv(current_setting('t.t3')) #> '{pass,lockbox}' = 'null'::jsonb, 'F-1: lockbox hidden after the return day');
update public.passengers set pickup_auth_name = 'ANA SOUZA' where id = 951104;
select pg_temp.check(pg_temp.pv(current_setting('t.t4')) #> '{pass,lockbox}' = 'null'::jsonb, 'lockbox hidden when someone else is authorized to pick up');

-- ready_by_staff: true only when staff marked the car ready
select pg_temp.check((pg_temp.pv(current_setting('t.t1')) #>> '{pass,ready_by_staff}')::boolean = false, 'ready_by_staff false without staff Ready');
update public.airvalet_pass_state set ready_at = now() where passenger_id = 951101;
select pg_temp.check((pg_temp.pv(current_setting('t.t1')) #>> '{pass,ready_by_staff}')::boolean = true, 'ready_by_staff true after staff Ready');

-- ── 2. Chat history follows the current phone ────────────────────────────
insert into public.airvalet_sms_messages (direction, passenger_id, ticket_snapshot, phone_e164, message_type, template_key, body, provider, provider_message_sid, status, match_method, received_at)
values ('inbound', 951101, 'A1105-01', '+13055551101', 'INBOUND', 'PORTAL_CHAT', 'from the stranger', 'portal', 'PORTAL-a1105-1', 'received', 'manual', now());
select pg_temp.check(jsonb_array_length(public.airvalet_portal_messages(current_setting('t.t1'), 'a1105-c') -> 'messages') = 1, 'chat shows messages of the current phone');
update public.passengers set phone = '3055559911' where id = 951101;
select set_config('t.t1b', pg_temp.mint(951101), true);
select pg_temp.check(jsonb_array_length(public.airvalet_portal_messages(current_setting('t.t1b'), 'a1105-c') -> 'messages') = 0, 'F-6: after a phone correction the old number''s chat is not shown');

-- ── 3. Closing reports ───────────────────────────────────────────────────
insert into public.daily_closing_reports (id, report_date, status, cash, stripe_tips_cents, other_tips_cents, total_tips_cents, closed_at, finalized_at, finalized_by, delivered_verified, hangars_verified)
values ('00000000-0000-0000-0000-00000000a105', date '2001-01-05', 'FINALIZED', 200, 1500, 0, 1500, null, now(), 'forged@x', true, true),
       ('00000000-0000-0000-0000-00000000a106', date '2001-01-06', 'DRAFT', 0, 900, 100, 1000, now(), null, null, true, true),
       ('00000000-0000-0000-0000-00000000a107', date '2001-01-07', 'DRAFT', 0, 0, 0, 0, null, null, null, true, true);
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.errs($q$update public.daily_closing_reports set cash = 1 where report_date = date '2001-01-05'$q$), 'ADM-01: staff cannot edit a FINALIZED report');
select pg_temp.check(pg_temp.errs($q$update public.daily_closing_reports set stripe_tips_cents = 0 where report_date = date '2001-01-06'$q$), 'ADM-01: staff cannot change tips of a closed report');
select pg_temp.check(not pg_temp.errs($q$update public.daily_closing_reports set notes = 'late note' where report_date = date '2001-01-06'$q$), 'other fields of a closed draft stay editable (old Closing flow)');
select pg_temp.check(not pg_temp.errs($q$update public.daily_closing_reports set cash = 5 where report_date = date '2001-01-07'$q$), 'open draft stays editable');
update public.daily_closing_reports set status = 'FINALIZED', finalized_by = 'someone.else@forged' where report_date = date '2001-01-07';
reset role;
select pg_temp.check((select finalized_by from public.daily_closing_reports where report_date = date '2001-01-07') = 'localiphone@airvalet.local', 'finalized_by comes from the session');
select pg_temp.check((select cash from public.daily_closing_reports where report_date = date '2001-01-05') = 200, 'finalized amounts unchanged');
select pg_temp.act('localadmin');
select pg_temp.check(not pg_temp.errs($q$update public.daily_closing_reports set notes = 'admin correction' where report_date = date '2001-01-05'$q$), 'ADMIN keeps a correction path');
reset role;

-- ── 4. passengers: no direct DELETE ──────────────────────────────────────
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.errs($q$delete from public.passengers where id = 951103$q$), 'ADM-02: direct REST DELETE is refused');
reset role;
select pg_temp.check(exists (select 1 from public.passengers where id = 951103), 'ADM-02: the row is still there');
select pg_temp.act('localiphone');
select pg_temp.check(not pg_temp.errs($q$select public.delete_passenger_with_log(951103)$q$), 'delete through delete_passenger_with_log() still works');
reset role;
select pg_temp.check(not exists (select 1 from public.passengers where id = 951103)
                     and exists (select 1 from public.activity_log where ticket = 'A1105-03' and action = 'DELETED'), 'that delete is logged');

-- ── 5. Stripe tip totals need a staff session ────────────────────────────
select pg_temp.act(null);
select pg_temp.check(pg_temp.errs($q$select public.get_stripe_tips_today_cents()$q$), 'ADM-03: anon cannot read today''s Stripe tips');
select pg_temp.check(pg_temp.errs($q$select public.get_stripe_tips_for_date_cents(current_date)$q$), 'ADM-03: anon cannot read Stripe tips by date');
select pg_temp.act('localiphone');
select pg_temp.check(not pg_temp.errs($q$select public.get_stripe_tips_today_cents()$q$), 'staff still reads Stripe tips');
reset role;

-- ── 6. activity_log.changed_by from the session ──────────────────────────
select pg_temp.act('localiphone');
insert into public.activity_log (ts, action, passenger, ticket, passenger_id, changed_by) values ('x', 'EDIT', 'LOCK NORMAL', 'A1105-01', 951101, 'localadmin@airvalet.local');
reset role;
select pg_temp.check((select changed_by from public.activity_log where passenger_id = 951101 and action = 'EDIT' order by id desc limit 1) = 'localiphone@airvalet.local', 'ADM-08: changed_by cannot be forged');

-- ── 7. last active ADMIN ─────────────────────────────────────────────────
select pg_temp.check(position('audit 1105: active' in pg_get_functiondef('public.set_user_role(uuid,public.account_role)'::regprocedure)) > 0, 'ADM-15: last-admin guard counts active admins only');

rollback;
