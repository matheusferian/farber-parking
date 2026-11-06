-- Rollback of 20261132: production definition read 2026-11-06 (20261131).
begin;
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION public.airvalet_staff_reminders(p_now timestamp with time zone)
 RETURNS TABLE(code text, category text, dedupe_key text, passenger_id bigint, ticket text, body text, due_at timestamp with time zone, expires_at timestamp with time zone, grp text, gtext text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with t as (select (p_now at time zone 'America/New_York')::date as d),
c as (select (coalesce(max(f.since), p_now) at time zone 'America/New_York')::date as since_d, max(f.move_lead_min) as mv
        from public.airvalet_staff_reminder_config f),
p as (
  select x.id, x.ticket, x.status, x.loc, x.carwash_status, x.departure_time, x.checkin_date, x.obs,
         public.airvalet_ret_date(x.ret) as rd,
         public.airvalet_wb_eta_min(btrim(coalesce(x.departure_time, ''))) as wb_eta,
         public.airvalet_return_operator_of(x.return_operator, x.not_returning_with_makers_air, x.ticket) as op,
         x.delivery_at_customs, x.delivery_type, x.welcome_back_sent_at,
         upper(regexp_replace(btrim(coalesce(x.loc, '')), '\s+', ' ', 'g')) as locn,
         coalesce(x.obs, '') ~* '(APPROX|ESTIMATED RETURN DATE)' as approx,
         (x.checkin_date is not null and public.airvalet_ret_date(x.ret) = (x.checkin_date at time zone 'America/New_York')::date) as day_trip
    from public.passengers x where x.status in ('PENDING', 'NO DATE')
),
a as (
  select p.*, case when p.op = 'MAKERS' then case when p.delivery_at_customs then 'CUSTOMS' else 'HANGAR 19' end
                   when p.op = 'ASCEND' then 'CUSTOMS' end as target
    from p
),
cw as (select a.* from a, t where a.carwash_status = 'CARWASH'),
fu as (select a.* from a, t where a.status = 'NO DATE' or a.approx or (a.status = 'PENDING' and (a.rd is null or a.rd < t.d))),
nd as (select a.* from a where a.status = 'NO DATE' or a.rd is null),
del as (  -- Customs deliveries (isCustomsCommEligible): status DELIVERED, type CUSTOMS, after the feature start
  select x.id, x.ticket, x.checkout_date, public.airvalet_ret_date(x.ret) as rd,
         public.airvalet_customs_eta_min(x.departure_time) as c_eta,
         x.customs_welcome_sent, x.customs_gratuity_sent, x.customs_gratuity_dismissed
    from public.passengers x
   where x.status = 'DELIVERED' and x.delivery_type = 'CUSTOMS'
     and x.checkout_date >= timestamptz '2026-07-12 09:50:00-04' and x.checkout_date > p_now - interval '3 days'
)
-- Car wash, 3 / 1 days before
select 'CW_D' || (cw.rd - t.d), case when cw.rd - t.d = 3 then 'CARWASH_ADMIN' else 'CARWASH' end, 'REM:CW_D' || (cw.rd - t.d) || ':' || cw.id || ':' || cw.rd, cw.id, cw.ticket,
       'Car wash in ' || (cw.rd - t.d) || case when cw.rd - t.d = 1 then ' day: ' else ' days: ' end || coalesce(cw.ticket, '?') || ' (' || to_char(cw.rd, 'Dy Mon FMDD') || ')',
       public.airvalet_ny_at(t.d, 540), public.airvalet_ny_at(t.d, 1320),
       'CW_D' || (cw.rd - t.d) || ':' || cw.rd,
       'Car wash in ' || (cw.rd - t.d) || case when cw.rd - t.d = 1 then ' day' else ' days' end || ' (' || to_char(cw.rd, 'Dy Mon FMDD') || '): {t}'
  from cw, t where cw.rd - t.d in (3, 1)
union all
-- Car wash, return day: 08:00, 10:00 … 20:00 until done
select 'CW_DAY', 'CARWASH', 'REM:CW_DAY:' || cw.id || ':' || cw.rd || ':' || s.m, cw.id, cw.ticket,
       'Car wash today: ' || coalesce(cw.ticket, '?') || ' — not marked washed yet',
       public.airvalet_ny_at(t.d, s.m), public.airvalet_ny_at(t.d, s.m + 120),
       'CW_DAY:' || cw.rd || ':' || s.m, 'Car wash today, not marked washed yet: {t}'
  from cw, t, generate_series(480, 1200, 120) s(m) where cw.rd = t.d
union all
-- Car wash pending, return far away or not set: every 3 days
select 'CW_E3', 'CARWASH', 'REM:CW_E3:' || cw.id || ':' || t.d, cw.id, cw.ticket,
       'Car wash pending: ' || coalesce(cw.ticket, '?') || ' (return ' || coalesce(to_char(cw.rd, 'Dy Mon FMDD'), 'not set') || ')',
       public.airvalet_ny_at(t.d, 540), public.airvalet_ny_at(t.d, 1320),
       'CW_E3:' || t.d, 'Car wash pending: {t}'
  from cw, t, c where (cw.rd is null or cw.rd > t.d + 3) and (t.d - c.since_d) % 3 = 0
union all
-- Return follow-up list: one summary every 3 days
select 'FOLLOWUP_E3', 'FOLLOWUP', 'REM:FOLLOWUP_E3:' || t.d, null, null,
       count(*) || case when count(*) = 1 then ' car' else ' cars' end || ' to check (return follow-up): ' || string_agg(coalesce(fu.ticket, '?'), ', ' order by fu.rd nulls first, fu.id),
       public.airvalet_ny_at(t.d, 540), public.airvalet_ny_at(t.d, 1320), null, null
  from fu, t, c where (t.d - c.since_d) % 3 = 0 group by t.d having count(*) > 0
union all
-- No usable return date: one summary every day (ADMIN phones)
select 'NODATE_ADMIN', 'NODATE_ADMIN', 'REM:NODATE_ADMIN:' || t.d, null, null,
       count(*) || case when count(*) = 1 then ' car' else ' cars' end || ' without a return date: ' || string_agg(coalesce(nd.ticket, '?'), ', ' order by nd.id),
       public.airvalet_ny_at(t.d, 540), public.airvalet_ny_at(t.d, 1320), null, null
  from nd, t group by t.d having count(*) > 0
union all
-- Customs gratuity link (after the Customs Welcome Back): ETA + 10 min, that day
select 'GRATUITY', 'CUSTOMS', 'REM:GRATUITY:' || del.id || ':' || del.rd || ':' || del.c_eta, del.id, del.ticket,
       'Send gratuity link: ' || coalesce(del.ticket, '?') || ' (at Customs)',
       public.airvalet_ny_at(del.rd, del.c_eta + 10), public.airvalet_ny_at(del.rd, 1439),
       'GRATUITY:' || del.rd || ':' || del.c_eta, 'Send gratuity link (at Customs): {t}'
  from del where del.customs_welcome_sent is true and del.customs_gratuity_sent is not true and del.customs_gratuity_dismissed is not true
             and del.c_eta is not null and del.rd is not null
union all
-- Customs Welcome Back not sent: delivery + 5 min, for 6 h
select 'CUSTOMS_WB', 'CUSTOMS', 'REM:CUSTOMS_WB:' || del.id || ':' || extract(epoch from del.checkout_date)::bigint, del.id, del.ticket,
       'Send Customs Welcome Back: ' || coalesce(del.ticket, '?'),
       del.checkout_date + interval '5 minutes', del.checkout_date + interval '6 hours',
       'CUSTOMS_WB', 'Send Customs Welcome Back: {t}'
  from del where del.customs_welcome_sent is not true
union all
-- Hangar 19 Welcome Back: ETA − 30 min, until ETA + 2 h
select 'H19_WB', 'WELCOME_BACK', 'REM:H19_WB:' || a.id || ':' || a.rd || ':' || a.wb_eta, a.id, a.ticket,
       'Send Welcome Back: ' || coalesce(a.ticket, '?') || ' lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM'),
       public.airvalet_ny_at(a.rd, a.wb_eta - 30), public.airvalet_ny_at(a.rd, a.wb_eta + 120),
       'H19_WB:' || a.rd || ':' || a.wb_eta,
       'Send Welcome Back, lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM') || ': {t}'
  from a, t where a.op = 'MAKERS' and coalesce(a.delivery_type, '') <> 'CUSTOMS' and a.welcome_back_sent_at is null
              and a.rd = t.d and a.wb_eta is not null and not a.day_trip
