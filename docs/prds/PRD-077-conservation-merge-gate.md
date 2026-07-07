# PRD-077: Conservation merge gate (reusable referee)

Status: SHIPPED 2026-07-07 (gate live + delta-blocking ACTIVE). Phantom scrub applied (`prd077_conservation_check_unpacked_only`: evaluate unpacked lines only) — past-date violations 20/21→0; baseline frozen (4 M2W/REMOVE orphan_removal on 2026-07-07 agreed as known-debt); delta mode PASSES. T1-T7 green. PARTIAL PRIOR ART — conservation _guards_ shipped (PRD-053 stitch conservation 2026-06-24; PRD-068 post-confirm conservation 2026-07-01). This PRD does NOT re-implement those; it wraps them into a single reusable **pre-merge pass/fail gate** callable by the WAVE0 loop and future waves. Wave 0 / 0a.2.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews, Stax wires CI.

## Why

Conservation is enforced _after the fact_ by nightly crons (`cron_conservation_monitor`, `cron_daily_inventory_reconciliation`, `monitor_stuck_remove_dispatches`) and by the shipped guards in PRD-053/068. There is no single callable that returns a **plan-level conservation verdict for a given plan_date/run** to gate a change before it merges. PRD-076 diffs plan _output_; this gate proves plan _units conserve_ across the pod↔WH boundary. Together they are the referee.

## Design (Dara designs, Cody reviews, Stax wires)

1. **`refill_qa.conservation_check(plan_date, run_id default null)`** returns `{status: pass|fail, violations: [...], totals: {...}}`. Built ON TOP of the existing `check_pod_conservation` + PRD-068 guard logic (reuse, do not fork). Assertions:
   - (a) **plan balance** per product/warehouse: planned WH-out == placed + M2W-returned.
   - (b) **batch availability**: every referenced batch has ≥ needed pickable units under the canonical pickable predicate (shared with PRD-079).
   - (c) **no orphan removal**: every REMOVE/M2W maps to a real on-machine `pod_inventory` position.
     Violation classes: `orphan_removal | phantom_batch | oversubscribed_batch | rounding_leak`.
2. **Modes:** `absolute` (all violations) and `delta` (only NEW violations vs a known-debt baseline) so pre-existing debt doesn't block a wave.
3. **CI wrapper** (Stax): fail the build on `delta` violations.
4. **Known-debt baseline**: capture today's committed-plan violation set once, agreed with CS, as the delta reference.

## Gates

- Read-only; writes nothing. Engines md5 byte-identical.
- Excludes held/quarantined/consignment stock from the WH-balance assertion (mirror PRD-079 predicate) — no false pass.
- Integer-exact; any non-integer residual is a `rounding_leak` fail.
- Cody signs the additive check. Registries updated.

## T-tests

- T1 balanced synthetic plan ⇒ `pass`.
- T2 inject orphan M2W ⇒ `fail/orphan_removal`.
- T3 reference an empty batch ⇒ `fail/phantom_batch`.
- T4 two lines one 1-unit batch ⇒ `fail/oversubscribed_batch`.
- T5 quarantined batch present ⇒ excluded, verdict correct.
- T6 run on today's committed plan ⇒ record known-debt baseline (agree with CS).
- T7 prod tables unchanged after run.

## CLOSE

RPC_REGISTRY (conservation_check) + CHANGELOG; PRD-077 status SHIPPED + EXECUTION-LOG; commit + push. Gate becomes mandatory for PRD-079..085.
