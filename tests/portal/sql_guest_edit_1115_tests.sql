-- LOCAL DB tests for 20261115_airvalet_guest_edit.sql (on top of 20261114). One transaction, rolled back.
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat tests/portal/sql_guest_edit_1115_tests.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.act(u text) returns void language plpgsql as $$
declare v_id uuid;
begin
  reset role;
  if u is null then perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; return; end if;
  select id into v_id from public.user_profiles where username = u;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', u || '@airvalet.local')::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.errs(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.gk(pid bigint) returns text language sql security definer as $$ select public.airvalet_guest_key_of(pid) $$;
create function pg_temp.ng(ids bigint[]) returns int language sql security definer as $$ select count(distinct public.airvalet_guest_key_of(i))::int from unnest(ids) i $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, deldate, checkout_date, obs, tip_received, return_flight, departure_time) values
 (983001, 'x', '2026-06-01 09:00-04', 'JACCLYN MURPHY', '3055559301', 'GE-1', 'DELIVERED', '6/4/2026', 'HANGAR 19', 'BMW X5', 'Black', '', '2026-06-04 10:00-04', null, true, null, null),
 (983002, 'x', '2026-08-01 09:00-04', 'JACCLYN MURPHY', '3055559301', 'GE-2', 'DELIVERED', '8/4/2026', 'HANGAR 19', 'BMW X5', 'Black', '', '2026-08-04 10:00-04', null, null, null, null),
 (983003, 'x', now() - interval '1 day', 'JACCLYN MURPHY', '(305) 555-9301', 'GE-3', 'PENDING', to_char((now() at time zone 'America/New_York')::date + 2, 'FMMM/FMDD/YYYY'), 'HANGAR 16', 'MERCEDES GLE', 'White', '', null, 'Spare key in glovebox', null, 'MA 212', '17:40'),
 (983004, 'x', '2026-09-01 09:00-04', 'JACLYN MURPHY',  '3055559399', 'GE-4', 'DELIVERED', '9/3/2026', 'HANGAR 19', 'Audi Q5', 'Blue', '', '2026-09-03 10:00-04', null, null, null, null);
select set_config('airvalet.tip_ledger', '1', true);
insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, source, business_date, recorded_by) values (983001, 'GE-1', 2000, 'DELIVERY', '2026-06-04', 'x');
update public.passengers set tip_in_person_cents = 2000 where id = 983001;
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id) values (983002, 'GE-2', 1000, 'TIP', 'STRIPE', 'succeeded', 'evt_ge_1');
insert into public.airvalet_sms_devices (key_hash, label, status, decided_at) values (public.airvalet_sms_device_key_hash('ge1115_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), 'GE iPad', 'approved', now());
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id) values (983003, '+13055559301', (select id from public.airvalet_sms_devices where label = 'GE iPad'), gen_random_uuid());
select public.airvalet_pass_mint(983003);
create temp table t_snap as select
  (select md5(string_agg(x::text, '|' order by x.id)) from public.airvalet_pass_links x where passenger_id between 983001 and 983004) links,
  (select count(*) from public.airvalet_sms_messages) sms,
  (select md5(string_agg(x::text, '|' order by x.id)) from public.payments x) pay,
  (select md5(string_agg(x::text, '|' order by x.id)) from public.airvalet_tip_records x) tips,
  (select md5(string_agg(p.name || p.phone || coalesce(p.ret, '') || p.status || coalesce(p.tip_in_person_cents::text, '') || coalesce(p.tip_received::text, ''), '|' order by p.id)) from public.passengers p where p.id between 983001 and 983004) idfields,
  pg_temp.gk(983001) key1, pg_temp.gk(983004) key4;
grant select on t_snap to authenticated;

-- ── Permissions ───────────────────────────────────────────────────────────
select pg_temp.check(not has_function_privilege('anon', 'public.airvalet_guest_profile_save(text,text,text,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.airvalet_guest_visit_update(bigint,jsonb,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.airvalet_guest_vehicle_update(text,bigint[],text,text,uuid)', 'execute'), 'anon (Valet Pass) cannot edit guests');
select pg_temp.check(not has_function_privilege('authenticated', 'public.airvalet_guest_apply_ticket_change(uuid,text,bigint,text,text,text)', 'execute'), 'internal ticket writer not callable by the app');
select pg_temp.check(not has_table_privilege('authenticated', 'public.airvalet_guest_profiles', 'insert') and not has_table_privilege('authenticated', 'public.airvalet_guest_changes', 'update')
  and not has_table_privilege('anon', 'public.airvalet_guest_changes', 'select'), 'no direct writes; anon reads nothing');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$ select public.airvalet_guest_profile_save(pg_temp.gk(983001), 'X Y', null, gen_random_uuid()) $q$), 'TV_ONLY cannot edit');

