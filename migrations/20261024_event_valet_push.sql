-- Event Valet: Web Push subscriptions for operator alerts (installed app on the
-- operator's iPhone). Owner request 2026-10-23. Only event_valet_* touched.
-- Rollback: 20261024_event_valet_push_rollback.sql
begin;

create table public.event_valet_push_subs (
  id          bigint generated always as identity primary key,
  event_id    text not null references public.event_valet_events(id),
  endpoint    text not null unique check (endpoint ~ '^https://'),
  p256dh      text not null,
  auth        text not null,
  user_id     uuid default auth.uid(),
  label       text,
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz,
  failures    int not null default 0
);
alter table public.event_valet_push_subs enable row level security;
revoke all on public.event_valet_push_subs from public, anon, authenticated;
grant all on public.event_valet_push_subs to service_role;

create or replace function public.event_valet_push_subscribe(p_event text, p_endpoint text, p_p256dh text, p_auth text, p_label text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or coalesce(p_p256dh,'') !~ '^[A-Za-z0-9_-]{80,100}$'
     or coalesce(p_auth,'') !~ '^[A-Za-z0-9_-]{16,32}$' then
    raise exception 'INVALID_SUBSCRIPTION' using errcode = '22023';
  end if;
  insert into public.event_valet_push_subs (event_id, endpoint, p256dh, auth, label)
  values (p_event, p_endpoint, p_p256dh, p_auth, left(p_label, 60))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, failures = 0,
     user_id = auth.uid(), label = excluded.label, event_id = excluded.event_id;
  return jsonb_build_object('ok', true, 'devices', (select count(*) from public.event_valet_push_subs where event_id = p_event));
end $$;

revoke all on function public.event_valet_push_subscribe(text, text, text, text, text) from public, anon;
grant execute on function public.event_valet_push_subscribe(text, text, text, text, text) to authenticated;

commit;
