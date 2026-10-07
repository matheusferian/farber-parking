// ONE LOGIN Phase 2C — "Continue with FarberOS" for HUMAN AirValet accounts.
// Browser half: creates state + PKCE verifier (sessionStorage, this tab only),
// sends the browser to FarberOS, and on return hands the one-time code + verifier
// to the sso-exchange edge function, which decides server-side and returns a normal
// Supabase session. Holds no secrets. The username/password login is unchanged.
// Offered only on the final domain (FARBEROS_SSO.redirectUri must match exactly).

// Rollout switch (ONE LOGIN Phase 2): the code ships first with the button, the
// FarberOS return handling and the revalidation watcher all OFF (rollout Step 3);
// rollout Step 5 flips this to true together with enabling the AirValet SSO client.
var FARBEROS_SSO_ROLLOUT_ENABLED = false;

var FARBEROS_SSO = (function () {
  var o = window.FARBEROS_SSO_CONFIG || {};
  return {
    issuer: o.issuer || 'https://farberos.com',
    clientId: o.clientId || 'airvalet',
    redirectUri: o.redirectUri || 'https://airvalet.farberos.com/',
    txKey: 'airvalet_sso_tx',
    enabled: typeof o.enabled === 'boolean' ? o.enabled : FARBEROS_SSO_ROLLOUT_ENABLED
  };
})();

function farberosSsoAvailable() {
  return FARBEROS_SSO.enabled && location.origin + '/' === FARBEROS_SSO.redirectUri;
}

function _ssoRandom(n) {
  var b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return _ssoB64url(b);
}

function _ssoB64url(bytes) {
  var s = '';
  for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function startFarberosSso() {
  var state = _ssoRandom(32);
  var verifier = _ssoRandom(48);
  var digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  sessionStorage.setItem(FARBEROS_SSO.txKey, JSON.stringify({ state: state, verifier: verifier, exp: Date.now() + 10 * 60 * 1000 }));
  var url = new URL('/sso/authorize', FARBEROS_SSO.issuer);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', FARBEROS_SSO.clientId);
  url.searchParams.set('redirect_uri', FARBEROS_SSO.redirectUri);
  url.searchParams.set('state', state);
  url.searchParams.set('code_challenge', _ssoB64url(new Uint8Array(digest)));
  url.searchParams.set('code_challenge_method', 'S256');
  location.assign(url.toString());
}

// Returns true if this page load was a FarberOS return (handled here either way).
async function completeFarberosSsoIfPresent(supa, exchangeUrl, anonKey, showError) {
  var params = new URLSearchParams(location.search);
  if (!params.has('state') || !(params.has('code') || params.has('error'))) return false;
  // Strip code/state from the address bar and history immediately.
  history.replaceState(null, '', location.pathname);

  var raw = sessionStorage.getItem(FARBEROS_SSO.txKey);
  sessionStorage.removeItem(FARBEROS_SSO.txKey);
  var tx = null;
  try { tx = raw ? JSON.parse(raw) : null; } catch (e) { tx = null; }
  if (!tx || tx.exp < Date.now() || tx.state !== params.get('state')) {
    showError('FarberOS sign-in expired. Please try again.');
    return true;
  }
  if (params.get('error')) {
    showError(params.get('error') === 'access_denied'
      ? 'Your FarberOS account does not have access to AirValet.'
      : 'FarberOS sign-in did not complete. Please try again.');
    return true;
  }
  try {
    var res = await fetch(exchangeUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'apikey': anonKey, 'Authorization': 'Bearer ' + anonKey },
      body: JSON.stringify({ code: params.get('code'), code_verifier: tx.verifier, redirect_uri: FARBEROS_SSO.redirectUri })
    });
    var data = await res.json().catch(function () { return {}; });
    if (!res.ok || !data.access_token || !data.refresh_token) {
      showError(data.error === 'access_denied' || data.error === 'not_linked' || data.error === 'not_a_human_account'
        ? 'Your FarberOS account does not have access to AirValet.'
        : 'FarberOS sign-in did not complete. Please try again.');
      return true;
    }
    // A normal Supabase session from here on: onAuthStateChange(SIGNED_IN) boots the app.
    var r = await supa.auth.setSession({ access_token: data.access_token, refresh_token: data.refresh_token });
    if (r.error) { showError('FarberOS sign-in did not complete. Please try again.'); return true; }
    markFarberosSsoSession();
    startFarberosSsoWatcher(supa, showError);
  } catch (e) {
    showError('FarberOS sign-in did not complete. Please try again.');
  }
  return true;
}

// ---- Revalidation watcher (HUMAN SSO sessions only) ---------------------------------
// The security check is server-side (current_user_role() denies a revoked SSO session;
// sso-revalidate terminates it). This only makes the page react promptly. It starts
// ONLY for a session created by "Continue with FarberOS" on this device — password,
// makers@, iPad / iPhone / TV and offline sessions never start it.
var FARBEROS_SSO_FLAG = 'airvalet_sso_session';
var _ssoWatchTimer = null;

function markFarberosSsoSession() {
  try { localStorage.setItem(FARBEROS_SSO_FLAG, '1'); } catch (e) {}
}

function startFarberosSsoWatcher(supa, showError) {
  var flagged = false;
  try { flagged = localStorage.getItem(FARBEROS_SSO_FLAG) === '1'; } catch (e) {}
  if (!flagged || _ssoWatchTimer) return;
  supa.auth.onAuthStateChange(function (event) {
    if (event === 'SIGNED_OUT') {
      try { localStorage.removeItem(FARBEROS_SSO_FLAG); } catch (e) {}
      if (_ssoWatchTimer) { clearInterval(_ssoWatchTimer); _ssoWatchTimer = null; }
    }
  });
  async function check() {
    if (!navigator.onLine) return;   // offline: nothing to ask; the server decides when back
    var r = await supa.rpc('sso_session_status');
    if (r.error) return;
    if (r.data === 'not_sso') {      // not an SSO session after all → never watch it
      try { localStorage.removeItem(FARBEROS_SSO_FLAG); } catch (e) {}
      clearInterval(_ssoWatchTimer); _ssoWatchTimer = null;
    } else if (r.data === 'revoked') {
      clearInterval(_ssoWatchTimer); _ssoWatchTimer = null;
      try { localStorage.removeItem(FARBEROS_SSO_FLAG); } catch (e) {}
      await supa.auth.signOut({ scope: 'local' });
      showError('Your FarberOS access has ended. Please sign in again.');
    }
  }
  _ssoWatchTimer = setInterval(check, 60 * 1000);
  check();
}
