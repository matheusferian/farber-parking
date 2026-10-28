-- AirValet — in-person tips at check-in, delivery and later (owner 2026-10-28). LOCAL ONLY until owner GO.
-- Extends the Smart Tips ledger (20261113, owner approved 2026-10-28) instead of a second table, so the
-- Closing Report and the future Smart Tips work keep one source of truth. Additive: nothing is deleted.
--
-- Base (production, md5 of pg_get_functiondef on 2026-10-28):
--   airvalet_tip_record ce0ebf54…  airvalet_tip_correct e2520bac…  airvalet_tip_legacy_capture f1c12eef…
--   airvalet_tip_mirror 7dedc638…  airvalet_cash_tips_for_date 2a3eef8f…  airvalet_guest_visit 778f7c5f…
--
--   1. stage (CHECKIN | CHECKOUT | LATER) on every row. A correction keeps the stage of the row it replaces.
--      source keeps its meaning; 'CHECKIN' is new.
--   2. Several cash tips per ticket ($10 at check-in + $20 at delivery = $30). The client key still makes a
--      double tap / retry / second device one row; the same amount, stage and ticket again within 2 minutes
--      is refused (RECENT_SAME) — two devices recording the same cash.
--   3. A check-in tip never touches the passenger side: tip_in_person_cents / tip_received (pass thank-you,
--      delivery text) stay the delivery answer = the sum of the CHECKOUT + LATER rows. No SMS, no push.
--   4. Business day: CHECKIN = check-in day, CHECKOUT = delivery day, LATER = delivery day when delivered,
--      else today. A closed day changes only by an ADMIN (unchanged).
--   5. airvalet_daily_tips(date): Cash recorded by the team + Online (Stripe succeeded) = Total recorded.
--      Ops roles only. Read-only. No split between staff.
--   6. Guests visit card: cash = the sum of the visit (was one row).
-- App v89 keeps working on this database (same signatures, same results for its calls).
-- Rollback: 20261117_airvalet_tip_stages_rollback.sql (refuses, changing nothing, once data needs 1117).

begin;
set local lock_timeout = '5s';

-- ── 1. Stage + several rows per ticket ────────────────────────────────────
alter table public.airvalet_tip_records drop constraint if exists airvalet_tip_records_source_check;
alter table public.airvalet_tip_records add constraint airvalet_tip_records_source_check
  check (source in ('CHECKIN', 'DELIVERY', 'ADDED_LATER', 'CORRECTION', 'DELIVERY_LEGACY'));
alter table public.airvalet_tip_records add column if not exists stage text;
with recursive chain as (
  select t.id, case t.source when 'CHECKIN' then 'CHECKIN' when 'ADDED_LATER' then 'LATER' else 'CHECKOUT' end as stage
    from public.airvalet_tip_records t where t.supersedes_id is null
  union all
  select t.id, c.stage from public.airvalet_tip_records t join chain c on t.supersedes_id = c.id
)
update public.airvalet_tip_records t set stage = c.stage from chain c where c.id = t.id and t.stage is null;
update public.airvalet_tip_records t set stage = 'CHECKOUT' where t.stage is null;   -- never expected; keeps NOT NULL safe
alter table public.airvalet_tip_records alter column stage set not null;
alter table public.airvalet_tip_records drop constraint if exists airvalet_tip_records_stage_check;
alter table public.airvalet_tip_records add constraint airvalet_tip_records_stage_check check (stage in ('CHECKIN', 'CHECKOUT', 'LATER'));
-- Any insert without a stage (older code, maintenance scripts) gets it from source / the row it corrects.
create or replace function public.airvalet_tip_stage_default()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.stage is null then
    new.stage := case
      when new.source = 'CHECKIN' then 'CHECKIN'
      when new.source = 'ADDED_LATER' then 'LATER'
      when new.source = 'CORRECTION' then coalesce((select t.stage from public.airvalet_tip_records t where t.id = new.supersedes_id), 'CHECKOUT')
      else 'CHECKOUT' end;
  end if;
  return new;
end $$;
revoke all on function public.airvalet_tip_stage_default() from public, anon, authenticated;
drop trigger if exists airvalet_tip_stage_default on public.airvalet_tip_records;
create trigger airvalet_tip_stage_default before insert on public.airvalet_tip_records
  for each row execute function public.airvalet_tip_stage_default();
drop index if exists public.airvalet_tip_records_one_active_cash;
create index if not exists airvalet_tip_records_active_pax
  on public.airvalet_tip_records (passenger_id) where voided_at is null;

