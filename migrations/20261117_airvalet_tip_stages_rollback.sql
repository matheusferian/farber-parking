-- Rollback of 20261117_airvalet_tip_stages.sql: production before it (20261113 / 20261114),
-- function bodies byte-for-byte from pg_get_functiondef on 2026-10-28.
-- SAFE BY DESIGN: refuses (raises, changes nothing) when the data already needs 1117 —
-- a check-in tip, or two active cash tips on one ticket. Never deletes a tip. In that case
-- roll back the app only (the database keeps working with app v89).
begin;
set local lock_timeout = '5s';
do $$ begin
  if exists (select 1 from public.airvalet_tip_records where source = 'CHECKIN') then
    raise exception 'rollback 1117 refused: check-in tips exist — roll back the app only (nothing changed)';
  end if;
  if exists (select 1 from public.airvalet_tip_records where voided_at is null and method = 'CASH'
              group by passenger_id having count(*) > 1) then
    raise exception 'rollback 1117 refused: a ticket has more than one active cash tip — roll back the app only (nothing changed)';
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.airvalet_tip_mirror(p_passenger_id bigint, p_cents integer, p_tip_received boolean, p_actor text, p_action text, p_detail text, p_old text, p_new text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_p public.passengers%rowtype;
begin
  perform set_config('airvalet.tip_ledger', '1', true);
  update public.passengers p set tip_in_person_cents = p_cents, tip_received = p_tip_received
   where p.id = p_passenger_id returning * into v_p;
  perform set_config('airvalet.tip_ledger', '', true);
  if v_p.id is null then return; end if;
  insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by, field_name, old_value, new_value)
  values (to_char(now() at time zone 'America/New_York', 'MM/DD/YYYY, HH12:MI:SS AM'), p_action, v_p.name, v_p.ticket, v_p.loc,
          p_detail, v_p.id, p_actor, 'tip_in_person_cents', p_old, p_new);
end $function$

;

CREATE OR REPLACE FUNCTION public.airvalet_tip_record(p_passenger_id bigint, p_amount_cents integer, p_client_key uuid, p_received_by text DEFAULT NULL::text, p_source text DEFAULT 'DELIVERY'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_role  public.account_role := public.current_user_role();
  v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_by    text := left(nullif(btrim(coalesce(p_received_by, '')), ''), 80);
  v_p     public.passengers%rowtype;
  v_row   public.airvalet_tip_records%rowtype;
  v_day   date;
begin
  if v_role is null or v_role not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER') then
    raise exception 'airvalet_tip_record: not allowed' using errcode = '42501';
  end if;
  if p_client_key is null or p_source not in ('DELIVERY', 'ADDED_LATER') then return jsonb_build_object('result', 'INVALID'); end if;
  -- Same tap again (retry, double tap): the first row, nothing new.
  select * into v_row from public.airvalet_tip_records t where t.client_key = p_client_key;
  if found then return jsonb_build_object('result', 'OK', 'duplicate', true, 'tip', to_jsonb(v_row)); end if;
  if p_amount_cents is null or p_amount_cents < 1 or p_amount_cents > 100000 then return jsonb_build_object('result', 'INVALID'); end if;

  select * into v_p from public.passengers p where p.id = p_passenger_id for update;   -- one writer per car
  if not found then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  if v_p.status is distinct from 'DELIVERED' then return jsonb_build_object('result', 'NOT_DELIVERED'); end if;
  select * into v_row from public.airvalet_tip_records t where t.passenger_id = v_p.id and t.method = 'CASH' and t.voided_at is null;
  if found then return jsonb_build_object('result', 'ALREADY_RECORDED', 'tip', to_jsonb(v_row)); end if;
  v_day := coalesce((v_p.checkout_date at time zone 'America/New_York')::date, (now() at time zone 'America/New_York')::date);
  if v_role <> 'ADMIN' and exists (select 1 from public.daily_closing_reports d where d.report_date = v_day and d.closed_at is not null) then
    return jsonb_build_object('result', 'DAY_CLOSED', 'business_date', v_day);
  end if;

  begin
    insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, method, source, business_date, received_by_name, recorded_by, client_key)
    values (v_p.id, v_p.ticket, p_amount_cents, 'CASH', p_source, v_day, v_by, v_actor, p_client_key)
    returning * into v_row;
  exception when unique_violation then
    select * into v_row from public.airvalet_tip_records t where t.client_key = p_client_key;
    if found then return jsonb_build_object('result', 'OK', 'duplicate', true, 'tip', to_jsonb(v_row)); end if;
    select * into v_row from public.airvalet_tip_records t where t.passenger_id = v_p.id and t.method = 'CASH' and t.voided_at is null;
    return jsonb_build_object('result', 'ALREADY_RECORDED', 'tip', to_jsonb(v_row));
  end;
  perform public.airvalet_tip_mirror(v_p.id, p_amount_cents, true, v_actor, 'TIP CASH',
    'Cash tip recorded: $' || to_char(p_amount_cents / 100.0, 'FM999990.00') || coalesce(' | Received by ' || v_by, '')
      || case when p_source = 'ADDED_LATER' then ' | Added after delivery' else '' end,
    null, (p_amount_cents / 100.0)::text);
  return jsonb_build_object('result', 'OK', 'tip', to_jsonb(v_row));
