-- Owner 2026-11-19: arrival photos (front / rear) kept on the server, visible on the car card on every
-- device, deleted 30 days after the car leaves ("30 dias depois que ele sai"). Additive only.
-- Files: private Storage bucket car-photos. Rows: airvalet_car_photos. All access goes through the
-- car-photos Edge Function (staff JWT + ops role, or the cleanup secret) with the service role:
-- no policy for anon/authenticated on the table or the bucket.
-- Cleanup: when a ticket becomes DELIVERED (or ARCHIVED) its photos get delete_after = now() + 30 days
-- (back to null if the ticket is reopened); a daily cron calls car-photos {cleanup:true}. hold = true
-- (a complaint) keeps them.
-- The cron needs the vault secret car_photos_cleanup_secret (created separately, never in this file).
-- Rollback: 20261156_airvalet_car_photos_rollback.sql
begin;
set local lock_timeout = '5s';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('car-photos', 'car-photos', false, 1048576, array['image/jpeg'])
on conflict (id) do nothing;

create table if not exists public.airvalet_car_photos (
  id           uuid primary key default gen_random_uuid(),
  passenger_id bigint not null references public.passengers(id) on delete cascade,
  angle        text not null check (angle in ('front', 'rear')),
  path         text not null unique,
  bytes        integer not null check (bytes > 0 and bytes <= 1048576),
  sha256       text check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  taken_at     timestamptz not null default now(),
  taken_by     uuid,
  delete_after timestamptz,
  hold         boolean not null default false
);
create index if not exists airvalet_car_photos_passenger on public.airvalet_car_photos (passenger_id, taken_at desc);
create index if not exists airvalet_car_photos_cleanup on public.airvalet_car_photos (delete_after) where not hold;
alter table public.airvalet_car_photos enable row level security;
revoke all on public.airvalet_car_photos from public, anon, authenticated;

create or replace function public.airvalet_car_photos_retention()
 returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
  if new.status in ('DELIVERED', 'ARCHIVED') and old.status is distinct from new.status then
    update public.airvalet_car_photos set delete_after = now() + interval '30 days'
     where passenger_id = new.id and delete_after is null;
  elsif old.status in ('DELIVERED', 'ARCHIVED') and new.status not in ('DELIVERED', 'ARCHIVED') then
    update public.airvalet_car_photos set delete_after = null where passenger_id = new.id;
  end if;
  return new;
end $function$;
revoke all on function public.airvalet_car_photos_retention() from public, anon, authenticated;
drop trigger if exists airvalet_car_photos_retention on public.passengers;
create trigger airvalet_car_photos_retention after update of status on public.passengers
  for each row execute function public.airvalet_car_photos_retention();

-- Daily at 4:40 AM Fort Lauderdale (08:40 / 09:40 UTC; the function only works once per day).
select cron.schedule('airvalet-car-photos-cleanup', '40 8,9 * * *', $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'airvalet_functions_url') || '/car-photos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'aircraft_tracking_platform_jwt'),
      'X-Car-Photos-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'car_photos_cleanup_secret')),
    body := '{"cleanup":true}'::jsonb,
    timeout_milliseconds := 60000
  );
$cron$);
commit;
