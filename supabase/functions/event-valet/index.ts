// Entry point — see handler.ts. Deploy: supabase functions deploy event-valet --no-verify-jwt
import { makeHandler } from './handler.ts';

const handle = makeHandler((k) => Deno.env.get(k));
Deno.serve(handle);
