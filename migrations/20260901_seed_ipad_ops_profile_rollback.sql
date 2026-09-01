-- Rollback for 20260901_seed_ipad_ops_profile.sql.
-- Removes only the user_profiles row for ipad@airvalet.local — does not
-- touch the Auth account itself (auth.users), which is outside this
-- migration's scope and was never created or modified by it.

delete from public.user_profiles
where id = (select id from auth.users where email = 'ipad@airvalet.local');
