#!/usr/bin/env python3
"""PRD-110 - S7 verdict: compare three sweep rounds for identical results.

PASS requires, per PRD-110-STEP7-STRESS-DESIGN §S7:
  - three rounds, 58/58 fixtures EVALUATED each (S-201 precondition: a fixture cancelled by
    statement_timeout contributes zero to n_fail and reads as green),
  - identical (fixture_id, n_eval, n_pass, n_fail) across all three rounds,
  - zero failures.

⛔ S-242 (leg 128) - THE VERDICT COMES FROM `golden.runs`, NOT FROM THE LOCAL JSON CACHE.
The leg-127 version of this script read ONLY the per-round `r<N>/f<FX>.json` files the sweep
runner captured. That is S-212 in mirror image. S-212 established that the HTTP response body
of the FIRE is not the verdict channel, because a query can succeed server-side while the
gateway drops the response. The exact same thing can happen to the runner's READ-BACK: in
leg 127 round 0, fixture 37 ran green server-side (30/30, committed to `golden.runs`) but all
12 read-back attempts returned zero bytes, leaving `f37.json` empty. A cache-only comparison
scores that as MISSING and fails S7 on a fixture that passed.

`golden.runs` is the authoritative channel (the runner COMMITS to it before any response is
sent). So this script queries it directly and treats the local JSON purely as a cross-check:
a fixture present in the DB but missing locally is reported as a CACHE HOLE - a transport
artifact, explicitly NOT an S7 failure. A genuine disagreement in the numbers IS a failure.

Fixture population is read from `golden.fixtures`, not hardcoded, so a population change
cannot silently shrink the denominator.
"""
import json
import os
import subprocess
import sys
import tempfile

BASE = os.environ.get("S7_BASE", "/tmp/prd110_leg127_out")
NOTE_PREFIX = os.environ.get("S7_NOTE_PREFIX", "leg127 S7 r")
FLOOR = os.environ.get("S7_FLOOR", "2026-08-04T06:36:12Z")
ROUNDS = [0, 1, 2]
SHIM = "/tmp/prd110_sql.sh"


def sql(query):
    """Run a query through the leg-52 shim. Returns a list of row dicts."""
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as fh:
        fh.write(query)
        path = fh.name
    try:
        out = subprocess.run([SHIM, path], capture_output=True, text=True, timeout=1800).stdout
    finally:
        os.unlink(path)
    try:
        rows = json.loads(out)
    except Exception:
        print(f"FATAL: shim did not return JSON. First 300 bytes:\n{out[:300]}")
        sys.exit(2)
    if isinstance(rows, dict) and "error" in rows:
        print(f"FATAL: query error: {rows['error']}")
        sys.exit(2)
    return rows


# ---------------------------------------------------------------- population
FIXTURES = [r["fixture_id"] for r in sql(
    "SELECT fixture_id FROM golden.fixtures ORDER BY fixture_id;")]
N_FX = len(FIXTURES)

# ---------------------------------------------------------------- DB verdict
notes = ", ".join(f"'{NOTE_PREFIX}{r}'" for r in ROUNDS)
db_rows = sql(f"""
WITH latest AS (
  SELECT DISTINCT ON (r.note, r.fixture_id)
         r.note, r.fixture_id, r.n_pass, r.n_fail, r.passed, r.duration_ms, r.detail
    FROM golden.runs r
   WHERE r.note IN ({notes})
     AND r.finished_at IS NOT NULL
     AND r.started_at >= '{FLOOR}'::timestamptz
   ORDER BY r.note, r.fixture_id, r.started_at DESC
)
SELECT l.note, l.fixture_id, l.n_pass, l.n_fail, l.passed, l.duration_ms,
       (SELECT count(*) FROM jsonb_array_elements(l.detail) d WHERE d ? 'seq')                AS n_eval,
       (SELECT count(*) FROM jsonb_array_elements(l.detail) d WHERE (d->>'skipped')::boolean) AS n_skip,
       COALESCE((SELECT string_agg(d->>'seq' || ':' || COALESCE(d->>'actual','NULL'), ' ~ ')
                   FROM jsonb_array_elements(l.detail) d
                  WHERE NOT (d->>'passed')::boolean AND NOT (d->>'skipped')::boolean), '')    AS failures
  FROM latest l
 ORDER BY l.note, l.fixture_id;
""")

data = {r: {} for r in ROUNDS}
for row in db_rows:
    rnd = int(row["note"][len(NOTE_PREFIX):])
    data[rnd][row["fixture_id"]] = dict(
        n_eval=int(row["n_eval"]), n_pass=int(row["n_pass"]), n_fail=int(row["n_fail"]),
        n_skip=int(row["n_skip"]), passed=row["passed"], failures=row["failures"] or "",
        duration_ms=row["duration_ms"],
    )