-- Ticket history line only (check-in tips: the car's tip fields stay the delivery answer).
create or replace function public.airvalet_tip_log(p_passenger_id bigint, p_actor text, p_action text, p_detail text, p_old text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_p public.passengers%rowtype;
begin
  select * into v_p from public.passengers p where p.id = p_passenger_id;
  if v_p.id is null then return; end if;
  insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by, field_name, old_value, new_value)
  values (to_char(now() at time zone 'America/New_York', 'MM/DD/YYYY, HH12:MI:SS AM'), p_action, v_p.name, v_p.ticket, v_p.loc,
          p_detail, v_p.id, p_actor, 'tip_in_person_cents', p_old, p_new);
end $$;
revoke all on function public.airvalet_tip_log(bigint, text, text, text, text, text) from public, anon, authenticated;

-- Mirror on the car = the sum of the active CHECKOUT + LATER cash rows (p_cents is no longer the value).
create or replace function public.airvalet_tip_mirror(p_passenger_id bigint, p_cents integer, p_tip_received boolean,
                                                     p_actor text, p_action text, p_detail text, p_old text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_sum integer; v_id bigint;
begin
  select nullif(coalesce(sum(t.amount_cents), 0), 0)::integer into v_sum from public.airvalet_tip_records t
   where t.passenger_id = p_passenger_id and t.voided_at is null and t.method = 'CASH' and t.stage <> 'CHECKIN';
  perform set_config('airvalet.tip_ledger', '1', true);
  update public.passengers p set tip_in_person_cents = v_sum,
         tip_received = case when v_sum is not null then true else p_tip_received end
   where p.id = p_passenger_id returning p.id into v_id;
  perform set_config('airvalet.tip_ledger', '', true);
  if v_id is null then return; end if;
  perform public.airvalet_tip_log(p_passenger_id, p_actor, p_action, p_detail, p_old, p_new);
end $$;
revoke all on function public.airvalet_tip_mirror(bigint, integer, boolean, text, text, text, text, text) from public, anon, authenticated;

create or replace function public.airvalet_tip_record(p_passenger_id bigint, p_amount_cents integer, p_client_key uuid,
                                                     p_received_by text default null, p_source text default 'DELIVERY')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role  public.account_role := public.current_user_role();
  v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_by    text := left(nullif(btrim(coalesce(p_received_by, '')), ''), 80);
  v_p     public.passengers%rowtype;
  v_row   public.airvalet_tip_records%rowtype;
  v_stage text := case p_source when 'CHECKIN' then 'CHECKIN' when 'DELIVERY' then 'CHECKOUT' when 'ADDED_LATER' then 'LATER' end;
  v_done  boolean;
  v_day   date;
begin
  if v_role is null or v_role not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER') then
    raise exception 'airvalet_tip_record: not allowed' using errcode = '42501';
  end if;
  if p_client_key is null or v_stage is null then return jsonb_build_object('result', 'INVALID'); end if;
  -- Same tap again (retry, double tap, offline replay): the first row, nothing new.
  select * into v_row from public.airvalet_tip_records t where t.client_key = p_client_key;
  if found then return jsonb_build_object('result', 'OK', 'duplicate', true, 'tip', to_jsonb(v_row)); end if;
  if p_amount_cents is null or p_amount_cents < 1 or p_amount_cents > 100000 then return jsonb_build_object('result', 'INVALID'); end if;

  select * into v_p from public.passengers p where p.id = p_passenger_id for update;   -- one writer per car
  if not found then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  v_done := v_p.status in ('DELIVERED', 'ARCHIVED');
  if v_stage = 'CHECKOUT' and v_p.status is distinct from 'DELIVERED' then return jsonb_build_object('result', 'NOT_DELIVERED'); end if;
  if v_stage = 'CHECKIN' and v_done then return jsonb_build_object('result', 'ALREADY_DELIVERED'); end if;
  if v_p.status = 'ARCHIVED' and v_role <> 'ADMIN' then return jsonb_build_object('result', 'ARCHIVED'); end if;
  -- Two devices typing the same cash: same ticket, stage and amount within 2 minutes.
  select * into v_row from public.airvalet_tip_records t
   where t.passenger_id = v_p.id and t.voided_at is null and t.stage = v_stage and t.amount_cents = p_amount_cents
     and t.recorded_at > now() - interval '2 minutes'
   order by t.id desc limit 1;
  if found then return jsonb_build_object('result', 'RECENT_SAME', 'tip', to_jsonb(v_row)); end if;
  v_day := case
    when v_stage = 'CHECKIN' then coalesce((v_p.checkin_date at time zone 'America/New_York')::date, (now() at time zone 'America/New_York')::date)
    when v_stage = 'CHECKOUT' or v_done then coalesce((v_p.checkout_date at time zone 'America/New_York')::date, (now() at time zone 'America/New_York')::date)
    else (now() at time zone 'America/New_York')::date end;
  if v_role <> 'ADMIN' and exists (select 1 from public.daily_closing_reports d where d.report_date = v_day and d.closed_at is not null) then
    return jsonb_build_object('result', 'DAY_CLOSED', 'business_date', v_day);
  end if;

  begin
    insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, method, source, stage, business_date, received_by_name, recorded_by, client_key)
    values (v_p.id, v_p.ticket, p_amount_cents, 'CASH', p_source, v_stage, v_day, v_by, v_actor, p_client_key)
    returning * into v_row;
  exception when unique_violation then
    select * into v_row from public.airvalet_tip_records t where t.client_key = p_client_key;
    return jsonb_build_object('result', 'OK', 'duplicate', true, 'tip', to_jsonb(v_row));
  end;
  if v_stage = 'CHECKIN' then
    perform public.airvalet_tip_log(v_p.id, v_actor, 'TIP CASH',
      'Cash tip recorded: $' || to_char(p_amount_cents / 100.0, 'FM999990.00') || coalesce(' | Received by ' || v_by, '') || ' | At check-in',
      null, (p_amount_cents / 100.0)::text);
  else
    perform public.airvalet_tip_mirror(v_p.id, p_amount_cents, true, v_actor, 'TIP CASH',
      'Cash tip recorded: $' || to_char(p_amount_cents / 100.0, 'FM999990.00') || coalesce(' | Received by ' || v_by, '')
        || case when p_source = 'ADDED_LATER' then ' | Added later' else '' end,
      null, (p_amount_cents / 100.0)::text);
  end if;
  return jsonb_build_object('result', 'OK', 'tip', to_jsonb(v_row));
end $$;
revoke all on function public.airvalet_tip_record(bigint, integer, uuid, text, text) from public, anon;
grant execute on function public.airvalet_tip_record(bigint, integer, uuid, text, text) to authenticated;

create or replace function public.airvalet_tip_correct(p_tip_id bigint, p_new_amount_cents integer, p_reason text, p_client_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role   public.account_role := public.current_user_role();
  v_actor  text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_old    public.airvalet_tip_records%rowtype;
  v_new    public.airvalet_tip_records%rowtype;
  v_pid    bigint;
  v_detail text;
begin
  if v_role is null or v_role not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER') then
    raise exception 'airvalet_tip_correct: not allowed' using errcode = '42501';
  end if;
  if p_client_key is null then return jsonb_build_object('result', 'INVALID'); end if;
  -- Same correction again: report the first one.
  select * into v_new from public.airvalet_tip_records t where t.client_key = p_client_key;
  if found then return jsonb_build_object('result', 'OK', 'duplicate', true, 'tip', to_jsonb(v_new)); end if;
  select * into v_old from public.airvalet_tip_records t where t.void_client_key = p_client_key;
  if found then return jsonb_build_object('result', 'OK', 'duplicate', true, 'removed', to_jsonb(v_old)); end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then return jsonb_build_object('result', 'REASON_REQUIRED'); end if;
  if p_new_amount_cents is not null and (p_new_amount_cents < 1 or p_new_amount_cents > 100000) then return jsonb_build_object('result', 'INVALID'); end if;
  select t.passenger_id into v_pid from public.airvalet_tip_records t where t.id = p_tip_id;
  if v_pid is not null then perform 1 from public.passengers p where p.id = v_pid for update; end if;   -- same lock order as record
  select * into v_old from public.airvalet_tip_records t where t.id = p_tip_id for update;
  if not found then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  if v_old.voided_at is not null then return jsonb_build_object('result', 'ALREADY_CORRECTED'); end if;
  if p_new_amount_cents = v_old.amount_cents then return jsonb_build_object('result', 'UNCHANGED'); end if;
  if v_role <> 'ADMIN' and exists (select 1 from public.daily_closing_reports d where d.report_date = v_old.business_date and d.closed_at is not null) then
    return jsonb_build_object('result', 'DAY_CLOSED', 'business_date', v_old.business_date);
  end if;
  update public.airvalet_tip_records t set voided_at = now(), voided_by = v_actor, void_reason = v_reason,
         void_client_key = case when p_new_amount_cents is null then p_client_key end
   where t.id = v_old.id;
  if p_new_amount_cents is not null then
    insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, method, source, stage, business_date, received_by_name, recorded_by, client_key, supersedes_id)
    values (v_old.passenger_id, v_old.ticket, p_new_amount_cents, v_old.method, 'CORRECTION', v_old.stage, v_old.business_date, v_old.received_by_name, v_actor, p_client_key, v_old.id)
    returning * into v_new;
  end if;
  if v_old.passenger_id is not null then
    v_detail := 'Cash tip corrected: $' || to_char(v_old.amount_cents / 100.0, 'FM999990.00') || ' → '
      || coalesce('$' || to_char(p_new_amount_cents / 100.0, 'FM999990.00'), 'removed') || ' | Reason: ' || v_reason
      || case when v_old.stage = 'CHECKIN' then ' | At check-in' else '' end;
    if v_old.stage = 'CHECKIN' then
      perform public.airvalet_tip_log(v_old.passenger_id, v_actor, 'TIP CASH CORRECTED', v_detail,
        (v_old.amount_cents / 100.0)::text, (p_new_amount_cents / 100.0)::text);
    else
      perform public.airvalet_tip_mirror(v_old.passenger_id, p_new_amount_cents,
        case when p_new_amount_cents is null then null else true end, v_actor, 'TIP CASH CORRECTED', v_detail,
        (v_old.amount_cents / 100.0)::text, (p_new_amount_cents / 100.0)::text);
    end if;
  end if;
  return jsonb_build_object('result', 'OK', 'tip', case when v_new.id is null then null else to_jsonb(v_new) end);
end $$;
revoke all on function public.airvalet_tip_correct(bigint, integer, text, uuid) from public, anon;
grant execute on function public.airvalet_tip_correct(bigint, integer, text, uuid) to authenticated;

-- Direct writes to the mirror (an old app at delivery): one audited CHECKOUT row, as in 1113.
create or replace function public.airvalet_tip_legacy_capture()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_sum integer;
begin
  if coalesce(current_setting('airvalet.tip_ledger', true), '') = '1' then return new; end if;   -- the ledger functions
  if new.tip_in_person_cents is not distinct from old.tip_in_person_cents then return new; end if;
  if old.tip_in_person_cents is null and new.tip_in_person_cents is not null then
    select sum(t.amount_cents)::integer into v_sum from public.airvalet_tip_records t
     where t.passenger_id = new.id and t.method = 'CASH' and t.voided_at is null and t.stage <> 'CHECKIN';
    if v_sum is not null then new.tip_in_person_cents := v_sum; return new; end if;
    insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, method, source, stage, business_date, recorded_by)
    values (new.id, new.ticket, new.tip_in_person_cents, 'CASH', 'DELIVERY_LEGACY', 'CHECKOUT',
            coalesce((new.checkout_date at time zone 'America/New_York')::date, (now() at time zone 'America/New_York')::date),
            coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), current_user::text));
    return new;
  end if;
  -- The message names the column: an old app then delivers without the amount.
  raise exception 'tip_in_person_cents: an amount already recorded changes only with Correct (audited)' using errcode = '42501';
