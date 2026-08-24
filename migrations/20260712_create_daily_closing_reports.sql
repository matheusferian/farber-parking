-- Daily Closing Report — internal end-of-day control.
-- Separate table: no passenger/customer PII, read-only against `passengers`.

-- gen_random_uuid() ships with the pgcrypto extension. Supabase projects
-- normally have it enabled already; this is a no-op in that case and only
-- matters if it was ever disabled.
create extension if not exists pgcrypto;

create table if not exists public.daily_closing_reports (
  id                  uuid primary key default gen_random_uuid(),
  report_date         date not null unique,

  first_ticket        text,
  last_ticket         text,
  total_cars          integer not null default 0,
  checked_in_today    integer not null default 0,
  delivered_today     integer not null default 0,

  cash                numeric(10,2) not null default 0,
  card                numeric(10,2) not null default 0,
  venmo               numeric(10,2) not null default 0,
  cash_app            numeric(10,2) not null default 0,
  zelle               numeric(10,2) not null default 0,

  attendants          jsonb not null default '[]'::jsonb,
  money_pickups       jsonb not null default '[]'::jsonb,
  money_left          numeric(10,2) not null default 0,

  delivered_verified  boolean not null default false,
  hangars_verified    boolean not null default false,
  notes               text,

  status              text not null default 'DRAFT' check (status in ('DRAFT','FINALIZED')),

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  finalized_at        timestamptz,
  created_by          text,
  finalized_by        text,

  constraint dcr_no_negative_totals check (
    total_cars >= 0 and checked_in_today >= 0 and delivered_today >= 0
    and cash >= 0 and card >= 0 and venmo >= 0 and cash_app >= 0 and zelle >= 0 and money_left >= 0
  ),
  -- Finalizing requires both operational checklist confirmations.
  constraint dcr_finalized_requires_checklist check (
    status <> 'FINALIZED' or (delivered_verified and hangars_verified)
  )
);

-- One row per calendar date (the `report_date` unique constraint above), so a
-- date can never carry more than one finalized report — drafts are updated
-- in place instead of inserting duplicates.

create index if not exists idx_daily_closing_reports_status on public.daily_closing_reports(status);
create index if not exists idx_daily_closing_reports_report_date on public.daily_closing_reports(report_date desc);

create or replace function public.dcr_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_dcr_set_updated_at on public.daily_closing_reports;
create trigger trg_dcr_set_updated_at
  before update on public.daily_closing_reports
  for each row execute function public.dcr_set_updated_at();

-- Database-level backstop (in addition to the app-level guard): once a
-- report is FINALIZED it can never be flipped back to DRAFT, whether the
-- update comes from the app, the SQL editor, or any other client.
create or replace function public.dcr_block_unfinalize()
returns trigger language plpgsql as $$
begin
  if old.status = 'FINALIZED' and new.status <> 'FINALIZED' then
    raise exception 'daily_closing_reports: a FINALIZED report cannot be changed back to DRAFT (report_date=%)', old.report_date;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dcr_block_unfinalize on public.daily_closing_reports;
create trigger trg_dcr_block_unfinalize
  before update on public.daily_closing_reports
  for each row execute function public.dcr_block_unfinalize();