union all
-- Day trip Welcome Back (owner 2026-11-06): ETA − 60 min, until ETA + 2 h, any return operator
select 'DAYTRIP_WB', 'WELCOME_BACK', 'REM:DAYTRIP_WB:' || a.id || ':' || a.rd || ':' || a.wb_eta, a.id, a.ticket,
       'Day trip lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM') || ' — send Welcome Back: ' || coalesce(a.ticket, '?'),
       public.airvalet_ny_at(a.rd, a.wb_eta - 60), public.airvalet_ny_at(a.rd, a.wb_eta + 120),
       'DAYTRIP_WB:' || a.rd || ':' || a.wb_eta,
       'Day trip lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM') || ', send Welcome Back: {t}'
  from a, t where a.day_trip and a.welcome_back_sent_at is null and a.rd = t.d and a.wb_eta is not null
union all
-- Car not at its pickup place, return today: ETA − move_lead_min (only when set), until ETA + 1 h
select 'MOVE', 'POSITION', 'REM:MOVE:' || a.id || ':' || a.rd || ':' || a.wb_eta || ':' || replace(a.target, ' ', '_') || ':' || c.mv, a.id, a.ticket,
       case when a.target = 'CUSTOMS' then 'Take ' || coalesce(a.ticket, '?') || ' to Customs' else 'Move ' || coalesce(a.ticket, '?') || ' to Hangar 19' end
         || ' — lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM'),
       public.airvalet_ny_at(a.rd, a.wb_eta - c.mv), public.airvalet_ny_at(a.rd, a.wb_eta + 60),
       'MOVE:' || a.rd || ':' || a.wb_eta || ':' || replace(a.target, ' ', '_'),
       case when a.target = 'CUSTOMS' then 'Take to Customs' else 'Move to Hangar 19' end
         || ', lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM') || ': {t}'
  from a, t, c where c.mv is not null and a.rd = t.d and a.target is not null and a.locn <> a.target and a.wb_eta is not null
