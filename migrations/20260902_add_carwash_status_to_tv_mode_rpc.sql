-- Carwash status — expose the new field to TV Mode's dedicated RPC.
--
-- get_tv_mode_passengers() is TV_ONLY's only read path to passengers
-- (base-table RLS blocks that role from selecting the table directly).
-- Without this migration, TV's Carwash/Send Price Follow-Up alerts would
-- silently never see carwash_status (always undefined -> falsy).
--
-- Adds exactly one column (carwash_status) to the function's return
-- table and select list. Everything else is byte-for-byte identical to
-- the prior definition (…_to_tv_mode_rpc.sql, the delivery_at_customs one).

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
  customs_gratuity_dismissed     boolean,
  delivery_at_customs            boolean,
  carwash_status                 text
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
    p.customs_welcome_sent, p.customs_gratuity_sent, p.customs_gratuity_dismissed,
    p.delivery_at_customs, p.carwash_status
  from public.passengers p
  order by p.id asc;
end;
$$;

revoke all on function public.get_tv_mode_passengers() from public;
grant execute on function public.get_tv_mode_passengers() to authenticated;
