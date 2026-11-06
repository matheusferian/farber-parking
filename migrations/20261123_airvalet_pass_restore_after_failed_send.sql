-- AirValet (audit 2026-11-06, A3): a text that carries a new pass link and is DEFINITELY not sent
-- (Twilio rejected it) must not kill the link the passenger already has.
-- airvalet_pass_restore_after_failed_send(passenger, new token): revokes the unsent link and puts back the
-- link that the same mint rotated (same timestamp, reason 'rotated'). Service role only (send-sms).
-- Rollback: 20261123_airvalet_pass_restore_after_failed_send_rollback.sql
begin;
set local lock_timeout = '5s';
create or replace function public.airvalet_pass_restore_after_failed_send(p_passenger_id bigint, p_token text)
 returns boolean
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_new public.airvalet_pass_links%rowtype; v_old_id bigint;
begin
  select * into v_new from public.airvalet_pass_links l
   where l.passenger_id = p_passenger_id and l.token_hash = extensions.digest(p_token, 'sha256') and l.revoked_at is null
   for update;
  if not found then return false; end if;
  select l.id into v_old_id from public.airvalet_pass_links l
   where l.passenger_id = p_passenger_id and l.id <> v_new.id and l.revoke_reason = 'rotated' and l.revoked_at = v_new.created_at
   order by l.id desc limit 1 for update;
  update public.airvalet_pass_links set revoked_at = now(), revoke_reason = 'rotated' where id = v_new.id;
  if v_old_id is null then return false; end if;
  update public.airvalet_pass_links set revoked_at = null, revoke_reason = null where id = v_old_id
     and (expires_at is null or expires_at > now());
  return found;
end $function$;
revoke all on function public.airvalet_pass_restore_after_failed_send(bigint, text) from public, anon, authenticated;
grant execute on function public.airvalet_pass_restore_after_failed_send(bigint, text) to service_role;
commit;
