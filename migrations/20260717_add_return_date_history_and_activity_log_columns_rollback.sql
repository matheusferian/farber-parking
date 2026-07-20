-- Rollback for 20260717_add_return_date_history_and_activity_log_columns.sql
--
-- Removes both RPCs (change_passenger_return_date_with_reason,
-- delete_passenger_with_log), their three internal helper functions, the
-- new passenger_return_date_changes table (with its indexes/RLS policies,
-- dropped automatically by DROP TABLE), and the five new activity_log
-- columns (with their FK and the two passenger_id-based indexes, also
-- dropped automatically as part of the column/table drops where
-- applicable).
--
-- Does NOT touch `passengers`, the pre-existing activity_log columns
-- (ts, action, passenger, ticket, location, detail, created_at), or any
-- other existing table or index — in particular, no index on the
-- pre-existing `action` column is created by the migration or removed by
-- this rollback, since one could conceivably have pre-existed under a
-- name this migration doesn't control. Existing Activity Log rows are
-- preserved — only the five new nullable columns disappear, along with
-- whatever values they held.
--
-- Run this only if you need to fully undo this feature's database change.

BEGIN;

drop function if exists public.change_passenger_return_date_with_reason(bigint, text, text, boolean);
drop function if exists public.delete_passenger_with_log(bigint);
drop function if exists public._normalize_ret_date(text);
drop function if exists public._clean_approx_from_obs(text);
drop function if exists public._is_valid_ret_date(text);

drop table if exists public.passenger_return_date_changes;

drop index if exists public.idx_activity_log_passenger_id;
drop index if exists public.idx_activity_log_passenger_id_created_at;

do $$
begin
  if exists (
    select 1 from information_schema.table_constraints
    where table_schema = 'public' and table_name = 'activity_log'
      and constraint_name = 'activity_log_passenger_id_fkey'
  ) then
    alter table public.activity_log drop constraint activity_log_passenger_id_fkey;
  end if;
end $$;

alter table public.activity_log drop column if exists passenger_id;
alter table public.activity_log drop column if exists changed_by;
alter table public.activity_log drop column if exists field_name;
alter table public.activity_log drop column if exists old_value;
alter table public.activity_log drop column if exists new_value;

COMMIT;
