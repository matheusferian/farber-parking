-- LOCAL DB tests for 20261114_airvalet_guests.sql. One transaction, rolled back. Runner:
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' migrations/20261114_airvalet_guests.sql;
--    cat tests/portal/sql_guests_1114_tests.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres
-- Fixtures mirror real patterns found in the 2026-10-27 audit (families on one phone, typos, titles,
-- placeholder phones, legacy M/D/YYYY dates). Needs the local logins localadmin / localipad / localmanager / localtv.

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
-- test helper: the guest key of a ticket (the app cannot call the internal identity function)
create function pg_temp.gk(pid bigint) returns text language sql security definer as $$ select public.airvalet_guest_key_of(pid) $$;
create function pg_temp.ng(ids bigint[]) returns int language sql security definer as $$ select count(distinct public.airvalet_guest_key_of(i))::int from unnest(ids) i $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- ── Fixtures ──────────────────────────────────────────────────────────────
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, deldate, checkout_date, previous_delivery_location, obs, tip_received, carwash_status, delivery_type) values
 (981001, '6/4/2025 8:04:49', null, 'LIBBY INFINGER',  '(305) 555-7301', 'GT-1', 'DELIVERED', '6/9/2025', 'HANGAR 19', 'BMW X5', 'Black', '6/9/2025', null, null, null, null, null, null),
 (981002, 'x', '2026-09-02 13:00-04', 'RHETT INFINGER', '+1 305 555 7301', 'GT-2', 'DELIVERED', '9/6/2026', 'HANGAR 19', 'Ford F150', 'White', '', '2026-09-06 10:00-04', 'HANGAR 16', null, false, null, 'NORMAL'),
 (981003, 'x', '2026-08-01 09:00-04', 'PHILIP STEUB',  '3055557302', 'GT-3', 'DELIVERED', '8/5/2026', 'HANGAR 19', 'Audi Q7', 'Gray', '', '2026-08-05 15:00-04', 'HANGAR 7', 'Battery was weak, jump started', null, 'WASHED', 'NORMAL'),
 (981004, 'x', '2026-10-01 09:00-04', 'PHILIP STEUBE', '305.555.7302', 'GT-4', 'DELIVERED', '10/4/2026', 'HANGAR 19', 'Audi Q7', 'Gray', '', '2026-10-04 15:00-04', 'HANGAR 16', null, true, null, 'LOCKBOX'),
 (981005, 'x', '2026-07-01 09:00-04', 'DOANALD RIEDEL', '3055557303', 'GT-5', 'DELIVERED', '7/3/2026', 'HANGAR 19', 'Lexus RX', 'Blue', '7/3/2026', null, null, null, null, null, null),
 (981006, 'x', '2026-10-20 09:00-04', 'DONALD RIEDEL',  '3055557303', 'GT-6', 'PENDING', '10/30/2026', 'HANGAR 18', 'Lexus RX', 'Blue', '', null, null, null, null, null, null),
 (981007, '5/2/2026 7:00:00', null, 'MRS MCATEER',     '3055557304', 'GT-7', 'DELIVERED', '5/4/2026', 'HANGAR 19', 'Jeep', 'Red', '', null, null, null, null, null, null),   -- delivery date unknown
 (981008, 'x', '2026-06-01 09:00-04', 'MCATEER 2',     '3055557304', 'GT-8', 'DELIVERED', '6/3/2026', 'HANGAR 19', 'Jeep', 'Red', '', '2026-06-03 12:00-04', 'HANGAR 18', null, null, null, 'NORMAL'),
 (981009, 'x', '2026-06-10 09:00-04', 'VIRGILIO SUAZO (WORK DAY TRIP)', '3055557305', 'GT-9', 'DELIVERED', '6/10/2026', 'HANGAR 19', 'Tesla', 'White', '', '2026-06-10 18:00-04', 'HANGAR 19', null, null, null, 'NORMAL'),
 (981010, 'x', '2026-07-10 09:00-04', 'VIRGILIO SUAZO', '3055557305', 'GT-10', 'DELIVERED', '7/12/2026', 'HANGAR 19', 'Tesla', 'White', '', '2026-07-12 18:00-04', 'HANGAR 19', null, null, null, 'NORMAL'),
 (981011, 'x', '2026-07-01 09:00-04', 'JOHN DOEMAN',   '0000000000', 'GT-11', 'DELIVERED', '7/2/2026', 'HANGAR 19', 'Kia', 'Gray', '', '2026-07-02 09:00-04', null, null, null, null, 'NORMAL'),
 (981012, 'x', '2026-08-01 09:00-04', 'JOHN DOEMAN',   '0000000000', 'GT-12', 'DELIVERED', '8/2/2026', 'HANGAR 19', 'Kia', 'Gray', '', '2026-08-02 09:00-04', null, null, null, null, 'NORMAL'),
 (981013, 'x', '2026-05-01 09:00-04', 'MARIA LOPEZGT',  '3055557306', 'GT-13', 'DELIVERED', '5/3/2026', 'HANGAR 19', 'Mini', 'Green', '', '2026-05-03 09:00-04', null, null, null, null, 'NORMAL'),
 (981014, 'x', '2026-09-01 09:00-04', 'MARIA LOPEZGT',  '3055557307', 'GT-14', 'DELIVERED', '9/3/2026', 'HANGAR 19', 'Mini', 'Green', '', '2026-09-03 09:00-04', null, null, null, null, 'NORMAL');
