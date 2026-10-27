-- LOCAL DB tests for 20261113_airvalet_cash_tips.sql. One transaction, rolled back. Runner:
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' migrations/20261113_airvalet_cash_tips_rollback.sql;
--    sed '/^begin;$/d;/^commit;$/d' migrations/20261113_airvalet_cash_tips.sql;
--    cat tests/portal/sql_cash_tips_1113_tests.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres
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
create function pg_temp.rec(pid bigint, cents int, k uuid, src text default 'DELIVERY', who text default null) returns jsonb language sql as $$
  select public.airvalet_tip_record(pid, cents, k, who, src) $$;
create function pg_temp.res(j jsonb) returns text language sql as $$ select j ->> 'result' $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- Fixed business day far from real data: 2031-03-10 (ET).
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator, checkout_date)
values (971301, 'x', now(), 'CASH ONE', '3055557101', 'T1113-1', 'PENDING',   '3/10/2031', 'HANGAR 16', 'BMW X5', 'Black', 'MAKERS', null),
       (971302, 'x', now(), 'CASH TWO', '3055557102', 'T1113-2', 'DELIVERED', '3/10/2031', 'HANGAR 19', 'Audi Q7', 'White', 'MAKERS', '2031-03-10 15:00-04'),
       (971303, 'x', now(), 'CASH THREE', '3055557103', 'T1113-3', 'DELIVERED', '3/10/2031', 'HANGAR 19', 'Tesla Y', 'Red', 'MAKERS', '2031-03-10 16:00-04'),
       (971304, 'x', now(), 'NO AMOUNT', '3055557104', 'T1113-4', 'DELIVERED', '3/10/2031', 'HANGAR 19', 'Kia', 'Gray', 'MAKERS', '2031-03-10 17:00-04'),
       (971305, 'x', now(), 'LEGACY V85', '3055557105', 'T1113-5', 'PENDING',  '3/10/2031', 'HANGAR 16', 'Ford', 'Blue', 'MAKERS', null);

-- ── 1. Permissions ────────────────────────────────────────────────────────
select pg_temp.check(not has_table_privilege('anon', 'public.airvalet_tip_records', 'select'), 'anon cannot read the tip ledger');
select pg_temp.check(not has_table_privilege('authenticated', 'public.airvalet_tip_records', 'insert')
  and not has_table_privilege('authenticated', 'public.airvalet_tip_records', 'update')
  and not has_table_privilege('authenticated', 'public.airvalet_tip_records', 'delete'), 'staff cannot write the ledger directly (functions only)');
select pg_temp.check(not has_function_privilege('anon', 'public.airvalet_tip_record(bigint,integer,uuid,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.airvalet_tip_correct(bigint,integer,text,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.airvalet_cash_tips_for_date(date)', 'execute'), 'anon cannot call the tip functions');
select pg_temp.check(not has_function_privilege('authenticated', 'public.airvalet_tip_mirror(bigint,integer,boolean,text,text,text,text,text)', 'execute'),
  'the mirror helper is internal');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$ select pg_temp.rec(971302, 1000, gen_random_uuid()) $q$), 'TV_ONLY cannot record a tip');
select pg_temp.act(null);
select pg_temp.check(pg_temp.errs($q$ select public.airvalet_tip_record(971302, 1000, gen_random_uuid(), null, 'DELIVERY') $q$), 'anon cannot record a tip');

