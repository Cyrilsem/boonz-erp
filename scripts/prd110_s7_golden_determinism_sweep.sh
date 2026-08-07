#!/bin/zsh
# PRD-110 leg 126 — S7 sweep runner (golden.run_all() x3 consecutive, identical results).
#
# INHERITS the leg-117 design (S-212): the HTTP response body is NOT the verdict channel.
# golden.run_fixture COMMITS to golden.runs; we fire, discard the body, and read the verdict
# back in a separate short query that cannot exceed the gateway ceiling.
#
# THREE CHANGES vs /tmp/prd110_leg117_sweep.sh, each closing a hole found this leg:
#
#  (1) NOTE NAMESPACE. leg117's note was 'leg117 S7 r<N>'. golden.runs holds no such rows, but
#      the read-back selected ORDER BY started_at DESC LIMIT 1 with no lower bound - so if a
#      fire silently failed to commit, a STALE row with the same note would be adopted as this
#      round's result. Notes are now leg-126 scoped AND the read-back carries a freshness
#      floor (started_at >= the round's own start), so a stale row can never be mistaken for
#      a fresh one. A missing row now reads as missing, which is the honest outcome.
#
#  (2) CRON-44 STRADDLE GUARD (S-204 / S-223 class). Fixtures 2, 19, 20, 21, 22 and 27 each
#      carry a seq-96 conservation assertion of the form
#         count(*) FROM public.shelf_composition  ==  golden.scratch['before'].comp
#      i.e. a snapshot taken at fixture START compared against the live count at fixture END.
#      cron 44 (prd110_p14_composition_estimator_hourly, '40 * * * *') REWRITES that table
#      every hour. Measured this leg: it starts at :40:00 and runs 2.1-2.6 s. A fixture that
#      straddles that instant would red seq 96 for a reason that has nothing to do with the
#      fixture - and being a BETWEEN-rounds drift, it is exactly the S-204 class that makes S7
#      fail. The guard refuses to START a fixture in minutes [37,40] and waits until :41:00.
#      The longest fixture is 42 at ~105 s, so a start at :36:59 ends by :38:45: safe.
#
#  (3) ROUND WINDOW RECORDED (S-213). Each round logs its UTC open/close so the stress_runs
#      note can carry the window. Rounds must not cross 00:00 UTC.
#
# S-210 stays fixed: per-round output subdirectories, nothing is ever deleted.
#  (4) NOTE NAMESPACE IS A PARAMETER (leg 144). Change (1) requires the note to be leg-scoped,
#      but the prefix was hard-coded to 'leg127', so every later leg had to fork the file.
#      Pass the prefix as $2. Rows in golden.runs stay attributable to the leg that fired them.
set -u
ROUND=${1:?usage: prd110_s7_golden_determinism_sweep.sh <round> [note_prefix]}
PREFIX=${2:-leg127}
NOTE="${PREFIX} S7 r${ROUND}"
BASE=/tmp/prd110_${PREFIX}_out
OUT=$BASE/r${ROUND}
mkdir -p $OUT
LOG=$BASE/progress.log
FIXTURES=$(cat /tmp/prd110_s7_fixtures.txt)

# freshness floor for this round's read-backs
FLOOR=$(date -u +%FT%TZ)
echo "SWEEPSTART round=$ROUND note='$NOTE' floor=$FLOOR" >> $LOG

for fx in ${(f)FIXTURES}; do
  # resume guard: a captured result must actually carry n_eval, not merely be non-empty
  if [ -f $OUT/f${fx}.json ] && grep -q '"n_eval"' $OUT/f${fx}.json; then continue; fi

  # (0) CRON-44 STRADDLE GUARD - never start a fixture in minutes [37,40]
  while true; do
    M=$(date -u +%M); M=${M#0}
    if [ "$M" -ge 37 ] && [ "$M" -le 40 ]; then
      echo "r$ROUND fx=$fx HOLD for cron44 window at $(date -u +%FT%TZ)" >> $LOG
      sleep 30
    else
      break
    fi
  done

  t0=$(date +%s)

  # (1) FIRE. Response is discarded - it is not the verdict channel.
  cat > /tmp/_leg127_fire_${ROUND}.sql <<SQL
SET statement_timeout = '600s';
SELECT count(*) AS n FROM golden.run_fixture($fx, '$NOTE', 'P4');
SQL
  /tmp/prd110_sql.sh /tmp/_leg127_fire_${ROUND}.sql > $OUT/f${fx}.fire 2>&1

  # (2) READ BACK from golden.runs. Short query, immune to the gateway ceiling. Poll in case
  #     the server is still finishing after the gateway gave up on us.
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    cat > /tmp/_leg127_read_${ROUND}.sql <<SQL
SELECT r.fixture_id, r.run_id, r.n_pass, r.n_fail, r.passed, r.duration_ms,
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
    /tmp/prd110_sql.sh /tmp/_leg127_read_${ROUND}.sql > $OUT/f${fx}.json 2>&1
    grep -q '"n_eval"' $OUT/f${fx}.json && break
    sleep 15
  done

  t1=$(date +%s)
  echo "r$ROUND fx=$fx secs=$((t1-t0)) $(tr -d '\n' < $OUT/f${fx}.json | head -c 300)" >> $LOG
done

echo "SWEEPDONE round=$ROUND close=$(date -u +%FT%TZ)" >> $LOG
