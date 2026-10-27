-- LOCAL DB tests for 20261116_airvalet_pass_small_cash_tip.sql. One transaction, rolled back:
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; cat tests/portal/sql_pass_small_cash_1116_tests.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres
create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.act(u text) returns void language plpgsql as $$
declare v_id uuid;
begin
  reset role;
  select id into v_id from public.user_profiles where username = u;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', u || '@airvalet.local')::text, true);
  execute 'set local role authenticated';
end $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- Cars delivered today (a delivered car's pass link lives 7 days from the delivery).
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, return_operator, checkout_date, deldate, delivery_type, tip_received, tip_in_person_cents)
select 971600 + n, 'x', now(), 'SMALL TIP ' || n, '30555576' || lpad(n::text, 2, '0'), 'T1116-' || n, 'DELIVERED', to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'HANGAR 19', 'BMW', 'Black', 'MAKERS',
       now(), to_char((now() at time zone 'America/New_York')::date, 'FMMM/FMDD/YYYY'), 'NORMAL', null, null
  from generate_series(1, 6) n;
select pg_temp.act('localipad');
select public.airvalet_tip_record(971601, 200, gen_random_uuid(), null, 'DELIVERY');   -- $2
select public.airvalet_tip_record(971602, 499, gen_random_uuid(), null, 'DELIVERY');   -- $4.99
select public.airvalet_tip_record(971603, 500, gen_random_uuid(), null, 'DELIVERY');   -- $5
select public.airvalet_tip_record(971604, 2000, gen_random_uuid(), null, 'DELIVERY');  -- $20
reset role;
update public.passengers set tip_received = true where id = 971605;                     -- legacy "Yes" without an amount
insert into public.payments (passenger_id, ticket, amount_cents, type, method, status, stripe_event_id) values (971606, 'T1116-6', 300, 'TIP', 'STRIPE', 'succeeded', 'evt_t1116_6');
insert into public.airvalet_sms_devices (key_hash, label, status, decided_at)
values (public.airvalet_sms_device_key_hash('t1116_device_key_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), 'T1116 iPad', 'approved', now());
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
select p.id, public.airvalet_sms_normalize_phone(p.phone), (select d.id from public.airvalet_sms_devices d where d.label = 'T1116 iPad'), gen_random_uuid()
  from public.passengers p where p.id between 971601 and 971606;
create temp table t_tok as select id pid, public.airvalet_pass_mint(id) tok from public.passengers where id between 971601 and 971606;
update public.airvalet_portal_settings set portal_enabled = true;
create temp table t_v as select pid, public.airvalet_portal_view(tok, 'c1116-' || pid) -> 'pass' p from t_tok;

select pg_temp.check((select tip_in_person_cents = 200 and tip_received from public.passengers where id = 971601), '$2 recorded as cash (counts in the Closing)');
select pg_temp.check((select p ->> 'tip_thanks' from t_v where pid = 971601) = 'false', '$2 cash → pass as if nothing was given (no thank-you)');
select pg_temp.check((select p ->> 'tip_thanks' from t_v where pid = 971602) = 'false', '$4.99 cash → no thank-you');
select pg_temp.check((select (p ->> 'gratuity_url') is not null from t_v where pid = 971601), '$2 cash → the Gratuity link stays on the pass');
select pg_temp.check((select p ->> 'tip_thanks' from t_v where pid = 971603) = 'true', '$5 cash → thank-you (no link asked again)');
select pg_temp.check((select p ->> 'tip_thanks' from t_v where pid = 971604) = 'true', '$20 cash → thank-you');
select pg_temp.check((select p ->> 'tip_thanks' from t_v where pid = 971605) = 'true', 'legacy Yes without amount → unchanged (thank-you)');
select pg_temp.check((select p ->> 'tip_thanks' from t_v where pid = 971606) = 'true', 'Stripe gratuity → unchanged (thank-you)');
select pg_temp.check((select bool_and(p::text !~ '(tip_in_person|amount_cents|"200"|4\.99)') from t_v), 'pass never carries the amount');
select pg_temp.check((select sum(amount_cents) = 3199 from public.airvalet_tip_records where passenger_id between 971601 and 971604 and voided_at is null), 'all four cash amounts stay in the ledger (Closing counts $2 too)');

select 'all 1116 checks passed';
