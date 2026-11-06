-- Rollback of 20261128: production definition read 2026-11-06.
begin;
set local lock_timeout = '5s';
create or replace function public.airvalet_is_admin_alert_phone(p_phone_e164 text)
 returns boolean language sql stable security definer set search_path to ''
as $function$ select exists (select 1 from public.airvalet_admin_alerts a where a.phone_e164 = p_phone_e164); $function$;
commit;
