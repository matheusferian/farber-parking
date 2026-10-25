-- LOCAL DB tests for 20261027_airvalet_digital_pass_golive.sql (rolled back).
\set ON_ERROR_STOP 1
begin;
create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin if cond is distinct from true then raise exception 'FAIL: %', label; end if; raise notice 'ok  %', label; end $$;
create function pg_temp.act(u text) returns void language plpgsql as $$
declare v_id uuid;
begin
  reset role;
  if u is null then perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; return; end if;
  select id into v_id from public.user_profiles where username = u;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', u || '@airvalet.local')::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.errs(q text) returns boolean language plpgsql as $$ begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.today() returns text language sql as $$ select to_char((now() at time zone 'America/New_York')::date, 'MMDD') $$;

-- ── Tickets ──
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (910001, 'x', now(), 'T ONE', '3055550001', pg_temp.today() || '-71', 'NO DATE');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (910002, 'x', now(), 'T TWO', '3055550002', pg_temp.today() || '-71', 'NO DATE');
select pg_temp.check((select ticket from public.passengers where id = 910002) = pg_temp.today() || '-72', 'same-day duplicate ticket is renumbered to the next free number');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (910003, 'x', now(), 'T THREE', '3055550003', 'A-' || pg_temp.today() || '-72', 'NO DATE');
select pg_temp.check((select ticket from public.passengers where id = 910003) = 'A-' || pg_temp.today() || '-73', 'Ascend shares the same daily sequence (A- prefix kept)');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (910004, 'x', now(), 'T FOUR', '3055550004', pg_temp.today() || '-90', 'NO DATE');
select pg_temp.check((select ticket from public.passengers where id = 910004) = pg_temp.today() || '-90', 'a free number is kept as typed');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (910005, 'x', now(), 'T FIVE', '3055550005', '0101-1', 'NO DATE');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (910006, 'x', now(), 'T SIX', '3055550006', '0101-1', 'NO DATE');
select pg_temp.check((select count(*) from public.passengers where ticket = '0101-1' and id in (910005, 910006)) = 2, 'tickets of another day (typed manually) are left as typed');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values (910007, 'x', now(), 'T SEVEN', '3055550007', 'CUSTOM 7', 'NO DATE');
select pg_temp.check((select ticket from public.passengers where id = 910007) = 'CUSTOM 7', 'non-standard tickets are unchanged');
select pg_temp.check((select count(*) from (select ticket, (checkin_date at time zone 'America/New_York')::date from public.passengers where id between 910001 and 910004 group by 1, 2 having count(*) > 1) d) = 0, 'no same-day duplicates among new check-ins');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, client_key) values (910008, 'x', now(), 'T EIGHT', '3055550008', pg_temp.today() || '-91', 'NO DATE', 'ck_form_0000000000000001');
select pg_temp.check(pg_temp.errs($$insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, client_key) values (910009, 'x', now(), 'T EIGHT', '3055550008', '0000-1', 'NO DATE', 'ck_form_0000000000000001')$$), 'same client key twice → second insert refused (no duplicate check-in)');
update public.passengers set ticket = ticket where id = 910001;
select pg_temp.check((select ticket from public.passengers where id = 910001) = pg_temp.today() || '-71', 'edits never renumber');

-- ── Chat ──
insert into public.airvalet_sms_devices (key_hash, label, status) values (public.airvalet_sms_device_key_hash('golive_test_device_key_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'), 'Golive iPad', 'approved');
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, return_operator) values (910101, 'x', now(), 'CHAT GUEST', '(305) 555-0301', '9999-1', 'PENDING', 'MAKERS'), (910102, 'x', now(), 'OTHER GUEST', '(305) 555-0301', '9999-2', 'PENDING', 'MAKERS');
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
  select id, '+13055550301', (select d.id from public.airvalet_sms_devices d where d.label = 'Golive iPad'), gen_random_uuid() from public.passengers where id in (910101, 910102);
