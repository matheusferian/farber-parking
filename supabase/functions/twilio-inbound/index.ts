// twilio-inbound — passenger replies: Passenger → Twilio ("AirValet SMS"
// Messaging Service, incoming = "Send a webhook") → here → passenger_id →
// airvalet_sms_messages (direction 'inbound') → future AirValet inbox.
//
// Public endpoint: deploy with --no-verify-jwt; protected by the Twilio
// signature against ${AIRVALET_SMS_PUBLIC_FUNCTIONS_URL}/twilio-inbound.
// Matching uses phone + conversation context (see
// airvalet_sms_match_passenger), never the ticket number alone.
// Replies with empty TwiML — AirValet sends no auto-reply; STOP/HELP answers
// come from Twilio Advanced Opt-Out.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { readSmsConfig } from '../_shared/sms/config.ts';
import { makeRedactor } from '../_shared/sms/sanitize.ts';
import { supabaseSmsStore } from '../_shared/sms/supabase-store.ts';
import { handleInbound } from '../_shared/sms/webhooks.ts';

Deno.serve((req) => {
  const cfg = readSmsConfig((k) => Deno.env.get(k));
  const authToken = Deno.env.get('TWILIO_AUTH_TOKEN');
  const redact = makeRedactor([authToken, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')]);
  // Signature validation needs the Auth Token + exact public URL + our
  // Messaging Service SID; without all three nothing is accepted.
  if (!cfg.webhookReady) return new Response('not configured', { status: 503 });
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  return handleInbound({
    authToken,
    publicUrl: `${cfg.publicFunctionsUrl}/twilio-inbound`,
    store: supabaseSmsStore(admin),
    expectedMessagingServiceSid: Deno.env.get('TWILIO_MESSAGING_SERVICE_SID'),
    log: (event, data) => console.log(redact(JSON.stringify({ event, ...data }))),
  }, req);
});
