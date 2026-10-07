-- ONE LOGIN Phase 2C — revalidation of HUMAN FarberOS-SSO sessions (2026-10-07).
--
-- A human ADMIN/MANAGER who signed in with "Continue with FarberOS" gets a row in
-- public.sso_sessions (written only by the sso-exchange edge function, keyed by the
-- Supabase session id from the JWT `session_id` claim, FarberOS token AES-GCM encrypted).
-- The sso-revalidate edge function (cron below, every minute) re-checks each such session
-- with FarberOS at most every 5 minutes; FarberOS logout / IAM disable / grant removal →
-- the session is revoked; FarberOS unreachable for > 15 minutes → revoked (fail closed).
--
-- Enforcement is in the database, not the browser: current_user_role() — the single
-- check behind every AirValet role policy (20) and role-gated function (8) — returns
-- NULL for a revoked SSO session, so all role-gated reads/writes stop immediately; the
-- session's refresh tokens are deleted as well.
--
-- Sessions WITHOUT an sso_sessions row — makers@ shared account, iPad / iPhone / TV
-- device accounts, any username/password login, offline mode — are completely
-- unaffected: for them current_user_role() returns exactly what it returned before.
--
-- PRE-DEPLOYMENT (out of band, never in git): vault.create_secret(<random>,
-- 'sso_revalidate_scheduler_secret') and the same value as the edge-function secret
-- SSO_REVALIDATE_SCHEDULER_SECRET. Reuses the existing 'aircraft_tracking_platform_jwt'.
-- Rollback: migrations/20261007_sso_session_revalidation_rollback.sql

-- 1. Registry of human SSO sessions -------------------------------------------------
create table if not exists public.sso_sessions (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  supabase_session_id   uuid not null unique,
  farberos_principal_id uuid not null,
  farberos_token_enc    text not null,
  created_at            timestamptz not null default now(),
  expires_at            timestamptz not null,
  last_validated_at     timestamptz not null default now(),
  revoked_at            timestamptz,
  revoked_reason        text
);
create index if not exists sso_sessions_due_idx on public.sso_sessions (last_validated_at) where revoked_at is null;
alter table public.sso_sessions enable row level security;
revoke all on table public.sso_sessions from public, anon, authenticated;
grant select, insert, update on table public.sso_sessions to service_role;

-- 2. Current JWT's Supabase session id (null when absent / malformed) -----------------
create or replace function public.sso_current_session_id() returns uuid
language sql stable set search_path to 'public' as $$
  select case when coalesce(auth.jwt() ->> 'session_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then (auth.jwt() ->> 'session_id')::uuid end;
$$;

-- 3. The single role check: unchanged, plus "not a revoked SSO session" ----------------
create or replace function public.current_user_role() returns account_role
language sql stable security definer set search_path to 'public' as $function$
  select role from public.user_profiles
   where id = auth.uid() and is_active = true
     and not exists (select 1 from public.sso_sessions s
                      where s.supabase_session_id = public.sso_current_session_id()
                        and s.revoked_at is not null);
$function$;

-- 4. UX helper for the page (the security check is #3) --------------------------------
create or replace function public.sso_session_status() returns text
language sql stable security definer set search_path to 'public' as $$
  select case when s.id is null then 'not_sso' when s.revoked_at is not null then 'revoked' else 'active' end
    from (select 1) one
    left join public.sso_sessions s on s.supabase_session_id = public.sso_current_session_id();
$$;
revoke all on function public.sso_session_status() from public, anon;
grant execute on function public.sso_session_status() to authenticated;

-- 5. Terminate one human SSO session (service_role only: sso-exchange / sso-revalidate) -
create or replace function public.sso_terminate_session(p_session uuid, p_reason text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.sso_sessions set revoked_at = now(), revoked_reason = left(coalesce(p_reason, 'revoked'), 80)
   where supabase_session_id = p_session and revoked_at is null;
  -- Only ever a session that IS a registered SSO session — never a device/password one.
  if exists (select 1 from public.sso_sessions where supabase_session_id = p_session) then
    delete from auth.sessions where id = p_session;   -- refresh tokens cascade
  end if;
end $$;
revoke all on function public.sso_terminate_session(uuid, text) from public, anon, authenticated;
grant execute on function public.sso_terminate_session(uuid, text) to service_role;

-- 6. Schedule (same pattern as refresh-aircraft-state) --------------------------------
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'sso_revalidate_scheduler_secret')
     or not exists (select 1 from vault.secrets where name = 'aircraft_tracking_platform_jwt') then
    raise exception 'SSO revalidation: Vault secret sso_revalidate_scheduler_secret / aircraft_tracking_platform_jwt missing — create it out of band first.';
  end if;
end $$;

select cron.schedule(
  'sso-revalidate-every-minute',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/sso-revalidate',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'aircraft_tracking_platform_jwt'),
      'X-SSO-Revalidate-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sso_revalidate_scheduler_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 15000
  );
  $$
);
