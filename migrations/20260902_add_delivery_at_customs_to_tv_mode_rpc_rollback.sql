-- Rollback for 20260902_add_delivery_at_customs_to_tv_mode_rpc.sql
-- Restores get_tv_mode_passengers() to its prior definition (byte-for-byte
-- the body from 20260901_add_tv_mode_passengers_rpc.sql), dropping the
-- delivery_at_customs column from its return set. Safe as long as no other
-- migration has since changed this function further.

drop function if exists public.get_tv_mode_passengers();

create function public.get_tv_mode_passengers()
returns table (
  id                             bigint,
  ts                             text,
  name                           text,
  ticket                         text,
  ret                            text,
  car                            text,
  color                          text,
  loc                            text,
  status                         text,
  deldate                        text,
  delivery_type                  text,
  checkin_date                   timestamptz,
  checkout_date                  timestamptz,
  return_flight                  text,
  departure_time                 text,
  not_returning_with_makers_air  boolean,
  welcome_back_sent_at           timestamptz,
  customs_welcome_sent           boolean,
  customs_gratuity_sent          boolean,
  customs_gratuity_dismissed     boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
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
    p.customs_welcome_sent, p.customs_gratuity_sent, p.customs_gratuity_dismissed
  from public.passengers p
  order by p.id asc;
end;
$$;

revoke all on function public.get_tv_mode_passengers() from public;
grant execute on function public.get_tv_mode_passengers() to authenticated;
