# AirValet Twilio — publication plan (PREPARED, NOT EXECUTED)

Every numbered step below needs its own explicit owner GO.

At each step, production keeps working on v46 with iPhone Messages until the owner:
1. approves a device,
2. turns texting on, and
3. presses START NEW CHECK-INS.

Nothing in this plan migrates existing tickets.

## 0. What is ready (local)
| Piece | Where | State |
|---|---|---|
| DB device model (Etapa 4) | prod | APPLIED 2026-10-10 19:59Z: texting OFF, test-only, 0 devices, no cutover |
| DB audit trail 20261012 | `~/Dev/airvalet-prod-backups/twilio-audit-20261012-prep/` | Guarded APPLY/DRYRUN built. Rehearsed on a replica of CURRENT prod: guard OK, 5/5 sabotages caught, v46 identical, rollback = current prod, suite 287 OK |
| Edge Functions send-sms, twilio-inbound, twilio-status-callback, valet-pass | branch `feature/twilio-sms-local` | Not deployed |
| AirValet app (device UI, admin panel, routing, dark launch) + pass.html | branch `feature/twilio-sms-local` | Not deployed (prod = main 591ce5d, SW v46) |
| FarberOS `/a` + `/a/api` route | FarberOS branch `feature/airvalet-pass-route` (worktree `~/Dev/worktrees/farberos-airvalet-pass`, commit 7eee830) | Not pushed |

## 1. Security checklist (all must be true before step 4)
- [ ] Staff phones use the shared IPHONE_OPS login and the operation iPad uses IPAD_OPS. ADMIN is only on the owner's devices.
  - Otherwise every staff phone could approve devices and START (step 2).
- [ ] TV: no texting. It is never approved, TV Mode never contacts the SMS functions, and a TV_ONLY login is refused by the server (tested).
- [ ] Twilio API key dedicated to AirValet (Standard key on the Farber account). Kept in function secrets only; never in the app, docs or chat.
- [ ] `AIRVALET_PASS_RATE_SALT` = new random secret (≥32 chars). Today it falls back to the public project URL.
- [ ] FarberOS Messaging Service MG4022… and Campaign CMa222… untouched. AirValet uses only MG9f8e…281f / CM690d….
- [ ] Program state before anything is visible: texting OFF, test-only ON, test numbers empty, no cutover. Verify read-only.
- [ ] Backups: daily Supabase backup of the day COMPLETED, a fresh T0 (catalog + data hashes) and a fresh data snapshot.
- [ ] Rollback paths below rehearsed (DB: replica; app/FarberOS: Vercel instant rollback IDs noted).

## 2. Logins (owner)
The owner does this in AirValet → User Access. No passwords are typed by Claude.
1. Create ONE shared login with role IPHONE_OPS, e.g. "iPhone".
2. On each staff phone: Sign Out of Admin, then sign in with IPHONE_OPS. Do it at shift change; no forced logout of other sessions.
3. Keep "iPad" (IPAD_OPS) for the operation iPad, and Admin, matheusferian, Marcio for the owner.

Closing Report:
- The daily closing (~16:30–19:30 ET) is done on the phones today.
- The app branch includes commit 44941b2, which gives IPHONE_OPS the Closing Report (server RLS already allows it). If the owner says no, drop that commit before step 4.
- Report / Logs / Debug stay hidden on phones.

## 3. Database audit trail (optional but recommended)
In `twilio-audit-20261012-prep/`:
1. Take a new T0 (catalog_fp.sql / data_fp.sql through the read-only endpoint).
2. Run `rwq.sh DRYRUN_audit_guarded.sql`. Expect HTTP 201, last row `CHANGED`-free.
3. Run `rwq.sh APPLY_audit_guarded.sql`.
4. Post-check: catalog = current + audit objects only; settings / devices unchanged; audit table empty.

Rollback: `20261012_airvalet_sms_audit_rollback.sql` (archives history).

## 4. Edge Functions (AirValet project sfewtirvqhrpanwhbchd), program still OFF
Secrets (set by the owner or from Keychain; never echoed):
```
AIRVALET_SMS_MODE=allowlist
AIRVALET_SMS_TEST_ALLOWLIST=+1<owner's confirmed number>
AIRVALET_SMS_PUBLIC_FUNCTIONS_URL=https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1
AIRVALET_PASS_BASE_URL=https://farberos.com/a#
AIRVALET_PASS_RATE_SALT=<random secret>
TWILIO_ACCOUNT_SID=<Farber account AC…>
TWILIO_API_KEY_SID=<AirValet API key SK…>
TWILIO_API_KEY_SECRET=<secret>
TWILIO_AUTH_TOKEN=<account auth token — only to verify webhook signatures>
TWILIO_MESSAGING_SERVICE_SID=MG9f8e2914abd018e27cad5d4881c3281f
```
Deploy (do not run without GO):
```
supabase functions deploy send-sms --project-ref sfewtirvqhrpanwhbchd
supabase functions deploy twilio-inbound --no-verify-jwt --project-ref sfewtirvqhrpanwhbchd
supabase functions deploy twilio-status-callback --no-verify-jwt --project-ref sfewtirvqhrpanwhbchd
supabase functions deploy valet-pass --no-verify-jwt --project-ref sfewtirvqhrpanwhbchd
```
Checks after deploy:
- send-sms without a JWT → 401.
- send-sms as Admin with no device → `DEVICE_NOT_AUTHORIZED` (DB program is OFF → `SMS_PAUSED`).
- twilio-inbound without a valid signature → 403.
- valet-pass with a junk token → `{"state":"expired"}`.

