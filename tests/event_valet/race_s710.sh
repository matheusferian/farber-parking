#!/bin/sh
# Concurrent check-ins through the S710 staff API (event_valet_staff), each in its own
# DB session: 25 from the S710 credential + 12 from a phone link at the same time.
# Expect: 35 cars, 35 distinct hooks, S710 cars on 1..25 (its pool), phone cars on
# 41..50, exactly 2 phone check-ins refused (phone pool full, never borrows S710 hooks).
# Cleans up the Watermakers rows afterwards. Local stack only.
DB=${DB:-supabase_db_airvalet-sms-local}
q() { docker exec -i $DB psql -U postgres -qtA -c "$1"; }
EV=watermakers-veterans-2026
DTOK=$(printf 'racedev%.0s' 1 | awk '{printf "%-43s", $0}' | tr ' ' 'x')
LTOK=$(printf 'racelnk%.0s' 1 | awk '{printf "%-43s", $0}' | tr ' ' 'x')
cleanup() {
  q "delete from event_valet_messages where event_id='$EV'; delete from event_valet_audit where event_id='$EV';
     delete from event_valet_ops where access_id in (select id from event_valet_access where event_id='$EV' and label like 'RACE%');
     delete from event_valet_rate where access_id in (select id from event_valet_access where event_id='$EV' and label like 'RACE%');
     delete from event_valet_tickets where event_id='$EV';
     delete from event_valet_sessions where access_id in (select id from event_valet_access where event_id='$EV' and label like 'RACE%');
     delete from event_valet_access where event_id='$EV' and label like 'RACE%';
     update event_valet_events set staff_access_enabled = exists (select 1 from event_valet_access
       where event_id='$EV' and revoked_at is null) where id='$EV';" >/dev/null   # other local keys (Android E2E) keep working
}
cleanup
q "update event_valet_events set staff_access_enabled=true where id='$EV';
   insert into event_valet_access (event_id, kind, label, token_hash, valid_until) values
   ('$EV','DEVICE','RACE S710',sha256(convert_to('$DTOK','UTF8')),now()+interval '1 hour'),
   ('$EV','LINK','RACE PHONE',sha256(convert_to('$LTOK','UTF8')),now()+interval '1 hour');" >/dev/null
SD=$(q "set role service_role; select public.event_valet_staff('$DTOK', null, 'session', '{\"name\":\"Racer\"}')->>'sessionId';" | tail -1)
SL=$(q "set role service_role; select public.event_valet_staff('$LTOK', null, 'session', '{\"name\":\"Phoner\"}')->>'sessionId';" | tail -1)
one() { # $1 token $2 session $3 n
  docker exec -i $DB psql -U postgres -qtA -c "set role service_role; select (public.event_valet_staff('$1', '$2', 'checkin',
    jsonb_build_object('clientKey','race-key-$3','phone','95455520' || lpad('$3',2,'0'),'vehicle',jsonb_build_object('make','RACE'),
                       'location','FRONT','keyStoredAt',now()))->'ticket'->>'hook');" 2>&1 | grep -E '^[0-9]+$|ERROR' | head -1
}
OUT=$(mktemp -d)
for i in $(seq 1 25); do one $DTOK $SD $i > $OUT/d$i & done
for i in $(seq 26 37); do one $LTOK $SL $i > $OUT/l$i & done
wait
echo "S710 hooks:  $(cat $OUT/d* | sort -n | tr '\n' ' ')"
echo "phone hooks: $(cat $OUT/l* | sort -n | tr '\n' ' ')"
q "select 'cars='||count(*)||' distinct_hooks='||count(distinct slot_no)||
       ' s710_in_pool='||count(*) filter (where checked_in_by='Racer' and slot_no between 1 and 40)||
       ' phone_in_pool='||count(*) filter (where checked_in_by='Phoner' and slot_no between 41 and 50)
     from event_valet_tickets where event_id='$EV'"
echo "phone refusals: $(grep -l 'HOOK_TAKEN' $OUT/l* | wc -l | tr -d ' ')"
rm -rf $OUT
cleanup
