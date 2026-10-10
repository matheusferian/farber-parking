// twilio-status-callback — Twilio → AirValet delivery status
// (queued / sent / delivered / undelivered / failed).
//
// Public endpoint: deploy with --no-verify-jwt (Twilio has no Supabase JWT).
// Protection is the X-Twilio-Signature check against the PUBLIC URL
// ${AIRVALET_SMS_PUBLIC_FUNCTIONS_URL}/twilio-status-callback — never the
// internal URL the function sees. Requests from any Messaging Service other
// than AirValet's are ignored, so FarberOS traffic can never land here.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readSmsConfig } from '../_shared/sms/config.ts';
import { makeRedactor } from '../_shared/sms/sanitize.ts';
import { supabaseSmsStore } from '../_shared/sms/supabase-store.ts';
import { handleStatusCallback } from '../_shared/sms/webhooks.ts';

Deno.serve((req) => {
  const cfg = readSmsConfig((k) => Deno.env.get(k));
  const authToken = Deno.env.get('TWILIO_AUTH_TOKEN');
  const redact = makeRedactor([authToken, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')]);
  // Signature validation needs the Auth Token + exact public URL + our
  // Messaging Service SID; without all three nothing is accepted.
  if (!cfg.webhookReady) return new Response('not configured', { status: 503 });
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  return handleStatusCallback({
    authToken,
    publicUrl: `${cfg.publicFunctionsUrl}/twilio-status-callback`,
    store: supabaseSmsStore(admin),
    expectedMessagingServiceSid: Deno.env.get('TWILIO_MESSAGING_SERVICE_SID'),
    log: (event, data) => console.log(redact(JSON.stringify({ event, ...data }))),
  }, req);
});
