-- LOCAL DB tests for 20261108_airvalet_staff_alerts.sql (check-in / Stripe tip
-- push alerts). Run (one transaction, rolled back; the migration's own
-- begin/commit are stripped by the runner):
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' migrations/20261108_airvalet_staff_alerts.sql;
--    cat tests/portal/sql_staff_alerts_1108_tests.sql) | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres
-- Needs the local logins localadmin (ADMIN), localipad (IPAD_OPS), localtv (TV_ONLY).

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;

-- Grants: only the right roles reach each function.
select pg_temp.check(not has_function_privilege('anon', 'public.airvalet_push_alerts_set(text,text,boolean)', 'execute')
  and has_function_privilege('authenticated', 'public.airvalet_push_alerts_set(text,text,boolean)', 'execute'), 'alerts_set: logged-in staff only');
select pg_temp.check(not has_function_privilege('authenticated', 'public.airvalet_staff_alert_claim(text,bigint)', 'execute')
  and not has_function_privilege('anon', 'public.airvalet_staff_alert_claim(text,bigint)', 'execute')
  and has_function_privilege('service_role', 'public.airvalet_staff_alert_claim(text,bigint)', 'execute'), 'claim: service only');
select pg_temp.check(not has_function_privilege('authenticated', 'public.airvalet_push_staff_targets(text)', 'execute'), 'targets: service only');
select pg_temp.check(not has_function_privilege('authenticated', 'public.airvalet_staff_alert_hook()', 'execute'), 'hook: not callable by staff');

-- Two approved phones with alerts on (subscriptions), one unapproved key.
insert into public.airvalet_sms_devices (key_hash, label, status) values
  (public.airvalet_sms_device_key_hash('owner_phone_key_' || repeat('a', 40)), 'T Owner iPhone', 'approved'),
  (public.airvalet_sms_device_key_hash('ipad_device_key_' || repeat('b', 40)), 'T iPad', 'approved'),
  (public.airvalet_sms_device_key_hash('pending_dev_key_' || repeat('c', 40)), 'T pending', 'pending');
insert into public.airvalet_push_subs (device_id, endpoint, p256dh, auth, show_preview)
select d.id, 'https://web.push.apple.com/T' || replace(d.label, ' ', '-'), repeat('p', 87), repeat('a', 22), true
  from public.airvalet_sms_devices d where d.label in ('T Owner iPhone', 'T iPad');
update public.airvalet_portal_settings set push_enabled = true;

-- Login ids read BEFORE switching role (RLS hides user_profiles from 'authenticated').
select id as u_ipad from public.user_profiles where username = 'localipad' \gset
select id as u_tv from public.user_profiles where username = 'localtv' \gset
select id as u_admin from public.user_profiles where username = 'localadmin' \gset

-- As the iPad login (IPAD_OPS)
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'u_ipad', 'role', 'authenticated')::text, true);
select pg_temp.check(public.current_user_role() = 'IPAD_OPS', 'test acts as the iPad login');
select pg_temp.check((public.airvalet_push_alerts_set('ipad_device_key_' || repeat('b', 40), 'CHECK_IN', true))->>'result' = 'FORBIDDEN', 'iPad login cannot turn on check-in alerts (ADMIN only)');
select pg_temp.check((public.airvalet_push_alerts_set('ipad_device_key_' || repeat('b', 40), 'TIP', true))->>'result' = 'FORBIDDEN', 'iPad login cannot turn on tip alerts (ADMIN only)');
select pg_temp.check((public.airvalet_push_alerts_get('ipad_device_key_' || repeat('b', 40))) = '{"check_in": false, "tip": false}'::jsonb, 'iPad phone: no admin alerts');
-- As the TV login
select set_config('request.jwt.claims', json_build_object('sub', :'u_tv', 'role', 'authenticated')::text, true);
select pg_temp.check(public.current_user_role() = 'TV_ONLY', 'test acts as the TV login');
select pg_temp.check((public.airvalet_push_alerts_set('ipad_device_key_' || repeat('b', 40), 'TIP', true))->>'result' = 'FORBIDDEN', 'TV login cannot change alerts');
-- As the owner (ADMIN)
select set_config('request.jwt.claims', json_build_object('sub', :'u_admin', 'role', 'authenticated')::text, true);
select pg_temp.check(public.current_user_role() = 'ADMIN', 'test acts as the ADMIN login');
select pg_temp.check((public.airvalet_push_alerts_set('owner_phone_key_' || repeat('a', 40), 'CHECK_IN', true))->>'result' = 'OK', 'ADMIN turns on check-in alerts');
select pg_temp.check((public.airvalet_push_alerts_set('owner_phone_key_' || repeat('a', 40), 'TIP', true))->>'result' = 'OK', 'ADMIN turns on tip alerts');
select pg_temp.check((public.airvalet_push_alerts_set('pending_dev_key_' || repeat('c', 40), 'TIP', true))->>'result' = 'DEVICE_NOT_AUTHORIZED', 'unapproved phone refused');
select pg_temp.check((public.airvalet_push_alerts_set('never_seen_key_' || repeat('d', 40), 'TIP', true))->>'result' = 'DEVICE_NOT_AUTHORIZED', 'unknown phone refused');
select pg_temp.check((public.airvalet_push_alerts_set('owner_phone_key_' || repeat('a', 40), 'SMS', true))->>'result' = 'BAD_KIND', 'unknown alert kind refused');
reset role;

