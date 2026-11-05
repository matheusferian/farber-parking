-- Watermakers Valet (2026-11-11) SQL tests. One transaction, ROLLS BACK.
-- Usage: psql -v ON_ERROR_STOP=1 -v ipad=<uuid> -f sql_tests_watermakers.sql
\set QUIET on
begin;
create temp table _r (n serial, name text, ok boolean, info text);
grant all on _r to authenticated; grant usage on sequence _r_n_seq to authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ipad', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true) \gset _x_
set local role authenticated;
do $$
declare r jsonb; t1 uuid; th uuid; i int; e text; W text := 'watermakers-veterans-2026'; H text := 'makers-halloween-2026';
begin
  r := public.event_valet_checkin(W, '(954) 555-0101', 'Ford F-150', 'wk1');
  t1 := (r#>>'{ticket,id}')::uuid;
  insert into _r(name, ok, info) values ('W check-in created', (r->>'created')::boolean, r::text);
  insert into _r(name, ok, info) values ('W own numbering starts at 1', (r#>>'{ticket,ticket_no}')::int = 1, r#>>'{ticket,ticket_no}');
  insert into _r(name, ok, info) values ('W slot 1', (r#>>'{ticket,slot_no}')::int = 1, r#>>'{ticket,slot_no}');
  insert into _r(name, ok, info) values ('W code = last 4', r#>>'{ticket,ticket_code}' = '0101', r#>>'{ticket,ticket_code}');
  r := public.event_valet_checkin(H, '(954) 555-0101', 'BMW', 'hk1');
  th := (r#>>'{ticket,id}')::uuid;
  insert into _r(name, ok, info) values ('same phone in Halloween does not get -B code from W', r#>>'{ticket,event_id}' = H, r::text);

  r := public.event_valet_set_location(t1, 'FRONT');
  insert into _r(name, ok, info) values ('W FRONT accepted', r#>>'{ticket,parking_location}' = 'FRONT', r::text);
  r := public.event_valet_set_location(t1, 'BACK');
  insert into _r(name, ok, info) values ('W change to BACK', r#>>'{ticket,parking_location}' = 'BACK' and (r->>'changed')::boolean, r::text);
  begin perform public.event_valet_set_location(t1, 'HANGAR 19'); insert into _r(name, ok) values ('W rejects HANGAR 19', false);
  exception when others then insert into _r(name, ok, info) values ('W rejects HANGAR 19', sqlerrm = 'INVALID_LOCATION', sqlerrm); end;
  begin perform public.event_valet_set_location(th, 'FRONT'); insert into _r(name, ok) values ('Halloween rejects FRONT', false);
  exception when others then insert into _r(name, ok, info) values ('Halloween rejects FRONT', sqlerrm = 'INVALID_LOCATION', sqlerrm); end;
  r := public.event_valet_set_location(th, 'GRASS');
  insert into _r(name, ok, info) values ('Halloween still accepts GRASS', r#>>'{ticket,parking_location}' = 'GRASS', r::text);

  -- 50 slots (S710 change 2026-11-05): cars 2..50 get slots 2..50, the 51st has no slot
  for i in 2..50 loop perform public.event_valet_checkin(W, '95455502' || lpad(i::text, 2, '0'), 'CAR ' || i, 'wk' || i); end loop;
  r := public.event_valet_checkin(W, '9545550251', 'CAR 51', 'wk51');
  insert into _r(name, ok, info) values ('W 51st car: slots full', (r->>'slots_full')::boolean and r#>'{ticket,slot_no}' = 'null'::jsonb, r::text);

  -- offline sync keeps a valid location, drops a foreign one
  r := public.event_valet_checkin_offline(W, '9545550301', 'TESLA', 'wo1', '0301', null, 'SIDE', now(), true);
  insert into _r(name, ok, info) values ('W offline keeps SIDE', r#>>'{ticket,parking_location}' = 'SIDE', r::text);
  r := public.event_valet_checkin_offline(W, '9545550302', 'AUDI', 'wo2', '0302', null, 'GRASS', now(), true);
  insert into _r(name, ok, info) values ('W offline drops GRASS', r#>'{ticket,parking_location}' = 'null'::jsonb, r::text);
  r := public.event_valet_checkin_offline(H, '9545550303', 'KIA', 'ho1', '0303', null, 'FENCE', now(), true);
  insert into _r(name, ok, info) values ('Halloween offline keeps FENCE', r#>>'{ticket,parking_location}' = 'FENCE', r::text);

  r := public.event_valet_board(W);
  insert into _r(name, ok, info) values ('W board only W tickets', not exists (select 1 from jsonb_array_elements(coalesce(r->'tickets', r)) x where x->>'event_id' <> W), left(r::text, 120));
end $$;
reset role;
-- trigger guards direct writes too
do $$ begin
  update public.event_valet_tickets set parking_location = 'HANGAR 18' where event_id = 'watermakers-veterans-2026' and ticket_no = 1;
  insert into _r(name, ok) values ('trigger blocks foreign location on direct update', false);
exception when others then insert into _r(name, ok, info) values ('trigger blocks foreign location on direct update', sqlerrm = 'INVALID_LOCATION', sqlerrm); end $$;
insert into _r(name, ok, info) select 'W row: 50 slots, SMS off, test-only, tips off, pass link on, switches off',
  slot_capacity = 50 and not sms_enabled and sms_test_only and not tip_enabled and include_ticket_link and not staff_access_enabled and not sms_replies_enabled and not thanks_enabled and revenue_slug = 'watermakers-2026-11-11', row_to_json(e)::text
  from public.event_valet_events e where id = 'watermakers-veterans-2026';
select n, case when ok then 'PASS' else 'FAIL' end, name, case when ok then '' else coalesce(info,'') end from _r order by n;
select count(*) filter (where ok) || '/' || count(*) || ' passed' from _r;
rollback;
