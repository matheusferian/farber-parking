-- Return operator (MAKERS | ASCEND | OTHER).
-- Self-contained: no dependency on the AirValet SMS (Twilio) migrations. The
-- Twilio phase extends the Needs Review view with its own sends later
-- (20261011_return_reviews_include_sms.sql).
--
-- Owner rules (2026-10-09):
--   * Departure and return are independent. Departure stays the existing
--     ticket-prefix rule ('A-' = Ascend, isAscend()); it is history and never
--     changes when the return changes.
--   * return_operator is THE source of truth for the return leg, editable the
--     whole trip. At insert it defaults from the legacy flags / departure;
--     after that nothing ever rewrites it automatically.
--   * Pickup place is derived, never stored:
--       MAKERS → HANGAR_19 · ASCEND → CUSTOMS · OTHER/NULL → none (manual)
--   * MAKERS returning via Customs is an operational EXCEPTION (never offered,
--     approved case by case). It already exists today as delivery_at_customs
--     ("Delivery at Customs"): on a MAKERS return it means "Customs exception
--     approved" — return_operator stays MAKERS. Reused as the override; who
--     approved and when comes from the existing activity_log. The only new
--     piece is customs_exception_requested_at (request under review).
--   * Effective pickup (derived, never stored):
--       MAKERS → HANGAR_19, or CUSTOMS when the exception is approved
--       ASCEND → CUSTOMS (rule, not an exception) · OTHER → manual (none)
--   * delivery_at_customs = true ONLY for MAKERS + staff-approved exception.
--     Flags can never contradict the return (trigger + CHECK backstop):
--       ASCEND → delivery_at_customs = false (Customs comes from the return
--                itself), no pending request
--       OTHER  → delivery_at_customs = false, no pending request
--       MAKERS → delivery_at_customs = staff decision, kept by every save /
--                edit; switching TO MAKERS from another return starts at
--                Hangar 19 (never an automatic exception); approving clears
--                the pending request
--       not_returning_with_makers_air ("Other Boat") = (return_operator = 'OTHER')
--     Rows with return_operator NULL (delivered/archived history) keep their
--     flags untouched.
--   * Changing the return after pickup instructions went out never sends
--     anything automatically: the conflict shows up in Needs Review (view
--     below) until staff send an update or mark "no update needed".
--   * Audit of who changed what/when uses the EXISTING activity_log
--     (field_name / old_value / new_value / changed_by) via saveEdits().
--
-- Existing data (prod read 2026-10-09): mixed trips are real (last 120 days:
-- 20 Ascend tickets delivered NORMAL, 31 Makers tickets delivered CUSTOMS).
-- Backfill only for passengers in custody (~33): "Other Boat" → OTHER,
-- otherwise the departure operator; an existing "Delivery at Customs" on a
-- Makers return is kept as an approved exception.

begin;

alter table public.passengers
  add column return_operator text
  constraint passengers_return_operator_check check (return_operator in ('MAKERS', 'ASCEND', 'OTHER'));
alter table public.passengers
  add column customs_exception_requested_at timestamptz;

comment on column public.passengers.customs_exception_requested_at is
  'MAKERS return only: passenger asked for Customs pickup; staff have not decided yet. Pickup stays Hangar 19 until delivery_at_customs is approved.';

comment on column public.passengers.return_operator is
  'Return leg (source of truth): MAKERS → Hangar 19 (Customs only as an approved exception = delivery_at_customs), ASCEND → Customs (delivery_at_customs stays false), OTHER → manual. Editable all trip.';

