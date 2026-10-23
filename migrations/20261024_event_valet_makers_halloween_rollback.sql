-- Rollback of 20261024_event_valet_makers_halloween.sql
-- Archives the event data (never dropped silently), then removes ONLY the
-- event_valet_* objects. Nothing else in the database is touched.

begin;

create schema if not exists airvalet_archive;
create table airvalet_archive.event_valet_events_20261024   as table public.event_valet_events;
create table airvalet_archive.event_valet_tickets_20261024  as table public.event_valet_tickets;
create table airvalet_archive.event_valet_messages_20261024 as table public.event_valet_messages;
create table airvalet_archive.event_valet_audit_20261024    as table public.event_valet_audit;
revoke all on all tables in schema airvalet_archive from anon, authenticated;

drop function if exists public.event_valet_inbound_ready(text, int);
drop function if exists public.event_valet_guest(text, text);
drop function if exists public.event_valet_mint_guest_token(uuid);
drop function if exists public.event_valet_board(text);
drop function if exists public.event_valet_mark_printed(uuid, text);
drop function if exists public.event_valet_set_slot(uuid, int);
drop function if exists public.event_valet_set_status(uuid, text);
drop function if exists public.event_valet_apply_status(uuid, text, text);
drop function if exists public.event_valet_checkin(text, text, text, text);
drop function if exists public.event_valet_ticket_json(public.event_valet_tickets);
drop function if exists public.event_valet_normalize_phone(text);
drop function if exists public.event_valet_is_staff();

drop table if exists public.event_valet_audit;
drop table if exists public.event_valet_messages;
drop table if exists public.event_valet_tickets;
drop table if exists public.event_valet_events;

commit;
