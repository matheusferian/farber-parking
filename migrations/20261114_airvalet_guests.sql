-- AirValet — GUESTS (owner 2026-10-27). LOCAL ONLY until owner GO. Requires 20261113.
-- Staff-only guest profiles built from the tickets that already exist. Nothing in a
-- ticket is ever written: the guest is DERIVED from passengers at read time, plus two
-- small staff-owned tables (identity decisions and notes). The Valet Pass, the
-- Closing Report, SMS and Stripe are not touched.
--
-- Identity (conservative — wrong merges are worse than duplicates):
--   * Automatic: same phone (normalized) AND same first name (normalized: titles,
--     brackets, digits, punctuation and accents removed) = same guest. Families
--     sharing a phone stay apart; last-name typos (STEUB / STEUBE) join.
--   * No usable phone (empty, too short, 0000000, 1111111111…) = the ticket stays
--     on its own; it can only be linked by hand.
--   * Possible matches are SUGGESTED, never applied: same phone + same last name +
--     same initial (DOANALD / DONALD RIEDEL), or same full name on another phone.
--   * Three expression indexes on passengers (automatic key, phone key, normalized name) keep
--     search and profiles fast; no ticket column is added or written.
--   * ADMIN / MANAGER may merge two guests or move one ticket to another guest,
--     with a reason; every decision is kept (who, when, why) and can be undone.
--
-- Read functions (ops roles only, SECURITY DEFINER, validated on the server):
--   airvalet_guest_search(q, limit, offset)   paged list, name / phone / ticket
--   airvalet_guest_profile(key)               summary, visits, tips, notes, identity
--   airvalet_guest_activity(key)              chronological timeline
--   airvalet_guest_for_passenger(id)          ticket → guest
--   airvalet_guest_lookup_phone(phone)        check-in: guests already on this phone
-- Write functions: airvalet_guest_note_save / _delete (ops roles),
--   airvalet_guest_merge / _move_ticket / _identity_undo (ADMIN, MANAGER).
--
-- Re-runnable. Rollback (keeps every note and identity decision):
--   20261114_airvalet_guests_rollback_safe.sql

begin;
set local lock_timeout = '5s';

-- ── 1. Normalization (pure functions) ─────────────────────────────────────
create or replace function public.airvalet_guest_phone_key(p_phone text)
returns text language sql immutable set search_path = '' as $$
  select case
    when d is null then null
    when btrim(coalesce(p_phone, '')) like '+%' and left(d, 1) <> '1' and length(d) between 8 and 15 then '+' || d   -- international
    when length(n) <> 10 then null
    when n ~ '^(\d)\1{9}$' or n ~ '0{6,}' or n in ('1234567890', '0123456789') then null                           -- placeholders
    else n end
  from (select nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '') d) a,
       lateral (select case when length(a.d) = 11 and left(a.d, 1) = '1' then substr(a.d, 2) else a.d end n) b
$$;

create or replace function public.airvalet_guest_name_norm(p_name text)
returns text language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(regexp_replace(
           regexp_replace(
             regexp_replace(translate(upper(coalesce(p_name, '')), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ', 'AAAAAEEEEIIIIOOOOOUUUUCN'),
                            '\([^)]*\)', ' ', 'g'),                 -- (WORK DAY TRIP)
             '[^A-Z ]', '', 'g'),                                   -- digits, dots, apostrophes, hyphens
           '^\s*(MR|MRS|MS|MISS|DR)\s+', ''),                       -- leading title
         '\s+', ' ', 'g'))
$$;

create or replace function public.airvalet_guest_auto_key(p_id bigint, p_phone text, p_name text)
returns text language sql immutable set search_path = '' as $$
  select case when ph is null or fn = '' then 'tk:' || p_id else 'ph:' || ph || ':' || fn end
  from (select public.airvalet_guest_phone_key(p_phone) ph,
               split_part(public.airvalet_guest_name_norm(p_name), ' ', 1) fn) x
$$;

-- 'M/D/YYYY…' (legacy ts / deldate / ret) → date; anything else → null (unknown, never guessed).
create or replace function public.airvalet_guest_mdy(p text)
returns date language plpgsql immutable set search_path = '' as $$
declare m text[];
begin
  m := regexp_match(coalesce(p, ''), '^\s*(\d{1,2})/(\d{1,2})/(\d{4})');
  if m is null then return null; end if;
  return make_date(m[3]::int, m[1]::int, m[2]::int);
exception when others then return null;
end $$;

-- ── 2. Staff-owned tables ─────────────────────────────────────────────────
create table if not exists public.airvalet_guest_identity (
  id            bigint generated always as identity primary key,
  kind          text not null check (kind in ('MERGE', 'TICKET')),
  from_key      text,                       -- MERGE: the guest merged away
  passenger_id  bigint,                     -- TICKET: the ticket moved (no FK: the decision outlives the ticket)
  to_key        text not null,
  reason        text not null check (char_length(reason) between 3 and 300),
  created_by    text not null,
  created_at    timestamptz not null default now(),
  revoked_at    timestamptz,
  revoked_by    text,
  revoke_reason text,
  client_key    uuid unique,
  constraint airvalet_guest_identity_shape check ((kind = 'MERGE') = (from_key is not null) and (kind = 'TICKET') = (passenger_id is not null) and from_key is distinct from to_key)
);
create unique index if not exists airvalet_guest_identity_merge_active on public.airvalet_guest_identity (from_key) where kind = 'MERGE' and revoked_at is null;
create unique index if not exists airvalet_guest_identity_ticket_active on public.airvalet_guest_identity (passenger_id) where kind = 'TICKET' and revoked_at is null;

