-- LOCAL release tests for the Return/Pickup deploy (migrations
-- 20261010_add_passenger_return_operator + 20261010_tv_mode_rpc_return_operator
-- ONLY — no SMS/Twilio objects exist in this database). Rolled back at the end.
\set ON_ERROR_STOP 1
begin;
create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.f(p_id bigint) returns text language sql as $$
  select coalesce(return_operator, 'NULL') || '/customs=' || coalesce(delivery_at_customs, false) || '/otherboat=' || coalesce(not_returning_with_makers_air, false)
         || '/pickup=' || coalesce(public.airvalet_pickup_location(return_operator, delivery_at_customs), '-')
    from public.passengers where id = p_id $$;

select pg_temp.check(to_regclass('public.airvalet_sms_messages') is null and to_regprocedure('public.airvalet_sms_require_ops()') is null, 'no SMS/Twilio objects in this release database');

-- Backfill of passengers in custody (prod mix)
select pg_temp.check(pg_temp.f(8001) = 'MAKERS/customs=false/otherboat=false/pickup=HANGAR_19', 'backfill Makers ticket → MAKERS → Hangar 19');
select pg_temp.check(pg_temp.f(8002) = 'MAKERS/customs=false/otherboat=false/pickup=HANGAR_19', 'backfill NO DATE Makers → MAKERS');
select pg_temp.check(pg_temp.f(8003) = 'MAKERS/customs=true/otherboat=false/pickup=CUSTOMS', 'backfill Makers + Delivery at Customs → MAKERS + approved exception → Customs');
select pg_temp.check(pg_temp.f(8004) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'backfill Ascend ticket → ASCEND → Customs');
select pg_temp.check(pg_temp.f(8005) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'backfill Ascend + old Customs flag → ASCEND, flag cleared, pickup still Customs');
select pg_temp.check(pg_temp.f(8006) = 'OTHER/customs=false/otherboat=true/pickup=-', 'backfill Other Boat → OTHER (manual)');
select pg_temp.check((select place from public.airvalet_return_instructions where passenger_id = 8007 and source = 'legacy_welcome_back') = 'HANGAR_19', 'Welcome Back already sent → instruction snapshot captured (Hangar 19)');
select pg_temp.check((select count(*) from public.airvalet_return_reviews) = 0, 'no Needs Review right after the migration');
select pg_temp.check((select count(*) from public.passengers p join public._release_hist_fp h using (id) where md5((to_jsonb(p) - 'return_operator' - 'customs_exception_requested_at')::text) <> h.fp) = 0
  and (select count(*) from public.passengers where status in ('DELIVERED','ARCHIVED') and (return_operator is not null or customs_exception_requested_at is not null)) = 0,
  'DELIVERED / ARCHIVED rows identical (md5 of all pre-existing columns) and without return_operator');
select pg_temp.check(exists (select 1 from pg_constraint where conname = 'passengers_return_flags_consistent' and convalidated), 'CHECK backstop present and validated');

-- OLD app (v45, before "Returning with") keeps working after the migration
update public.passengers set not_returning_with_makers_air = true where id = 8001;
select pg_temp.check(pg_temp.f(8001) = 'OTHER/customs=false/otherboat=true/pickup=-', 'old app ticks "Other Boat" → OTHER (not silently undone)');
update public.passengers set not_returning_with_makers_air = false where id = 8001;
select pg_temp.check(pg_temp.f(8001) = 'MAKERS/customs=false/otherboat=false/pickup=HANGAR_19', 'old app unticks "Other Boat" → back to the departure operator (Makers)');
update public.passengers set not_returning_with_makers_air = false where id = 8004;
update public.passengers set not_returning_with_makers_air = true where id = 8004;
update public.passengers set not_returning_with_makers_air = false where id = 8004;
select pg_temp.check(pg_temp.f(8004) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'old app Other Boat on/off on an Ascend ticket → back to ASCEND');
update public.passengers set delivery_at_customs = true where id = 8002;
select pg_temp.check(pg_temp.f(8002) = 'MAKERS/customs=true/otherboat=false/pickup=CUSTOMS', 'old app ticks "Delivery at Customs" on Makers → approved exception');
update public.passengers set delivery_at_customs = false where id = 8002;
select pg_temp.check(pg_temp.f(8002) = 'MAKERS/customs=false/otherboat=false/pickup=HANGAR_19', 'old app unticks it → Hangar 19');
update public.passengers set delivery_at_customs = true where id = 8004;
select pg_temp.check(pg_temp.f(8004) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'old app Customs flag on an Ascend return stays false (pickup Customs anyway)');
update public.passengers set loc = 'HANGAR 19', obs = 'X', status = 'PENDING' where id = 8003;
select pg_temp.check(pg_temp.f(8003) = 'MAKERS/customs=true/otherboat=false/pickup=CUSTOMS', 'old app unrelated edit keeps the exception');
insert into public.passengers (id, name, phone, ticket, status, not_returning_with_makers_air, delivery_at_customs) values
  (8201, 'OLD INS 1', '3055558201', '1010-1', 'PENDING', false, false),
  (8202, 'OLD INS 2', '3055558202', 'A-1010-2', 'PENDING', false, false),
  (8203, 'OLD INS 3', '3055558203', '1010-3', 'PENDING', true, false),
  (8204, 'OLD INS 4', '3055558204', '1010-4', 'PENDING', false, true);