-- ── Edit guest (corrected details; tickets untouched) ─────────────────────
select pg_temp.act('localipad');
select pg_temp.check(public.airvalet_guest_profile_save(pg_temp.gk(983001), ' ', null, gen_random_uuid()) ->> 'result' = 'INVALID_NAME', 'empty name refused');
select pg_temp.check(public.airvalet_guest_profile_save(pg_temp.gk(983001), 'Jacklyn Murphy', '0000000000', gen_random_uuid()) ->> 'result' = 'INVALID_PHONE', 'placeholder phone refused');
select pg_temp.check(public.airvalet_guest_profile_save(pg_temp.gk(983001), 'Jacklyn  Murphy', '(305) 555-9302', '44444444-0000-0000-0000-000000000001') ->> 'result' = 'OK', 'name and phone corrected');
select pg_temp.check(public.airvalet_guest_profile_save(pg_temp.gk(983001), 'Jacklyn  Murphy', '(305) 555-9302', '44444444-0000-0000-0000-000000000001') ->> 'duplicate' = 'true', 'same tap again → saved once');
select pg_temp.check(public.airvalet_guest_profile_save(pg_temp.gk(983001), 'JACKLYN MURPHY', '(305) 555-9302', gen_random_uuid()) ->> 'result' = 'UNCHANGED', 'same values → unchanged');
select pg_temp.check((select x ->> 'name' = 'JACKLYN MURPHY' and x ->> 'name_on_tickets' = 'JACCLYN MURPHY' and x -> 'profile' ->> 'phone' = '(305) 555-9302' and x -> 'profile' ->> 'updated_by' = 'localipad@airvalet.local'
                        from (select public.airvalet_guest_profile(pg_temp.gk(983001)) x) y), 'profile shows the corrected name and phone; the tickets'' name kept apart');
select pg_temp.check((select jsonb_array_length(x -> 'changes') = 2 and x -> 'changes' @> '[{"field":"guest_name","old":"JACCLYN MURPHY","new":"JACKLYN MURPHY","by":"localipad@airvalet.local"}]'
                        and x -> 'changes' @> '[{"field":"guest_phone","new":"(305) 555-9302"}]' from (select public.airvalet_guest_profile(pg_temp.gk(983001)) x) y), 'history: old / new / who for name and phone');
reset role;
select pg_temp.check((select md5(string_agg(p.name || p.phone || coalesce(p.ret, '') || p.status || coalesce(p.tip_in_person_cents::text, '') || coalesce(p.tip_received::text, ''), '|' order by p.id)) from public.passengers p where p.id between 983001 and 983004) = (select idfields from t_snap),
  'tickets keep their name, phone, return, status, tips (nothing rewritten)');
select pg_temp.check((select md5(string_agg(x::text, '|' order by x.id)) from public.airvalet_pass_links x where passenger_id between 983001 and 983004) = (select links from t_snap), 'Valet Pass link not revoked (ticket phone untouched)');
select pg_temp.check((select count(*) from public.airvalet_sms_messages) = (select sms from t_snap), 'no text sent');
select pg_temp.check(pg_temp.gk(983001) = (select key1 from t_snap) and pg_temp.ng(array[983001, 983004]) = 2, 'identity unchanged: the corrected name does NOT merge JACLYN (other phone)');
select pg_temp.act('localipad');
select pg_temp.check((select count(*) = 1 from jsonb_array_elements(public.airvalet_guest_search('jacklyn', 10, 0) -> 'rows') r where r ->> 'name' = 'JACKLYN MURPHY'), 'search finds the corrected name');
select pg_temp.check((select count(*) = 1 from jsonb_array_elements(public.airvalet_guest_search('555-9302', 10, 0) -> 'rows') r where r ->> 'name' = 'JACKLYN MURPHY'), 'search finds the corrected phone');
select pg_temp.check((select jsonb_array_length(x -> 'guests') = 1 and x -> 'guests' -> 0 ->> 'name' = 'JACKLYN MURPHY' and (x -> 'guests' -> 0 ->> 'visits')::int = 3 from (select public.airvalet_guest_lookup_phone('3055559302') x) y),
  'check-in: the corrected phone finds the guest, with the corrected name');

