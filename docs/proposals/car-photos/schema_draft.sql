-- DRAFT — NOT A MIGRATION. NOT APPLIED ANYWHERE. Proposal 2026-11-18 (arrival car photos).
-- Kept outside migrations/ on purpose so no deploy script can pick it up.
-- Before it becomes a real migration: owner OK, a free number (20261154_* is taken by the TV work),
-- a rollback file, and a test in a rollback transaction on a local stack.

-- 1) Private bucket: JPEG only, 1 MB max per photo (the app sends ~250 KB at 1600 px).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('car-photos', 'car-photos', false, 1048576, array['image/jpeg'])
on conflict (id) do nothing;

-- 2) One row per photo. taken_at is the SERVER time (the proof); device time is informative only.
create table if not exists public.airvalet_car_photos (
  id               uuid primary key default gen_random_uuid(),
  passenger_id     bigint not null references public.passengers(id) on delete cascade,
  stage            text not null check (stage in ('ARRIVAL', 'DELIVERY')),
  angle            text not null check (angle in ('driver', 'front', 'passenger', 'rear', 'close')),
  storage_path     text not null unique,                -- car-photos/<passenger_id>/<stage>/<angle>-<uuid>.jpg
  sha256           text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  bytes            integer not null check (bytes > 0 and bytes <= 1048576),
  width            integer, height integer,
  device_taken_at  timestamptz,
  taken_at         timestamptz not null default now(),
  taken_by         uuid not null default auth.uid(),
  hold             boolean not null default false,      -- complaint open: never auto-delete
  delete_after     timestamptz                          -- set at delivery = delivered + 30 days
);
create index if not exists airvalet_car_photos_passenger on public.airvalet_car_photos (passenger_id, stage);
create index if not exists airvalet_car_photos_cleanup on public.airvalet_car_photos (delete_after) where not hold;

alter table public.airvalet_car_photos enable row level security;
-- Staff can add and see photos. Nobody edits or deletes from the app: photos are evidence.
create policy car_photos_select on public.airvalet_car_photos for select to authenticated
  using (public.current_user_role() in ('ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'));
create policy car_photos_insert on public.airvalet_car_photos for insert to authenticated
  with check (public.current_user_role() in ('ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS') and taken_by = auth.uid());

create policy car_photos_obj_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'car-photos' and public.current_user_role() in ('ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'));
create policy car_photos_obj_select on storage.objects for select to authenticated
  using (bucket_id = 'car-photos' and public.current_user_role() in ('ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS'));
-- No update/delete policy on storage.objects for car-photos: only the service role (cleanup job) deletes.

-- 3) Plate on the car record (today only car + color exist as text).
alter table public.passengers add column if not exists plate text;
alter table public.passengers add column if not exists plate_state text;

-- 4) What the AI suggested and whether staff accepted it (cost + accuracy tracking).
create table if not exists public.airvalet_vehicle_ai (
  id            bigint generated always as identity primary key,
  passenger_id  bigint references public.passengers(id) on delete set null,
  model         text not null,
  input_tokens  integer, output_tokens integer,
  result        jsonb not null,          -- make, model, color, plate, marks, confidences
  accepted      boolean,                 -- null = no answer yet
  created_by    uuid not null default auth.uid(),
  created_at    timestamptz not null default now()
);
alter table public.airvalet_vehicle_ai enable row level security;
create policy vehicle_ai_select on public.airvalet_vehicle_ai for select to authenticated
  using (public.current_user_role() in ('ADMIN', 'MANAGER'));

-- 5) Retention: at delivery, set delete_after = now() + 30 days (trigger on passengers.status → DELIVERED).
--    A daily job (Edge Function with the service role) removes the storage objects and rows where
--    delete_after < now() and hold = false. ADMIN can set hold = true through an RPC when a guest complains.