create table if not exists public.airvalet_guest_notes (
  id          bigint generated always as identity primary key,
  guest_key   text not null,
  passenger_ids bigint[] not null default '{}',   -- the guest's tickets when written: the note follows them if a ticket's name / phone is corrected later
  body        text not null check (char_length(btrim(body)) between 1 and 1000),
  created_by  text not null,
  created_at  timestamptz not null default now(),
  updated_by  text,
  updated_at  timestamptz,
  deleted_by  text,
  deleted_at  timestamptz,
  client_key  uuid unique
);
alter table public.airvalet_guest_notes add column if not exists passenger_ids bigint[] not null default '{}';
create index if not exists airvalet_guest_notes_key on public.airvalet_guest_notes (guest_key) where deleted_at is null;

create table if not exists public.airvalet_guest_note_revisions (
  id          bigint generated always as identity primary key,
  note_id     bigint not null references public.airvalet_guest_notes(id),
  action      text not null check (action in ('CREATE', 'EDIT', 'DELETE')),
  body        text not null,
  by_user     text not null,
  at          timestamptz not null default now(),
  client_key  uuid unique
);

do $$
declare t text;
begin
  foreach t in array array['airvalet_guest_identity', 'airvalet_guest_notes', 'airvalet_guest_note_revisions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select_ops', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.current_user_role() = any (array[''ADMIN'', ''IPAD_OPS'', ''IPHONE_OPS'', ''MANAGER'']::public.account_role[]))', t || '_select_ops', t);
  end loop;
end $$;

-- ── 3. Identity resolution (set-based; two expression indexes, no ticket data written) ──
create index if not exists passengers_guest_auto_key on public.passengers (public.airvalet_guest_auto_key(id, phone, name));
create index if not exists passengers_guest_phone_key on public.passengers (public.airvalet_guest_phone_key(phone));
create index if not exists passengers_guest_name_norm on public.passengers (public.airvalet_guest_name_norm(name));

-- Active merges, each followed to the guest that is shown (A → B → C gives A → C).
create or replace function public.airvalet_guest_merge_map()
returns table (from_key text, final_key text) language sql stable set search_path = '' as $$
  with recursive m as (select i.from_key, i.to_key from public.airvalet_guest_identity i where i.kind = 'MERGE' and i.revoked_at is null),
  f (from_key, to_key, depth) as (select m.from_key, m.to_key, 1 from m
                                  union all select f.from_key, m.to_key, f.depth + 1 from f join m on m.from_key = f.to_key where f.depth < 10)
  select distinct on (f.from_key) f.from_key, f.to_key from f order by f.from_key, f.depth desc
$$;

create or replace function public.airvalet_guest_resolve(p_key text)
returns text language sql stable set search_path = '' as $$
  select coalesce((select mm.final_key from public.airvalet_guest_merge_map() mm where mm.from_key = p_key), p_key)
$$;

-- The guest of one ticket: a manual ticket move wins, then merges, then the automatic key.
create or replace function public.airvalet_guest_key_of(p_passenger_id bigint)
returns text language sql stable set search_path = '' as $$
  select public.airvalet_guest_resolve(coalesce(
           (select t.to_key from public.airvalet_guest_identity t where t.kind = 'TICKET' and t.revoked_at is null and t.passenger_id = p.id),
           public.airvalet_guest_auto_key(p.id, p.phone, p.name)))
    from public.passengers p where p.id = p_passenger_id
$$;

-- The tickets of one guest (uses the automatic-key index).
create or replace function public.airvalet_guest_members(p_key text)
returns setof bigint language sql stable set search_path = '' as $$
  with k as (select p_key k union select mm.from_key from public.airvalet_guest_merge_map() mm where mm.final_key = p_key),
       moved as (select t.passenger_id, t.to_key from public.airvalet_guest_identity t where t.kind = 'TICKET' and t.revoked_at is null)
  select p.id from public.passengers p
   where public.airvalet_guest_auto_key(p.id, p.phone, p.name) = any (array(select k.k from k))
     and not exists (select 1 from moved where moved.passenger_id = p.id)
  union
  select moved.passenger_id from moved where public.airvalet_guest_resolve(moved.to_key) = p_key
$$;

-- When a visit happened (legacy rows: the M/D/YYYY arrival text; never the import date).
create or replace function public.airvalet_guest_visit_at(p_checkin timestamptz, p_ts text, p_created timestamptz)
returns timestamptz language sql immutable set search_path = '' as $$
  select coalesce(p_checkin, (public.airvalet_guest_mdy(p_ts)::timestamp at time zone 'America/New_York'), p_created)
