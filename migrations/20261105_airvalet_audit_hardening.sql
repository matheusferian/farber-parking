-- Full-system audit 2026-10-25, hardening (owner GO required before prod).
-- 1. Passenger pass: the lockbox code stayed visible after a Customs delivery
--    (display status CUSTOMS_CONFIRMED is not 'DELIVERED') and with no end date.
--    Hide it once the car left custody, after the return day, and whenever a
--    different pickup person is authorized. Add ready_by_staff so the pass only
--    says "A/C running" when staff actually marked the car ready.
-- 2. Passenger chat: only show messages to/from the passenger's current phone,
--    so a correction of a wrong number does not show the stranger's history.
-- 3. Closing reports: a FINALIZED report can no longer be edited, and the tip
--    figures of a closed report are frozen. ADMIN keeps a correction path.
--    finalized_by is stamped from the session.
-- 4. passengers: no direct DELETE from the client. The app already deletes
--    through delete_passenger_with_log(), which writes the Activity Log entry.
-- 5. Stripe tip totals are no longer readable with the public anon key.
-- 6. activity_log.changed_by is stamped from the session for staff accounts.
-- 7. set_user_role: the last-admin guard counts only active ADMIN accounts.
-- 8. Texting: the delivered text also carries each passenger's own link, so a
--    second companion on the same phone gets it too (same rule as the welcome).
begin;

-- 1. Portal pass view
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('audit 1105: lockbox' in v) = 0 then
    v := replace(v,
      '''lockbox'', case when v_st.lockbox_authorized_at is null or v_status = ''DELIVERED'' then null else',
      '''lockbox'', case when v_st.lockbox_authorized_at is null  -- audit 1105: lockbox' || chr(10) ||
      '                       or v_p.status in (''DELIVERED'', ''ARCHIVED'') or v_status in (''DELIVERED'', ''CUSTOMS_CONFIRMED'')' || chr(10) ||
      '                       or nullif(btrim(coalesce(v_p.pickup_auth_name, '''')), '''') is not null' || chr(10) ||
      '                       or (public.airvalet_return_at(v_p.ret, null) is not null' || chr(10) ||
      '                           and (public.airvalet_return_at(v_p.ret, null) at time zone ''America/New_York'')::date < v_today)' || chr(10) ||
      '                     then null else');
    v := replace(v,
      '''car_wash'', v_wash_state,',
      '''car_wash'', v_wash_state,' || chr(10) ||
      '      ''ready_by_staff'', v_st.ready_at is not null,');
    if position('audit 1105: lockbox' in v) = 0 or position('''ready_by_staff''' in v) = 0 then
      raise exception 'portal view patch points not found';
    end if;
    execute v;
  end if;
end $$;

-- 2. Portal chat history
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_messages(text,text)'::regprocedure);
begin
  if position('audit 1105: phone' in v) = 0 then
    v := replace(v,
      '             where x.passenger_id = r.o_passenger_id' || chr(10),
      '             where x.passenger_id = r.o_passenger_id' || chr(10) ||
      '               and x.phone_e164 is not distinct from (select coalesce(public.airvalet_sms_normalize_phone(p.phone), ''+10000000000'')' || chr(10) ||
      '                                                        from public.passengers p where p.id = r.o_passenger_id)  -- audit 1105: phone' || chr(10));
    if position('audit 1105: phone' in v) = 0 then raise exception 'portal messages patch point not found'; end if;
    execute v;
  end if;
end $$;

-- 3. Closing reports
create or replace function public.dcr_lock_closed()
returns trigger language plpgsql set search_path = '' as $$
declare v_admin boolean := public.current_user_role() is not distinct from 'ADMIN';
begin
  if current_user in ('authenticated', 'anon') and not v_admin then
    if old.status = 'FINALIZED' then
      raise exception 'daily_closing_reports: the report for % is finalized and cannot be edited', old.report_date
        using errcode = '42501';
    end if;
    if old.closed_at is not null and (
         new.stripe_tips_cents is distinct from old.stripe_tips_cents
      or new.other_tips_cents is distinct from old.other_tips_cents
      or new.total_tips_cents is distinct from old.total_tips_cents
      or new.cash_custodian_name is distinct from old.cash_custodian_name
      or new.closed_at is distinct from old.closed_at) then
      raise exception 'daily_closing_reports: the closing report for % is already closed', old.report_date
        using errcode = '42501';
    end if;
  end if;
  if new.status = 'FINALIZED' and old.status is distinct from 'FINALIZED' then
    new.finalized_by := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), new.finalized_by);
    new.finalized_at := coalesce(new.finalized_at, now());
  end if;
  return new;
