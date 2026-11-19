-- Rollback of 20261156. Removes the cron, the trigger and the table. The Storage files are NOT removed
-- here (Supabase blocks deleting storage.objects from SQL): empty the car-photos bucket with the
-- Storage API / dashboard first if the photos must go too, then this file drops the bucket row.
begin;
set local lock_timeout = '5s';
select cron.unschedule('airvalet-car-photos-cleanup') where exists (select 1 from cron.job where jobname = 'airvalet-car-photos-cleanup');
drop trigger if exists airvalet_car_photos_retention on public.passengers;
drop function if exists public.airvalet_car_photos_retention();
drop table if exists public.airvalet_car_photos;
delete from storage.buckets where id = 'car-photos' and not exists (select 1 from storage.objects where bucket_id = 'car-photos');
commit;
