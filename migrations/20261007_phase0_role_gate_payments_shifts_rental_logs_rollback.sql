-- Rollback for 20261007_phase0_role_gate_payments_shifts_rental_logs.sql
-- Restores the exact production policies captured on 2026-10-07 (pg_policies baseline).

begin;

drop policy if exists "rental_logs_ops_roles_all" on public.rental_logs;
create policy "allow_all" on public.rental_logs
  for all to public using (true) with check (true);

drop policy if exists "payments_select_ops_roles" on public.payments;
create policy "payments_select_authenticated" on public.payments
  for select to authenticated using (true);

drop policy if exists "valet_shifts_select_ops_roles" on public.valet_shifts;
drop policy if exists "valet_shifts_insert_ops_roles" on public.valet_shifts;
drop policy if exists "valet_shifts_update_ops_roles" on public.valet_shifts;
create policy "Authenticated users can read valet_shifts"   on public.valet_shifts
  for select to authenticated using (true);
create policy "Authenticated users can insert valet_shifts" on public.valet_shifts
  for insert to authenticated with check (true);
create policy "Authenticated users can update valet_shifts" on public.valet_shifts
  for update to authenticated using (true) with check (true);

commit;
