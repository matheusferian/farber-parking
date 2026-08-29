-- Live Aircraft Tracking — Phase B.4: schedule refresh-aircraft-state via
-- pg_cron + pg_net, once per minute. Does not rewrite B.1/B.2/B.3.
--
-- Contains NO secret value. Two independent authorization factors are
-- read at execution time by NAME only from vault.decrypted_secrets —
-- their values must already exist before this migration runs (see
-- "REQUIRED PRE-DEPLOYMENT SETUP" below). This migration deliberately
-- FAILS FAST (raises an exception, schedules nothing) if either is
-- missing, rather than silently creating a cron job whose headers would
-- resolve to null.
--
--   1. aircraft_tracking_platform_jwt — a Supabase anon-role JWT (same
--      key already public in index.html), sent as `Authorization: Bearer
--      ...` purely to satisfy the platform's own JWT-verification gate
--      on the Edge Function. This does NOT prove the caller is our
--      scheduler — the anon key is public.
--   2. aircraft_tracking_scheduler_secret — a dedicated, high-entropy
--      secret (NOT the anon key, NOT the service_role key), sent as the
--      `X-Aircraft-Refresh-Secret` header. refresh-aircraft-state (B.4
--      hardening) compares this against its own
--      AIRCRAFT_REFRESH_SCHEDULER_SECRET Edge Function env var before
--      allowing any lease claim or provider fetch — THIS is the actual
--      scheduler authorization boundary, not the JWT.
--
-- REQUIRED PRE-DEPLOYMENT SETUP (run once, out-of-band, NEVER via a
-- committed migration file, so the values never enter git history):
--   select vault.create_secret('<anon key>', 'aircraft_tracking_platform_jwt', '...');
--   select vault.create_secret('<fresh high-entropy value, e.g. openssl rand -hex 32>', 'aircraft_tracking_scheduler_secret', '...');
--   supabase secrets set AIRCRAFT_REFRESH_SCHEDULER_SECRET=<the same high-entropy value> --project-ref <ref>
--
-- The cron job is a thin trigger only. It does not implement any
-- provider-failure handling, rate-limit logic, or retry logic of its
-- own — refresh-aircraft-state (B.2/B.3/B.4) remains solely responsible
-- for all of that, plus the lease (claim_aircraft_refresh,
-- upsert_aircraft_observations, complete_aircraft_refresh — B.1/B.2)
-- remains the sole authority on whether a given tick actually reaches
-- adsb.lol, and the scheduler-secret check (B.4) remains the sole
-- authority on whether a given HTTP call is even allowed to attempt a
-- claim in the first place. This migration only ensures the tick
-- happens; every other guarantee already exists elsewhere.
--
-- Safe to run more than once — extensions are IF NOT EXISTS, the
-- precondition check simply re-passes if secrets are already present,
-- and cron.schedule() with an existing job NAME reschedules that same
-- job in place rather than creating a duplicate (native pg_cron
-- upsert-by-name behavior, confirmed against 1.6.4, the version this
-- project's CLI installed).

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

do $$
declare
  v_missing text[];
begin
  select array_agg(expected.name)
  into v_missing
  from (values ('aircraft_tracking_platform_jwt'), ('aircraft_tracking_scheduler_secret')) as expected(name)
  where not exists (
    select 1 from vault.secrets s where s.name = expected.name
  );

  if v_missing is not null then
    raise exception 'Live Aircraft Tracking B.4: required Vault secret(s) missing: %. Create them out-of-band via vault.create_secret() before re-running this migration — see the header comment of this file for the exact pre-deployment setup. Refusing to schedule a cron job whose Authorization/X-Aircraft-Refresh-Secret header would resolve to null.', v_missing;
  end if;
end;
$$;

select cron.schedule(
  'refresh-aircraft-state-every-minute',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/refresh-aircraft-state',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'aircraft_tracking_platform_jwt'
      ),
      'X-Aircraft-Refresh-Secret', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'aircraft_tracking_scheduler_secret'
      )
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 8000
  );
  $$
);
