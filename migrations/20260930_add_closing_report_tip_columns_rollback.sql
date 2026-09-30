-- Rollback: remove Closing Report tip columns and RPC.

drop function if exists public.get_stripe_tips_for_date_cents(date);

alter table public.daily_closing_reports
  drop column if exists stripe_tips_cents,
  drop column if exists other_tips_cents,
  drop column if exists total_tips_cents,
  drop column if exists closed_at;
