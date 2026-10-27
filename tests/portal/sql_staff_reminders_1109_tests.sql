-- LOCAL DB tests for 20261109_airvalet_staff_reminders.sql, with a fixed clock
-- (America/New_York). One transaction, rolled back. Runner:
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;';
--    for m in 20261108_airvalet_staff_alerts 20261109_airvalet_staff_reminders; do sed '/^begin;$/d;/^commit;$/d' migrations/$m.sql; done;
--    cat tests/portal/sql_staff_reminders_1109_tests.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.ny(p text) returns timestamptz language sql as $$ select (p::timestamp at time zone 'America/New_York') $$;
-- Codes due (for our test tickets only) at a given New York time, before any claim.
create function pg_temp.due(p_now text) returns text[] language sql as $$
  select coalesce(array_agg(r.code || ':' || coalesce(r.ticket, 'ALL') order by r.code, r.ticket), '{}')
    from public.airvalet_staff_reminders(pg_temp.ny(p_now)) r
   where r.due_at <= pg_temp.ny(p_now) and pg_temp.ny(p_now) < r.expires_at
     and (r.ticket like 'RT-%' or r.ticket is null)
$$;
create function pg_temp.claim(p_now text) returns text[] language sql as $$
  select coalesce(array_agg((j->>'code') || ':' || coalesce(j->>'ticket', 'ALL') order by j->>'code', j->>'ticket'), '{}')
    from jsonb_array_elements(public.airvalet_staff_reminders_claim(pg_temp.ny(p_now))) j
   where coalesce(j->>'ticket', 'RT-') like 'RT-%'
$$;
create function pg_temp.body(p_code text, p_now text) returns text language sql as $$
  select r.body from public.airvalet_staff_reminders(pg_temp.ny(p_now)) r where r.code = p_code and r.ticket is null limit 1
$$;

-- Only our test rows count: park every other active car out of the way (rolled back).
update public.passengers set status = 'ARCHIVED' where status in ('PENDING', 'NO DATE') or (status = 'DELIVERED' and delivery_type = 'CUSTOMS');
delete from public.airvalet_notify_log where dedupe_key like 'REM:%';
-- Fixed start day (every-3-days cadence counts from it) and MOVE off, as after the deploy.
update public.airvalet_staff_reminder_config set since = pg_temp.ny('2026-10-26 00:00'), move_lead_min = null;
select pg_temp.check((select count(*) from public.airvalet_staff_reminder_config) = 1, 'one settings row (start cutoff + MOVE lead time)');

-- ── Parsers (same rules as the staff app) ──
select pg_temp.check(public.airvalet_ret_date('11/7/2026') = date '2026-11-07' and public.airvalet_ret_date('2026-11-07') = date '2026-11-07'
  and public.airvalet_ret_date('') is null and public.airvalet_ret_date('soon') is null and public.airvalet_ret_date('13/45/2026') is null, 'return date parser (M/D/YYYY, ISO; invalid → none)');
select pg_temp.check(public.airvalet_wb_eta_min('18:30') = 1110 and public.airvalet_wb_eta_min('00:00') = 0 and public.airvalet_wb_eta_min('6:30') is null
  and public.airvalet_wb_eta_min('') is null, 'Welcome Back time: strict HH:MM (00:00 allowed), as isValidDepTime');
select pg_temp.check(public.airvalet_customs_eta_min('15:00') = 900 and public.airvalet_customs_eta_min('3:00 PM') = 900 and public.airvalet_customs_eta_min('00:00') is null
  and public.airvalet_customs_eta_min('12:00 AM') is null and public.airvalet_customs_eta_min('NO ETA') is null, 'Customs time: as getValidCustomsEtaMinutes');
select pg_temp.check(public.airvalet_return_operator_of(null, false, 'A-1101-1') = 'ASCEND' and public.airvalet_return_operator_of(null, true, '1101-1') = 'OTHER'
  and public.airvalet_return_operator_of(null, false, '1101-1') = 'MAKERS' and public.airvalet_return_operator_of('ASCEND', false, '1101-1') = 'ASCEND', 'returnOperator rules');

