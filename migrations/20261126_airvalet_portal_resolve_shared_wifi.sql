-- AirValet pass (audit 2026-11-06, #11): several guests on one FBO Wi-Fi no longer hit "Too many attempts".
-- Per-client cap 150 → 600 hits / 10 min, and the 8-wrong-links rule now blocks only further wrong links
-- (a valid pass always opens). Global failure cap unchanged. Base: production definition read 2026-11-06.
-- Rollback: 20261126_airvalet_portal_resolve_shared_wifi_rollback.sql
begin;
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION public.airvalet_portal_resolve(p_token text, p_client text, OUT o_state text, OUT o_link_id bigint, OUT o_passenger_id bigint)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c_client_max   constant int := 600;   -- audit 1106: a shared FBO Wi-Fi (one IP) with several open passes
  c_client_fails constant int := 8;
  c_global_fails constant int := 2000;
  v_client text := coalesce(nullif(p_client, ''), 'none');
  v_win    timestamptz := date_bin('10 minutes', now(), timestamptz '2000-01-01');
  v_link   public.airvalet_pass_links%rowtype;
  v_p      public.passengers%rowtype;
  v_ok     boolean := false;
begin
  if random() < 0.01 then
    delete from public.airvalet_pass_rate r where r.window_start < now() - interval '1 hour';
  end if;
  if public.airvalet_pass_hit('c:' || v_client) > c_client_max then
    o_state := 'limited'; return;
  end if;
  if not coalesce((select s.portal_enabled from public.airvalet_portal_settings s), false) then
    o_state := 'expired'; return;  -- dark launch: indistinguishable from an unknown link
  end if;
  if p_token ~ '^[A-Za-z0-9]{17}$' then
    select * into v_link from public.airvalet_pass_links l
     where l.token_hash = extensions.digest(p_token, 'sha256') and l.revoked_at is null;
    if found then
      select * into v_p from public.passengers p where p.id = v_link.passenger_id;
      v_ok := found and v_p.status <> 'ARCHIVED'
        and (case when v_link.expires_at is not null then now() < v_link.expires_at
                  else v_p.status in ('PENDING', 'NO DATE') end);
    end if;
  end if;
  if not v_ok then
    -- audit 1106: too many wrong links from this client block only further wrong links, never a valid pass
    if coalesce((select r.hits from public.airvalet_pass_rate r where r.bucket = 'f:' || v_client and r.window_start = v_win), 0) >= c_client_fails then
      o_state := 'limited'; return;
    end if;
    perform public.airvalet_pass_hit('f:' || v_client);
    o_state := case when public.airvalet_pass_hit('f:*') > c_global_fails then 'limited' else 'expired' end;
    return;
  end if;
  o_state := 'ok'; o_link_id := v_link.id; o_passenger_id := v_p.id;
end $function$
;
commit;
