-- AirValet SMS (audit 2026-11-06, #23): only a VERIFIED admin alert phone is treated as the admin phone by
-- twilio-inbound (its texts skip the guest inbox). Before, a number saved but not yet verified also
-- swallowed every reply from that number, STOP included.
-- Rollback: 20261128_airvalet_admin_alert_phone_verified_rollback.sql
begin;
set local lock_timeout = '5s';
create or replace function public.airvalet_is_admin_alert_phone(p_phone_e164 text)
 returns boolean language sql stable security definer set search_path to ''
as $function$ select exists (select 1 from public.airvalet_admin_alerts a where a.phone_e164 = p_phone_e164 and a.phone_verified_at is not null); $function$;
commit;
