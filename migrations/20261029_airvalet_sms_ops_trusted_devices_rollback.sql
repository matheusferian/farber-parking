-- Rollback of 20261029: back to ADMIN-only automatic approval (20261028).

begin;

create or replace function public.airvalet_sms_device_request(p_device_key text, p_label text, p_user_agent text default null)
returns table(device_id uuid, status text)
language plpgsql security definer set search_path = '' as $function$
declare
  v_hash bytea := public.airvalet_sms_device_key_hash(p_device_key);
begin
  perform public.airvalet_sms_require_ops();   -- TV_ONLY / no role → refused
  if v_hash is null then raise exception 'invalid device key' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_label, ''))) not between 2 and 40 then raise exception 'device name 2-40 chars' using errcode = '22023'; end if;
  insert into public.airvalet_sms_devices as d (key_hash, label, requested_by, user_agent)
  values (v_hash, btrim(p_label), auth.uid(), left(p_user_agent, 160))
  on conflict (key_hash) do nothing;
  if public.current_user_role() = 'ADMIN'::public.account_role then
    update public.airvalet_sms_devices d set status = 'approved', decided_by = auth.uid(), decided_at = now()
     where d.key_hash = v_hash and d.status = 'pending';
  end if;
  return query select d.id, d.status from public.airvalet_sms_devices d where d.key_hash = v_hash;
end;
$function$;

commit;
