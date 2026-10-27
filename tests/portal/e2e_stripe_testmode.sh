#!/bin/bash
# REAL Stripe TEST-MODE run of the Valet Pass gratuity, LOCAL ONLY (2026-10-27).
# Preconditions (owner, once):
#   1. Restricted TEST key stored with tests/portal/owner_set_stripe_test_key.sh
#      → ~/Dev/airvalet-local-secrets/stripe-test.env (600).
#   2. Stripe CLI logged into the MATT SOLUTIONS account under the project name
#      "airvalet-matt":  stripe login --project-name airvalet-matt
# What it does: starts (only for the run) the local functions with the test key,
# the real stripe-webhook on :8000 with the signing secret of `stripe listen`,
# and `stripe listen` forwarding to it; runs e2e_stripe_testmode.ts; then puts the
# local stack back as it was. Never prints a key or a signing secret; test mode only.
#   bash tests/portal/e2e_stripe_testmode.sh <scratch portal dir> [SKIP_PAY=1]
set -u
P="${1:?scratch portal dir (functions.env, stack/)}"
W="$(cd "$(dirname "$0")/../.." && pwd)"
S="$HOME/Dev/airvalet-local-secrets"; KEYF="$S/stripe-test.env"; PROFILE=airvalet-matt
CONF="$HOME/.config/stripe/config.toml"
die() { echo "STOP: $*"; exit 2; }

[ -f "$KEYF" ] || die "no test key yet. Owner: run  bash $W/tests/portal/owner_set_stripe_test_key.sh"
[ "$(stat -f %Lp "$KEYF")" = "600" ] || die "$KEYF must be chmod 600"
grep -q '^AIRVALET_STRIPE_CHECKOUT_KEY=rk_test_' "$KEYF" || die "the key file must hold a restricted TEST key (rk_test_)"
command -v stripe >/dev/null || die "Stripe CLI not installed (brew install stripe/stripe-cli/stripe)"
NAME=$(awk -v p="[$PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f && /display_name/{sub(/^[^=]*= */,"");gsub(/'"'"'/,"");print;exit}' "$CONF" 2>/dev/null)
[ -n "$NAME" ] || die "Stripe CLI not logged in as \"$PROFILE\". Owner: stripe login --project-name $PROFILE (choose MATT SOLUTIONS)"
echo "$NAME" | grep -qi 'farber' && die "the CLI profile \"$PROFILE\" points to \"$NAME\". AirValet tips are MATT SOLUTIONS only."
echo "Stripe CLI profile $PROFILE → account \"$NAME\" (test mode)"

ORIG_LINK=$(readlink "$P/stack/supabase/functions")
cleanup() {
  [ -n "${LISTEN:-}" ] && kill $LISTEN 2>/dev/null
  [ -n "${HOOK:-}" ] && kill $HOOK 2>/dev/null
  pkill -f "functions serve --env-file $S/functions.testmode.env" 2>/dev/null; sleep 3
  rm -f "$S/functions.testmode.env" "$S/listen.log"
  ln -sfn "$ORIG_LINK" "$P/stack/supabase/functions"
  (cd "$P/stack" && nohup supabase functions serve --env-file "$P/functions.env" >> "$P/functions.log" 2>&1 &)
  echo "local stack restored (functions → $ORIG_LINK, original env)"
}
trap cleanup EXIT

# Functions env for this run only: the usual local env + origins, the test key, no mock override.
umask 077
grep -v -E '^(AIRVALET_STRIPE_CHECKOUT_KEY|AIRVALET_STRIPE_API_BASE|AIRVALET_PASS_RETURN_URL|AIRVALET_PASS_ORIGINS|AIRVALET_APP_ORIGINS)=' "$P/functions.env" > "$S/functions.testmode.env"
grep -E '^AIRVALET_(PASS|APP)_ORIGINS=' "$P/functions.env" | sed -E 's#$#,http://127.0.0.1:8795#' >> "$S/functions.testmode.env"
echo 'AIRVALET_PASS_RETURN_URL=http://127.0.0.1:8795/a' >> "$S/functions.testmode.env"
cat "$KEYF" >> "$S/functions.testmode.env"
pkill -f "functions serve --env-file" 2>/dev/null; sleep 3
ln -sfn "$W/supabase/functions" "$P/stack/supabase/functions"
(cd "$P/stack" && nohup supabase functions serve --env-file "$S/functions.testmode.env" > /dev/null 2>&1 &)

# Signed webhooks: the real stripe-webhook file on :8000 with the stripe listen secret.
WHSEC=$(stripe listen --project-name $PROFILE --print-secret 2>/dev/null)
case "$WHSEC" in whsec_*) ;; *) die "could not get the test signing secret from stripe listen";; esac
SUPA=http://127.0.0.1:56331
SRK=$(sed -n "s/^const SRK = '\([^']*\)'.*/\1/p" "$W/tests/portal/e2e_stripe_local.ts")   # the public local demo key
STRIPE_WEBHOOK_SECRET="$WHSEC" SUPABASE_URL=$SUPA SUPABASE_SERVICE_ROLE_KEY="$SRK" AIRVALET_GRATUITY_PAYMENT_LINK_IDS=plink_testmode_none STRIPE_SECRET_KEY='' \
  deno run --allow-env --allow-read --allow-net=127.0.0.1,0.0.0.0,localhost "$W/supabase/functions/stripe-webhook/index.ts" > /dev/null 2>&1 &
HOOK=$!; unset WHSEC
stripe listen --project-name $PROFILE --forward-to http://127.0.0.1:8000/ \
  --events checkout.session.completed,checkout.session.async_payment_succeeded,checkout.session.expired,charge.refunded > "$S/listen.log" 2>&1 &
LISTEN=$!
sleep 15
env STRIPE_PROFILE=$PROFILE STRIPE_TEST_ENV="$KEYF" ${2:-} deno run -A "$W/tests/portal/e2e_stripe_testmode.ts"
RC=$?
echo "forwarded events (types only): $(grep -oE '(checkout\.session\.[a-z_]+|charge\.refunded)' "$S/listen.log" | sort | uniq -c | tr '\n' ' ')"
exit $RC
