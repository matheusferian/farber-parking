// Simulate an incoming SMS to the local devserver, signed like Twilio does.
// deno run -A tests/event_valet/sim_sms.ts +19545550102 "ready"
import { computeSignature } from '../../supabase/functions/event-valet/lib.ts';
const [from, body] = Deno.args;
const url = 'http://127.0.0.1:8790/event-valet/inbound';
const params = { MessageSid: 'SM' + crypto.randomUUID().replace(/-/g, ''), From: from, To: '+19545269800', Body: body, AccountSid: 'AClocal', MessagingServiceSid: 'MGlocal' };
const sig = await computeSignature('local_test_auth_token', url, Object.entries(params));
const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Twilio-Signature': sig }, body: new URLSearchParams(params) });
console.log(r.status, await r.text());
