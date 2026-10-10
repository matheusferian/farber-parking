-- Rollback for 20261012_airvalet_sms_audit.sql. Stops auditing; KEEPS the
-- history: the table moves to airvalet_archive (no anon/authenticated access).
begin;
drop trigger if exists airvalet_sms_audit_settings_trg on public.airvalet_sms_settings;
drop trigger if exists airvalet_sms_audit_devices_trg on public.airvalet_sms_devices;
drop function if exists public.airvalet_sms_audit_settings();
drop function if exists public.airvalet_sms_audit_devices();
drop function if exists public.airvalet_sms_audit_write(text, uuid, text, jsonb);
create schema if not exists airvalet_archive;
revoke all on schema airvalet_archive from public, anon, authenticated;
do $$
declare v_new text := 'airvalet_sms_audit__rb_' || to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDD"T"HH24MISS');
begin
  if to_regclass('public.airvalet_sms_audit') is not null then
    execute format('alter table public.airvalet_sms_audit rename to %I', v_new);
    execute format('alter table public.%I set schema airvalet_archive', v_new);
    execute format('revoke all on airvalet_archive.%I from public, anon, authenticated', v_new);
  end if;
end $$;
commit;