end $function$

;

CREATE OR REPLACE FUNCTION public.airvalet_tip_correct(p_tip_id bigint, p_new_amount_cents integer, p_reason text, p_client_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_role   public.account_role := public.current_user_role();
  v_actor  text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_old    public.airvalet_tip_records%rowtype;
  v_new    public.airvalet_tip_records%rowtype;
  v_pid    bigint;
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
    insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, method, source, business_date, received_by_name, recorded_by, client_key, supersedes_id)
    values (v_old.passenger_id, v_old.ticket, p_new_amount_cents, v_old.method, 'CORRECTION', v_old.business_date, v_old.received_by_name, v_actor, p_client_key, v_old.id)
    returning * into v_new;
  end if;
  if v_old.passenger_id is not null then
    perform public.airvalet_tip_mirror(v_old.passenger_id, p_new_amount_cents,
      case when p_new_amount_cents is null then null else true end, v_actor, 'TIP CASH CORRECTED',
      'Cash tip corrected: $' || to_char(v_old.amount_cents / 100.0, 'FM999990.00') || ' → '
        || coalesce('$' || to_char(p_new_amount_cents / 100.0, 'FM999990.00'), 'removed') || ' | Reason: ' || v_reason,
      (v_old.amount_cents / 100.0)::text, (p_new_amount_cents / 100.0)::text);
  end if;
  return jsonb_build_object('result', 'OK', 'tip', case when v_new.id is null then null else to_jsonb(v_new) end);
end $function$

;

CREATE OR REPLACE FUNCTION public.airvalet_tip_legacy_capture()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_row public.airvalet_tip_records%rowtype;
begin
  if coalesce(current_setting('airvalet.tip_ledger', true), '') = '1' then return new; end if;   -- the ledger functions
  if new.tip_in_person_cents is not distinct from old.tip_in_person_cents then return new; end if;
  if old.tip_in_person_cents is null and new.tip_in_person_cents is not null then
    select * into v_row from public.airvalet_tip_records t where t.passenger_id = new.id and t.method = 'CASH' and t.voided_at is null;
    if found then new.tip_in_person_cents := v_row.amount_cents; return new; end if;
    insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, method, source, business_date, recorded_by)
    values (new.id, new.ticket, new.tip_in_person_cents, 'CASH', 'DELIVERY_LEGACY',
            coalesce((new.checkout_date at time zone 'America/New_York')::date, (now() at time zone 'America/New_York')::date),
            coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), current_user::text));
    return new;
  end if;
  -- The message names the column: app v85 then delivers without the amount.
  raise exception 'tip_in_person_cents: an amount already recorded changes only with Correct (audited)' using errcode = '42501';
end $function$

;

CREATE OR REPLACE FUNCTION public.airvalet_cash_tips_for_date(p_date date)
 RETURNS TABLE(cash_cents integer, tickets integer, no_amount integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
         (select count(*) from public.airvalet_tip_records t
           where t.business_date = p_date and t.voided_at is null and t.method = 'CASH')::integer,
         (select count(*) from public.passengers p
           where p.status = 'DELIVERED' and p.tip_received is true
             and (p.checkout_date at time zone 'America/New_York')::date = p_date
             and not exists (select 1 from public.airvalet_tip_records t where t.passenger_id = p.id and t.voided_at is null))::integer;
end $function$

;

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
    'cash_cents', (select t.amount_cents from public.airvalet_tip_records t where t.passenger_id = p.id and t.voided_at is null and t.method = 'CASH'),
    'stripe_cents', (select nullif(sum(y.amount_cents), 0) from public.payments y where y.passenger_id = p.id and y.type = 'TIP' and y.status = 'succeeded'),
    'notes', nullif(btrim(coalesce(p.obs, '')), ''))
  from (select coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts)) ci,
               coalesce((p.checkout_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.deldate)) dl) d
$function$

;

drop function if exists public.airvalet_daily_tips(date);
drop trigger if exists airvalet_tip_stage_default on public.airvalet_tip_records;
drop function if exists public.airvalet_tip_stage_default();
drop function if exists public.airvalet_tip_log(bigint, text, text, text, text, text);
drop index if exists public.airvalet_tip_records_active_pax;
create unique index if not exists airvalet_tip_records_one_active_cash
  on public.airvalet_tip_records (passenger_id) where voided_at is null and method = 'CASH';
alter table public.airvalet_tip_records drop constraint if exists airvalet_tip_records_stage_check;
alter table public.airvalet_tip_records drop column if exists stage;
alter table public.airvalet_tip_records drop constraint if exists airvalet_tip_records_source_check;
alter table public.airvalet_tip_records add constraint airvalet_tip_records_source_check
  check (source in ('DELIVERY', 'ADDED_LATER', 'CORRECTION', 'DELIVERY_LEGACY'));
commit;
