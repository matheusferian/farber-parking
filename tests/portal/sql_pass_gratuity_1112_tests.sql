-- LOCAL DB tests for 20261112_airvalet_pass_gratuity.sql. One transaction, rolled back. Runner
-- (works whether 1112 is applied or not: the rollback file is idempotent, then the migration):
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' migrations/20261112_airvalet_pass_gratuity_rollback.sql;
--    sed '/^begin;$/d;/^commit;$/d' migrations/20261112_airvalet_pass_gratuity.sql;
--    cat tests/portal/sql_pass_gratuity_1112_tests.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.rejects(q text) returns boolean language plpgsql as $$
begin
  execute q; return false;
exception when check_violation then return true;
end $$;

-- ── grants ────────────────────────────────────────────────────────────────
select pg_temp.check(not has_function_privilege('anon', 'public.airvalet_portal_gratuity_click(text,text)', 'execute')
  and not has_function_privilege('authenticated', 'public.airvalet_portal_gratuity_click(text,text)', 'execute')
  and has_function_privilege('service_role', 'public.airvalet_portal_gratuity_click(text,text)', 'execute'), 'gratuity_click: Edge Function (service_role) only');
-- (The local stack has table-wide grants that production does not have; the column checks below
--  only bite where the table-wide grant is absent, as in production.)
select pg_temp.check(has_column_privilege('authenticated', 'public.airvalet_pass_links', 'gratuity_clicks', 'select')
  and (has_table_privilege('authenticated', 'public.airvalet_pass_links', 'select') or not has_column_privilege('authenticated', 'public.airvalet_pass_links', 'token_hash', 'select'))
  and (has_table_privilege('anon', 'public.airvalet_pass_links', 'select') or not has_column_privilege('anon', 'public.airvalet_pass_links', 'gratuity_clicks', 'select')),
  'click count readable by staff; no new grant on token_hash or to anon');

-- ── defaults: everything OFF ──────────────────────────────────────────────
select pg_temp.check((select gratuity_reference = false and gratuity_checkout_enabled = false and gratuity_amounts_cents = '{500,1000,2000,4000,5000}'
  and gratuity_min_cents = 100 and gratuity_max_cents = 50000 from public.airvalet_portal_settings), 'flags default OFF; amounts $5 $10 $20 $40 $50, Other $1–$500');
select pg_temp.check(exists (select 1 from pg_indexes where indexname = 'payments_stripe_checkout_session_id_key' and indexdef like '%UNIQUE%'), 'payments: one row per Checkout Session');
select pg_temp.check(pg_temp.rejects($q$update public.airvalet_portal_settings set gratuity_amounts_cents = '{}'$q$), 'amounts: empty list refused');
select pg_temp.check(pg_temp.rejects($q$update public.airvalet_portal_settings set gratuity_amounts_cents = '{500,1000,2000,4000,5000,6000}'$q$), 'amounts: more than 5 refused (5 + Other = 2 rows of 3)');
select pg_temp.check(pg_temp.rejects($q$update public.airvalet_portal_settings set gratuity_amounts_cents = '{500,null}'$q$), 'amounts: null refused');
select pg_temp.check(pg_temp.rejects($q$update public.airvalet_portal_settings set gratuity_amounts_cents = '{50,1000}'$q$), 'amounts: below the minimum refused');
select pg_temp.check(pg_temp.rejects($q$update public.airvalet_portal_settings set gratuity_min_cents = 10$q$), 'minimum below Stripe''s $0.50 refused');
select pg_temp.check(pg_temp.rejects($q$update public.airvalet_portal_settings set gratuity_max_cents = 200000$q$), 'maximum over $1,000 refused');
update public.airvalet_portal_settings set gratuity_reference = false, gratuity_checkout_enabled = false, portal_enabled = true;

