-- LOCAL performance check for 20261114 (rolled back): 50,000 synthetic tickets (~14x production),
-- 40% returning guests. Prints the time of each call as the IPAD_OPS login.
--   (echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' migrations/20261114_airvalet_guests.sql; cat tests/portal/perf_guests_1114.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, loc, car, color, checkout_date, previous_delivery_location, delivery_type)
select 2000000 + g, 'x', now() - (g % 500) * interval '1 day',
       (array['JOHN','MARY','PHILIP','ANA','LUCAS','EMMA','NOAH','OLIVIA','LIAM','SOPHIA'])[1 + g % 10] || ' ' || translate((g % 30000)::text, '0123456789', 'ABCDEFGHIJ') || 'SON',
       '30' || lpad(((g % 30000) + 1000000)::text, 8, '0'), 'P' || g, 'DELIVERED', '1/1/2026', 'HANGAR 19', 'Car ' || (g % 50), 'Black',
       now() - (g % 500) * interval '1 day' + interval '4 days', 'HANGAR 16', 'NORMAL'
  from generate_series(1, 50000) g;
analyze public.passengers;
create function pg_temp.t(q text) returns text language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); r jsonb;
begin execute q into r; return round(extract(epoch from clock_timestamp() - t0) * 1000) || ' ms  ' || left(q, 70) || '  → ' || left(coalesce(r ->> 'total', r ->> 'visits_count', jsonb_array_length(coalesce(r -> 'events', r -> 'guests', '[]'::jsonb))::text), 12); end $$;
grant execute on all functions in schema pg_temp to authenticated;
select set_config('request.jwt.claims', json_build_object('sub', (select id from public.user_profiles where username = 'localipad'), 'role', 'authenticated', 'email', 'localipad@airvalet.local')::text, true);
set local role authenticated;
select pg_temp.t($$select public.airvalet_guest_search('', 30, 0)$$);
select pg_temp.t($$select public.airvalet_guest_search('philip bc', 30, 0)$$);
select pg_temp.t($$select public.airvalet_guest_search('3001012345', 30, 0)$$);
select pg_temp.t($$select public.airvalet_guest_search('P4999', 30, 0)$$);
select pg_temp.t($$select public.airvalet_guest_profile('ph:3001001234:LUCAS')$$);
select pg_temp.t($$select public.airvalet_guest_activity('ph:3001001234:LUCAS')$$);
select pg_temp.t($$select public.airvalet_guest_lookup_phone('3001001234')$$);
select pg_temp.t($$select public.airvalet_guest_search('john', 30, 0)$$);
select pg_temp.t($$select public.airvalet_guest_search('', 30, 300)$$);
select pg_temp.t($$select public.airvalet_guest_for_passenger(2001234)$$);
