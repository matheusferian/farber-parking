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
  perform pg_temp.ok((select count(*) from public.passengers where pickup_auth_name is not null and id <> v_id) = 0, 'existing rows have no authorization (additive migration)');
end $$;
rollback;
