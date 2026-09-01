// Phase 5 — ADMIN-only Auth account administration (Create/Disable/
// Enable/Delete User). This is the ONLY code in the project authorized
// to call the Supabase Auth Admin API or hold the service-role key — the
// browser never receives it (Deno env var only, server-side).
//
// Every request goes through the same shape:
//   1. Supabase's platform-level JWT verification (this function is
//      deployed with the default verify_jwt: true, same as the
//      project's existing refresh-aircraft-state function) rejects any
//      request without a valid project JWT before this code runs at
//      all.
//   2. A second, INDEPENDENT check here: a Supabase client built with
//      the CALLER's own JWT (not the service role) calls
//      current_user_role() through PostgREST/RLS — if that isn't
//      'ADMIN', the request is refused (403) before touching Auth Admin
//      or any user_profiles row. Same never-trust-a-client-supplied-flag
//      pattern already used by every guarded RPC in this project
//      (set_user_role(), get_tv_mode_passengers()).
//   3. Only after that passes does a SEPARATE client, built with
//      SUPABASE_SERVICE_ROLE_KEY (a Deno env var available only inside
//      this server-side function, never bundled into any frontend
//      asset), get used — and only for the two things Postgres itself
//      cannot do: calling auth.admin.createUser/deleteUser/updateUserById,
//      and one pre-check SELECT against user_profiles (a read, not a
//      mutation) to give a clean "username already in use" error before
//      ever creating a real Auth account.
//   4. Every user_profiles WRITE (create/disable/enable/delete) goes
//      through a dedicated SECURITY DEFINER RPC
//      (admin_create_user_profile / admin_set_user_active /
//      admin_delete_user_profile — see
//      migrations/20260901_add_admin_user_management_rpcs.sql), called
//      with the CALLER's own JWT, not the service-role key — so even if
//      this function's own ADMIN check in step 2 had a bug, the
//      database-side RPC would independently refuse a non-ADMIN caller
//      anyway. Defense in depth, not a single point of trust.
//
// Username -> internal email: deterministic canonicalization
// (canonicalizeUsername below), identical in shape to the frontend's
// copy in index.html (emailForLoginUsername()) so both sides always
// agree on what email a given username maps to. "admin" is reserved —
// it can never be created through this function, since that identity
// belongs to the pre-existing, protected makers@farber.local account
// (seeded outside this function, in
// migrations/20260901_create_user_profiles_and_roles.sql) and is
// additionally already blocked by user_profiles' own case-insensitive
// unique index on username.
//
// Password handling: received once in the request body over HTTPS,
// passed directly to auth.admin.createUser(), never written to any log
// statement, never stored in user_profiles or anywhere else in this
// file.

import { createClient } from 'npm:@supabase/supabase-js@2';

function canonicalizeUsername(raw: string): string {
  const trimmed = String(raw ?? '').trim();
  if (!trimmed) return '';
  const lower = trimmed.toLowerCase();
  const noDiacritics = lower.normalize('NFKD').replace(/[̀-ͯ]/g, '');
  return noDiacritics.replace(/[^a-z0-9]/g, '');
}

