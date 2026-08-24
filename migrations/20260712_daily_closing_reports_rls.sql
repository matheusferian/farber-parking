-- RLS for daily_closing_reports — same authenticated-internal-app model as
-- the rest of the Makers Air Valet system. No customer data lives here, but
-- access is still restricted to signed-in staff, matching existing tables.

alter table public.daily_closing_reports enable row level security;

drop policy if exists "dcr_select_authenticated" on public.daily_closing_reports;
create policy "dcr_select_authenticated"
  on public.daily_closing_reports
  for select
  to authenticated
  using (true);

drop policy if exists "dcr_insert_authenticated" on public.daily_closing_reports;
create policy "dcr_insert_authenticated"
  on public.daily_closing_reports
  for insert
  to authenticated
  with check (true);

drop policy if exists "dcr_update_authenticated" on public.daily_closing_reports;
create policy "dcr_update_authenticated"
  on public.daily_closing_reports
  for update
  to authenticated
  using (true)
  with check (true);

-- No delete policy: closing reports (draft or finalized) are never removed
-- through the app, so no role is granted delete access.