select pg_temp.check(pg_temp.f(8201) = 'MAKERS/customs=false/otherboat=false/pickup=HANGAR_19' and pg_temp.f(8202) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS'
  and pg_temp.f(8203) = 'OTHER/customs=false/otherboat=true/pickup=-' and pg_temp.f(8204) = 'MAKERS/customs=true/otherboat=false/pickup=CUSTOMS', 'old app check-ins (incl. offline replay) → correct Returning with');

-- NEW app writes
update public.passengers set return_operator = 'ASCEND' where id = 8001;
select pg_temp.check(pg_temp.f(8001) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'new app Makers → Ascend');
update public.passengers set return_operator = 'MAKERS' where id = 8001;
select pg_temp.check(pg_temp.f(8001) = 'MAKERS/customs=false/otherboat=false/pickup=HANGAR_19', 'new app Ascend → Makers (Hangar 19, never an automatic exception)');
update public.passengers set return_operator = 'OTHER' where id = 8001;
select pg_temp.check(pg_temp.f(8001) = 'OTHER/customs=false/otherboat=true/pickup=-', 'new app → Other (manual)');
insert into public.passengers (id, name, phone, ticket, status, return_operator, not_returning_with_makers_air, delivery_at_customs) values (8205, 'NEW INS', '3055558205', 'A-1010-5', 'PENDING', 'MAKERS', false, false);
select pg_temp.check(pg_temp.f(8205) = 'MAKERS/customs=false/otherboat=false/pickup=HANGAR_19', 'new app check-in: Ascend flight out, Makers return → Hangar 19');
update public.passengers set loc = 'CUSTOMS' where id = 8205;
select pg_temp.check((select loc from public.passengers where id = 8205) = 'CUSTOMS' and pg_temp.f(8205) = 'MAKERS/customs=false/otherboat=false/pickup=HANGAR_19', 'loc = CUSTOMS is accepted and never changes the return model');
do $$ begin
  update public.passengers set return_operator = 'BOAT' where id = 8205;
  raise exception 'FAIL: invalid return_operator accepted';
exception when check_violation then raise notice 'ok  invalid return_operator rejected';
end $$;

