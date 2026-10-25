-- 20261104 authorized pickup: additive columns + release guard. Local stack only; rolls back.
-- Run: psql -v ON_ERROR_STOP=1 -f tests/portal/sql_pickup_1104_tests.sql
begin;
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$
begin if not coalesce(c,false) then raise exception 'FAIL: %', m; end if; raise notice 'ok   %', m; end $$;
do $$
declare v_id bigint; v_err text;
begin
  select id into v_id from public.passengers where status <> 'DELIVERED' order by id limit 1;
  -- no authorization → delivery works as before
  update public.passengers set status = 'DELIVERED' where id = v_id;
  perform pg_temp.ok((select status from public.passengers where id = v_id) = 'DELIVERED', 'no authorization → delivery unchanged');
  update public.passengers set status = 'PENDING' where id = v_id;
  -- authorization without ID check → refused
  update public.passengers set pickup_auth_name = 'ANA SOUZA', pickup_auth_phone = '7865550111' where id = v_id;
  begin
    update public.passengers set status = 'DELIVERED' where id = v_id;
    v_err := 'none';
  exception when check_violation then v_err := sqlerrm; end;
  perform pg_temp.ok(v_err like 'AUTHORIZED_PICKUP_ID_REQUIRED%', 'authorization without ID check → delivery refused');
  -- with the release record → allowed
  update public.passengers set status = 'DELIVERED', released_to_name = 'ANA SOUZA', released_to_kind = 'AUTHORIZED', released_id_checked = true, released_by = 't', released_at = now() where id = v_id;
  perform pg_temp.ok((select status from public.passengers where id = v_id) = 'DELIVERED', 'ID check recorded → delivered');
  -- reopened → the old check no longer counts; delivering again needs a new one
  update public.passengers set status = 'PENDING' where id = v_id;
  perform pg_temp.ok((select released_id_checked is null and released_to_name is null and released_by is null and released_at is null from public.passengers where id = v_id), 'reopening clears the previous release record');
  begin
    update public.passengers set status = 'DELIVERED' where id = v_id;
    v_err := 'none';
  exception when check_violation then v_err := sqlerrm; end;
  perform pg_temp.ok(v_err like 'AUTHORIZED_PICKUP_ID_REQUIRED%', 'reopened ticket cannot be delivered again with the old check');
  begin
    update public.passengers set status = 'DELIVERED', released_id_checked = true where id = v_id;
    v_err := 'none';
  exception when check_violation then v_err := sqlerrm; end;
  perform pg_temp.ok(v_err like 'AUTHORIZED_PICKUP_ID_REQUIRED%', 'ID flag without who took the car → refused');
  update public.passengers set status = 'DELIVERED', released_to_name = 'ANA SOUZA', released_to_kind = 'AUTHORIZED', released_id_checked = true where id = v_id;
  -- an INSERT that starts DELIVERED with an authorization is checked too
  begin
    insert into public.passengers (ts, checkin_date, name, phone, ticket, status, pickup_auth_name) values ('x', now(), 'T INS', '3055550999', '9999-01', 'DELIVERED', 'SOMEONE');
    v_err := 'none';
  exception when check_violation then v_err := sqlerrm; end;
  perform pg_temp.ok(v_err like 'AUTHORIZED_PICKUP_ID_REQUIRED%', 'insert as DELIVERED with an authorization and no check → refused');
  -- edits that do not touch status are never blocked
  update public.passengers set pickup_auth_notes = 'sister' where id = v_id;
  perform pg_temp.ok(true, 'other edits on an authorized ticket are not blocked');
  -- constraints
  begin update public.passengers set pickup_auth_phone = '123' where id = v_id; v_err := 'none';
  exception when check_violation then v_err := 'refused'; end;
  perform pg_temp.ok(v_err = 'refused', 'pickup phone must be 10 digits');
  begin update public.passengers set released_to_kind = 'FRIEND' where id = v_id; v_err := 'none';
  exception when check_violation then v_err := 'refused'; end;
  perform pg_temp.ok(v_err = 'refused', 'released_to_kind only GUEST or AUTHORIZED');
  -- who/when are stamped from the signed-in session, not taken from the client
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c1","email":"real.staff@airvalet.local","role":"authenticated"}', true);
  update public.passengers set pickup_auth_name = 'BRUNO LIMA', pickup_auth_by = 'someone.else@forged' where id = v_id;
  perform pg_temp.ok((select pickup_auth_by = 'real.staff@airvalet.local' and pickup_auth_at > now() - interval '1 minute' from public.passengers where id = v_id), 'pickup_auth_by comes from the session (forged value ignored)');
  update public.passengers set released_to_name = 'BRUNO LIMA', released_by = 'forged', released_at = '2000-01-01' where id = v_id;
  perform pg_temp.ok((select released_by = 'real.staff@airvalet.local' and released_at > now() - interval '1 minute' from public.passengers where id = v_id), 'released_by / released_at come from the session');
  update public.passengers set pickup_auth_name = null, pickup_auth_phone = null where id = v_id;
  perform pg_temp.ok((select pickup_auth_by is null and pickup_auth_at is null from public.passengers where id = v_id), 'revoking clears who/when');
  perform pg_temp.ok((select bool_and(is_nullable = 'YES' and column_default is null) from information_schema.columns
                      where table_schema = 'public' and table_name = 'passengers' and (column_name like 'pickup_auth%' or column_name like 'released%')), 'new columns are nullable with no default (existing rows untouched)');
end $$;
rollback;
