-- Rollback for 20261007_sso_session_revalidation.sql
-- Restores current_user_role() to its exact production body (captured 2026-10-07) and
-- removes the SSO session registry. Human SSO sessions then behave like ordinary sessions
-- (no FarberOS revalidation). Device/password sessions were never affected either way.
begin;
select cron.unschedule('sso-revalidate-every-minute') where exists (select 1 from cron.job where jobname = 'sso-revalidate-every-minute');

CREATE OR REPLACE FUNCTION public.current_user_role()
 RETURNS account_role
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select role from public.user_profiles where id = auth.uid() and is_active = true;
$function$;

drop function if exists public.sso_terminate_session(uuid, text);
drop function if exists public.sso_session_status();
drop function if exists public.sso_current_session_id();
drop table if exists public.sso_sessions;
commit;