insert into public.passenger_return_date_changes (passenger_id, passenger_name, ticket, old_return_date, new_return_date, comment, changed_by)
values (981004, 'PHILIP STEUBE', 'GT-4', '10/3/2026', '10/4/2026', 'Flight moved', 'localipad@airvalet.local');
insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by)
values ('x', 'RETURN DATE', 'PHILIP STEUBE', 'GT-4', 'HANGAR 16', 'Return date changed: 10/3/2026 → 10/4/2026 | Reason: Flight moved', 981004, 'localipad@airvalet.local');
insert into public.airvalet_pass_requests (passenger_id, kind, requested_date, status, created_at, decided_at, client_key) values (981004, 'CAR_WASH', null, 'APPROVED', '2026-10-02 10:00-04', '2026-10-02 11:00-04', 'gt-carwash-request-0001');
select set_config('airvalet.tip_ledger', '1', true);
insert into public.airvalet_tip_records (passenger_id, ticket, amount_cents, source, business_date, recorded_by) values (981004, 'GT-4', 2000, 'DELIVERY', '2026-10-04', 'localipad@airvalet.local');
update public.passengers set tip_in_person_cents = 2000 where id = 981004;
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id) values
 (981003, 'GT-3', 1000, 'TIP', 'STRIPE', 'succeeded', 'evt_gt_1'), (981003, 'GT-3', 500, 'TIP', 'STRIPE', 'refunded', 'evt_gt_2');
create temp table t_before as select md5(string_agg(p::text, '|' order by p.id)) h from public.passengers p where p.id between 981001 and 981014;
create temp table t_k as select null::text k;
grant all on t_k, t_before to authenticated;

-- ── 1. Identity rules ─────────────────────────────────────────────────────
select pg_temp.check(pg_temp.ng(array[981001, 981002]) = 2, 'family on one phone (LIBBY / RHETT) = two guests');
select pg_temp.check(pg_temp.ng(array[981003, 981004]) = 1, 'last-name typo, phone in another format (STEUB / STEUBE) = one guest');
select pg_temp.check(pg_temp.ng(array[981005, 981006]) = 2, 'first-name typo (DOANALD / DONALD) NOT merged automatically');
select pg_temp.check(pg_temp.ng(array[981007, 981008]) = 1, 'title and digits ignored (MRS MCATEER / MCATEER 2) = one guest');
select pg_temp.check(pg_temp.ng(array[981009, 981010]) = 1, 'bracket note ignored (VIRGILIO SUAZO (WORK DAY TRIP)) = one guest');
select pg_temp.check(pg_temp.ng(array[981011, 981012]) = 2, 'placeholder phone 0000000000: same name never merged automatically');
select pg_temp.check(pg_temp.ng(array[981013, 981014]) = 2, 'same name on two phones: two guests (suggested only)');

