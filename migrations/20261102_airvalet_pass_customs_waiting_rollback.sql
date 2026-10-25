-- Rollback of 20261102: a Customs delivery shows "Delivered" right away again.
begin;
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('waiting at Customs' in v) > 0 then
    v := replace(v,
      '    -- car waiting at Customs until the gratuity link goes out (owner 2026-10-25)' || chr(10) ||
      '    when v_p.status = ''DELIVERED'' and v_p.delivery_type = ''CUSTOMS'' and coalesce(v_p.customs_gratuity_sent, false) = false then ''CUSTOMS_CONFIRMED''' || chr(10), '');
    execute v;
  end if;
end $$;
commit;