-- ── Car wash ──
insert into public.passengers (id, name, phone, ticket, status, ret, loc, carwash_status, checkin_date) values
  (991001, 'CW DATE', '3055551001', 'RT-CW1', 'PENDING', '11/10/2026', 'HANGAR 19', 'CARWASH', pg_temp.ny('2026-11-01 10:00')),
  (991002, 'CW FAR', '3055551002', 'RT-CW2', 'PENDING', '11/20/2026', 'HANGAR 19', 'CARWASH', pg_temp.ny('2026-11-01 10:00')),
  (991003, 'CW NODATE', '3055551003', 'RT-CW3', 'NO DATE', '', 'HANGAR 19', 'CARWASH', pg_temp.ny('2026-11-01 10:00')),
  (991004, 'CW PRICE', '3055551004', 'RT-CW4', 'PENDING', '11/10/2026', 'HANGAR 19', 'SEND_PRICE', pg_temp.ny('2026-11-01 10:00'));
select pg_temp.check(not ('CW_D3:RT-CW1' = any (pg_temp.due('2026-11-07 08:59'))), 'car wash 3 days before: not before 09:00');
select pg_temp.check((select category from public.airvalet_staff_reminders(pg_temp.ny('2026-11-07 09:00')) where code = 'CW_D3' and ticket = 'RT-CW1') = 'CARWASH_ADMIN', 'car wash 3 days before: ADMIN phones only (owner 10/26)');
select pg_temp.check('CW_D3:RT-CW1' = any (pg_temp.claim('2026-11-07 09:00')), 'car wash 3 days before: 09:00');
select pg_temp.check(not ('CW_D3:RT-CW1' = any (pg_temp.claim('2026-11-07 09:01'))), 'never twice');
select pg_temp.check((select bool_and(not (c like '%RT-CW4')) from unnest(pg_temp.due('2026-11-07 09:00')) c), 'SEND_PRICE is not a car wash reminder');
select pg_temp.check(not exists (select 1 from unnest(pg_temp.due('2026-11-08 09:30')) c where c like 'CW_%:RT-CW1'), '2 days before: nothing (plan is 3 and 1)');
select pg_temp.check((select category from public.airvalet_staff_reminders(pg_temp.ny('2026-11-09 09:00')) where code = 'CW_D1' and ticket = 'RT-CW1') = 'CARWASH', 'car wash 1 day before: ADMIN + team devices');
select pg_temp.check('CW_D1:RT-CW1' = any (pg_temp.claim('2026-11-09 09:00')), 'car wash 1 day before: 09:00');
select pg_temp.check(not ('CW_DAY:RT-CW1' = any (pg_temp.due('2026-11-10 07:59'))), 'return day: not before 08:00');
select pg_temp.check('CW_DAY:RT-CW1' = any (pg_temp.claim('2026-11-10 08:00')), 'return day: 08:00');
select pg_temp.check(not ('CW_DAY:RT-CW1' = any (pg_temp.claim('2026-11-10 09:59'))), 'return day: nothing new before 10:00');
select pg_temp.check('CW_DAY:RT-CW1' = any (pg_temp.claim('2026-11-10 10:00')), 'return day: again at 10:00 (every 2 h)');
update public.passengers set carwash_status = 'WASHED' where id = 991001;
select pg_temp.check(not ('CW_DAY:RT-CW1' = any (pg_temp.claim('2026-11-10 12:00'))), 'marked WASHED → stops');
update public.passengers set carwash_status = 'CARWASH', status = 'DELIVERED' where id = 991001;
select pg_temp.check(not ('CW_DAY:RT-CW1' = any (pg_temp.claim('2026-11-10 14:00'))), 'delivered → stops');
-- every 3 days (cadence from 2026-10-26): 11-07 yes (12 days), 11-08 no, 11-10 yes (15 days)
select pg_temp.check('CW_E3:RT-CW2' = any (pg_temp.due('2026-11-07 09:00')) and 'CW_E3:RT-CW3' = any (pg_temp.due('2026-11-07 09:00')), 'car wash pending, return far or not set: every 3 days at 09:00');
select pg_temp.check(not exists (select 1 from unnest(pg_temp.due('2026-11-08 09:00')) c where c like 'CW_E3%'), '… not on the days in between');
select pg_temp.check(not ('CW_E3:RT-CW2' = any (pg_temp.due('2026-11-17 09:00'))) and 'CW_D3:RT-CW2' = any (pg_temp.due('2026-11-17 09:00')), 'once 3 days away, the 3-day plan takes over (no double)');

