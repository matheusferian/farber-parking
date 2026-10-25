-- 20261103: chat polling must not trip the per-client brake; token guessing still must.
-- Run: psql -v ON_ERROR_STOP=1 -f tests/portal/sql_fix_1103_tests.sql  (local stack only, rolls back)
begin;
create or replace function pg_temp.ok(c boolean, m text) returns void language plpgsql as $$
begin if not coalesce(c,false) then raise exception 'FAIL: %', m; end if; raise notice 'ok   %', m; end $$;
do $$
declare v_pid bigint; v_tok text := 'Fx1103chatLimitAA'; r record; i int; v_lim int := 0;
begin
  delete from public.airvalet_pass_rate;
  update public.airvalet_portal_settings set portal_enabled = true;
  select id into v_pid from public.passengers where status <> 'DELIVERED' order by id limit 1;
  update public.airvalet_pass_links set revoked_at = now(), revoke_reason = 'staff' where passenger_id = v_pid and revoked_at is null;
  insert into public.airvalet_pass_links (token_hash, passenger_id) values (extensions.digest(v_tok,'sha256'), v_pid);
  -- 15 min of chat open at the old 8 s poll (≈ 112 calls in one 10-min window would be the worst case; 90 here)
  for i in 1..90 loop
    select * into r from public.airvalet_portal_resolve(v_tok, 'chat-client');
    if r.o_state = 'limited' then v_lim := v_lim + 1; end if;
  end loop;
  perform pg_temp.ok(v_lim = 0, '90 valid calls from one client in a window → never limited (was limited after 30)');
  -- brake still exists for real abuse
  for i in 1..70 loop perform public.airvalet_portal_resolve(v_tok, 'chat-client'); end loop;
  select * into r from public.airvalet_portal_resolve(v_tok, 'chat-client');
  perform pg_temp.ok(r.o_state = 'limited', '> 150 calls from one client in a window → limited');
  -- token guessing: 8 wrong tokens then even the right token is refused for that client
  for i in 1..8 loop perform public.airvalet_portal_resolve('Wrong' || lpad(i::text, 12, '0'), 'guesser'); end loop;
  select * into r from public.airvalet_portal_resolve(v_tok, 'guesser');
  perform pg_temp.ok(r.o_state = 'limited', '8 wrong tokens → that client is limited (unchanged)');
end $$;
rollback;
