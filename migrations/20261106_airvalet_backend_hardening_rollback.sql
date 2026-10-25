-- Rollback of 20261106_airvalet_backend_hardening.sql
-- Data note: rows that carry the new alert kinds NO_STATUS / DELIVERED_AFTER_RESEND lose
-- the alert (attention cleared) so the old CHECK can be restored. Their status, SID,
-- delivered_at, error_code and resolution stay as they are. vehicle_location_history
-- rows written while installed are kept.
begin;

-- 1. closing reports: IPHONE_OPS back
do $$ begin
  if to_regclass('public.daily_closing_reports') is not null then
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

-- 2a. rental_logs: back to one ALL policy for ops roles
do $$ begin
  if to_regclass('public.rental_logs') is not null then
    drop policy if exists rental_logs_select_ops_roles on public.rental_logs;
    drop policy if exists rental_logs_insert_ops_roles on public.rental_logs;
    drop policy if exists rental_logs_update_admin_manager on public.rental_logs;
    drop policy if exists rental_logs_delete_admin_manager on public.rental_logs;
    drop policy if exists rental_logs_ops_roles_all on public.rental_logs;
    create policy rental_logs_ops_roles_all on public.rental_logs
      for all to authenticated
      using (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'))
      with check (public.current_user_role() in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER'));
  end if;
end $$;

-- 2b. valet_shifts guard
do $$ begin
  if to_regclass('public.valet_shifts') is not null then
    drop trigger if exists trg_valet_shifts_guard_update on public.valet_shifts;
  end if;
end $$;
drop function if exists public.valet_shifts_guard_update();

-- 3. vehicle_location_history: back to no policy (rows kept)
do $$ begin
  if to_regclass('public.vehicle_location_history') is not null then
    drop policy if exists vlh_insert_ops_roles on public.vehicle_location_history;
    drop policy if exists vlh_select_report_roles on public.vehicle_location_history;
    drop trigger if exists trg_vlh_stamp on public.vehicle_location_history;
  end if;
end $$;
drop function if exists public.vlh_stamp();

-- 4. match_passenger
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_match_passenger(text)'::regprocedure);
begin
  if position('audit 1106: active' in v) > 0 then
    v := replace(v,
      '  if v_last.passenger_id is not null and v_last.created_at > now() - interval ''72 hours''' || chr(10) ||
      '     and cardinality(v_active) > 0 and not (v_last.passenger_id = any (v_active)) then' || chr(10) ||
      '    -- audit 1106: active. Last text went to a trip that is no longer active while' || chr(10) ||
      '    -- another active ticket uses this phone: staff decide (both are candidates).' || chr(10) ||
      '    return query select null::bigint, ''ambiguous''::text, to_jsonb(v_active || v_last.passenger_id);' || chr(10) ||
      '  elsif v_last.passenger_id is not null and v_last.created_at > now() - interval ''72 hours'' then' || chr(10),
      '  if v_last.passenger_id is not null and v_last.created_at > now() - interval ''72 hours'' then' || chr(10));
    v := replace(v,
      '  elsif v_last.passenger_id is not null and v_last.created_at > now() - interval ''14 days''' || chr(10) ||
      '        and (cardinality(v_active) = 0 or v_last.passenger_id = any (v_active)) then  -- audit 1106: active14' || chr(10),
      '  elsif v_last.passenger_id is not null and v_last.created_at > now() - interval ''14 days'' then' || chr(10));
    if position('audit 1106' in v) > 0 then raise exception 'match_passenger rollback failed'; end if;
    execute v;
  end if;
end $$;

-- 5. reconcile
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_reconcile(integer)'::regprocedure);
begin
  if position('audit 1106: no_status' in v) > 0 then
    v := replace(v, 'declare v_n integer; v_n2 integer;  -- audit 1106: no_status', 'declare v_n integer;');
    v := replace(v,
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
      '  return v_n + v_n2;',
      '  get diagnostics v_n = row_count;' || chr(10) || '  return v_n;');
    if position('audit 1106' in v) > 0 then raise exception 'reconcile rollback failed'; end if;
    execute v;
  end if;
end $$;

do $$
declare v text := pg_get_functiondef('public.airvalet_sms_apply_status_row(uuid,text,text,text)'::regprocedure);
begin
  if position('audit 1106: no_status' in v) > 0 then
    v := replace(v,
      'when m.attention in (''UNCONFIRMED'', ''NO_STATUS'') then null  -- audit 1106: no_status',
      'when m.attention = ''UNCONFIRMED'' then null');
    if position('audit 1106' in v) > 0 then raise exception 'apply_status_row rollback failed'; end if;
    execute v;
  end if;
end $$;

-- 6. apply_status
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_apply_status(text,text,text,text,uuid)'::regprocedure);
begin
  if position('audit 1106: late' in v) > 0 then
    v := replace(v,
      '       and m.provider_message_sid is null' || chr(10) ||
      '       and (m.status in (''pending'', ''send_unknown'') or (m.status = ''failed'' and m.resolution = ''marked_not_sent''))  -- audit 1106: late' || chr(10),
      '       and m.provider_message_sid is null and m.status in (''pending'', ''send_unknown'')' || chr(10));
    v := replace(v,
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
      '  end if;' || chr(10),
      '');
    if position('audit 1106' in v) > 0 then raise exception 'apply_status rollback failed'; end if;
    execute v;
  end if;
end $$;

-- 4-6. alert kinds
update public.airvalet_sms_messages
   set attention = null, attention_at = null, updated_at = now()
 where attention in ('NO_STATUS', 'DELIVERED_AFTER_RESEND');
alter table public.airvalet_sms_messages drop constraint if exists airvalet_sms_messages_attention_check;
alter table public.airvalet_sms_messages add constraint airvalet_sms_messages_attention_check
  check (attention = any (array['UNCONFIRMED', 'UNREACHABLE', 'CARRIER_FILTERED', 'FAILED']));

-- 7. start_verify
do $$
declare v text;
begin
  if to_regprocedure('public.airvalet_admin_alerts_start_verify(uuid,text)') is null then return; end if;
  v := pg_get_functiondef('public.airvalet_admin_alerts_start_verify(uuid,text)'::regprocedure);
  if position('audit 1106: csprng' in v) > 0 then
    v := replace(v,
      'declare v_code text := lpad(((''x'' || encode(extensions.gen_random_bytes(4), ''hex''))::bit(32)::bigint % 1000000)::text, 6, ''0'');  -- audit 1106: csprng',
      'declare v_code text := lpad((floor(random() * 1000000))::int::text, 6, ''0'');');
    if position('audit 1106' in v) > 0 then raise exception 'start_verify rollback failed'; end if;
    execute v;
  end if;
end $$;

commit;
