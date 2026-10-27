-- SAFE rollback of 20261115_airvalet_guest_edit.sql: the v88 edit functions go and search /
-- profile / check-in lookup are restored to their exact v87 definitions. KEPT: every corrected
-- guest detail (airvalet_guest_profiles) and every change record (airvalet_guest_changes); the
-- ticket corrections already saved stay on the tickets (each one is in the ticket history).
-- Run AFTER the app is back on v87. Turn back on: re-run the migration.
begin;
set local lock_timeout = '5s';

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
end $function$;

drop function if exists public.airvalet_guest_profile_save(text, text, text, uuid);
drop function if exists public.airvalet_guest_visit_update(bigint, jsonb, uuid, text);
drop function if exists public.airvalet_guest_vehicle_update(text, bigint[], text, text, uuid, text);
drop function if exists public.airvalet_guest_apply_ticket_change(uuid, text, bigint, text, text, text, text);
drop function if exists public.airvalet_guest_profile_row(text);
drop function if exists public.airvalet_guest_visit_closed(text);
drop function if exists public.airvalet_guest_is_manager();
commit;
