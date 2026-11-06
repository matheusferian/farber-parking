-- Rollback of 20261139: the TV no longer reads valet pass photos.
begin;
drop function if exists public.airvalet_tv_pass_photos(bigint[], boolean);
commit;
