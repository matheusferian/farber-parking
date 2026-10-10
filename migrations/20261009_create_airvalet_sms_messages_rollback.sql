-- Rollback for 20261009_create_airvalet_sms_messages.sql.
-- PRESERVES DATA (A2P record keeping): nothing is deleted. Functions and
-- views are removed; every SMS table (messages, status audit trail, opt-outs,
-- consents, enrollments, devices, settings) is MOVED to the private schema
-- airvalet_archive as <table>__rb_<UTC timestamp>, with all access revoked
-- from anon/authenticated (that schema is not exposed by the API).
-- Run AFTER the 20261011 and pass-link rollbacks (they depend on this).
-- Re-applying the migration creates fresh, empty tables; old rows stay in
-- the archive (restore = INSERT … SELECT from the archived table).
-- Foreign keys to live tables (passengers) are dropped from the archived copy, so
-- a later passenger delete can neither cascade into nor block the archive.

begin;

drop view if exists public.airvalet_sms_alerts;
drop view if exists public.airvalet_sms_review_queue;
drop view if exists public.airvalet_sms_conversations;
drop function if exists public.airvalet_sms_set_cutover(text);
drop function if exists public.airvalet_sms_set_settings(boolean, boolean, text[], integer, integer, integer, integer, integer, integer);
drop function if exists public.airvalet_sms_device_decide(uuid, text, text);
drop function if exists public.airvalet_sms_device_status(text);
drop function if exists public.airvalet_sms_device_request(text, text, text);
drop function if exists public.airvalet_sms_resolve_alert(uuid, text);
drop function if exists public.airvalet_sms_reconcile(integer);
drop function if exists public.airvalet_sms_assign_inbound(uuid, bigint);
drop function if exists public.airvalet_sms_mark_read(bigint, uuid);
drop function if exists public.airvalet_sms_record_consent(bigint, text, text, text);
drop function if exists public.airvalet_sms_require_ops();

drop function if exists public.airvalet_sms_mark_opted_out(text, text);
drop function if exists public.airvalet_sms_record_inbound(text, text, text, text, text);
drop function if exists public.airvalet_sms_match_passenger(text);
drop function if exists public.airvalet_sms_apply_status(text, text, text, text, uuid);
drop function if exists public.airvalet_sms_mark_result(uuid, text, text, text, text, text, integer);
drop function if exists public.airvalet_sms_apply_status_row(uuid, text, text, text);
drop function if exists public.airvalet_sms_claim(text, bigint, text, text, text, text, text, text, integer, text, uuid, integer, integer, text, bytea);
drop function if exists public.airvalet_sms_ticket_eligible(bigint);
drop function if exists public.airvalet_sms_device_key_hash(text);
drop function if exists public.airvalet_sms_has_consent(text);
drop function if exists public.airvalet_sms_status_rank(text);

create schema if not exists airvalet_archive;
revoke all on schema airvalet_archive from public, anon, authenticated;
do $$
declare
  t text;
  v_new text;
  v_fk name;
  v_suffix text := to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDD"T"HH24MISS');
begin
  foreach t in array array['airvalet_sms_messages', 'airvalet_sms_status_events', 'airvalet_sms_opt_outs',
                           'airvalet_sms_consents', 'airvalet_sms_enrollments', 'airvalet_sms_devices', 'airvalet_sms_settings'] loop
    if to_regclass('public.' || t) is not null then
      v_new := t || '__rb_' || v_suffix;
      execute format('alter table public.%I rename to %I', t, v_new);
      execute format('alter table public.%I set schema airvalet_archive', v_new);
      execute format('revoke all on airvalet_archive.%I from public, anon, authenticated', v_new);
      for v_fk in select conname from pg_constraint where conrelid = format('airvalet_archive.%I', v_new)::regclass and contype = 'f' loop
        execute format('alter table airvalet_archive.%I drop constraint %I', v_new, v_fk);
      end loop;
    end if;
  end loop;
end $$;

drop function if exists public.airvalet_sms_normalize_phone(text);

commit;
