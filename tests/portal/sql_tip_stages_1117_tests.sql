-- LOCAL DB tests for 20261117_airvalet_tip_stages.sql. One transaction, rolled back. Runner:
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' migrations/20261117_airvalet_tip_stages.sql;
--    cat tests/portal/sql_tip_stages_1117_tests.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres
-- Needs the local test logins (localadmin / localipad / localiphone / localmanager / localtv).

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
create function pg_temp.rec(pid bigint, cents int, k uuid, src text, who text default null) returns jsonb language sql as $$
  select public.airvalet_tip_record(pid, cents, k, who, src) $$;
create function pg_temp.res(j jsonb) returns text language sql as $$ select j ->> 'result' $$;
-- Recorded 3 minutes ago (outside the 2-minute same-amount guard), so a test can add the same amount again.
create function pg_temp.age() returns void language sql as $$
  update public.airvalet_tip_records set recorded_at = recorded_at - interval '3 minutes' where passenger_id between 971701 and 971709 $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- Check-in day 2031-03-11, delivery day 2031-03-15 (ET), far from real data.
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator, checkout_date)
values (971701, 'x', '2031-03-11 09:00-04', 'STAGE ONE', '3055557201', 'T1117-1', 'PENDING',   '3/15/2031', 'HANGAR 16', 'BMW X5',  'Black', 'MAKERS', null),
       (971702, 'x', '2031-03-11 09:30-04', 'STAGE TWO', '3055557202', 'T1117-2', 'DELIVERED', '3/15/2031', 'HANGAR 19', 'Audi Q7', 'White', 'MAKERS', '2031-03-15 15:00-04'),
       (971703, 'x', '2031-03-11 10:00-04', 'STAGE OLD', '3055557203', 'T1117-3', 'ARCHIVED',  '3/15/2031', 'HANGAR 19', 'Kia',     'Gray',  'MAKERS', '2031-03-15 16:00-04'),
       (971704, 'x', '2031-03-11 10:30-04', 'LEGACY',    '3055557204', 'T1117-4', 'DELIVERED', '3/15/2031', 'HANGAR 19', 'Ford',    'Blue',  'MAKERS', '2031-03-15 17:00-04');
create temp table pay_before as select count(*) n from public.payments;
grant select on pay_before to authenticated;

-- ── 1. Structure + permissions (unchanged from 1113) ─────────────────────
select pg_temp.check(not exists (select 1 from pg_indexes where indexname = 'airvalet_tip_records_one_active_cash'), 'one-active-tip-per-ticket rule removed');
select pg_temp.check((select is_nullable from information_schema.columns where table_name = 'airvalet_tip_records' and column_name = 'stage') = 'NO', 'every row has a stage');
select pg_temp.check(not has_table_privilege('authenticated', 'public.airvalet_tip_records', 'insert')
  and not has_table_privilege('authenticated', 'public.airvalet_tip_records', 'update'), 'staff still cannot write the ledger directly');
select pg_temp.check(not has_function_privilege('anon', 'public.airvalet_daily_tips(date)', 'execute')
  and not has_function_privilege('authenticated', 'public.airvalet_tip_log(bigint,text,text,text,text,text)', 'execute'), 'daily tips not for anon; log helper internal');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$select pg_temp.rec(971701, 1000, gen_random_uuid(), 'CHECKIN')$q$), 'TV cannot record a tip');
select pg_temp.check(pg_temp.errs($q$select public.airvalet_daily_tips(date '2031-03-11')$q$), 'TV cannot read DAILY TIPS');
select pg_temp.check((select count(*) from public.airvalet_tip_records) = 0, 'TV reads no ledger rows (RLS)');
select pg_temp.act(null);
select pg_temp.check(pg_temp.errs($q$select public.airvalet_daily_tips(date '2031-03-11')$q$), 'anon cannot read DAILY TIPS');