const VALID_ROLES = ['ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'TV_ONLY', 'MANAGER'];

// This function is called directly from the browser (unlike this
// project's other Edge Function, refresh-aircraft-state, which is only
// ever called server-to-server by a cron job and never needed CORS
// handling). The browser sends a CORS preflight OPTIONS request first
// because the real POST carries custom headers (Authorization, apikey,
// Content-Type) — without an explicit OPTIONS response and
// Access-Control-Allow-* headers on every response, the browser blocks
// the actual request before it ever reaches this code, with no server
// log to show for it.
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method not allowed' }, 405);
  }

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
  const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

  const authHeader = req.headers.get('Authorization') || '';

  // Caller-scoped client — RLS/RPC-internal checks apply exactly as they
  // would for any normal frontend request from this same session.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: roleData, error: roleErr } = await callerClient.rpc('current_user_role');
  if (roleErr || roleData !== 'ADMIN') {
    return jsonResponse({ error: 'only ADMIN accounts may use this function' }, 403);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid JSON body' }, 400);
  }

  const action = payload.action;
  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  if (action === 'create') {
    const rawUsername = String(payload.username ?? '').trim();
    const displayName = String(payload.display_name ?? rawUsername).trim();
    const password = String(payload.password ?? '');
    const role = String(payload.role ?? '');

    const canonical = canonicalizeUsername(rawUsername);
    if (!canonical) {
      return jsonResponse({ error: 'username must contain at least one letter or digit' }, 400);
    }
    if (canonical === 'admin') {
      return jsonResponse({ error: 'this identity is reserved for the existing protected Admin account' }, 400);
    }
    if (!VALID_ROLES.includes(role)) {
      return jsonResponse({ error: 'role must be one of ' + VALID_ROLES.join(', ') }, 400);
    }
    if (!password || password.length < 8) {
      return jsonResponse({ error: 'password must be at least 8 characters' }, 400);
    }

    // Pre-check for a username collision (case-insensitive) BEFORE
    // creating any real Auth account. A read via the service-role
    // client (bypasses RLS, which otherwise only exposes a caller's own
    // row) — not a mutation.
    const { data: existing, error: existingErr } = await adminClient
      .from('user_profiles')
      .select('id')
      .ilike('username', rawUsername)
      .maybeSingle();
    if (existingErr) {
      return jsonResponse({ error: 'could not validate username: ' + existingErr.message }, 500);
    }
    if (existing) {
      return jsonResponse({ error: 'that username is already in use' }, 409);
    }

    const email = canonical + '@airvalet.local';

    const { data: created, error: createErr } = await adminClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (createErr || !created?.user) {
      return jsonResponse({ error: createErr?.message || 'could not create Auth account' }, 400);
    }

    const newId = created.user.id;

    const { error: profileErr } = await callerClient.rpc('admin_create_user_profile', {
      p_id: newId,
      p_username: rawUsername,
      p_display_name: displayName || rawUsername,
      p_role: role,
    });

    if (profileErr) {
      // Roll back the orphaned Auth account — never leave a working
      // credential with no role mapping.
      await adminClient.auth.admin.deleteUser(newId);
      return jsonResponse({ error: 'could not create profile, Auth account rolled back: ' + profileErr.message }, 400);
    }

    return jsonResponse({ id: newId, username: rawUsername, display_name: displayName, role }, 200);
  }

  if (action === 'disable' || action === 'enable') {
    const targetId = String(payload.target_id ?? '');
    if (!targetId) return jsonResponse({ error: 'target_id is required' }, 400);

    if (action === 'disable') {
      // Revoke operational capability first (profile-side) — safe even
      // if the Auth-layer ban below fails, since current_user_role()
      // already returns NULL once is_active is false, denying every
      // RLS policy and guarded RPC immediately.
      const { error: setErr } = await callerClient.rpc('admin_set_user_active', {
        p_id: targetId, p_active: false,
      });
      if (setErr) return jsonResponse({ error: setErr.message }, 400);

      const { error: banErr } = await adminClient.auth.admin.updateUserById(targetId, {
        ban_duration: '87600h',
      });
      if (banErr) {
        return jsonResponse({
          warning: 'account disabled (no operational access), but the Auth-level lock could not be applied: ' + banErr.message,
        }, 200);
      }
      return jsonResponse({ id: targetId, is_active: false }, 200);
    } else {
      // Grant direction — only restore operational capability once the
      // Auth-level unban has actually succeeded, so Auth status and
      // profile state can never diverge in the unsafe direction.
      const { error: unbanErr } = await adminClient.auth.admin.updateUserById(targetId, {
        ban_duration: 'none',
      });
      if (unbanErr) {
        return jsonResponse({ error: 'could not lift Auth-level lock: ' + unbanErr.message }, 400);
      }
      const { error: setErr } = await callerClient.rpc('admin_set_user_active', {
        p_id: targetId, p_active: true,
      });
      if (setErr) return jsonResponse({ error: setErr.message }, 400);
      return jsonResponse({ id: targetId, is_active: true }, 200);
    }
  }

  if (action === 'delete') {
    const targetId = String(payload.target_id ?? '');
    if (!targetId) return jsonResponse({ error: 'target_id is required' }, 400);

    // Remove the profile/role mapping first — an orphaned Auth account
    // with no profile has zero operational access (current_user_role()
    // returns NULL), the same safe state as any other unmapped account.
    const { error: delProfileErr } = await callerClient.rpc('admin_delete_user_profile', {
      p_id: targetId,
    });
    if (delProfileErr) return jsonResponse({ error: delProfileErr.message }, 400);

    const { error: delAuthErr } = await adminClient.auth.admin.deleteUser(targetId);
    if (delAuthErr) {
      return jsonResponse({
        warning: 'profile removed (no operational access remains), but the Auth account itself could not be deleted: ' + delAuthErr.message,
      }, 200);
    }
    return jsonResponse({ id: targetId, deleted: true }, 200);
  }

  return jsonResponse({ error: 'unknown action' }, 400);
});
