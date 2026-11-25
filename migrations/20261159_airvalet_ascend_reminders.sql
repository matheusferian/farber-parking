-- Ascend reminders (owner 2026-11-25): flights LEAVING with Ascend are easy to forget (another building), so staff get
-- a text the day before, 2 h and 1 h before, and the Dashboard shows a bar with "On my way".
-- Flights come from the Makers robot (read-only). Nothing here touches passengers or their texts.

create table if not exists public.airvalet_ascend_flights (
  id           bigint generated always as identity primary key,
  service_date date not null,
  flight       text not null check (flight ~ '^9[0-9]{3}$'),
  route        text not null check (char_length(route) between 3 and 12),
  dest         text not null check (char_length(dest) between 2 and 40),
  dep_time     time not null,
  prev_time    time,                    -- the time it had before the last change
  changed_at   timestamptz,
  pax          integer not null default 0 check (pax between 0 and 99),
  tail         text,
  first_seen   timestamptz not null default now(),
  seen_at      timestamptz not null default now(),
  missing_at   timestamptz,             -- first reading without it
  gone_at      timestamptz,             -- a second reading, 20+ min later, also without it
  went_at      timestamptz,
  went_by      text,
  unique (service_date, flight, route)
);
alter table public.airvalet_ascend_flights enable row level security;
revoke all on public.airvalet_ascend_flights from public, anon, authenticated;
grant all on public.airvalet_ascend_flights to service_role;

-- Who gets the texts. Phones live only here (never in the repo, never sent to a browser).
create table if not exists public.airvalet_ascend_contacts (
  id         bigint generated always as identity primary key,
  name       text not null check (char_length(name) between 1 and 40),
  phone_e164 text not null unique check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  active     boolean not null default true,
  consent_at timestamptz not null default now(),
  consent_by text
);
alter table public.airvalet_ascend_contacts enable row level security;
revoke all on public.airvalet_ascend_contacts from public, anon, authenticated;
grant all on public.airvalet_ascend_contacts to service_role;

