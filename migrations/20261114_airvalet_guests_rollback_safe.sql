-- SAFE rollback of 20261114_airvalet_guests.sql: the Guests functions and the three
-- expression indexes go (the app must be back on v86 first). KEPT, untouched:
-- airvalet_guest_notes, airvalet_guest_note_revisions, airvalet_guest_identity (every
-- note, every revision, every merge / move decision) and their staff-only read access.
-- Turn it back on: re-run 20261114_airvalet_guests.sql.
begin;
set local lock_timeout = '5s';
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
commit;