-- ── Customs (gratuity link / Welcome Back) ──
insert into public.passengers (id, name, phone, ticket, status, ret, loc, delivery_type, checkout_date, departure_time, customs_welcome_sent, customs_gratuity_sent, customs_gratuity_dismissed) values
  (991011, 'CU GRAT', '3055551011', 'RT-CU1', 'DELIVERED', '11/7/2026', 'CUSTOMS', 'CUSTOMS', pg_temp.ny('2026-11-07 14:00'), '15:00', true, false, false),
  (991012, 'CU WB', '3055551012', 'RT-CU2', 'DELIVERED', '11/7/2026', 'CUSTOMS', 'CUSTOMS', pg_temp.ny('2026-11-07 14:00'), '15:00', false, false, false),
  (991013, 'CU NOETA', '3055551013', 'RT-CU3', 'DELIVERED', '11/7/2026', 'CUSTOMS', 'CUSTOMS', pg_temp.ny('2026-11-07 14:00'), '00:00', true, false, false),
  (991014, 'CU OLD', '3055551014', 'RT-CU4', 'DELIVERED', '7/1/2026', 'CUSTOMS', 'CUSTOMS', pg_temp.ny('2026-07-01 14:00'), '15:00', false, false, false);
select pg_temp.check(not ('CUSTOMS_WB:RT-CU2' = any (pg_temp.due('2026-11-07 14:04'))) and 'CUSTOMS_WB:RT-CU2' = any (pg_temp.claim('2026-11-07 14:05')), 'Customs Welcome Back: delivery + 5 min');
select pg_temp.check(not ('GRATUITY:RT-CU1' = any (pg_temp.due('2026-11-07 15:09'))) and 'GRATUITY:RT-CU1' = any (pg_temp.claim('2026-11-07 15:10')), 'gratuity link: ETA + 10 min');
select pg_temp.check(not exists (select 1 from unnest(pg_temp.due('2026-11-07 15:30')) c where c like '%RT-CU3'), 'gratuity: 00:00 is not an ETA (as the app)');
update public.passengers set customs_gratuity_sent = true where id = 991011;
select pg_temp.check(not exists (select 1 from public.airvalet_staff_reminders(pg_temp.ny('2026-11-07 16:00')) r where r.ticket = 'RT-CU1'), 'gratuity sent → reminder gone');
select pg_temp.check(not ('CUSTOMS_WB:RT-CU2' = any (pg_temp.due('2026-11-07 20:01'))), 'Customs Welcome Back: expires after 6 h');
update public.passengers set customs_welcome_sent = true where id = 991012;
select pg_temp.check(not exists (select 1 from public.airvalet_staff_reminders(pg_temp.ny('2026-11-07 14:30')) r where r.code = 'CUSTOMS_WB' and r.ticket = 'RT-CU2'), 'done: Customs Welcome Back sent → reminder gone');
update public.passengers set customs_gratuity_dismissed = true where id = 991012;
select pg_temp.check(not exists (select 1 from public.airvalet_staff_reminders(pg_temp.ny('2026-11-07 15:30')) r where r.ticket = 'RT-CU2'), 'done: gratuity dismissed → reminder gone');
select pg_temp.check(not exists (select 1 from public.airvalet_staff_reminders(pg_temp.ny('2026-07-01 14:30')) r where r.ticket = 'RT-CU4'), 'old Customs deliveries (more than 3 days) never alert');

-- ── Hangar 19 Welcome Back, move the car (ETA), changed time / date re-arms ──
insert into public.passengers (id, name, phone, ticket, status, ret, loc, departure_time, return_operator, checkin_date) values
  (991021, 'WB H19', '3055551021', 'RT-WB1', 'PENDING', '11/7/2026', 'HANGAR 18', '18:30', 'MAKERS', pg_temp.ny('2026-11-01 10:00')),
  (991022, 'WB ASC', '3055551022', 'A-RT-WB2', 'PENDING', '11/7/2026', 'CUSTOMS', '18:30', null, pg_temp.ny('2026-11-01 10:00'));
