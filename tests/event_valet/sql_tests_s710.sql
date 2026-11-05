-- Watermakers S710 staff API (event_valet_staff) + admin RPC tests. One transaction, ROLLS BACK.
-- Usage: psql -v ON_ERROR_STOP=1 -v admin=<uuid> -v ipad=<uuid> -f sql_tests_s710.sql
\set QUIET on
begin;
create temp table _r (n serial, name text, ok boolean, info text);
grant all on _r to public; grant usage on sequence _r_n_seq to public;
create temp table _v (k text primary key, v text);
grant all on _v to public;

-- fixtures (as postgres): clean Watermakers, switch staff access on, four credentials + one Halloween credential
delete from public.event_valet_messages where event_id = 'watermakers-veterans-2026';
delete from public.event_valet_audit    where event_id = 'watermakers-veterans-2026';
delete from public.event_valet_tickets  where event_id = 'watermakers-veterans-2026';
update public.event_valet_events set staff_access_enabled = true, is_open = true, closed_at = null where id in ('watermakers-veterans-2026', 'makers-halloween-2026');
insert into public.event_valet_access (event_id, kind, label, token_hash, valid_until) values
  ('watermakers-veterans-2026', 'DEVICE', 'S710-1',   sha256(convert_to(rpad('dev', 43, 'x'), 'UTF8')), now() + interval '1 day'),
  ('watermakers-veterans-2026', 'LINK',   'Phone A',  sha256(convert_to(rpad('lnk', 43, 'x'), 'UTF8')), now() + interval '1 day'),
  ('makers-halloween-2026',     'DEVICE', 'HW dev',   sha256(convert_to(rpad('hwd', 43, 'x'), 'UTF8')), now() + interval '1 day');
insert into public.event_valet_access (event_id, kind, label, token_hash, valid_from, valid_until) values
  ('watermakers-veterans-2026', 'LINK', 'Expired', sha256(convert_to(rpad('exp', 43, 'x'), 'UTF8')), now() - interval '1 day', now() - interval '1 minute');
insert into public.event_valet_access (event_id, kind, label, token_hash, valid_until, revoked_at) values
  ('watermakers-veterans-2026', 'LINK', 'Revoked', sha256(convert_to(rpad('rev', 43, 'x'), 'UTF8')), now() + interval '1 day', now());

create or replace function pg_temp.err(p_token text, p_session uuid, p_op text, p_body jsonb) returns text language plpgsql as $$
declare d text;
begin
  perform public.event_valet_staff(p_token, p_session, p_op, p_body);
  return 'OK';
exception when others then get stacked diagnostics d = pg_exception_detail; return sqlerrm || coalesce(' ' || d, '');
end $$;
grant execute on function pg_temp.err(text, uuid, text, jsonb) to public;

set local role service_role;
do $$
declare D text := rpad('dev', 43, 'x'); L text := rpad('lnk', 43, 'x'); HW text := rpad('hwd', 43, 'x');
        sd uuid; sl uuid; sl2 uuid; sh uuid; r jsonb; e text; t1 uuid; t2 uuid; tw uuid; i int; h int; v_ok boolean;
