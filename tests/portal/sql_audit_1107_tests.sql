-- 20261107 portal abuse limits. LOCAL ONLY, one transaction, rolled back.
-- The migration is NOT applied in production: this file is fed after it in
-- the same transaction, so the local database stays equal to production:
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat migrations/20261107_airvalet_portal_abuse_limits.sql; cat tests/portal/sql_audit_1107_tests.sql) \
--     | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres -qAt
-- A failed check raises 'FAIL: …'.

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
create function pg_temp.hit(b text, n int) returns int language plpgsql as $$
declare v int; begin for i in 1..n loop v := public.airvalet_pass_hit(b); end loop; return v; end $$;

-- ── 1. Per-link limits keep their real period ────────────────────────────
select pg_temp.check(pg_temp.hit('r:999001:20261025', 12) = 12, 'requests bucket counts 12');
-- "10+ minutes later": every 10-minute window row gets older (this is what reset the count before).
update public.airvalet_pass_rate set window_start = window_start - interval '11 minutes';
select pg_temp.check(public.airvalet_pass_hit('r:999001:20261025') = 13, 'request #13 the same day is over the 12/day limit (no reset after 10 min)');
select pg_temp.check(pg_temp.hit('m:999001:2026102514', 20) = 20, 'chat bucket counts 20');
update public.airvalet_pass_rate set window_start = window_start - interval '11 minutes';
select pg_temp.check(public.airvalet_pass_hit('m:999001:2026102514') = 21, 'chat message #21 in the same hour is over the 20/h limit');
select pg_temp.check(public.airvalet_pass_hit('m:999001:2026102515') = 1, 'a new hour starts a new chat count');
select pg_temp.check(not exists (select 1 from public.airvalet_pass_rate where bucket like 'r:999001:%' or bucket like 'm:999001:%'), 'long buckets are not in the 10-minute table (its cleanup cannot reset them)');
select pg_temp.check(pg_temp.hit('c:e2e1107', 3) = 3, 'per-IP buckets keep the 10-minute window');
update public.airvalet_pass_rate set window_start = window_start - interval '11 minutes' where bucket = 'c:e2e1107';
select pg_temp.check(public.airvalet_pass_hit('c:e2e1107') = 1, 'per-IP bucket resets after 10 minutes (unchanged)');
select pg_temp.act('localadmin');
select pg_temp.check(pg_temp.errs($q$select public.airvalet_pass_hit('r:x')$q$), 'staff cannot call airvalet_pass_hit');
select pg_temp.check(pg_temp.errs($q$select * from public.airvalet_pass_rate_long$q$), 'staff cannot read the long rate table');
reset role;

-- ── 2. Super Admin alerts: unknown senders cannot use up the cap ─────────
update public.airvalet_admin_alerts set enabled = true, phone_e164 = '+17545550100', phone_verified_at = now(),
       notify_guest_messages = true, daily_cap = 30, per_guest_window_min = 10;
delete from public.airvalet_notify_log where channel = 'admin_sms';
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', null, '+13055550001', 'admin:msg:px:u1') = '+17545550100', 'first text from an unknown number alerts the admin');
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', null, '+13055550002', 'admin:msg:px:u2') is null, 'second unknown text inside the window: no alert');
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', 999001, '+13055550003', 'admin:msg:p999001:g1') = '+17545550100', 'a real guest still alerts right away');
do $$ begin
  for i in 2..5 loop
    update public.airvalet_notify_log set created_at = created_at - interval '11 minutes' where channel = 'admin_sms';
    perform public.airvalet_admin_alert_claim('GUEST_MESSAGE', null, '+1305555001' || i, 'admin:msg:px:w' || i);
  end loop;
end $$;
select pg_temp.check((select count(*) from public.airvalet_notify_log where dedupe_key like 'admin:%:px:%') = 5, '5 unknown-number alerts in a day');
update public.airvalet_notify_log set created_at = created_at - interval '11 minutes' where channel = 'admin_sms';
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', null, '+13055550099', 'admin:msg:px:w6') is null, 'the 6th unknown-number alert of the day is dropped');
select pg_temp.check(public.airvalet_admin_alert_claim('GUEST_MESSAGE', 999002, '+13055550004', 'admin:msg:p999002:g2') = '+17545550100', 'real guests keep their alerts after a flood from unknown numbers');

-- ── 3. Push subscriptions: real push services only ───────────────────────
insert into public.airvalet_sms_devices (key_hash, label, status)
values (public.airvalet_sms_device_key_hash('e2e1107devicekeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'), 'E2E 1107', 'approved');
select pg_temp.act('localipad');
select pg_temp.check(public.airvalet_push_subscribe('e2e1107devicekeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'https://attacker.example/x', 'BE2e1107p256dhKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'e2e1107authAAA', true)->>'result' = 'ENDPOINT_NOT_ALLOWED', 'push to an arbitrary https server is refused');
select pg_temp.check(public.airvalet_push_subscribe('e2e1107devicekeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'https://web.push.apple.com.attacker.example/x', 'BE2e1107p256dhKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'e2e1107authAAA', true)->>'result' = 'ENDPOINT_NOT_ALLOWED', 'look-alike host is refused');
select pg_temp.check(public.airvalet_push_subscribe('e2e1107devicekeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'https://web.push.apple.com/QE2e1107', 'BE2e1107p256dhKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'e2e1107authAAA', true)->>'result' = 'OK', 'Safari / iPad push (web.push.apple.com) still works');
select pg_temp.check(public.airvalet_push_subscribe('e2e1107devicekeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'https://fcm.googleapis.com/fcm/send/e2e1107', 'BE2e1107p256dhKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'e2e1107authAAA', false)->>'result' = 'OK', 'Chrome push (fcm.googleapis.com) works');
reset role;

-- ── 4. Stripe tip totals: operation roles only ───────────────────────────
select pg_temp.act('localiphone');
select pg_temp.check(not pg_temp.errs($q$select public.get_stripe_tips_today_cents()$q$), 'IPHONE_OPS reads today''s tips (Closing Report on the phones)');
select pg_temp.check(not pg_temp.errs($q$select public.get_stripe_tips_for_date_cents(date '2026-10-25')$q$), 'IPHONE_OPS reads a day''s tips');
select pg_temp.act('localipad');
select pg_temp.check(not pg_temp.errs($q$select public.get_stripe_tips_today_cents()$q$), 'IPAD_OPS reads today''s tips');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$select public.get_stripe_tips_for_date_cents(date '2026-10-25')$q$), 'TV_ONLY cannot read tip totals');
select pg_temp.act(null);
select pg_temp.check(pg_temp.errs($q$select public.get_stripe_tips_today_cents()$q$), 'anon cannot read tip totals');
reset role;

rollback;
