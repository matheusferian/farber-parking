-- Phase 5 — real, DB-level TV_ONLY restriction (not a frontend redirect).
--
-- Every policy touched below already exists and already grants
-- `to authenticated using(true)` (or an equivalent unconditional check) —
-- confirmed by direct inspection of pg_policies immediately before writing
-- this migration. This migration ONLY adds "and current_user_role() is
-- distinct from 'TV_ONLY'" to each existing check; it does not change
-- access for any other role, and does not touch tables that currently
-- have NO policy for `authenticated` at all (vehicle_location_history has
-- RLS enabled with zero policies today — confirmed separately, zero rows
-- exist in it in production; that looks like a pre-existing, unrelated
-- gap and is deliberately left untouched here, out of this phase's
-- scope). rental_logs (roles: {public}, not just {authenticated}) is
-- likewise a separate, pre-existing issue, also left untouched.
--
-- "is distinct from 'TV_ONLY'" (not "<> 'TV_ONLY'") is deliberate: NULL
-- IS DISTINCT FROM 'TV_ONLY' evaluates true, so an account with no
-- user_profiles row yet (or any role other than TV_ONLY) is unaffected —
-- this migration can only ever narrow access for a role that does not
-- exist as a real account yet (see companion migration), never for the
-- existing admin account or any future non-TV role.
--
-- TV Mode's own passenger read is intentionally NOT narrowed to a
-- restricted column set in this pass: refreshTvData() calls the exact
-- same sbGet()/mapPassengerRow() path used by the rest of the app, which
-- references a large fraction of the passengers table's real columns
-- (aircraft-tracking cross-reference via return_flight, Welcome-Back-
-- overdue via welcome_back_sent_at, Customs badges, delayed-return
-- badges via departure_time, etc.). Building a narrower view now, before
-- a real TV_ONLY account exists to test it against, risks exactly the
-- kind of TV Mode regression this project has protected against across
-- four prior phases. What TV_ONLY does get here, for real: zero write
-- access anywhere (passengers, activity_log, contact sync, daily closing,
-- return-date changes, and the two SECURITY DEFINER functions that would
-- otherwise bypass table RLS entirely), and zero read access to
-- financial/contact-export/audit-log tables it has no legitimate reason
-- to see. A column-scoped passengers view for TV_ONLY is flagged as a
-- named follow-up once a real TV_ONLY account exists to validate against.

-- ── passengers ───────────────────────────────────────────────────────
drop policy if exists "authenticated_passengers_select" on public.passengers;
create policy "authenticated_passengers_select"
  on public.passengers
  for select
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "authenticated_passengers_insert" on public.passengers;
create policy "authenticated_passengers_insert"
  on public.passengers
  for insert
  to authenticated
  with check (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "authenticated_passengers_update" on public.passengers;
create policy "authenticated_passengers_update"
  on public.passengers
  for update
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY')
  with check (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "authenticated_passengers_delete" on public.passengers;
create policy "authenticated_passengers_delete"
  on public.passengers
  for delete
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY');

-- ── activity_log ─────────────────────────────────────────────────────
-- TV Mode never reads activity_log directly (confirmed: refreshTvData()
-- only calls sbGet() against passengers) — safe to fully exclude TV_ONLY.
drop policy if exists "authenticated_logs_select" on public.activity_log;
create policy "authenticated_logs_select"
  on public.activity_log
  for select
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "authenticated_logs_insert" on public.activity_log;
create policy "authenticated_logs_insert"
  on public.activity_log
  for insert
  to authenticated
  with check (current_user_role() is distinct from 'TV_ONLY');

-- ── contact_sync_batches / contact_sync_items ───────────────────────
-- Contact export data — TV Mode has no legitimate reason to read or
-- touch any of it. Existing ownership checks (created_by = jwt email)
-- are preserved unchanged; the TV_ONLY exclusion is ANDed alongside them.
drop policy if exists "csb_select_authenticated" on public.contact_sync_batches;
create policy "csb_select_authenticated"
  on public.contact_sync_batches
  for select
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "csb_insert_own" on public.contact_sync_batches;
create policy "csb_insert_own"
  on public.contact_sync_batches
  for insert
  to authenticated
  with check (
    (created_by = (auth.jwt() ->> 'email'::text))
    and current_user_role() is distinct from 'TV_ONLY'
  );

drop policy if exists "csb_update_authenticated" on public.contact_sync_batches;
create policy "csb_update_authenticated"
  on public.contact_sync_batches
  for update
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY')
  with check (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "csi_select_authenticated" on public.contact_sync_items;
create policy "csi_select_authenticated"
  on public.contact_sync_items
  for select
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "csi_insert_into_own_generated_batch" on public.contact_sync_items;
create policy "csi_insert_into_own_generated_batch"
  on public.contact_sync_items
  for insert
  to authenticated
  with check (
    (exists ( select 1
       from contact_sync_batches b
      where ((b.id = contact_sync_items.batch_id) and (b.status = 'GENERATED'::text) and (b.created_by = (auth.jwt() ->> 'email'::text)))))
    and current_user_role() is distinct from 'TV_ONLY'
  );

-- ── daily_closing_reports ────────────────────────────────────────────
-- Financial/end-of-day data — TV Mode never reads this table.
drop policy if exists "dcr_select_authenticated" on public.daily_closing_reports;
create policy "dcr_select_authenticated"
  on public.daily_closing_reports
  for select
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "dcr_insert_authenticated" on public.daily_closing_reports;
create policy "dcr_insert_authenticated"
  on public.daily_closing_reports
  for insert
  to authenticated
  with check (current_user_role() is distinct from 'TV_ONLY');

drop policy if exists "dcr_update_authenticated" on public.daily_closing_reports;
create policy "dcr_update_authenticated"
  on public.daily_closing_reports
  for update
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY')
  with check (current_user_role() is distinct from 'TV_ONLY');

-- ── passenger_return_date_changes ────────────────────────────────────
-- SELECT-only table today (writes go exclusively through
-- change_passenger_return_date_with_reason() below, which never reaches
-- here for TV_ONLY once that function's own guard is in place).
drop policy if exists "prdc_select_authenticated" on public.passenger_return_date_changes;
create policy "prdc_select_authenticated"
  on public.passenger_return_date_changes
  for select
  to authenticated
  using (current_user_role() is distinct from 'TV_ONLY');

-- ── SECURITY DEFINER write functions ────────────────────────────────
-- Both bypass table RLS entirely (they run as their owner, not the
-- caller) — without a guard here, a TV_ONLY account could still delete
-- or modify passengers via RPC even with every policy above in place.
-- Bodies below are byte-for-byte the existing functions (captured via
-- pg_get_functiondef() immediately before writing this migration) with
-- exactly one guard clause added near the top of each — no other logic
-- changed.
create or replace function public.change_passenger_return_date_with_reason(p_passenger_id bigint, p_new_return_date text, p_reason text, p_reopen boolean DEFAULT false)
 returns passengers
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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

  if public.current_user_role() = 'TV_ONLY' then
    raise exception 'change_passenger_return_date_with_reason: not permitted for this account role';
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
$function$;

create or replace function public.delete_passenger_with_log(p_passenger_id bigint)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid   uuid;
  v_email text;
  v_row   public.passengers%rowtype;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'delete_passenger_with_log: authentication required';
  end if;

  if public.current_user_role() = 'TV_ONLY' then
    raise exception 'delete_passenger_with_log: not permitted for this account role';
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
$function$;
