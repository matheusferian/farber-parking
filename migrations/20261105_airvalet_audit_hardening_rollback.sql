-- Rollback of 20261105_airvalet_audit_hardening.sql
begin;

do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('audit 1105: lockbox' in v) > 0 then
    v := replace(v,
      '''lockbox'', case when v_st.lockbox_authorized_at is null  -- audit 1105: lockbox' || chr(10) ||
      '                       or v_p.status in (''DELIVERED'', ''ARCHIVED'') or v_status in (''DELIVERED'', ''CUSTOMS_CONFIRMED'')' || chr(10) ||
      '                       or nullif(btrim(coalesce(v_p.pickup_auth_name, '''')), '''') is not null' || chr(10) ||
      '                       or (public.airvalet_return_at(v_p.ret, null) is not null' || chr(10) ||
      '                           and (public.airvalet_return_at(v_p.ret, null) at time zone ''America/New_York'')::date < v_today)' || chr(10) ||
      '                     then null else',
      '''lockbox'', case when v_st.lockbox_authorized_at is null or v_status = ''DELIVERED'' then null else');
    v := replace(v, chr(10) || '      ''ready_by_staff'', v_st.ready_at is not null,', '');
    if position('audit 1105' in v) > 0 or position('ready_by_staff' in v) > 0 then raise exception 'portal view rollback failed'; end if;
    execute v;
  end if;
end $$;

do $$
declare v text := pg_get_functiondef('public.airvalet_portal_messages(text,text)'::regprocedure);
begin
  if position('audit 1105: phone' in v) > 0 then
    v := replace(v,
      '               and x.phone_e164 is not distinct from (select coalesce(public.airvalet_sms_normalize_phone(p.phone), ''+10000000000'')' || chr(10) ||
      '                                                        from public.passengers p where p.id = r.o_passenger_id)  -- audit 1105: phone' || chr(10),
      '');
    if position('audit 1105' in v) > 0 then raise exception 'portal messages rollback failed'; end if;
    execute v;
  end if;
end $$;

do $$ begin
  if to_regclass('public.daily_closing_reports') is not null then
    drop trigger if exists trg_dcr_lock_closed on public.daily_closing_reports;
    drop trigger if exists trg_dcr_stamp_insert on public.daily_closing_reports;
  end if;
end $$;
drop function if exists public.dcr_lock_closed();
drop function if exists public.dcr_stamp_insert();

do $$ begin
  if to_regprocedure('public.current_user_role()') is not null then
    drop policy if exists authenticated_passengers_delete on public.passengers;
    create policy authenticated_passengers_delete on public.passengers
      for delete to authenticated using (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'));
    grant delete on public.passengers to authenticated;
  end if;
end $$;

do $$ begin
  if to_regprocedure('public.get_stripe_tips_today_cents()') is not null then
    grant execute on function public.get_stripe_tips_for_date_cents(date) to anon;
    grant execute on function public.get_stripe_tips_today_cents() to anon;
  end if;
end $$;

do $$ begin
  if to_regclass('public.activity_log') is not null then
    drop trigger if exists trg_activity_log_stamp on public.activity_log;
  end if;
end $$;
drop function if exists public.activity_log_stamp();

do $$
declare v text;
begin
  if to_regprocedure('public.set_user_role(uuid,public.account_role)') is null then return; end if;
  v := pg_get_functiondef('public.set_user_role(uuid,public.account_role)'::regprocedure);
  if position('audit 1105: active' in v) > 0 then
    v := replace(v,
      'where role = ''ADMIN'' and id <> target_id and is_active;  -- audit 1105: active',
      'where role = ''ADMIN'' and id <> target_id;');
    execute v;
  end if;
end $$;

do $$
declare v text := pg_get_functiondef('public.airvalet_sms_claim(text,bigint,text,text,text,text,text,text,integer,text,uuid,integer,integer,text,bytea)'::regprocedure);
begin
  if position('audit 1105: companion' in v) > 0 then
    v := replace(v,
      'and (p_message_type not in (''CHECK_IN'', ''VEHICLE_DELIVERED'') or m.passenger_id is not distinct from p_passenger_id)  -- companion check-in: own link (audit 1105: companion)',
      'and (p_message_type <> ''CHECK_IN'' or m.passenger_id is not distinct from p_passenger_id)  -- companion check-in: own link');
    execute v;
  end if;
end $$;

commit;