end $$;
revoke all on function public.dcr_lock_closed() from public;

create or replace function public.dcr_stamp_insert()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'FINALIZED' then
    new.finalized_by := coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''), new.finalized_by);
    new.finalized_at := coalesce(new.finalized_at, now());
  end if;
  return new;
end $$;
revoke all on function public.dcr_stamp_insert() from public;
do $$ begin
  if to_regclass('public.daily_closing_reports') is not null then  -- (absent only in the SMS test fixture)
    drop trigger if exists trg_dcr_lock_closed on public.daily_closing_reports;
    create trigger trg_dcr_lock_closed before update on public.daily_closing_reports
      for each row execute function public.dcr_lock_closed();
    drop trigger if exists trg_dcr_stamp_insert on public.daily_closing_reports;
    create trigger trg_dcr_stamp_insert before insert on public.daily_closing_reports
      for each row execute function public.dcr_stamp_insert();
  end if;
end $$;

-- 4. passengers: delete only through delete_passenger_with_log()
drop policy if exists authenticated_passengers_delete on public.passengers;
revoke delete, truncate on public.passengers from anon, authenticated;

-- 5. Stripe tip totals: staff only
do $$ begin
  if to_regprocedure('public.get_stripe_tips_today_cents()') is not null then
    revoke execute on function public.get_stripe_tips_for_date_cents(date) from public, anon;
    revoke execute on function public.get_stripe_tips_today_cents() from public, anon;
    grant execute on function public.get_stripe_tips_for_date_cents(date) to authenticated;
    grant execute on function public.get_stripe_tips_today_cents() to authenticated;
  end if;
end $$;

-- 6. activity_log.changed_by from the session
create or replace function public.activity_log_stamp()
returns trigger language plpgsql set search_path = '' as $$
declare v_who text := nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), '');
begin
  if coalesce(auth.jwt() ->> 'role', '') = 'authenticated' and v_who is not null then
    new.changed_by := v_who;
  end if;
  return new;
end $$;
revoke all on function public.activity_log_stamp() from public;
do $$ begin
  if to_regclass('public.activity_log') is not null then
    drop trigger if exists trg_activity_log_stamp on public.activity_log;
    create trigger trg_activity_log_stamp before insert on public.activity_log
      for each row execute function public.activity_log_stamp();
  end if;
end $$;

-- 7. set_user_role: count active admins only
do $$
declare v text;
begin
  if to_regprocedure('public.set_user_role(uuid,public.account_role)') is null then return; end if;
  v := pg_get_functiondef('public.set_user_role(uuid,public.account_role)'::regprocedure);
  if position('audit 1105: active' in v) = 0 then
    v := replace(v,
      'where role = ''ADMIN'' and id <> target_id;',
      'where role = ''ADMIN'' and id <> target_id and is_active;  -- audit 1105: active');
    if position('audit 1105: active' in v) = 0 then raise exception 'set_user_role patch point not found'; end if;
    execute v;
  end if;
end $$;

-- 8. Companion exception also for VEHICLE_DELIVERED
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_claim(text,bigint,text,text,text,text,text,text,integer,text,uuid,integer,integer,text,bytea)'::regprocedure);
begin
  if position('audit 1105: companion' in v) = 0 then
    v := replace(v,
      'and (p_message_type <> ''CHECK_IN'' or m.passenger_id is not distinct from p_passenger_id)  -- companion check-in: own link',
      'and (p_message_type not in (''CHECK_IN'', ''VEHICLE_DELIVERED'') or m.passenger_id is not distinct from p_passenger_id)  -- companion check-in: own link (audit 1105: companion)');
    if (length(v) - length(replace(v, 'audit 1105: companion', ''))) / length('audit 1105: companion') <> 2 then
      raise exception 'sms claim companion patch points not found';
    end if;
    execute v;
  end if;
end $$;

commit;