update public.passengers set ticket = 'RT-WB2' where id = 991022;   -- ticket shown in tests; operator stays ASCEND via return_operator below
update public.passengers set return_operator = 'ASCEND' where id = 991022;
select pg_temp.check(not exists (select 1 from public.airvalet_staff_reminders(pg_temp.ny('2026-11-07 18:20')) r where r.code = 'MOVE'), 'MOVE is off until the owner sets the lead time (no fixed 60 min)');
update public.airvalet_staff_reminder_config set move_lead_min = 45;
select pg_temp.check(not ('MOVE:RT-WB1' = any (pg_temp.due('2026-11-07 17:44'))) and 'MOVE:RT-WB1' = any (pg_temp.due('2026-11-07 17:45')), 'MOVE uses the owner lead time (45 min → 17:45 for 18:30)');
update public.airvalet_staff_reminder_config set move_lead_min = 60;
select pg_temp.check(not ('MOVE:RT-WB1' = any (pg_temp.due('2026-11-07 17:29'))) and 'MOVE:RT-WB1' = any (pg_temp.claim('2026-11-07 17:30')), 'move the car: ETA − lead (60 here) (HANGAR 18 → Hangar 19)');
select pg_temp.check(not ('H19_WB:RT-WB1' = any (pg_temp.due('2026-11-07 17:59'))) and 'H19_WB:RT-WB1' = any (pg_temp.claim('2026-11-07 18:00')), 'Hangar 19 Welcome Back: ETA − 30 min');
select pg_temp.check((select r.body from public.airvalet_staff_reminders(pg_temp.ny('2026-11-07 18:00')) r where r.code = 'H19_WB' and r.ticket = 'RT-WB1') = 'Send Welcome Back: RT-WB1 lands 6:30 PM', 'Welcome Back text says the landing time');
select pg_temp.check(not exists (select 1 from unnest(pg_temp.due('2026-11-07 18:00')) c where c = 'H19_WB:RT-WB2'), 'Ascend return: no Hangar 19 Welcome Back');
update public.passengers set departure_time = '19:30' where id = 991021;
select pg_temp.check(pg_temp.claim('2026-11-07 19:00') @> array['H19_WB:RT-WB1', 'MOVE:RT-WB1'], 'changed landing time → reminders re-armed for the new time');
update public.passengers set ret = '11/8/2026' where id = 991021;
select pg_temp.check(not exists (select 1 from unnest(pg_temp.due('2026-11-07 19:10')) c where c like '%:RT-WB1'), 'return moved to tomorrow → nothing today');
update public.passengers set ret = '11/7/2026', loc = 'HANGAR 19' where id = 991021;
select pg_temp.check(not exists (select 1 from unnest(pg_temp.due('2026-11-07 19:10')) c where c = 'MOVE:RT-WB1') and 'H19_WB:RT-WB1' = any (pg_temp.due('2026-11-07 19:10')), 'done: car already at Hangar 19 → MOVE gone, Welcome Back still due');
update public.passengers set welcome_back_sent_at = now() where id = 991021;
select pg_temp.check(not exists (select 1 from unnest(pg_temp.due('2026-11-07 19:10')) c where c like '%:RT-WB1'), 'car at Hangar 19 + Welcome Back sent → nothing');
update public.passengers set delivery_at_customs = true where id = 991021;
select pg_temp.check((select r.body like 'Take RT-WB1 to Customs%' from public.airvalet_staff_reminders(pg_temp.ny('2026-11-07 18:40')) r where r.code = 'MOVE' and r.ticket = 'RT-WB1'), 'Customs exception approved → "Take … to Customs"');

-- ── Same flight: one group, one alert (prod 10/26: three cars landing 5:02 PM) ──
insert into public.passengers (id, name, phone, ticket, status, ret, loc, departure_time, return_operator, checkin_date) values
  (991061, 'FL A', '3055551061', 'RT-FL1', 'PENDING', '11/9/2026', 'HANGAR 19', '17:02', 'MAKERS', pg_temp.ny('2026-11-01 10:00')),
  (991062, 'FL B', '3055551062', 'RT-FL2', 'PENDING', '11/9/2026', 'HANGAR 18', '17:02', 'MAKERS', pg_temp.ny('2026-11-01 10:00')),
  (991063, 'FL C', '3055551063', 'RT-FL3', 'PENDING', '11/9/2026', 'HANGAR 19', '17:02', 'MAKERS', pg_temp.ny('2026-11-01 10:00')),
  (991064, 'FL D', '3055551064', 'RT-FL4', 'PENDING', '11/9/2026', 'HANGAR 19', '19:15', 'MAKERS', pg_temp.ny('2026-11-01 10:00'));
