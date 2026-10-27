#!/bin/bash
# Run by the OWNER in their own Terminal (never by an agent, never pasted in chat):
#   bash ~/Dev/worktrees/airvalet-pass-stage1/tests/portal/owner_set_stripe_test_key.sh
# Stores the Stripe TEST-MODE restricted key (rk_test_…) of the MATT SOLUTIONS
# account for LOCAL tests only, in ~/Dev/airvalet-local-secrets/stripe-test.env
# (folder 700, file 600, outside every repo and outside iCloud). The key is read
# with `read -s` (not shown, not in shell history) and is never printed.
# A live key (rk_live_ / sk_live_) or a secret key (sk_) is refused.
# To remove it later:  rm ~/Dev/airvalet-local-secrets/stripe-test.env
set -eu
DIR="$HOME/Dev/airvalet-local-secrets"; FILE="$DIR/stripe-test.env"
mkdir -p "$DIR"; chmod 700 "$DIR"
printf 'Paste the Stripe TEST restricted key (starts with rk_test_). Nothing will appear: '
IFS= read -rs KEY; echo
KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
case "$KEY" in
  rk_test_*) ;;
  rk_live_*|sk_live_*) echo 'REFUSED: this is a LIVE key. Only a test-mode key goes here.'; exit 1 ;;
  sk_test_*) echo 'REFUSED: this is a full secret key. Create a RESTRICTED key (rk_test_) with only Checkout Sessions: Write.'; exit 1 ;;
  *) echo 'REFUSED: not a Stripe restricted test key (rk_test_...).'; exit 1 ;;
esac
[ "${#KEY}" -ge 30 ] || { echo 'REFUSED: the key looks incomplete.'; exit 1; }
umask 077
printf 'AIRVALET_STRIPE_CHECKOUT_KEY=%s\n' "$KEY" > "$FILE"
chmod 600 "$FILE"; unset KEY
echo "Saved (test mode only) in $FILE — permissions $(stat -f %Lp "$FILE"). Never commit or share this file."
