-- Rollback of 20261133_airvalet_manifest_scan.sql. Removes the manifest scan log and what staff
-- taught the matcher (feedback). Nothing else depends on these objects.
begin;
set local lock_timeout = '5s';
drop function if exists public.airvalet_manifest_feedback_set(text, text, text);
drop table if exists public.airvalet_manifest_feedback;
drop table if exists public.airvalet_manifest_scans;
commit;
