-- Rollback of 20261108_airvalet_staff_alerts.sql. Removes only what it added:
-- the triggers first (no more calls), then the functions, then the per-phone
-- choices (check-ins / tips / reminders). Alerts for guest messages and
-- passenger requests are untouched. pg_net stays (it was already installed).
-- Vault secrets airvalet_functions_url / staff_alert_secret: delete out of band
-- if wanted (harmless without the triggers).

begin;
set local lock_timeout = '5s';

drop trigger if exists airvalet_staff_alert_checkin on public.passengers;
drop trigger if exists airvalet_staff_alert_tip on public.payments;
drop function if exists public.airvalet_staff_alert_hook();
drop function if exists public.airvalet_staff_alert_claim(text, bigint);
drop function if exists public.airvalet_push_staff_targets(text);
drop function if exists public.airvalet_push_alerts_get(text);
drop function if exists public.airvalet_push_alerts_set(text, text, boolean);
alter table public.airvalet_push_subs
  drop column if exists notify_checkins,
  drop column if exists notify_tips,
  drop column if exists notify_reminders;

commit;
