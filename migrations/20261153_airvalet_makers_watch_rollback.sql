-- Rollback of 20261153: no quick check (quick-check readings expire on their own after 3 days).
begin;
select cron.unschedule('makers-watch') where exists (select 1 from cron.job where jobname = 'makers-watch');
commit;
