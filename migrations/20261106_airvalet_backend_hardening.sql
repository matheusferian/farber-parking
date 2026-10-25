-- Full-system audit 2026-10-25, backend hardening round 2 (owner GO required before prod).
-- 1. ADM-09  daily_closing_reports: INSERT had no role check; now ops roles only
--            (ADMIN, IPAD_OPS, IPHONE_OPS, MANAGER). The iPhone keeps the Closing
--            Report (daily closing is done on the phones; hotfix main 14e191d). activity_log (passenger change history in
--            the car panel) and payments (realtime refresh of the Tips KPI on the
--            Dashboard) stay readable: the iPhone uses both.
-- 2. ADM-07  rental_logs: ops roles keep SELECT + INSERT (the app only adds and
--            lists); UPDATE / DELETE only ADMIN / MANAGER.
--            valet_shifts: every ops role still records Clock Out, but IPAD_OPS /
--            IPHONE_OPS can only set clock_out_at on an open shift. Any other
--            change (name, date, clock-in, a closed shift) needs ADMIN / MANAGER.
--            No DELETE policy exists (unchanged).
-- 3. ADM-06  vehicle_location_history had RLS on and no policy: every vlhInsert()
--            was silently refused. Ops roles may now INSERT (created_by stamped
--            from the session); SELECT for the roles that have the Report tab.
-- 4. Twilio F4  an inbound reply is no longer pinned to an old trip (delivered /
--            archived) when another ACTIVE ticket uses the same phone: it goes to
--            review as 'ambiguous' with both trips as candidates.
-- 5. Twilio F5  a send that has a Twilio SID but never got a status callback
--            (accepted / queued / sending for 45+ min) raises attention 'NO_STATUS'.
--            A later real status clears it, like UNCONFIRMED.
-- 6. Twilio F7  a late 'delivered' callback for a send that staff marked "not
--            received" is adopted (proof of delivery kept) and reopens the alert
--            as 'DELIVERED_AFTER_RESEND'.
-- 7. ADM-18  admin alert verify code from gen_random_bytes (CSPRNG), not random().
-- Rollback: 20261106_airvalet_backend_hardening_rollback.sql
begin;