-- ── 2. CHECK-IN ───────────────────────────────────────────────────────────
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 1000, 'a1117000-0000-4000-8000-000000000001', 'CHECKIN')) = 'OK', 'IPAD records $10 at check-in');
select pg_temp.check((pg_temp.rec(971701, 1000, 'a1117000-0000-4000-8000-000000000001', 'CHECKIN') ->> 'duplicate') = 'true', 'same tap again = same row');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 1000, gen_random_uuid(), 'CHECKIN')) = 'RECENT_SAME', 'second device, same $10 within 2 min: refused');
reset role;
select pg_temp.check((select count(*) from public.airvalet_tip_records where passenger_id = 971701) = 1, 'one row after 3 attempts');
select pg_temp.check((select stage || '|' || source || '|' || business_date::text || '|' || recorded_by from public.airvalet_tip_records where passenger_id = 971701)
  = 'CHECKIN|CHECKIN|2031-03-11|localipad@airvalet.local', 'stage CHECK-IN, check-in day, who = the login');
select pg_temp.check((select tip_in_person_cents is null and tip_received is null from public.passengers where id = 971701), 'check-in tip does not touch the car''s delivery answer');
select pg_temp.check(exists (select 1 from public.activity_log where passenger_id = 971701 and action = 'TIP CASH' and detail like '%At check-in%'), 'ticket history line');
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 550, gen_random_uuid(), 'CHECKIN')) = 'OK', 'a second, different check-in tip ($5.50) is allowed');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 2000, gen_random_uuid(), 'DELIVERY')) = 'NOT_DELIVERED', 'delivery tip on a parked car: refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971702, 1000, gen_random_uuid(), 'CHECKIN')) = 'ALREADY_DELIVERED', 'check-in tip on a delivered car: refused');

-- ── 3. Invalid amounts / input ────────────────────────────────────────────
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 0, gen_random_uuid(), 'CHECKIN')) = 'INVALID', '$0 is never recorded');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, -500, gen_random_uuid(), 'CHECKIN')) = 'INVALID', 'negative refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 100001, gen_random_uuid(), 'CHECKIN')) = 'INVALID', 'over $1,000 refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, null, gen_random_uuid(), 'CHECKIN')) = 'INVALID', 'empty amount = nothing recorded');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 1000, null, 'CHECKIN')) = 'INVALID', 'no client key refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 1000, gen_random_uuid(), 'STRIPE')) = 'INVALID', 'unknown stage refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 1, gen_random_uuid(), 'CHECKIN')) = 'OK', '$0.01 accepted (cents exact)');
select pg_temp.check(pg_temp.res(pg_temp.rec(999999999, 1000, gen_random_uuid(), 'CHECKIN')) = 'NOT_FOUND', 'unknown ticket');

