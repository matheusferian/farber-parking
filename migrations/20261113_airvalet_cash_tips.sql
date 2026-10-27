-- AirValet — Smart Tips & Closing Report (owner 2026-10-27). LOCAL ONLY until owner GO.
-- Requires 20261112_airvalet_pass_gratuity.sql (production airvalet_portal_view,
-- md5 caf314d92eea95c5629754a9679e2646 before this change). Does NOT touch the
-- dynamic Checkout: settings, payments, valet-pass and stripe-webhook unchanged.
--
--   1. airvalet_tip_records: the in-person (cash) tip ledger. One row per amount
--      recorded, never updated in place, never deleted: a correction voids the
--      row (who, when, why) and adds the new amount (supersedes_id). Staff read
--      it; nobody writes it directly — only the two functions below.
--        airvalet_tip_record(passenger, cents, client_key, received_by, source)
--        airvalet_tip_correct(tip_id, new cents | null = remove, reason, client_key)
--      Who recorded = the signed-in account (from the JWT, never from the app).
--      One active cash tip per ticket; the same client_key twice = one row
--      (double tap, retry, second device). A day whose Closing Report is closed
--      can only be changed by an ADMIN (the report keeps its snapshot).
--   2. passengers.tip_in_person_cents stays as a mirror of the active amount.
--      An app still on v85 writes it directly at delivery: the trigger turns
--      that write into an audited ledger row (DELIVERY_LEGACY). Any other direct
--      change of an existing amount is refused (use Correct).
--   3. daily_closing_reports: staff type only the cash counted in the box (B).
--      The server computes A = cash tips on tickets that day, Other Tips =
--      max(B − A, 0), difference = B − A, Total = Stripe + B (never A + B). A
--      negative difference closes only after the team confirms the review.
--      Reports without cash_counted_cents (old app, old days) are unchanged.
--   4. airvalet_portal_view: + 'tip_thanks' (true/false) for the Valet Pass
--      thank-you. Never the amount.
--
-- Re-runnable (same end state). Rollback: 20261113_airvalet_cash_tips_rollback.sql

begin;
set local lock_timeout = '5s';

-- ── 1. Ledger ─────────────────────────────────────────────────────────────
create table if not exists public.airvalet_tip_records (
  id               bigint generated always as identity primary key,
  passenger_id     bigint references public.passengers(id) on delete set null,
  ticket           text,
  amount_cents     integer not null check (amount_cents between 1 and 100000),
  method           text not null default 'CASH' check (method in ('CASH')),
  source           text not null check (source in ('DELIVERY', 'ADDED_LATER', 'CORRECTION', 'DELIVERY_LEGACY')),
  business_date    date not null,
  received_by_name text check (received_by_name is null or char_length(received_by_name) between 1 and 80),
  recorded_by      text not null,
  recorded_at      timestamptz not null default now(),
  client_key       uuid unique,
  supersedes_id    bigint references public.airvalet_tip_records(id),
  voided_at        timestamptz,
  voided_by        text,
  void_reason      text check (void_reason is null or char_length(void_reason) between 3 and 200),
  void_client_key  uuid unique,
  constraint airvalet_tip_records_void_complete check ((voided_at is null) = (void_reason is null) and (voided_at is null) = (voided_by is null))
);
create unique index if not exists airvalet_tip_records_one_active_cash
  on public.airvalet_tip_records (passenger_id) where voided_at is null and method = 'CASH';
create index if not exists airvalet_tip_records_day
  on public.airvalet_tip_records (business_date) where voided_at is null;

alter table public.airvalet_tip_records enable row level security;
revoke all on public.airvalet_tip_records from public, anon, authenticated;
grant select on public.airvalet_tip_records to authenticated;
drop policy if exists airvalet_tip_records_select_ops on public.airvalet_tip_records;
create policy airvalet_tip_records_select_ops on public.airvalet_tip_records for select to authenticated
  using (public.current_user_role() = any (array['ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER']::public.account_role[]));

