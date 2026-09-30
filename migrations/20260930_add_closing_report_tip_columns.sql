-- Closing Report: add tip-snapshot columns and closed_at timestamp
-- to daily_closing_reports. No existing columns are changed.
-- These columns store the snapshot taken when a Closing Report is
-- generated, so viewing it later does not recalculate from live data.

alter table public.daily_closing_reports
  add column if not exists stripe_tips_cents integer not null default 0,
  add column if not exists other_tips_cents  integer not null default 0,
  add column if not exists total_tips_cents  integer not null default 0,
  add column if not exists closed_at         timestamptz;

-- New RPC: sum Stripe tips for any business date (America/New_York).
-- The existing get_stripe_tips_today_cents() only works for literal
-- "today" (it compares against now()). This version accepts a date
-- parameter so the Closing Report can query tips for any date.
create or replace function public.get_stripe_tips_for_date_cents(target_date date)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(amount_cents), 0)::bigint
  from public.payments
  where type = 'TIP' and method = 'STRIPE' and status = 'succeeded'
    and (created_at at time zone 'America/New_York')::date = target_date;
$$;

revoke all on function public.get_stripe_tips_for_date_cents(date) from public;
grant execute on function public.get_stripe_tips_for_date_cents(date) to authenticated;
