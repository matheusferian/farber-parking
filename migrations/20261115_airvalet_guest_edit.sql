-- AirValet — Guests v88: edit guest details, vehicles and visits (owner 2026-10-27). LOCAL ONLY
-- until owner GO. Requires 20261114 (v87). Identity rules are NOT changed: a guest is still
-- derived from its tickets (phone + first name), nothing is merged by an edit.
--
--   1. airvalet_guest_profiles: the corrected name / phone of a guest. The tickets keep what was
--      typed (changing a ticket's phone would revoke its Valet Pass link and is never done here).
--      Shown in Guests, found by search and by the check-in phone lookup.
--   2. airvalet_guest_changes: every change made from Guests — old value, new value, who, when,
--      ticket. Ticket edits are also written to the ticket history (activity_log), like the
--      ticket card does.
--   3. airvalet_guest_profile_save(key, name, phone)       ops roles; corrected details
--      airvalet_guest_visit_update(ticket, changes)          ops roles; vehicle, color, return
--          flight, arrival time, notes of ONE ticket. Never name, phone, return date, status,
--          money, consent: those keep their own screens and rules.
--      airvalet_guest_vehicle_update(key, tickets[], car, color)  ops roles; the same vehicle
--          correction on the tickets the staff ticked (all of that guest), nothing else.
--   4. search / profile / check-in lookup (v87) show the corrected details; their v87
--      definitions are restored exactly by the safe rollback.
-- Re-runnable. Rollback (keeps every correction and its history): 20261115_airvalet_guest_edit_rollback_safe.sql

begin;
set local lock_timeout = '5s';

create table if not exists public.airvalet_guest_profiles (
  guest_key     text primary key,
  passenger_ids bigint[] not null default '{}',     -- the guest's tickets when edited: the details follow them
  display_name  text check (display_name is null or char_length(display_name) between 2 and 80),
  phone         text check (phone is null or char_length(phone) between 8 and 20),
  updated_by    text not null,
  updated_at    timestamptz not null default now()
);
create table if not exists public.airvalet_guest_changes (
  id          bigint generated always as identity primary key,
  action_key  uuid not null,                        -- one save = one key (a double tap saves once)
  guest_key   text,
  passenger_id bigint,                              -- the ticket, when a ticket was changed
  ticket      text,
  field       text not null check (field in ('guest_name', 'guest_phone', 'car', 'color', 'return_flight', 'departure_time', 'obs')),
  old_value   text,
  new_value   text,
  changed_by  text not null,
  changed_at  timestamptz not null default now()
);
create index if not exists airvalet_guest_changes_key on public.airvalet_guest_changes (guest_key);
create index if not exists airvalet_guest_changes_pax on public.airvalet_guest_changes (passenger_id);
create index if not exists airvalet_guest_changes_action on public.airvalet_guest_changes (action_key);
do $$
declare t text;
begin
  foreach t in array array['airvalet_guest_profiles', 'airvalet_guest_changes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select_ops', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.current_user_role() = any (array[''ADMIN'', ''IPAD_OPS'', ''IPHONE_OPS'', ''MANAGER'']::public.account_role[]))', t || '_select_ops', t);
  end loop;
end $$;

-- The corrected details of a guest (latest), found by key (incl. merges) or by its tickets.
create or replace function public.airvalet_guest_profile_row(p_key text)
returns setof public.airvalet_guest_profiles language sql stable set search_path = '' as $$
  select gp.* from public.airvalet_guest_profiles gp
   where public.airvalet_guest_resolve(gp.guest_key) = p_key
      or gp.passenger_ids && array(select public.airvalet_guest_members(p_key))
   order by gp.updated_at desc limit 1
$$;

create or replace function public.airvalet_guest_profile_save(p_key text, p_name text, p_phone text, p_client_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_key   text := public.airvalet_guest_resolve(btrim(coalesce(p_key, '')));
  v_name  text := nullif(upper(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'))), '');
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_old   public.airvalet_guest_profiles%rowtype;
  v_ids   bigint[];
  v_tick_name text; v_tick_phone text;
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_profile_save: not allowed' using errcode = '42501'; end if;
  if p_client_key is null then return jsonb_build_object('result', 'INVALID'); end if;
  if exists (select 1 from public.airvalet_guest_changes c where c.action_key = p_client_key) then return jsonb_build_object('result', 'OK', 'duplicate', true); end if;
  v_ids := array(select public.airvalet_guest_members(v_key));
  if cardinality(v_ids) = 0 then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  if v_name is null or char_length(v_name) < 2 or char_length(v_name) > 80 or v_name !~ '[A-Z]' then return jsonb_build_object('result', 'INVALID_NAME'); end if;
  if v_phone is not null and public.airvalet_guest_phone_key(v_phone) is null then return jsonb_build_object('result', 'INVALID_PHONE'); end if;
  perform pg_advisory_xact_lock(hashtext('airvalet_guest_profile:' || v_key));
  select * into v_old from public.airvalet_guest_profile_row(v_key);
  select (array_agg(p.name order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1],
         (array_agg(p.phone order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1]
    into v_tick_name, v_tick_phone from public.passengers p where p.id = any (v_ids);
  if coalesce(v_old.display_name, v_tick_name) is not distinct from v_name
     and coalesce(v_old.phone, v_tick_phone) is not distinct from coalesce(v_phone, v_old.phone, v_tick_phone) then
    return jsonb_build_object('result', 'UNCHANGED');
  end if;
  if coalesce(v_old.display_name, v_tick_name) is distinct from v_name then
    insert into public.airvalet_guest_changes (action_key, guest_key, field, old_value, new_value, changed_by)
    values (p_client_key, v_key, 'guest_name', coalesce(v_old.display_name, v_tick_name), v_name, v_actor);
  end if;
  if v_phone is not null and coalesce(v_old.phone, v_tick_phone) is distinct from v_phone then
    insert into public.airvalet_guest_changes (action_key, guest_key, field, old_value, new_value, changed_by)
    values (p_client_key, v_key, 'guest_phone', coalesce(v_old.phone, v_tick_phone), v_phone, v_actor);
  end if;
  delete from public.airvalet_guest_profiles gp where gp.guest_key = v_old.guest_key and gp.guest_key <> v_key;   -- the details now live under the current key
  insert into public.airvalet_guest_profiles (guest_key, passenger_ids, display_name, phone, updated_by, updated_at)
  values (v_key, v_ids, v_name, coalesce(v_phone, v_old.phone), v_actor, now())
  on conflict (guest_key) do update set passenger_ids = excluded.passenger_ids, display_name = excluded.display_name, phone = excluded.phone,
                                        updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return jsonb_build_object('result', 'OK');
end $$;

-- One ticket: vehicle, color, return flight, arrival time, notes. Audited twice (ticket history + Guests).
create or replace function public.airvalet_guest_apply_ticket_change(p_action uuid, p_key text, p_id bigint, p_field text, p_new text, p_actor text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_p public.passengers%rowtype; v_old text; v_label text;
begin
  select * into v_p from public.passengers p where p.id = p_id for update;
  v_old := case p_field when 'car' then v_p.car when 'color' then v_p.color when 'return_flight' then v_p.return_flight
                        when 'departure_time' then v_p.departure_time when 'obs' then v_p.obs end;
  if coalesce(v_old, '') = coalesce(p_new, '') then return false; end if;
  if p_field = 'car' then update public.passengers set car = p_new where id = p_id;
  elsif p_field = 'color' then update public.passengers set color = p_new where id = p_id;
  elsif p_field = 'return_flight' then update public.passengers set return_flight = p_new where id = p_id;
  elsif p_field = 'departure_time' then update public.passengers set departure_time = p_new where id = p_id;
  elsif p_field = 'obs' then update public.passengers set obs = p_new where id = p_id;
  else raise exception 'field % not editable here', p_field; end if;
  v_label := case p_field when 'car' then 'Vehicle' when 'color' then 'Color' when 'return_flight' then 'Return Flight' when 'departure_time' then 'Departure Time' else 'Notes' end;
  insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by, field_name, old_value, new_value)
  values (to_char(now() at time zone 'America/New_York', 'MM/DD/YYYY, HH12:MI:SS AM'), 'EDITED', v_p.name, v_p.ticket, v_p.loc,
          v_label || ' changed: ' || coalesce(nullif(v_old, ''), '—') || ' → ' || coalesce(nullif(p_new, ''), '—') || ' | From Passengers', p_id, p_actor, p_field, v_old, p_new);
  insert into public.airvalet_guest_changes (action_key, guest_key, passenger_id, ticket, field, old_value, new_value, changed_by)
  values (p_action, p_key, p_id, v_p.ticket, p_field, v_old, p_new, p_actor);
  return true;
end $$;
revoke all on function public.airvalet_guest_apply_ticket_change(uuid, text, bigint, text, text, text) from public, anon, authenticated;

create or replace function public.airvalet_guest_visit_update(p_passenger_id bigint, p_changes jsonb, p_client_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_key text; k text; v text; n int := 0;
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_visit_update: not allowed' using errcode = '42501'; end if;
  if p_client_key is null or jsonb_typeof(p_changes) is distinct from 'object' then return jsonb_build_object('result', 'INVALID'); end if;
  if exists (select 1 from public.airvalet_guest_changes c where c.action_key = p_client_key) then return jsonb_build_object('result', 'OK', 'duplicate', true); end if;
  if not exists (select 1 from public.passengers p where p.id = p_passenger_id) then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  for k in select jsonb_object_keys(p_changes) loop
    if k not in ('car', 'color', 'return_flight', 'departure_time', 'obs') then return jsonb_build_object('result', 'FIELD_NOT_ALLOWED', 'field', k); end if;
  end loop;
  -- validate everything before writing anything
  if p_changes ? 'car' and char_length(btrim(coalesce(p_changes ->> 'car', ''))) not between 2 and 60 then return jsonb_build_object('result', 'INVALID', 'field', 'car'); end if;
  if p_changes ? 'color' and char_length(btrim(coalesce(p_changes ->> 'color', ''))) > 30 then return jsonb_build_object('result', 'INVALID', 'field', 'color'); end if;
  if p_changes ? 'return_flight' and char_length(btrim(coalesce(p_changes ->> 'return_flight', ''))) > 20 then return jsonb_build_object('result', 'INVALID', 'field', 'return_flight'); end if;
  if p_changes ? 'departure_time' and coalesce(btrim(p_changes ->> 'departure_time'), '') !~ '^(([01]?[0-9]|2[0-3]):[0-5][0-9])?$' then return jsonb_build_object('result', 'INVALID', 'field', 'departure_time'); end if;
  if p_changes ? 'obs' and char_length(coalesce(p_changes ->> 'obs', '')) > 500 then return jsonb_build_object('result', 'INVALID', 'field', 'obs'); end if;
  v_key := public.airvalet_guest_key_of(p_passenger_id);
  for k, v in select key, value from jsonb_each_text(p_changes) loop
    v := nullif(btrim(coalesce(v, '')), '');
    if k = 'car' then v := upper(v); end if;
    if k = 'return_flight' then v := upper(v); end if;
    if public.airvalet_guest_apply_ticket_change(p_client_key, v_key, p_passenger_id, k, v, v_actor) then n := n + 1; end if;
  end loop;
  return jsonb_build_object('result', case when n = 0 then 'UNCHANGED' else 'OK' end, 'changed', n);
end $$;

-- The same vehicle correction on the tickets the staff ticked (they must all be this guest's).
create or replace function public.airvalet_guest_vehicle_update(p_key text, p_passenger_ids bigint[], p_car text, p_color text, p_client_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor text := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), 'unknown');
  v_key text := public.airvalet_guest_resolve(btrim(coalesce(p_key, '')));
  v_car text := upper(nullif(btrim(coalesce(p_car, '')), ''));
  v_color text := nullif(btrim(coalesce(p_color, '')), '');
  v_ids bigint[]; i bigint; n int := 0; t int := 0;
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_vehicle_update: not allowed' using errcode = '42501'; end if;
  if p_client_key is null then return jsonb_build_object('result', 'INVALID'); end if;
  if exists (select 1 from public.airvalet_guest_changes c where c.action_key = p_client_key) then return jsonb_build_object('result', 'OK', 'duplicate', true); end if;
  if v_car is null or char_length(v_car) not between 2 and 60 or char_length(coalesce(v_color, '')) > 30 then return jsonb_build_object('result', 'INVALID'); end if;
  if coalesce(cardinality(p_passenger_ids), 0) = 0 or cardinality(p_passenger_ids) > 50 then return jsonb_build_object('result', 'NO_VISITS'); end if;
  v_ids := array(select public.airvalet_guest_members(v_key));
  if exists (select 1 from unnest(p_passenger_ids) x where x <> all (v_ids)) then return jsonb_build_object('result', 'NOT_THIS_GUEST'); end if;
  foreach i in array (select array_agg(distinct x order by x) from unnest(p_passenger_ids) x) loop
    t := 0;
    if public.airvalet_guest_apply_ticket_change(p_client_key, v_key, i, 'car', v_car, v_actor) then t := 1; end if;
    if public.airvalet_guest_apply_ticket_change(p_client_key, v_key, i, 'color', v_color, v_actor) then t := 1; end if;
    n := n + t;
  end loop;
  return jsonb_build_object('result', case when n = 0 then 'UNCHANGED' else 'OK' end, 'tickets_changed', n);
end $$;

-- ── v87 functions with the corrected details (restored exactly by the safe rollback) ──
CREATE OR REPLACE FUNCTION public.airvalet_guest_search(p_q text DEFAULT ''::text, p_limit integer DEFAULT 30, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        or p.id in (select unnest(gp.passenger_ids) from public.airvalet_guest_profiles gp                -- v88: corrected guest details
                     where (v_words is not null and (select bool_and(position(w in public.airvalet_guest_name_norm(gp.display_name)) > 0) from unnest(v_words) w))
                        or (length(v_digits) >= 3 and regexp_replace(coalesce(gp.phone, ''), '\D', '', 'g') like '%' || v_digits || '%'))
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
               coalesce((select gp.display_name from public.airvalet_guest_profile_row(page.gk) gp),
                        (array_agg(p.name order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1]) name,
               coalesce((select gp.phone from public.airvalet_guest_profile_row(page.gk) gp),
                        (array_agg(p.phone order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1]) phone,
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
end $function$;

CREATE OR REPLACE FUNCTION public.airvalet_guest_profile(p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
                          where public.airvalet_guest_resolve(i.to_key) = v_key or i.from_key = v_key or i.passenger_id = any (v_ids)
                             or (i.kind = 'DISTINCT' and v_key in (public.airvalet_guest_resolve(i.from_key), public.airvalet_guest_resolve(i.to_key)))), '[]'::jsonb),
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
         c as (select * from (select distinct on (cand.gk) cand.gk, cand.why from cand where cand.gk <> v_key
                                and not public.airvalet_guest_is_distinct(cand.gk, v_key) order by cand.gk, cand.why) d limit 8)
    select jsonb_agg(jsonb_build_object('key', c.gk, 'why', c.why, 'name', s.name, 'phone', s.phone, 'visits', s.visits, 'last_visit', s.last_visit))
      from c cross join lateral (
        select (array_agg(p.name order by p.id desc))[1] name, (array_agg(p.phone order by p.id desc))[1] phone, count(*) visits,
               max(coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts))) last_visit
          from public.passengers p where p.id in (select public.airvalet_guest_members(c.gk))) s
  ), '[]'::jsonb));
  -- v88: corrected guest details (the tickets keep what was typed) + every change made from Guests.
  v_res := v_res || jsonb_build_object(
    'name_on_tickets', v_res ->> 'name',
    'profile', (select jsonb_build_object('name', gp.display_name, 'phone', gp.phone, 'updated_by', gp.updated_by, 'updated_at', gp.updated_at)
                  from public.airvalet_guest_profile_row(v_key) gp),
    'changes', coalesce((select jsonb_agg(jsonb_build_object('field', c.field, 'old', c.old_value, 'new', c.new_value, 'by', c.changed_by, 'at', c.changed_at,
                                   'ticket', c.ticket, 'passenger_id', c.passenger_id) order by c.changed_at desc, c.id desc)
                           from (select * from public.airvalet_guest_changes c where public.airvalet_guest_resolve(c.guest_key) = v_key or c.passenger_id = any (v_ids)
                                  order by c.changed_at desc, c.id desc limit 100) c), '[]'::jsonb));
  if v_res -> 'profile' ->> 'name' is not null then v_res := jsonb_set(v_res, '{name}', to_jsonb(v_res -> 'profile' ->> 'name')); end if;
  return v_res;
end $function$;

CREATE OR REPLACE FUNCTION public.airvalet_guest_lookup_phone(p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ph text := public.airvalet_guest_phone_key(p_phone);
begin
  if not public.airvalet_guest_is_ops() then raise exception 'airvalet_guest_lookup_phone: not allowed' using errcode = '42501'; end if;
  if v_ph is null then return jsonb_build_object('result', 'OK', 'guests', '[]'::jsonb); end if;
  return jsonb_build_object('result', 'OK', 'guests', coalesce((
    with k as (select public.airvalet_guest_key_of(p.id) gk from public.passengers p
                where public.airvalet_guest_phone_key(p.phone) = v_ph
               union                                                                                   -- v88: corrected phone
               select public.airvalet_guest_resolve(gp.guest_key) from public.airvalet_guest_profiles gp where public.airvalet_guest_phone_key(gp.phone) = v_ph)
    select jsonb_agg(x order by x ->> 'last_visit' desc nulls last) from (
      select jsonb_build_object('key', k.gk,
               'name', coalesce((select gp.display_name from public.airvalet_guest_profile_row(k.gk) gp),
                                (array_agg(p.name order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1]),
               'visits', count(*),
               'last_visit', max(coalesce((p.checkin_date at time zone 'America/New_York')::date, public.airvalet_guest_mdy(p.ts))),
               'car', (array_agg(nullif(btrim(p.car), '') order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1],
               'color', (array_agg(nullif(btrim(p.color), '') order by public.airvalet_guest_visit_at(p.checkin_date, p.ts, p.created_at) desc, p.id desc))[1],
               'parked_now', bool_or(p.status in ('PENDING', 'NO DATE'))) x
        from k join public.passengers p on p.id in (select public.airvalet_guest_members(k.gk))
       group by k.gk) s), '[]'::jsonb));
end $function$;

do $$
declare f text;
begin
  foreach f in array array['airvalet_guest_profile_save(text,text,text,uuid)', 'airvalet_guest_visit_update(bigint,jsonb,uuid)', 'airvalet_guest_vehicle_update(text,bigint[],text,text,uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  execute 'revoke all on function public.airvalet_guest_profile_row(text) from public, anon, authenticated';
end $$;

commit;