-- Mirror on the car + one line in the ticket history (activity_log), same
-- format as the other server-side history rows.
create or replace function public.airvalet_tip_mirror(p_passenger_id bigint, p_cents integer, p_tip_received boolean,
                                                     p_actor text, p_action text, p_detail text, p_old text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
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
end $$;
revoke all on function public.airvalet_tip_correct(bigint, integer, text, uuid) from public, anon;
grant execute on function public.airvalet_tip_correct(bigint, integer, text, uuid) to authenticated;

-- ── 2. Direct writes to the mirror (app v85 at delivery) ─────────────────
create or replace function public.airvalet_tip_legacy_capture()
returns trigger language plpgsql security definer set search_path = '' as $$
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
end $$;
revoke all on function public.airvalet_tip_legacy_capture() from public, anon, authenticated;
drop trigger if exists airvalet_tip_legacy_capture on public.passengers;
create trigger airvalet_tip_legacy_capture before update of tip_in_person_cents on public.passengers
  for each row execute function public.airvalet_tip_legacy_capture();

-- Amounts already stored on cars before this migration join the ledger once.
insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, method, source, business_date, recorded_by)
select p.id, p.ticket, p.tip_in_person_cents, 'CASH', 'DELIVERY_LEGACY',
       coalesce((p.checkout_date at time zone 'America/New_York')::date, (p.created_at at time zone 'America/New_York')::date), 'backfill-20261113'
  from public.passengers p
 where p.tip_in_person_cents is not null
   and not exists (select 1 from public.airvalet_tip_records t where t.passenger_id = p.id);

-- ── 3. Closing Report: cash reconciliation computed by the server ─────────
alter table public.daily_closing_reports
  add column if not exists cash_counted_cents     integer check (cash_counted_cents is null or cash_counted_cents between 0 and 10000000),
  add column if not exists ticket_cash_tips_cents integer,
  add column if not exists cash_difference_cents  integer,
  add column if not exists cash_reconciliation    text check (cash_reconciliation is null or cash_reconciliation in ('RECONCILED', 'OTHER_TIPS', 'SHORT')),
  add column if not exists cash_review_ack        boolean not null default false,
  add column if not exists cash_tickets_no_amount integer;

