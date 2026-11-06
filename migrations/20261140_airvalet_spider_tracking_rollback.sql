-- Rollback of 20261140: stop the robot and remove what it stored (positions + tokens).
begin;
select cron.unschedule('spider-sync') where exists (select 1 from cron.job where jobname = 'spider-sync');
drop function if exists public.airvalet_spider_board();
drop table if exists public.airvalet_spider_session;
drop table if exists public.airvalet_spider_state;
commit;
