-- TV Follow-Up note with a photo (owner 2026-11-24: Nancy Peel 1107-5, the tow truck took the car).
-- One note per active ticket, shown on the TV "Return Date Follow-Up" page. The photo is NOT the valet pass photo:
-- the passenger never sees it. Gone by itself when the ticket is DELIVERED / ARCHIVED.
create table if not exists public.airvalet_tv_followup (
  passenger_id bigint primary key references public.passengers(id) on delete cascade,
  note         text not null check (char_length(note) between 1 and 80),
  detail       text check (detail is null or char_length(detail) <= 80),
  image_b64    text check (image_b64 is null or (left(image_b64, 4) = '/9j/' and char_length(image_b64) <= 400000)),
  created_at   timestamptz not null default now(),
  created_by   text
);
alter table public.airvalet_tv_followup enable row level security;
revoke all on public.airvalet_tv_followup from public, anon, authenticated;
grant all on public.airvalet_tv_followup to service_role;

create or replace function public.airvalet_tv_followups() returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER','TV_ONLY']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('passenger_id', f.passenger_id, 'note', f.note, 'detail', f.detail, 'at', f.created_at, 'image_b64', f.image_b64) order by f.created_at)
      from public.airvalet_tv_followup f join public.passengers p on p.id = f.passenger_id
     where p.status in ('PENDING', 'NO DATE')), '[]'::jsonb);
end $fn$;
revoke all on function public.airvalet_tv_followups() from public, anon;
grant execute on function public.airvalet_tv_followups() to authenticated, service_role;
