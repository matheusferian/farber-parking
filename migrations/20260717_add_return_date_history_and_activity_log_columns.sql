-- Passenger Change History + atomic Return Date changes.
--
-- Additive only against existing tables (activity_log gains five nullable
-- columns; passengers is never altered). Creates one new table
-- (passenger_return_date_changes) and one new RPC
-- (change_passenger_return_date_with_reason) that performs a manual
-- return-date correction, its mandatory reason, and its Activity Log entry
-- as a single atomic transaction — see DECISIONS.md-style rationale in the
-- accompanying implementation report: a three-step frontend sequence
-- (update passenger -> insert history -> insert log) could leave a changed
-- return date with no permanent reason and no audit trail if any later step
-- failed, which is unacceptable for this workflow.
--
-- Does NOT touch `passengers`, `daily_closing_reports`, `contact_sync_*`,
-- or any other existing table/column. Safe to run more than once (all
-- statements are idempotent / use IF NOT EXISTS or CREATE OR REPLACE).

BEGIN;

-- ── A. ACTIVITY LOG: structured columns ─────────────────────────────────
-- Existing `passenger`/`ticket`/`location`/`detail` text columns are left
-- exactly as they are — the current global Activity Log UI reads only
-- those and must keep working unmodified. These five columns are additive
-- metadata for the new per-passenger Passenger Change History feature and
-- for reliable identity/reason association (Architectural Corrections 1-3).

alter table public.activity_log add column if not exists passenger_id bigint;
alter table public.activity_log add column if not exists changed_by   text;
alter table public.activity_log add column if not exists field_name   text;
alter table public.activity_log add column if not exists old_value    text;
alter table public.activity_log add column if not exists new_value    text;

do $$
begin
  if not exists (
    select 1 from information_schema.table_constraints
    where table_schema = 'public' and table_name = 'activity_log'
      and constraint_name = 'activity_log_passenger_id_fkey'
  ) then
    alter table public.activity_log
      add constraint activity_log_passenger_id_fkey
      foreign key (passenger_id) references public.passengers(id) on delete set null;
  end if;
end $$;

