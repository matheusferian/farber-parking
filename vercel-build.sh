#!/bin/sh
# Vercel serves only dist/. Allowlist of runtime files — internal docs,
# migrations, reports and scripts in this repo must never be published.
# A new runtime file must be added here (and to SHELL_FILES in service-worker.js).
set -eu

rm -rf dist
mkdir -p dist/assets dist/vendor

cp index.html styles.css utils.js offline-auth.js offline-db.js sso-client.js service-worker.js \
   manifest.webmanifest logo.PNG apple-touch-icon.png icon-192.png icon-512.png \
   favicon-32x32.png dist/
cp assets/*.png dist/assets/
cp vendor/supabase.js dist/vendor/
# Public A2P compliance pages (SMS program, privacy, terms). Static only,
# not app-shell files: not in SHELL_FILES, never cached by the service worker.
cp sms.html privacy.html terms.html dist/
# Temporary Event Valet module (MAKERS AIR — HALLOWEEN VALET, 2026-10-24).
# Separate pages, not app-shell files: not in SHELL_FILES, never cached by the
# service worker. Remove this block (and events/) to retire the event.
mkdir -p dist/events/makers-halloween-2026
cp events/makers-halloween-2026/index.html events/makers-halloween-2026/t.html \
   events/makers-halloween-2026/sw.js events/makers-halloween-2026/manifest.webmanifest dist/events/makers-halloween-2026/
