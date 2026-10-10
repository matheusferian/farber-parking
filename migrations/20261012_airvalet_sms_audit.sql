-- AirValet texting — append-only AUDIT TRAIL of device decisions and program
-- settings (who approved/removed which device, who turned texting or new
-- check-ins on/off, limit changes). Written ONLY by triggers on the two SMS
-- tables, so every path (admin panel, SQL, service role) is captured.
-- Never stores a device key or its hash; test numbers only as count + last 4.
-- Requires 20261009_create_airvalet_sms_messages.sql. Touches NO v46 object.
-- LOCAL ONLY until the owner gives a GO for production.

begin;

create table public.airvalet_sms_audit (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor        uuid,           -- auth.uid() (shared login); null = service / SQL
  actor_role   text,
  action       text not null check (action in (
                 'DEVICE_REQUESTED', 'DEVICE_APPROVED', 'DEVICE_REVOKED', 'DEVICE_RENAMED',
                 'TEXTING_ON', 'TEXTING_OFF', 'TEST_MODE_ON', 'TEST_MODE_OFF', 'TEST_PHONES_CHANGED',
                 'LIMITS_CHANGED', 'CHECKINS_STARTED', 'CHECKINS_STOPPED')),
  device_id    uuid,           -- no FK: the history survives device deletion
  device_label text,
  details      jsonb not null default '{}'::jsonb
);
create index airvalet_sms_audit_at_idx on public.airvalet_sms_audit (at desc);
alter table public.airvalet_sms_audit enable row level security;
revoke all on public.airvalet_sms_audit from public, anon, authenticated;
revoke all on sequence public.airvalet_sms_audit_id_seq from public, anon, authenticated;
grant select on public.airvalet_sms_audit to authenticated;   -- rows: ADMIN only (policy)
grant select on public.airvalet_sms_audit to service_role;
create policy airvalet_sms_audit_select_admin on public.airvalet_sms_audit
  for select to authenticated
  using (public.current_user_role() = 'ADMIN'::public.account_role);

create or replace function public.airvalet_sms_audit_write(p_action text, p_device_id uuid, p_label text, p_details jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.airvalet_sms_audit (actor, actor_role, action, device_id, device_label, details)
  values (auth.uid(), (select public.current_user_role())::text, p_action, p_device_id, p_label, coalesce(p_details, '{}'::jsonb));
$$;
revoke all on function public.airvalet_sms_audit_write(text, uuid, text, jsonb) from public, anon, authenticated;

create or replace function public.airvalet_sms_audit_devices()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.airvalet_sms_audit_write(case new.status when 'approved' then 'DEVICE_APPROVED' when 'revoked' then 'DEVICE_REVOKED' else 'DEVICE_REQUESTED' end,
      new.id, new.label, jsonb_build_object('user_agent', left(coalesce(new.user_agent, ''), 160)));
  else
    if new.status is distinct from old.status then
      perform public.airvalet_sms_audit_write(case new.status when 'approved' then 'DEVICE_APPROVED' when 'revoked' then 'DEVICE_REVOKED' else 'DEVICE_REQUESTED' end,
        new.id, new.label, jsonb_build_object('from', old.status, 'to', new.status));
    end if;
    if new.label is distinct from old.label then
      perform public.airvalet_sms_audit_write('DEVICE_RENAMED', new.id, new.label, jsonb_build_object('from', old.label));
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public.airvalet_sms_audit_devices() from public, anon, authenticated;

create or replace function public.airvalet_sms_audit_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_lim jsonb := '{}'::jsonb; c text;
begin
  if new.sending_enabled is distinct from old.sending_enabled then
    perform public.airvalet_sms_audit_write(case when new.sending_enabled then 'TEXTING_ON' else 'TEXTING_OFF' end, null, null, '{}'::jsonb);
  end if;
  if new.test_only is distinct from old.test_only then
    perform public.airvalet_sms_audit_write(case when new.test_only then 'TEST_MODE_ON' else 'TEST_MODE_OFF' end, null, null, '{}'::jsonb);
  end if;
  if new.test_phones is distinct from old.test_phones then
    perform public.airvalet_sms_audit_write('TEST_PHONES_CHANGED', null, null, jsonb_build_object(
      'count', cardinality(new.test_phones),
      'last4', (select coalesce(jsonb_agg(right(x, 4)), '[]'::jsonb) from unnest(new.test_phones) x)));
  end if;
  if new.cutover_at is distinct from old.cutover_at then
    perform public.airvalet_sms_audit_write(case when new.cutover_at is null then 'CHECKINS_STOPPED' else 'CHECKINS_STARTED' end, null, null,
      jsonb_build_object('cutover_at', new.cutover_at, 'after_ticket_id', new.cutover_after_id));
  end if;
  foreach c in array array['max_per_phone_hour','max_per_phone_day','max_per_device_hour','max_messages_day','max_segments_day','max_segments_message'] loop
    if (to_jsonb(new) -> c) is distinct from (to_jsonb(old) -> c) then
      v_lim := v_lim || jsonb_build_object(c, jsonb_build_array(to_jsonb(old) -> c, to_jsonb(new) -> c));
    end if;
  end loop;
  if v_lim <> '{}'::jsonb then
    perform public.airvalet_sms_audit_write('LIMITS_CHANGED', null, null, v_lim);
  end if;
  return null;
end;
$$;
revoke all on function public.airvalet_sms_audit_settings() from public, anon, authenticated;

create trigger airvalet_sms_audit_devices_trg
  after insert or update on public.airvalet_sms_devices
  for each row execute function public.airvalet_sms_audit_devices();
create trigger airvalet_sms_audit_settings_trg
  after update on public.airvalet_sms_settings
  for each row execute function public.airvalet_sms_audit_settings();

commit;
