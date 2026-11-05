#!/bin/sh
# LOCAL ONLY. Turns Watermakers staff access on in the local stack and mints one
# DEVICE (S710) and one LINK (backup phone) credential, valid 7 days. Raw tokens are
# written to $OUT (default: ./.local-keys, git-ignored) — never commit them.
#   sh tests/event_valet/mint_local_keys.sh [out_dir]
set -e
DB=${DB:-supabase_db_airvalet-sms-local}
OUT=${1:-.local-keys}
mkdir -p "$OUT"
q() { docker exec -i $DB psql -U postgres -v ON_ERROR_STOP=1 -qtA -c "$1"; }
mint() { # kind label
  q "with t as (select rtrim(translate(encode(extensions.gen_random_bytes(32),'base64'),'+/','-_'),'=') tok)
     , i as (insert into event_valet_access (event_id, kind, label, token_hash, valid_until)
             select 'watermakers-veterans-2026', '$1', '$2', sha256(convert_to(tok,'UTF8')), now() + interval '7 days' from t)
     select tok from t" | tail -1
}
q "update event_valet_events set staff_access_enabled = true, is_open = true, closed_at = null where id = 'watermakers-veterans-2026'" >/dev/null
mint DEVICE 'LOCAL S710' > "$OUT/av_device.key"
mint LINK 'LOCAL phone' > "$OUT/av_link.key"
chmod 600 "$OUT"/*.key
echo "DEVICE key → $OUT/av_device.key"
echo "LINK key   → $OUT/av_link.key"
echo "staff page → http://127.0.0.1:8789/events/watermakers-veterans-2026/staff#k=\$(cat $OUT/av_link.key)"
