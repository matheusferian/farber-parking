-- Plane pushes (owner 2026-11-06): spider-sync sends ONE push per leg and event to the DAILY phones/watch —
-- LANDING_SOON (about 5 min out), LANDED (first stop at FXE = Customs), LEFT_CUSTOMS (tracker on again, taxi
-- to Hangar 19). This table remembers what was already sent (service role only).
begin;
set local lock_timeout = '5s';
create table if not exists public.airvalet_spider_events (
  service_date date not null,
  leg_key text not null,          -- flight|registration
  event text not null check (event in ('LANDING_SOON','LANDED','LEFT_CUSTOMS')),
  at timestamptz not null default now(),
  primary key (service_date, leg_key, event)
);
alter table public.airvalet_spider_events enable row level security;
revoke all on public.airvalet_spider_events from public, anon, authenticated;
commit;
