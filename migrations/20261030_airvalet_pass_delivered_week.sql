-- Valet pass after delivery (owner 2026-10-25):
--  * the link keeps working while the car is parked, however long (unchanged);
--  * it stops 7 days AFTER DELIVERY (was 3 hours), so a returning guest never
--    opens an old trip by mistake; undoing a delivery clears that end date;
--  * the delivered text may carry the link: minting is allowed for a DELIVERED
--    ticket (enrolled tickets only) and that link also ends 7 days after delivery.
begin;

create or replace function public.airvalet_pass_on_passenger_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'DELIVERED' and old.status is distinct from 'DELIVERED' then
    update public.airvalet_pass_links l
       set expires_at = now() + interval '7 days'
     where l.passenger_id = new.id and l.revoked_at is null;
  end if;
  if old.status = 'DELIVERED' and new.status in ('PENDING', 'NO DATE') then
    update public.airvalet_pass_links l set expires_at = null
     where l.passenger_id = new.id and l.revoked_at is null;
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
$$;

create or replace function public.airvalet_pass_mint(p_passenger_id bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_status text;
  v_token  text;
begin
  select p.status into v_status from public.passengers p where p.id = p_passenger_id for update;
  if not found or v_status not in ('PENDING', 'NO DATE', 'DELIVERED') then return null; end if;
  -- Only tickets enrolled in the Twilio program (new check-ins) get a link.
  if not exists (select 1 from public.airvalet_sms_enrollments e where e.passenger_id = p_passenger_id) then return null; end if;
  update public.airvalet_pass_links l set revoked_at = now(), revoke_reason = 'rotated'
   where l.passenger_id = p_passenger_id and l.revoked_at is null;
  loop
    v_token := public.airvalet_pass_new_token();
    begin
      insert into public.airvalet_pass_links (token_hash, passenger_id, expires_at)
      values (extensions.digest(v_token, 'sha256'), p_passenger_id,
              case when v_status = 'DELIVERED' then now() + interval '7 days' end);
      return v_token;
    exception when unique_violation then
      null; -- 2^-101 collision: draw again
    end;
  end loop;
end;
$function$;

-- One-time fix of links left with the old 3-hour end: a car back in custody
-- (delivery undone) gets no end date; a car delivered under the old rule whose
-- link has not ended yet gets the new 7-day end.
update public.airvalet_pass_links l set expires_at = null
  from public.passengers p
 where p.id = l.passenger_id and l.revoked_at is null and l.expires_at is not null
   and p.status in ('PENDING', 'NO DATE');
update public.airvalet_pass_links l set expires_at = coalesce(p.checkout_date, now()) + interval '7 days'
  from public.passengers p
 where p.id = l.passenger_id and l.revoked_at is null and l.expires_at > now()
   and p.status = 'DELIVERED';

commit;
