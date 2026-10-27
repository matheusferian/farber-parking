-- FULL (destructive) rollback of 20261114_airvalet_guests.sql. PRODUCTION: use
-- 20261114_airvalet_guests_rollback_safe.sql (keeps every note and identity decision).
-- This file REFUSES to run while any guest note or identity decision exists.
begin;
set local lock_timeout = '5s';
do $$
declare v_n bigint := 0; v_i bigint := 0;
begin
  if to_regclass('public.airvalet_guest_notes') is not null then select count(*) into v_n from public.airvalet_guest_notes; end if;
  if to_regclass('public.airvalet_guest_identity') is not null then select count(*) into v_i from public.airvalet_guest_identity; end if;
  if v_n > 0 or v_i > 0 then
    raise exception 'refused: % guest notes and % identity decisions would be deleted. Use 20261114_airvalet_guests_rollback_safe.sql (keeps them).', v_n, v_i;
  end if;
end $$;
drop function if exists public.airvalet_guest_search(text, integer, integer);
drop function if exists public.airvalet_guest_profile(text);
drop function if exists public.airvalet_guest_activity(text);
drop function if exists public.airvalet_guest_for_passenger(bigint);
drop function if exists public.airvalet_guest_lookup_phone(text);
drop function if exists public.airvalet_guest_note_save(text, bigint, text, uuid);
drop function if exists public.airvalet_guest_note_delete(bigint, uuid);
drop function if exists public.airvalet_guest_merge(text, text, text, uuid);
drop function if exists public.airvalet_guest_move_ticket(bigint, text, text, uuid);
drop function if exists public.airvalet_guest_identity_undo(bigint, text);
drop function if exists public.airvalet_guest_visit(public.passengers);
drop function if exists public.airvalet_guest_members(text);
drop function if exists public.airvalet_guest_key_of(bigint);
drop function if exists public.airvalet_guest_resolve(text);
drop function if exists public.airvalet_guest_merge_map();
drop function if exists public.airvalet_guest_is_ops();
drop function if exists public.airvalet_guest_visit_at(timestamptz, text, timestamptz);
drop index if exists public.passengers_guest_auto_key;
drop index if exists public.passengers_guest_phone_key;
drop index if exists public.passengers_guest_name_norm;
drop function if exists public.airvalet_guest_auto_key(bigint, text, text);
drop function if exists public.airvalet_guest_phone_key(text);
drop function if exists public.airvalet_guest_name_norm(text);
drop function if exists public.airvalet_guest_mdy(text);
drop table if exists public.airvalet_guest_note_revisions;
drop table if exists public.airvalet_guest_notes;
drop table if exists public.airvalet_guest_identity;
commit;