create temp table fl as select j from jsonb_array_elements(public.airvalet_staff_reminders_claim(pg_temp.ny('2026-11-09 16:32'))) j where j->>'code' = 'H19_WB';
select pg_temp.check((select count(*) from fl) = 3 and (select count(distinct j->>'grp') from fl) = 1 and (select count(distinct j->>'key') from fl) = 3
  and (select min(j->>'gtext') from fl) = 'Send Welcome Back, lands 5:02 PM: {t}', 'same flight: 3 Welcome Back reminders share one group (one alert), each audited');
select pg_temp.check(not exists (select 1 from fl where j->>'ticket' = 'RT-FL4'), 'another flight (7:15 PM) is not mixed in');
update public.passengers set status = 'DELIVERED' where id between 991061 and 991064;

-- ── Check-in without a hangar ──
insert into public.passengers (id, name, phone, ticket, status, ret, loc, checkin_date) values
  (991031, 'NO LOC', '3055551031', 'RT-NL1', 'PENDING', '11/12/2026', '', pg_temp.ny('2026-11-07 10:00')),
  (991032, 'NO LOC OLD', '3055551032', 'RT-NL2', 'PENDING', '11/12/2026', '', pg_temp.ny('2026-11-01 10:00'));
select pg_temp.check(not ('NO_HANGAR:RT-NL1' = any (pg_temp.due('2026-11-07 10:29'))) and 'NO_HANGAR:RT-NL1' = any (pg_temp.claim('2026-11-07 10:30')), 'no hangar: check-in + 30 min');
select pg_temp.check(not exists (select 1 from unnest(pg_temp.due('2026-11-07 10:30')) c where c = 'NO_HANGAR:RT-NL2'), 'no hangar: only for check-ins of the last 24 h');
update public.passengers set loc = 'HANGAR 16' where id = 991031;
select pg_temp.check(not exists (select 1 from public.airvalet_staff_reminders(pg_temp.ny('2026-11-07 11:00')) r where r.ticket = 'RT-NL1'), 'done: hangar set → reminder gone');

-- ── Daily summaries ──
insert into public.passengers (id, name, phone, ticket, status, ret, loc, departure_time, checkin_date) values
  (991041, 'TMRW', '3055551041', 'RT-TM1', 'PENDING', '11/8/2026', 'HANGAR 19', '', pg_temp.ny('2026-11-01 10:00')),
  (991042, 'TMRW T', '3055551042', 'RT-TM2', 'PENDING', '11/8/2026', 'HANGAR 19', '09:00', pg_temp.ny('2026-11-01 10:00')),
  (991043, 'LATE', '3055551043', 'RT-OD1', 'PENDING', '11/2/2026', 'HANGAR 19', '', pg_temp.ny('2026-11-01 10:00')),
  (991044, 'NODATE', '3055551044', 'RT-ND1', 'NO DATE', '', 'HANGAR 19', '', pg_temp.ny('2026-11-01 10:00'));
select pg_temp.check(not ('TMRW_NO_TIME:ALL' = any (pg_temp.due('2026-11-07 17:59'))) and pg_temp.body('TMRW_NO_TIME', '2026-11-07 18:00') like '%RT-TM1%'
  and pg_temp.body('TMRW_NO_TIME', '2026-11-07 18:00') not like '%RT-TM2%', 'tomorrow without a time: one summary at 18:00 (cars with a time left out)');
select pg_temp.check(not ('OVERDUE:ALL' = any (pg_temp.due('2026-11-07 07:59'))) and pg_temp.body('OVERDUE', '2026-11-07 08:00') like '%RT-OD1%'
  and pg_temp.body('OVERDUE', '2026-11-07 08:00') not like '%RT-ND1%', 'overdue returns: one summary at 08:00 (NO DATE not counted)');
select pg_temp.check(pg_temp.body('NODATE_ADMIN', '2026-11-08 09:00') like '%RT-ND1%' and pg_temp.body('NODATE_ADMIN', '2026-11-08 09:00') like '%RT-CW3%', 'no return date: daily summary at 09:00');
select pg_temp.check(pg_temp.body('FOLLOWUP_E3', '2026-11-07 09:00') like '%RT-OD1%' and pg_temp.body('FOLLOWUP_E3', '2026-11-07 09:00') like '%RT-ND1%'
  and pg_temp.body('FOLLOWUP_E3', '2026-11-08 09:00') is null, 'return follow-up: summary every 3 days (TV follow-up list)');