-- ── 2. Record ─────────────────────────────────────────────────────────────
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(pg_temp.rec(971301, 1000, gen_random_uuid())) = 'NOT_DELIVERED', 'car not delivered → refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971302, 0, gen_random_uuid())) = 'INVALID', '$0 refused (unknown amount is never $0)');
select pg_temp.check(pg_temp.res(pg_temp.rec(971302, -500, gen_random_uuid())) = 'INVALID', 'negative refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971302, 100001, gen_random_uuid())) = 'INVALID', 'above $1,000 refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971302, 1000, null)) = 'INVALID', 'no client key refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971302, 1000, gen_random_uuid(), 'WHATEVER')) = 'INVALID', 'unknown source refused');
select pg_temp.check(pg_temp.res(pg_temp.rec(971302, 2000, '11111111-1111-1111-1111-111111111111', 'DELIVERY', 'JOAO')) = 'OK', 'delivered car: $20 cash recorded');
select pg_temp.check(pg_temp.rec(971302, 2000, '11111111-1111-1111-1111-111111111111') ->> 'duplicate' = 'true', 'same tap again → same row (duplicate)');
select pg_temp.check(pg_temp.res(pg_temp.rec(971302, 2500, gen_random_uuid())) = 'ALREADY_RECORDED', 'second device, other key → refused (one active cash tip per ticket)');
select pg_temp.check((select count(*) from public.airvalet_tip_records where passenger_id = 971302) = 1, 'three taps → one ledger row');
select pg_temp.check((select recorded_by = 'localipad@airvalet.local' and received_by_name = 'JOAO' and method = 'CASH' and source = 'DELIVERY'
                        and business_date = '2031-03-10' and ticket = 'T1113-2' from public.airvalet_tip_records where passenger_id = 971302),
  'row: who (from the login), received by, cash, delivery day, ticket');
select pg_temp.check(pg_temp.errs($q$ insert into public.airvalet_tip_records (passenger_id, amount_cents, source, business_date, recorded_by) values (971303, 500, 'DELIVERY', '2031-03-10', 'x') $q$),
  'direct insert refused');
select pg_temp.check(pg_temp.errs($q$ update public.airvalet_tip_records set amount_cents = 1 where passenger_id = 971302 $q$), 'direct update refused');
select pg_temp.check(pg_temp.errs($q$ delete from public.airvalet_tip_records where passenger_id = 971302 $q$), 'direct delete refused');
select pg_temp.check(pg_temp.errs($q$ update public.passengers set tip_in_person_cents = 9900 where id = 971302 $q$),
  'changing the amount on the car directly is refused (audit required)');
select pg_temp.check(pg_temp.res(pg_temp.rec(971303, 1500, gen_random_uuid(), 'ADDED_LATER')) = 'OK', 'add later: $15 on another car');
reset role;
select pg_temp.check((select tip_in_person_cents = 2000 and tip_received from public.passengers where id = 971302), 'car mirror = $20, tip received');
select pg_temp.check((select count(*) = 1 from public.activity_log where passenger_id = 971302 and action = 'TIP CASH'
                        and changed_by = 'localipad@airvalet.local' and detail like 'Cash tip recorded: $20.00 | Received by JOAO%'), 'ticket history line');

-- ── 3. v85 app at delivery (direct write) → audited ledger row ────────────
select pg_temp.act('localiphone');
update public.passengers set status = 'DELIVERED', checkout_date = '2031-03-10 18:00-04', tip_received = true, tip_in_person_cents = 700
 where id = 971305 and status <> 'DELIVERED';
reset role;
select pg_temp.check((select source = 'DELIVERY_LEGACY' and amount_cents = 700 and recorded_by = 'localiphone@airvalet.local' and business_date = '2031-03-10'
                        from public.airvalet_tip_records where passenger_id = 971305), 'v85 delivery with an amount → ledger row (legacy, who = login)');

