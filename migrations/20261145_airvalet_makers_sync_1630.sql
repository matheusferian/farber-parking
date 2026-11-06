-- Makers robot no-show check (owner 2026-11-06): 4:30 PM Fort Lauderdale reads TODAY again before the last
-- flights leave the islands and warns about guests with a car who are on no Makers flight. Separate job
-- because the minute is :30. 4:30 PM ET = 20:30 UTC (EDT) / 21:30 UTC (EST); makers-sync only works in the
-- run that is 4 PM local.
begin;
set local lock_timeout = '5s';
select cron.schedule('makers-sync-1630', '30 20,21 * * *', (select command from cron.job where jobname = 'makers-sync'));
commit;