select pg_temp.check('OVERDUE:ALL' = any (pg_temp.claim('2026-11-07 08:00')) and not ('OVERDUE:ALL' = any (pg_temp.claim('2026-11-07 08:30'))), 'a summary is sent once a day');
-- 9-day scan (start day 10/26): every 3 days = 11/01, 11/04, 11/07 for both car wash pending and Return Follow-Up
select pg_temp.check((select array_agg(to_char(d, 'MM/DD') order by d) from generate_series(date '2026-11-01', date '2026-11-09', interval '1 day') g(d)
                       where 'CW_E3:RT-CW3' = any (pg_temp.due(to_char(d, 'YYYY-MM-DD') || ' 09:00'))) = array['11/01', '11/04', '11/07']
  and (select array_agg(to_char(d, 'MM/DD') order by d) from generate_series(date '2026-11-01', date '2026-11-09', interval '1 day') g(d)
                       where 'FOLLOWUP_E3:ALL' = any (pg_temp.due(to_char(d, 'YYYY-MM-DD') || ' 09:00'))) = array['11/01', '11/04', '11/07'],
  '3-day cadence: car wash pending and Return Follow-Up fire on 11/01, 11/04, 11/07 only');
update public.passengers set status = 'PENDING', ret = '11/20/2026' where id = 991044;
select pg_temp.check(pg_temp.body('NODATE_ADMIN', '2026-11-08 09:00') not like '%RT-ND1%', 'done: return date set → out of the "no return date" summary');

-- ── Quiet hours 22:00–06:00; what is still valid goes out at 06:00 ──
insert into public.passengers (id, name, phone, ticket, status, ret, loc, checkin_date) values
  (991051, 'NIGHT', '3055551051', 'RT-NT1', 'PENDING', '11/12/2026', '', pg_temp.ny('2026-11-07 21:50'));
select pg_temp.check('NO_HANGAR:RT-NT1' = any (pg_temp.due('2026-11-07 22:20')) and pg_temp.claim('2026-11-07 22:20') = '{}', 'quiet hours: due but nothing sent at 22:20');
select pg_temp.check(pg_temp.claim('2026-11-08 05:59') = '{}', 'quiet hours: nothing at 05:59');
select pg_temp.check('NO_HANGAR:RT-NT1' = any (pg_temp.claim('2026-11-08 06:00')), 'at 06:00 the reminder still valid goes out');

-- ── Start cutoff (deploy): nothing due before it is sent; cadence restarts from it ──
update public.airvalet_staff_reminder_config set since = pg_temp.ny('2026-11-12 12:00');
insert into public.passengers (id, name, phone, ticket, status, ret, loc, checkin_date) values
  (991071, 'CUT OLD', '3055551071', 'RT-CT1', 'PENDING', '11/20/2026', '', pg_temp.ny('2026-11-12 11:00')),
  (991072, 'CUT NEW', '3055551072', 'RT-CT2', 'PENDING', '11/20/2026', '', pg_temp.ny('2026-11-12 12:10'));
create temp table cut as select unnest(pg_temp.claim('2026-11-12 12:05')) c;
select pg_temp.check('NODATE_ADMIN:ALL' = any (pg_temp.due('2026-11-12 12:05')) and not exists (select 1 from cut where c in ('NODATE_ADMIN:ALL', 'OVERDUE:ALL', 'NO_HANGAR:RT-CT1')),
  'deploy at 12:00: the 8 AM / 9 AM summaries and an 11:30 reminder are not sent afterwards');
select pg_temp.check('NO_HANGAR:RT-CT2' = any (pg_temp.claim('2026-11-12 12:40')), 'after the deploy: a new check-in without hangar alerts normally (12:10 → 12:40)');
select pg_temp.check('NODATE_ADMIN:ALL' = any (pg_temp.claim('2026-11-13 09:00')), 'next morning the daily summary goes out');
select pg_temp.check((select array_agg(to_char(d, 'MM/DD') order by d) from generate_series(date '2026-11-12', date '2026-11-16', interval '1 day') g(d)
                       where 'FOLLOWUP_E3:ALL' = any (pg_temp.due(to_char(d, 'YYYY-MM-DD') || ' 09:00'))) = array['11/12', '11/15'],
  'every-3-days counts from the deploy day (11/12 skipped by the cutoff, next 11/15)');