-- One row per text: the key makes every reminder go out once.
create table if not exists public.airvalet_ascend_texts (
  id         bigint generated always as identity primary key,
  key        text not null,
  contact_id bigint not null references public.airvalet_ascend_contacts(id) on delete cascade,
  kind       text not null check (kind in ('TOMORROW', 'H2', 'H1', 'CHANGED', 'GONE')),
  body       text not null,
  status     text not null default 'CLAIMED' check (status in ('CLAIMED', 'SENT', 'BLOCKED', 'FAILED', 'UNKNOWN')),
  sid        text,
  error_code text,
  flight_ids bigint[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (key, contact_id)
);
alter table public.airvalet_ascend_texts enable row level security;
revoke all on public.airvalet_ascend_texts from public, anon, authenticated;
grant all on public.airvalet_ascend_texts to service_role;

-- The robot's reading of one day: upsert what it saw, and only after two readings without a flight call it gone.
create or replace function public.airvalet_ascend_sync(p_date date, p_flights jsonb, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_seen integer := 0; v_gone integer := 0;
begin
  if jsonb_typeof(p_flights) is distinct from 'array' then raise exception 'airvalet_ascend_sync: array expected'; end if;
  with f as (
    -- The same number on two planes the same day (seen 11/21): the later one is kept as "route#2".
    select x->>'flight' flight, (x->>'route') || case when n > 1 then '#' || n else '' end route, left(coalesce(nullif(x->>'dest', ''), x->>'route'), 40) dest,
           (x->>'time')::time dep, least(greatest(coalesce((x->>'pax')::integer, 0), 0), 99) pax, left(x->>'tail', 12) tail
      from (select x, row_number() over (partition by x->>'flight', x->>'route' order by (x->>'time')::time) n from jsonb_array_elements(p_flights) x
             where x->>'flight' ~ '^9[0-9]{3}$' and x->>'time' ~ '^\d{1,2}:\d{2}' and char_length(coalesce(x->>'route', '')) between 3 and 9) q
     where n <= 9
  ), up as (
    insert into public.airvalet_ascend_flights as a (service_date, flight, route, dest, dep_time, pax, tail, first_seen, seen_at)
    select p_date, flight, route, dest, dep, pax, tail, p_now, p_now from f
    on conflict (service_date, flight, route) do update set
      dest = excluded.dest, pax = excluded.pax, tail = excluded.tail, seen_at = p_now, missing_at = null, gone_at = null,
      prev_time  = case when a.dep_time <> excluded.dep_time then a.dep_time else a.prev_time end,
      changed_at = case when a.dep_time <> excluded.dep_time then p_now else a.changed_at end,
      -- A moved flight is a new trip to Ascend: "On my way" for the old time no longer counts.
      went_at = case when a.dep_time <> excluded.dep_time then null else a.went_at end,
      went_by = case when a.dep_time <> excluded.dep_time then null else a.went_by end,
      dep_time = excluded.dep_time
    returning 1)
  select count(*) into v_seen from up;
  -- Not in this reading. Already left (time passed) = nothing to do.
  update public.airvalet_ascend_flights a set
      missing_at = coalesce(a.missing_at, p_now),
      gone_at = case when a.missing_at is not null and a.missing_at <= p_now - interval '20 minutes' then coalesce(a.gone_at, p_now) else a.gone_at end
   where a.service_date = p_date and a.seen_at < p_now and a.gone_at is null
     and (a.service_date + a.dep_time) at time zone 'America/New_York' > p_now;
  get diagnostics v_gone = row_count;
  delete from public.airvalet_ascend_flights where service_date < (p_now at time zone 'America/New_York')::date - 60;
  delete from public.airvalet_ascend_texts where created_at < p_now - interval '60 days';
  return jsonb_build_object('seen', v_seen, 'missing', v_gone);
end $fn$;
revoke all on function public.airvalet_ascend_sync(date, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.airvalet_ascend_sync(date, jsonb, timestamptz) to service_role;

create or replace function public.airvalet_ascend_t12(p time) returns text language sql immutable set search_path = '' as
$fn$ select to_char(p, 'FMHH12:MI AM') $fn$;
revoke all on function public.airvalet_ascend_t12(time) from public, anon;
grant execute on function public.airvalet_ascend_t12(time) to authenticated, service_role;

-- Which texts are due right now. Each (key, contact) is claimed once, so a minute tick never repeats a text.
-- A text the claim already covered is also never sent late: H2 only from 2 h to 1 h before, H1 only in the last hour.
create or replace function public.airvalet_ascend_claim(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_et timestamp := p_now at time zone 'America/New_York'; v_today date := (p_now at time zone 'America/New_York')::date; v jsonb;
begin
  if v_et::time < time '04:30' then return '[]'::jsonb; end if;
  with fl as (
    select a.*, extract(epoch from ((a.service_date + a.dep_time) at time zone 'America/New_York' - p_now)) / 60 as mins
      from public.airvalet_ascend_flights a where a.service_date in (v_today, v_today + 1)
  ), tom as (
    -- The day before: from 3 PM to 9 PM (the robot reads tomorrow at 3 PM and 7 PM). A new list = a new text.
    select 'TOMORROW' kind, 'TOM:' || (v_today + 1) || ':' || md5(string_agg(flight || route || dep_time, ',' order by dep_time, flight, route)) key,
           string_agg(public.airvalet_ascend_t12(dep_time) || ' ' || dest || ', ' || pax || case when pax = 1 then ' guest' else ' guests' end, chr(10) order by dep_time, flight, route) list,
           array_agg(id) ids
      from fl where service_date = v_today + 1 and gone_at is null
     having count(*) > 0 and v_et::time between time '15:00' and time '21:00'
  ), grp as (
    select dep_time, min(mins) mins, string_agg(dest || ', ' || pax || case when pax = 1 then ' guest' else ' guests' end, chr(10) order by flight, route) list, array_agg(id) ids
      from fl where service_date = v_today and gone_at is null and went_at is null group by dep_time
  ), due as (
    select kind, key, 'Farber Parking: ASCEND TOMORROW' ||
           case when exists (select 1 from public.airvalet_ascend_texts t where t.key like 'TOM:' || (v_today + 1) || ':%' and t.key <> tom.key) then ' (updated)' else '' end
           || chr(10) || list body, ids from tom
    union all
    select 'H2', 'H2:' || v_today || ':' || dep_time, 'Farber Parking: ASCEND at ' || public.airvalet_ascend_t12(dep_time) || chr(10) || list || chr(10) || 'Leaves in 2 hours.', ids
      from grp where mins > 60.5 and mins <= 120.5
    union all
    select 'H1', 'H1:' || v_today || ':' || dep_time, 'Farber Parking: GO TO ASCEND NOW' || chr(10) || public.airvalet_ascend_t12(dep_time) || ' ' || list || chr(10)
           || 'Leaves in ' || case when mins >= 55 then '1 hour.' else greatest(1, round(mins))::text || ' min.' end, ids
      from grp where mins > 2 and mins <= 60.5
    union all
    -- Today's flight moved after someone was already told about it.
    select 'CHANGED', 'CHG:' || id || ':' || dep_time, 'Farber Parking: ASCEND CHANGED' || chr(10) || dest || ' now ' || public.airvalet_ascend_t12(dep_time) || ' (was ' || public.airvalet_ascend_t12(prev_time) || ')', array[id]
      from fl where service_date = v_today and gone_at is null and prev_time is not null and changed_at > p_now - interval '30 minutes' and mins > 2
       and exists (select 1 from public.airvalet_ascend_texts t where fl.id = any (t.flight_ids))
    union all
    select 'GONE', 'GONE:' || id || ':' || dep_time, 'Farber Parking: ASCEND ' || public.airvalet_ascend_t12(dep_time) || ' ' || dest || ' is no longer on the Makers list.', array[id]
      from fl where service_date = v_today and gone_at > p_now - interval '30 minutes' and mins > 2
       and exists (select 1 from public.airvalet_ascend_texts t where fl.id = any (t.flight_ids))
  ), ins as (
    insert into public.airvalet_ascend_texts (key, contact_id, kind, body, flight_ids)
    select d.key, c.id, d.kind, d.body, d.ids from due d cross join public.airvalet_ascend_contacts c where c.active
    on conflict (key, contact_id) do nothing
    returning id, contact_id, body)
  select coalesce(jsonb_agg(jsonb_build_object('id', ins.id, 'phone', c.phone_e164, 'body', ins.body) order by ins.id), '[]'::jsonb) into v
    from ins join public.airvalet_ascend_contacts c on c.id = ins.contact_id;
  return v;
end $fn$;
revoke all on function public.airvalet_ascend_claim(timestamptz) from public, anon, authenticated;
grant execute on function public.airvalet_ascend_claim(timestamptz) to service_role;

-- Dashboard bar: today's flights still to leave, and tomorrow's from 3 PM on.
create or replace function public.airvalet_ascend_board(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = '' as $fn$
declare v_et timestamp := p_now at time zone 'America/New_York'; v_today date := (p_now at time zone 'America/New_York')::date;
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER','TV_ONLY']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'today', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'time', public.airvalet_ascend_t12(a.dep_time), 'dest', a.dest, 'pax', a.pax, 'went', a.went_at is not null, 'by', a.went_by,
        'mins', round(extract(epoch from ((a.service_date + a.dep_time) at time zone 'America/New_York' - p_now)) / 60)) order by a.dep_time, a.flight)
      from public.airvalet_ascend_flights a where a.service_date = v_today and a.gone_at is null and v_today + a.dep_time > v_et - interval '5 minutes'), '[]'::jsonb),
    'tomorrow', case when v_et::time < time '15:00' then '[]'::jsonb else coalesce((select jsonb_agg(public.airvalet_ascend_t12(a.dep_time) order by a.dep_time, a.flight)
      from public.airvalet_ascend_flights a where a.service_date = v_today + 1 and a.gone_at is null), '[]'::jsonb) end);
end $fn$;
revoke all on function public.airvalet_ascend_board(timestamptz) from public, anon;
grant execute on function public.airvalet_ascend_board(timestamptz) to authenticated, service_role;

-- "On my way" / Undo on the Dashboard.
create or replace function public.airvalet_ascend_went(p_id bigint, p_on boolean, p_name text default null) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.airvalet_ascend_flights a set went_at = case when p_on then coalesce(a.went_at, now()) end,
         went_by = case when p_on then coalesce(a.went_by, left(nullif(trim(p_name), ''), 40)) end
   where a.id = p_id and a.service_date = (now() at time zone 'America/New_York')::date;
  return jsonb_build_object('result', case when found then 'OK' else 'NOT_FOUND' end);
end $fn$;
revoke all on function public.airvalet_ascend_went(bigint, boolean, text) from public, anon;
grant execute on function public.airvalet_ascend_went(bigint, boolean, text) to authenticated, service_role;
