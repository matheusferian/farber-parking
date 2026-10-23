-- Rollback of 20261024_event_valet_push.sql
begin;
drop function if exists public.event_valet_push_subscribe(text, text, text, text, text);
drop table if exists public.event_valet_push_subs;
commit;