-- ── 4. Correct ────────────────────────────────────────────────────────────
select pg_temp.act('localipad');
create temp table t_ids as select id from public.airvalet_tip_records where passenger_id = 971302;
grant select on t_ids to authenticated;
select pg_temp.check(public.airvalet_tip_correct((select id from t_ids), 2500, '', gen_random_uuid()) ->> 'result' = 'REASON_REQUIRED', 'correction needs a reason');
select pg_temp.check(public.airvalet_tip_correct((select id from t_ids), -1, 'typo', gen_random_uuid()) ->> 'result' = 'INVALID', 'correction to a negative refused');
select pg_temp.check(public.airvalet_tip_correct((select id from t_ids), 2000, 'same', gen_random_uuid()) ->> 'result' = 'UNCHANGED', 'same amount → unchanged');
select pg_temp.check(public.airvalet_tip_correct((select id from t_ids), 2500, 'Typed 20, it was 25', '22222222-2222-2222-2222-222222222222') ->> 'result' = 'OK', '$20 → $25 corrected');
select pg_temp.check(public.airvalet_tip_correct((select id from t_ids), 2500, 'Typed 20, it was 25', '22222222-2222-2222-2222-222222222222') ->> 'duplicate' = 'true', 'same correction tapped twice → once');
select pg_temp.check(public.airvalet_tip_correct((select id from t_ids), 3000, 'again', gen_random_uuid()) ->> 'result' = 'ALREADY_CORRECTED', 'old row cannot be corrected twice');
reset role;
select pg_temp.check((select count(*) = 2 and count(*) filter (where voided_at is null) = 1
                        and bool_and(case when voided_at is null then amount_cents = 2500 and source = 'CORRECTION' and supersedes_id = (select id from t_ids)
                                          else amount_cents = 2000 and voided_by = 'localipad@airvalet.local' and void_reason = 'Typed 20, it was 25' end)
                        from public.airvalet_tip_records where passenger_id = 971302), 'old row kept + voided (who/why), new row supersedes it');
select pg_temp.check((select tip_in_person_cents = 2500 from public.passengers where id = 971302), 'car mirror follows the correction');
select pg_temp.check((select count(*) = 1 from public.activity_log where passenger_id = 971302 and action = 'TIP CASH CORRECTED'
                        and detail = 'Cash tip corrected: $20.00 → $25.00 | Reason: Typed 20, it was 25'), 'correction in the ticket history');
-- remove (wrong car)
select pg_temp.act('localmanager');
select pg_temp.check(public.airvalet_tip_correct((select id from public.airvalet_tip_records where passenger_id = 971305 and voided_at is null), null, 'Wrong car', gen_random_uuid()) ->> 'result' = 'OK',
  'manager removes a tip recorded on the wrong car');
reset role;
select pg_temp.check((select tip_in_person_cents is null and tip_received is null from public.passengers where id = 971305)
  and (select count(*) = 1 and bool_and(voided_at is not null) from public.airvalet_tip_records where passenger_id = 971305), 'removed: row voided (kept), car back to unknown');

-- tip received, amount unknown → never $0
update public.passengers set tip_received = true where id = 971304;
select pg_temp.check((select count(*) = 0 from public.airvalet_tip_records where passenger_id = 971304), 'Yes without an amount → no $0 row');

-- ── 5. Closing reconciliation (server-side A / B / C) ─────────────────────
-- A on 2031-03-10 = $25 (971302) + $15 (971303) = $40; 971305 voided; 971304 = tip without amount.
select pg_temp.act('localipad');
select pg_temp.check((select cash_cents = 4000 and tickets = 2 and no_amount = 1 from public.airvalet_cash_tips_for_date('2031-03-10')), 'A = $40 on 2 tickets, 1 car tip without amount');
insert into public.daily_closing_reports (report_date, stripe_tips_cents, other_tips_cents, total_tips_cents, cash_counted_cents, ticket_cash_tips_cents)
values ('2031-03-10', 1000, 99999, 99999, 4000, 1);
select pg_temp.check((select ticket_cash_tips_cents = 4000 and other_tips_cents = 0 and cash_difference_cents = 0 and cash_reconciliation = 'RECONCILED'
                        and total_tips_cents = 5000 and cash_tickets_no_amount = 1 from public.daily_closing_reports where report_date = '2031-03-10'),
  'B = A → reconciled; values typed by the app are ignored; total = Stripe + B ($10 + $40)');
update public.daily_closing_reports set cash_counted_cents = 6500 where report_date = '2031-03-10';
select pg_temp.check((select other_tips_cents = 2500 and cash_difference_cents = 2500 and cash_reconciliation = 'OTHER_TIPS' and total_tips_cents = 7500
                        from public.daily_closing_reports where report_date = '2031-03-10'), 'B > A → Other Tips = $25; total = $10 + $65 (never A + B = $105)');