create or replace function public.airvalet_departure_operator(p_ticket text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when coalesce(p_ticket, '') ~ '^A-' then 'ASCEND' else 'MAKERS' end;
$$;

create or replace function public.airvalet_return_location(p_return_operator text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_return_operator when 'MAKERS' then 'HANGAR_19' when 'ASCEND' then 'CUSTOMS' end;
$$;

-- Effective pickup place, including the approved Makers Customs exception.
create or replace function public.airvalet_pickup_location(p_return_operator text, p_delivery_at_customs boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_return_operator
    when 'MAKERS' then case when coalesce(p_delivery_at_customs, false) then 'CUSTOMS' else 'HANGAR_19' end
    when 'ASCEND' then 'CUSTOMS'
  end;
$$;

-- Initial value: honour the legacy flags an older client may still send,
-- otherwise follow the departure. Same rule as the backfill below.
create or replace function public.airvalet_initial_return_operator(p_ticket text, p_not_returning boolean, p_at_customs boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  -- p_at_customs is NOT a return operator: on a Makers return it is the
  -- approved Customs exception (kept by the sync trigger).
  select case
    when coalesce(p_not_returning, false) then 'OTHER'
    else public.airvalet_departure_operator(p_ticket)
  end;
$$;

create or replace function public.airvalet_sync_return_operator()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.return_operator is null then
    new.return_operator := public.airvalet_initial_return_operator(
      new.ticket, new.not_returning_with_makers_air, new.delivery_at_customs);
  end if;
  -- Never rewrite return_operator on UPDATE by itself. Only exception: an
  -- older app version (before "Returning with") that toggles the legacy
  -- "Other Boat" checkbox without sending return_operator — honour that
  -- explicit staff action instead of silently undoing it.
  if tg_op = 'UPDATE' and old.return_operator is not null
     and new.return_operator is not distinct from old.return_operator
     and coalesce(new.not_returning_with_makers_air, false) is distinct from coalesce(old.not_returning_with_makers_air, false) then
    new.return_operator := case when coalesce(new.not_returning_with_makers_air, false) then 'OTHER'
                                else public.airvalet_departure_operator(new.ticket) end;
  end if;
  if new.return_operator is not null then
    new.not_returning_with_makers_air := (new.return_operator = 'OTHER');
    if new.return_operator <> 'MAKERS' then
      -- delivery_at_customs is ONLY the Makers Customs exception. For ASCEND,
      -- Customs comes from return_operator itself; for OTHER there is no place.
      -- (Also neutralises an old app writing delivery_at_customs = true.)
      new.delivery_at_customs := false;
      new.customs_exception_requested_at := null;
    else
      if tg_op = 'UPDATE' and old.return_operator is not null and old.return_operator <> 'MAKERS' then
        -- switched TO Makers: Hangar 19; never create an exception automatically
        new.delivery_at_customs := false;
        new.customs_exception_requested_at := null;
      end if;
      if new.delivery_at_customs then
        new.customs_exception_requested_at := null;  -- approved: request settled
      end if;
    end if;
  end if;
  return new;
end;
$$;

create trigger passengers_sync_return_operator
  before insert or update on public.passengers
  for each row execute function public.airvalet_sync_return_operator();

-- One-time backfill of passengers currently in custody.
update public.passengers p
   set return_operator = public.airvalet_initial_return_operator(p.ticket, p.not_returning_with_makers_air, p.delivery_at_customs)
 where p.status in ('PENDING', 'NO DATE') and p.return_operator is null;

-- Backstop: a row with a return operator can never hold contradictory flags.
alter table public.passengers
  add constraint passengers_return_flags_consistent check (
    return_operator is null
    or (coalesce(not_returning_with_makers_air, false) = (return_operator = 'OTHER')
        and (not delivery_at_customs or return_operator = 'MAKERS')
        and (customs_exception_requested_at is null
             or (return_operator = 'MAKERS' and not delivery_at_customs))));

-- ── Pickup instructions already given (legacy iOS Messages path) ──────────
-- The legacy native path only stamps welcome_back_sent_at /
-- customs_welcome_sent_at, so the PLACE told to the passenger is captured at
-- the moment of the stamp (it can't be recomputed later: the flags follow
-- the current return). Undo (stamp cleared) removes it.
create table public.airvalet_return_instructions (
  passenger_id bigint not null references public.passengers(id) on delete cascade,
  source       text not null check (source in ('legacy_welcome_back', 'legacy_customs_welcome')),
  place        text not null check (place in ('HANGAR_19', 'CUSTOMS')),
  sent_at      timestamptz not null,
  primary key (passenger_id, source)
);
alter table public.airvalet_return_instructions enable row level security;
revoke all on public.airvalet_return_instructions from public, anon, authenticated;
grant select on public.airvalet_return_instructions to authenticated;
grant all on public.airvalet_return_instructions to service_role;
create policy airvalet_return_instructions_select_ops on public.airvalet_return_instructions
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

create or replace function public.airvalet_capture_legacy_instructions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_place text;
begin
  if tg_op = 'INSERT' or new.welcome_back_sent_at is distinct from old.welcome_back_sent_at then
    if new.welcome_back_sent_at is null then
      delete from public.airvalet_return_instructions where passenger_id = new.id and source = 'legacy_welcome_back';
    else
      -- What the legacy button actually sent: Customs text when the vehicle
      -- goes to Customs, otherwise the Hangar 19 text.
      v_place := coalesce(public.airvalet_pickup_location(new.return_operator, new.delivery_at_customs),
                          case when new.delivery_at_customs then 'CUSTOMS' else 'HANGAR_19' end);
      insert into public.airvalet_return_instructions (passenger_id, source, place, sent_at)
      values (new.id, 'legacy_welcome_back', v_place, new.welcome_back_sent_at)
      on conflict (passenger_id, source) do update set place = excluded.place, sent_at = excluded.sent_at;
    end if;
  end if;
  if tg_op = 'INSERT' or new.customs_welcome_sent_at is distinct from old.customs_welcome_sent_at then
    if new.customs_welcome_sent_at is null then
      delete from public.airvalet_return_instructions where passenger_id = new.id and source = 'legacy_customs_welcome';
    else
      insert into public.airvalet_return_instructions (passenger_id, source, place, sent_at)
      values (new.id, 'legacy_customs_welcome', 'CUSTOMS', new.customs_welcome_sent_at)
      on conflict (passenger_id, source) do update set place = excluded.place, sent_at = excluded.sent_at;
    end if;
  end if;
  return null;
end;
$$;

create trigger passengers_capture_legacy_instructions
  after insert or update of welcome_back_sent_at, customs_welcome_sent_at on public.passengers
  for each row execute function public.airvalet_capture_legacy_instructions();

-- Snapshot of instructions already given to passengers in custody, taken
-- right after the backfill (flags still equal what was true when sent).
insert into public.airvalet_return_instructions (passenger_id, source, place, sent_at)
select p.id, 'legacy_welcome_back',
       coalesce(public.airvalet_pickup_location(p.return_operator, p.delivery_at_customs),
                case when p.delivery_at_customs then 'CUSTOMS' else 'HANGAR_19' end), p.welcome_back_sent_at
  from public.passengers p
 where p.status in ('PENDING', 'NO DATE') and p.welcome_back_sent_at is not null
on conflict do nothing;
insert into public.airvalet_return_instructions (passenger_id, source, place, sent_at)
select p.id, 'legacy_customs_welcome', 'CUSTOMS', p.customs_welcome_sent_at
  from public.passengers p
 where p.status in ('PENDING', 'NO DATE') and p.customs_welcome_sent_at is not null
on conflict do nothing;

-- ── Needs Review: return changed after pickup instructions went out ──────
create table public.airvalet_return_review_acks (
  id              uuid primary key default gen_random_uuid(),
  passenger_id    bigint not null references public.passengers(id) on delete cascade,
  instructions_at timestamptz not null,
  return_operator text,
  resolution      text not null check (resolution in ('UPDATE_SENT', 'NO_UPDATE_NEEDED')),
  acknowledged_by uuid,
  acknowledged_at timestamptz not null default now()
);
alter table public.airvalet_return_review_acks enable row level security;
revoke all on public.airvalet_return_review_acks from public, anon, authenticated;
grant select on public.airvalet_return_review_acks to authenticated;
grant all on public.airvalet_return_review_acks to service_role;
create policy airvalet_return_review_acks_select_ops on public.airvalet_return_review_acks
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

create view public.airvalet_return_reviews with (security_invoker = true) as
with sent as (
  select i.passenger_id, i.place, i.sent_at as at, 'legacy_ios'::text as source
    from public.airvalet_return_instructions i
), latest as (
  select distinct on (s.passenger_id) s.passenger_id, s.place, s.at, s.source
    from sent s where s.place is not null
   order by s.passenger_id, s.at desc
)
select p.id as passenger_id, p.name, p.ticket, p.status,
       public.airvalet_departure_operator(p.ticket) as departure_operator,
       p.return_operator,
       public.airvalet_pickup_location(p.return_operator, p.delivery_at_customs) as current_place,
       l.place as instructions_place, l.at as instructions_at, l.source as instructions_source,
       'Return changed - passenger may have old instructions'::text as reason
  from public.passengers p
  join latest l on l.passenger_id = p.id
 where p.status in ('PENDING', 'NO DATE')
   and l.place is distinct from public.airvalet_pickup_location(p.return_operator, p.delivery_at_customs)
   and not exists (
     select 1 from public.airvalet_return_review_acks a
      where a.passenger_id = p.id and a.instructions_at = l.at
        and a.return_operator is not distinct from p.return_operator);

revoke all on public.airvalet_return_reviews from public, anon, authenticated;
grant select on public.airvalet_return_reviews to authenticated, service_role;

create or replace function public.airvalet_return_review_ack(p_passenger_id bigint, p_resolution text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_role public.account_role := public.current_user_role();
begin
  if v_role is null or v_role not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_resolution not in ('UPDATE_SENT', 'NO_UPDATE_NEEDED') then
    raise exception 'invalid resolution' using errcode = '22023';
  end if;
  select v.instructions_at, v.return_operator into r
    from public.airvalet_return_reviews v where v.passenger_id = p_passenger_id;
  if r.instructions_at is null then
    return; -- nothing to acknowledge (already resolved)
  end if;
  insert into public.airvalet_return_review_acks (passenger_id, instructions_at, return_operator, resolution, acknowledged_by)
  values (p_passenger_id, r.instructions_at, r.return_operator, p_resolution, auth.uid());
end;
$$;

revoke all on function public.airvalet_departure_operator(text) from public, anon;
revoke all on function public.airvalet_return_location(text) from public, anon;
revoke all on function public.airvalet_initial_return_operator(text, boolean, boolean) from public, anon;
revoke all on function public.airvalet_pickup_location(text, boolean) from public, anon;
grant execute on function public.airvalet_pickup_location(text, boolean) to authenticated, service_role;
revoke all on function public.airvalet_sync_return_operator() from public, anon, authenticated;
revoke all on function public.airvalet_capture_legacy_instructions() from public, anon, authenticated;
revoke all on function public.airvalet_return_review_ack(bigint, text) from public, anon;
grant execute on function public.airvalet_departure_operator(text) to authenticated, service_role;
grant execute on function public.airvalet_return_location(text) to authenticated, service_role;
grant execute on function public.airvalet_initial_return_operator(text, boolean, boolean) to authenticated, service_role;
grant execute on function public.airvalet_return_review_ack(bigint, text) to authenticated;

commit;
