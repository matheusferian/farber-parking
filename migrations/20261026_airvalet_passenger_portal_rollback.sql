-- Rollback of 20261026_airvalet_passenger_portal.sql.
-- Never deletes data: the new tables move to schema airvalet_archive with a
-- timestamp suffix. passengers.ret_time is dropped only when no row uses it
-- (otherwise it stays, harmless and nullable). Safe to run more than once.

begin;

create schema if not exists airvalet_archive;
revoke all on schema airvalet_archive from public, anon, authenticated;

-- Realtime publication back to production's set (payments only).
do $$
declare t text;
begin
  foreach t in array array['passengers', 'airvalet_sms_messages', 'airvalet_pass_requests', 'airvalet_alert_events'] loop
    if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime drop table public.%I', t);
    end if;
  end loop;
end $$;

drop trigger if exists airvalet_alert_inbound on public.airvalet_sms_messages;
drop trigger if exists airvalet_alert_request on public.airvalet_pass_requests;

drop function if exists public.airvalet_alert_on_inbound();
drop function if exists public.airvalet_alert_on_request();
drop function if exists public.airvalet_admin_alerts_confirm(text);
drop function if exists public.airvalet_admin_alerts_start_verify(uuid, text);
drop function if exists public.airvalet_admin_alerts_set(jsonb);
drop function if exists public.airvalet_admin_alerts_get();
drop function if exists public.airvalet_notify_details(text, uuid);
drop function if exists public.airvalet_is_admin_alert_phone(text);
drop function if exists public.airvalet_admin_alert_target(text, bigint, text);
drop function if exists public.airvalet_notify_finish(text, text, integer, text, text);
drop function if exists public.airvalet_notify_claim(text, text);
drop function if exists public.airvalet_push_result(uuid, boolean, boolean);
drop function if exists public.airvalet_push_targets();
drop function if exists public.airvalet_push_unsubscribe(text);
drop function if exists public.airvalet_push_subscribe(text, text, text, text, boolean);
drop function if exists public.airvalet_tv_alerts();
drop function if exists public.airvalet_portal_settings_set(jsonb);
drop function if exists public.airvalet_portal_settings_get();
drop function if exists public.airvalet_pass_state_set(bigint, text, jsonb);
drop function if exists public.airvalet_pass_state_get(bigint);
drop function if exists public.airvalet_pass_request_decide(uuid, text, text, boolean);
drop function if exists public.airvalet_pass_requests_list(integer);
drop function if exists public.airvalet_portal_request(text, text, text, text, date, time, text, text, text);
drop function if exists public.airvalet_portal_view(text, text);
drop function if exists public.airvalet_portal_resolve(text, text);
drop function if exists public.airvalet_return_at(text, time);
drop function if exists public.airvalet_is_super_admin();
drop function if exists public.airvalet_portal_require_admin();
drop function if exists public.airvalet_portal_require_ops();

do $$
declare
  t text;
  sfx text := to_char(now(), 'YYYYMMDD"T"HH24MISS');
begin
  foreach t in array array['airvalet_admin_alerts', 'airvalet_notify_log', 'airvalet_push_subs', 'airvalet_alert_events',
                           'airvalet_pass_requests', 'airvalet_pass_state', 'airvalet_super_admins', 'airvalet_portal_settings'] loop
    if to_regclass('public.' || t) is not null then
      -- Archived copies keep their data but lose links to live tables, so a
      -- later passenger delete is never blocked by an archive row.
      execute (select coalesce(string_agg(format('alter table public.%I drop constraint %I', t, c.conname), '; '), 'select 1')
                 from pg_constraint c where c.conrelid = ('public.' || t)::regclass and c.contype = 'f');
      execute format('alter table public.%I rename to %I', t, t || '_' || sfx);
      execute format('alter table public.%I set schema airvalet_archive', t || '_' || sfx);
    end if;
  end loop;
end $$;

do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'passengers' and column_name = 'ret_time')
     and not exists (select 1 from public.passengers where ret_time is not null) then
    alter table public.passengers drop column ret_time;
  end if;
end $$;

commit;