union all
-- Check-in without a hangar: + 30 min, within 24 h of the check-in
select 'NO_HANGAR', 'POSITION', 'REM:NO_HANGAR:' || a.id, a.id, a.ticket,
       coalesce(a.ticket, '?') || ' has no hangar — set where the car is',
       a.checkin_date + interval '30 minutes', a.checkin_date + interval '24 hours',
       'NO_HANGAR', 'No hangar set (set where the car is): {t}'
  from a where a.locn = '' and a.checkin_date is not null
union all
-- Returns tomorrow without a time: one summary at 18:00
select 'TMRW_NO_TIME', 'DAILY', 'REM:TMRW_NO_TIME:' || t.d, null, null,
       count(*) || case when count(*) = 1 then ' car leaves' else ' cars leave' end || ' tomorrow without a time: ' || string_agg(coalesce(a.ticket, '?'), ', ' order by a.id),
       public.airvalet_ny_at(t.d, 1080), public.airvalet_ny_at(t.d, 1320), null, null
  from a, t where a.rd = t.d + 1 and a.wb_eta is null group by t.d having count(*) > 0
union all
-- Return date passed, not delivered: one summary at 08:00
select 'OVERDUE', 'DAILY', 'REM:OVERDUE:' || t.d, null, null,
       count(*) || case when count(*) = 1 then ' car is' else ' cars are' end || ' past the return date: ' || string_agg(coalesce(a.ticket, '?'), ', ' order by a.rd, a.id),
       public.airvalet_ny_at(t.d, 480), public.airvalet_ny_at(t.d, 1320), null, null
  from a, t where a.status = 'PENDING' and a.rd < t.d group by t.d having count(*) > 0;
$function$
;
commit;
