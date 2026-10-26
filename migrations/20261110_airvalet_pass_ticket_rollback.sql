-- Rollback of 20261110_airvalet_pass_ticket.sql: the production definition of
-- airvalet_portal_view before the change (md5 de1d56c295286e0a34b67d766c6f670c). Grants are unchanged by
-- create or replace.

begin;
set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.airvalet_portal_view(p_token text, p_client text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r        record;
  v_p      public.passengers%rowtype;
  v_st     public.airvalet_pass_state%rowtype;
  v_set    public.airvalet_portal_settings%rowtype;
  v_req    public.airvalet_pass_requests%rowtype;
  v_wash   public.airvalet_pass_requests%rowtype;
  v_pickup text;
  v_status text;
  v_ret_at timestamptz;
  v_today  date := (now() at time zone 'America/New_York')::date;
  v_wash_state text;
  v_vehicle text;
begin
  select * into r from public.airvalet_portal_resolve(p_token, p_client);
  if r.o_state <> 'ok' then return jsonb_build_object('state', r.o_state); end if;

  select * into v_p   from public.passengers p where p.id = r.o_passenger_id;
  select * into v_st  from public.airvalet_pass_state s where s.passenger_id = v_p.id;
  select * into v_set from public.airvalet_portal_settings;
  select * into v_req from public.airvalet_pass_requests q
   where q.passenger_id = v_p.id and q.kind = 'RETURN_CHANGE' and q.status = 'PENDING';
  select * into v_wash from public.airvalet_pass_requests q
   where q.passenger_id = v_p.id and q.kind = 'CAR_WASH' and q.status = 'PENDING';

  update public.airvalet_pass_links l
     set first_opened_at = coalesce(l.first_opened_at, now()), last_opened_at = now(), open_count = l.open_count + 1
   where l.id = r.o_link_id;

  -- P3: Customs only when the team confirmed it. MAKERS + approved exception
  -- (delivery_at_customs) is a staff decision already; ASCEND needs the
  -- explicit confirmation. Until then: no pickup place is promised.
  v_pickup := case
    when v_p.return_operator = 'MAKERS' and coalesce(v_p.delivery_at_customs, false) then 'CUSTOMS_EXCEPTION'
    when v_p.return_operator = 'MAKERS' then 'HANGAR_19'
    when v_p.return_operator = 'ASCEND' and v_st.customs_confirmed_at is not null then 'CUSTOMS_ASCEND'
    when v_p.return_operator = 'ASCEND' then 'TO_BE_CONFIRMED'
    else 'OTHER' end;
  v_status := case
    -- car waiting at Customs until the gratuity link goes out (owner 2026-10-25)
    when v_p.status = 'DELIVERED' and v_p.delivery_type = 'CUSTOMS' and coalesce(v_p.customs_gratuity_sent, false) = false then 'CUSTOMS_CONFIRMED'
    when v_p.status = 'DELIVERED' then 'DELIVERED'
    when v_pickup in ('CUSTOMS_EXCEPTION', 'CUSTOMS_ASCEND') and v_st.ready_at is not null then 'CUSTOMS_CONFIRMED'
    when v_st.ready_at is not null then 'READY'
    -- HANGAR 19 on the return day (owner 2026-10-25)
    when v_pickup = 'HANGAR_19' and upper(btrim(coalesce(v_p.loc, ''))) = 'HANGAR 19'
         and (public.airvalet_return_at(v_p.ret, null) at time zone 'America/New_York')::date = (now() at time zone 'America/New_York')::date then 'READY'
    else 'PARKED' end;

  v_ret_at := public.airvalet_return_at(v_p.ret, v_p.ret_time);
  v_wash_state := case
    when v_p.status not in ('PENDING', 'NO DATE') or v_st.ready_at is not null then 'NONE'
    when v_wash.id is not null then 'REQUESTED'
    when v_p.carwash_status = 'CARWASH' then 'SCHEDULED'
    when v_p.carwash_status = 'SEND_PRICE' then 'PRICE_PENDING'
    when v_p.carwash_status = 'WASHED' then 'DONE'
    when v_ret_at is not null and v_ret_at - now() >= make_interval(hours => v_set.car_wash_lead_hours) then 'REQUEST'
    else 'CONTACT' end;
  v_vehicle := nullif(btrim(concat_ws(' ', nullif(btrim(coalesce(v_p.color, '')), ''), nullif(btrim(coalesce(v_p.car, '')), ''))), '');

  return jsonb_build_object(
    'state', 'ok',
    'pass', jsonb_build_object(
      'first_name', nullif(initcap(split_part(btrim(coalesce(v_p.name, '')), ' ', 1)), ''),
      'vehicle', v_vehicle,
      'status', v_status,
      'pickup', v_pickup,
      'return_date', nullif(btrim(coalesce(v_p.ret, '')), ''),
      'return_time', to_char(v_p.ret_time, 'HH24:MI'),
      'return_flight', nullif(upper(btrim(coalesce(v_p.return_flight, ''))), ''),
      'arrival_time', case when btrim(coalesce(v_p.departure_time, '')) ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' then btrim(v_p.departure_time) end,
      'pending_return', case when v_req.id is null then null else jsonb_build_object(
          'reason', v_req.reason, 'date', v_req.requested_date, 'time', to_char(v_req.requested_time, 'HH24:MI'),
          'carrier', v_req.carrier, 'created_at', v_req.created_at) end,
      'car_wash', v_wash_state,
      'ready_by_staff', v_st.ready_at is not null,
      'car_wash_lead_hours', v_set.car_wash_lead_hours,
      'lockbox', case when v_st.lockbox_authorized_at is null  -- audit 1105: lockbox
                       or v_p.status in ('DELIVERED', 'ARCHIVED') or v_status in ('DELIVERED', 'CUSTOMS_CONFIRMED')
                       or nullif(btrim(coalesce(v_p.pickup_auth_name, '')), '') is not null
                       or (public.airvalet_return_at(v_p.ret, null) is not null
                           and (public.airvalet_return_at(v_p.ret, null) at time zone 'America/New_York')::date < v_today)
                     then null else jsonb_build_object(
          'authorized', true,
          'reveal_on', v_st.lockbox_reveal_on,
          'code', case when v_st.lockbox_reveal_on is not null and v_today >= v_st.lockbox_reveal_on then v_st.lockbox_code end) end,
      'requests_enabled', v_set.requests_enabled and v_p.status in ('PENDING', 'NO DATE'),
      'chat_enabled', v_set.chat_enabled and v_p.status <> 'ARCHIVED',
      'valet_hours', v_set.valet_hours,
      'contacts', jsonb_strip_nulls(jsonb_build_object(
          'valet_phone', v_set.valet_phone, 'text_phone', v_set.text_phone, 'reservations_phone', v_set.reservations_phone)),
      'gratuity_url', v_set.gratuity_url,
      'terms_published', v_set.terms_published
    ));
end $function$;

commit;
