-- Event Valet: SMS alert to the operator's phone(s) when a guest requests a car
-- (by SMS READY or the guest link). Owner request 2026-10-23. Only event_valet_* touched.
-- Rollback: alter table public.event_valet_events drop column staff_alert_phones;
alter table public.event_valet_events add column staff_alert_phones text[] not null default '{}';