def load_cache(rnd, fx):
    p = f"{BASE}/r{rnd}/f{fx}.json"
    if not os.path.exists(p):
        return None
    try:
        rows = json.load(open(p))
    except Exception:
        return None
    if not isinstance(rows, list) or not rows or "n_eval" not in rows[0]:
        return None
    return rows[0]


print("=" * 78)
print("S7 - golden.run_all() x3 consecutive, identical results")
print(f"verdict source: golden.runs   notes: '{NOTE_PREFIX}0/1/2'   floor: {FLOOR}")
print("=" * 78)

problems = []

# 1. completeness -----------------------------------------------------------
for r in ROUNDS:
    missing = [fx for fx in FIXTURES if fx not in data[r]]
    n_ok = N_FX - len(missing)
    print(f"round {r}: {n_ok}/{N_FX} fixtures evaluated", end="")
    if missing:
        print(f"   MISSING: {missing}")
        problems.append(f"round {r} missing verdicts for {missing}")
        continue
    tot = lambda k: sum(data[r][fx][k] for fx in FIXTURES)  # noqa: E731
    secs = sum((data[r][fx]["duration_ms"] or 0) for fx in FIXTURES) / 1000.0
    print(f"   assertions: eval={tot('n_eval')} pass={tot('n_pass')} fail={tot('n_fail')} "
          f"skip={tot('n_skip')}  server-time={secs / 60:.1f} min")

# 2. zero failures ----------------------------------------------------------
print("-" * 78)
for r in ROUNDS:
    reds = [(fx, data[r][fx]["failures"]) for fx in FIXTURES
            if fx in data[r] and data[r][fx]["n_fail"] > 0]
    if reds:
        problems.append(f"round {r} has {len(reds)} failing fixture(s)")
        for fx, f in reds:
            print(f"  RED round {r} fixture {fx}: {f[:300]}")
    else:
        print(f"round {r}: zero failing assertions")

# 3. determinism ------------------------------------------------------------
print("-" * 78)
drift = []
for fx in FIXTURES:
    tup = [None if fx not in data[r] else
           (data[r][fx]["n_eval"], data[r][fx]["n_pass"], data[r][fx]["n_fail"])
           for r in ROUNDS]
    if len(set(map(str, tup))) != 1:
        drift.append((fx, tup))

if drift:
    problems.append(f"{len(drift)} fixture(s) drifted between rounds")
    print(f"DETERMINISM: DRIFT on {len(drift)} fixture(s)  (n_eval, n_pass, n_fail)")
    for fx, tup in drift:
        print(f"  fixture {fx}: r0={tup[0]}  r1={tup[1]}  r2={tup[2]}")
        for r in ROUNDS:
            d = data[r].get(fx)
            if d and d["failures"]:
                print(f"      r{r} failures: {d['failures'][:250]}")
else:
    print(f"DETERMINISM: all {N_FX} fixtures identical (n_eval, n_pass, n_fail) across r0/r1/r2")

# 4. cache cross-check (S-242) - diagnostics only, never a verdict ----------
print("-" * 78)
holes, conflicts = [], []
for r in ROUNDS:
    for fx in FIXTURES:
        c, d = load_cache(r, fx), data[r].get(fx)
        if d is None:
            continue
        if c is None:
            holes.append((r, fx))
        elif (c["n_eval"], c["n_pass"], c["n_fail"]) != (d["n_eval"], d["n_pass"], d["n_fail"]):
            conflicts.append((r, fx, c, d))

if holes:
    print(f"CACHE HOLES (transport artifact, NOT an S7 failure): {len(holes)}")
    for r, fx in holes:
        d = data[r][fx]
        print(f"  r{r} fixture {fx}: local json empty/missing; golden.runs has "
              f"n_eval={d['n_eval']} n_pass={d['n_pass']} n_fail={d['n_fail']}")
else:
    print("CACHE HOLES: none - local cache agrees with golden.runs on presence")

if conflicts:
    problems.append(f"{len(conflicts)} cache/DB numeric conflict(s)")
    print(f"CACHE CONFLICTS (REAL problem - local disagrees with golden.runs): {len(conflicts)}")
    for r, fx, c, d in conflicts:
        print(f"  r{r} fixture {fx}: local=({c['n_eval']},{c['n_pass']},{c['n_fail']}) "
              f"db=({d['n_eval']},{d['n_pass']},{d['n_fail']})")

print("=" * 78)
if problems:
    print("S7 VERDICT: FAIL")
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print(f"S7 VERDICT: PASS  - {N_FX}/{N_FX} fixtures, 3 rounds, identical, zero failures")