$$;

create or replace function public.airvalet_guest_is_ops()
returns boolean language sql stable set search_path = '' as $$
  select coalesce(public.current_user_role() = any (array['ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER']::public.account_role[]), false)
$$;

-- One visit, in the shape every screen uses. Dates that cannot be read are null (unknown).
create or replace function public.airvalet_guest_visit(p public.passengers)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'ticket', p.ticket, 'name', p.name, 'phone', p.phone, 'status', p.status,
    'checkin', ci, 'delivered', dl, 'stay_days', case when ci is not null and dl is not null and dl >= ci then dl - ci end,
    'vehicle', nullif(btrim(concat_ws(' ', nullif(btrim(p.color), ''), nullif(btrim(p.car), ''))), ''),
    'hangar', case when p.status = 'DELIVERED' then nullif(btrim(coalesce(p.previous_delivery_location, '')), '') else nullif(btrim(coalesce(p.loc, '')), '') end,
    'return_now', nullif(btrim(coalesce(p.ret, '')), ''),
    'return_original', coalesce((select c.old_return_date from public.passenger_return_date_changes c where c.passenger_id = p.id order by c.created_at, c.id limit 1), nullif(btrim(coalesce(p.ret, '')), '')),
    'return_changes', coalesce((select jsonb_agg(jsonb_build_object('at', c.created_at, 'from', c.old_return_date, 'to', c.new_return_date, 'reason', c.comment, 'by', c.changed_by) order by c.created_at, c.id)
                                  from public.passenger_return_date_changes c where c.passenger_id = p.id), '[]'::jsonb),
    'flight', nullif(btrim(coalesce(p.return_flight, '')), ''),
    'delivery_type', p.delivery_type, 'carwash', p.carwash_status, 'released_to', p.released_to_name,
    'tip_received', p.tip_received,
    'cash_cents', (select t.amount_cents from public.airvalet_tip_records t where t.passenger_id = p.id and t.voided_at is null and t.method = 'CASH'),
    'stripe_cents', (select nullif(sum(y.amount_cents), 0) from public.payments y where y.passenger_id = p.id and y.type = 'TIP' and y.status = 'succeeded'),
    'notes', nullif(btrim(coalesce(p.obs, '')), ''))
  from (select coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts)) ci,
               coalesce((p.checkout_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.deldate)) dl) d
$$;

-- ── 4. Search (paged, on the server) ──────────────────────────────────────
-- Matches tickets (name words / phone digits / ticket prefix), then shows each
-- matching guest once, aggregated over ALL of that guest's visits.
create or replace function public.airvalet_guest_search(p_q text default '', p_limit integer default 30, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_q      text := btrim(coalesce(p_q, ''));
  v_digits text := regexp_replace(v_q, '\D', '', 'g');
  v_name   text := public.airvalet_guest_name_norm(v_q);
  v_words  text[];
  v_lim    int := least(greatest(coalesce(p_limit, 30), 1), 50);
  v_off    int := least(greatest(coalesce(p_offset, 0), 0), 2000);
  v_rows   jsonb;
  v_total  int;
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_search: not allowed' using errcode = '42501'; end if;
  if char_length(v_q) > 80 then return jsonb_build_object('rows', '[]'::jsonb, 'total', 0, 'has_more', false); end if;
  v_words := case when v_q !~ '\d' and v_name <> '' then string_to_array(v_name, ' ') end;   -- names never carry digits
  with mm as materialized (select * from public.airvalet_guest_merge_map()),
  mv as materialized (select t.passenger_id, t.to_key from public.airvalet_guest_identity t where t.kind = 'TICKET' and t.revoked_at is null),
  hits as materialized (
    select p.id, p.phone, p.name, public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) at
      from public.passengers p
     where v_q = ''
        or (char_length(v_q) >= 2 and v_q !~ '\s' and upper(btrim(coalesce(p.ticket, ''))) like upper(v_q) || '%')            -- ticket 1027-6
        or (length(v_digits) >= 3 and v_digits = regexp_replace(v_q, '[\s().+-]', '', 'g')
            and regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') like '%' || v_digits || '%')                             -- phone, any format
        or (v_words is not null and (
              (select bool_and(position(w in upper(p.name)) > 0) from unnest(v_words) w)                 -- plain names: no normalization needed
              or (upper(p.name) ~ '[^A-Z ]'                                                             -- accents, titles, punctuation: normalize
                  and (select bool_and(position(w in public.airvalet_guest_name_norm(p.name)) > 0) from unnest(v_words) w))))
     order by 3 desc, p.id desc
     limit case when v_q = '' then (v_off + v_lim) * 4 + 100 else 1500 end),   -- a very broad word: newest 1,500 tickets (type more to narrow)
  hk as (
    select coalesce(mm.final_key, b.base) gk, h.id, h.at
      from hits h left join mv on mv.passenger_id = h.id
      cross join lateral (select coalesce(mv.to_key, public.airvalet_guest_auto_key(h.id, h.phone, h.name)) base) b
      left join mm on mm.from_key = b.base),
  keys as (select hk.gk, max(hk.at) lv, max(hk.id) mid from hk group by hk.gk),
  page as (select keys.gk from keys order by keys.lv desc nulls last, keys.mid desc limit v_lim offset v_off),
  agg as (
    select page.gk guest_key, a.*
      from page cross join lateral (
        select count(*) visits,
               (array_agg(p.name order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1] name,
               (array_agg(p.phone order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1] phone,
               (array_agg(nullif(btrim(concat_ws(' ', nullif(btrim(p.color), ''), nullif(btrim(p.car), ''))), '')
                          order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1] vehicle,
               (array_agg(p.ticket order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1] last_ticket,
               max(coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts))) last_visit,
               min(coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts))) first_visit,
               bool_or(p.status in ('PENDING', 'NO DATE')) parked_now,
               max(public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at)) last_at
          from public.passengers p where p.id in (select public.airvalet_guest_members(page.gk))) a)
  select (select count(*) from keys),
         coalesce((select jsonb_agg(to_jsonb(agg) - 'last_at' order by agg.last_at desc nulls last) from agg), '[]'::jsonb)
    into v_total, v_rows;
  return jsonb_build_object('rows', v_rows, 'total', case when v_q = '' then null else v_total end, 'has_more', v_off + v_lim < v_total,
                            'broad', v_q <> '' and v_total >= 300);