select pg_temp.check(not ('FOLLOWUP_E3:ALL' = any (pg_temp.claim('2026-11-12 13:00'))) and 'FOLLOWUP_E3:ALL' = any (pg_temp.claim('2026-11-15 09:00')), 'Return Follow-Up: first one 3 days after the deploy');
update public.airvalet_staff_reminder_config set since = pg_temp.ny('2026-10-26 00:00');

-- ── Duplicates under concurrency / audit ──
select pg_temp.check((select count(*) from public.airvalet_notify_log where dedupe_key like 'REM:%') = (select count(distinct dedupe_key) from public.airvalet_notify_log where dedupe_key like 'REM:%'), 'audit: one row per reminder sent (no duplicates)');
select pg_temp.check((select bool_and(detail is not null and channel = 'push') from public.airvalet_notify_log where dedupe_key like 'REM:%'), 'audit rows carry the reminder code');

-- ── Per-phone categories (permissions) ──
insert into public.airvalet_sms_devices (key_hash, label, status) values
  (public.airvalet_sms_device_key_hash('rem_owner_key___' || repeat('a', 40)), 'R-owner', 'approved'),
  (public.airvalet_sms_device_key_hash('rem_ipad_key____' || repeat('b', 40)), 'R-ipad', 'approved');
insert into public.airvalet_push_subs (device_id, endpoint, p256dh, auth, show_preview)
select d.id, 'https://web.push.apple.com/' || d.label, repeat('p', 87), repeat('a', 22), true from public.airvalet_sms_devices d where d.label in ('R-owner', 'R-ipad');
update public.airvalet_portal_settings set push_enabled = true;
select id as u_ipad from public.user_profiles where username = 'localipad' \gset
select id as u_admin from public.user_profiles where username = 'localadmin' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'u_ipad', 'role', 'authenticated')::text, true);
select pg_temp.check((public.airvalet_push_reminders_set('rem_ipad_key____' || repeat('b', 40), array['CARWASH', 'CUSTOMS', 'WELCOME_BACK', 'POSITION', 'DAILY', 'FOLLOWUP']))->>'result' = 'OK', 'iPad login: turns on the operational categories');
select pg_temp.check((public.airvalet_push_reminders_set('rem_ipad_key____' || repeat('b', 40), array['CARWASH', 'NODATE_ADMIN']))->>'result' = 'FORBIDDEN', 'iPad login cannot take the admin-only summary');
select pg_temp.check((public.airvalet_push_reminders_set('rem_ipad_key____' || repeat('b', 40), array['CARWASH', 'CARWASH_ADMIN']))->>'result' = 'FORBIDDEN', 'iPad login cannot take car wash 3 days before (ADMIN only)');
select pg_temp.check((public.airvalet_push_reminders_set('rem_ipad_key____' || repeat('b', 40), array['SPAM']))->>'result' = 'BAD_CATEGORY', 'unknown category refused');
select pg_temp.check(public.airvalet_push_reminders_get('rem_ipad_key____' || repeat('b', 40)) = array['CARWASH', 'CUSTOMS', 'DAILY', 'FOLLOWUP', 'POSITION', 'WELCOME_BACK'], 'iPad phone keeps its categories');
select set_config('request.jwt.claims', json_build_object('sub', :'u_admin', 'role', 'authenticated')::text, true);
select pg_temp.check((public.airvalet_push_reminders_set('rem_owner_key___' || repeat('a', 40), array['CARWASH', 'CARWASH_ADMIN', 'NODATE_ADMIN']))->>'result' = 'OK', 'ADMIN: car wash (incl. 3 days before) + admin-only summary');
select pg_temp.check((public.airvalet_push_reminders_set('rem_owner_key___' || repeat('a', 40), '{}'))->>'result' = 'OK'
  and (public.airvalet_push_reminders_set('rem_owner_key___' || repeat('a', 40), array['CARWASH', 'NODATE_ADMIN']))->>'result' = 'OK', 'categories can be cleared and set again');
