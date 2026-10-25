-- Rollback of 20261103: client brake back to 30; companion CHECK_IN dedupe by phone again.
begin;
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_resolve(text,text)'::regprocedure);
begin
  if position('c_client_max   constant int := 150;' in v) > 0 then
    execute replace(v, 'c_client_max   constant int := 150;', 'c_client_max   constant int := 30;');
  end if;
end $$;
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_claim(text,bigint,text,text,text,text,text,text,integer,text,uuid,integer,integer,text,bytea)'::regprocedure);
begin
  if position('companion check-in' in v) > 0 then
    execute replace(v,
      '                   and (p_message_type <> ''CHECK_IN'' or m.passenger_id is not distinct from p_passenger_id)  -- companion check-in: own link' || chr(10), '');
  end if;
end $$;
commit;
