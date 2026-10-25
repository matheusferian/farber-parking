-- Rollback of 20261030: back to the prod versions captured 2026-10-25 (3-hour end after delivery; no link for DELIVERED).
begin;
CREATE OR REPLACE FUNCTION public.airvalet_pass_on_passenger_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status = 'DELIVERED' and old.status is distinct from 'DELIVERED' then
    update public.airvalet_pass_links l
       set expires_at = least(coalesce(new.checkout_date, now()), now()) + interval '3 hours'
     where l.passenger_id = new.id and l.revoked_at is null and l.expires_at is null;
  end if;
  if new.status = 'ARCHIVED' and old.status is distinct from 'ARCHIVED' then
    update public.airvalet_pass_links l set revoked_at = now(), revoke_reason = 'archived'
     where l.passenger_id = new.id and l.revoked_at is null;
  end if;
  if new.phone is distinct from old.phone then
    update public.airvalet_pass_links l set revoked_at = now(), revoke_reason = 'phone_changed'
     where l.passenger_id = new.id and l.revoked_at is null;
  end if;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.airvalet_pass_mint(p_passenger_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_status text;
  v_token  text;
begin
  select p.status into v_status from public.passengers p where p.id = p_passenger_id for update;
  if not found or v_status not in ('PENDING', 'NO DATE') then return null; end if;
  -- Only tickets enrolled in the Twilio program (new check-ins) get a link.
  if not exists (select 1 from public.airvalet_sms_enrollments e where e.passenger_id = p_passenger_id) then return null; end if;
  update public.airvalet_pass_links l set revoked_at = now(), revoke_reason = 'rotated'
   where l.passenger_id = p_passenger_id and l.revoked_at is null;
  loop
    v_token := public.airvalet_pass_new_token();
    begin
      insert into public.airvalet_pass_links (token_hash, passenger_id)
      values (extensions.digest(v_token, 'sha256'), p_passenger_id);
      return v_token;
    exception when unique_violation then
      null; -- 2^-101 collision: draw again
    end;
  end loop;
end;
$function$
;
commit;
