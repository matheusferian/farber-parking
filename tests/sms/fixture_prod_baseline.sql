-- LOCAL TEST FIXTURE ONLY — never run against a real project.
-- Reproduces the slice of the AirValet production schema (read 2026-10-09,
-- read-only) that the SMS migration depends on: account_role, user_profiles,
-- sso_sessions, current_user_role(), passengers, prod default privileges
-- (anon/authenticated get table rights + EXECUTE by default) and the
-- rls_auto_enable event trigger.

-- Current Supabase auth.uid() (the bare postgres image ships the legacy one).
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid
$$;

create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

create type public.account_role as enum ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'TV_ONLY', 'MANAGER');

create table public.user_profiles (
  id uuid primary key,
  username text not null,
  role public.account_role not null,
  display_name text,
  is_protected boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  is_active boolean not null default true
);

create table public.sso_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  supabase_session_id uuid,
  revoked_at timestamptz
);

create or replace function public.sso_current_session_id() returns uuid language sql stable set search_path to 'public' as $$
  select case when coalesce(auth.jwt() ->> 'session_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then (auth.jwt() ->> 'session_id')::uuid end;
$$;

create or replace function public.current_user_role() returns public.account_role
language sql stable security definer set search_path to 'public' as $$
  select role from public.user_profiles
   where id = auth.uid() and is_active = true
     and not exists (select 1 from public.sso_sessions s
                      where s.supabase_session_id = public.sso_current_session_id()
                        and s.revoked_at is not null);
$$;

create table public.passengers (
  id bigserial primary key,
  ts text, name text, phone text, ticket text, ret text, car text, loc text,
  status text default 'PENDING', block text, obs text, deldate text,
  created_at timestamptz default now(), color text, delivery_type text,
  checkin_date timestamptz, checkout_date timestamptz, return_flight text,
  customer_rating text, not_returning_with_makers_air boolean default false,
  archived_by text default '', archived_at text default '', departure_time text,
  previous_delivery_location text, welcome_back_sent_at timestamptz,
  customs_welcome_sent boolean not null default false, customs_welcome_sent_at timestamptz,
  customs_gratuity_sent boolean not null default false, customs_gratuity_sent_at timestamptz,
  customs_gratuity_dismissed boolean not null default false, tip_received boolean,
  delivery_at_customs boolean not null default false, carwash_status text
);
alter table public.passengers enable row level security;
create policy authenticated_passengers_select on public.passengers for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

-- Production default privileges (the reason the migration revokes explicitly).
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant execute on functions to anon, authenticated, service_role;
grant all on public.passengers, public.user_profiles, public.sso_sessions to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

create or replace function public.rls_auto_enable() returns event_trigger language plpgsql security definer set search_path to 'pg_catalog' as $$
declare cmd record;
begin
  for cmd in select * from pg_event_trigger_ddl_commands()
             where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
               and object_type in ('table', 'partitioned table') loop
    if cmd.schema_name = 'public' then
      execute format('alter table if exists %s enable row level security', cmd.object_identity);
    end if;
  end loop;
end;
$$;
create event trigger ensure_rls on ddl_command_end execute function public.rls_auto_enable();

-- In production these tables are owned by postgres (the migration role).
alter table public.passengers owner to postgres;
alter table public.user_profiles owner to postgres;
alter table public.sso_sessions owner to postgres;

-- Legacy rows that exist BEFORE the return-operator migration (backfill test).
insert into public.passengers (id, name, phone, ticket, status, not_returning_with_makers_air, delivery_at_customs) values
  (9001, 'LEGACY OTHERBOAT', '3055559001', '0901-1', 'PENDING', true,  false),
  (9002, 'LEGACY CUSTOMS',   '3055559002', '0901-2', 'PENDING', false, true),
  (9003, 'LEGACY ASCEND',    '3055559003', 'A-0901-3', 'NO DATE', false, false),
  (9004, 'LEGACY MAKERS',    '3055559004', '0901-4', 'PENDING', false, false),
  (9005, 'LEGACY DELIVERED', '3055559005', '0901-5', 'DELIVERED', false, false);