-- ── 2. Permissions ────────────────────────────────────────────────────────
select pg_temp.check(not has_function_privilege('anon', 'public.airvalet_guest_search(text,integer,integer)', 'execute')
  and not has_function_privilege('anon', 'public.airvalet_guest_profile(text)', 'execute')
  and not has_function_privilege('anon', 'public.airvalet_guest_lookup_phone(text)', 'execute'), 'anon (Valet Pass) cannot call any guest function');
select pg_temp.check(not has_table_privilege('anon', 'public.airvalet_guest_notes', 'select') and not has_table_privilege('authenticated', 'public.airvalet_guest_notes', 'insert')
  and not has_table_privilege('authenticated', 'public.airvalet_guest_identity', 'insert') and not has_table_privilege('authenticated', 'public.airvalet_guest_note_revisions', 'update'),
  'no direct writes to the guest tables; anon reads nothing');
select pg_temp.check(not has_function_privilege('authenticated', 'public.airvalet_guest_members(text)', 'execute') and not has_function_privilege('authenticated', 'public.airvalet_guest_key_of(bigint)', 'execute'), 'internal identity functions not callable by the app');
select pg_temp.act('localtv');
select pg_temp.check(pg_temp.errs($q$ select public.airvalet_guest_search('STEUB', 10, 0) $q$), 'TV_ONLY cannot search guests');
select pg_temp.check(pg_temp.errs($q$ select public.airvalet_guest_lookup_phone('3055557301') $q$), 'TV_ONLY cannot look up phones');
select pg_temp.act(null);
select pg_temp.check(pg_temp.errs($q$ select public.airvalet_guest_search('STEUB', 10, 0) $q$), 'anon cannot search');

-- ── 3. Search ─────────────────────────────────────────────────────────────
select pg_temp.act('localipad');
select pg_temp.check((select (r ->> 'visits')::int = 2 and r ->> 'name' = 'PHILIP STEUBE' and r ->> 'vehicle' = 'Gray Audi Q7'
                        from jsonb_array_elements(public.airvalet_guest_search('steub', 10, 0) -> 'rows') r), 'partial name → one guest, 2 visits, latest name and vehicle');
select pg_temp.check((select count(*) = 2 from jsonb_array_elements(public.airvalet_guest_search('305-555-7301', 10, 0) -> 'rows')), 'phone with dashes → both guests on that phone');
select pg_temp.check((select count(*) = 2 from jsonb_array_elements(public.airvalet_guest_search('5557301', 10, 0) -> 'rows')), 'phone, partial digits');
select pg_temp.check((select r ->> 'name' = 'PHILIP STEUBE' from jsonb_array_elements(public.airvalet_guest_search('GT-3', 10, 0) -> 'rows') r where r ->> 'last_ticket' like 'GT-%' limit 1), 'ticket number → its guest');
select pg_temp.check((select count(*) = 1 from jsonb_array_elements(public.airvalet_guest_search('rhett infinger', 10, 0) -> 'rows')), 'first + last name');
select pg_temp.check((select count(*) = 0 from jsonb_array_elements(public.airvalet_guest_search('nobody zzz', 10, 0) -> 'rows')), 'no match → empty list');
select pg_temp.check((select (s ->> 'has_more')::boolean and jsonb_array_length(s -> 'rows') = 2 from (select public.airvalet_guest_search('GT-', 2, 0) s) x), 'paging: 2 rows + has_more');
select pg_temp.check((select jsonb_array_length(public.airvalet_guest_search('', 500, 0) -> 'rows') <= 50), 'page size capped at 50');
select pg_temp.check((select jsonb_array_length(public.airvalet_guest_search(repeat('a', 81), 10, 0) -> 'rows') = 0), 'over-long query refused');
select pg_temp.check((select r ->> 'last_visit' = '2026-10-01' and r ->> 'first_visit' = '2026-08-01' from jsonb_array_elements(public.airvalet_guest_search('steub', 10, 0) -> 'rows') r),
  'first / last visit');