select pg_temp.check((select count(*) from public.airvalet_push_staff_targets('CHECK_IN')) = 1 and (select count(*) from public.airvalet_push_staff_targets('TIP')) = 1
  and (select count(*) from public.airvalet_push_staff_targets('REMINDER')) = 0, 'targets: only the owner phone, for check-in and tip');
update public.airvalet_portal_settings set push_enabled = false;
select pg_temp.check((select count(*) from public.airvalet_push_staff_targets('CHECK_IN')) = 0, 'portal alerts switched off → no targets');
update public.airvalet_portal_settings set push_enabled = true;

-- Claims: check-ins (no Vault secrets yet → the trigger queues nothing)
delete from vault.secrets where name in ('airvalet_functions_url', 'staff_alert_secret');   -- local DB may keep a dead test URL (rolled back)
create temp table q0 as select count(*) n from net.http_request_queue;
insert into public.passengers (id, name, phone, ticket, status, ret) values
  (981101, 'T ONE', '3055550101', 'T-1', 'PENDING', ''), (981102, 'T TWO', '3055550102', 'T-2', 'NO DATE', ''),
  (981103, 'T THREE', '3055550103', 'T-3', 'PENDING', ''), (981104, 'T FOUR', '3055550104', 'T-4', 'PENDING', ''),
  (981105, 'T DONE', '3055550105', 'T-5', 'DELIVERED', '');
select pg_temp.check((select count(*) from net.http_request_queue) = (select n from q0), 'Vault not configured → the trigger does nothing (check-in saved)');
delete from public.airvalet_notify_log where dedupe_key like 'push:CHECK\_IN:%';
select pg_temp.check(public.airvalet_staff_alert_claim('CHECK_IN', 981101)->>'mode' = 'single', '1st check-in in a minute: single alert');
select pg_temp.check(public.airvalet_staff_alert_claim('CHECK_IN', 981101)->>'mode' = 'skip', 'same check-in again: never twice');
select pg_temp.check((select (j->>'mode') = 'single' and (j->>'ticket') = 'T-2' and (j->>'name') = 'T TWO' from (select public.airvalet_staff_alert_claim('CHECK_IN', 981102) j) x), '2nd: single, with ticket and name');
select pg_temp.check(public.airvalet_staff_alert_claim('CHECK_IN', 981103)->>'mode' = 'summary', '3rd in the same minute: one "more check-ins" alert');
select pg_temp.check(public.airvalet_staff_alert_claim('CHECK_IN', 981104)->>'mode' = 'skip', '4th in the same minute: silent');
select pg_temp.check(exists (select 1 from public.airvalet_notify_log where dedupe_key = 'push:CHECK_IN:981104' and status = 'skipped'), 'silent one is recorded (never alerted later)');
select pg_temp.check(public.airvalet_staff_alert_claim('CHECK_IN', 981105)->>'mode' = 'skip', 'a delivered ticket is not a check-in');
select pg_temp.check(public.airvalet_staff_alert_claim('CHECK_IN', 999999999)->>'mode' = 'skip', 'unknown ticket: skip');
update public.airvalet_notify_log set created_at = now() - interval '2 minutes' where dedupe_key like 'push:CHECK\_IN:98110%';
insert into public.passengers (id, name, phone, ticket, status, ret) values (981106, 'T SIX', '3055550106', 'T-6', 'PENDING', '');
select pg_temp.check(public.airvalet_staff_alert_claim('CHECK_IN', 981106)->>'mode' = 'single', 'a minute later: single alerts again');

