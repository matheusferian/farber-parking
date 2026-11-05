-- Rollback of 20261112_event_valet_watermakers_s710.sql.
-- Archives the new tables' data first (airvalet_archive), then removes every new
-- object and puts the Watermakers row back as 20261111 left it (30 slots, no link).
-- Tickets in RETRIEVING go back to REQUESTED so the old status check holds.
begin;
create schema if not exists airvalet_archive;
create table airvalet_archive.event_valet_s710_access   as select * from public.event_valet_access;
create table airvalet_archive.event_valet_s710_sessions as select * from public.event_valet_sessions;
create table airvalet_archive.event_valet_s710_tips     as select * from public.event_valet_tips;
create table airvalet_archive.event_valet_s710_ops      as select * from public.event_valet_ops;
create table airvalet_archive.event_valet_s710_tickets  as
  select id, event_id, status, vehicle_color, vehicle_make, vehicle_model, vehicle_plate, key_stored_at, offline_checkin,
         checked_in_by, checked_in_access, retrieving_by, retrieving_access, retrieving_session, retrieving_at, delivered_by
    from public.event_valet_tickets where checked_in_access is not null or status = 'RETRIEVING';

drop function if exists public.event_valet_route_check(text);
drop function if exists public.event_valet_admin_close(text);
drop function if exists public.event_valet_admin_report(text);
drop function if exists public._ev_blockers(public.event_valet_events);
drop function if exists public.event_valet_admin_cash_correct(uuid, int, text);
drop function if exists public.event_valet_admin_set_flags(text, jsonb);
drop function if exists public.event_valet_admin_access_extend(text, timestamptz);
drop function if exists public.event_valet_admin_access_revoke(uuid);
drop function if exists public.event_valet_admin_access_list(text);
drop function if exists public.event_valet_admin_access_create(text, text, text, timestamptz, timestamptz);
drop function if exists public._ev_admin();
drop function if exists public.event_valet_staff(text, uuid, text, jsonb);
drop function if exists public._ev_counts(public.event_valet_events);
drop function if exists public._ev_vehicle_text(jsonb);
drop function if exists public._ev_hook_allowed(public.event_valet_events, text, int);
drop function if exists public._ev_hook_free(public.event_valet_events, int, text, uuid);
drop function if exists public._ev_alloc(public.event_valet_events, text, text);
drop function if exists public.event_valet_staff_ticket(public.event_valet_tickets);
drop function if exists public._ev_err(text, jsonb);

drop table if exists public.event_valet_tips;
drop table if exists public.event_valet_holds;
drop table if exists public.event_valet_rate;
drop table if exists public.event_valet_ops;
drop table if exists public.event_valet_sessions;
drop table if exists public.event_valet_access;

update public.event_valet_tickets set status = 'REQUESTED' where status = 'RETRIEVING';
alter table public.event_valet_tickets drop constraint event_valet_tickets_status_check;
alter table public.event_valet_tickets add constraint event_valet_tickets_status_check
  check (status in ('PARKED','REQUESTED','READY','DELIVERED'));
alter table public.event_valet_tickets
  drop column vehicle_color, drop column vehicle_make, drop column vehicle_model, drop column vehicle_plate,
  drop column key_stored_at, drop column offline_checkin, drop column checked_in_by, drop column checked_in_access,
  drop column retrieving_by, drop column retrieving_access, drop column retrieving_session, drop column retrieving_at,
  drop column delivered_by;

-- slots above 30 would violate nothing, but the row goes back to 30 like 20261111
update public.event_valet_events set slot_capacity = 30, include_ticket_link = false where id = 'watermakers-veterans-2026';
alter table public.event_valet_events
  drop column device_pool, drop column phone_pool, drop column staff_access_enabled, drop column sms_replies_enabled,
  drop column thanks_enabled, drop column revenue_slug, drop column closed_at;
commit;