-- ── fixture ───────────────────────────────────────────────────────────────
insert into public.airvalet_sms_devices (key_hash, label, status, decided_at)
values (public.airvalet_sms_device_key_hash('sql1112_device_key_ggggggggggggggggggggggggggggggggggggggg'), 'SQL1112 iPad', 'approved', now()) on conflict do nothing;
insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status, ret, car, color, return_operator)
values (960201, 'x', now(), 'GRAT SQL', '3055556201', 'S1Q-01', 'PENDING', '12/31/2030', 'BMW X5', 'Black', 'MAKERS');
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id)
values (960201, public.airvalet_sms_normalize_phone('3055556201'), (select id from public.airvalet_sms_devices where label = 'SQL1112 iPad'), gen_random_uuid());
select public.airvalet_pass_mint(960201) as tok \gset
select pg_temp.check(length(:'tok') = 17, 'fixture token minted');

-- ── tip_in_person_cents ───────────────────────────────────────────────────
select pg_temp.check(pg_temp.rejects($q$update public.passengers set tip_in_person_cents = 0 where id = 960201$q$), 'tip_in_person_cents: 0 refused');
select pg_temp.check(pg_temp.rejects($q$update public.passengers set tip_in_person_cents = 100001 where id = 960201$q$), 'tip_in_person_cents: over $1,000 refused');
select pg_temp.check(not pg_temp.rejects($q$update public.passengers set tip_in_person_cents = 2000 where id = 960201$q$), 'tip_in_person_cents: $20 accepted');
update public.passengers set tip_in_person_cents = null where id = 960201;

-- ── view: flags off = production payload + gratuity_checkout null ─────────
select public.airvalet_portal_view(:'tok', 'sql1112-a') -> 'pass' as v \gset
select pg_temp.check((:'v'::jsonb ->> 'gratuity_url') = (select gratuity_url from public.airvalet_portal_settings), 'flags off: gratuity_url unchanged');
select pg_temp.check((:'v'::jsonb -> 'gratuity_checkout') = 'null'::jsonb, 'flags off: no checkout amounts');
select pg_temp.check(array(select k from jsonb_object_keys(:'v'::jsonb) k order by k) = array(select k from unnest(array['ticket','first_name','vehicle','status','pickup',
  'return_date','return_time','return_flight','arrival_time','pending_return','car_wash','ready_by_staff','car_wash_lead_hours','lockbox','requests_enabled',
  'chat_enabled','valet_hours','contacts','gratuity_url','terms_published','gratuity_checkout']) k order by k), 'view: the production keys + gratuity_checkout only');
select pg_temp.check(not (:'v'::jsonb ? 'passenger_id') and position('960201' in :'v') = 0, 'view: no internal id while the reference flag is off');

update public.airvalet_portal_settings set gratuity_reference = true;
select public.airvalet_portal_view(:'tok', 'sql1112-a') -> 'pass' as v \gset
select pg_temp.check((:'v'::jsonb ->> 'gratuity_url') = 'https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00?client_reference_id=pax-960201', 'reference on: the current link carries pax-<id>');
update public.airvalet_portal_settings set gratuity_reference = false, gratuity_checkout_enabled = true;
select public.airvalet_portal_view(:'tok', 'sql1112-a') -> 'pass' as v \gset
select pg_temp.check((:'v'::jsonb -> 'gratuity_checkout') = '{"amounts":[5,10,20,40,50],"min":1,"max":500}'::jsonb, 'checkout on: $5 $10 $20 $40 $50, Other $1–$500, in order');
select pg_temp.check((:'v'::jsonb ->> 'gratuity_url') = 'https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00', 'checkout on: the printed-QR link is still returned, unchanged');
-- dynamic checkout claim
select pg_temp.check(public.airvalet_portal_gratuity_checkout('AAAAAAAAAAAAAAAAA', 'sql1112-e', 2000) ->> 'state' = 'expired', 'checkout claim: unknown token → expired');
select pg_temp.check(public.airvalet_portal_gratuity_checkout(:'tok', 'sql1112-e', 99) ->> 'result' = 'INVALID', 'checkout claim: $0.99 → INVALID');
select pg_temp.check(public.airvalet_portal_gratuity_checkout(:'tok', 'sql1112-e', 50001) ->> 'result' = 'INVALID', 'checkout claim: $500.01 → INVALID');
select pg_temp.check(public.airvalet_portal_gratuity_checkout(:'tok', 'sql1112-e', null) ->> 'result' = 'INVALID', 'checkout claim: no amount → INVALID');
select public.airvalet_portal_gratuity_checkout(:'tok', 'sql1112-e', 1250) as c \gset
select pg_temp.check((:'c'::jsonb ->> 'result') = 'OK' and (:'c'::jsonb ->> 'passenger_id') = '960201' and (:'c'::jsonb ->> 'ticket') = 'S1Q-01'
  and (:'c'::jsonb ->> 'amount_cents') = '1250', 'checkout claim: OK with the server-side passenger, ticket and amount');
