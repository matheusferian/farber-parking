-- Phase 0 security (ONE LOGIN prerequisite) — 2026-10-07
--
-- Problem (verified against production pg_policies + has_table_privilege on 2026-10-07):
--   * rental_logs   : policy "allow_all" FOR ALL TO public USING (true) WITH CHECK (true),
--                     and anon holds SELECT/INSERT/UPDATE/DELETE — anyone holding the
--                     public anon key (shipped in index.html) can read, edit or wipe
--                     rental logs (passenger names) WITHOUT logging in.
--   * payments      : SELECT TO authenticated USING (true)  — any signed-in account
--                     (TV_ONLY, disabled, or a self-registered account with no profile).
--   * valet_shifts  : SELECT/INSERT/UPDATE TO authenticated USING/CHECK (true) — same.
--
-- Fix: same fail-closed role set already used by passengers/activity_log/
-- daily_closing_reports (migrations/20260712_fail_closed_role_checks.sql):
--   ADMIN, IPAD_OPS, IPHONE_OPS, MANAGER.
-- current_user_role() returns NULL for a missing profile or is_active = false,
-- so those accounts are denied. TV_ONLY is denied (TV Mode never reads these
-- tables; it uses get_tv_mode_passengers()).
--
-- Unchanged on purpose:
--   * Commands each table allows today (rental_logs keeps ALL, valet_shifts keeps
--     SELECT/INSERT/UPDATE, payments keeps SELECT only). No grants changed.
--   * service_role (stripe-webhook, edge functions) bypasses RLS — unaffected.
--   * get_stripe_tips_today_cents() is SECURITY DEFINER — Day KPI unaffected.
--   * Realtime payments INSERT events keep working for the 4 operational roles.
--   * No UI change. No data change.
--
-- Rollback: 20261007_phase0_role_gate_payments_shifts_rental_logs_rollback.sql

begin;

-- rental_logs -----------------------------------------------------------------
drop policy if exists "allow_all" on public.rental_logs;
create policy "rental_logs_ops_roles_all" on public.rental_logs
  for all to authenticated
  using      (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]))
  with check (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

-- payments --------------------------------------------------------------------
drop policy if exists "payments_select_authenticated" on public.payments;
create policy "payments_select_ops_roles" on public.payments
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

-- valet_shifts ----------------------------------------------------------------
drop policy if exists "Authenticated users can read valet_shifts"   on public.valet_shifts;
drop policy if exists "Authenticated users can insert valet_shifts" on public.valet_shifts;
drop policy if exists "Authenticated users can update valet_shifts" on public.valet_shifts;
create policy "valet_shifts_select_ops_roles" on public.valet_shifts
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));
create policy "valet_shifts_insert_ops_roles" on public.valet_shifts
  for insert to authenticated
  with check (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));
create policy "valet_shifts_update_ops_roles" on public.valet_shifts
  for update to authenticated
  using      (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]))
  with check (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

commit;