end $$;

-- ── 5. Profile ────────────────────────────────────────────────────────────
create or replace function public.airvalet_guest_profile(p_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_key   text := public.airvalet_guest_resolve(btrim(coalesce(p_key, '')));
  v_ids   bigint[];
  v_visits jsonb;
  v_ph    text;
  v_res   jsonb;
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_profile: not allowed' using errcode = '42501'; end if;
  v_ids := array(select public.airvalet_guest_members(v_key));
  if cardinality(v_ids) = 0 then return jsonb_build_object('result', 'NOT_FOUND'); end if;

  select jsonb_agg(public.airvalet_guest_visit(p) order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc)
    into v_visits from public.passengers p where p.id = any (v_ids);

  select jsonb_build_object(
    'result', 'OK', 'key', v_key,
    'name', v_visits -> 0 ->> 'name',
    'names', (select jsonb_agg(distinct x ->> 'name') from jsonb_array_elements(v_visits) x),
    'phones', (select jsonb_agg(distinct x ->> 'phone') from jsonb_array_elements(v_visits) x where coalesce(x ->> 'phone', '') <> ''),
    'visits_count', jsonb_array_length(v_visits),
    'first_visit', (select min((x ->> 'checkin')::date) from jsonb_array_elements(v_visits) x),
    'last_visit', (select max((x ->> 'checkin')::date) from jsonb_array_elements(v_visits) x),
    'known_stays', (select count(*) from jsonb_array_elements(v_visits) x where x ->> 'stay_days' is not null),
    'total_days', (select sum((x ->> 'stay_days')::int) from jsonb_array_elements(v_visits) x),
    'avg_days', (select round(avg((x ->> 'stay_days')::int), 1) from jsonb_array_elements(v_visits) x),
    'parked_now', exists (select 1 from jsonb_array_elements(v_visits) x where x ->> 'status' in ('PENDING', 'NO DATE')),
    'vehicles', (select jsonb_agg(jsonb_build_object('vehicle', v, 'visits', n, 'last', l) order by l desc nulls last)
                   from (select x ->> 'vehicle' v, count(*) n, max((x ->> 'checkin')::date) l from jsonb_array_elements(v_visits) x
                          where x ->> 'vehicle' is not null group by 1) vv),
    'visits', v_visits,
    'tips', jsonb_build_object(
       'cash', coalesce((select jsonb_agg(jsonb_build_object('ticket', t.ticket, 'passenger_id', t.passenger_id, 'cents', t.amount_cents, 'at', t.recorded_at,
                                   'day', t.business_date, 'by', t.recorded_by, 'received_by', t.received_by_name, 'voided', t.voided_at is not null, 'void_reason', t.void_reason) order by t.recorded_at desc)
                          from public.airvalet_tip_records t where t.passenger_id = any (v_ids)), '[]'::jsonb),
       'stripe', coalesce((select jsonb_agg(jsonb_build_object('ticket', coalesce(y.ticket, pp.ticket), 'passenger_id', y.passenger_id, 'cents', y.amount_cents, 'at', y.created_at, 'status', y.status) order by y.created_at desc)
                            from public.payments y left join public.passengers pp on pp.id = y.passenger_id
                           where y.passenger_id = any (v_ids) and y.type = 'TIP' and y.status in ('succeeded', 'refunded')), '[]'::jsonb),
       'cash_total', (select coalesce(sum(t.amount_cents), 0) from public.airvalet_tip_records t where t.passenger_id = any (v_ids) and t.voided_at is null),
       'stripe_total', (select coalesce(sum(y.amount_cents), 0) from public.payments y where y.passenger_id = any (v_ids) and y.type = 'TIP' and y.status = 'succeeded')),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'body', n.body, 'created_by', n.created_by, 'created_at', n.created_at,
                               'updated_by', n.updated_by, 'updated_at', n.updated_at,
                               'revisions', (select jsonb_agg(jsonb_build_object('action', r.action, 'body', r.body, 'by', r.by_user, 'at', r.at) order by r.at, r.id)
                                               from public.airvalet_guest_note_revisions r where r.note_id = n.id)) order by n.created_at desc)
                        from public.airvalet_guest_notes n where n.deleted_at is null and (public.airvalet_guest_resolve(n.guest_key) = v_key or n.passenger_ids && v_ids)), '[]'::jsonb),
    'identity', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'from_key', i.from_key, 'passenger_id', i.passenger_id, 'to_key', i.to_key,
                                  'reason', i.reason, 'by', i.created_by, 'at', i.created_at, 'revoked_at', i.revoked_at, 'revoked_by', i.revoked_by) order by i.created_at desc)
                           from public.airvalet_guest_identity i
                          where public.airvalet_guest_resolve(i.to_key) = v_key or i.from_key = v_key or i.passenger_id = any (v_ids)), '[]'::jsonb),
    'can_manage_identity', public.current_user_role() in ('ADMIN', 'MANAGER'))
  into v_res;

  -- Possible matches (suggested, never applied). Both lookups use the indexes.
  v_res := v_res || jsonb_build_object('suggestions', coalesce((
    with mine as (select distinct public.airvalet_guest_name_norm(x ->> 'name') nm, public.airvalet_guest_phone_key(x ->> 'phone') ph
                    from jsonb_array_elements(v_visits) x),
         cand as (
           select public.airvalet_guest_key_of(p.id) gk, 'SAME_PHONE_SIMILAR_NAME' why
             from mine m join public.passengers p
               on m.ph is not null and position(' ' in m.nm) > 0
              and public.airvalet_guest_phone_key(p.phone) = m.ph
              and split_part(public.airvalet_guest_name_norm(p.name), ' ', 1) <> split_part(m.nm, ' ', 1)
              and left(public.airvalet_guest_name_norm(p.name), 1) = left(m.nm, 1)
              and regexp_replace(public.airvalet_guest_name_norm(p.name), '^.* ', '') = regexp_replace(m.nm, '^.* ', '')
           union
           select public.airvalet_guest_key_of(x.id), 'SAME_NAME_OTHER_PHONE'
             from mine m cross join lateral (
               select p.id from public.passengers p
                where position(' ' in m.nm) > 0 and public.airvalet_guest_name_norm(p.name) = m.nm
                  and public.airvalet_guest_phone_key(p.phone) is distinct from m.ph
                order by p.id desc limit 40) x),
         c as (select * from (select distinct on (cand.gk) cand.gk, cand.why from cand where cand.gk <> v_key order by cand.gk, cand.why) d limit 8)
    select jsonb_agg(jsonb_build_object('key', c.gk, 'why', c.why, 'name', s.name, 'phone', s.phone, 'visits', s.visits, 'last_visit', s.last_visit))
      from c cross join lateral (
        select (array_agg(p.name order by p.id desc))[1] name, (array_agg(p.phone order by p.id desc))[1] phone, count(*) visits,
               max(coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts))) last_visit
          from public.passengers p where p.id in (select public.airvalet_guest_members(c.gk))) s
  ), '[]'::jsonb));
  return v_res;
