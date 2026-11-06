begin;
select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-makers-names-purge';
drop function if exists public.airvalet_makers_names_get();
drop table if exists public.airvalet_makers_names;
commit;