-- Ambiguity: an explicit NEW-app choice is never overwritten by an old-app
-- (v45) save that does not really change "Other Boat". v45 saveEdits() only
-- sends the fields that changed; a stale cached value equal to the stored
-- one is not a change, so the trigger keeps Returning with.
insert into public.passengers (id, name, phone, ticket, status) values (8301, 'AMB ASC', '3055558301', '1011-1', 'PENDING'), (8302, 'AMB OTH', '3055558302', 'A-1011-2', 'PENDING');
update public.passengers set return_operator = 'ASCEND' where id = 8301;   -- new app: Makers ticket, returning with Ascend
select pg_temp.check(pg_temp.f(8301) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'amb 1  new app chose ASCEND');
update public.passengers set obs = 'OLD SAVE', loc = 'HANGAR 16', ret = '10/12/2026' where id = 8301;   -- v45 save, unrelated fields only
select pg_temp.check(pg_temp.f(8301) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'amb 2  v45 save of other fields → ASCEND kept (not MAKERS)');
update public.passengers set not_returning_with_makers_air = false where id = 8301;   -- v45 stale "Other Boat" unticked, same as stored
select pg_temp.check(pg_temp.f(8301) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'amb 3  v45 stale Other Boat=false (no real change) → ASCEND kept');
update public.passengers set not_returning_with_makers_air = false, delivery_at_customs = false, obs = 'OLD SAVE 2' where id = 8301;   -- v45 stale legacy payload
select pg_temp.check(pg_temp.f(8301) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'amb 4  v45 stale legacy flags payload → ASCEND kept');
update public.passengers set delivery_at_customs = true where id = 8301;   -- v45 ticks Customs on it
select pg_temp.check(pg_temp.f(8301) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'amb 5  v45 Customs flag on new-app ASCEND → ASCEND kept, flag normalized');
update public.passengers set return_operator = 'OTHER' where id = 8302;    -- new app: Ascend ticket, returning with Other
select pg_temp.check(pg_temp.f(8302) = 'OTHER/customs=false/otherboat=true/pickup=-', 'amb 6  new app chose OTHER');
update public.passengers set obs = 'OLD SAVE', loc = 'HANGAR 7' where id = 8302;
update public.passengers set not_returning_with_makers_air = true where id = 8302;    -- v45 stale tick, same as stored
update public.passengers set delivery_at_customs = false, not_returning_with_makers_air = true where id = 8302;
select pg_temp.check(pg_temp.f(8302) = 'OTHER/customs=false/otherboat=true/pickup=-', 'amb 7  v45 saves without a real Other Boat change → OTHER kept (not ASCEND)');
update public.passengers set return_operator = 'ASCEND', not_returning_with_makers_air = true where id = 8302;   -- return change + stale legacy flag in one write
select pg_temp.check(pg_temp.f(8302) = 'ASCEND/customs=false/otherboat=false/pickup=CUSTOMS', 'amb 8  Returning with changed + stale Other Boat in the same write → explicit return wins');

-- Needs Review works without any SMS table
update public.passengers set return_operator = 'ASCEND' where id = 8007;
select pg_temp.check((select instructions_place = 'HANGAR_19' and current_place = 'CUSTOMS' and instructions_source = 'legacy_ios' from public.airvalet_return_reviews where passenger_id = 8007), 'return changed after Welcome Back → Needs Review (legacy source only)');
insert into public.user_profiles (id, username, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin', 'ADMIN'), ('00000000-0000-0000-0000-0000000000b1', 'tv', 'TV_ONLY');
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
do $$ begin
  perform public.airvalet_return_review_ack(8007, 'NO_UPDATE_NEEDED');
  raise exception 'FAIL: TV_ONLY can acknowledge';
exception when insufficient_privilege then raise notice 'ok  TV_ONLY cannot acknowledge (inline ops check, no SMS helper)';
end $$;
select pg_temp.check((select count(*) from public.airvalet_return_reviews) = 0, 'TV_ONLY sees no reviews');
select pg_temp.check((select count(*) from public.get_tv_mode_passengers() where id = 8007 and return_operator = 'ASCEND') = 1, 'TV RPC returns return_operator (TV_ONLY)');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 8007) = 1, 'ADMIN sees the review');
select public.airvalet_return_review_ack(8007, 'NO_UPDATE_NEEDED');
select pg_temp.check((select count(*) from public.airvalet_return_reviews where passenger_id = 8007) = 0, 'ADMIN ack → leaves Needs Review');
reset role;
set local role anon;
do $$ begin
  perform public.airvalet_return_review_ack(8007, 'NO_UPDATE_NEEDED');
  raise exception 'FAIL: anon can acknowledge';
exception when insufficient_privilege then raise notice 'ok  anon cannot call the ack RPC';
end $$;
reset role;
select pg_temp.check((select count(*) from public.passengers where return_operator is not null
   and not (coalesce(not_returning_with_makers_air, false) = (return_operator = 'OTHER') and (not delivery_at_customs or return_operator = 'MAKERS'))) = 0,
  'invariant: no row with flags contradicting Returning with');
rollback;
\echo RELEASE_TESTS_PASSED
