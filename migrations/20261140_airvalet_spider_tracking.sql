-- Spidertracks (owner 2026-11-06): satellite positions of the 8 Makers Air Caravans for the TV, because
-- the public ADS-B feed loses them ~110 nm out over the Bahamas. READ-ONLY robot (spider-sync) using the
-- owner's Spidertracks login (Supabase secrets SPIDER_USER / SPIDER_PASS, set by the owner).
--   airvalet_spider_state   one row per aircraft: latest position, altitude, speed, heading, status,
--                           distance to FXE (+ previous distance, to see it closing in). Fleet data only.
--   airvalet_spider_session the Cognito refresh/id tokens so the robot does not sign in every minute.
--                           Service role only: RLS on, no policies, no grants.
--   airvalet_spider_board() what the TV reads (ops roles + TV_ONLY): positions, nothing else.
--   cron 'spider-sync'      every minute; the function itself only works 5:30 AM – 9 PM Fort Lauderdale.
begin;
set local lock_timeout = '5s';

create table if not exists public.airvalet_spider_state (
  registration text primary key,
  track_id text, departed_at timestamptz, last_at timestamptz not null,
  lat double precision not null, lon double precision not null,
  alt_ft integer, speed_kt integer, heading double precision, track_status text,
  dist_fxe_nm numeric(7,1) not null, prev_dist_fxe_nm numeric(7,1), inbound boolean not null default false,
  polled_at timestamptz not null default now()
);
alter table public.airvalet_spider_state enable row level security;
revoke all on public.airvalet_spider_state from public, anon, authenticated;

create table if not exists public.airvalet_spider_session (
  id smallint primary key default 1 check (id = 1),
  refresh_token text, id_token text, id_expires_at timestamptz,
  last_ok_at timestamptz, last_error text, last_error_at timestamptz, alerted_on date
);
alter table public.airvalet_spider_session enable row level security;
revoke all on public.airvalet_spider_session from public, anon, authenticated;

create or replace function public.airvalet_spider_board()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER','TV_ONLY']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('registration', s.registration, 'departed_at', s.departed_at, 'last_at', s.last_at,
            'lat', s.lat, 'lon', s.lon, 'alt_ft', s.alt_ft, 'speed_kt', s.speed_kt, 'heading', s.heading, 'track_status', s.track_status,
            'dist_fxe_nm', s.dist_fxe_nm, 'prev_dist_fxe_nm', s.prev_dist_fxe_nm, 'inbound', s.inbound, 'polled_at', s.polled_at))
    from public.airvalet_spider_state s where s.last_at > now() - interval '18 hours'), '[]'::jsonb);
end $function$;
revoke all on function public.airvalet_spider_board() from public, anon;
grant execute on function public.airvalet_spider_board() to authenticated;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'makers_sync_secret') or not exists (select 1 from vault.secrets where name = 'aircraft_tracking_platform_jwt') then
    raise exception 'spider-sync: Vault secrets missing';
  end if;
end $$;
select cron.schedule('spider-sync', '* * * * *', $$
  select net.http_post(
    url := 'https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/spider-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'aircraft_tracking_platform_jwt'),
      'X-Makers-Sync-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'makers_sync_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 30000);
$$);
commit;