-- ── 4. Profile ────────────────────────────────────────────────────────────
update t_k set k = pg_temp.gk(981004);
select pg_temp.check((select (x ->> 'visits_count')::int = 2 and (x ->> 'total_days')::int = 7 and (x ->> 'avg_days')::numeric = 3.5 and (x ->> 'known_stays')::int = 2
                        and x -> 'names' @> '["PHILIP STEUB","PHILIP STEUBE"]' and x -> 'vehicles' -> 0 ->> 'vehicle' = 'Gray Audi Q7'
                        from (select public.airvalet_guest_profile(k) x from t_k) y), 'profile: 2 visits, 4 + 3 days, avg 3.5, both spellings, vehicle');
select pg_temp.check((select v ->> 'return_original' = '10/3/2026' and v ->> 'return_now' = '10/4/2026' and v -> 'return_changes' -> 0 ->> 'reason' = 'Flight moved'
                        and (v ->> 'cash_cents')::int = 2000 and v ->> 'hangar' = 'HANGAR 16' and v ->> 'delivery_type' = 'LOCKBOX'
                        from (select jsonb_array_elements(public.airvalet_guest_profile(k) -> 'visits') v from t_k) y where v ->> 'ticket' = 'GT-4'),
  'visit: original vs current return, change reason, cash tip, hangar it was in, delivery type');
select pg_temp.check((select (x -> 'tips' ->> 'cash_total')::int = 2000 and (x -> 'tips' ->> 'stripe_total')::int = 1000 and jsonb_array_length(x -> 'tips' -> 'stripe') = 2
                        from (select public.airvalet_guest_profile(k) x from t_k) y), 'tips: cash $20 + Stripe $10 confirmed (refunded listed, not counted)');
select pg_temp.check((select v ->> 'tip_received' is null and (select v2 ->> 'tip_received' from jsonb_array_elements(public.airvalet_guest_profile(pg_temp.gk(981002)) -> 'visits') v2) = 'false'
                        from (select jsonb_array_elements(public.airvalet_guest_profile(k) -> 'visits') v from t_k) y where v ->> 'ticket' = 'GT-3'),
  'no record (null) kept apart from "No" (false)');
select pg_temp.check((select (x ->> 'known_stays')::int = 1 and (x ->> 'visits_count')::int = 2
                        from (select public.airvalet_guest_profile(pg_temp.gk(981007)) x) y),
  'unknown delivery date: not counted in the stay average (never guessed)');
select pg_temp.check((select (v ->> 'stay_days')::int = 5 and v ->> 'checkin' = '2025-06-04' from jsonb_array_elements(public.airvalet_guest_profile(pg_temp.gk(981001)) -> 'visits') v),
  'legacy M/D/YYYY dates read (6/4 → 6/9 = 5 days)');
select pg_temp.check((select public.airvalet_guest_profile('ph:9999999999:NOBODY') ->> 'result') = 'NOT_FOUND', 'unknown guest → NOT_FOUND');
select pg_temp.check((select exists (select 1 from jsonb_array_elements(public.airvalet_guest_profile(pg_temp.gk(981006)) -> 'suggestions') s
                                       where s ->> 'why' = 'SAME_PHONE_SIMILAR_NAME' and s ->> 'name' = 'DOANALD RIEDEL')), 'suggestion: DONALD ↔ DOANALD RIEDEL (same phone, similar name)');
select pg_temp.check((select exists (select 1 from jsonb_array_elements(public.airvalet_guest_profile(pg_temp.gk(981013)) -> 'suggestions') s
                                       where s ->> 'why' = 'SAME_NAME_OTHER_PHONE')), 'suggestion: same name on another phone');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(public.airvalet_guest_profile(pg_temp.gk(981001)) -> 'suggestions') s
                                           where s ->> 'name' = 'RHETT INFINGER')), 'family member (other first name, other initial) is NOT suggested');