-- Both indexes below are on `passenger_id`, a column that did not exist
-- before this migration — neither could possibly have pre-existed under
-- these names, so the rollback can drop them unconditionally with no risk
-- to any pre-existing object. (An index on the pre-existing `action`
-- column was deliberately NOT added here: the per-passenger history query
-- filters by passenger_id/created_at only, an action-column index isn't
-- required by this feature, and adding one would have made the rollback
-- responsible for dropping something on a column it didn't create.)
create index if not exists idx_activity_log_passenger_id            on public.activity_log(passenger_id);
create index if not exists idx_activity_log_passenger_id_created_at on public.activity_log(passenger_id, created_at desc);

-- ── B. RETURN-DATE HISTORY TABLE ────────────────────────────────────────
-- Permanent record of every manual return-date change and its mandatory
-- reason. `activity_log_id` is the direct link back to the single
-- corresponding activity_log row (Correction 3) — the Passenger Change
-- History UI renders ONE card per RETURN DATE change by joining through
-- this id, never by matching name/ticket/timestamp.

create extension if not exists pgcrypto;

create table if not exists public.passenger_return_date_changes (
  id               uuid primary key default gen_random_uuid(),
  passenger_id     bigint references public.passengers(id) on delete set null,
  activity_log_id  bigint references public.activity_log(id) on delete set null,
  passenger_name   text not null,
  ticket           text,
  old_return_date  text,
  new_return_date  text,
  comment          text not null,
  changed_by       text not null,
  created_at       timestamptz not null default now(),

  constraint prdc_comment_length check (
    char_length(btrim(comment)) >= 5 and char_length(comment) <= 500
  )
);

create index if not exists idx_prdc_passenger_id            on public.passenger_return_date_changes(passenger_id);
create index if not exists idx_prdc_activity_log_id         on public.passenger_return_date_changes(activity_log_id);
create index if not exists idx_prdc_created_at              on public.passenger_return_date_changes(created_at desc);
create index if not exists idx_prdc_passenger_id_created_at on public.passenger_return_date_changes(passenger_id, created_at desc);

alter table public.passenger_return_date_changes enable row level security;

drop policy if exists "prdc_select_authenticated" on public.passenger_return_date_changes;
create policy "prdc_select_authenticated"
  on public.passenger_return_date_changes for select to authenticated using (true);

-- No INSERT/UPDATE/DELETE policy for any frontend role: rows are written
-- exclusively by the SECURITY DEFINER RPC below (which bypasses RLS as its
-- owning role), never directly by an authenticated app session. This is
-- what makes the history immutable from the frontend, per the requirement.

-- ── C. INTERNAL HELPERS (not exposed as RPC endpoints) ──────────────────
-- Mirrors utils.js's pd()/d2us() (M/D/YYYY, no zero-padding) and index.html's
-- cleanApproxFromObs() exactly, so the database's notion of "did the return
-- date really change" and "strip the approx tag" matches what the app has
-- always done client-side. Kept as separate small functions (not inlined
-- into the RPC) for readability and unit-testability from the SQL editor.

create or replace function public._normalize_ret_date(p_val text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
  parts text[];
  mm int; dd int; yy int;
begin
  v := btrim(coalesce(p_val, ''));
  if v = '' then
    return '';
  end if;
  parts := string_to_array(v, '/');
  if array_length(parts, 1) = 3 then
    begin
      mm := nullif(parts[1], '')::int;
      dd := nullif(parts[2], '')::int;
      yy := nullif(parts[3], '')::int;
    exception when others then
      mm := null; dd := null; yy := null;
    end;
    if mm is not null and dd is not null and yy is not null then
      return lpad(yy::text, 4, '0') || '-' || lpad(mm::text, 2, '0') || '-' || lpad(dd::text, 2, '0');
    end if;
  end if;
  -- Defensive fallback only — passengers.ret is always written by the app
  -- as M/D/YYYY, but never silently drop a comparison on an unexpected shape.
  return v;
end;
$$;

revoke all on function public._normalize_ret_date(text) from public, anon, authenticated;

create or replace function public._clean_approx_from_obs(p_obs text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := coalesce(p_obs, '');
  v := regexp_replace(v, '\s*\[?~?APPROX(?:IMATE)?(?: DATE)?\]?\s*', ' ', 'gi');
  v := regexp_replace(v, '\s*APPROX DATE\s*[:\-]?\s*', ' ', 'gi');
  v := regexp_replace(v, '\s*ESTIMATED RETURN DATE\s*[:\-]?\s*', ' ', 'gi');
  v := regexp_replace(v, '\s*ESTIMATED\s*[:\-]?\s*', ' ', 'gi');
  v := regexp_replace(v, '\s*APPROX\s*[:\-]?\s*', ' ', 'gi');
  v := regexp_replace(v, '\s{2,}', ' ', 'g');
  return btrim(v);
end;
$$;

revoke all on function public._clean_approx_from_obs(text) from public, anon, authenticated;

-- Rejects malformed or impossible dates (e.g. "abc", "13/40/2026",
-- "2/30/2026") before they can ever reach passengers.ret. Blank is always
-- valid (Open Return Date). Does not change the storage format — a value
-- that passes this check is still written to passengers.ret exactly as
-- given (M/D/YYYY text), never converted to a native date type.
create or replace function public._is_valid_ret_date(p_val text)
returns boolean
language plpgsql
immutable
as $$
declare
  v text;
  parts text[];
  mm int; dd int; yy int;
  d date;
begin
  v := btrim(coalesce(p_val, ''));
  if v = '' then
    return true;
  end if;
  parts := string_to_array(v, '/');
  if array_length(parts, 1) <> 3 then
    return false;
  end if;
  begin
    mm := parts[1]::int;
    dd := parts[2]::int;
    yy := parts[3]::int;
  exception when others then
    return false; -- non-numeric parts, e.g. "abc"
  end;
  if mm < 1 or mm > 12 or dd < 1 or dd > 31 or yy < 2000 or yy > 2099 then
    return false;
  end if;
  begin
    d := make_date(yy, mm, dd); -- throws for impossible combinations, e.g. Feb 30
  exception when others then
    return false;
  end;
  return true;
end;
$$;

revoke all on function public._is_valid_ret_date(text) from public, anon, authenticated;

-- ── D. ATOMIC RPC ────────────────────────────────────────────────────────
-- Performs a manual return-date change, its mandatory reason, and its
-- Activity Log entry as one transaction. Mirrors saveEdits()'s existing
-- side-effect rules exactly:
--   - NO DATE -> PENDING promotion when a real date is now set
--   - APPROX/ESTIMATED obs-tag cleanup when a real date is now set
--   - optional reopen-from-DELIVERED (status -> PENDING, deldate cleared,
--     "REOPENED FROM DELIVERED" appended to obs, a second REOPENED log row)
--     ONLY when the frontend explicitly passes p_reopen = true, matching
--     the existing confirm() gate in saveEdits() (declining that confirm
--     leaves status/deldate untouched even though ret still changes, which
--     is the app's existing, preserved behavior).
--
-- SECURITY DEFINER is required because normal authenticated sessions have
-- no INSERT policy on activity_log's structured use here or on
-- passenger_return_date_changes at all. search_path is pinned to prevent
-- search-path hijacking. Authentication is gated on auth.uid() — the
-- authoritative "is there a real session" check, derived from the JWT's
-- `sub` claim by Supabase's auth schema — not merely on the presence of a
-- custom `email` claim. changed_by is derived server-side (auth.uid(),
-- with auth.jwt()->>'email' preferred when present); the frontend cannot
-- supply it.

create or replace function public.change_passenger_return_date_with_reason(
  p_passenger_id     bigint,
  p_new_return_date  text,
  p_reason           text,
  p_reopen           boolean default false
)
returns public.passengers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid        uuid;
  v_email      text;
  v_row        public.passengers%rowtype;
  v_new_ret    text;
  v_old_norm   text;
  v_new_norm   text;
  v_reason     text;
  v_new_status text;
  v_new_obs    text;
  v_new_deldate text;
  v_has_real_date boolean;
  v_log_id     bigint;
  v_old_disp   text;
  v_new_disp   text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'change_passenger_return_date_with_reason: authentication required';
  end if;

  v_email := auth.jwt() ->> 'email';
  if v_email is null or btrim(v_email) = '' then
    -- A valid session (auth.uid() present) but no email claim on the JWT —
    -- fall back to the uid itself so changed_by is always a stable,
    -- server-derived identifier and is never left blank or accepted from
    -- the client, even in this edge case.
    v_email := v_uid::text;
  end if;

  if p_passenger_id is null then
    raise exception 'change_passenger_return_date_with_reason: passenger id is required';
  end if;

  select * into v_row from public.passengers where id = p_passenger_id for update;
  if not found then
    raise exception 'change_passenger_return_date_with_reason: passenger % not found', p_passenger_id;
  end if;

  if p_reopen and v_row.status <> 'DELIVERED' then
    raise exception 'change_passenger_return_date_with_reason: p_reopen may only be used when the passenger status is DELIVERED (current status: %)', v_row.status;
  end if;

  -- Canonical trimmed value: used for every subsequent read of the "new
  -- return date" in this function — validation, normalization/comparison,
  -- the passengers.ret write, both log/history detail strings, the
  -- REOPENED text, and the returned row. A blank or whitespace-only input
  -- becomes '' (Open Return Date). Storage format is unchanged — still
  -- M/D/YYYY text, never converted to ISO/native date.
  v_new_ret := btrim(coalesce(p_new_return_date, ''));

  if not public._is_valid_ret_date(v_new_ret) then
    raise exception 'change_passenger_return_date_with_reason: invalid return date (expected blank for Open Return Date, or a valid M/D/YYYY date)';
  end if;

  v_old_norm := public._normalize_ret_date(v_row.ret);
  v_new_norm := public._normalize_ret_date(v_new_ret);

  if v_old_norm is not distinct from v_new_norm then
    raise exception 'change_passenger_return_date_with_reason: new return date is not different from the current return date';
  end if;

  v_reason := btrim(coalesce(p_reason, ''));
  if char_length(v_reason) < 5 then
    raise exception 'change_passenger_return_date_with_reason: reason must be at least 5 characters';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'change_passenger_return_date_with_reason: reason must be at most 500 characters';
  end if;

  v_has_real_date := v_new_ret <> '';

  if p_reopen then
    -- Mirrors saveEdits()'s doReopen branch exactly: unconditional status/
    -- deldate/obs overwrite, independent of the NO-DATE-promotion/APPROX-
    -- cleanup branch below (which only runs when NOT reopening, same as
    -- the frontend today).
    v_new_status  := 'PENDING';
    v_new_deldate := null;
    v_new_obs     := case when btrim(coalesce(v_row.obs, '')) <> ''
                          then btrim(v_row.obs) || ' | REOPENED FROM DELIVERED'
                          else 'REOPENED FROM DELIVERED' end;
  else
    v_new_status  := v_row.status;
    v_new_obs     := v_row.obs;
    v_new_deldate := v_row.deldate;
    if v_has_real_date then
      v_new_obs := public._clean_approx_from_obs(v_row.obs);
      if v_new_status = 'NO DATE' then
        v_new_status := 'PENDING';
      end if;
    end if;
  end if;

  update public.passengers
     set ret     = v_new_ret,
         status  = v_new_status,
         obs     = v_new_obs,
         deldate = v_new_deldate
   where id = p_passenger_id;

  v_old_disp := case when btrim(coalesce(v_row.ret, '')) = '' then 'Open Return Date' else v_row.ret end;
  v_new_disp := case when not v_has_real_date then 'Open Return Date' else v_new_ret end;

  insert into public.activity_log
    (ts, action, passenger, ticket, location, detail,
     passenger_id, changed_by, field_name, old_value, new_value)
  values
    (to_char(now(), 'MM/DD/YYYY, HH12:MI:SS AM'), 'RETURN DATE', v_row.name, v_row.ticket, v_row.loc,
     'Return date changed: ' || v_old_disp || ' → ' || v_new_disp || ' | Reason: ' || v_reason,
     p_passenger_id, v_email, 'ret', v_old_disp, v_new_disp)
  returning id into v_log_id;

  insert into public.passenger_return_date_changes
    (passenger_id, activity_log_id, passenger_name, ticket, old_return_date, new_return_date, comment, changed_by)
  values
    (p_passenger_id, v_log_id, v_row.name, v_row.ticket, v_row.ret, v_new_ret, v_reason, v_email);

  if p_reopen then
    insert into public.activity_log
      (ts, action, passenger, ticket, location, detail, passenger_id, changed_by)
    values
      (to_char(now(), 'MM/DD/YYYY, HH12:MI:SS AM'), 'REOPENED', v_row.name, v_row.ticket, v_row.loc,
       'Reopened from DELIVERED. New ret: ' || v_new_ret,
       p_passenger_id, v_email);
  end if;

  select * into v_row from public.passengers where id = p_passenger_id;
  return v_row;
end;
$$;

revoke all on function public.change_passenger_return_date_with_reason(bigint, text, text, boolean) from public, anon;
grant execute on function public.change_passenger_return_date_with_reason(bigint, text, text, boolean) to authenticated;

-- ── E. ATOMIC DELETE RPC ─────────────────────────────────────────────────
-- Deletes a passenger and writes its DELETED Activity Log entry as one
-- transaction — the same reasoning as the return-date RPC above: a
-- two-step frontend sequence (log, then delete) could FK-violate if
-- reordered, or leave a false "DELETED" log behind if the delete step
-- failed after the log had already committed. Doing both in one
-- transaction makes that entire class of problem impossible: either both
-- happen, or neither does, and no DELETE_FAILED / contradictory log is
-- ever needed. activity_log.passenger_id references passengers(id)
-- ON DELETE SET NULL, so once this transaction commits, the log row's
-- passenger_id is automatically nulled by Postgres while its snapshot
-- fields (passenger, ticket, location, detail) remain exactly as written.

create or replace function public.delete_passenger_with_log(
  p_passenger_id bigint
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid;
  v_email text;
  v_row   public.passengers%rowtype;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'delete_passenger_with_log: authentication required';
  end if;

  v_email := auth.jwt() ->> 'email';
  if v_email is null or btrim(v_email) = '' then
    v_email := v_uid::text;
  end if;

  if p_passenger_id is null then
    raise exception 'delete_passenger_with_log: passenger id is required';
  end if;

  select * into v_row from public.passengers where id = p_passenger_id for update;
  if not found then
    raise exception 'delete_passenger_with_log: passenger % not found', p_passenger_id;
  end if;

  insert into public.activity_log
    (ts, action, passenger, ticket, location, detail, passenger_id, changed_by)
  values
    (to_char(now(), 'MM/DD/YYYY, HH12:MI:SS AM'), 'DELETED', v_row.name, v_row.ticket, v_row.loc,
     'Passenger removed from system', p_passenger_id, v_email);

  delete from public.passengers where id = p_passenger_id;

  return p_passenger_id;
end;
$$;

revoke all on function public.delete_passenger_with_log(bigint) from public, anon;
grant execute on function public.delete_passenger_with_log(bigint) to authenticated;

COMMIT;
