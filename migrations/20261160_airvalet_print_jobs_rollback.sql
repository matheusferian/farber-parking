select cron.unschedule('makers-sync-tomorrow-1345');
select cron.unschedule('airvalet-print-jobs-purge');
drop table if exists public.airvalet_print_jobs;
