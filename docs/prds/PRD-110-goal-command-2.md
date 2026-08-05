# PRD-110 GOAL COMMAND 2 — EXECUTION SPRINT · from DONE to cutover-ready

# Operator: Claude Code (Opus). Read this file FIRST and in full. Then:

# 1. PRD-110-goal-command.md — THE LAW (1–13), RELAY protocol, PARKING protocol, ENVIRONMENT

# CARD, ANTI-PATTERNS. ALL of it binds this sprint unchanged, except as amended below.

# 2. PRD-110-EXECUTION-LOG.md — tail only: the leg-131 DONE report + the leg-125 RESUME POINTER

# conventions (S-241 ps-first, RISK 104 probe order, S-80 whole-file decision grep).

# 3. PRD-110-PARKING-LOT.md — IN FULL. The CS rulings of 2026-08-04 at the bottom are BINDING:

# "D-43..D-47 ALL CLOSED" + "POST-DONE DR REGISTER CLOSED".

## MISSION

PRD-110 build is DONE (leg 131, 2026-08-04T09:45Z). This sprint EXECUTES the accumulated,
fully-answered work queue and builds the authorized units. No open CS question exists at start.
Same relay loop, same log (append to PRD-110-EXECUTION-LOG.md, legs continue numbering from 132),
same parking discipline. **Halt marker for THIS sprint: `## DONE-2` (exactly).**

## THE WORK QUEUE (order within tiers is the operator's; tiers are priority order)

### Tier 1 — safety + correctness (already-ruled defects)

- **D-46 EXECUTE:** `bind_dispatch_fefo` two-predicate fix (the parked migration), Cody review,
  then update S5's S-237 sensor — the red-then-fix IS the proof. md5 45ec06ab must move.
- **D-45 EXECUTE:** `add` is ADDITIVE — fix `compose_plan_with_edits_v3`, leave the writer.
  S3 assertion 20 flips as proof.
- **DR-3 BUILD:** pod_inventory physical write-freeze (revoke + write-guard + daily-delta report).
- **D-43 EXECUTE:** warehouse self-serves repack — add `warehouse` to push role list AND the
  repack pre-flight authorisation check (both halves, per the ruling).
- **DR-4 EXECUTE:** `spot_buy_cap_enforcement` → 'block' (cap stays AED 15).

### Tier 2 — the 12 answered decisions (D-19*, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34,

D-37, D-39, D-40) — fixture-first, one unit each, per their parking-lot rulings.
*D-19 waits on DR-6's FE deploy; do DR-6 first (Stax unit: p_force passthrough + refusal
affordance), then flip `preflight_enforcement` → block and update fixture 33 seq 91 as proof.

### Tier 3 — ruled policy/build items

- **D-44 EXECUTE:** picker reserves K=2 of 6 day slots for the money rule; fixture 42
  self-supplies its precondition + |breached|-vs-capacity sensor; seq 60 NOT loosened.
- **D-47 EXECUTE:** fixture 28 synthetic tier plant (policy_seed branch executed, not inspected).
- **DR-5 EXECUTE:** apply w_empty 0.900→0.945, set both miner dry-run flags false.
- **DR-7 EXECUTE:** rotation heartbeat cron, weekly Sunday (Dubai-sensible hour, Cody-reviewed).
- **DR-8 BUILD:** facing-rightsizing approve-RPC (the 23 proposals stay for CS review).
- Parked units: S-233 same-key retry · S4/S6 `::text` re-ship.

### Tier 4 — DR-1: BUILD the per-cluster cutover unit (Dara design → Cody review → fixture).

Ships FLAG-OFF. LAW 4 holds: this sprint NEVER flips it. DR-2 (sentinel inactivation) stays
parked behind the actual cutover. The unit must make the flip auditable, reversible per cluster,
and refuse to flip a cluster while WMAPE for v3 is vacuous (`horizon_not_elapsed` — settles
2026-08-11).

## AMENDMENTS TO THE LAW FOR THIS SPRINT

- LAW 4 amended only this far: ruled flag flips listed above (DR-4, DR-5, D-19-after-DR-6) are
  AUTHORIZED executions, not violations. The CUTOVER flag itself remains untouchable.
- Everything else — LAW 12 (live plan tables), fixture-first, Cody on every migration, S-241,
  RISK 104, S-80, no version drift — binds unchanged.
- S-244 reminder: any CS-facing diff read filters `plan_date < '2027-01-01'`.

## DEFINITION OF DONE-2

Tiers 1–3 fully executed with fixture proof · DR-1 unit built flag-off with its fixture green ·
golden fully green (run_all ×1 suffices; S7-style triple only if the fixture population changed) ·
every flag state change logged with before/after · DONE-2 report (≤40 lines: what flipped, what
shipped, what the cutover flip will require of CS on ~Aug 17) · append `## DONE-2`.

# BEGIN. STEP R per the original goal command. Do not stop until DONE-2 or a hard unparkable blocker.