-- Claims: Stripe tips
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_checkout_session_id, stripe_event_id)
values (981101, 'T-1', 1500, 'TIP', 'STRIPE', 'succeeded', 'cs_test_t1', 'evt_t1') returning id as tip_ok \gset
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_checkout_session_id, stripe_event_id)
values (null, null, 700, 'TIP', 'STRIPE', 'refunded', 'cs_test_t2', 'evt_t2') returning id as tip_ref \gset
select pg_temp.check((select (j->>'mode') = 'single' and (j->>'amount_cents')::int = 1500 and (j->>'ticket') = 'T-1' and (j->>'name') = 'T ONE'
  from (select public.airvalet_staff_alert_claim('TIP', :tip_ok) j) x), 'succeeded tip: alert with amount, ticket and guest');
select pg_temp.check(public.airvalet_staff_alert_claim('TIP', :tip_ok)->>'mode' = 'skip', 'same tip again: never twice');
select pg_temp.check(public.airvalet_staff_alert_claim('TIP', :tip_ref)->>'mode' = 'skip', 'refunded tip: no alert');
select pg_temp.check(public.airvalet_staff_alert_claim('NOPE', 1)->>'mode' = 'skip', 'unknown kind: skip');

-- The trigger, with Vault configured (local values; never the production URL)
select vault.create_secret('http://127.0.0.1:9/functions/v1', 'airvalet_functions_url');
select vault.create_secret('test-secret-value', 'staff_alert_secret');
select vault.create_secret('test-platform-jwt', 'aircraft_tracking_platform_jwt') where not exists (select 1 from vault.secrets where name = 'aircraft_tracking_platform_jwt');
create temp table q1 as select coalesce(max(id), 0) m from net.http_request_queue;
insert into public.passengers (id, name, phone, ticket, status, ret) values (981107, 'T SEVEN', '3055550107', 'T-7', 'PENDING', '');
insert into public.passengers (id, name, phone, ticket, status, ret) values (981108, 'T ARCH', '3055550108', 'T-8', 'ARCHIVED', '');
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_checkout_session_id, stripe_event_id)
values (981107, 'T-7', 2000, 'TIP', 'STRIPE', 'succeeded', 'cs_test_t3', 'evt_t3');
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_checkout_session_id, stripe_event_id)
values (981107, 'T-7', 2500, 'TIP', 'STRIPE', 'refunded', 'cs_test_t4', 'evt_t4');
create temp table q2 as select url, headers, convert_from(body, 'utf8')::jsonb b from net.http_request_queue where id > (select m from q1);
select pg_temp.check((select count(*) from q2) = 2, 'trigger: one call for the new check-in and one for the succeeded tip (none for archived / refunded)');
select pg_temp.check((select count(*) from q2 where url = 'http://127.0.0.1:9/functions/v1/staff-alert' and b->>'kind' = 'CHECK_IN' and (b->>'id')::bigint = 981107) = 1, 'trigger: check-in call to staff-alert with kind + id');
select pg_temp.check((select count(*) from q2 where b->>'kind' = 'TIP') = 1, 'trigger: tip call');
select pg_temp.check((select bool_and(headers->>'X-Staff-Alert-Secret' = 'test-secret-value' and headers->>'Authorization' like 'Bearer %') from q2), 'trigger: secret + platform JWT sent');
select pg_temp.check((select bool_and(not (b ? 'name') and not (b ? 'phone')) from q2), 'trigger body carries no personal data');
update public.passengers set status = 'DELIVERED' where id = 981107;
select pg_temp.check((select count(*) from net.http_request_queue where id > (select m from q1)) = 2, 'an update (delivery) never alerts');
