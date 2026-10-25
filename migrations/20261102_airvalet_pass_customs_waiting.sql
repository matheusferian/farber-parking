-- Valet pass: a car left at Customs (status DELIVERED, delivery_type CUSTOMS)
-- shows "At Customs" until staff send the gratuity link (customs_gratuity_sent),
-- then "Delivered" (owner 2026-10-25). Display only.
begin;
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('waiting at Customs' in v) = 0 then
    v := replace(v,
      '    when v_p.status = ''DELIVERED'' then ''DELIVERED''' || chr(10),
      '    -- car waiting at Customs until the gratuity link goes out (owner 2026-10-25)' || chr(10) ||
      '    when v_p.status = ''DELIVERED'' and v_p.delivery_type = ''CUSTOMS'' and coalesce(v_p.customs_gratuity_sent, false) = false then ''CUSTOMS_CONFIRMED''' || chr(10) ||
      '    when v_p.status = ''DELIVERED'' then ''DELIVERED''' || chr(10));
    if position('waiting at Customs' in v) = 0 then raise exception 'portal view patch point not found'; end if;
    execute v;
  end if;
end $$;
commit;