-- A for a business day (and the cars marked "tip received" with no amount).
-- Also read by the app's Closing Report form (ops roles only).
create or replace function public.airvalet_cash_tips_for_date(p_date date)
returns table (cash_cents integer, tickets integer, no_amount integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.current_user_role() is null or public.current_user_role() not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER') then
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
end $$;
revoke all on function public.airvalet_cash_tips_for_date(date) from public, anon;
grant execute on function public.airvalet_cash_tips_for_date(date) to authenticated;

create or replace function public.airvalet_dcr_cash_reconcile()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_admin boolean := public.current_user_role() is not distinct from 'ADMIN';
  v_c     record;
begin
  if tg_op = 'UPDATE' and old.closed_at is not null then
    -- Closed: the snapshot stays (only an ADMIN may touch it, as with the other totals).
    if current_user in ('authenticated', 'anon') and not v_admin and (
         new.cash_counted_cents is distinct from old.cash_counted_cents
      or new.ticket_cash_tips_cents is distinct from old.ticket_cash_tips_cents
      or new.cash_difference_cents is distinct from old.cash_difference_cents
      or new.cash_reconciliation is distinct from old.cash_reconciliation
      or new.cash_review_ack is distinct from old.cash_review_ack
      or new.cash_tickets_no_amount is distinct from old.cash_tickets_no_amount) then
      raise exception 'daily_closing_reports: the closing report for % is already closed', old.report_date using errcode = '42501';
    end if;
    return new;
  end if;
  if new.cash_counted_cents is null then
    -- Old app / old flow: Other Tips typed by hand, nothing reconciled.
    new.ticket_cash_tips_cents := null; new.cash_difference_cents := null;
    new.cash_reconciliation := null; new.cash_review_ack := false; new.cash_tickets_no_amount := null;
    return new;
  end if;
  select * into v_c from public.airvalet_cash_tips_for_date(new.report_date);
  new.ticket_cash_tips_cents := v_c.cash_cents;
  new.cash_difference_cents  := new.cash_counted_cents - v_c.cash_cents;
  new.other_tips_cents       := greatest(new.cash_counted_cents - v_c.cash_cents, 0);   -- never negative
  new.total_tips_cents       := coalesce(new.stripe_tips_cents, 0) + new.cash_counted_cents;   -- Stripe + B, never A + B
  new.cash_reconciliation    := case when new.cash_counted_cents = v_c.cash_cents then 'RECONCILED'
                                     when new.cash_counted_cents > v_c.cash_cents then 'OTHER_TIPS' else 'SHORT' end;
  if new.cash_reconciliation <> 'SHORT' then new.cash_review_ack := false; end if;
  new.cash_tickets_no_amount := v_c.no_amount;
  if new.closed_at is not null and new.cash_reconciliation = 'SHORT' and not new.cash_review_ack then
    raise exception 'daily_closing_reports: cash counted is below the cash tips on tickets; review before closing'
      using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.airvalet_dcr_cash_reconcile() from public;
drop trigger if exists trg_dcr_cash_reconcile on public.daily_closing_reports;
create trigger trg_dcr_cash_reconcile before insert or update on public.daily_closing_reports
  for each row execute function public.airvalet_dcr_cash_reconcile();

-- ── 4. airvalet_portal_view: production definition + 'tip_thanks' ────────
CREATE OR REPLACE FUNCTION public.airvalet_portal_view(p_token text, p_client text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r        record;
  v_p      public.passengers%rowtype;
  v_st     public.airvalet_pass_state%rowtype;
  v_set    public.airvalet_portal_settings%rowtype;
  v_req    public.airvalet_pass_requests%rowtype;
  v_wash   public.airvalet_pass_requests%rowtype;
  v_pickup text;
  v_status text;
  v_ret_at timestamptz;
  v_today  date := (now() at time zone 'America/New_York')::date;
  v_wash_state text;
  v_vehicle text;
  v_ref    text;
begin
  select * into r from public.airvalet_portal_resolve(p_token, p_client);
  if r.o_state <> 'ok' then return jsonb_build_object('state', r.o_state); end if;

  select * into v_p   from public.passengers p where p.id = r.o_passenger_id;
  select * into v_st  from public.airvalet_pass_state s where s.passenger_id = v_p.id;
  select * into v_set from public.airvalet_portal_settings;
  select * into v_req from public.airvalet_pass_requests q
   where q.passenger_id = v_p.id and q.kind = 'RETURN_CHANGE' and q.status = 'PENDING';
  select * into v_wash from public.airvalet_pass_requests q
   where q.passenger_id = v_p.id and q.kind = 'CAR_WASH' and q.status = 'PENDING';

  update public.airvalet_pass_links l
     set first_opened_at = coalesce(l.first_opened_at, now()), last_opened_at = now(), open_count = l.open_count + 1
   where l.id = r.o_link_id;

  -- P3: Customs only when the team confirmed it. MAKERS + approved exception
  -- (delivery_at_customs) is a staff decision already; ASCEND needs the
  -- explicit confirmation. Until then: no pickup place is promised.
  v_pickup := case
    when v_p.return_operator = 'MAKERS' and coalesce(v_p.delivery_at_customs, false) then 'CUSTOMS_EXCEPTION'
    when v_p.return_operator = 'MAKERS' then 'HANGAR_19'
    when v_p.return_operator = 'ASCEND' and v_st.customs_confirmed_at is not null then 'CUSTOMS_ASCEND'
    when v_p.return_operator = 'ASCEND' then 'TO_BE_CONFIRMED'
    else 'OTHER' end;
  v_status := case
    -- car waiting at Customs until the gratuity link goes out (owner 2026-10-25)
    when v_p.status = 'DELIVERED' and v_p.delivery_type = 'CUSTOMS' and coalesce(v_p.customs_gratuity_sent, false) = false then 'CUSTOMS_CONFIRMED'
    when v_p.status = 'DELIVERED' then 'DELIVERED'
    when v_pickup in ('CUSTOMS_EXCEPTION', 'CUSTOMS_ASCEND') and v_st.ready_at is not null then 'CUSTOMS_CONFIRMED'
    when v_st.ready_at is not null then 'READY'
    -- HANGAR 19 on the return day (owner 2026-10-25)
    when v_pickup = 'HANGAR_19' and upper(btrim(coalesce(v_p.loc, ''))) = 'HANGAR 19'
         and (public.airvalet_return_at(v_p.ret, null) at time zone 'America/New_York')::date = (now() at time zone 'America/New_York')::date then 'READY'
    else 'PARKED' end;

  v_ret_at := public.airvalet_return_at(v_p.ret, v_p.ret_time);
  v_wash_state := case
    when v_p.status not in ('PENDING', 'NO DATE') or v_st.ready_at is not null then 'NONE'
    when v_wash.id is not null then 'REQUESTED'
    when v_p.carwash_status = 'CARWASH' then 'SCHEDULED'
    when v_p.carwash_status = 'SEND_PRICE' then 'PRICE_PENDING'
    when v_p.carwash_status = 'WASHED' then 'DONE'
    when v_ret_at is not null and v_ret_at - now() >= make_interval(hours => v_set.car_wash_lead_hours) then 'REQUEST'
    else 'CONTACT' end;
  v_vehicle := nullif(btrim(concat_ws(' ', nullif(btrim(coalesce(v_p.color, '')), ''), nullif(btrim(coalesce(v_p.car, '')), ''))), '');
  -- Stage 1 (flag gratuity_reference, OFF by default): Stripe ties the tip to the car.
  v_ref := case when v_set.gratuity_reference then '?client_reference_id=pax-' || v_p.id else '' end;

  return jsonb_build_object(
    'state', 'ok',
    'pass', jsonb_build_object(
      -- the guest's own ticket number, shown small on the pass for reference (owner 2026-10-26)
      'ticket', nullif(btrim(coalesce(v_p.ticket, '')), ''),
      'first_name', nullif(initcap(split_part(btrim(coalesce(v_p.name, '')), ' ', 1)), ''),
      'vehicle', v_vehicle,
      'status', v_status,
      'pickup', v_pickup,
      'return_date', nullif(btrim(coalesce(v_p.ret, '')), ''),
      'return_time', to_char(v_p.ret_time, 'HH24:MI'),
      'return_flight', nullif(upper(btrim(coalesce(v_p.return_flight, ''))), ''),
      'arrival_time', case when btrim(coalesce(v_p.departure_time, '')) ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' then btrim(v_p.departure_time) end,
      'pending_return', case when v_req.id is null then null else jsonb_build_object(
          'reason', v_req.reason, 'date', v_req.requested_date, 'time', to_char(v_req.requested_time, 'HH24:MI'),
          'carrier', v_req.carrier, 'created_at', v_req.created_at) end,
      'car_wash', v_wash_state,
      'ready_by_staff', v_st.ready_at is not null,
      'car_wash_lead_hours', v_set.car_wash_lead_hours,
      'lockbox', case when v_st.lockbox_authorized_at is null  -- audit 1105: lockbox
                       or v_p.status in ('DELIVERED', 'ARCHIVED') or v_status in ('DELIVERED', 'CUSTOMS_CONFIRMED')
                       or nullif(btrim(coalesce(v_p.pickup_auth_name, '')), '') is not null
                       or (public.airvalet_return_at(v_p.ret, null) is not null
                           and (public.airvalet_return_at(v_p.ret, null) at time zone 'America/New_York')::date < v_today)
                     then null else jsonb_build_object(
          'authorized', true,
          'reveal_on', v_st.lockbox_reveal_on,
          'code', case when v_st.lockbox_reveal_on is not null and v_today >= v_st.lockbox_reveal_on then v_st.lockbox_code end) end,
      'requests_enabled', v_set.requests_enabled and v_p.status in ('PENDING', 'NO DATE'),
      'chat_enabled', v_set.chat_enabled and v_p.status <> 'ARCHIVED',
      'valet_hours', v_set.valet_hours,
      'contacts', jsonb_strip_nulls(jsonb_build_object(
          'valet_phone', v_set.valet_phone, 'text_phone', v_set.text_phone, 'reservations_phone', v_set.reservations_phone)),
      'gratuity_url', case when v_set.gratuity_url is not null then v_set.gratuity_url || v_ref end,
      -- Dynamic checkout amounts (flag, OFF by default). Dollars for display; the
      -- server re-checks every amount against min/max before calling Stripe.
      'gratuity_checkout', case when v_set.gratuity_checkout_enabled or v_p.id = any (v_set.gratuity_checkout_passenger_ids) then jsonb_build_object(
          'amounts', (select jsonb_agg(a / 100.0 order by o) from unnest(v_set.gratuity_amounts_cents) with ordinality u(a, o)),
          'min', v_set.gratuity_min_cents / 100.0, 'max', v_set.gratuity_max_cents / 100.0) end,
      'terms_published', v_set.terms_published,
      -- Smart Tips (owner 2026-10-27): a tip was received in person → the pass thanks
      -- the guest instead of asking. Yes/no only, never the amount.
      'tip_thanks', v_p.status = 'DELIVERED' and coalesce(v_p.tip_received, false)
    ));
end $function$;

commit;