end $$;
revoke all on function public.airvalet_tip_legacy_capture() from public, anon, authenticated;

-- ── 2. Closing Report input: A = every cash row of the day (check-in ones included) ──
create or replace function public.airvalet_cash_tips_for_date(p_date date)
returns table (cash_cents integer, tickets integer, no_amount integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  -- App logins: ops roles only. Server-side SQL (no app JWT, e.g. the Closing
  -- trigger during an owner's maintenance query) is allowed.
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') in ('authenticated', 'anon')
     and (public.current_user_role() is null or public.current_user_role() not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER')) then
    raise exception 'airvalet_cash_tips_for_date: not allowed' using errcode = '42501';
  end if;
  return query
  select coalesce((select sum(t.amount_cents) from public.airvalet_tip_records t
                    where t.business_date = p_date and t.voided_at is null and t.method = 'CASH'), 0)::integer,
         (select count(distinct t.passenger_id) from public.airvalet_tip_records t
           where t.business_date = p_date and t.voided_at is null and t.method = 'CASH')::integer,
         (select count(*) from public.passengers p
           where p.status = 'DELIVERED' and p.tip_received is true
             and (p.checkout_date at time zone 'America/New_York')::date = p_date
             and not exists (select 1 from public.airvalet_tip_records t where t.passenger_id = p.id and t.voided_at is null and t.stage <> 'CHECKIN'))::integer;
end $$;
revoke all on function public.airvalet_cash_tips_for_date(date) from public, anon;
grant execute on function public.airvalet_cash_tips_for_date(date) to authenticated;

-- ── 3. DAILY TIPS (read-only) ─────────────────────────────────────────────
-- Cash = what the team recorded (not every tip received). Online = Stripe gratuities Stripe
-- confirmed (succeeded; refunded ones drop out). They never overlap: cash rows are CASH only,
-- online rows come only from payments. No split between staff.
create or replace function public.airvalet_daily_tips(p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cash jsonb; v_online jsonb;
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') in ('authenticated', 'anon')
     and (public.current_user_role() is null or public.current_user_role() not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER')) then
    raise exception 'airvalet_daily_tips: not allowed' using errcode = '42501';
  end if;
  if p_date is null then return jsonb_build_object('result', 'INVALID'); end if;
  select jsonb_build_object(
           'cents', coalesce(sum(t.amount_cents), 0), 'entries', count(*), 'tickets', count(distinct t.passenger_id),
           'checkin_cents', coalesce(sum(t.amount_cents) filter (where t.stage = 'CHECKIN'), 0),
           'checkout_cents', coalesce(sum(t.amount_cents) filter (where t.stage = 'CHECKOUT'), 0),
           'later_cents', coalesce(sum(t.amount_cents) filter (where t.stage = 'LATER'), 0))
    into v_cash
    from public.airvalet_tip_records t
   where t.business_date = p_date and t.voided_at is null and t.method = 'CASH';
  select jsonb_build_object('cents', coalesce(sum(y.amount_cents), 0), 'count', count(*))
    into v_online
    from public.payments y
   where y.type = 'TIP' and y.method = 'STRIPE' and y.status = 'succeeded'
     and (y.created_at at time zone 'America/New_York')::date = p_date;
  return jsonb_build_object('result', 'OK', 'date', p_date, 'cash', v_cash, 'online', v_online,
    'total_recorded_cents', (v_cash ->> 'cents')::bigint + (v_online ->> 'cents')::bigint);
end $$;
revoke all on function public.airvalet_daily_tips(date) from public, anon;
grant execute on function public.airvalet_daily_tips(date) to authenticated;

-- ── 4. Guests visit card: cash of the visit = the sum ─────────────────────
CREATE OR REPLACE FUNCTION public.airvalet_guest_visit(p passengers)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', p.id, 'ticket', p.ticket, 'name', p.name, 'phone', p.phone, 'status', p.status,
    'checkin', ci, 'delivered', dl, 'stay_days', case when ci is not null and dl is not null and dl >= ci then dl - ci end,
    'vehicle', nullif(btrim(concat_ws(' ', nullif(btrim(p.color), ''), nullif(btrim(p.car), ''))), ''),
    'hangar', case when p.status = 'DELIVERED' then nullif(btrim(coalesce(p.previous_delivery_location, '')), '') else nullif(btrim(coalesce(p.loc, '')), '') end,
    'return_now', nullif(btrim(coalesce(p.ret, '')), ''),
    'return_original', coalesce((select c.old_return_date from public.passenger_return_date_changes c where c.passenger_id = p.id order by c.created_at, c.id limit 1), nullif(btrim(coalesce(p.ret, '')), '')),
    'return_changes', coalesce((select jsonb_agg(jsonb_build_object('at', c.created_at, 'from', c.old_return_date, 'to', c.new_return_date, 'reason', c.comment, 'by', c.changed_by) order by c.created_at, c.id)
                                  from public.passenger_return_date_changes c where c.passenger_id = p.id), '[]'::jsonb),
    'flight', nullif(btrim(coalesce(p.return_flight, '')), ''),
    'delivery_type', p.delivery_type, 'carwash', p.carwash_status, 'released_to', p.released_to_name,
    'tip_received', p.tip_received,
    'cash_cents', (select sum(t.amount_cents)::integer from public.airvalet_tip_records t where t.passenger_id = p.id and t.voided_at is null and t.method = 'CASH'),
    'stripe_cents', (select nullif(sum(y.amount_cents), 0) from public.payments y where y.passenger_id = p.id and y.type = 'TIP' and y.status = 'succeeded'),
    'notes', nullif(btrim(coalesce(p.obs, '')), ''))
  from (select coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts)) ci,
               coalesce((p.checkout_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.deldate)) dl) d
$function$;

commit;