select set_config('t.tok', public.airvalet_pass_mint(910101), true), set_config('t.tok2', public.airvalet_pass_mint(910102), true);
update public.airvalet_portal_settings set portal_enabled = true, chat_enabled = false where id;
select pg_temp.check(public.airvalet_portal_send_message(current_setting('t.tok'), 'c1', 'Hello', 'ck_chat_000000000000001') ->> 'result' = 'UNAVAILABLE', 'chat closed → unavailable');
update public.airvalet_portal_settings set chat_enabled = true where id;
select pg_temp.check(public.airvalet_portal_view(current_setting('t.tok'), 'c1') #>> '{pass,chat_enabled}' = 'true', 'portal says chat is open');
select pg_temp.check(public.airvalet_portal_send_message(current_setting('t.tok'), 'c1', 'Hi, landing at 6pm', 'ck_chat_000000000000002') ->> 'result' = 'OK', 'guest sends a chat message');
select pg_temp.check(public.airvalet_portal_send_message(current_setting('t.tok'), 'c1', 'Hi, landing at 6pm', 'ck_chat_000000000000002') ->> 'duplicate' = 'true', 'same client key → one message');
select pg_temp.check((select count(*) from public.airvalet_sms_messages where passenger_id = 910101 and provider = 'portal' and direction = 'inbound' and message_type = 'INBOUND') = 1, 'stored once as an inbound message (no SMS)');
select pg_temp.check((select count(*) from public.airvalet_alert_events e join public.airvalet_sms_messages m on m.id = e.ref_id where m.passenger_id = 910101) = 1, 'chat message alerts staff like a text');
select pg_temp.check(public.airvalet_portal_send_message(current_setting('t.tok'), 'c1', '', 'ck_chat_000000000000003') ->> 'result' = 'INVALID', 'empty message refused');
select pg_temp.check(public.airvalet_portal_send_message(current_setting('t.tok'), 'c1', repeat('x', 601), 'ck_chat_000000000000004') ->> 'result' = 'INVALID', 'over 600 chars refused');
insert into public.airvalet_sms_messages (direction, passenger_id, phone_e164, message_type, body, provider, status, idempotency_key, segments, provider_message_sid)
values ('outbound', 910101, '+13055550301', 'CHECK_IN', 'Welcome to Makers Air Valet!' || chr(10) || 'Your digital valet pass:' || chr(10) || 'https://airvalet.farberos.com/a#*****************', 'twilio', 'delivered', 'k-golive-1', 1, 'SMgolive1'),
       ('outbound', 910101, '+13055550301', 'REPLY', 'never sent', 'twilio', 'failed', 'k-golive-2', 1, null),
       ('inbound', 910101, '+13055550301', 'INBOUND_STOP', 'STOP', 'twilio', 'received', null, 1, 'SMgolivestop');
select set_config('t.msgs', public.airvalet_portal_messages(current_setting('t.tok'), 'c1')::text, true);
select pg_temp.check(jsonb_array_length(current_setting('t.msgs')::jsonb -> 'messages') = 2, 'thread: delivered text + chat message (failed send and STOP hidden)');
select pg_temp.check(position('*****' in current_setting('t.msgs')) = 0 and position('(your valet pass link)' in current_setting('t.msgs')) > 0, 'masked link shown as "(your valet pass link)"');
select pg_temp.check(jsonb_array_length(public.airvalet_portal_messages(current_setting('t.tok2'), 'c2') -> 'messages') = 0, 'another passenger on the same phone sees none of it');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($$select public.airvalet_portal_staff_reply(910101, 'x', 'compose-0001')$$), 'TV cannot reply');
select pg_temp.act('localipad');
select pg_temp.check(public.airvalet_portal_staff_reply(910101, 'Thanks, noted. See you at Hangar 19.', 'compose-0002', 'Ana') ->> 'result' = 'OK', 'staff chat-only reply');
select pg_temp.check(public.airvalet_portal_staff_reply(910101, 'Thanks, noted. See you at Hangar 19.', 'compose-0002', 'Ana') ->> 'duplicate' = 'true', 'same compose id → one reply');
select pg_temp.check(public.airvalet_portal_staff_reply(910101, 'On our way.', 'compose:' || gen_random_uuid()::text, 'Ana') ->> 'result' = 'OK', 'app compose id format (compose:<uuid>) accepted');
reset role;
select pg_temp.check((select count(*) from public.airvalet_sms_messages where passenger_id = 910101 and provider = 'portal' and direction = 'outbound') = 2, 'chat replies stored as provider portal (no SMS)');
select pg_temp.check(jsonb_array_length(public.airvalet_portal_messages(current_setting('t.tok'), 'c1') -> 'messages') = 4, 'replies appear in the guest chat');
update public.airvalet_pass_links set revoked_at = now(), revoke_reason = 'staff' where passenger_id = 910101 and revoked_at is null;
select pg_temp.act('localipad');
select pg_temp.check(public.airvalet_portal_staff_reply(910101, 'x', 'compose-0003') ->> 'result' = 'NO_PASS_LINK', 'chat-only reply refused without an active link');
reset role;

-- ── Digital Pass switch ──
insert into public.airvalet_sms_settings (id) values (true) on conflict do nothing;
update public.airvalet_sms_settings set sending_enabled = true, cutover_at = now(), cutover_after_id = 0 where id;
select pg_temp.act('localiphone');
select pg_temp.check(pg_temp.errs($$select public.airvalet_digital_pass_set(false)$$), 'IPHONE_OPS cannot switch Digital Pass');
select pg_temp.act('localadmin');
select pg_temp.check((public.airvalet_digital_pass_set(false) ->> 'on')::boolean = false, 'ADMIN switches OFF');
reset role;
select pg_temp.check((select not sending_enabled and cutover_at is null from public.airvalet_sms_settings where id)
  and (select not chat_enabled and not requests_enabled and portal_enabled from public.airvalet_portal_settings where id), 'OFF: no texts, no new check-ins, chat/requests closed, links still readable');
select pg_temp.act('localadmin');
select pg_temp.check((public.airvalet_digital_pass_set(true) ->> 'on')::boolean, 'ADMIN switches ON');
reset role;
select pg_temp.check((select cutover_at is null from public.airvalet_sms_settings where id), 'ON never starts new check-ins by itself (typed START stays)');
rollback;