-- ── Edit visit (one ticket, operational fields only) ──────────────────────
select pg_temp.check(public.airvalet_guest_visit_update(983003, '{"name":"X"}', gen_random_uuid()) ->> 'result' = 'FIELD_NOT_ALLOWED', 'name not editable here');
select pg_temp.check(public.airvalet_guest_visit_update(983003, '{"phone":"3055550000"}', gen_random_uuid()) ->> 'result' = 'FIELD_NOT_ALLOWED', 'phone not editable here (would revoke the pass)');
select pg_temp.check(public.airvalet_guest_visit_update(983003, '{"ret":"1/1/2030"}', gen_random_uuid()) ->> 'result' = 'FIELD_NOT_ALLOWED', 'return date keeps its own flow (reason)');
select pg_temp.check(public.airvalet_guest_visit_update(983003, '{"status":"DELIVERED"}', gen_random_uuid()) ->> 'result' = 'FIELD_NOT_ALLOWED', 'status not editable here');
select pg_temp.check(public.airvalet_guest_visit_update(983001, '{"tip_in_person_cents":1}', gen_random_uuid()) ->> 'result' = 'FIELD_NOT_ALLOWED', 'money not editable here');
select pg_temp.check(public.airvalet_guest_visit_update(983003, '{"departure_time":"25:99"}', gen_random_uuid()) ->> 'result' = 'INVALID', 'bad arrival time refused');
select pg_temp.check(public.airvalet_guest_visit_update(983003, '{"car":"Mercedes GLS","color":"Silver","return_flight":"ma 318","departure_time":"18:05","obs":"Spare key in glovebox. Child seat."}', '55555555-0000-0000-0000-000000000001') ->> 'changed' = '5',
  'visit: vehicle, color, flight, arrival time, notes saved');
select pg_temp.check(public.airvalet_guest_visit_update(983003, '{"car":"Mercedes GLS"}', '55555555-0000-0000-0000-000000000001') ->> 'duplicate' = 'true', 'same tap again → once');
select pg_temp.check(public.airvalet_guest_visit_update(983003, '{"car":"MERCEDES GLS"}', gen_random_uuid()) ->> 'result' = 'UNCHANGED', 'no change → unchanged');
reset role;
select pg_temp.check((select car = 'MERCEDES GLS' and color = 'Silver' and return_flight = 'MA 318' and departure_time = '18:05' and status = 'PENDING' from public.passengers where id = 983003), 'ticket updated, status untouched');
select pg_temp.check((select count(*) = 5 from public.activity_log where passenger_id = 983003 and action = 'EDITED' and changed_by = 'localipad@airvalet.local' and detail like '%| From Guests')
  and (select old_value = 'MERCEDES GLE' and new_value = 'MERCEDES GLS' from public.activity_log where passenger_id = 983003 and field_name = 'car'), 'ticket history: 5 lines, old / new / who');
select pg_temp.check((select count(*) = 5 from public.airvalet_guest_changes where passenger_id = 983003 and ticket = 'GE-3'), 'Guests history: 5 lines with the ticket');
select pg_temp.check((select md5(string_agg(x::text, '|' order by x.id)) from public.airvalet_pass_links x where passenger_id between 983001 and 983004) = (select links from t_snap)
  and (select count(*) from public.airvalet_sms_messages) = (select sms from t_snap), 'visit edit: pass link kept, no text');

-- ── Vehicles (two cars stay two cars) ─────────────────────────────────────
select pg_temp.act('localiphone');
select pg_temp.check(public.airvalet_guest_vehicle_update(pg_temp.gk(983001), array[983001, 983004]::bigint[], 'BMW X6', 'Black', gen_random_uuid()) ->> 'result' = 'NOT_THIS_GUEST', 'another guest''s ticket refused');
select pg_temp.check(public.airvalet_guest_vehicle_update(pg_temp.gk(983001), array[]::bigint[], 'BMW X6', 'Black', gen_random_uuid()) ->> 'result' = 'NO_VISITS', 'no visit ticked → nothing');
select pg_temp.check(public.airvalet_guest_vehicle_update(pg_temp.gk(983001), array[983001, 983002]::bigint[], 'bmw x6', 'Black', '66666666-0000-0000-0000-000000000001') ->> 'tickets_changed' = '2', 'BMW corrected on the 2 ticked visits');
reset role;
select pg_temp.check((select string_agg(id || ':' || car || ':' || color, ',' order by id) from public.passengers where id between 983001 and 983003) = '983001:BMW X6:Black,983002:BMW X6:Black,983003:MERCEDES GLS:Silver',
  'the Mercedes visit is untouched');
select pg_temp.check((select md5(string_agg(x::text, '|' order by x.id)) from public.payments x) = (select pay from t_snap) and (select md5(string_agg(x::text, '|' order by x.id)) from public.airvalet_tip_records x) = (select tips from t_snap),
  'payments and tips untouched by every edit');
select pg_temp.act('localipad');
select pg_temp.check((select jsonb_array_length(public.airvalet_guest_profile(pg_temp.gk(983001)) -> 'vehicles') = 2), 'profile: two vehicles (BMW X6, Mercedes GLS)');

select 'all 1115 checks passed';
