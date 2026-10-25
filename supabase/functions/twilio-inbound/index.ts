// twilio-inbound — passenger replies: Passenger → Twilio ("AirValet SMS"
// Messaging Service, incoming = "Send a webhook") → here → passenger_id →
// airvalet_sms_messages (direction 'inbound') → AirValet Inbox (Realtime).
//
// Public endpoint: deploy with --no-verify-jwt; protected by the Twilio
// signature against ${AIRVALET_SMS_PUBLIC_FUNCTIONS_URL}/twilio-inbound.
// Matching uses phone + conversation context (see
// airvalet_sms_match_passenger), never the ticket number alone.
// Replies with empty TwiML — AirValet sends no auto-reply (any hour); STOP/HELP
// answers come from Twilio Advanced Opt-Out.
// After a NEW guest message is stored, staff are notified (iPad push + the
// Super Admin SMS copy, both optional) in the background; texts from the
// Super Admin alert phone are never stored as guest messages.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readSmsConfig } from '../_shared/sms/config.ts';
import { makeRedactor } from '../_shared/sms/sanitize.ts';
import { supabaseSmsStore } from '../_shared/sms/supabase-store.ts';
import { handleInbound } from '../_shared/sms/webhooks.ts';
import { notifyEvent } from '../_shared/notify/notify.ts';
import { makeNotifyDeps } from '../_shared/notify/runtime.ts';

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

Deno.serve((req) => {
  const get = (k: string) => Deno.env.get(k);
  const cfg = readSmsConfig(get);
  const authToken = get('TWILIO_AUTH_TOKEN');
  const redact = makeRedactor([authToken, get('SUPABASE_SERVICE_ROLE_KEY'), get('AIRVALET_VAPID_PRIVATE_JWK')]);
  const log = (event: string, data: Record<string, unknown>) => console.log(redact(JSON.stringify({ event, ...data })));
  // Signature validation needs the Auth Token + exact public URL + our
  // Messaging Service SID; without all three nothing is accepted.
  if (!cfg.webhookReady) return new Response('not configured', { status: 503 });
  const admin = createClient(get('SUPABASE_URL')!, get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const store = supabaseSmsStore(admin);
  return handleInbound({
    authToken,
    publicUrl: `${cfg.publicFunctionsUrl}/twilio-inbound`,
    store,
    expectedMessagingServiceSid: get('TWILIO_MESSAGING_SERVICE_SID'),
    log,
    isAdminPhone: (e164) => store.isAdminAlertPhone!(e164),
    onGuestMessage: (messageId) => {
      const job = notifyEvent(makeNotifyDeps(admin, cfg, get, log), 'GUEST_MESSAGE', messageId);
      if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(job); else job.catch(() => {});
    },
  }, req);
});