end $$;

-- ── 6. Activity timeline ──────────────────────────────────────────────────
-- source: 'system' (recorded by AirValet), 'staff' (typed or changed by the team),
-- 'guest' (sent by the guest). time_known = false when only a day is on record.
create or replace function public.airvalet_guest_activity(p_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_key text := public.airvalet_guest_resolve(btrim(coalesce(p_key, ''))); v_ids bigint[];
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_activity: not allowed' using errcode = '42501'; end if;
  v_ids := array(select public.airvalet_guest_members(v_key));
  if cardinality(v_ids) = 0 then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  return jsonb_build_object('result', 'OK', 'events', coalesce((
    select jsonb_agg(e order by (e ->> 'at') desc nulls last) from (
      -- check-in (from the ticket itself)
      select jsonb_build_object('at', coalesce(p.checkin_date, (public.airvalet_guest_mdy(p.ts)::timestamp at time zone 'America/New_York')),
             'time_known', p.checkin_date is not null, 'kind', 'CHECK_IN', 'source', 'system', 'ticket', p.ticket, 'passenger_id', p.id,
             'label', 'Checked in', 'detail', nullif(btrim(concat_ws(' ', p.color, p.car)), '')) e   -- not the location: loc is where the car is NOW
        from public.passengers p where p.id = any (v_ids) and (p.checkin_date is not null or public.airvalet_guest_mdy(p.ts) is not null)
      union all
      -- delivery known only by day (legacy deldate)
      select jsonb_build_object('at', (public.airvalet_guest_mdy(p.deldate)::timestamp at time zone 'America/New_York') + interval '12 hours', 'time_known', false,
             'kind', 'DELIVERED', 'source', 'system', 'ticket', p.ticket, 'passenger_id', p.id, 'label', 'Delivered', 'detail', null)
        from public.passengers p where p.id = any (v_ids) and p.checkout_date is null and public.airvalet_guest_mdy(p.deldate) is not null
      union all
      -- ticket history (activity_log rows linked to the ticket)
      select jsonb_build_object('at', l.created_at, 'time_known', true,
             'kind', case when l.action in ('DELIVERED', 'DELIVERED_FROM_LOCATION') then 'DELIVERED' when l.action = 'RETURN DATE' then 'RETURN_CHANGE'
                          when l.action = 'RETURN TIME' then 'RETURN_TIME' when l.action = 'FLIGHT_NOTE' then 'FLIGHT' when l.action like 'TIP CASH%' then 'TIP'
                          when l.action = 'CREATED' then 'CREATED' when l.action = 'EDITED' then 'EDIT' else 'STATUS' end,
             'source', case when l.action in ('EDITED', 'FLIGHT_NOTE', 'RETURN DATE', 'RETURN TIME') then 'staff' else 'system' end,
             'issue', l.detail ~* '(batter|jump.?start|tire|tyre|flat)',
             'ticket', l.ticket, 'passenger_id', l.passenger_id, 'label', l.action, 'detail', left(l.detail, 400), 'by', split_part(coalesce(l.changed_by, ''), '@', 1))
        from public.activity_log l where l.passenger_id = any (v_ids) and l.action <> 'CREATED'
      union all
      select jsonb_build_object('at', h.created_at, 'time_known', true, 'kind', 'MOVE', 'source', 'staff', 'ticket', h.ticket, 'passenger_id', h.passenger_id,
             'label', 'Moved', 'detail', concat_ws(' → ', nullif(h.from_location, ''), nullif(h.to_location, '')) || coalesce(' · ' || nullif(h.note, ''), ''), 'by', split_part(coalesce(h.created_by, ''), '@', 1))
        from public.vehicle_location_history h where h.passenger_id = any (v_ids) and coalesce(h.action, '') not like 'DELIVERED%'
      union all
      select jsonb_build_object('at', q.created_at, 'time_known', true, 'kind', case when q.kind = 'CAR_WASH' then 'CAR_WASH' else 'GUEST_REQUEST' end, 'source', 'guest',
             'ticket', (select p.ticket from public.passengers p where p.id = q.passenger_id), 'passenger_id', q.passenger_id,
             'label', case when q.kind = 'CAR_WASH' then 'Car wash requested' else 'Return change requested' end,
             'detail', concat_ws(' · ', to_char(q.requested_date, 'Mon FMDD'), to_char(q.requested_time, 'HH24:MI'), nullif(q.carrier, ''), nullif(q.note, ''), lower(q.status)))
        from public.airvalet_pass_requests q where q.passenger_id = any (v_ids)
      union all
      select jsonb_build_object('at', s.ready_at, 'time_known', true, 'kind', 'READY', 'source', 'staff', 'ticket', (select p.ticket from public.passengers p where p.id = s.passenger_id),
             'passenger_id', s.passenger_id, 'label', 'Marked ready', 'detail', null)
        from public.airvalet_pass_state s where s.passenger_id = any (v_ids) and s.ready_at is not null
      union all
      select jsonb_build_object('at', m.created_at, 'time_known', true, 'kind', 'MESSAGE', 'source', case when m.direction = 'inbound' then 'guest' else 'system' end,
             'ticket', coalesce(m.ticket_snapshot, (select p.ticket from public.passengers p where p.id = m.passenger_id)), 'passenger_id', m.passenger_id,
             'label', case when m.direction = 'inbound' then 'Message from guest' else 'Text sent · ' || replace(initcap(replace(m.message_type, '_', ' ')), 'Sms', 'SMS') end,
             'detail', case when m.direction = 'inbound' then left(m.body, 200) else m.status end, 'by', m.sent_by_name)
        from public.airvalet_sms_messages m where m.passenger_id = any (v_ids)
      union all
      select jsonb_build_object('at', y.created_at, 'time_known', true, 'kind', 'TIP', 'source', 'system', 'ticket', coalesce(y.ticket, (select p.ticket from public.passengers p where p.id = y.passenger_id)),
             'passenger_id', y.passenger_id, 'label', 'Stripe gratuity ' || case when y.status = 'refunded' then 'refunded' else 'confirmed' end,
             'detail', '$' || to_char(y.amount_cents / 100.0, 'FM999990.00'))
        from public.payments y where y.passenger_id = any (v_ids) and y.type = 'TIP' and y.status in ('succeeded', 'refunded')
      union all
      -- free-text note on the ticket: no time on record → shown on the check-in day
      select jsonb_build_object('at', coalesce(p.checkin_date, (public.airvalet_guest_mdy(p.ts)::timestamp at time zone 'America/New_York')), 'time_known', false,
             'kind', 'NOTE', 'source', 'staff', 'issue', p.obs ~* '(batter|jump.?start|tire|tyre|flat)', 'ticket', p.ticket, 'passenger_id', p.id,
             'label', 'Note on the ticket', 'detail', left(p.obs, 400))
        from public.passengers p where p.id = any (v_ids) and coalesce(btrim(p.obs), '') <> ''
    ) x), '[]'::jsonb));
end $$;

-- ── 7. Ticket → guest, check-in lookup ────────────────────────────────────
create or replace function public.airvalet_guest_for_passenger(p_passenger_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_key text;
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_for_passenger: not allowed' using errcode = '42501'; end if;
  v_key := public.airvalet_guest_key_of(p_passenger_id);
  if v_key is null then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  return jsonb_build_object('result', 'OK', 'key', v_key, 'visits', (select count(*) from public.airvalet_guest_members(v_key)));
end $$;

-- Check-in: guests already seen on this phone (a shared phone lists each person).
-- Only names, visit counts and the last confirmed vehicle: never return dates or consent.
create or replace function public.airvalet_guest_lookup_phone(p_phone text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_ph text := public.airvalet_guest_phone_key(p_phone);
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_lookup_phone: not allowed' using errcode = '42501'; end if;
  if v_ph is null then return jsonb_build_object('result', 'OK', 'guests', '[]'::jsonb); end if;
  return jsonb_build_object('result', 'OK', 'guests', coalesce((
    with k as (select distinct public.airvalet_guest_key_of(p.id) gk from public.passengers p
                where public.airvalet_guest_phone_key(p.phone) = v_ph)
    select jsonb_agg(x order by x ->> 'last_visit' desc nulls last) from (
      select jsonb_build_object('key', k.gk,
               'name', (array_agg(p.name order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1],
               'visits', count(*),
               'last_visit', max(coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts))),
               'car', (array_agg(nullif(btrim(p.car), '') order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1],
               'color', (array_agg(nullif(btrim(p.color), '') order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1],
               'parked_now', bool_or(p.status in ('PENDING', 'NO DATE'))) x
        from k join public.passengers p on p.id in (select public.airvalet_guest_members(k.gk))
       group by k.gk) s), '[]'::jsonb));
end $$;

-- ── 8. Notes (ops roles; every change kept) ───────────────────────────────
create or replace function public.airvalet_guest_note_save(p_guest_key text, p_note_id bigint, p_body text, p_client_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_body  text := btrim(coalesce(p_body, ''));
  v_key   text := public.airvalet_guest_resolve(btrim(coalesce(p_guest_key, '')));
  v_n     public.airvalet_guest_notes%rowtype;
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_note_save: not allowed' using errcode = '42501'; end if;
  if p_client_key is null then return jsonb_build_object('result', 'INVALID'); end if;
  if exists (select 1 from public.airvalet_guest_note_revisions r where r.client_key = p_client_key) then
    return jsonb_build_object('result', 'OK', 'duplicate', true);
  end if;
  if char_length(v_body) < 1 or char_length(v_body) > 1000 then return jsonb_build_object('result', 'INVALID'); end if;
  if p_note_id is null then
    if not exists (select 1 from public.airvalet_guest_members(v_key)) then return jsonb_build_object('result', 'NOT_FOUND'); end if;
    insert into public.airvalet_guest_notes (guest_key, passenger_ids, body, created_by, client_key)
    values (v_key, array(select public.airvalet_guest_members(v_key)), v_body, v_actor, p_client_key) returning * into v_n;
    insert into public.airvalet_guest_note_revisions (note_id, action, body, by_user, client_key) values (v_n.id, 'CREATE', v_body, v_actor, p_client_key);
  else
    select * into v_n from public.airvalet_guest_notes n where n.id = p_note_id and n.deleted_at is null for update;
    if not found then return jsonb_build_object('result', 'NOT_FOUND'); end if;
    if v_n.body = v_body then return jsonb_build_object('result', 'UNCHANGED'); end if;
    update public.airvalet_guest_notes n set body = v_body, updated_by = v_actor, updated_at = now() where n.id = v_n.id returning * into v_n;
    insert into public.airvalet_guest_note_revisions (note_id, action, body, by_user, client_key) values (v_n.id, 'EDIT', v_body, v_actor, p_client_key);
  end if;
  return jsonb_build_object('result', 'OK', 'note_id', v_n.id);
end $$;

create or replace function public.airvalet_guest_note_delete(p_note_id bigint, p_client_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown'); v_n public.airvalet_guest_notes%rowtype;
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_note_delete: not allowed' using errcode = '42501'; end if;
  if p_client_key is null then return jsonb_build_object('result', 'INVALID'); end if;
  if exists (select 1 from public.airvalet_guest_note_revisions r where r.client_key = p_client_key) then return jsonb_build_object('result', 'OK', 'duplicate', true); end if;
  select * into v_n from public.airvalet_guest_notes n where n.id = p_note_id and n.deleted_at is null for update;
  if not found then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  update public.airvalet_guest_notes n set deleted_at = now(), deleted_by = v_actor where n.id = v_n.id;   -- kept, hidden
  insert into public.airvalet_guest_note_revisions (note_id, action, body, by_user, client_key) values (v_n.id, 'DELETE', v_n.body, v_actor, p_client_key);
  return jsonb_build_object('result', 'OK');
end $$;

-- ── 9. Identity decisions (ADMIN / MANAGER; reason required; undoable) ────
create or replace function public.airvalet_guest_merge(p_from_key text, p_into_key text, p_reason text, p_client_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_from text := public.airvalet_guest_resolve(btrim(coalesce(p_from_key, '')));
  v_into text := public.airvalet_guest_resolve(btrim(coalesce(p_into_key, '')));
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if public.current_user_role() is null or public.current_user_role() not in ('ADMIN', 'MANAGER') then
    raise exception 'airvalet_guest_merge: ADMIN or MANAGER only' using errcode = '42501';
  end if;
  if p_client_key is null then return jsonb_build_object('result', 'INVALID'); end if;
  if exists (select 1 from public.airvalet_guest_identity i where i.client_key = p_client_key) then return jsonb_build_object('result', 'OK', 'duplicate', true, 'key', v_into); end if;
  if char_length(v_reason) < 3 then return jsonb_build_object('result', 'REASON_REQUIRED'); end if;
  if v_from = v_into then return jsonb_build_object('result', 'SAME_GUEST'); end if;
  if not exists (select 1 from public.airvalet_guest_members(v_from))
     or not exists (select 1 from public.airvalet_guest_members(v_into)) then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  perform pg_advisory_xact_lock(hashtext('airvalet_guest_identity'));
  insert into public.airvalet_guest_identity (kind, from_key, to_key, reason, created_by, client_key) values ('MERGE', v_from, v_into, v_reason, v_actor, p_client_key);
  return jsonb_build_object('result', 'OK', 'key', v_into);
end $$;

-- Move one ticket to another guest (p_to_key) or to a new guest of its own (null).
create or replace function public.airvalet_guest_move_ticket(p_passenger_id bigint, p_to_key text, p_reason text, p_client_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_to text;
begin
  if public.current_user_role() is null or public.current_user_role() not in ('ADMIN', 'MANAGER') then
    raise exception 'airvalet_guest_move_ticket: ADMIN or MANAGER only' using errcode = '42501';
  end if;
  if p_client_key is null then return jsonb_build_object('result', 'INVALID'); end if;
  if exists (select 1 from public.airvalet_guest_identity i where i.client_key = p_client_key) then return jsonb_build_object('result', 'OK', 'duplicate', true); end if;
  if char_length(v_reason) < 3 then return jsonb_build_object('result', 'REASON_REQUIRED'); end if;
  if not exists (select 1 from public.passengers p where p.id = p_passenger_id) then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  if p_to_key is null then v_to := 'g:' || gen_random_uuid()::text;
  else
    v_to := public.airvalet_guest_resolve(btrim(p_to_key));
    if not exists (select 1 from public.airvalet_guest_members(v_to)) then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('airvalet_guest_identity'));
  update public.airvalet_guest_identity i set revoked_at = now(), revoked_by = v_actor, revoke_reason = 'Replaced: ' || v_reason
   where i.kind = 'TICKET' and i.passenger_id = p_passenger_id and i.revoked_at is null;
  insert into public.airvalet_guest_identity (kind, passenger_id, to_key, reason, created_by, client_key) values ('TICKET', p_passenger_id, v_to, v_reason, v_actor, p_client_key);
  return jsonb_build_object('result', 'OK', 'key', public.airvalet_guest_resolve(v_to));
end $$;

create or replace function public.airvalet_guest_identity_undo(p_identity_id bigint, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown'); v_reason text := btrim(coalesce(p_reason, ''));
begin
  if public.current_user_role() is null or public.current_user_role() not in ('ADMIN', 'MANAGER') then
    raise exception 'airvalet_guest_identity_undo: ADMIN or MANAGER only' using errcode = '42501';
  end if;
  if char_length(v_reason) < 3 then return jsonb_build_object('result', 'REASON_REQUIRED'); end if;
  update public.airvalet_guest_identity i set revoked_at = now(), revoked_by = v_actor, revoke_reason = v_reason
   where i.id = p_identity_id and i.revoked_at is null;
  if not found then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  return jsonb_build_object('result', 'OK');
end $$;

-- ── 10. Grants: staff app only; nothing for anon (the Valet Pass never sees guests) ──
do $$
declare f text;
begin
  foreach f in array array[
    'airvalet_guest_search(text,integer,integer)', 'airvalet_guest_profile(text)', 'airvalet_guest_activity(text)',
    'airvalet_guest_for_passenger(bigint)', 'airvalet_guest_lookup_phone(text)',
    'airvalet_guest_note_save(text,bigint,text,uuid)', 'airvalet_guest_note_delete(bigint,uuid)',
    'airvalet_guest_merge(text,text,text,uuid)', 'airvalet_guest_move_ticket(bigint,text,text,uuid)', 'airvalet_guest_identity_undo(bigint,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['airvalet_guest_merge_map()', 'airvalet_guest_key_of(bigint)', 'airvalet_guest_members(text)', 'airvalet_guest_visit(public.passengers)', 'airvalet_guest_resolve(text)', 'airvalet_guest_is_ops()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

commit;
