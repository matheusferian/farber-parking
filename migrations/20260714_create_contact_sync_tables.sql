-- Daily Contact Sync — database-backed sync state for the iPhone Contacts
-- workflow (replaces the localStorage-only "last export" tracking).
-- Additive only: creates two new tables. Does NOT alter, rename, or drop
-- any column on `passengers` or any other existing table. Safe to run
-- more than once (all statements are idempotent).
--
-- Revision 7 (2026-07-15): every workflow now creates a batch as
-- GENERATED, inserts all its items, and only then transitions it to
-- CONFIRMED or CANCELLED (see revision 5) — so direct insertion of a
-- batch already CONFIRMED or CANCELLED is no longer a legitimate case for
-- any workflow, including BASELINE. contact_sync_batches_protect_insert()
-- now explicitly rejects any insert where status <> 'GENERATED', instead
-- of only checking confirmed_by/cancelled_by identity conditionally.
-- Comments elsewhere in this file that referred to "a BASELINE batch
-- inserted directly as CONFIRMED" described the pre-revision-5 workflow
-- and have been corrected — that path no longer exists anywhere in the
-- app or in this schema.
--
-- Revision 6 (2026-07-15): wrapped the whole migration in a single
-- transaction (BEGIN ... COMMIT). All DDL used here (CREATE TABLE, CREATE
-- INDEX, CREATE TRIGGER, CREATE POLICY, ALTER TABLE, the DO block) is
-- transactional in PostgreSQL — none of it is CREATE INDEX CONCURRENTLY,
-- which is the one common DDL statement that cannot run inside a
-- transaction block. If any statement fails, everything below rolls back
-- and no table, trigger, function, or policy is left half-created.
--
-- Revision 5 (2026-07-15): the contact_sync_items INSERT policy was
-- `with check (true)` — any authenticated user could append items to ANY
-- batch, including one already CONFIRMED or CANCELLED, which would let
-- confirmed sync history / the baseline fingerprint set be tampered with
-- retroactively. Fixed with two layers:
--   - RLS: items may only be inserted when the parent batch exists, has
--     status = 'GENERATED', and was created by the inserting user.
--   - A BEFORE INSERT trigger on contact_sync_items re-checks the exact
--     same four conditions (auth email present; batch exists; batch is
--     GENERATED; batch belongs to the caller) as database-level defense
--     in depth, independent of the RLS policy.
-- This also forced a change to the app-side baseline workflow: a BASELINE
-- batch can no longer be inserted directly as CONFIRMED (the items policy
-- above would then reject every item insert, since the batch wouldn't be
-- GENERATED anymore by the time items are written). Baseline creation is
-- now: insert BASELINE as GENERATED -> insert all items -> update to
-- CONFIRMED only after every item insert succeeds. The same sequence
-- applies when "Use This Full Export as New Baseline" creates a new
-- BASELINE batch. See index.html (confirmCreateBaseline(),
-- confirmFullExportAsBaseline(), safelyCancelOrphanedBatch()).
--
-- Revision 4 (2026-07-15): CHECK constraints must not call auth.jwt() —
-- they should validate only row-state consistency (which fields are
-- null/non-null for a given status), not caller identity. Identity
-- matching (created_by/confirmed_by/cancelled_by = the authenticated
-- user's own email) is now enforced entirely by RLS + triggers:
--   - created_by:              INSERT RLS policy (csb_insert_own)
--   - confirmed_by/cancelled_by at insert time (BASELINE inserted
--     directly as CONFIRMED):  BEFORE INSERT trigger
--   - confirmed_by/cancelled_by at update time (confirm/cancel a
--     GENERATED batch):        BEFORE UPDATE trigger
-- Both triggers explicitly reject the operation if the authenticated
-- email (auth.jwt()->>'email') is null or empty, before checking anything
-- else. See the bottom of this file for the full explanation.
--
-- Revision 3 (2026-07-15): this is a shared operational system used by
-- multiple authenticated attendants across shifts, so ownership-restricted
-- UPDATE was wrong — any attendant must be able to resolve a batch a
-- teammate left unconfirmed from a previous shift. UPDATE RLS is open to
-- any authenticated user; a BEFORE UPDATE trigger is what actually
-- prevents tampering with immutable fields or illegal status transitions.

BEGIN;

create extension if not exists pgcrypto;

-- One row per generated/confirmed/cancelled sync attempt (baseline, daily
-- sync, or full recovery export).
create table if not exists public.contact_sync_batches (
  id                uuid primary key default gen_random_uuid(),
  created_at        timestamptz not null default now(),
  created_by        text not null,
  batch_type        text not null check (batch_type in ('BASELINE','DAILY','FULL_EXPORT')),
  status            text not null default 'GENERATED' check (status in ('GENERATED','CONFIRMED','CANCELLED')),
  generated_count   integer not null default 0,
  unique_count      integer not null default 0,
  duplicate_count   integer not null default 0,
  invalid_count     integer not null default 0,
  confirmed_at      timestamptz,
  confirmed_by      text,
  cancelled_at      timestamptz,
  cancelled_by      text,
  filename          text,
  notes             text,

  constraint csb_no_negative_counts check (
    generated_count >= 0 and unique_count >= 0 and duplicate_count >= 0 and invalid_count >= 0
  ),

  -- Row-state consistency only — no auth.jwt() / no identity checks here.
  -- Exactly one of the three branches must hold, matched to `status`:
  --   GENERATED  -> confirmed_at/by and cancelled_at/by are all null.
  --   CONFIRMED  -> confirmed_at/by are set; cancelled_at/by stay null.
  --   CANCELLED  -> cancelled_at/by are set; confirmed_at/by stay null.
  constraint csb_status_fields_consistent check (
    (status = 'GENERATED' and confirmed_at is null and confirmed_by is null
                           and cancelled_at is null and cancelled_by is null)
    or
    (status = 'CONFIRMED' and confirmed_at is not null and confirmed_by is not null
                           and cancelled_at is null and cancelled_by is null)
    or
    (status = 'CANCELLED' and cancelled_at is not null and cancelled_by is not null
                           and confirmed_at is null and confirmed_by is null)
  )
);

-- If this migration is being re-run on a database where the table already
-- exists from a prior partial apply, backfill and tighten created_by
-- before enforcing NOT NULL, so the ALTER can't fail on existing rows.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='contact_sync_batches' and column_name='created_by') then
    update public.contact_sync_batches set created_by = 'unknown@pre-existing-row' where created_by is null;
    alter table public.contact_sync_batches alter column created_by set not null;
  end if;
end $$;

create index if not exists idx_contact_sync_batches_status      on public.contact_sync_batches(status);
create index if not exists idx_contact_sync_batches_type_status on public.contact_sync_batches(batch_type, status);
create index if not exists idx_contact_sync_batches_created_at  on public.contact_sync_batches(created_at desc);

-- One row per unique contact included in a batch. Immutable once written —
-- a batch's outcome (confirmed/cancelled) is tracked on the parent batch
-- row above, never by editing items. `passenger_id` references the specific
-- passengers row that contributed the winning name/phone for its batch
-- (dedup picks the most-recently-updated usable record per phone number).
create table if not exists public.contact_sync_items (
  id                  uuid primary key default gen_random_uuid(),
  batch_id            uuid not null references public.contact_sync_batches(id) on delete cascade,
  passenger_id        bigint references public.passengers(id) on delete set null,
  passenger_name      text not null,
  normalized_phone    text not null,
  contact_fingerprint text not null,
  source_updated_at   timestamptz,
  created_at          timestamptz not null default now()
);

create index if not exists idx_contact_sync_items_batch_id     on public.contact_sync_items(batch_id);
create index if not exists idx_contact_sync_items_fingerprint  on public.contact_sync_items(contact_fingerprint);
create index if not exists idx_contact_sync_items_passenger_id on public.contact_sync_items(passenger_id);

-- Database-safety backstop for the client-side dedup in buildSyncCandidateContacts():
-- the same batch can never contain two items for the same phone number or
-- the same contact fingerprint. Scoped per batch_id (not global) because a
-- contact legitimately reappears across different batches over time (e.g.
-- pending again after a name/phone change).
create unique index if not exists uq_contact_sync_items_batch_phone
  on public.contact_sync_items(batch_id, normalized_phone);
create unique index if not exists uq_contact_sync_items_batch_fingerprint
  on public.contact_sync_items(batch_id, contact_fingerprint);

-- ── BEFORE INSERT trigger: every batch is born GENERATED ──
-- created_by identity is enforced separately by the INSERT RLS policy
-- (csb_insert_own, below) — a simple "column must equal my own email" rule
-- that RLS expresses natively. Every workflow (DAILY sync, FULL_EXPORT,
-- and BASELINE — including "Use This Full Export as New Baseline")
-- creates a batch as GENERATED, inserts all its items, and only
-- afterwards transitions it to CONFIRMED or CANCELLED via the BEFORE
-- UPDATE trigger below. There is no longer any legitimate case for a
-- batch to be inserted already CONFIRMED or CANCELLED, so that's rejected
-- outright here. The confirmed_by/cancelled_by identity checks below are
-- consequently defense in depth, not the primary guard — the explicit
-- status check already blocks the only way those fields could legitimately
-- be non-null at insert time, and the csb_status_fields_consistent CHECK
-- constraint independently requires them null whenever status is
-- GENERATED. Keeping specific, separate checks here just gives a clearer
-- error message than a generic constraint violation would.
create or replace function public.contact_sync_batches_protect_insert()
returns trigger language plpgsql as $$
declare
  v_auth_email text := auth.jwt() ->> 'email';
begin
  if v_auth_email is null or v_auth_email = '' then
    raise exception 'contact_sync_batches: no authenticated user email available for insert';
  end if;

  if new.status <> 'GENERATED' then
    raise exception 'contact_sync_batches: new batches must be inserted with GENERATED status';
  end if;

  if new.confirmed_by is not null and new.confirmed_by is distinct from v_auth_email then
    raise exception 'contact_sync_batches: confirmed_by must equal the authenticated user (got %)', new.confirmed_by;
  end if;

  if new.cancelled_by is not null and new.cancelled_by is distinct from v_auth_email then
    raise exception 'contact_sync_batches: cancelled_by must equal the authenticated user (got %)', new.cancelled_by;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_contact_sync_batches_protect_insert on public.contact_sync_batches;
create trigger trg_contact_sync_batches_protect_insert
  before insert on public.contact_sync_batches
  for each row execute function public.contact_sync_batches_protect_insert();

-- ── BEFORE UPDATE trigger: field immutability + status-transition guard ──
-- This is the real protection for contact_sync_batches once RLS is open to
-- any authenticated user (see below) — RLS only gates "must be signed in,"
-- not which fields change or which transitions are legal.
create or replace function public.contact_sync_batches_protect_update()
returns trigger language plpgsql as $$
declare
  v_auth_email text := auth.jwt() ->> 'email';
begin
  if v_auth_email is null or v_auth_email = '' then
    raise exception 'contact_sync_batches: no authenticated user email available for update on batch %', old.id;
  end if;

  -- 1. Immutable fields: never allowed to change after insert, no matter
  --    which lifecycle field the update is trying to change at the same time.
  if new.id is distinct from old.id
     or new.created_at is distinct from old.created_at
     or new.created_by is distinct from old.created_by
     or new.batch_type is distinct from old.batch_type
     or new.generated_count is distinct from old.generated_count
     or new.unique_count is distinct from old.unique_count
     or new.duplicate_count is distinct from old.duplicate_count
     or new.invalid_count is distinct from old.invalid_count
     or new.filename is distinct from old.filename
     or new.notes is distinct from old.notes
  then
    raise exception 'contact_sync_batches: immutable field changed on batch % (only status/confirmed_*/cancelled_* may change)', old.id;
  end if;

  -- 2. Status transitions: only GENERATED -> CONFIRMED and
  --    GENERATED -> CANCELLED are legal. This also rejects any update that
  --    leaves status unchanged, since none of the currently mutable fields
  --    (confirmed_*/cancelled_*) have a legitimate reason to change outside
  --    of one of these two transitions. (The csb_status_fields_consistent
  --    CHECK constraint independently re-validates the resulting row's
  --    internal consistency regardless of transition — this trigger is
  --    about *identity* and *which transition*, the CHECK constraint is
  --    about *row-state* consistency.)
  if old.status = 'GENERATED' and new.status = 'CONFIRMED' then
    if new.confirmed_by is distinct from v_auth_email then
      raise exception 'contact_sync_batches: confirmed_by must equal the authenticated user (batch %)', old.id;
    end if;

  elsif old.status = 'GENERATED' and new.status = 'CANCELLED' then
    if new.cancelled_by is distinct from v_auth_email then
      raise exception 'contact_sync_batches: cancelled_by must equal the authenticated user (batch %)', old.id;
    end if;

  else
    raise exception 'contact_sync_batches: invalid status transition % -> % on batch % (only GENERATED->CONFIRMED and GENERATED->CANCELLED are allowed)', old.status, new.status, old.id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_contact_sync_batches_protect_update on public.contact_sync_batches;
create trigger trg_contact_sync_batches_protect_update
  before update on public.contact_sync_batches
  for each row execute function public.contact_sync_batches_protect_update();

-- Row Level Security — same authenticated-internal-app model as
-- daily_closing_reports (not the fully-open `allow_all` style used by the
-- older activity_log table). No anonymous access to sync data or contact
-- fingerprints. No delete access for any role: a batch is superseded by
-- changing its status, never removed.

alter table public.contact_sync_batches enable row level security;
alter table public.contact_sync_items   enable row level security;

-- SELECT: open to any authenticated staff member — everyone needs to see
-- pending counts, sync history, and in-flight batches regardless of who
-- created them.
drop policy if exists "csb_select_authenticated" on public.contact_sync_batches;
create policy "csb_select_authenticated"
  on public.contact_sync_batches for select to authenticated using (true);

-- INSERT: any authenticated user may create a batch, but only as
-- themselves — created_by must equal their own JWT email. Without this,
-- a row could be inserted already "owned" by someone else's identity.
-- (confirmed_by/cancelled_by identity checks live in the BEFORE INSERT
-- trigger above, since they're conditional on status, not a fixed column.)
drop policy if exists "csb_insert_authenticated" on public.contact_sync_batches;
drop policy if exists "csb_insert_own" on public.contact_sync_batches;
create policy "csb_insert_own"
  on public.contact_sync_batches for insert to authenticated
  with check (created_by = (auth.jwt() ->> 'email'));

-- UPDATE: open to any authenticated user — this is a shared operational
-- tool, and any attendant must be able to confirm or cancel a batch left
-- over from a previous shift. The BEFORE UPDATE trigger above (not this
-- policy) is what actually prevents tampering with immutable fields or
-- performing an illegal status transition; RLS here only gates "must be
-- signed in," matching the same model as every other write policy in this
-- system.
drop policy if exists "csb_update_authenticated" on public.contact_sync_batches;
drop policy if exists "csb_update_own" on public.contact_sync_batches;
create policy "csb_update_authenticated"
  on public.contact_sync_batches for update to authenticated
  using (true)
  with check (true);

-- contact_sync_items: write-once. SELECT + INSERT only, no UPDATE, no
-- DELETE, for any role.
drop policy if exists "csi_select_authenticated" on public.contact_sync_items;
create policy "csi_select_authenticated"
  on public.contact_sync_items for select to authenticated using (true);

-- INSERT: only into a batch that (a) exists, (b) is still GENERATED, and
-- (c) was created by the inserting user. Without this, any authenticated
-- user could append (or, combined with the unique indexes, silently fail
-- to append) items to someone else's batch, or to a batch that has
-- already been CONFIRMED or CANCELLED — retroactively altering confirmed
-- sync history and the baseline fingerprint set. This is why every batch
-- (BASELINE included) must be inserted as GENERATED and only promoted to
-- CONFIRMED after its items exist — enforced by
-- contact_sync_batches_protect_insert() above, not just by app-code
-- convention (see revision 7 note at the top of this file).
drop policy if exists "csi_insert_authenticated" on public.contact_sync_items;
drop policy if exists "csi_insert_into_own_generated_batch" on public.contact_sync_items;
create policy "csi_insert_into_own_generated_batch"
  on public.contact_sync_items
  for insert
  to authenticated
  with check (
    exists (
      select 1
      from public.contact_sync_batches b
      where b.id = batch_id
        and b.status = 'GENERATED'
        and b.created_by = (auth.jwt() ->> 'email')
    )
  );

-- BEFORE INSERT trigger: database-level defense in depth for the same
-- four conditions the RLS policy above enforces, with explicit, specific
-- error messages instead of RLS's generic "new row violates row-level
-- security policy." Independent of the policy — if the policy were ever
-- misconfigured or dropped, this trigger still holds.
create or replace function public.contact_sync_items_protect_insert()
returns trigger language plpgsql as $$
declare
  v_auth_email text := auth.jwt() ->> 'email';
  v_batch public.contact_sync_batches%rowtype;
begin
  if v_auth_email is null or v_auth_email = '' then
    raise exception 'contact_sync_items: no authenticated user email available for insert';
  end if;

  select * into v_batch from public.contact_sync_batches where id = new.batch_id;

  if not found then
    raise exception 'contact_sync_items: parent batch % does not exist', new.batch_id;
  end if;

  if v_batch.status <> 'GENERATED' then
    raise exception 'contact_sync_items: parent batch % is not GENERATED (status=%)', new.batch_id, v_batch.status;
  end if;

  if v_batch.created_by is distinct from v_auth_email then
    raise exception 'contact_sync_items: parent batch % was not created by the authenticated user', new.batch_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_contact_sync_items_protect_insert on public.contact_sync_items;
create trigger trg_contact_sync_items_protect_insert
  before insert on public.contact_sync_items
  for each row execute function public.contact_sync_items_protect_insert();

-- No update/delete policy on contact_sync_items: items are write-once.
-- No delete policy on contact_sync_batches: batches are superseded by
-- status change (GENERATED -> CONFIRMED or CANCELLED), never removed.

COMMIT;