update public.daily_closing_reports set cash_counted_cents = 3000 where report_date = '2031-03-10';
select pg_temp.check((select other_tips_cents = 0 and cash_difference_cents = -1000 and cash_reconciliation = 'SHORT' and total_tips_cents = 4000
                        from public.daily_closing_reports where report_date = '2031-03-10'), 'B < A → no negative Other Tips; difference −$10');
select pg_temp.check(pg_temp.errs($q$ update public.daily_closing_reports set closed_at = now() where report_date = '2031-03-10' $q$), 'short day cannot close without the review');
select pg_temp.check(pg_temp.errs($q$ update public.daily_closing_reports set cash_counted_cents = -1 where report_date = '2031-03-10' $q$), 'negative cash counted refused');
update public.daily_closing_reports set cash_review_ack = true, closed_at = now() where report_date = '2031-03-10';
select pg_temp.check((select closed_at is not null and cash_review_ack from public.daily_closing_reports where report_date = '2031-03-10'), 'short day closes after the review');
select pg_temp.check(pg_temp.errs($q$ update public.daily_closing_reports set cash_counted_cents = 4000 where report_date = '2031-03-10' $q$), 'closed: cash counted locked');
select pg_temp.check(pg_temp.errs($q$ update public.daily_closing_reports set cash_review_ack = false where report_date = '2031-03-10' $q$), 'closed: review flag locked');
-- day closed → only ADMIN changes its tips
select pg_temp.check(public.airvalet_tip_correct((select id from public.airvalet_tip_records where passenger_id = 971303 and voided_at is null), 1800, 'late fix', gen_random_uuid()) ->> 'result' = 'DAY_CLOSED',
  'closed day: staff correction refused');
update public.passengers set tip_received = true where id = 971304;
select pg_temp.check(pg_temp.res(pg_temp.rec(971304, 500, gen_random_uuid(), 'ADDED_LATER')) = 'DAY_CLOSED', 'closed day: staff add refused');
select pg_temp.act('localadmin');
select pg_temp.check(public.airvalet_tip_correct((select id from public.airvalet_tip_records where passenger_id = 971303 and voided_at is null), 1800, 'late fix', gen_random_uuid()) ->> 'result' = 'OK',
  'closed day: ADMIN correction allowed (audited)');
select pg_temp.check((select ticket_cash_tips_cents = 4000 from public.daily_closing_reports where report_date = '2031-03-10'), 'closed report keeps its snapshot');
-- old flow (no cash counted) unchanged
select pg_temp.act('localiphone');
insert into public.daily_closing_reports (report_date, stripe_tips_cents, other_tips_cents, total_tips_cents) values ('2031-03-11', 500, 1200, 1700);
select pg_temp.check((select other_tips_cents = 1200 and total_tips_cents = 1700 and cash_reconciliation is null and ticket_cash_tips_cents is null
                        from public.daily_closing_reports where report_date = '2031-03-11'), 'old app (no cash counted): typed Other Tips kept, nothing reconciled');
-- zero cash day
insert into public.daily_closing_reports (report_date, stripe_tips_cents, cash_counted_cents, closed_at) values ('2031-03-12', 0, 0, now());
select pg_temp.check((select cash_reconciliation = 'RECONCILED' and other_tips_cents = 0 and total_tips_cents = 0 from public.daily_closing_reports where report_date = '2031-03-12'),
  'no cash, nothing on tickets → reconciled at $0');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$ select * from public.airvalet_cash_tips_for_date('2031-03-10') $q$), 'TV_ONLY cannot read the cash totals');
select pg_temp.check((select count(*) = 0 from public.airvalet_tip_records), 'TV_ONLY sees no ledger rows');

-- ── 6. Valet Pass: thank-you flag, never the amount ───────────────────────
-- (the pass link of a delivered car lives 7 days from the real delivery: a car delivered today)
reset role;
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator, checkout_date, deldate, delivery_type, tip_received, tip_in_person_cents)
values (971306, 'x', now(), 'PASS THANKS', '3055557106', 'T1113-6', 'DELIVERED', to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'HANGAR 19', 'BMW', 'Black', 'MAKERS',
        now(), to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'NORMAL', true, null);
