# AirValet Twilio — status at end of day 2026-10-10 and how to resume

## Production (verified read-only 2026-10-10 20:44 UTC)
- App: airvalet.farberos.com = main 591ce5d, service worker v46, `SMS_PROVIDER = 'native'` (iPhone Messages). None of the Etapa 5 UI is published.
- Not published: Edge Functions send-sms / twilio-inbound / twilio-status-callback / valet-pass; route farberos.com/a (404); /pass.html (404).
- Database (Supabase sfewtirvqhrpanwhbchd): the Etapa 4 migrations are applied (20261009 / 20261010 / 20261011, device model). State:
  - sending OFF, test_only ON, 0 test numbers, no cutover;
  - 0 devices, 0 enrollments, 0 messages, 0 consents, 0 links.
  - The catalog is identical to the one right after the apply. v46 reads OK as Admin: TV 3,554, 32 open, Needs Review 0.
- Unchanged: logins, sessions, passwords, permissions, FarberOS (abccf5c), Revenue, Twilio Console.
- Twilio: Campaign CM690d… APPROVED; +1 954-526-9800 on Messaging Service "AirValet SMS" MG9f8e…; Advanced Opt-Out set up (Etapa 3). Nothing sends: no function is deployed and the DB program is OFF.

## Done (branch feature/twilio-sms-local, local checkpoint commit)
- Etapas 1–3: review, short link farberos.com/a#TOKEN, local fixes, Twilio Console opt-out setup.
- Etapa 4: device-model migrations, guarded APPLY in production. Folder ~/Dev/airvalet-prod-backups/twilio-etapa4-2026-10-10 (ETAPA4_APPLY_REPORT.md, rollbacks, snapshots).
- Etapa 5 (local only), in index.html / styles.css:
  - device key + request / approval;
  - Messages-tab device card;
  - "Texted by" (Clock In names) and "Who is texting?" picker;
  - per-ticket routing (enrolled → AirValet, everything else → iPhone);
  - safe iPhone fallback, only when the server confirms nothing was sent; Customs gratuity always via iPhone;
  - ADMIN panel in User Access: Approve / Reject / Remove, START NEW CHECK-INS (typed) / STOP, Pause all texting.
  - Edge: _shared/sms/device.ts; send-sms reads x-airvalet-device + staff_name.
- Owner decisions recorded:
  - D1: ADMIN only on owner devices, IPAD_OPS = operation iPad, IPHONE_OPS = operation phones, TV unchanged, no individual logins.
  - D2: Customs gratuity → iPhone fallback, never via Twilio; no fallback when the result is uncertain.

## Tests (local, last run 2026-10-10)
| Suite | Result |
|---|---|
| E2E roles (ADMIN / IPAD_OPS / IPHONE_OPS / TV_ONLY) | 43/43 |
| E2E Etapa 5 | 40/40 |
| E2E inbox / link | 28/28 |
| E2E Etapa 2 | 12/12 |
| Link security | 42/42 |
| DB runner (SQL, race 20→1, cap 20→5, integration) | 321 checks, 8/8 integration |
| Deno | 68/68 |
| Node | 7/7 |

v46 parity: only 8 of 578 v46 functions differ, all behind the SMS gates. Print builders, epsonSend, TV and Return/Pickup are byte-identical. Customer/Key/Dashboard XML is identical with or without AirValet texting.

Scripts are in the session scratchpad airvalet-local (e2e_roles.mjs, e2e_etapa5.mjs, e2e.mjs, e2e_etapa2.mjs, passlink_security.mjs, reseed_inbox.sql, harness.py). Copies are in ~/Dev/airvalet-prod-backups/etapa5-local-tests-20261010/.

## Open items / decisions
1. **Production has no IPHONE_OPS login.** Today it has Admin, Marcio, matheusferian (ADMIN) and iPad (IPAD_OPS), and the staff iPhones use the shared "Admin" login. D1 needs:
   - one shared IPHONE_OPS login;
   - the phones moved to it;
   - Admin kept only on owner devices.
   All of that needs an owner GO (production login change).
2. **IPHONE_OPS does not see Closing Report** (tab and EOD button), Report, Logs or Debug; the server would allow them. Decide whether phones need Closing Report.
3. **The TV runs TV Mode from an Admin/iPad session.** It is isolated in the app and never approved for texting. A TV_ONLY login is optional; kept as is per owner.
4. **Publication is not done.** It needs a separate GO for each step below.
5. **Service worker:** the branch has v47; confirm the bump when publishing.
6. **Pre-existing v46 fragility, not from this work:** the app script fails if utils.js fails to load.

## How to resume (each step only with the owner's GO)
1. **Local first.**
   - Start the stack: `supabase start` in the scratchpad airvalet-local, then `supabase functions serve --env-file functions.env` (mock) and `python3 harness.py` (:8766).
   - Re-run the suites listed above.
2. **Logins (D1):** create the shared IPHONE_OPS login and move the staff phones to it, without ending sessions unexpectedly. Keep Admin on the owner's devices.
3. **Publish dark.** Nothing changes for staff until an ADMIN approves a device and presses START.
   - Deploy the Edge Functions with AIRVALET_SMS_MODE=allowlist and the secrets. The program stays OFF.
   - Publish the app (Etapa 5 UI) and the FarberOS /a route.
4. **Owner phone test:**
   - set test_phones = the owner's confirmed number, test_only ON, sending ON;
   - approve one owner device;
   - START NEW CHECK-INS;
   - first real SMS only after explicit authorization.
   Then test link, reply, inbox, STOP/START, delivery and expiry.
5. **Go live (on GO):** approve the operation iPad and phones (never the TV), set test_only OFF, START NEW CHECK-INS. Old tickets always stay on iPhone Messages.
6. **Instant off:** Pause all texting, STOP NEW CHECK-INS, or Remove a device. The app returns to iPhone Messages.
