-- Rollback for 20261010_create_airvalet_pass_links.sql (v2). Links already
-- sent by SMS stop working (the page shows "This valet link has expired.").
-- PRESERVES the link audit (hashes only, opened/expired/revoked times): the
-- table moves to airvalet_archive; only the throttle counters are dropped.
begin;
drop trigger if exists airvalet_pass_passenger_change on public.passengers;
drop view if exists public.airvalet_sms_pass_status;
drop function if exists public.airvalet_pass_revoke(bigint);
drop function if exists public.airvalet_pass_on_passenger_change();
drop function if exists public.airvalet_pass_view(text, text);
drop function if exists public.airvalet_pass_hit(text);
drop function if exists public.airvalet_pass_mint(bigint);
drop function if exists public.airvalet_pass_new_token();
drop table if exists public.airvalet_pass_rate;
create schema if not exists airvalet_archive;
revoke all on schema airvalet_archive from public, anon, authenticated;
do $$
declare v_fk name; v_new text := 'airvalet_pass_links__rb_' || to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDD"T"HH24MISS');
begin
  if to_regclass('public.airvalet_pass_links') is not null then
    execute format('alter table public.airvalet_pass_links rename to %I', v_new);
    execute format('alter table public.%I set schema airvalet_archive', v_new);
    execute format('revoke all on airvalet_archive.%I from public, anon, authenticated', v_new);
    for v_fk in select conname from pg_constraint where conrelid = format('airvalet_archive.%I', v_new)::regclass and contype = 'f' loop
      execute format('alter table airvalet_archive.%I drop constraint %I', v_new, v_fk);  -- no cascade from passengers
    end loop;
  end if;
end $$;
commit;