-- ── 4. CHECKOUT + several tips on one ticket ($10 in, $20 out = $30) ──────
reset role;
update public.passengers set status = 'DELIVERED', checkout_date = '2031-03-15 14:00-04' where id = 971701;
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 2000, 'a1117000-0000-4000-8000-000000000002', 'DELIVERY', 'Diego')) = 'OK', '$20 at delivery after $10 at check-in');
reset role;
select pg_temp.check((select stage || '|' || business_date::text || '|' || received_by_name from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-000000000002')
  = 'CHECKOUT|2031-03-15|Diego', 'CHECKOUT row on the delivery day, received by');
select pg_temp.check((select tip_in_person_cents = 2000 and tip_received from public.passengers where id = 971701), 'car mirror = delivery tips only ($20)');
select pg_temp.check((select sum(amount_cents) from public.airvalet_tip_records where passenger_id = 971701 and voided_at is null) = 3551, 'ticket total $35.51 (10 + 5.50 + 0.01 + 20), nothing overwritten');
select pg_temp.act('localmanager');
select pg_temp.check(pg_temp.res(pg_temp.rec(971701, 1500, 'a1117000-0000-4000-8000-000000000003', 'ADDED_LATER')) = 'OK', 'MANAGER adds $15 later (after delivery)');
reset role;
select pg_temp.check((select stage || '|' || business_date::text from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-000000000003') = 'LATER|2031-03-15', 'LATER after delivery counts on the delivery day');
select pg_temp.check((select tip_in_person_cents from public.passengers where id = 971701) = 3500, 'mirror = $20 + $15');

-- ── 5. LATER on a parked car + archived car ───────────────────────────────
reset role;
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator)
values (971705, 'x', '2031-03-11 11:00-04', 'STAGE PARKED', '3055557205', 'T1117-5', 'PENDING', '3/15/2031', 'HANGAR 16', 'Mini', 'Green', 'MAKERS');
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.res(pg_temp.rec(971705, 700, 'a1117000-0000-4000-8000-000000000005', 'ADDED_LATER')) = 'OK', 'LATER on a parked car');
reset role;
select pg_temp.check((select stage || '|' || (business_date = (now() at time zone 'America/New_York')::date)::text from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-000000000005') = 'LATER|true', 'LATER on a parked car = today');
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(pg_temp.rec(971703, 1000, gen_random_uuid(), 'ADDED_LATER')) = 'ARCHIVED', 'archived ticket: staff refused');
select pg_temp.act('localadmin');
select pg_temp.check(pg_temp.res(pg_temp.rec(971703, 1000, gen_random_uuid(), 'ADDED_LATER')) = 'OK', 'archived ticket: ADMIN can add');

-- ── 6. Corrections with audit ─────────────────────────────────────────────
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(public.airvalet_tip_correct((select id from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-000000000001'), 1200, '', gen_random_uuid())) = 'REASON_REQUIRED', 'correction needs a reason');
select pg_temp.check(pg_temp.res(public.airvalet_tip_correct((select id from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-000000000001'), 1200, 'Typed 10, it was 12', 'a1117000-0000-4000-8000-0000000000c1')) = 'OK', 'check-in $10 → $12');
select pg_temp.check((public.airvalet_tip_correct((select id from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-000000000001'), 1200, 'Typed 10, it was 12', 'a1117000-0000-4000-8000-0000000000c1') ->> 'duplicate') = 'true', 'same correction tap again = once');
reset role;
select pg_temp.check((select stage || '|' || source || '|' || amount_cents from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-0000000000c1') = 'CHECKIN|CORRECTION|1200', 'correction keeps the CHECK-IN stage');
select pg_temp.check((select voided_by || '|' || void_reason from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-000000000001') = 'localipad@airvalet.local|Typed 10, it was 12', 'old amount kept with who + why');
select pg_temp.check((select tip_in_person_cents from public.passengers where id = 971701) = 3500, 'check-in correction does not touch the delivery mirror');
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(public.airvalet_tip_correct((select id from public.airvalet_tip_records where client_key = 'a1117000-0000-4000-8000-000000000003'), null, 'Was the same cash as the delivery tip', gen_random_uuid())) = 'OK', 'remove the LATER $15');
reset role;
select pg_temp.check((select tip_in_person_cents = 2000 and tip_received from public.passengers where id = 971701), 'mirror back to $20, still tip received');
select pg_temp.check((select count(*) from public.airvalet_tip_records where passenger_id = 971701) = 6, 'no row ever deleted (5 recorded + 1 correction)');

-- ── 7. Closed day ─────────────────────────────────────────────────────────
insert into public.daily_closing_reports (report_date, closed_at) values ('2031-03-15', now());
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.res(pg_temp.rec(971702, 1000, gen_random_uuid(), 'ADDED_LATER')) = 'DAY_CLOSED', 'closed day: staff cannot add');
select pg_temp.act('localadmin');
select pg_temp.check(pg_temp.res(pg_temp.rec(971702, 1000, 'a1117000-0000-4000-8000-000000000007', 'ADDED_LATER')) = 'OK', 'closed day: ADMIN can add');

-- ── 8. DAILY TIPS + Closing Report input + no double counting ────────────
reset role;
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_checkout_session_id, created_at)
values (971702, 'T1117-2', 4500, 'TIP', 'STRIPE', 'succeeded', 'cs_test_1117_a', '2031-03-15 18:00-04'),
       (971702, 'T1117-2', 2000, 'TIP', 'STRIPE', 'refunded',  'cs_test_1117_b', '2031-03-15 18:05-04');
select pg_temp.act('localiphone');
select pg_temp.check((public.airvalet_daily_tips(date '2031-03-11') -> 'cash' ->> 'cents')::int = 1200 + 550 + 1, '03/11 cash = the check-in tips (corrected amount)');
select pg_temp.check((public.airvalet_daily_tips(date '2031-03-11') -> 'cash' ->> 'checkin_cents')::int = 1751, '03/11 by stage: check-in');
select pg_temp.check((public.airvalet_daily_tips(date '2031-03-15') -> 'cash' ->> 'cents')::int = 2000 + 1000 + 1000, '03/15 cash = delivery $20 + later $10 + archived $10 (removed $15 out)');
select pg_temp.check((public.airvalet_daily_tips(date '2031-03-15') -> 'online' ->> 'cents')::int = 4500, '03/15 online = Stripe succeeded only (refund out)');
select pg_temp.check((public.airvalet_daily_tips(date '2031-03-15') ->> 'total_recorded_cents')::int = 8500, 'Total recorded = cash + online, once each');
select pg_temp.check((select cash_cents from public.airvalet_cash_tips_for_date(date '2031-03-11')) = 1751, 'Closing Report A includes check-in cash');
select pg_temp.check((select tickets from public.airvalet_cash_tips_for_date(date '2031-03-15')) = 3, 'Closing Report counts tickets, not rows');
select pg_temp.act('localmanager');
select pg_temp.check((public.airvalet_daily_tips(date '2031-03-15') ->> 'result') = 'OK', 'MANAGER reads DAILY TIPS');
reset role;
select pg_temp.check((select count(*) from public.payments) = (select n from pay_before) + 2, 'cash tips never create payments (only the 2 test Stripe rows)');

-- ── 9. Old app path (v85/v89 direct write) + guests + pass ───────────────
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(pg_temp.rec(971704, 300, gen_random_uuid(), 'ADDED_LATER')) = 'DAY_CLOSED', 'legacy car on the closed day');
reset role; delete from public.daily_closing_reports where report_date = '2031-03-15';
select pg_temp.act('localipad');
update public.passengers set tip_in_person_cents = 1800 where id = 971704;
reset role;
select pg_temp.check((select count(*) from public.airvalet_tip_records where passenger_id = 971704 and source = 'DELIVERY_LEGACY' and stage = 'CHECKOUT') = 1, 'old app writing the amount = one audited CHECKOUT row');
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.errs($q$update public.passengers set tip_in_person_cents = 900 where id = 971704$q$), 'old app cannot overwrite a recorded amount');
reset role;
select pg_temp.check(((select public.airvalet_guest_visit(p) from public.passengers p where p.id = 971701) ->> 'cash_cents')::int = 1200 + 550 + 1 + 2000, 'Passengers visit card: cash = sum (no error with several tips)');
-- Pass (runner replaces __TOKEN__ with the seed token of 900101): a check-in tip alone never
-- thanks the passenger, and no amount is ever in the pass.
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(pg_temp.rec(900101, 5000, gen_random_uuid(), 'CHECKIN')) = 'OK', 'seed car: $50 at check-in');
reset role;
update public.passengers set status = 'DELIVERED', delivery_type = 'HANGAR', checkout_date = now(), tip_received = null where id = 900101;
select pg_temp.check((public.airvalet_portal_view('__TOKEN__', 'c1117') -> 'pass' ->> 'tip_thanks') = 'false', 'pass: a check-in tip alone does not change the pass');
select pg_temp.check(public.airvalet_portal_view('__TOKEN__', 'c1117')::text !~ '(5000|50\.00|tip_in_person|amount_cents)', 'pass never shows an in-person amount');
select 'ALL 1117 TESTS PASSED';