The Messaging Service already points its webhooks at `…/twilio-inbound` and `…/twilio-status-callback`; until now those return 404 (nothing breaks).

## 5. AirValet app (dark launch)
1. Merge `feature/twilio-sms-local` → main. The owner's GO also covers the commit list.
2. Vercel production deploy; service worker v47 (update banner, staff tap Reload).
3. Note the rollback deployment: current production = main 591ce5d.

With texting OFF:
- IPAD_OPS / IPHONE_OPS see exactly v46 (dark-launch E2E 12/12).
- Only ADMIN sees the "Request AirValet texting" card and the AirValet Texting panel.
- Customer Copy / Key Copy / Dashboard prints are byte-identical (E2E compares the XML).

Smoke after deploy (read-only + owner session):
- v46 TV, Needs Review, check-in **without** saving a real ticket.
- `/pass.html` served.
- No JavaScript errors.

## 6. FarberOS `/a` route
1. Push `feature/airvalet-pass-route` as a **preview first** (owner GO; Vercel builds a preview).
2. On the preview, verify:
   - `/a` serves pass.html;
   - `/a/api` reaches valet-pass;
   - **x-forwarded-for carries the passenger's IP** (rate limit per client);
   - FarberOS headers apply (no-store, no-referrer, noindex) and there are no CSP errors;
   - no cookie is set.
3. Production: merge to FarberOS main. The FarberOS deploy = push to main.

Rollback: revert commit 7eee830, or Vercel instant rollback.

## 7. Test on the owner's phone only
Precondition: the owner confirms the number in chat. It goes in BOTH places:
- `AIRVALET_SMS_TEST_ALLOWLIST` (Edge);
- `test_phones` (ADMIN `set_settings`).

Steps:
1. ADMIN panel: approve ONE owner device (e.g. the owner's iPhone with the Admin login).
2. Texting ON with **test mode ON**.
3. START NEW CHECK-INS.
4. Check in a TEST car with the owner's number and consent. First real SMS **only after the owner says "send"**.

Expected results:

| Check | Expected |
|---|---|
| CHECK_IN text arrives from +1 954-526-9800 | "Makers Air Valet: …" |
| Link | farberos.com/a#… opens, shows ticket / vehicle / pickup |
| Reply from the phone | Appears UNREAD in the AirValet inbox; staff reply arrives |
| HELP | Branded help text from Twilio; no extra AirValet reply |
| STOP → START | Blocked, then allowed (inbox shows the state) |
| Delivery | Delivered → "Send text?" → delivered text; link expires 3 h later ("This valet link has expired.") |
| Any other number | Refused (test mode); staff get "Send from iPhone Messages" |
| Twilio Console | Cost per segment and status match AirValet's log |

Cleanup:
- archive the test car (link revoked);
- STOP NEW CHECK-INS;
- texting stays ON or OFF as the owner decides.

## 8. Gradual activation — new check-ins only
1. Operation iPad and phones: Messages tab → "Request AirValet texting". ADMIN approves each one by name. Never the TV.
2. Test mode OFF (ADMIN). Texting ON. Limits stay at 4/h and 10/day per phone, 40/h per device, 300 texts and 600 segments per 24 h. Adjust only with GO.
3. START NEW CHECK-INS (typed START). Only cars checked in after that moment, with consent, on an approved device, join. Every older car stays on iPhone Messages forever.
4. Watch day 1:
   - ADMIN panel "Last 24 h" and "Recent activity";
   - Messages → Text alerts (unconfirmed);
   - Twilio Console errors (30007 = carrier filtering → link domain).

## 9. Instant off / rollback (fastest first)
| Need | Action | Effect |
|---|---|---|
| Stop all texting now | ADMIN → "Pause all texting" | Every device back to iPhone Messages at the next screen refresh. Nothing already sent is affected. |
| Stop new cars joining | ADMIN → STOP NEW CHECK-INS | Enrolled cars keep AirValet; new cars use iPhone. |
| A lost/stolen device | ADMIN → Remove | Server refuses it immediately. |
| Kill at the server | Secret `AIRVALET_SMS_MODE=disabled` | send-sms answers SMS_DISABLED; app offers iPhone (nothing sent). |
| App problem | Vercel instant rollback to the 591ce5d deployment (v46) | Exact v46. |
| FarberOS route problem | Revert 7eee830 / Vercel rollback | /a gone (links show nothing). |
| DB | Rollback scripts (reverse order) archive every SMS table in `airvalet_archive` (never dropped) | Only with an owner GO and a proven need. |

## 10. Known limits / follow-ups
- Twilio-side opt-out (Advanced Opt-Out) and the DB opt-out list are kept in sync by the inbound webhook. A STOP received while the functions were not deployed is not in the DB; it is still blocked by Twilio (error 21610 → recorded).
- The rate limit per passenger IP depends on Vercel forwarding x-forwarded-for (step 6 check).
- Template wording: CHECK_IN / RETURN_CONFIRMATION / VEHICLE_READY / VEHICLE_DELIVERED are marked PENDING_APPROVAL in code. Switch them to APPROVED (version strings) in `templates.ts` only after the owner approves the final wording. allowlist/live refuse unapproved templates.
