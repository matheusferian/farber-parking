-- Delivery at Customs — expose the new flag to TV Mode's dedicated RPC.
--
-- get_tv_mode_passengers() (20260901_add_tv_mode_passengers_rpc.sql) is
-- TV_ONLY's only read path to passengers (base-table RLS blocks that role
-- from selecting the table directly), and it enumerates an explicit
-- least-privilege column list rather than `select *`. Without this
-- migration, TV Mode's Move to Hangar 19 / Move to Customs reminder would
-- silently never see delivery_at_customs (always undefined -> falsy),
-- even though the Dashboard (which reads the table directly) would.
--
-- Adds exactly one column (delivery_at_customs) to the function's return
-- table and select list. Every other column, the role allowlist, and all
-- other behavior are byte-for-byte identical to the prior definition.
--
-- Postgres refuses `create or replace function` when the OUT-parameter
-- row type changes ("cannot change return type of existing function"), so
-- this drops the function first, then recreates it immediately with the
-- widened return table.

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
  delivery_at_customs            boolean
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
    p.delivery_at_customs
  from public.passengers p
  order by p.id asc;
end;
$$;

revoke all on function public.get_tv_mode_passengers() from public;
grant execute on function public.get_tv_mode_passengers() to authenticated;
