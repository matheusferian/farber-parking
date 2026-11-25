-- Rollback of 20261159 (first: ASCEND_SMS=off and redeploy staff-alert + makers-sync from the previous main).
drop function if exists public.airvalet_ascend_went(bigint, boolean, text);
drop function if exists public.airvalet_ascend_board(timestamptz);
drop function if exists public.airvalet_ascend_claim(timestamptz);
drop function if exists public.airvalet_ascend_sync(date, jsonb, timestamptz);
drop function if exists public.airvalet_ascend_t12(time);
drop table if exists public.airvalet_ascend_texts;
drop table if exists public.airvalet_ascend_contacts;
drop table if exists public.airvalet_ascend_flights;
