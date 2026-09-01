-- Phase 5 follow-up — dedicated TV Mode read RPC.
--
-- Gap found during post-implementation review of 20260901_restrict_tv_only_role.sql:
-- that migration correctly blocks TV_ONLY from `select` on public.passengers
-- (authenticated_passengers_select now requires
-- current_user_role() is distinct from 'TV_ONLY'), but TV Mode's own data
-- fetch (refreshTvData() -> sbGet() -> GET /rest/v1/passengers) is the exact
-- same table/endpoint/policy — so a real TV_ONLY account would get zero rows
-- back and TV Mode itself would render empty. This migration adds a narrow,
-- dedicated SECURITY DEFINER RPC for TV Mode's read instead of reopening
-- direct table access for TV_ONLY. Base-table RLS continues to block
-- TV_ONLY's direct `select` on passengers, unchanged by this migration.
--
-- ── Column set — least-privilege audit ──────────────────────────────
-- index.html's mapPassengerRow() (shared by loadData() and refreshTvData())
-- reads 30 columns off each row, but TV Mode does not render or compute
-- from all of them — it just tolerates the extra ones via `||''`/`||false`
-- defaults, same as it always has. Every TV-mode code path (buildTvViewModel,
-- tvCard, tvRow, tvBadges, tvFlightLine, tvWelcomeBackState, tvNeedsH19Move,
-- tvBuildTodayPages/tvBuildTomorrowPages/tvBuildOpsPages, and the
-- getCustomsDueRecords()/isCustomsGratuityReminderDue() chain that drives
-- the GRATUITY DUE badge) was read line-by-line, grepping every `r.<field>`
-- access, to confirm exactly which of the 30 are actually used.
--
-- 10 columns are excluded here, deliberately:
--   phone                     — never read by any TV code path (PII with
--                              no TV use — TV Mode has no messaging/calling
--                              feature).
--   customer_rating           — never read by any TV code path.
--   tip_received               — never read by any TV code path.
--   archived_by                — TV Mode only ever checks status==='ARCHIVED'
--                              to exclude a row from every list; it never
--                              displays who archived it.
--   archived_at                — same as archived_by: only the ARCHIVED
--                              status check matters, not this value.
--   previous_delivery_location — explicitly NOT used by TV Mode per the
--                              existing code comment at buildTvViewModel()
--                              ("TV Mode intentionally uses raw current
--                              `loc`... NOT... previous_delivery_location").
--   customs_welcome_sent_at    — only the boolean customs_welcome_sent is
--                              read by isCustomsGratuityReminderDue() (the
--                              function that drives the GRATUITY DUE badge);
--                              the timestamp itself is only used by the
--                              Customs tab / Messages Workspace (normal
--                              dashboard, not TV).
--   customs_gratuity_sent_at   — same reasoning as customs_welcome_sent_at.
--   block                      — found to be unused anywhere in the entire
--                              codebase, not just TV Mode (grep-confirmed:
--                              the only reference is mapPassengerRow's own
--                              `block: r.block||''` line) — excluded here
--                              as a TV-Mode-least-privilege matter; the
--                              base passengers.block column itself is
--                              untouched and out of this migration's scope.
--   obs                        — DELIBERATELY excluded even though TV Mode
--                              DOES render it today (tvCard()'s
--                              tv-card-notes block, Leaving Tomorrow cards
--                              only — tvRow(), used by every other panel,
--                              never reads it). Decision made explicitly
--                              after flagging the tradeoff: obs is
--                              unstructured free text with no content
--                              constraints, and TV screens may sit in
--                              semi-public/shared operational areas —
--                              accepted that the Leaving Tomorrow notes
--                              block simply won't render for the TV_ONLY
--                              RPC path (mapPassengerRow's `r.obs||''`
--                              default already makes this a no-op, not an
--                              error — the existing
--                              `r.obs ? '<div class="tv-card-notes">'+
--                              escapeHTML(r.obs)+'</div>' : ''` ternary
--                              degrades to '' cleanly). No other TV panel
--                              is affected.
--
-- The 20 columns returned below are genuinely exercised by TV Mode:
--   id, ts            — row identity; ts is checkin_date's fallback source
--                        in mapPassengerRow (checkin_date||ts) and
--                        checkin_date drives the Checked In Today panel.
--   name, ticket, car,
--   color, loc, status,
--   return_flight,
--   departure_time     — directly rendered on TV cards/rows (name, #ticket,
--                        vehicle meta, hangar/NO LOCATION alert, flight+time
--                        line).
--   ret                — drives Leaving Today/Tomorrow/Late qualification
--                        and sorting throughout buildTvViewModel().
--   deldate,
--   delivery_type,
--   checkin_date,
--   checkout_date      — drive list membership/eligibility computations
--                        (Lockbox Today, Customs-delivered, Customs-comm-
--                        eligible window) that produce visible TV badges.
--   not_returning_with_makers_air,
--   welcome_back_sent_at — directly drive the NOT RETURNING and WELCOME
--                        BACK SENT/OVERDUE/DUE badges.
--   customs_welcome_sent,
--   customs_gratuity_sent,
--   customs_gratuity_dismissed — the three booleans
--                        isCustomsGratuityReminderDue() reads to compute
--                        the GRATUITY DUE badge shown on Ops-page cards.
--
-- No parameters, no dynamic SQL, no client-supplied filter — the function
-- always returns the same full unfiltered row set (ordered by id, matching
-- sbGet()'s existing order=id.asc), just with a narrower column set than
-- the normal passengers path.
--
-- ── Who may call it — explicit fixed allowlist ──────────────────────
-- current_user_role() returns public.account_role, a closed 5-member enum,
-- so checking "is not null" is functionally identical to an explicit
-- 5-way allowlist today. An explicit allowlist is used anyway, as
-- defense-in-depth against a future enum change (e.g. a 6th role added to
-- account_role later without this function being revisited) and to keep
-- this project's "exactly 5 fixed roles, no generic RBAC" posture
-- self-documenting at the point of use. All 5 are allowed deliberately,
-- not by omission: isTvMode() (index.html) is a URL-only check
-- (`?mode=tv` or `#tv`), independent of role — any signed-in account can
-- already navigate to that URL and trigger refreshTvData() today (TV_ONLY
-- is merely forced into it, not the only role that can reach it).
-- Restricting this RPC to fewer than all 5 roles would silently break TV
-- Mode for whichever roles were excluded the moment those accounts exist,
-- even though nothing in the approved role matrix excludes any of them
-- from viewing TV Mode.

create or replace function public.get_tv_mode_passengers()
returns table (
  id                             bigint,
  ts                             text,
  name                           text,
  ticket                         text,
  ret                            text,
  car                            text,
  color                          text,
  loc                            text,
  status                         text,
  deldate                        text,
  delivery_type                  text,
  checkin_date                   timestamptz,
  checkout_date                  timestamptz,
  return_flight                  text,
  departure_time                 text,
  not_returning_with_makers_air  boolean,
  welcome_back_sent_at           timestamptz,
  customs_welcome_sent           boolean,
  customs_gratuity_sent          boolean,
  customs_gratuity_dismissed     boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.account_role;
begin
  if auth.uid() is null then
    raise exception 'get_tv_mode_passengers: authentication required';
  end if;

  v_role := public.current_user_role();
  if v_role is null or v_role not in (
    'ADMIN',
    'IPAD_OPS',
    'IPHONE_OPS',
    'TV_ONLY',
    'MANAGER'
  ) then
    raise exception 'get_tv_mode_passengers: role not permitted';
  end if;

  return query
  select
    p.id, p.ts, p.name, p.ticket, p.ret, p.car, p.color, p.loc, p.status,
    p.deldate, p.delivery_type, p.checkin_date, p.checkout_date, p.return_flight,
    p.departure_time, p.not_returning_with_makers_air, p.welcome_back_sent_at,
    p.customs_welcome_sent, p.customs_gratuity_sent, p.customs_gratuity_dismissed
  from public.passengers p
  order by p.id asc;
end;
$$;

revoke all on function public.get_tv_mode_passengers() from public;
grant execute on function public.get_tv_mode_passengers() to authenticated;