select pg_temp.act('localipad');
select pg_temp.check(pg_temp.res(pg_temp.rec(971306, 2500, gen_random_uuid())) = 'OK', 'pass car: $25 recorded');
reset role;
insert into public.airvalet_sms_devices (key_hash, label, status, decided_at)
values (public.airvalet_sms_device_key_hash('t1113_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), 'T1113 iPad', 'approved', now());
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
select p.id, public.airvalet_sms_normalize_phone(p.phone), (select d.id from public.airvalet_sms_devices d where d.label = 'T1113 iPad'), gen_random_uuid()
  from public.passengers p where p.id in (971301, 971306);
create temp table t_tok as select 971306::bigint pid, public.airvalet_pass_mint(971306) tok
                 union all select 971301, public.airvalet_pass_mint(971301);
update public.airvalet_portal_settings set portal_enabled = true;
select pg_temp.check((select public.airvalet_portal_view(tok, 'c1113a') -> 'pass' ->> 'tip_thanks' from t_tok where pid = 971306) = 'true', 'pass: tip received → tip_thanks true');
select pg_temp.check((select public.airvalet_portal_view(tok, 'c1113b') -> 'pass' ->> 'tip_thanks' from t_tok where pid = 971301) = 'false', 'pass: not delivered → false');
select pg_temp.check((select public.airvalet_portal_view(tok, 'c1113c')::text !~ '(2500|25\.0|tip_in_person|amount_cents)' from t_tok where pid = 971306), 'pass never carries the amount');

-- Stripe gratuity confirmed for the ticket → thanked too; refunded / another ticket's → not.
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator, checkout_date, deldate, delivery_type)
values (971307, 'x', now(), 'STRIPE PAID', '3055557107', 'T1113-7', 'DELIVERED', to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'HANGAR 19', 'Audi', 'White', 'MAKERS',
        now(), to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'NORMAL');
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
select 971307, public.airvalet_sms_normalize_phone('3055557107'), (select d.id from public.airvalet_sms_devices d where d.label = 'T1113 iPad'), gen_random_uuid();
create temp table t_tok7 as select public.airvalet_pass_mint(971307) tok;
select pg_temp.check((select public.airvalet_portal_view(tok, 'c1113d') -> 'pass' ->> 'tip_thanks' from t_tok7) = 'false', 'pass: delivered, no tip → false (gratuity card stays)');
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id) values (971307, 'T1113-7', 1000, 'TIP', 'STRIPE', 'refunded', 'evt_t1113_a');
select pg_temp.check((select public.airvalet_portal_view(tok, 'c1113e') -> 'pass' ->> 'tip_thanks' from t_tok7) = 'false', 'pass: refunded Stripe tip → not thanked');
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id) values (971306, 'T1113-6', 2000, 'TIP', 'STRIPE', 'succeeded', 'evt_t1113_b');
select pg_temp.check((select public.airvalet_portal_view(tok, 'c1113f') -> 'pass' ->> 'tip_thanks' from t_tok7) = 'false', 'pass: another ticket''s Stripe tip → not thanked');
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id) values (971307, 'T1113-7', 1500, 'TIP', 'STRIPE', 'succeeded', 'evt_t1113_c');
select pg_temp.check((select public.airvalet_portal_view(tok, 'c1113g') -> 'pass' ->> 'tip_thanks' from t_tok7) = 'true', 'pass: Stripe tip confirmed for this ticket → thanked');
select pg_temp.check((select public.airvalet_portal_view(tok, 'c1113h')::text !~ '(1500|15\.0|amount_cents)' from t_tok7), 'pass: Stripe amount never shown');
select pg_temp.check((select (jsonb_typeof(public.airvalet_portal_view(tok, 'c1113i') -> 'pass' -> 'gratuity_checkout') = 'object')
                              = (s.gratuity_checkout_enabled or 971307 = any (s.gratuity_checkout_passenger_ids))
                        from t_tok7, public.airvalet_portal_settings s), 'pass: dynamic Checkout field untouched by the thank-you');

select 'all 1113 checks passed';