reset role;
select pg_temp.check((select count(*) from public.airvalet_push_reminder_targets() where endpoint like '%R-%') = 2, 'both phones are reminder targets');
create function pg_temp.ipad_target() returns boolean language sql as $$ select exists (select 1 from public.airvalet_push_reminder_targets() where endpoint like '%R-ipad') $$;
update public.airvalet_sms_devices set status = 'revoked' where label = 'R-ipad';
select pg_temp.check(not pg_temp.ipad_target(), 'disconnected device (revoked): no reminders');
update public.airvalet_sms_devices set status = 'pending' where label = 'R-ipad';
select pg_temp.check(not pg_temp.ipad_target(), 'device not approved: no reminders');
update public.airvalet_sms_devices set status = 'approved' where label = 'R-ipad';
update public.airvalet_push_subs set fail_count = 5 where endpoint like '%R-ipad';
select pg_temp.check(not pg_temp.ipad_target(), 'subscription failing 5 times in a row: skipped');
update public.airvalet_push_subs set fail_count = 0 where endpoint like '%R-ipad';
select public.airvalet_push_result((select id from public.airvalet_push_subs where endpoint like '%R-ipad'), false, true);
select pg_temp.check(not pg_temp.ipad_target() and (select revoked_at is not null from public.airvalet_push_subs where endpoint like '%R-ipad'), 'push service says "gone" (phone removed the app): subscription revoked');
update public.airvalet_push_subs set revoked_at = null where endpoint like '%R-ipad';
select pg_temp.check(pg_temp.ipad_target(), 'back to normal → target again');
update public.airvalet_portal_settings set push_enabled = false;
select pg_temp.check((select count(*) from public.airvalet_push_reminder_targets()) = 0, 'alerts switched off for AirValet → no phone at all');
update public.airvalet_portal_settings set push_enabled = true;
select pg_temp.check(not has_function_privilege('authenticated', 'public.airvalet_staff_reminders_claim(timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'public.airvalet_staff_reminders(timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'public.airvalet_push_reminder_targets()', 'execute'), 'reminder engine: service only');

-- ── Cron tick: nothing without Vault; with Vault → one call (kind REMINDERS) ──
select pg_temp.check(exists (select 1 from cron.job where jobname = 'airvalet-staff-reminders' and schedule = '* * * * *'), 'scheduled every minute');
delete from vault.secrets where name in ('airvalet_functions_url', 'staff_alert_secret');   -- rolled back
create temp table rq0 as select coalesce(max(id), 0) m from net.http_request_queue;
select public.airvalet_staff_reminders_tick();
select pg_temp.check((select count(*) from net.http_request_queue where id > (select m from rq0)) = 0, 'tick without Vault secrets: no call (local never calls production)');
select vault.create_secret('http://127.0.0.1:9/functions/v1', 'airvalet_functions_url');
select vault.create_secret('test-secret-value', 'staff_alert_secret');
select vault.create_secret('test-platform-jwt', 'aircraft_tracking_platform_jwt') where not exists (select 1 from vault.secrets where name = 'aircraft_tracking_platform_jwt');
select public.airvalet_staff_reminders_tick();
select pg_temp.check((select count(*) from net.http_request_queue where id > (select m from rq0) and url = 'http://127.0.0.1:9/functions/v1/staff-alert'
  and convert_from(body, 'utf8')::jsonb = '{"kind": "REMINDERS"}'::jsonb) = 1, 'tick with Vault: one call to staff-alert (kind REMINDERS)');

-- ── pg_net throwing (misconfigured URL in Vault): operations still go through (rolled back) ──
select vault.update_secret((select id from vault.secrets where name = 'airvalet_functions_url'), 'not a url at all');
select pg_temp.check((select count(*) from vault.decrypted_secrets where name = 'airvalet_functions_url' and decrypted_secret = 'not a url at all') = 1, 'Vault URL broken on purpose');
insert into public.passengers (id, name, phone, ticket, status, ret, loc, checkin_date) values
  (991081, 'NET DOWN', '3055551081', 'RT-NET1', 'PENDING', '11/20/2026', 'HANGAR 19', now());
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_checkout_session_id, stripe_event_id)
values (991081, 'RT-NET1', 1000, 'TIP', 'STRIPE', 'succeeded', 'cs_test_net1', 'evt_net1');
update public.passengers set status = 'DELIVERED', checkout_date = now() where id = 991081;
select public.airvalet_staff_reminders_tick();
select pg_temp.check((select status from public.passengers where id = 991081) = 'DELIVERED'
  and exists (select 1 from public.payments where stripe_event_id = 'evt_net1'), 'pg_net throwing: check-in, Stripe tip, delivery and the cron tick all go through');