select public.airvalet_portal_gratuity_checkout(:'tok', 'sql1112-e', 500) from generate_series(1, 5);
select pg_temp.check(public.airvalet_portal_gratuity_checkout(:'tok', 'sql1112-e', 500) ->> 'result' = 'LIMITED', 'checkout claim: 7th session in 10 minutes → LIMITED');
select pg_temp.check((select gratuity_clicks from public.airvalet_pass_links where passenger_id = 960201 and revoked_at is null) = 6, 'checkout claim: every session counted as a gratuity click');
update public.airvalet_portal_settings set gratuity_checkout_enabled = false;
select pg_temp.check(public.airvalet_portal_gratuity_checkout(:'tok', 'sql1112-f', 2000) ->> 'result' = 'UNAVAILABLE', 'checkout claim: flag off → UNAVAILABLE');
update public.airvalet_pass_links set gratuity_clicks = 0, first_gratuity_click_at = null, last_gratuity_click_at = null where passenger_id = 960201;
delete from public.airvalet_pass_rate where bucket like 'g:%' or bucket like 'k:%';
update public.airvalet_portal_settings set gratuity_url = null;
select pg_temp.check((public.airvalet_portal_view(:'tok', 'sql1112-a') -> 'pass' ->> 'gratuity_url') is null, 'no gratuity_url: no link');
update public.airvalet_portal_settings set gratuity_url = 'https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00';

-- ── gratuity_click ────────────────────────────────────────────────────────
select open_count as opens_before from public.airvalet_pass_links where passenger_id = 960201 and revoked_at is null \gset
select pg_temp.check(public.airvalet_portal_gratuity_click('AAAAAAAAAAAAAAAAA', 'sql1112-b') ->> 'state' = 'expired', 'click: unknown token → expired');
select pg_temp.check(public.airvalet_portal_gratuity_click(:'tok', 'sql1112-b') = '{"state":"ok","result":"OK"}'::jsonb, 'click: valid token → OK');
select pg_temp.check((select gratuity_clicks = 1 and first_gratuity_click_at is not null and last_gratuity_click_at is not null and open_count = :opens_before
  from public.airvalet_pass_links where passenger_id = 960201 and revoked_at is null), 'click: counted once, opens untouched');
select public.airvalet_portal_gratuity_click(:'tok', 'sql1112-b') from generate_series(1, 4);
select pg_temp.check(public.airvalet_portal_gratuity_click(:'tok', 'sql1112-b') ->> 'result' = 'LIMITED', 'click: 6th within 10 minutes → LIMITED');
select pg_temp.check((select gratuity_clicks from public.airvalet_pass_links where passenger_id = 960201 and revoked_at is null) = 5, 'click: count capped at 5 per 10 minutes');
select pg_temp.check(not exists (select 1 from public.airvalet_pass_rate where bucket like 'g:%' and bucket !~ '^g:[0-9]+$'), 'click: throttle bucket holds the link id only (no IP, no token)');
update public.airvalet_portal_settings set portal_enabled = false;
select pg_temp.check(public.airvalet_portal_gratuity_click(:'tok', 'sql1112-c') ->> 'state' = 'expired', 'click: portal OFF → expired (dark launch)');
update public.airvalet_portal_settings set portal_enabled = true;
update public.airvalet_pass_links set revoked_at = now(), revoke_reason = 'staff' where passenger_id = 960201 and revoked_at is null;
select pg_temp.check(public.airvalet_portal_gratuity_click(:'tok', 'sql1112-d') ->> 'state' = 'expired', 'click: revoked link → expired');

select 'all 1112 checks passed' as result;
