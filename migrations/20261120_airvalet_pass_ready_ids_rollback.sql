-- Rollback of 20261120 (read-only helper; nothing else depends on it).
begin;
drop function if exists public.airvalet_pass_ready_ids();
commit;
