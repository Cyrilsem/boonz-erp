#!/bin/zsh
# PRD-110 leg 123 — S-237 reproducer.
#
# PROVES: a CTE-filtered UPDATE does NOT re-apply its CTE's predicates during the
# EvalPlanQual recheck that follows a concurrent-update lock wait. This is the exact
# shape of `bind_dispatch_fefo`, whose `packed=false` / `from_wh_inventory_id IS NULL`
# filters live in the `targets` CTE while the final UPDATE joins on `dispatch_id` alone.
#
# Consequence in production: a dispatch line that becomes packed (or bound) between the
# bind statement's snapshot and its row lock IS STILL RE-BOUND, silently re-pointing a
# packed line at a warehouse batch it was never picked from.
#
# This probe deliberately uses a SCRATCH TABLE, not refill_dispatching: it isolates the
# Postgres semantics with zero exposure to a protected entity. The full S5 suite is what
# exercises the real function.
#
# Usage: ./scripts/prd110_s5_epq_rebind_probe.sh
# Requires: /tmp/prd110_sql.sh (the project's DB access shim).
#
# EXPECTED OUTPUT (the defect is present):  id 1 -> packed=true, bound='BOUND_BY_B'
# If it ever reads bound='PACKED_BY_P', the recheck DID re-apply the filter and S-237
# has been fixed (or the planner shape changed) — re-derive before trusting either way.
set -e
SHIM=/tmp/prd110_sql.sh
[ -x "$SHIM" ] || { echo "missing $SHIM"; exit 1; }

echo "$SHIM" >/dev/null

# ---------------------------------------------------------------- setup
cat > /tmp/s5_probe_setup.sql <<'EOF'
DROP TABLE IF EXISTS golden._s5_epq_probe;
CREATE TABLE golden._s5_epq_probe(id int PRIMARY KEY, packed boolean NOT NULL DEFAULT false, bound text);
INSERT INTO golden._s5_epq_probe(id, packed, bound) VALUES (1, false, 'INITIAL');
SELECT extract(minute FROM now() AT TIME ZONE 'UTC') AS utc_min;
EOF
$SHIM /tmp/s5_probe_setup.sql

# Contender P == the PACK side. Takes the row lock, stamps packed=true, then HOLDS the
# lock uncommitted for 5 s so the bind side is guaranteed to queue behind it.
cat > /tmp/s5_probe_P.sql <<'EOF'
DO $$
DECLARE v_barrier timestamptz;
BEGIN
  v_barrier := to_timestamp(ceil(extract(epoch from clock_timestamp())/30.0)*30 + 30);
  PERFORM pg_sleep(GREATEST(0, EXTRACT(EPOCH FROM (v_barrier - clock_timestamp()))));
  UPDATE golden._s5_epq_probe SET packed=true, bound='PACKED_BY_P' WHERE id=1;
  INSERT INTO golden._s5_epq_probe(id,packed,bound) VALUES (10,false,'P_barrier='||v_barrier||' entered='||clock_timestamp());
  PERFORM pg_sleep(5);
END $$;
SELECT 'P_committed' AS who, clock_timestamp() AS t;
EOF

# Contender B == the BIND side, in bind_dispatch_fefo's exact CTE shape. Enters 2 s after
# the barrier: P's packed=true is written but NOT yet committed, so B's snapshot still
# sees packed=false and the row qualifies in `targets`.
cat > /tmp/s5_probe_B.sql <<'EOF'
DO $$
DECLARE v_barrier timestamptz; v_bound int;
BEGIN
  v_barrier := to_timestamp(ceil(extract(epoch from clock_timestamp())/30.0)*30 + 30) + interval '2 second';
  PERFORM pg_sleep(GREATEST(0, EXTRACT(EPOCH FROM (v_barrier - clock_timestamp()))));
  INSERT INTO golden._s5_epq_probe(id,packed,bound) VALUES (11,false,'B_barrier='||v_barrier||' entered='||clock_timestamp());
  WITH targets AS (
    SELECT p.id FROM golden._s5_epq_probe p WHERE p.id=1 AND COALESCE(p.packed,false) = false
  ),
  picks AS (SELECT t2.id, 'BOUND_BY_B'::text AS newval FROM targets t2),
  upd AS (
    UPDATE golden._s5_epq_probe p SET bound = picks.newval
    FROM picks WHERE p.id = picks.id AND picks.newval IS NOT NULL
    RETURNING 1
  )
  SELECT count(*) INTO v_bound FROM upd;
  INSERT INTO golden._s5_epq_probe(id,packed,bound) VALUES (12,false,'B_reported_bound='||v_bound||' exited='||clock_timestamp());
END $$;
SELECT 'B_committed' AS who, clock_timestamp() AS t;
EOF

# ------------------------------------------------------------- fire both
( $SHIM /tmp/s5_probe_P.sql > /tmp/s5_P.out 2>&1 & \
  $SHIM /tmp/s5_probe_B.sql > /tmp/s5_B.out 2>&1 & \
  wait )
echo "=== P ==="; cat /tmp/s5_P.out
echo "=== B ==="; cat /tmp/s5_B.out

# ------------------------------------------------------------- verdict
echo "=== VERDICT (id 1: bound=BOUND_BY_B means S-237 REPRODUCED) ==="
echo "SELECT id, packed, bound FROM golden._s5_epq_probe ORDER BY id;" | $SHIM -

# ------------------------------------------------------------- clean up
echo "DROP TABLE IF EXISTS golden._s5_epq_probe;" | $SHIM -
echo "scratch dropped"
