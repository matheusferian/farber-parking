-- Rollback of 20261109_airvalet_staff_reminders.sql. The schedule first (no
-- more ticks), then the functions, then the per-phone reminder categories and
-- the reminder settings (start cutoff / MOVE lead time).
-- 20261108 (check-in / tip alerts) and its Vault secrets are untouched.

begin;
set local lock_timeout = '5s';

select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-staff-reminders';
drop function if exists public.airvalet_staff_reminders_tick();
drop function if exists public.airvalet_push_reminders_get(text);
drop function if exists public.airvalet_push_reminders_set(text, text[]);
drop function if exists public.airvalet_push_reminder_targets();
drop function if exists public.airvalet_staff_reminders_claim(timestamptz);
drop function if exists public.airvalet_staff_reminders(timestamptz);
drop function if exists public.airvalet_ny_at(date, int);
drop function if exists public.airvalet_return_operator_of(text, boolean, text);
drop function if exists public.airvalet_customs_eta_min(text);
drop function if exists public.airvalet_wb_eta_min(text);
drop function if exists public.airvalet_ret_date(text);
alter table public.airvalet_push_subs drop column if exists reminder_categories;
drop table if exists public.airvalet_staff_reminder_config;

commit;
