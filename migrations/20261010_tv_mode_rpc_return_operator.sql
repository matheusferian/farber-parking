-- TV Mode RPC: also return return_operator + customs_exception_requested_at
-- so TV computes the pickup place with the same central helper
-- (pickupLocation() in utils.js) as every other screen.
-- LOCAL ONLY until owner GO. Requires 20261010_add_passenger_return_operator.sql.
-- Only two columns are appended; body, role checks, ordering and grants are
-- byte-for-byte the production version (read 2026-10-09). The return type
-- changes, so the function is dropped and recreated in one transaction.

begin;

drop function if exists public.get_tv_mode_passengers();

CREATE OR REPLACE FUNCTION "public"."get_tv_mode_passengers"() RETURNS TABLE("id" bigint, "ts" "text", "name" "text", "ticket" "text", "ret" "text", "car" "text", "color" "text", "loc" "text", "status" "text", "deldate" "text", "delivery_type" "text", "checkin_date" timestamp with time zone, "checkout_date" timestamp with time zone, "return_flight" "text", "departure_time" "text", "not_returning_with_makers_air" boolean, "welcome_back_sent_at" timestamp with time zone, "customs_welcome_sent" boolean, "customs_gratuity_sent" boolean, "customs_gratuity_dismissed" boolean, "delivery_at_customs" boolean, "carwash_status" "text", "return_operator" "text", "customs_exception_requested_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;

ALTER FUNCTION public.get_tv_mode_passengers() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_tv_mode_passengers() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_tv_mode_passengers() TO anon;
GRANT ALL ON FUNCTION public.get_tv_mode_passengers() TO authenticated;
GRANT ALL ON FUNCTION public.get_tv_mode_passengers() TO service_role;

commit;
