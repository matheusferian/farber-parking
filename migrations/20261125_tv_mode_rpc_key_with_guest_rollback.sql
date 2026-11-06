-- Rollback of 20261125: production definition read 2026-11-06.
begin;
set local lock_timeout = '5s';
drop function public.get_tv_mode_passengers();
CREATE FUNCTION public.get_tv_mode_passengers()
 RETURNS TABLE(id bigint, ts text, name text, ticket text, ret text, car text, color text, loc text, status text, deldate text, delivery_type text, checkin_date timestamp with time zone, checkout_date timestamp with time zone, return_flight text, departure_time text, not_returning_with_makers_air boolean, welcome_back_sent_at timestamp with time zone, customs_welcome_sent boolean, customs_gratuity_sent boolean, customs_gratuity_dismissed boolean, delivery_at_customs boolean, carwash_status text, return_operator text, customs_exception_requested_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role public.account_role;
begin
  if auth.uid() is null then
    raise exception 'get_tv_mode_passengers: authentication required';
  end if;

  v_role := public.current_user_role();
  if v_role is null or v_role not in (
    'ADMIN',
    'IPAD_OPS',
    'IPHONE_OPS',
    'TV_ONLY',
    'MANAGER'
  ) then
    raise exception 'get_tv_mode_passengers: role not permitted';
  end if;

  return query
  select
    p.id, p.ts, p.name, p.ticket, p.ret, p.car, p.color, p.loc, p.status,
    p.deldate, p.delivery_type, p.checkin_date, p.checkout_date, p.return_flight,
    p.departure_time, p.not_returning_with_makers_air, p.welcome_back_sent_at,
    p.customs_welcome_sent, p.customs_gratuity_sent, p.customs_gratuity_dismissed,
    p.delivery_at_customs, p.carwash_status, p.return_operator, p.customs_exception_requested_at
  from public.passengers p
  order by p.id asc;
end;
$function$
;
revoke all on function public.get_tv_mode_passengers() from public;
grant execute on function public.get_tv_mode_passengers() to anon, authenticated, service_role;
commit;
