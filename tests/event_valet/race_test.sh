#!/bin/sh
# 20 simultaneous check-ins from separate DB sessions; verifies unique ticket
# numbers 1..20 and unique slots 1..20, then deletes the test rows.
DB=${DB:-supabase_db_airvalet-sms-local}; IPAD=$1; N=${N:-20}
docker exec $DB psql -U postgres -qtAc "delete from event_valet_messages where event_id='makers-halloween-2026'; delete from event_valet_audit where event_id='makers-halloween-2026'; delete from event_valet_tickets where event_id='makers-halloween-2026';"
for i in $(seq 1 $N); do
  docker exec $DB psql -U postgres -qtAc "begin; select set_config('request.jwt.claims', json_build_object('sub','$IPAD','role','authenticated','session_id',gen_random_uuid())::text, true) is null; set local role authenticated; select public.event_valet_checkin('makers-halloween-2026', '95455510' || lpad('$i',2,'0'), 'RACE $i', 'race-$i')->'ticket'->>'ticket_no'; commit;" >/dev/null 2>/tmp/race_err_$i &
done
wait
docker exec $DB psql -U postgres -qtAc "select count(*), count(distinct ticket_no), min(ticket_no), max(ticket_no), count(distinct slot_no), min(slot_no), max(slot_no) from event_valet_tickets where event_id='makers-halloween-2026'"
cat /tmp/race_err_* 2>/dev/null | grep -v '^$' | head -3; rm -f /tmp/race_err_*
docker exec $DB psql -U postgres -qtAc "delete from event_valet_audit where event_id='makers-halloween-2026'; delete from event_valet_tickets where event_id='makers-halloween-2026';"