-- ── 5. Activity ───────────────────────────────────────────────────────────
select pg_temp.check((select bool_or(e ->> 'kind' = 'CHECK_IN') and bool_or(e ->> 'kind' = 'RETURN_CHANGE' and e ->> 'source' = 'staff') and bool_or(e ->> 'kind' = 'CAR_WASH' and e ->> 'source' = 'guest')
                             and bool_or(e ->> 'kind' = 'TIP' and e ->> 'label' like 'Stripe gratuity confirmed%') and bool_or(e ->> 'kind' = 'NOTE' and (e ->> 'issue')::boolean and not (e ->> 'time_known')::boolean)
                        from (select jsonb_array_elements(public.airvalet_guest_activity(k) -> 'events') e from t_k) y),
  'timeline: check-in, staff return change, guest car-wash request, Stripe tip, ticket note flagged battery (time unknown)');
select pg_temp.check((select public.airvalet_guest_activity(k)::text !~* 'lockbox_code' from t_k), 'timeline never carries a lockbox code');
select pg_temp.check((select bool_or(e ->> 'kind' = 'DELIVERED' and not (e ->> 'time_known')::boolean)
                        from (select jsonb_array_elements(public.airvalet_guest_activity(pg_temp.gk(981001)) -> 'events') e) y),
  'legacy delivery known only by day → marked time unknown');

-- ── 6. Notes ──────────────────────────────────────────────────────────────
select pg_temp.check((select public.airvalet_guest_note_save(k, null, 'Prefers the car facing out', '11111111-0000-0000-0000-000000000001') ->> 'result' from t_k) = 'OK', 'note added');
select pg_temp.check((select public.airvalet_guest_note_save(k, null, 'Prefers the car facing out', '11111111-0000-0000-0000-000000000001') ->> 'duplicate' from t_k) = 'true', 'same tap again → one note');
select pg_temp.check((select public.airvalet_guest_note_save(k, null, '   ', gen_random_uuid()) ->> 'result' from t_k) = 'INVALID', 'empty note refused');
select pg_temp.check(public.airvalet_guest_note_save(null, (select id from public.airvalet_guest_notes where body like 'Prefers%'), 'Prefers the car facing out, keys in hand', gen_random_uuid()) ->> 'result' = 'OK', 'note edited');
select pg_temp.check((select jsonb_array_length(n -> 'revisions') = 2 and n ->> 'updated_by' = 'localipad@airvalet.local' and n ->> 'created_by' = 'localipad@airvalet.local'
                        from (select jsonb_array_elements(public.airvalet_guest_profile(k) -> 'notes') n from t_k) y), 'note shows author, editor and its 2 revisions');
select pg_temp.check(public.airvalet_guest_note_delete((select id from public.airvalet_guest_notes where body like 'Prefers%'), gen_random_uuid()) ->> 'result' = 'OK', 'note deleted');
select pg_temp.check((select jsonb_array_length(public.airvalet_guest_profile(k) -> 'notes') = 0 from t_k)
  and (select count(*) = 3 from public.airvalet_guest_note_revisions r join public.airvalet_guest_notes n on n.id = r.note_id where n.body like 'Prefers%'), 'deleted note hidden but kept with its history');
select pg_temp.check(pg_temp.errs($q$ insert into public.airvalet_guest_notes (guest_key, body, created_by) values ('x', 'y', 'z') $q$), 'direct note insert refused');

-- ── 7. Identity decisions ─────────────────────────────────────────────────
select pg_temp.check(pg_temp.errs($q$ select public.airvalet_guest_merge(pg_temp.gk(981005), pg_temp.gk(981006), 'same person', gen_random_uuid()) $q$),
  'staff device (IPAD_OPS) cannot merge guests');
