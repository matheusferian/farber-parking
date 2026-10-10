-- Passenger link (Makers Air Valet "valet details" page) — LOCAL ONLY until owner GO.
-- Requires 20261009_create_airvalet_sms_messages.sql and
-- 20261010_add_passenger_return_operator.sql.
--
-- v2 (owner 2026-10-10): https://farberos.com/a#<token>
--   * Token: 17 chars base62 from pgcrypto with rejection sampling (no modulo
--     bias) = 17·log2(62) ≈ 101 bits. Never sequential, never derived from
--     name/phone/ticket. ONLY its SHA-256 is stored; the plaintext exists once,
--     returned by airvalet_pass_mint() to the send-sms function for the SMS.
--   * The token travels in the URL fragment (#…): browsers never send it to
--     any server, proxy, log or Referer. The page POSTs it to valet-pass,
--     which is the only place it is validated.
--   * Validity: open service (PENDING / NO DATE) → active. The first time the
--     passenger becomes DELIVERED, expires_at is set ONCE to delivery time
--     (checkout_date, never later than now) + 3 hours. It is never moved
--     again: undo / re-deliver / later edits cannot renew it. Archive, phone
--     change or a staff revoke kill the link immediately.
--   * Unknown, malformed, revoked and expired tokens get the SAME answer
--     ('expired'), so the endpoint is no oracle. Per-client and global
--     throttles live in airvalet_pass_rate (client = salted hash computed by
--     the Edge Function, never a raw IP).
-- Page shows only: first name, vehicle, status, return date on file, the
-- EFFECTIVE pickup place and the operational ticket number (display only,
-- never a key). No phone, no key location, no internal ids.

begin;

create table public.airvalet_pass_links (
  id              bigint generated always as identity primary key,
  token_hash      bytea not null unique check (octet_length(token_hash) = 32),
  passenger_id    bigint not null references public.passengers(id) on delete cascade,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz,   -- set once at first DELIVERED (+3h); never moved
  revoked_at      timestamptz,
  revoke_reason   text check (revoke_reason in ('rotated','staff','phone_changed','archived')),
  revoked_by      uuid,
  first_opened_at timestamptz,
  last_opened_at  timestamptz,
  open_count      integer not null default 0,
  check ((revoked_at is null) = (revoke_reason is null))
);
create unique index airvalet_pass_links_one_active on public.airvalet_pass_links (passenger_id) where revoked_at is null;

-- Throttle counters (10-minute windows). service_role only.
create table public.airvalet_pass_rate (
  bucket       text not null,
  window_start timestamptz not null,
  hits         integer not null default 0,
  primary key (bucket, window_start)
);

alter table public.airvalet_pass_links enable row level security;
alter table public.airvalet_pass_rate enable row level security;
revoke all on public.airvalet_pass_links from public, anon, authenticated;
revoke all on public.airvalet_pass_rate from public, anon, authenticated;
grant all on public.airvalet_pass_links to service_role;
grant all on public.airvalet_pass_rate to service_role;
revoke all on sequence public.airvalet_pass_links_id_seq from public, anon, authenticated;
-- Staff may read link STATE (never token_hash): column-level grant + ops RLS.
grant select (id, passenger_id, created_at, expires_at, revoked_at, revoke_reason, first_opened_at, last_opened_at, open_count)
  on public.airvalet_pass_links to authenticated;
create policy airvalet_pass_links_select_ops on public.airvalet_pass_links
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

-- 17-char base62 token; bytes ≥ 248 are discarded so every symbol is uniform.
create or replace function public.airvalet_pass_new_token()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_alpha constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  v_token text := '';
  v_bytes bytea;
  b int;
  i int;
begin
  while length(v_token) < 17 loop
    v_bytes := extensions.gen_random_bytes(32);
    for i in 0..31 loop
      b := get_byte(v_bytes, i);
      if b < 248 then
        v_token := v_token || substr(v_alpha, (b % 62) + 1, 1);
        exit when length(v_token) = 17;
      end if;
    end loop;
  end loop;
  return v_token;
end;
$$;

-- Mint a fresh link for an OPEN service and return the plaintext ONCE.
-- Any previous active link of that passenger is revoked ('rotated').
-- Delivered / archived / missing passengers get NULL (no new links after delivery).
create or replace function public.airvalet_pass_mint(p_passenger_id bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_token  text;
begin
  select p.status into v_status from public.passengers p where p.id = p_passenger_id for update;
  if not found or v_status not in ('PENDING', 'NO DATE') then return null; end if;
  -- Only tickets enrolled in the Twilio program (new check-ins) get a link.
  if not exists (select 1 from public.airvalet_sms_enrollments e where e.passenger_id = p_passenger_id) then return null; end if;
  update public.airvalet_pass_links l set revoked_at = now(), revoke_reason = 'rotated'
   where l.passenger_id = p_passenger_id and l.revoked_at is null;
  loop
    v_token := public.airvalet_pass_new_token();
    begin
      insert into public.airvalet_pass_links (token_hash, passenger_id)
      values (extensions.digest(v_token, 'sha256'), p_passenger_id);
      return v_token;
    exception when unique_violation then
      null; -- 2^-101 collision: draw again
    end;
  end loop;
end;
$$;

-- Count one hit in a 10-minute bucket and return the new total.
create or replace function public.airvalet_pass_hit(p_bucket text)
returns integer
language sql
security definer
set search_path = ''
as $$
  insert into public.airvalet_pass_rate (bucket, window_start, hits)
  values (p_bucket, date_bin('10 minutes', now(), timestamptz '2000-01-01'), 1)
  on conflict (bucket, window_start) do update set hits = public.airvalet_pass_rate.hits + 1
  returning hits;
$$;

-- Public read, called ONLY by the valet-pass Edge Function (service_role).
-- state: 'ok' | 'expired' (unknown/malformed/revoked/expired/archived — one
-- answer for all) | 'limited'. Fields are filled only when state = 'ok'.
create or replace function public.airvalet_pass_view(p_token text, p_client text default null)
returns table (
  state text, ticket text, first_name text, vehicle text, color text, status text, return_date text,
  return_location text, return_other boolean, customs_exception boolean,
  customs_request_pending boolean, delivered boolean, expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_client_max   constant int := 30;    -- requests per client per 10 min
  c_client_fails constant int := 8;     -- failed lookups per client per 10 min
  c_global_fails constant int := 2000;  -- failed lookups, all clients, per 10 min
  v_client text := coalesce(nullif(p_client, ''), 'none');
  v_win    timestamptz := date_bin('10 minutes', now(), timestamptz '2000-01-01');
  v_link   public.airvalet_pass_links%rowtype;
  v_p      public.passengers%rowtype;
  v_ok     boolean := false;
begin
  if random() < 0.01 then
    delete from public.airvalet_pass_rate r where r.window_start < now() - interval '1 hour';
  end if;
  -- Per-client brakes (checked before any lookup).
  if public.airvalet_pass_hit('c:' || v_client) > c_client_max
     or coalesce((select r.hits from public.airvalet_pass_rate r where r.bucket = 'f:' || v_client and r.window_start = v_win), 0) >= c_client_fails then
    return query select 'limited'::text, null::text, null::text, null::text, null::text, null::text, null::text,
                        null::text, null::boolean, null::boolean, null::boolean, null::boolean, null::timestamptz;
    return;
  end if;

  if p_token ~ '^[A-Za-z0-9]{17}$' then
    select * into v_link from public.airvalet_pass_links l
     where l.token_hash = extensions.digest(p_token, 'sha256') and l.revoked_at is null;
    if found then
      select * into v_p from public.passengers p where p.id = v_link.passenger_id;
      v_ok := found
        and v_p.status <> 'ARCHIVED'
        and (case when v_link.expires_at is not null then now() < v_link.expires_at
                  else v_p.status in ('PENDING', 'NO DATE') end);
    end if;
  end if;

  if not v_ok then
    perform public.airvalet_pass_hit('f:' || v_client);
    if public.airvalet_pass_hit('f:*') > c_global_fails then
      return query select 'limited'::text, null::text, null::text, null::text, null::text, null::text, null::text,
                          null::text, null::boolean, null::boolean, null::boolean, null::boolean, null::timestamptz;
      return;
    end if;
    return query select 'expired'::text, null::text, null::text, null::text, null::text, null::text, null::text,
                        null::text, null::boolean, null::boolean, null::boolean, null::boolean, null::timestamptz;
    return;
  end if;

  update public.airvalet_pass_links l
     set first_opened_at = coalesce(l.first_opened_at, now()), last_opened_at = now(), open_count = l.open_count + 1
   where l.id = v_link.id;
  return query select
    'ok'::text,
    nullif(btrim(coalesce(v_p.ticket, '')), ''),  -- display only, exactly as printed
    initcap(split_part(btrim(coalesce(v_p.name, '')), ' ', 1)),
    nullif(btrim(coalesce(v_p.car, '')), ''),
    nullif(btrim(coalesce(v_p.color, '')), ''),
    case when v_p.status = 'DELIVERED' then 'DELIVERED' else 'PARKED' end,
    nullif(btrim(coalesce(v_p.ret, '')), ''),
    public.airvalet_pickup_location(v_p.return_operator, v_p.delivery_at_customs),
    coalesce(v_p.return_operator = 'OTHER', false),
    coalesce(v_p.return_operator = 'MAKERS' and v_p.delivery_at_customs, false),
    v_p.customs_exception_requested_at is not null,
    v_p.status = 'DELIVERED',
    v_link.expires_at;
end;
$$;

-- Lifecycle: first DELIVERED fixes the 3-hour window ONCE; archive / phone
-- change revoke immediately. Undo or re-deliver never renews (expires_at is
-- only written while still null).
create or replace function public.airvalet_pass_on_passenger_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'DELIVERED' and old.status is distinct from 'DELIVERED' then
    update public.airvalet_pass_links l
       set expires_at = least(coalesce(new.checkout_date, now()), now()) + interval '3 hours'
     where l.passenger_id = new.id and l.revoked_at is null and l.expires_at is null;
  end if;
  if new.status = 'ARCHIVED' and old.status is distinct from 'ARCHIVED' then
    update public.airvalet_pass_links l set revoked_at = now(), revoke_reason = 'archived'
     where l.passenger_id = new.id and l.revoked_at is null;
  end if;
  if new.phone is distinct from old.phone then
    update public.airvalet_pass_links l set revoked_at = now(), revoke_reason = 'phone_changed'
     where l.passenger_id = new.id and l.revoked_at is null;
  end if;
  return null;
end;
$$;
create trigger airvalet_pass_passenger_change
  after update of status, phone on public.passengers
  for each row execute function public.airvalet_pass_on_passenger_change();

-- Staff revoke (immediate). Same ops roles that work the SMS inbox.
create or replace function public.airvalet_pass_revoke(p_passenger_id bigint)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  if public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.airvalet_pass_links l set revoked_at = now(), revoke_reason = 'staff', revoked_by = auth.uid()
   where l.passenger_id = p_passenger_id and l.revoked_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.airvalet_pass_new_token() from public, anon, authenticated;
revoke all on function public.airvalet_pass_mint(bigint) from public, anon, authenticated;
revoke all on function public.airvalet_pass_hit(text) from public, anon, authenticated;
revoke all on function public.airvalet_pass_view(text, text) from public, anon, authenticated;
revoke all on function public.airvalet_pass_on_passenger_change() from public, anon, authenticated;
revoke all on function public.airvalet_pass_revoke(bigint) from public, anon;
grant execute on function public.airvalet_pass_mint(bigint) to service_role;
grant execute on function public.airvalet_pass_view(text, text) to service_role;
grant execute on function public.airvalet_pass_revoke(bigint) to authenticated, service_role;

-- Inbox / passenger panel: link state per passenger, never the hash
-- (security_invoker keeps the column grant + RLS above).
create or replace view public.airvalet_sms_pass_status with (security_invoker = true) as
select l.passenger_id, l.created_at, l.expires_at, l.first_opened_at, l.last_opened_at, l.open_count,
       (l.expires_at is null or now() < l.expires_at) as active
  from public.airvalet_pass_links l
 where l.revoked_at is null;
revoke all on public.airvalet_sms_pass_status from public, anon, authenticated;
grant select on public.airvalet_sms_pass_status to authenticated, service_role;

commit;
