#!/bin/zsh
# PRD-110 STEP 7 · S5 — spot-buy race driver (external).
#
# WHY EXTERNAL: true concurrency cannot come from one SQL session. Each contender needs its own
# connection and its own transaction, so the driver fans out /tmp/prd110_sql.sh calls and lets the
# backend do the racing. Same shape as scripts/prd110_s3_concurrent_edits.py.
#
# WAVE 1 — pack vs pack, COMMON barrier. Proves pack_dispatch_line is clean POSITIVELY:
#          exactly one leg packs, the other is refused with 'Already packed', and the batch is
#          debited exactly once.
# WAVE 2 — bind vs pack, OFFSET barrier (the bind side enters +2 s). The pack side holds its row
#          lock 5 s after packing, so the bind side snapshots BEFORE the pack commits and then
#          blocks on the lock. ⛔ THE WITNESS IS THE BIND SIDE'S LOCK-WAIT DURATION (S-234) —
#          no wait means the two never contended and the suite FAILS rather than passing on a
#          race that did not happen.
#
# Usage: ./scripts/prd110_s5_spot_buy_race.sh <setup.json>
#   where <setup.json> is the raw output of  SELECT golden.stress_s5_setup_v1('<note>');
#
# ⛔ S-223: do not START between :36 and :48 UTC (cron 44 rewrites shelf_composition at :40 and
#    this suite spans minutes across several transactions). The setup function refuses on its own;
#    this driver refuses too, because the waves are what actually straddle the window.
# ⛔ S-213: do not let a round boundary cross 00:00 UTC (avoid 03:00-05:00 Dubai).
set -e
SHIM=/tmp/prd110_sql.sh
SETUP_JSON=${1:?usage: prd110_s5_spot_buy_race.sh <setup.json>}
[ -x "$SHIM" ] || { echo "missing $SHIM"; exit 1; }

MIN=$(date -u +%M | sed 's/^0//')
if [ "$MIN" -ge 36 ] && [ "$MIN" -le 48 ]; then
  echo "REFUSING: :$MIN UTC is inside the cron-44 window :36-:48 (S-223). Wait it out."; exit 2
fi

# ---------------------------------------------------------------- parse the setup handle
eval "$(python3 - "$SETUP_JSON" <<'EOF'
import json,sys
d=json.load(open(sys.argv[1]))[0]['setup']
for k in ('run_tag','l_bind','l_pack','batch_x','batch_y','batch_z','plan_date','machine_name','qty_bind','qty_pack'):
    print(f"{k.upper()}='{d[k]}'")
EOF
)"
echo "run_tag=$RUN_TAG  l_bind=$L_BIND  l_pack=$L_PACK"
echo "X=$BATCH_X (pack picks this)  Y=$BATCH_Y (FEFO prefers this)  Z=$BATCH_Z"

# ---------------------------------------------------------------- helper: one barrier epoch
# Computed ONCE, server-side, and handed to every contender. Deriving it independently in each
# session risks the two straddling a rounding boundary and never meeting.
barrier () {
  echo "SELECT (ceil(extract(epoch from clock_timestamp())/30.0)*30 + $1)::text AS b;" \
    | $SHIM - | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['b'])"
}

# ================================================================= WAVE 1 — pack vs pack
B1=$(barrier 30)
echo "\n=== WAVE 1 (pack vs pack, common barrier @ epoch $B1) ==="
for i in 1 2; do
  cat > /tmp/s5_w1_$i.sql <<EOF
SELECT golden.stress_s5_pack_leg_v1('$RUN_TAG','w1_pack$i','$L_PACK','$BATCH_Z',$QTY_PACK,$B1,0) AS r;
EOF
done
( $SHIM /tmp/s5_w1_1.sql > /tmp/s5_w1_1.out 2>&1 & \
  $SHIM /tmp/s5_w1_2.sql > /tmp/s5_w1_2.out 2>&1 & \
  wait )
echo "--- leg 1 ---"; head -c 700 /tmp/s5_w1_1.out; echo
echo "--- leg 2 ---"; head -c 700 /tmp/s5_w1_2.out; echo

# ================================================================= WAVE 2 — offset bind race
# The pack side enters at B2 and HOLDS its row lock 5 s. The bind side enters at B2+2 s: late
# enough that pack has already stamped packed=true, early enough that pack has NOT committed, so
# the bind statement's snapshot still sees packed=false and the row qualifies in `targets`.
B2=$(barrier 30)
B2B=$(python3 -c "print(float('$B2')+2)")
echo "\n=== WAVE 2 (offset race: pack @ $B2, bind @ $B2B) ==="
cat > /tmp/s5_w2_pack.sql <<EOF
SELECT golden.stress_s5_pack_leg_v1('$RUN_TAG','w2_pack','$L_BIND','$BATCH_X',$QTY_BIND,$B2,5) AS r;
EOF
cat > /tmp/s5_w2_bind.sql <<EOF
SELECT golden.stress_s5_bind_leg_v1('$RUN_TAG','w2_bind','$PLAN_DATE','$MACHINE_NAME',$B2B) AS r;
EOF
( $SHIM /tmp/s5_w2_pack.sql > /tmp/s5_w2_pack.out 2>&1 & \
  $SHIM /tmp/s5_w2_bind.sql > /tmp/s5_w2_bind.out 2>&1 & \
  wait )
echo "--- pack side ---"; head -c 700 /tmp/s5_w2_pack.out; echo
echo "--- bind side ---"; head -c 700 /tmp/s5_w2_bind.out; echo

echo "\n=== legs recorded ==="
echo "SELECT leg, payload->>'status' AS status, payload->>'wait_ms' AS wait_ms, payload->>'bound' AS bound, left(COALESCE(payload->>'sqlerrm',''),40) AS err FROM golden._s5_leg_log WHERE run_tag='$RUN_TAG' ORDER BY leg_log_id;" | $SHIM -

echo "\n=== NEXT: run the verifier ==="
echo "  SELECT golden.stress_s5_verify_v1('\$(cat $SETUP_JSON | jq -c '.[0].setup')'::jsonb, true, '<note>');"