begin
  -- sessions
  r := public.event_valet_staff(D, null, 'session', '{"name":"carlos"}');
  sd := (r->>'sessionId')::uuid;
  insert into _r(name, ok, info) values ('device session created, name capitalised, pool 1–40', r->>'employeeName' = 'Carlos' and r#>>'{access,pool}' = '[1, 40]', r::text);
  sl := (public.event_valet_staff(L, null, 'session', '{"name":"Ana"}')->>'sessionId')::uuid;
  sl2 := (public.event_valet_staff(L, null, 'session', '{"name":"Diego"}')->>'sessionId')::uuid;
  sh := (public.event_valet_staff(HW, null, 'session', '{"name":"Hal"}')->>'sessionId')::uuid;
  insert into _r(name, ok, info) values ('name too short rejected', pg_temp.err(D, null, 'session', '{"name":"x"}') like 'BAD_INPUT%', null);

  -- auth failures
  e := pg_temp.err('short', sd, 'state', '{}');               insert into _r(name, ok, info) values ('malformed token → AUTH', e like 'AUTH%', e);
  e := pg_temp.err(rpad('zzz', 43, 'x'), sd, 'state', '{}');  insert into _r(name, ok, info) values ('unknown token → AUTH', e like 'AUTH%', e);
  e := pg_temp.err(rpad('rev', 43, 'x'), sd, 'state', '{}');  insert into _r(name, ok, info) values ('revoked link → REVOKED', e like 'REVOKED%', e);
  e := pg_temp.err(rpad('exp', 43, 'x'), sd, 'state', '{}');  insert into _r(name, ok, info) values ('expired link → OUTSIDE_WINDOW', e like 'OUTSIDE_WINDOW%', e);
  e := pg_temp.err(D, null, 'state', '{}');                   insert into _r(name, ok, info) values ('no session → AUTH', e like 'AUTH%', e);
  e := pg_temp.err(D, sl, 'state', '{}');                     insert into _r(name, ok, info) values ('session of another credential → AUTH', e like 'AUTH%', e);

  -- state
  r := public.event_valet_staff(D, sd, 'state', '{"pending":0}');
  insert into _r(name, ok, info) values ('state: 50 hooks free, FRONT/SIDE/BACK, pools', (r#>>'{counts,hooksFree}')::int = 50
     and r#>>'{event,locations}' = '["FRONT", "SIDE", "BACK"]' and r#>>'{pools,device}' = '[1, 40]' and r#>>'{pools,phone}' = '[41, 50]', left(r::text, 300));

  -- check-in: auto allocation per pool
  r := public.event_valet_staff(D, sd, 'checkin', '{"clientKey":"ck-dev-0001","phone":"(954) 555-0101","vehicle":{"color":"Black","make":"BMW","model":"X5"},"location":"FRONT","keyStoredAt":"2026-11-05T12:00:00Z"}');
  t1 := (r->>'ticketId')::uuid;
  insert into _r(name, ok, info) values ('device check-in → hook 1, notify CHECKIN, vehicle text', (r#>>'{ticket,hook}')::int = 1 and r->>'notify' = 'CHECKIN'
     and r#>>'{ticket,vehicleText}' = 'BLACK BMW X5' and r#>>'{ticket,checkedInBy}' = 'Carlos' and r#>>'{ticket,phoneLast4}' = '0101', r::text);
  insert into _r(name, ok, info) values ('staff ticket JSON has no full phone', r::text not like '%+19545550101%', null);
  r := public.event_valet_staff(L, sl, 'checkin', '{"clientKey":"ck-lnk-0001","phone":"9545550102","vehicle":{"plate":"lxr 4417"},"location":"SIDE","keyStoredAt":"2026-11-05T12:00:00Z"}');
  t2 := (r->>'ticketId')::uuid;
  insert into _r(name, ok, info) values ('phone link check-in → hook 41 (phone pool), plate vehicle', (r#>>'{ticket,hook}')::int = 41 and r#>>'{ticket,vehicleText}' = 'PLATE LXR 4417', r::text);

  -- idempotent replay
  r := public.event_valet_staff(D, sd, 'checkin', '{"clientKey":"ck-dev-0001","phone":"(954) 555-0101","vehicle":{"color":"Black","make":"BMW","model":"X5"},"location":"FRONT","keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('replay same clientKey → same ticket, replayed', (r->>'ticketId')::uuid = t1 and (r->>'replayed')::boolean
     and (select count(*) from public.event_valet_tickets where event_id = 'watermakers-veterans-2026') = 2, r::text);
  e := pg_temp.err(D, sd, 'status', '{"clientKey":"ck-dev-0001","ticketId":"00000000-0000-0000-0000-000000000000","to":"READY"}');
  insert into _r(name, ok, info) values ('clientKey reused for another op → BAD_INPUT', e like 'BAD_INPUT%', e);

  -- input validation
  e := pg_temp.err(D, sd, 'checkin', '{"clientKey":"ck-dev-bad1","phone":"123","vehicle":{"make":"KIA"},"location":"FRONT","keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('bad phone → BAD_INPUT phone', e like 'BAD_INPUT%phone%', e);
  e := pg_temp.err(D, sd, 'checkin', '{"clientKey":"ck-dev-bad2","phone":"9545550103","vehicle":{"color":"Red"},"location":"FRONT","keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('no make and no plate → BAD_INPUT vehicle', e like 'BAD_INPUT%vehicle%', e);
  e := pg_temp.err(D, sd, 'checkin', '{"clientKey":"ck-dev-bad3","phone":"9545550103","vehicle":{"make":"KIA"},"location":"GRASS","keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('foreign location → BAD_INPUT location', e like 'BAD_INPUT%location%', e);
  e := pg_temp.err(D, sd, 'checkin', '{"clientKey":"ck-dev-bad4","phone":"9545550103","vehicle":{"make":"KIA"},"location":"BACK"}');
  insert into _r(name, ok, info) values ('no key confirmation → BAD_INPUT keyStoredAt', e like 'BAD_INPUT%keyStoredAt%', e);

  -- pool rules
  e := pg_temp.err(L, sl, 'checkin', '{"clientKey":"ck-lnk-0002","phone":"9545550104","vehicle":{"make":"KIA"},"location":"BACK","hook":5,"keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('phone may NOT use an S710 hook (5)', e like 'BAD_INPUT%not_your_pool%', e);
  e := pg_temp.err(D, sd, 'checkin', '{"clientKey":"ck-dev-0002","phone":"9545550104","vehicle":{"make":"KIA"},"location":"BACK","hook":41,"keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('taken hook 41 → HOOK_TAKEN suggestedHook 2', e like 'HOOK_TAKEN%"suggestedHook": 2%', e);
  r := public.event_valet_staff(D, sd, 'checkin', '{"clientKey":"ck-dev-0003","phone":"9545550105","vehicle":{"make":"KIA"},"location":"BACK","hook":45,"offline":true,"keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('S710 may pick a free phone-pool hook explicitly (45)', (r#>>'{ticket,hook}')::int = 45, r::text);

  -- holds
  r := public.event_valet_staff(D, sd, 'hold', '{"clientKey":"ck-dev-hold"}');
  insert into _r(name, ok, info) values ('hold → hook 2', (r->>'hook')::int = 2, r::text);
  r := public.event_valet_staff(D, sd, 'hold', '{"clientKey":"ck-dev-hold"}');
  insert into _r(name, ok, info) values ('hold again same key → same hook 2', (r->>'hook')::int = 2, r::text);
  r := public.event_valet_staff(D, sd, 'checkin', '{"clientKey":"ck-dev-0004","phone":"9545550106","vehicle":{"make":"FORD"},"location":"BACK","keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('other check-in skips held hook 2 → 3', (r#>>'{ticket,hook}')::int = 3, r::text);
  e := pg_temp.err(D, sd, 'checkin', '{"clientKey":"ck-dev-0005","phone":"9545550107","vehicle":{"make":"FORD"},"location":"BACK","hook":2,"keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('explicit held hook 2 by another key → HOOK_TAKEN', e like 'HOOK_TAKEN%', e);
  r := public.event_valet_staff(D, sd, 'checkin', '{"clientKey":"ck-dev-hold","phone":"9545550108","vehicle":{"make":"FORD"},"location":"BACK","keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('check-in with the hold key uses hook 2, hold cleared', (r#>>'{ticket,hook}')::int = 2
     and not exists (select 1 from public.event_valet_holds where client_key = 'ck-dev-hold'), r::text);
  update public.event_valet_holds set held_until = now() - interval '1 second';  -- (none left; harmless)

  -- fill the S710 pool (hooks 1..40), then the S710 borrows phone hooks; phones never borrow S710 hooks
  for i in 6..60 loop
    e := pg_temp.err(D, sd, 'checkin', jsonb_build_object('clientKey', 'ck-fill-' || i, 'phone', '95455510' || lpad(i::text, 2, '0'),
           'vehicle', jsonb_build_object('make', 'CAR'), 'location', 'FRONT', 'keyStoredAt', '2026-11-05T12:00:00Z'));
    exit when e <> 'OK';
  end loop;
  insert into _r(name, ok, info) values ('S710 fills 1..40 then borrows 42..50 (41/45 used) → all 50 used, 51st full',
     e like 'HOOK_TAKEN%full%' and (select count(distinct slot_no) from public.event_valet_tickets where event_id = 'watermakers-veterans-2026' and status <> 'DELIVERED') = 50, e);
  r := public.event_valet_staff(D, sd, 'state', '{}');
  insert into _r(name, ok, info) values ('state: hooksFree 0, active 50', (r#>>'{counts,hooksFree}')::int = 0 and (r#>>'{counts,active}')::int = 50, r#>>'{counts}');

  -- retrieval ownership
  r := public.event_valet_staff(D, sd, 'status', jsonb_build_object('clientKey', 'ck-stat-1', 'ticketId', t1, 'to', 'RETRIEVING'));
  insert into _r(name, ok, info) values ('GET CAR from PARKED → RETRIEVING by Carlos, notify ONWAY, requestedAt set', r#>>'{ticket,status}' = 'RETRIEVING'
     and r#>>'{ticket,retrievingBy}' = 'Carlos' and r->>'notify' = 'ONWAY' and r#>>'{ticket,requestedAt}' is not null, r::text);
  e := pg_temp.err(L, sl, 'status', jsonb_build_object('clientKey', 'ck-stat-2', 'ticketId', t1, 'to', 'RETRIEVING'));
  insert into _r(name, ok, info) values ('second employee claim → TAKEN_BY Carlos', e like 'TAKEN_BY%Carlos%', e);
  r := public.event_valet_staff(D, sd, 'status', jsonb_build_object('clientKey', 'ck-stat-3', 'ticketId', t1, 'to', 'RETRIEVING'));
  insert into _r(name, ok, info) values ('same session re-claim is a no-op (no notify)', r#>>'{ticket,status}' = 'RETRIEVING' and not (r ? 'notify'), r::text);
  r := public.event_valet_staff(D, sd, 'status', jsonb_build_object('clientKey', 'ck-stat-4', 'ticketId', t1, 'to', 'READY'));
  insert into _r(name, ok, info) values ('CAR READY → notify READY', r#>>'{ticket,status}' = 'READY' and r->>'notify' = 'READY', r::text);
  r := public.event_valet_staff(D, sd, 'status', jsonb_build_object('clientKey', 'ck-stat-5', 'ticketId', t1, 'to', 'DELIVERED'));
  insert into _r(name, ok, info) values ('DELIVERED → notify THANKS, deliveredBy Carlos', r#>>'{ticket,status}' = 'DELIVERED' and r->>'notify' = 'THANKS' and r#>>'{ticket,deliveredBy}' = 'Carlos', r::text);
  r := public.event_valet_staff(D, sd, 'state', '{}');
  insert into _r(name, ok, info) values ('hook released only at DELIVERED (hooksFree 1)', (r#>>'{counts,hooksFree}')::int = 1, r#>>'{counts}');
  r := public.event_valet_staff(D, sd, 'checkin', '{"clientKey":"ck-dev-reuse","phone":"9545550199","vehicle":{"make":"AUDI"},"location":"SIDE","keyStoredAt":"2026-11-05T12:00:00Z"}');
  insert into _r(name, ok, info) values ('released hook 1 is reused', (r#>>'{ticket,hook}')::int = 1, r::text);
  e := pg_temp.err(D, sd, 'edit', jsonb_build_object('clientKey', 'ck-edit-1', 'ticketId', t1, 'location', 'BACK'));
  insert into _r(name, ok, info) values ('edit delivered car → BAD_INPUT', e like 'BAD_INPUT%already_delivered%', e);

  -- staff request / cancel / undo
  r := public.event_valet_staff(L, sl, 'status', jsonb_build_object('clientKey', 'ck-stat-6', 'ticketId', t2, 'to', 'REQUESTED'));
  insert into _r(name, ok, info) values ('staff request PARKED → REQUESTED (source STAFF)', r#>>'{ticket,status}' = 'REQUESTED' and r#>>'{ticket,requestSource}' = 'STAFF', r::text);
  r := public.event_valet_staff(L, sl, 'status', jsonb_build_object('clientKey', 'ck-stat-7', 'ticketId', t2, 'to', 'PARKED'));
  insert into _r(name, ok, info) values ('cancel request → PARKED clears requestedAt', r#>>'{ticket,status}' = 'PARKED' and r#>>'{ticket,requestedAt}' is null, r::text);
  e := pg_temp.err(L, sl, 'status', jsonb_build_object('clientKey', 'ck-stat-8', 'ticketId', t2, 'to', 'FLYING'));
  insert into _r(name, ok, info) values ('unknown status → BAD_INPUT', e like 'BAD_INPUT%', e);

  -- edit / move hook
  r := public.event_valet_staff(L, sl, 'edit', jsonb_build_object('clientKey', 'ck-edit-2', 'ticketId', t2, 'location', 'BACK', 'vehicle', jsonb_build_object('color', 'White', 'make', 'Tesla', 'plate', 'lxr 4417')));
  insert into _r(name, ok, info) values ('edit location + vehicle', r#>>'{ticket,location}' = 'BACK' and r#>>'{ticket,vehicleText}' = 'WHITE TESLA', r::text);
  e := pg_temp.err(L, sl, 'move-hook', jsonb_build_object('clientKey', 'ck-move-1', 'ticketId', t2, 'hook', 42));
  insert into _r(name, ok, info) values ('move to a used hook → HOOK_TAKEN', e like 'HOOK_TAKEN%', e);

  -- cash tips
  r := public.event_valet_staff(L, sl, 'cash-tip', jsonb_build_object('clientKey', 'ck-cash-1', 'ticketId', t2, 'amountCents', 1000));
  insert into _r(name, ok, info) values ('cash tip $10 recorded for Ana', (r#>>'{tip,amountCents}')::int = 1000 and r#>>'{tip,employeeName}' = 'Ana', r::text);
  e := pg_temp.err(D, sd, 'cash-tip', jsonb_build_object('clientKey', 'ck-cash-2', 'ticketId', t2, 'amountCents', 1000));
  insert into _r(name, ok, info) values ('same car + amount within 3 min → DUPLICATE_CASH', e like 'DUPLICATE_CASH%Ana%', e);
  r := public.event_valet_staff(D, sd, 'cash-tip', jsonb_build_object('clientKey', 'ck-cash-3', 'ticketId', t2, 'amountCents', 1000, 'confirmDuplicate', true));
  insert into _r(name, ok, info) values ('confirmDuplicate records a second tip', (r#>>'{tip,amountCents}')::int = 1000, r::text);
  r := public.event_valet_staff(D, sd, 'cash-tip', jsonb_build_object('clientKey', 'ck-cash-3', 'ticketId', t2, 'amountCents', 1000, 'confirmDuplicate', true));
  insert into _r(name, ok, info) values ('replayed cash clientKey does not add a row', (r->>'replayed')::boolean
     and (select count(*) from public.event_valet_tips where event_id = 'watermakers-veterans-2026') = 2, r::text);
  r := public.event_valet_staff(D, sd, 'cash-tip', jsonb_build_object('clientKey', 'ck-cash-4', 'amountCents', 500));
  insert into _r(name, ok, info) values ('event-level cash tip (no car)', r#>'{tip,ticketId}' = 'null'::jsonb, r::text);
  e := pg_temp.err(D, sd, 'cash-tip', jsonb_build_object('clientKey', 'ck-cash-5', 'amountCents', 50));
  insert into _r(name, ok, info) values ('$0.50 cash → BAD_INPUT', e like 'BAD_INPUT%', e);

  -- search
  r := public.event_valet_staff(D, sd, 'search', '{"q":"41"}');
  insert into _r(name, ok, info) values ('search hook "41"', jsonb_array_length(r->'tickets') = 1 and (r#>>'{tickets,0,id}')::uuid = t2, r::text);
  r := public.event_valet_staff(D, sd, 'search', '{"q":"0102"}');
  insert into _r(name, ok, info) values ('search phone last 4', exists (select 1 from jsonb_array_elements(r->'tickets') x where (x->>'id')::uuid = t2), left(r::text, 200));
  r := public.event_valet_staff(D, sd, 'search', '{"q":"lxr4417"}');
  insert into _r(name, ok, info) values ('search plate without space', exists (select 1 from jsonb_array_elements(r->'tickets') x where (x->>'id')::uuid = t2), left(r::text, 200));
  r := public.event_valet_staff(D, sd, 'search', '{"q":"bmw"}');
  insert into _r(name, ok, info) values ('search vehicle text finds the delivered BMW (last hour)', exists (select 1 from jsonb_array_elements(r->'tickets') x where (x->>'id')::uuid = t1), left(r::text, 200));

  -- cross-event isolation
  e := pg_temp.err(HW, sh, 'status', jsonb_build_object('clientKey', 'ck-hwd-01', 'ticketId', t2, 'to', 'READY'));
  insert into _r(name, ok, info) values ('Halloween credential cannot touch a Watermakers car', e like 'NOT_FOUND%', e);
  r := public.event_valet_staff(HW, sh, 'state', '{}');
  insert into _r(name, ok, info) values ('Halloween credential sees no Watermakers car', not exists (select 1 from jsonb_array_elements(r->'tickets') x where (x->>'id')::uuid in (t1, t2)), left(r::text, 120));
  e := pg_temp.err(HW, sh, 'cash-tip', jsonb_build_object('clientKey', 'ck-hwd-02', 'ticketId', t2, 'amountCents', 500));
  insert into _r(name, ok, info) values ('Halloween credential cannot tip a Watermakers car', e like 'NOT_FOUND%', e);
end $$;
reset role;

-- rate limit + switches + closed event (as postgres, then back to service_role)
insert into public.event_valet_rate (access_id, bucket, n)
  select id, date_trunc('minute', now()), 240 from public.event_valet_access where label = 'Phone A'
  on conflict (access_id, bucket) do update set n = 240;
set local role service_role;
insert into _v values ('rate', pg_temp.err(rpad('lnk', 43, 'x'), (select id from public.event_valet_sessions where employee_name = 'Ana' limit 1), 'state', '{}'));
reset role;
insert into _r(name, ok, info) select '241st request in a minute → RATE_LIMIT', v like 'RATE_LIMIT%', v from _v where k = 'rate';
update public.event_valet_events set staff_access_enabled = false where id = 'watermakers-veterans-2026';
set local role service_role;
insert into _v values ('off', pg_temp.err(rpad('dev', 43, 'x'), (select id from public.event_valet_sessions where employee_name = 'Carlos' limit 1), 'state', '{}'));
reset role;
insert into _r(name, ok, info) select 'staff access switch OFF → OUTSIDE_WINDOW', v like 'OUTSIDE_WINDOW%staff_access_off%', v from _v where k = 'off';
update public.event_valet_events set staff_access_enabled = true where id = 'watermakers-veterans-2026';

-- route check (READY routing pre-check)
update public.event_valet_events set sms_replies_enabled = false where id = 'watermakers-veterans-2026';
insert into _r(name, ok, info) select 'route_check NONE while replies switch is off', public.event_valet_route_check('+19545550102')->>'route' = 'NONE', public.event_valet_route_check('+19545550102')::text;
update public.event_valet_events set sms_replies_enabled = true where id = 'watermakers-veterans-2026';
insert into _r(name, ok, info) select 'route_check EVENT for an active Watermakers car', public.event_valet_route_check('+19545550102')->>'route' = 'EVENT', public.event_valet_route_check('+19545550102')::text;
insert into _r(name, ok, info) select 'route_check NONE for a delivered-only phone', public.event_valet_route_check('+19545550101')->>'route' = 'NONE', public.event_valet_route_check('+19545550101')::text;
insert into _r(name, ok, info) select 'route_check NONE for an unknown phone', public.event_valet_route_check('+13055550000')->>'route' = 'NONE', null;

-- admin RPCs
insert into _v select 'tip5', id::text from public.event_valet_tips where event_id = 'watermakers-veterans-2026' and amount_cents = 500;
select set_config('request.jwt.claims', json_build_object('sub', :'ipad', 'role', 'authenticated')::text, true) \gset _x_
set local role authenticated;
do $$ begin
  perform public.event_valet_admin_report('watermakers-veterans-2026');
  insert into _r(name, ok) values ('non-admin cannot read the report', false);
exception when others then insert into _r(name, ok, info) values ('non-admin cannot read the report', sqlerrm = 'NOT_AUTHORIZED', sqlerrm); end $$;
do $$ begin
  perform public.event_valet_admin_access_create('watermakers-veterans-2026', 'LINK', 'x', now() + interval '1 hour');
  insert into _r(name, ok) values ('non-admin cannot create links', false);
exception when others then insert into _r(name, ok, info) values ('non-admin cannot create links', sqlerrm = 'NOT_AUTHORIZED', sqlerrm); end $$;
do $$ begin
  perform public.event_valet_staff(rpad('dev', 43, 'x'), null, 'session', '{"name":"Hacker"}');
  insert into _r(name, ok) values ('authenticated users cannot call the staff dispatcher', false);
exception when others then insert into _r(name, ok, info) values ('authenticated users cannot call the staff dispatcher', sqlstate = '42501', sqlerrm); end $$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'admin', 'role', 'authenticated')::text, true) \gset _x_
set local role authenticated;
do $$
declare r jsonb; v_tip uuid; n int;
begin
  r := public.event_valet_admin_access_create('watermakers-veterans-2026', 'LINK', 'New phone', now() + interval '3 hours');
  insert into _r(name, ok, info) values ('admin creates a link: 43-char token returned once', r->>'token' ~ '^[A-Za-z0-9_-]{43}$', left(r::text, 60));
  insert into _v values ('newtok', r->>'token');
  r := public.event_valet_admin_access_revoke((r->>'id')::uuid);
  insert into _r(name, ok, info) values ('admin revokes it', r->>'revokedAt' is not null, r::text);
  r := public.event_valet_admin_access_extend('watermakers-veterans-2026', now() + interval '2 days');
  insert into _r(name, ok, info) values ('admin extends the window of live credentials', (r->>'extended')::int >= 2, r::text);
  r := public.event_valet_admin_set_flags('watermakers-veterans-2026', '{"thanks":true,"tips":true}');
  insert into _r(name, ok, info) values ('admin flags', (r->>'thanks')::boolean and (r->>'tips')::boolean and (r->>'staffAccess')::boolean, r::text);
  r := public.event_valet_admin_report('watermakers-veterans-2026');
  insert into _r(name, ok, info) values ('report: counts, peak 50, employees, cash $25', (r#>>'{counts,checkedIn}')::int = 51 and (r#>>'{peak,count}')::int = 50
     and (r#>>'{cash,totalCents}')::int = 2500 and jsonb_array_length(r->'employees') >= 2 and jsonb_array_length(r->'blockers') = 1,
     concat_ws(' | ', r->'counts', r->'peak', r#>'{cash,totalCents}', jsonb_array_length(r->'employees'), r->'blockers'));
  select v::uuid into v_tip from _v where k = 'tip5';
  begin perform public.event_valet_admin_cash_correct(v_tip, 700, ''); insert into _r(name, ok) values ('correction without reason rejected', false);
  exception when others then insert into _r(name, ok, info) values ('correction without reason rejected', sqlerrm = 'REASON_REQUIRED', sqlerrm); end;
  r := public.event_valet_admin_cash_correct(v_tip, 700, 'counted $7');
  insert into _r(name, ok, info) values ('cash correction returns old value', (r->>'from')::int = 500 and (r->>'amountCents')::int = 700, r::text);
  r := public.event_valet_admin_close('watermakers-veterans-2026');
  insert into _r(name, ok, info) values ('close blocked while cars are active', not (r->>'closed')::boolean and r#>>'{blockers,0,code}' = 'ACTIVE_VEHICLES', r::text);
end $$;
reset role;
insert into _r(name, ok, info) select 'cash correction stored with reason + audit row', t.corrected_from = 500 and t.amount_cents = 700 and t.correction_reason = 'counted $7'
   and exists (select 1 from public.event_valet_audit where action = 'CASH_CORRECT' and detail->>'tip_id' = t.id::text), null
  from public.event_valet_tips t where t.id = (select v::uuid from _v where k = 'tip5');
update public.event_valet_tickets set status = 'DELIVERED', delivered_at = now() where event_id = 'watermakers-veterans-2026' and status <> 'DELIVERED';
update public.event_valet_access set pending_ops = 2 where label = 'S710-1';
set local role authenticated;
do $$ declare r jsonb; begin
  r := public.event_valet_admin_close('watermakers-veterans-2026');
  insert into _r(name, ok, info) values ('close blocked while the S710 reports unsynced ops', not (r->>'closed')::boolean and r#>>'{blockers,0,code}' = 'PENDING_OPS', r::text);
end $$;
reset role;
update public.event_valet_access set pending_ops = 0 where label = 'S710-1';
set local role authenticated;
do $$ declare r jsonb; begin
  r := public.event_valet_admin_close('watermakers-veterans-2026');
  insert into _r(name, ok, info) values ('close OK → event closed', (r->>'closed')::boolean, r::text);
end $$;
reset role;
insert into _r(name, ok, info) select 'admin link stored as sha256 only', exists (select 1 from public.event_valet_access x, _v where _v.k = 'newtok' and x.token_hash = sha256(convert_to(_v.v, 'UTF8')))
   and not exists (select 1 from public.event_valet_access x, _v where _v.k = 'newtok' and x.label = _v.v), null;
insert into _r(name, ok, info) select 'after close all credentials are revoked', not exists (select 1 from public.event_valet_access where event_id = 'watermakers-veterans-2026' and revoked_at is null), null;
insert into _r(name, ok, info) select 'records kept after close', (select count(*) from public.event_valet_tickets where event_id = 'watermakers-veterans-2026') = 51
     and (select count(*) from public.event_valet_tips where event_id = 'watermakers-veterans-2026') = 3, null;
set local role service_role;
insert into _v values ('closed', pg_temp.err(rpad('dev', 43, 'x'), (select id from public.event_valet_sessions where employee_name = 'Carlos' limit 1), 'state', '{}'));
reset role;
insert into _r(name, ok, info) select 'after close the S710 token is refused', v like 'REVOKED%' or v like 'EVENT_CLOSED%', v from _v where k = 'closed';
insert into _r(name, ok, info) select 'Halloween event untouched by the close', is_open and closed_at is null, null from public.event_valet_events where id = 'makers-halloween-2026';

select n, case when ok then 'PASS' else 'FAIL' end, name, case when ok then '' else coalesce(info, '') end from _r order by n;
select count(*) filter (where ok) || '/' || count(*) || ' passed' from _r;
rollback;
