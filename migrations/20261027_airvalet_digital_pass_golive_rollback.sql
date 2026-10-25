-- Rollback of 20261027_airvalet_digital_pass_golive.sql. Never deletes data:
-- chat messages stay in airvalet_sms_messages (the provider check keeps
-- 'portal' while such rows exist), passengers.client_key stays while used,
-- tickets keep the numbers they were given. Safe to run more than once.

begin;

drop trigger if exists airvalet_ticket_assign on public.passengers;
drop function if exists public.airvalet_ticket_assign();
drop function if exists public.airvalet_digital_pass_set(boolean);
drop function if exists public.airvalet_digital_pass_status();
drop function if exists public.airvalet_portal_staff_reply(bigint, text, text, text);
drop function if exists public.airvalet_portal_send_message(text, text, text, text);
drop function if exists public.airvalet_portal_messages(text, text);

do $$
begin
  if not exists (select 1 from public.airvalet_sms_messages where provider = 'portal') then
    alter table public.airvalet_sms_messages drop constraint airvalet_sms_messages_provider_check;
    alter table public.airvalet_sms_messages add constraint airvalet_sms_messages_provider_check check (provider in ('twilio', 'mock'));
  end if;
  if not exists (select 1 from public.passengers where client_key is not null) then
    drop index if exists public.passengers_client_key_unique;
    alter table public.passengers drop column if exists client_key;
  end if;
end $$;

-- Portal view / settings: back to the 20261026 versions (chat key removed).
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('''chat_enabled''' in v) > 0 then
    v := replace(v, chr(10) || '      ''chat_enabled'', v_set.chat_enabled and v_p.status <> ''ARCHIVED'',', '');
    execute v;
  end if;
end $$;
update public.airvalet_portal_settings s set chat_enabled = false where s.id;

commit;
