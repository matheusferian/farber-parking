-- Event Valet SQL tests. Runs inside one transaction and ROLLS BACK.
-- Usage: psql -v ON_ERROR_STOP=1 -v ipad=<uuid> -v tv=<uuid> -f sql_tests.sql
\set QUIET on
\pset tuples_only off
begin;

create temp table _r (n serial, name text, ok boolean, info text);
grant all on _r to anon, authenticated, service_role;
grant usage on sequence _r_n_seq to anon, authenticated, service_role;

-- ── as IPAD_OPS ──────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'ipad', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true) \gset _x_
set local role authenticated;

do $$
declare r jsonb; t1 uuid; t2 uuid; t3 uuid; e text; i int;
begin
  -- 1-3 check-in, sequence, first free slot, normalization
  r := public.event_valet_checkin('makers-halloween-2026', '(954) 555-0101', ' honda   civic ', 'k1');
  insert into _r(name, ok, info) values ('checkin #1 created', (r->>'created')::boolean, r::text);
  insert into _r(name, ok, info) values ('ticket_no = 1', (r#>>'{ticket,ticket_no}')::int = 1, r#>>'{ticket,ticket_no}');
  insert into _r(name, ok, info) values ('slot = 1', (r#>>'{ticket,slot_no}')::int = 1, r#>>'{ticket,slot_no}');
  insert into _r(name, ok, info) values ('phone E.164', r#>>'{ticket,phone_e164}' = '+19545550101', r#>>'{ticket,phone_e164}');
  insert into _r(name, ok, info) values ('vehicle upper/trim', r#>>'{ticket,vehicle}' = 'HONDA CIVIC', r#>>'{ticket,vehicle}');
  insert into _r(name, ok, info) values ('status PARKED', r#>>'{ticket,status}' = 'PARKED', r#>>'{ticket,status}');
  insert into _r(name, ok, info) values ('ticket code = last 4 of phone', r#>>'{ticket,ticket_code}' = '0101', r#>>'{ticket,ticket_code}');
  t1 := (r#>>'{ticket,id}')::uuid;

  -- double tap: same client key → same ticket, no new number
  r := public.event_valet_checkin('makers-halloween-2026', '9545550101', 'HONDA CIVIC', 'k1');
  insert into _r(name, ok, info) values ('double tap returns same ticket', not (r->>'created')::boolean and (r#>>'{ticket,id}')::uuid = t1, r::text);

  r := public.event_valet_checkin('makers-halloween-2026', '+1 954 555 0102', 'Tesla', 'k2');
  t2 := (r#>>'{ticket,id}')::uuid;
  insert into _r(name, ok, info) values ('ticket #2 slot 2', (r#>>'{ticket,ticket_no}')::int = 2 and (r#>>'{ticket,slot_no}')::int = 2, r::text);

  -- invalid inputs
  begin perform public.event_valet_checkin('makers-halloween-2026', '123', 'BMW', null);
        insert into _r(name, ok) values ('invalid phone rejected', false);
  exception when others then insert into _r(name, ok, info) values ('invalid phone rejected', sqlerrm = 'INVALID_PHONE', sqlerrm); end;
  begin perform public.event_valet_checkin('makers-halloween-2026', '(154) 555-0101', 'BMW', null);
        insert into _r(name, ok) values ('NANP area 1xx rejected', false);
  exception when others then insert into _r(name, ok, info) values ('NANP area 1xx rejected', sqlerrm = 'INVALID_PHONE', sqlerrm); end;
  begin perform public.event_valet_checkin('makers-halloween-2026', '9545550199', '   ', null);
        insert into _r(name, ok) values ('empty vehicle rejected', false);
  exception when others then insert into _r(name, ok, info) values ('empty vehicle rejected', sqlerrm = 'INVALID_VEHICLE', sqlerrm); end;

  -- request → ready → delivered frees slot 1; next check-in reuses slot 1, new number 3
  r := public.event_valet_set_status(t1, 'REQUESTED');
  insert into _r(name, ok, info) values ('PARKED→REQUESTED', (r->>'changed')::boolean and r#>>'{ticket,status}' = 'REQUESTED', r::text);
  r := public.event_valet_set_status(t1, 'REQUESTED');
  insert into _r(name, ok, info) values ('REQUESTED again is a no-op', not (r->>'changed')::boolean, r::text);
  r := public.event_valet_set_status(t1, 'READY');
  insert into _r(name, ok, info) values ('→READY', r#>>'{ticket,status}' = 'READY', r::text);
  r := public.event_valet_set_status(t1, 'DELIVERED');
  insert into _r(name, ok, info) values ('→DELIVERED changed', (r->>'changed')::boolean and r#>>'{ticket,delivered_at}' is not null, r::text);
  r := public.event_valet_set_status(t1, 'DELIVERED');
  insert into _r(name, ok, info) values ('DELIVERED twice is a no-op (no 2nd tip SMS trigger)', not (r->>'changed')::boolean, r::text);

  r := public.event_valet_checkin('makers-halloween-2026', '9545550103', 'Camry', 'k3');
  t3 := (r#>>'{ticket,id}')::uuid;
  insert into _r(name, ok, info) values ('ticket #3 reuses freed slot 1', (r#>>'{ticket,ticket_no}')::int = 3 and (r#>>'{ticket,slot_no}')::int = 1, r::text);
  -- same last 4 again (other phone, and returning guest after delivery) → -B, -C; never reused
  r := public.event_valet_checkin('makers-halloween-2026', '3055550101', 'Audi', 'k3b');
  insert into _r(name, ok, info) values ('same last 4, other phone → 10101', r#>>'{ticket,ticket_code}' = '10101', r::text);
  perform public.event_valet_set_status((r#>>'{ticket,id}')::uuid, 'DELIVERED');
  r := public.event_valet_checkin('makers-halloween-2026', '9545550101', 'Honda Civic', 'k3c');
  insert into _r(name, ok, info) values ('returning guest → 20101 (codes never reused)', r#>>'{ticket,ticket_code}' = '20101', r::text);
  perform public.event_valet_set_status((r#>>'{ticket,id}')::uuid, 'DELIVERED');

  -- undo delivered when its slot was reused → READY without slot
  r := public.event_valet_set_status(t1, 'READY');
  insert into _r(name, ok, info) values ('undo DELIVERED → READY, slot cleared (reused)', r#>>'{ticket,status}' = 'READY' and r#>>'{ticket,slot_no}' is null, r::text);
  begin perform public.event_valet_set_status(t1, 'PARKED');
        insert into _r(name, ok, info) values ('READY→PARKED allowed', true, null);
  exception when others then insert into _r(name, ok, info) values ('READY→PARKED allowed', false, sqlerrm); end;

  -- manual slot change: occupied rejected, invalid rejected, free accepted + audited
  begin perform public.event_valet_set_slot(t1, 2);
        insert into _r(name, ok) values ('slot occupied rejected', false);
  exception when others then insert into _r(name, ok, info) values ('slot occupied rejected', sqlerrm = 'SLOT_OCCUPIED', sqlerrm); end;
  begin perform public.event_valet_set_slot(t1, 21);
        insert into _r(name, ok) values ('slot > capacity rejected', false);
  exception when others then insert into _r(name, ok, info) values ('slot > capacity rejected', sqlerrm = 'INVALID_SLOT', sqlerrm); end;
  r := public.event_valet_set_slot(t1, 7);
  insert into _r(name, ok, info) values ('slot 7 assigned', (r#>>'{ticket,slot_no}')::int = 7, r::text);

  -- print bookkeeping: reprint never changes number/slot
  r := public.event_valet_mark_printed(t2, 'AUTO');
  r := public.event_valet_mark_printed(t2, 'REPRINT');
  insert into _r(name, ok, info) values ('reprint keeps number+slot, count 2',
    (r#>>'{ticket,print_count}')::int = 2 and (r#>>'{ticket,ticket_no}')::int = 2 and (r#>>'{ticket,slot_no}')::int = 2, r::text);

  -- board
  r := public.event_valet_board('makers-halloween-2026');
  insert into _r(name, ok, info) values ('board counts', (r#>>'{counts,PARKED}')::int = 3 and jsonb_array_length(r->'tickets') = 5, r->>'counts');
  insert into _r(name, ok, info) values ('board has no token hash', position('guest_token' in r::text) = 0, null);

  -- fill all 20 slots → 21st gets slot NULL + slots_full
  for i in 1..17 loop
    perform public.event_valet_checkin('makers-halloween-2026', '954555' || lpad((200 + i)::text, 4, '0'), 'CAR ' || i, 'fill' || i);
  end loop;
  r := public.event_valet_checkin('makers-halloween-2026', '9545550300', 'OVERFLOW', 'fill-x');
  insert into _r(name, ok, info) values ('21st car: slots_full, slot NULL, still gets ticket',
    (r->>'slots_full')::boolean and r#>>'{ticket,slot_no}' is null and (r#>>'{ticket,ticket_no}')::int = 23, r::text);

  -- internal functions are not callable by staff directly
  begin perform public.event_valet_apply_status(t2, 'DELIVERED', 'SMS');
        insert into _r(name, ok) values ('apply_status not executable by authenticated', false);
  exception when insufficient_privilege then insert into _r(name, ok) values ('apply_status not executable by authenticated', true); end;
  begin perform public.event_valet_guest('x', 'view');
        insert into _r(name, ok) values ('guest fn not executable by authenticated', false);
  exception when insufficient_privilege then insert into _r(name, ok) values ('guest fn not executable by authenticated', true); end;
  begin perform 1 from public.event_valet_tickets limit 1;
        insert into _r(name, ok) values ('table not readable by authenticated', false);
  exception when insufficient_privilege then insert into _r(name, ok) values ('table not readable by authenticated', true); end;
end $$;

reset role;

-- ── as TV_ONLY: denied ───────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'tv', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true) \gset _x_
set local role authenticated;
do $$ begin
  begin perform public.event_valet_board('makers-halloween-2026');
        insert into _r(name, ok) values ('TV_ONLY denied board', false);
  exception when others then insert into _r(name, ok, info) values ('TV_ONLY denied board', sqlerrm = 'NOT_AUTHORIZED', sqlerrm); end;
  begin perform public.event_valet_checkin('makers-halloween-2026', '9545550111', 'BMW', null);
        insert into _r(name, ok) values ('TV_ONLY denied checkin', false);
  exception when others then insert into _r(name, ok, info) values ('TV_ONLY denied checkin', sqlerrm = 'NOT_AUTHORIZED', sqlerrm); end;
end $$;
reset role;

-- ── as anon: nothing executable ──────────────────────────────────────
set local role anon;
do $$ begin
  begin perform public.event_valet_board('makers-halloween-2026');
        insert into _r(name, ok) values ('anon denied board', false);
  exception when insufficient_privilege then insert into _r(name, ok) values ('anon denied board', true); end;
end $$;
reset role;

-- ── as service_role: guest link + inbound READY ──────────────────────
set local role service_role;
do $$
declare t2 uuid; tok text; tok2 text; r jsonb; t_multi1 uuid;
begin
  select id into t2 from public.event_valet_tickets where event_id = 'makers-halloween-2026' and ticket_no = 2;
  tok := public.event_valet_mint_guest_token(t2);
  r := public.event_valet_guest(tok, 'view');
  insert into _r(name, ok, info) values ('guest view ok, no slot/phone',
    r->>'state' = 'ok' and (r->>'ticket_no')::int = 2 and not (r ? 'slot_no') and not (r ? 'phone_e164'), r::text);
  r := public.event_valet_guest(repeat('0', 64), 'view');
  insert into _r(name, ok, info) values ('guest wrong token invalid', r->>'state' = 'invalid', r::text);
  r := public.event_valet_guest('../etc', 'view');
  insert into _r(name, ok, info) values ('guest malformed token invalid', r->>'state' = 'invalid', r::text);
  tok2 := public.event_valet_mint_guest_token(t2);
  r := public.event_valet_guest(tok, 'view');
  insert into _r(name, ok, info) values ('rotated token kills old link', r->>'state' = 'invalid', r::text);
  r := public.event_valet_guest(tok2, 'request');
  insert into _r(name, ok, info) values ('guest request PARKED→REQUESTED', (r->>'changed')::boolean and r->>'status' = 'REQUESTED', r::text);
  r := public.event_valet_guest(tok2, 'request');
  insert into _r(name, ok, info) values ('guest request twice no-op', not (r->>'changed')::boolean, r::text);

  -- inbound READY: single active ticket (#3, +19545550103)
  r := public.event_valet_inbound_ready('+19545550103', null);
  insert into _r(name, ok, info) values ('SMS READY requests the one active ticket', r->>'result' = 'REQUESTED' and r#>>'{ticket,ticket_code}' = '0103', r::text);
  r := public.event_valet_inbound_ready('+19545550103', null);
  insert into _r(name, ok, info) values ('SMS READY duplicate → ALREADY', r->>'result' = 'ALREADY', r::text);
  r := public.event_valet_inbound_ready('+19545559999', null);
  insert into _r(name, ok, info) values ('unknown phone → NONE', r->>'result' = 'NONE', r::text);

  -- two cars on the same phone → AMBIGUOUS; with number → that ticket only
  insert into public.event_valet_tickets (event_id, ticket_no, ticket_code, slot_no, phone_e164, vehicle)
    values ('makers-halloween-2026', 50, '0500', null, '+19545550500', 'BMW'), ('makers-halloween-2026', 51, '10500', null, '+19545550500', 'AUDI');
  r := public.event_valet_inbound_ready('+19545550500', null);
  insert into _r(name, ok, info) values ('two cars same phone → AMBIGUOUS + options', r->>'result' = 'AMBIGUOUS'
    and r->'options' = '[{"code":"0500","vehicle":"BMW"},{"code":"10500","vehicle":"AUDI"}]'::jsonb, r::text);
  r := public.event_valet_inbound_ready('+19545550500', '0102');
  insert into _r(name, ok, info) values ('other person''s ticket code → NO_MATCH', r->>'result' = 'NO_MATCH', r::text);
  r := public.event_valet_inbound_ready('+19545550500', '10500');
  insert into _r(name, ok, info) values ('READY 10500 requests only 10500', r->>'result' = 'REQUESTED' and r#>>'{ticket,ticket_code}' = '10500', r::text);
  insert into _r(name, ok, info) values ('#50 untouched', (select status from public.event_valet_tickets where ticket_no = 50) = 'PARKED', null);

  -- delivered-only phone → DELIVERED (never re-requests)
  update public.event_valet_tickets set status = 'DELIVERED', delivered_at = now() where phone_e164 = '+19545550500';
  r := public.event_valet_inbound_ready('+19545550500', null);
  insert into _r(name, ok, info) values ('delivered phone → DELIVERED', r->>'result' = 'DELIVERED', r::text);

  -- closed event ignores inbound
  update public.event_valet_events set is_open = false where id = 'makers-halloween-2026';
  r := public.event_valet_inbound_ready('+19545550102', null);
  insert into _r(name, ok, info) values ('closed event → NONE', r->>'result' = 'NONE', r::text);
  update public.event_valet_events set is_open = true where id = 'makers-halloween-2026';
end $$;
reset role;

-- audit trail exists
insert into _r(name, ok, info)
select 'audit rows written', count(*) >= 10, count(*)::text from public.event_valet_audit;

-- isolation: no other table changed by this module (only event_valet_* written)
insert into _r(name, ok, info)
select 'no existing table references event_valet', count(*) = 0, string_agg(conrelid::regclass::text, ',')
  from pg_constraint where contype = 'f' and confrelid::regclass::text like 'event_valet%'
   and conrelid::regclass::text not like 'event_valet%';

\set QUIET off
select n, case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else coalesce(info,'') end as info from _r order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from _r;
rollback;
