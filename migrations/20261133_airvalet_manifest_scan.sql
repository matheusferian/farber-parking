-- AirValet "Makers manifest" check (2026-11-06, owner): staff photograph the printed Makers Air
-- passenger manifests; the manifest-scan Edge Function reads them with Claude and matches the
-- names against the cars we hold (early returns, missing guests, tail + arrival time, name typos).
--
-- airvalet_manifest_scans: one row per scan, for audit, rate limit and cost. `result` keeps only
--   the rows that matched one of our passengers: the names of other travelers are not stored.
-- airvalet_manifest_feedback: what staff taught the matcher ("this manifest name is / is not this
--   passenger name"). The function reads it on every scan, so a confirmed pair matches the next time
--   and a rejected pair is never suggested again.
-- Both tables are closed (no anon / authenticated access). The Edge Function writes scans with the
-- service role; staff write feedback only through airvalet_manifest_feedback_set (ops roles).
begin;
set local lock_timeout = '5s';

create table if not exists public.airvalet_manifest_scans (
  id             bigserial primary key,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  service_date   date,
  pages          int not null default 0,
  manifest_rows  int not null default 0,
  matched        int not null default 0,
  surprises      int not null default 0,
  missing        int not null default 0,
  result         jsonb not null default '{}'::jsonb,
  usage          jsonb
);
create index if not exists airvalet_manifest_scans_created_idx on public.airvalet_manifest_scans (created_at desc);
alter table public.airvalet_manifest_scans enable row level security;
revoke all on public.airvalet_manifest_scans from public, anon, authenticated;

create table if not exists public.airvalet_manifest_feedback (
  manifest_name  text not null check (char_length(manifest_name) between 2 and 120),
  system_name    text not null check (char_length(system_name) between 2 and 120),
  verdict        text not null check (verdict in ('same', 'different')),
  created_at     timestamptz not null default now(),
  created_by     uuid,
  primary key (manifest_name, system_name)
);
alter table public.airvalet_manifest_feedback enable row level security;
revoke all on public.airvalet_manifest_feedback from public, anon, authenticated;

create or replace function public.airvalet_manifest_feedback_set(p_manifest_name text, p_system_name text, p_verdict text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare v_m text := upper(btrim(coalesce(p_manifest_name, ''))); v_s text := upper(btrim(coalesce(p_system_name, '')));
begin
  perform public.airvalet_portal_require_ops();
  if char_length(v_m) not between 2 and 120 or char_length(v_s) not between 2 and 120 or p_verdict not in ('same', 'different') then
    return jsonb_build_object('result', 'INVALID');
  end if;
  insert into public.airvalet_manifest_feedback (manifest_name, system_name, verdict, created_by)
  values (v_m, v_s, p_verdict, auth.uid())
  on conflict (manifest_name, system_name) do update
    set verdict = excluded.verdict, created_at = now(), created_by = excluded.created_by;
  return jsonb_build_object('result', 'OK');
end $function$;

revoke all on function public.airvalet_manifest_feedback_set(text, text, text) from public, anon;
grant execute on function public.airvalet_manifest_feedback_set(text, text, text) to authenticated;

commit;
