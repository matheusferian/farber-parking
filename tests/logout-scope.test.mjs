// Regression (incident 2026-10-07 12:13 ET): one Logout on a makers@ device used the
// supabase-js default scope 'global' and ended ALL 15 makers@ sessions on every device.
// Every sign-out in the app must end THIS device's session only.
// Run: node --test tests/logout-scope.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
const files = ["index.html", ...readdirSync(root).filter((f) => f.endsWith(".js") && f !== "service-worker.js")];
const sources = Object.fromEntries(files.map((f) => [f, readFileSync(root + f, "utf8")]));

test("every auth signOut() call passes scope 'local'", () => {
  let calls = 0;
  for (const [file, src] of Object.entries(sources)) {
    for (const m of src.matchAll(/\.auth\.signOut\(([^)]*)\)/g)) {
      calls++;
      assert.match(m[1], /scope:\s*['"]local['"]/, `${file}: signOut(${m[1]}) must use scope 'local'`);
    }
  }
  assert.ok(calls >= 2, "expected the Logout button and the SSO watcher sign-outs");
});

test("no global or 'others' logout anywhere in the app", () => {
  for (const [file, src] of Object.entries(sources)) {
    assert.doesNotMatch(src, /scope:\s*['"](global|others)['"]/, `${file} requests a multi-device logout`);
    assert.doesNotMatch(src, /logout\?scope=(global|others)/, `${file} calls the logout endpoint globally`);
  }
});

test("doLogout() — the Sign Out button — is device-local", () => {
  const raw = sources["index.html"].match(/async function doLogout\(\)\s*\{([\s\S]*?)\n\}/)?.[1] ?? "";
  const body = raw.replace(/\/\/.*$/gm, ""); // code only, comments ignored
  assert.match(body, /_supaClient\.auth\.signOut\(\{\s*scope:\s*'local'\s*\}\)/);
  assert.doesNotMatch(body, /updateUser|password|admin\./, "logout must never touch credentials");
});

test("the service-worker cache version was bumped for this fix", () => {
  const sw = readFileSync(root + "service-worker.js", "utf8");
  assert.match(sw, /var CACHE_VERSION = 'v(4[5-9]|[5-9]\d)';/);
});