-- 1. ADM-09 closing reports: ops roles only (INSERT had no role check); IPHONE_OPS keeps access
do $$ begin
  if to_regclass('public.daily_closing_reports') is not null then  -- (absent only in the SMS test fixture)
    drop policy if exists dcr_select_authenticated on public.daily_closing_reports;
    create policy dcr_select_authenticated on public.daily_closing_reports
      for select to authenticated using (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'));
    drop policy if exists dcr_insert_authenticated on public.daily_closing_reports;
    create policy dcr_insert_authenticated on public.daily_closing_reports
      for insert to authenticated with check (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'));
    drop policy if exists dcr_update_authenticated on public.daily_closing_reports;
    create policy dcr_update_authenticated on public.daily_closing_reports
      for update to authenticated using (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'))
      with check (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'));
  end if;
end $$;

-- 2a. ADM-07 rental_logs
do $$ begin
  if to_regclass('public.rental_logs') is not null then
    drop policy if exists rental_logs_ops_roles_all on public.rental_logs;
    drop policy if exists rental_logs_select_ops_roles on public.rental_logs;
    create policy rental_logs_select_ops_roles on public.rental_logs
      for select to authenticated using (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'));
    drop policy if exists rental_logs_insert_ops_roles on public.rental_logs;
    create policy rental_logs_insert_ops_roles on public.rental_logs
      for insert to authenticated with check (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'));
    drop policy if exists rental_logs_update_admin_manager on public.rental_logs;
    create policy rental_logs_update_admin_manager on public.rental_logs
      for update to authenticated using (public.current_user_role() in ('ADMIN', 'MANAGER'))
      with check (public.current_user_role() in ('ADMIN', 'MANAGER'));
    drop policy if exists rental_logs_delete_admin_manager on public.rental_logs;
    create policy rental_logs_delete_admin_manager on public.rental_logs
      for delete to authenticated using (public.current_user_role() in ('ADMIN', 'MANAGER'));
  end if;
end $$;

-- 2b. ADM-07 valet_shifts: ops only record Clock Out on an open shift
create or replace function public.valet_shifts_guard_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon')
     and coalesce(public.current_user_role()::text, '') not in ('ADMIN', 'MANAGER') then
    if old.clock_out_at is not null then
      raise exception 'valet_shifts: this shift is already clocked out; a manager can correct it'
        using errcode = '42501';
    end if;
    if new.id is distinct from old.id or new.valet_name is distinct from old.valet_name
       or new.business_date is distinct from old.business_date or new.clock_in_at is distinct from old.clock_in_at
       or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by then
      raise exception 'valet_shifts: only Clock Out can be recorded here; a manager can correct the shift'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.valet_shifts_guard_update() from public;
do $$ begin
  if to_regclass('public.valet_shifts') is not null then
    drop trigger if exists trg_valet_shifts_guard_update on public.valet_shifts;
    create trigger trg_valet_shifts_guard_update before update on public.valet_shifts
      for each row execute function public.valet_shifts_guard_update();
  end if;
end $$;

-- 3. ADM-06 vehicle_location_history
create or replace function public.vlh_stamp()
returns trigger language plpgsql set search_path = '' as $$
declare v_who text := nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), '');
begin
  if coalesce(auth.jwt() ->> 'role', '') = 'authenticated' and v_who is not null then
    new.created_by := v_who;
    new.created_at := now();
  end if;
  return new;
end $$;
revoke all on function public.vlh_stamp() from public;
do $$ begin
  if to_regclass('public.vehicle_location_history') is not null then
    drop policy if exists vlh_insert_ops_roles on public.vehicle_location_history;
    create policy vlh_insert_ops_roles on public.vehicle_location_history
      for insert to authenticated with check (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'));
    drop policy if exists vlh_select_report_roles on public.vehicle_location_history;
    create policy vlh_select_report_roles on public.vehicle_location_history
      for select to authenticated using (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'MANAGER'));
    drop trigger if exists trg_vlh_stamp on public.vehicle_location_history;
    create trigger trg_vlh_stamp before insert on public.vehicle_location_history
      for each row execute function public.vlh_stamp();
  end if;
end $$;

-- 4-6. New alert kinds
alter table public.airvalet_sms_messages drop constraint if exists airvalet_sms_messages_attention_check;
alter table public.airvalet_sms_messages add constraint airvalet_sms_messages_attention_check
  check (attention = any (array['UNCONFIRMED', 'UNREACHABLE', 'CARRIER_FILTERED', 'FAILED', 'NO_STATUS', 'DELIVERED_AFTER_RESEND']));

-- 4. F4 inbound matching: an old trip never wins over another active ticket
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_match_passenger(text)'::regprocedure);
begin
  if position('audit 1106: active' in v) = 0 then
    v := replace(v,
      '  if v_last.passenger_id is not null and v_last.created_at > now() - interval ''72 hours'' then' || chr(10),
      '  if v_last.passenger_id is not null and v_last.created_at > now() - interval ''72 hours''' || chr(10) ||
      '     and cardinality(v_active) > 0 and not (v_last.passenger_id = any (v_active)) then' || chr(10) ||
      '    -- audit 1106: active. Last text went to a trip that is no longer active while' || chr(10) ||
      '    -- another active ticket uses this phone: staff decide (both are candidates).' || chr(10) ||
      '    return query select null::bigint, ''ambiguous''::text, to_jsonb(v_active || v_last.passenger_id);' || chr(10) ||
      '  elsif v_last.passenger_id is not null and v_last.created_at > now() - interval ''72 hours'' then' || chr(10));
    v := replace(v,
      '  elsif v_last.passenger_id is not null and v_last.created_at > now() - interval ''14 days'' then' || chr(10),
      '  elsif v_last.passenger_id is not null and v_last.created_at > now() - interval ''14 days''' || chr(10) ||
      '        and (cardinality(v_active) = 0 or v_last.passenger_id = any (v_active)) then  -- audit 1106: active14' || chr(10));
    if position('audit 1106: active.' in v) = 0 or position('audit 1106: active14' in v) = 0 then
      raise exception 'match_passenger patch points not found';
    end if;
    execute v;
  end if;
end $$;

-- 5. F5 reconcile: SID but no status callback → NO_STATUS
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_reconcile(integer)'::regprocedure);
begin
  if position('audit 1106: no_status' in v) = 0 then
    v := replace(v, 'declare v_n integer;', 'declare v_n integer; v_n2 integer;  -- audit 1106: no_status');
    v := replace(v,
      '  get diagnostics v_n = row_count;' || chr(10) || '  return v_n;',
      '  get diagnostics v_n = row_count;' || chr(10) ||
      '  -- audit 1106: no_status. Twilio accepted it (SID) but no status callback came' || chr(10) ||
      '  -- for 45+ min (callback URL / signature / outage): staff should check it.' || chr(10) ||
      '  update public.airvalet_sms_messages m' || chr(10) ||
      '     set attention = ''NO_STATUS'', attention_at = now(), updated_at = now()' || chr(10) ||
      '   where m.direction = ''outbound'' and m.status in (''accepted'', ''queued'', ''sending'')' || chr(10) ||
      '     and m.provider_message_sid is not null and m.attention is null and m.resolved_at is null' || chr(10) ||
      '     and coalesce(m.last_status_at, m.created_at) < now() - interval ''45 minutes''' || chr(10) ||
      '     and m.created_at > now() - interval ''3 days'';' || chr(10) ||
      '  get diagnostics v_n2 = row_count;' || chr(10) ||
      '  return v_n + v_n2;');
    if (length(v) - length(replace(v, 'audit 1106: no_status', ''))) / length('audit 1106: no_status') <> 2 then
      raise exception 'reconcile patch points not found';
    end if;
    execute v;
  end if;
end $$;

-- 5b. A real status clears NO_STATUS too
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_apply_status_row(uuid,text,text,text)'::regprocedure);
begin
  if position('audit 1106: no_status' in v) = 0 then
    v := replace(v,
      'when m.attention = ''UNCONFIRMED'' then null',
      'when m.attention in (''UNCONFIRMED'', ''NO_STATUS'') then null  -- audit 1106: no_status');
    if (length(v) - length(replace(v, 'audit 1106: no_status', ''))) / length('audit 1106: no_status') <> 2 then
      raise exception 'apply_status_row patch points not found';
    end if;
    execute v;
  end if;
end $$;

-- 6. F7 late delivered after "Not received — allow resend"
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_apply_status(text,text,text,text,uuid)'::regprocedure);
begin
  if position('audit 1106: late' in v) = 0 then
    v := replace(v,
      '       and m.provider_message_sid is null and m.status in (''pending'', ''send_unknown'')' || chr(10),
      '       and m.provider_message_sid is null' || chr(10) ||
      '       and (m.status in (''pending'', ''send_unknown'') or (m.status = ''failed'' and m.resolution = ''marked_not_sent''))  -- audit 1106: late' || chr(10));
    v := replace(v,
      '  if public.airvalet_sms_apply_status_row(v_msg_id, p_status, p_error_code, p_error_message) then' || chr(10),
      '  -- audit 1106: late. Staff marked this send "not received" but the carrier now' || chr(10) ||
      '  -- confirms delivery: keep the proof and reopen it as an alert.' || chr(10) ||
      '  if p_status = ''delivered'' then' || chr(10) ||
      '    update public.airvalet_sms_messages m' || chr(10) ||
      '       set status = ''delivered'', delivered_at = now(), sent_at = coalesce(m.sent_at, now()),' || chr(10) ||
      '           last_status_at = now(), updated_at = now(),' || chr(10) ||
      '           attention = ''DELIVERED_AFTER_RESEND'', attention_at = now(), resolved_at = null' || chr(10) ||
      '     where m.id = v_msg_id and m.status = ''failed'' and m.resolution = ''marked_not_sent'';' || chr(10) ||
      '    if found then' || chr(10) ||
      '      update public.airvalet_sms_status_events set applied = true where id = v_event_id;' || chr(10) ||
      '      return ''applied'';' || chr(10) ||
      '    end if;' || chr(10) ||
      '  end if;' || chr(10) ||
      '  if public.airvalet_sms_apply_status_row(v_msg_id, p_status, p_error_code, p_error_message) then' || chr(10));
    if (length(v) - length(replace(v, 'audit 1106: late', ''))) / length('audit 1106: late') <> 2 then
      raise exception 'apply_status patch points not found';
    end if;
    execute v;
  end if;
end $$;

-- 7. ADM-18 verify code from a CSPRNG
do $$
declare v text;
begin
  if to_regprocedure('public.airvalet_admin_alerts_start_verify(uuid,text)') is null then return; end if;
  v := pg_get_functiondef('public.airvalet_admin_alerts_start_verify(uuid,text)'::regprocedure);
  if position('audit 1106: csprng' in v) = 0 then
    v := replace(v,
      'declare v_code text := lpad((floor(random() * 1000000))::int::text, 6, ''0'');',
      'declare v_code text := lpad(((''x'' || encode(extensions.gen_random_bytes(4), ''hex''))::bit(32)::bigint % 1000000)::text, 6, ''0'');  -- audit 1106: csprng');
    if position('audit 1106: csprng' in v) = 0 then raise exception 'start_verify patch point not found'; end if;
    execute v;
  end if;
end $$;

commit;
