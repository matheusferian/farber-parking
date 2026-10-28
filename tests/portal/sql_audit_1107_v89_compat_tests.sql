-- 1107 against production v89 (1112 Checkout, 1113 cash tips, 1116 pass). LOCAL ONLY,
-- fed after the migration in one transaction that is rolled back:
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat migrations/20261107_airvalet_portal_abuse_limits.sql; \
--    sed "s/__TOKEN__/<seed token>/" tests/portal/sql_audit_1107_v89_compat_tests.sql) | psql ...
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

create temp table subs_before as select id, endpoint, revoked_at, fail_count from public.airvalet_push_subs;
update public.airvalet_portal_settings set gratuity_checkout_enabled = true, chat_enabled = true, requests_enabled = true;   -- = production settings
delete from public.airvalet_pass_rate;

-- ── Valet Pass + chat still open for a real link ─────────────────────────
select pg_temp.check((public.airvalet_portal_view('__TOKEN__', 'c1107a') ->> 'state') = 'ok', 'Valet Pass opens (portal view) after 1107');
select pg_temp.check((public.airvalet_portal_view('__TOKEN__', 'c1107a') -> 'pass' -> 'gratuity_checkout' -> 'amounts') is not null, 'pass still offers the six gratuity amounts');
select pg_temp.check((public.airvalet_portal_view('__TOKEN__', 'c1107a') -> 'pass' ->> 'ticket') is not null, 'ticket number still on the pass (1110)');
select pg_temp.check(public.airvalet_portal_view('__TOKEN__', 'c1107a') -> 'pass' ? 'tip_thanks', 'tip_thanks still on the pass (1113/1116)');
select pg_temp.check((public.airvalet_portal_send_message('__TOKEN__', 'c1107a', 'Hello from 1107 test', 'ck1107aaaaaaaaaaaaaaaa') ->> 'result') = 'OK', 'passenger chat still sends');

-- ── Dynamic Checkout: 6 sessions per 10 minutes, unchanged ───────────────
do $$ begin for i in 1..6 loop
  if (public.airvalet_portal_gratuity_checkout('__TOKEN__', 'c1107a', 1000) ->> 'result') <> 'OK' then raise exception 'FAIL: checkout % refused', i; end if;
end loop; end $$;
select pg_temp.check((public.airvalet_portal_gratuity_checkout('__TOKEN__', 'c1107a', 1000) ->> 'result') = 'LIMITED', '7th Checkout in 10 minutes is limited (same as v85)');
update public.airvalet_pass_rate set window_start = window_start - interval '11 minutes';
select pg_temp.check((public.airvalet_portal_gratuity_checkout('__TOKEN__', 'c1107a', 1000) ->> 'result') = 'OK', 'Checkout works again 10 minutes later (k: stays a 10-minute bucket)');
select pg_temp.check(not exists (select 1 from public.airvalet_pass_rate_long where bucket like 'k:%' or bucket like 'g:%' or bucket like 'c:%' or bucket like 'f:%'), 'k: / g: / c: / f: buckets never go to the long table');
select pg_temp.check((public.airvalet_portal_gratuity_checkout('__TOKEN__', 'c1107a', 99) ->> 'result') = 'INVALID', 'amount under $1 still refused');
select pg_temp.check((public.airvalet_portal_gratuity_checkout('bad-token-xxxxxxxxxxxxxxxx', 'c1107a', 1000) ->> 'state') <> 'ok', 'unknown token gets no Checkout');

-- ── Stripe totals and cash tips per role ─────────────────────────────────
select pg_temp.act('localadmin');
select pg_temp.check(not pg_temp.errs($q$select public.get_stripe_tips_today_cents()$q$), 'ADMIN reads Stripe tips');
select pg_temp.check(not pg_temp.errs($q$select * from public.airvalet_cash_tips_for_date(current_date)$q$), 'ADMIN: Smart Tips cash totals unaffected');
select pg_temp.act('localmanager');
select pg_temp.check(not pg_temp.errs($q$select public.get_stripe_tips_for_date_cents(current_date)$q$), 'MANAGER reads Stripe tips');
select pg_temp.act('localiphone');
select pg_temp.check(not pg_temp.errs($q$select * from public.airvalet_cash_tips_for_date(current_date)$q$), 'IPHONE_OPS: Smart Tips cash totals unaffected');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$select public.get_stripe_tips_today_cents()$q$), 'TV_ONLY: Stripe total refused (TV never shows it)');
reset role;
select pg_temp.check(pg_temp.errs($q$select public.get_stripe_tips_today_cents()$q$), 'no JWT (cron / service role / SQL editor): refused — no server code calls it (checked prod pg_proc, cron.job, functions)');

-- ── Existing push subscriptions untouched ────────────────────────────────
select pg_temp.check((select count(*) from public.airvalet_push_subs) = (select count(*) from subs_before)
   and not exists (select 1 from public.airvalet_push_subs s join subs_before b using (id) where s.revoked_at is distinct from b.revoked_at or s.endpoint <> b.endpoint), 'existing push devices unchanged');
rollback;