select pg_temp.act('localmanager');
select public.airvalet_guest_note_save(pg_temp.gk(981005), null, 'Note on the typo guest', gen_random_uuid());
select pg_temp.check(public.airvalet_guest_merge(pg_temp.gk(981005), pg_temp.gk(981006), '', gen_random_uuid()) ->> 'result' = 'REASON_REQUIRED', 'merge needs a reason');
select pg_temp.check(public.airvalet_guest_merge(pg_temp.gk(981005), pg_temp.gk(981006), 'Typo at check-in, same phone and car', '22222222-0000-0000-0000-000000000001') ->> 'result' = 'OK', 'manager merges DOANALD into DONALD');
select pg_temp.check((select (x ->> 'visits_count')::int = 2 and jsonb_array_length(x -> 'notes') = 1 and x -> 'identity' -> 0 ->> 'by' = 'localmanager@airvalet.local'
                        from (select public.airvalet_guest_profile(pg_temp.gk(981006)) x) y),
  'merged: 2 visits, the merged guest''s note follows, decision shows who');
select pg_temp.check((pg_temp.ng(array[981005, 981006]) = 1), 'both tickets now resolve to one guest');
select pg_temp.check(public.airvalet_guest_identity_undo((select id from public.airvalet_guest_identity where client_key = '22222222-0000-0000-0000-000000000001'), 'Checked: different people') ->> 'result' = 'OK', 'merge undone (reason)');
select pg_temp.check((pg_temp.ng(array[981005, 981006]) = 2)
  and (select revoked_by = 'localmanager@airvalet.local' from public.airvalet_guest_identity where client_key = '22222222-0000-0000-0000-000000000001'), 'after undo: two guests again, decision kept with who undid it');
select pg_temp.check(public.airvalet_guest_move_ticket(981003, null, 'Different Philip, same phone', gen_random_uuid()) ->> 'result' = 'OK', 'ticket GT-3 moved to a guest of its own');
select pg_temp.check((pg_temp.ng(array[981003, 981004]) = 2), 'split: STEUB and STEUBE now two guests');
select pg_temp.check(public.airvalet_guest_move_ticket(981003, pg_temp.gk(981004), 'Back: same Philip', gen_random_uuid()) ->> 'result' = 'OK', 'ticket moved back to STEUBE');
select pg_temp.check(pg_temp.ng(array[981003, 981004]) = 1, 'moved back: one guest again');
select pg_temp.check((select count(*) from public.airvalet_guest_identity where passenger_id = 981003) = 2
                 and (select count(*) from public.airvalet_guest_identity where passenger_id = 981003 and revoked_at is null) = 1, 'both decisions kept (the first one revoked)');
select pg_temp.check(public.airvalet_guest_merge('ph:9999999999:NOBODY', pg_temp.gk(981006), 'x x x', gen_random_uuid()) ->> 'result' = 'NOT_FOUND', 'merge with an unknown guest refused');

-- ── 8. Check-in lookup + ticket → guest ───────────────────────────────────
select pg_temp.act('localipad');
select pg_temp.check((select jsonb_array_length(x -> 'guests') = 2 and x::text !~* '(ret|return|consent|sms)' and x -> 'guests' -> 0 ->> 'car' is not null
                        from (select public.airvalet_guest_lookup_phone('305 555 7301') x) y), 'check-in lookup: shared phone lists both people, car only — no return date, no consent');
select pg_temp.check((select jsonb_array_length(public.airvalet_guest_lookup_phone('0000000000') -> 'guests') = 0), 'placeholder phone → no lookup');
select pg_temp.check((select (x ->> 'visits')::int = 2 from (select public.airvalet_guest_for_passenger(981003) x) y), 'ticket → guest key and visit count');

-- ── 9. Nothing outside the guest tables changed ──────────────────────────
reset role;
select pg_temp.check((select md5(string_agg(p::text, '|' order by p.id)) from public.passengers p where p.id between 981001 and 981014) = (select h from t_before), 'tickets untouched by search, notes, merges and moves');
select pg_temp.check((select md5(pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure))) = '38c00516d1971a855a04b5d68ad63b45', 'Valet Pass view unchanged (v86 definition)');

select 'all 1114 checks passed';
