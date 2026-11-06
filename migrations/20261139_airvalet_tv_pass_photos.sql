-- TV v4 (owner 2026-11-06): the car photo staff upload to the valet pass (e.g. the car left at Customs)
-- shows as a small square on the guest's card on the TV. Read-only. Ops roles and TV_ONLY; only the
-- passengers asked for (max 60) that are not archived. p_with_image = false lists who has a photo and
-- when it was taken (cheap poll); true returns the JPEG (base64) for the ids the TV does not have yet.
begin;
set local lock_timeout = '5s';
create or replace function public.airvalet_tv_pass_photos(p_ids bigint[], p_with_image boolean default false)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER','TV_ONLY']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 then return '[]'::jsonb; end if;
  if cardinality(p_ids) > 60 then raise exception 'too many ids' using errcode = '22023'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('passenger_id', ph.passenger_id, 'at', ph.created_at)
             || case when p_with_image then jsonb_build_object('image_b64', ph.image_b64, 'mime', ph.mime) else '{}'::jsonb end)
      from public.airvalet_pass_photos ph
      join public.passengers p on p.id = ph.passenger_id
     where ph.passenger_id = any (p_ids) and p.status <> 'ARCHIVED'), '[]'::jsonb);
end $function$;
revoke all on function public.airvalet_tv_pass_photos(bigint[], boolean) from public, anon;
grant execute on function public.airvalet_tv_pass_photos(bigint[], boolean) to authenticated;
commit;
