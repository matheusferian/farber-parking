-- Rollback of 20261122: production definition read 2026-11-06.
begin;
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION public.airvalet_sms_record_consent(p_passenger_id bigint, p_disclosure_version text, p_device_key text, p_staff_name text DEFAULT NULL::text)
 RETURNS TABLE(enrolled boolean, reason text, consent_id uuid, phone_e164 text, opted_out boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_phone  text;
  v_device uuid;
  v_id     uuid;
  v_pax    public.passengers%rowtype;
begin
  perform public.airvalet_sms_require_ops();
  if coalesce(btrim(p_disclosure_version), '') = '' then
    raise exception 'disclosure version required' using errcode = '22023';
  end if;
  select d.id into v_device from public.airvalet_sms_devices d
   where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key) and d.status = 'approved';
  select * into v_pax from public.passengers p where p.id = p_passenger_id for update;
  if not found then
    return query select false, 'PASSENGER_NOT_FOUND'::text, null::uuid, null::text, null::boolean; return;
  end if;
  v_phone := public.airvalet_sms_normalize_phone(v_pax.phone);
  if v_device is null then
    return query select false, 'DEVICE_NOT_AUTHORIZED'::text, null::uuid, v_phone, null::boolean; return;
  elsif exists (select 1 from public.airvalet_sms_enrollments e where e.passenger_id = p_passenger_id) then
    return query select true, 'ALREADY_ENROLLED'::text, (select e.consent_id from public.airvalet_sms_enrollments e where e.passenger_id = p_passenger_id), v_phone,
      coalesce((select o.opted_out from public.airvalet_sms_opt_outs o where o.phone_e164 = v_phone), false); return;
  elsif not public.airvalet_sms_ticket_eligible(p_passenger_id) then
    return query select false, 'TICKET_NOT_ELIGIBLE'::text, null::uuid, v_phone, null::boolean; return;
  elsif v_pax.created_at < now() - interval '2 hours' then
    return query select false, 'CHECKIN_WINDOW_CLOSED'::text, null::uuid, v_phone, null::boolean; return;
  elsif v_phone is null then
    return query select false, 'INVALID_PHONE'::text, null::uuid, null::text, null::boolean; return;
  end if;
  insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method, disclosure_version, recorded_by)
  values (v_phone, p_passenger_id, 'granted', 'checkin_attendant', left(p_disclosure_version, 40), auth.uid())
  returning id into v_id;
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id, staff_name)
  values (p_passenger_id, v_phone, v_device, v_id, left(btrim(p_staff_name), 60));
  update public.airvalet_sms_devices d set last_seen_at = now() where d.id = v_device;
  -- A previous STOP stays in force until the passenger texts START.
  return query select true, 'ENROLLED'::text, v_id, v_phone,
    coalesce((select o.opted_out from public.airvalet_sms_opt_outs o where o.phone_e164 = v_phone), false);
end;
$function$
;
commit;
