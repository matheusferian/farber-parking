-- LOCAL DB tests for 20261030_airvalet_pass_delivered_week.sql (rolled back).
\set ON_ERROR_STOP 1
begin;
create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin if cond is distinct from true then raise exception 'FAIL: %', label; end if; raise notice 'ok  %', label; end $$;
create function pg_temp.days(p bigint) returns numeric language sql as $$
  select round(extract(epoch from expires_at - now()) / 86400, 2) from public.airvalet_pass_links where passenger_id = p and revoked_at is null $$;

insert into public.passengers (id, ts, checkin_date, name, phone, ticket, status) values
  (920001, 'x', now() - interval '120 days', 'LONG STAY', '3055550901', 'X-1', 'PENDING'),
  (920002, 'x', now(), 'NOT ENROLLED', '3055550902', 'X-2', 'PENDING');
insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id) select 920001, '+13055550901', (select id from public.airvalet_sms_devices limit 1), (select id from public.airvalet_sms_consents limit 1);
select pg_temp.check(public.airvalet_pass_mint(920001) is not null, 'enrolled parked car gets a link');
select pg_temp.check((select expires_at is null from public.airvalet_pass_links where passenger_id = 920001 and revoked_at is null), 'parked (even 120 days): link has no end date');
update public.passengers set status = 'DELIVERED', checkout_date = now() where id = 920001;
select pg_temp.check(pg_temp.days(920001) between 6.99 and 7.01, 'delivered → link ends 7 days later');
update public.passengers set status = 'PENDING', checkout_date = null where id = 920001;
select pg_temp.check((select expires_at is null from public.airvalet_pass_links where passenger_id = 920001 and revoked_at is null), 'delivery undone → back to no end date');
update public.passengers set status = 'DELIVERED', checkout_date = now() where id = 920001;
create temp table old_link as select id from public.airvalet_pass_links where passenger_id = 920001 and revoked_at is null;
select pg_temp.check(public.airvalet_pass_mint(920001) is not null, 'delivered text can mint a link (enrolled ticket)');
select pg_temp.check(pg_temp.days(920001) between 6.99 and 7.01, 'link minted after delivery also ends in 7 days');
select pg_temp.check((select revoke_reason = 'rotated' from public.airvalet_pass_links where id = (select id from old_link)), 'previous link rotated (one active link)');
select pg_temp.check((select count(*) = 1 from public.airvalet_pass_links where passenger_id = 920001 and revoked_at is null), 'exactly one active link');
update public.passengers set status = 'DELIVERED' where id = 920002;
select pg_temp.check(public.airvalet_pass_mint(920002) is null, 'not enrolled (older check-in) → no link, even delivered');
update public.airvalet_pass_links set expires_at = now() - interval '1 second' where passenger_id = 920001 and revoked_at is null;
select pg_temp.check((select (public.airvalet_portal_view(
  (select null::text), null)) is not null), 'portal view still callable');
update public.passengers set status = 'ARCHIVED' where id = 920001;
select pg_temp.check(not exists (select 1 from public.airvalet_pass_links where passenger_id = 920001 and revoked_at is null), 'archive revokes the link');
rollback;
