-- Rollback of 20261123 (deploy send-sms without restorePassLink first, or the call just fails safely).
begin;
drop function if exists public.airvalet_pass_restore_after_failed_send(bigint, text);
commit;
