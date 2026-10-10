-- Rollback for 20261011_return_reviews_include_sms.sql: back to the
-- Return/Pickup view (legacy iOS instructions only). Run BEFORE rolling back
-- the SMS migration.
begin;

create or replace view public.airvalet_return_reviews with (security_invoker = true) as
with sent as (
  select i.passenger_id, i.place, i.sent_at as at, 'legacy_ios'::text as source
    from public.airvalet_return_instructions i
), latest as (
  select distinct on (s.passenger_id) s.passenger_id, s.place, s.at, s.source
    from sent s where s.place is not null
   order by s.passenger_id, s.at desc
)
select p.id as passenger_id, p.name, p.ticket, p.status,
       public.airvalet_departure_operator(p.ticket) as departure_operator,
       p.return_operator,
       public.airvalet_pickup_location(p.return_operator, p.delivery_at_customs) as current_place,
       l.place as instructions_place, l.at as instructions_at, l.source as instructions_source,
       'Return changed - passenger may have old instructions'::text as reason
  from public.passengers p
  join latest l on l.passenger_id = p.id
 where p.status in ('PENDING', 'NO DATE')
   and l.place is distinct from public.airvalet_pickup_location(p.return_operator, p.delivery_at_customs)
   and not exists (
     select 1 from public.airvalet_return_review_acks a
      where a.passenger_id = p.id and a.instructions_at = l.at
        and a.return_operator is not distinct from p.return_operator);

revoke all on public.airvalet_return_reviews from public, anon, authenticated;
grant select on public.airvalet_return_reviews to authenticated, service_role;

commit;
