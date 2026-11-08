-- Demand forecast (owner 2026-11-08): people booked per day leaving FXE / arriving at FXE, read by the Makers robot every
-- morning. Counts only, no names. Service role only (RLS on, no grants). History keeps each morning's reading to see
-- how a future day fills up. Rollback: 20261151_airvalet_makers_forecast_rollback.sql
begin;
set local lock_timeout = '5s';
create table if not exists public.airvalet_makers_forecast (
  day date primary key,
  departures integer not null default 0 check (departures >= 0),
  arrivals integer not null default 0 check (arrivals >= 0),
  read_at timestamptz not null default now()
);
create table if not exists public.airvalet_makers_forecast_history (
  read_date date not null,
  day date not null,
  departures integer not null default 0,
  arrivals integer not null default 0,
  primary key (read_date, day)
);
alter table public.airvalet_makers_forecast enable row level security;
alter table public.airvalet_makers_forecast_history enable row level security;
revoke all on public.airvalet_makers_forecast, public.airvalet_makers_forecast_history from public, anon, authenticated;
commit;
