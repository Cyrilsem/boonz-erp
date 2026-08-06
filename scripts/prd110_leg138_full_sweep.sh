#!/bin/zsh
# PRD-110 leg 138 - THE OWED FULL 58-FIXTURE SWEEP.
#
# Inherits the leg-126/127 S7 runner design wholesale (S-212 response-is-not-the-verdict,
# S-210 per-round subdirs, the cron-44 straddle guard, the freshness floor) and adds the
# two rules leg 137 had to learn the hard way:
#
#  (A) S-254 - DELETE golden.scratch FOR THE FIXTURE BEFORE FIRING IT.
#      run_fixture executes the scenario in a plpgsql subtransaction. The scenario's own
#      opening `DELETE FROM golden.scratch WHERE fixture_id = N` therefore ROLLS BACK with
#      the scenario when it raises, leaving the PREVIOUS run's blob in place - and the
#      assertions then score stale observations and reproduce an old verdict perfectly.
#      Deleting from OUTSIDE the fixture's transaction makes a scenario_error read as NULL
#      everywhere, which is unmistakable, instead of as a plausible old red.
#
#  (B) The read-back now surfaces detail[0]->>'scenario_error'. Per S-254 rule 1, a non-null
#      value means the whole assertion list is untrustworthy - not merely incomplete - so the
#      sweep must never be adjudicated off n_pass/n_fail alone.
#
# S-250 stays closed by construction: we fire PER FIXTURE. golden.run_all() through the
# management API commits NOTHING (8 of 58 silently failed to bank for leg 134).
set -u
ROUND=${1:-1}
NOTE="leg138 sweep r${ROUND}"
BASE=/tmp/prd110_leg138_out
OUT=$BASE/r${ROUND}
mkdir -p $OUT
LOG=$BASE/progress.log
FIXTURES=$(cat /tmp/prd110_s7_fixtures.txt)

FLOOR=$(date -u +%FT%TZ)
echo "SWEEPSTART round=$ROUND note='$NOTE' floor=$FLOOR" >> $LOG

for fx in ${(f)FIXTURES}; do
  # resume guard: a captured result must actually carry n_eval, not merely be non-empty
  if [ -f $OUT/f${fx}.json ] && grep -q '"n_eval"' $OUT/f${fx}.json; then continue; fi

  # (0) CRON-44 STRADDLE GUARD - never START a fixture in UTC minutes [37,40].
  while true; do
    M=$(date -u +%M); M=${M#0}; M=${M:-0}
    if [ "$M" -ge 37 ] && [ "$M" -le 40 ]; then
      echo "r$ROUND fx=$fx HOLD for cron44 window at $(date -u +%FT%TZ)" >> $LOG
      sleep 30
    else
      break
    fi
  done

  t0=$(date +%s)

  # (A) S-254 - clear the scratch blob from OUTSIDE the fixture transaction.
  echo "DELETE FROM golden.scratch WHERE fixture_id = $fx;" > /tmp/_leg138_scratch_${ROUND}.sql
  /tmp/prd110_sql.sh /tmp/_leg138_scratch_${ROUND}.sql > $OUT/f${fx}.scratch 2>&1

  # (1) FIRE. Response body discarded - it is not the verdict channel.
  cat > /tmp/_leg138_fire_${ROUND}.sql <<SQL
SET statement_timeout = '600s';
SELECT count(*) AS n FROM golden.run_fixture($fx, '$NOTE', 'P4');
SQL
  /tmp/prd110_sql.sh /tmp/_leg138_fire_${ROUND}.sql > $OUT/f${fx}.fire 2>&1

  # (2) READ BACK from golden.runs, with a freshness floor so a stale row can never be
  #     adopted as this round's result, and with scenario_error surfaced per (B).
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    cat > /tmp/_leg138_read_${ROUND}.sql <<SQL
SELECT r.fixture_id, r.run_id, r.n_pass, r.n_fail, r.passed, r.duration_ms,
       r.detail->0->>'scenario_error'                                                         AS scenario_error,
       (SELECT count(*) FROM jsonb_array_elements(r.detail) d WHERE d ? 'seq')                AS n_eval,
       (SELECT count(*) FROM jsonb_array_elements(r.detail) d WHERE (d->>'skipped')::boolean) AS n_skip,
       COALESCE((SELECT string_agg(d->>'seq'||':'||COALESCE(d->>'actual','NULL'), ' ~ ')
                   FROM jsonb_array_elements(r.detail) d
                  WHERE NOT (d->>'passed')::boolean AND NOT (d->>'skipped')::boolean), '')    AS failures
  FROM golden.runs r
 WHERE r.fixture_id = $fx AND r.note = '$NOTE'
   AND r.finished_at IS NOT NULL
   AND r.started_at >= '$FLOOR'::timestamptz
 ORDER BY r.started_at DESC LIMIT 1;
SQL
    /tmp/prd110_sql.sh /tmp/_leg138_read_${ROUND}.sql > $OUT/f${fx}.json 2>&1
    grep -q '"n_eval"' $OUT/f${fx}.json && break
    sleep 15
  done

  t1=$(date +%s)
  echo "r$ROUND fx=$fx secs=$((t1-t0)) $(tr -d '\n' < $OUT/f${fx}.json | head -c 400)" >> $LOG
done

echo "SWEEPDONE round=$ROUND close=$(date -u +%FT%TZ)" >> $LOG
