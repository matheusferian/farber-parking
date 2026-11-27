-- Automatic thermal slips (owner 2026-11-27): the Epson printer asks printer-poll; this table remembers
-- what was printed so each print goes out once (8 AM today, 2 PM tomorrow before 11 AM).
create table if not exists public.airvalet_print_jobs (
  job_key text primary key,              -- am-YYYY-MM-DD / pm-YYYY-MM-DD
  kind text not null check (kind in ('am','pm')),
  service_date date not null,
  status text not null check (status in ('sent','printed','failed','empty')),
  attempts int not null default 0,
  passenger_ids bigint[] not null default '{}',
  flights int,
  sent_at timestamptz,
  printed_at timestamptz,
  last_result text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.airvalet_print_jobs enable row level security;
-- no policies: only the service role (printer-poll) reads/writes.
revoke all on public.airvalet_print_jobs from anon, authenticated;

-- 1:45 PM Fort Lauderdale: read tomorrow from Makers so the 2 PM slips have flights (fires 17:45 and 18:45 UTC
-- so it works in EDT and EST; the extra run is a harmless re-read).
select cron.schedule('makers-sync-tomorrow-1345', '45 17,18 * * *', $$
  select net.http_post(
    url := 'https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/makers-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'aircraft_tracking_platform_jwt'),
      'X-Makers-Sync-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'makers_sync_secret')
    ),
    body := '{"day":"tomorrow"}'::jsonb,
    timeout_milliseconds := 120000
  );
$$);
-- delete old rows after 30 days
select cron.schedule('airvalet-print-jobs-purge', '25 9 * * *', $$ delete from public.airvalet_print_jobs where service_date < current_date - 30 $$);
