-- Phase 5 security fix — close the NULL/missing-role fail-open gap.
--
-- Every policy/function touched here used "current_user_role() IS DISTINCT
-- FROM 'TV_ONLY'" (or, in the two functions, "current_user_role() =
-- 'TV_ONLY'") to mean "permit everyone except TV_ONLY". Both forms fail
-- OPEN for an unmapped account: current_user_role() returns NULL for any
-- auth.users row with no user_profiles row, and
--   NULL IS DISTINCT FROM 'TV_ONLY'  → true   (policies: silently permitted)
--   NULL = 'TV_ONLY'                  → NULL   (functions: IF NULL behaves
--                                                like IF false in PL/pgSQL,
--                                                so the guard never fires)
-- No account is exploiting this today — the only two real accounts
-- (makers@farber.local / ADMIN, ipad@airvalet.local / IPAD_OPS) both
-- already have a mapped, non-NULL role — but this closes the gap before
-- User Access / Create User work makes creating additional accounts
-- routine, where a partially-created or not-yet-profiled account could
-- otherwise transiently have full operational access.
--
-- Fix: replace every "exclude TV_ONLY" condition with an explicit
-- 4-role allowlist. NULL IN (...) evaluates to NULL, which RLS treats as
-- false (deny) — genuinely fail-closed, not reliant on an operator
-- quirk. TV_ONLY is excluded by omission from the allowlist, same
-- practical effect as before. Every other condition (ownership checks,
-- exists(...) subqueries, auth.uid()/auth.jwt() usage) is preserved
-- byte-for-byte — only the role clause changes.
--
-- ALTER POLICY is used instead of drop/create: it changes only the
-- USING/WITH CHECK expression(s) a given command actually has, leaving
-- the policy's name, table, command, and role list untouched — the
-- smallest possible diff for an RLS-condition-only change.
--
-- Explicitly NOT touched, per the approved scope: set_user_role()
-- (its ADMIN-required check already fails closed the correct way —
-- NULL IS DISTINCT FROM 'ADMIN' is true, so it already denies NULL) and
-- get_tv_mode_passengers() (already uses this same explicit-allowlist
-- pattern with its own "is null or ... not in" guard, added in the prior
-- hardening pass).

-- ── passengers ───────────────────────────────────────────────────────
alter policy "authenticated_passengers_select" on public.passengers
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "authenticated_passengers_insert" on public.passengers
  with check (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "authenticated_passengers_update" on public.passengers
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'))
  with check (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "authenticated_passengers_delete" on public.passengers
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

-- ── activity_log ─────────────────────────────────────────────────────
alter policy "authenticated_logs_select" on public.activity_log
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "authenticated_logs_insert" on public.activity_log
  with check (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

-- ── contact_sync_batches / contact_sync_items ───────────────────────
-- Ownership (created_by = jwt email) and the GENERATED-batch exists(...)
-- check are preserved exactly, unchanged — only the ANDed role clause
-- is replaced.
alter policy "csb_select_authenticated" on public.contact_sync_batches
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "csb_insert_own" on public.contact_sync_batches
  with check (
    (created_by = (auth.jwt() ->> 'email'::text))
    and current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER')
  );

alter policy "csb_update_authenticated" on public.contact_sync_batches
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'))
  with check (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "csi_select_authenticated" on public.contact_sync_items
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "csi_insert_into_own_generated_batch" on public.contact_sync_items
  with check (
    (exists ( select 1
       from contact_sync_batches b
      where ((b.id = contact_sync_items.batch_id) and (b.status = 'GENERATED'::text) and (b.created_by = (auth.jwt() ->> 'email'::text)))))
    and current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER')
  );

-- ── daily_closing_reports ────────────────────────────────────────────
alter policy "dcr_select_authenticated" on public.daily_closing_reports
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "dcr_insert_authenticated" on public.daily_closing_reports
  with check (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

alter policy "dcr_update_authenticated" on public.daily_closing_reports
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'))
  with check (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

-- ── passenger_return_date_changes ────────────────────────────────────
alter policy "prdc_select_authenticated" on public.passenger_return_date_changes
  using (current_user_role() in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'));

-- ── SECURITY DEFINER write functions — guard line replaced only ─────
-- Bodies below are byte-for-byte the currently-live definitions
-- (captured via pg_get_functiondef() immediately before writing this
-- migration) with exactly one line changed in each: the TV_ONLY-equality
-- guard replaced with an explicit "is null or not in (...)" allowlist
-- check, so a NULL role no longer silently skips the guard (PL/pgSQL's
-- IF treats a NULL condition the same as false — "= 'TV_ONLY'" alone
-- never fired for NULL; this form does, via the explicit "is null" arm).
-- No other logic, comment, or statement changed.
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

  if public.current_user_role() is null or public.current_user_role() not in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER') then
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

  if public.current_user_role() is null or public.current_user_role() not in ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER') then
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
