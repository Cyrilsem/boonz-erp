# PRD-110 STEP 7 — STRESS SUITE design (leg 116)

Binding plan for S1–S7. Written so any relay leg can pick up one suite as a single atomic unit.
Everything below that is **measured** says so; everything else is a hypothesis to re-derive live
(LAW 13).

## Harness (already shipped, leg 109 — do not rebuild)

- `golden.stress_runs(stress_run_id, suite, started_at, finished_at, duration_ms, passed, n_pass,
n_fail, metric jsonb, detail jsonb, driver, note)` — RLS on, zero policies, zero grants,
  `EXECUTE` revoked from PUBLIC.
- `golden.record_stress(p_suite, p_passed, p_started_at, p_metric, p_detail, p_note, p_driver,
p_n_pass, p_n_fail)` — INVOKER, `search_path = golden, public, pg_temp` (pg_temp LAST).
- ⛔ CHECK constraints bite: `suite ∈ (S1..S7)` and `driver ∈ ('sql','external')` **only**. The full
  set is six: those two plus `duration_ms >= 0`, `n_pass >= 0`, `n_fail >= 0`, PK. **Zero triggers**
  on `golden.stress_runs` and zero on `golden.runs` (re-verified live leg 129).
- ⭐ **`golden.record_stress` IS THE CANONICAL WRITER - USE IT, DO NOT RAW-INSERT.** It refuses a
  result with no `p_started_at` ("a stress result without a measured window is not evidence") and
  rejects a future start. ⚠️ It stamps `finished_at := clock_timestamp()`, so for an EXTERNAL
  multi-round sweep `duration_ms` is (window open -> bank time), **not** the true sweep window. Bank
  promptly and carry the exact per-round windows in `p_metric`.
- Contents at leg 129 pickup: **10 rows** (S6/S1/S4/S2/S5 ×1 PASS, S3 ×2 PASS, S7 ×2 FAIL from
  legs 110/117, plus leg 127's `9960d6d9` diagnostic inventory row). ⛔ None of the FAIL rows is a
  standing red on a suite; do not delete them.

## Why the stress suites are NOT golden fixtures

`golden.run_all()` is the population S7 measures for determinism. Adding heavy, fleet-scale,
deliberately-racy scenarios to that population would (a) make S7 measure itself and (b) push the
sweep past any transport ceiling. Leg 109 already ruled this and built `stress_runs` as the separate
home. **Keep S1–S6 out of `golden.fixtures`.** Their re-runnability comes from being shipped as
`golden.stress_sN_v1()` functions (SQL-driven suites) or a checked-in driver script (concurrent
suites), not from the fixture registry.

## Plan-date allocation — RESERVED, verified free 2026-08-04

Fixture plan_dates run 2030-01-02 … **2030-08-04**; `machines_to_visit`, `pod_refills_shadow`,
`shadow_runner_log_v3` and `refill_plan_output` carry nothing at all in 2030-11. Reserved band:

| suite | plan_date  |
| ----- | ---------- |
| S1    | 2030-11-01 |
| S2    | 2030-11-02 |
| S3    | 2030-11-03 |
| S4    | 2030-11-04 |
| S5    | 2030-11-05 |
| S6    | 2030-11-06 |

⛔ LAW 12: re-probe the band before each unit — a later leg may have minted a fixture into it.
⛔ Do **not** reuse a fixture's date; the fixture will clean-on-entry and destroy the stress run.

## Per-suite design

### S1 — full-fleet shadow run, all machines, one date, < 10 min, zero errors

- **Scope, measured:** 31 machines `include_in_refill AND status='Active'`; 656 rows in
  `v_shelf_state`.
- **Shape:** clean-on-entry the four shadow/date-scoped tables for 2030-11-01 → plant all 31
  machines into `machines_to_visit` as `status='picked'`, `is_included=true`, **`confirmed_at` set**
  (Gate 0 is manual-only, LAW 11 — the plant supplies the confirm, it does not bypass the gate) →
  `run_nightly_shadow_v3('2030-11-01', 7, 0, 'S1')` → measure wall clock.
- ⭐ **Where the confirm is actually read, measured from `pg_proc`:** `run_nightly_shadow_v3` itself
  contains **no** `confirmed_at` reference; `_build_draft_core_v3` **does**, and
  `build_draft_for_confirmed_v3` is the **only** function in `public` that reads the
  `gate0_require_manual_confirm` flag. So the plant's `confirmed_at` is consumed one level down the
  chain, not by the runner — do not "fix" a zero-line S1 by patching the runner.
- ⛔ `p_settle_limit => 0` is **mandatory** (S-199): STEP 3 of the runner loops other plan_dates
  (`WHERE plan_date <> v_pd`), and any other value makes the timing non-hermetic and the write set
  unbounded.
- **Pass:** duration < 600 000 ms · `shadow_runner_log_v3` shows zero `status='error'` for the date ·
  **non-vacuity**: lines > 0 and machines covered = 31 (a `no_picks` run finishing in 2 s is not a
  pass — the S-132 trap).
- ⚠️ **S-209 bears on this directly**: `v_facing_performance_v3` costs 23.6 s per materialisation.
  If it is on the nightly path, budget it; if S1 breaches 10 min, S-209 is the first suspect and it
  is already parked with its own unit.

### S2 — estimator soak: 10 000 synthetic WEIMI deltas incl. anomaly storm

- **Under test:** `estimate_shelf_composition_v3(p_shelf_id, p_dry_run, p_force_rederive)`,
  `_estimator_rise_disposition_v3`, `decay_composition_confidence_v3`.
- **Storm content (all four required, per goal command):** count > capacity · negative deltas ·
  venue fills · ordinary decrements.
- **Invariants (the actual assertions):** composition `est_qty` **never negative** · **expired
  buckets never auto-consumed** (EXPIRY IRON RULE, LAW 7 — exit only via write_off / return /
  expired_sold_incident) · confidence stays within `[0, 1]` and is monotone non-increasing under
  unexplained deltas · every count-rise that is not auto-`venue_fill` lands in
  `inventory_anomalies` (**silent qty-0 is a build failure**, LAW 5's sibling).
- ⚠️ `inventory_events` is **append-only** and currently holds 50 rows; `shelf_composition` 31;
  `inventory_anomalies` 147. A 10k-event soak moves all three permanently. **Decide before building
  whether the soak runs against a rollback-restored probe (the fixture-31 / fixture-8 idiom, proven
  four times) or is allowed to persist.** Persisting 10k rows into an append-only truth table to
  prove a stress property is the kind of thing Cody refuses; prefer the subtransaction idiom.
- ✅ **SHIPPED AND GREEN, leg 121** - `golden.stress_s2_v1(p_rounds, p_record, p_note,
p_allow_cron_window)`, migrations `20260804050000` + `20260804051000`, **25 pass / 0 fail**,
  `stress_run_id` `0e792c88`, **27 611 ms**, **10 336 deltas**. The rollback-probe question above
  is answered: subtransaction, nothing persists. ⭐ **A "delta" is one shelf observation processed
  against a distinct WEIMI snapshot** - `shelves_examined - already_processed_skipped`, summed over
  19 rounds x 544 shelves. ⛔ **S2 consumes NO plan_date**, so the reserved **2030-11-02 is
  released**. ⛔ Five things the design did not have, all now in the PARKING-LOT: **S-227** (the
  `text[] || 'literal'` failure branch crashes - binds S4 and S6 too), **S-228** (one WEIMI snapshot
  per device per calendar DATE; key on `weimi_device_id`, never `device_name`), **S-229** (the
  canonical ingest writer cannot express a dated or a draining snapshot), **S-230** (cold-start
  `correction` seeds are read as explanation for later rises, so rises go silent after two rounds
  without a `driver_confirm` re-anchor), **S-231** (zero live shelves are co_managed+venue, so the
  `venue_fill` branch is unreachable without a planted edge), **S-232** (cold start mints expired
  buckets from `max(pod_inventory.expiration_date)`, which is what makes LAW 7 testable at all -
  22 witnesses - and why any expired-bucket assertion must be role-scoped).

### S3 — concurrent edits: 20 parallel `plan_edits` + engine re-run, zero lost edits

- **Under test:** `record_plan_edit_v3(p_plan_date, p_shelf_id, p_pod_product_id, p_kind, p_qty,
p_lock, p_reason)` + `tg_plan_edits_v3_append_only` + P3.6's "re-runs NEVER drop overlay".
- **Driver: `external`.** True concurrency cannot come from one SQL session — fan out 20 parallel
  `/tmp/prd110_sql.sh` calls, then run the engine once, then count.
- **Pass:** all 20 edits present in `plan_edits_v3` (none lost, none duplicated) **and** all 20
  visible in the post-re-run plan overlay. ⛔ "20 rows exist" alone is vacuous — the PRD's property
  is _survival across the re-run_, so the count must be taken **after** the engine re-runs.
- ✅ **SHIPPED AND GREEN, leg 122** — `golden._s3_edit_plan_v1` + `golden.stress_s3_setup_v1` +
  `golden.stress_s3_verify_v1`, migrations `20260804060000` + `20260804061000`, driver
  `scripts/prd110_s3_concurrent_edits.py`. **35 pass / 0 fail / 0 skip**, `stress_run_id`
  `e08cfe09`, 39 723 ms. Wave 1: **peak concurrency 20**, span 4 692 ms against a serial sum of
  67 561 ms (14×) — the backend really did run them in parallel. **20/20 in the ledger, 20/20 still
  active, zero duplicates, `edits_considered` 21 = `applied` 21 + `yielded` 0** after the re-run;
  10/10 hard locks landed verbatim in the composed run and all 5 applied drops removed their lines.
- ⛔ **FIVE THINGS THE DESIGN DID NOT HAVE, all now in the PARKING-LOT.** **S-233** (a same-key
  concurrent edit can lose with a bare 23505 — correct at the DB, but the FE edit drawer needs a
  retry); **S-234** (client in-flight overlap is NOT backend contention — the critical section is
  milliseconds, so a wave needs a server-side clock barrier or it never races and still passes);
  **S-235** (`plan_edits_v3` is append-only, so a stress suite that writes it can never be a
  rollback probe — bank the pre-existing counts instead of assuming a virgin date, which is what
  makes S3 re-runnable with a STRICT equality rather than a `>=`); **S-236** (a subtransaction
  rollback does NOT release a TRUNCATE's ACCESS EXCLUSIVE lock — probe last, never before an engine
  run); **D-45** (`add` is ADDITIVE in `record_plan_edit_v3` and ABSOLUTE in
  `compose_plan_with_edits_v3` — assertion 20 pins the current behaviour on purpose).

### S4 — pipeline chaos: every engine 3× same date, idempotent, no dup lines

- ⭐ **Draft already exists:** `docs/prds/PRD-110-S4-scenario-DRAFT.sql` (leg 109). ⛔ **NOT
  dry-proven** — it was authored while S7 held the DB. Dry-test it (DO block ending in
  `RAISE EXCEPTION` carrying the payload; `RAISE WARNING` does not return through the API) before
  shipping.
- ⛔ **S-199 is the whole design:** the shadow tables are `run_id`-keyed and `engine_add_pod_v3`
  mints `gen_random_uuid()` per call with no DELETE and no ON CONFLICT, so three runs legitimately
  produce three generations. **"Idempotent" means content equality per `run_id`, NOT row-count
  stability.** An S4 asserting "row count unchanged" goes RED against correct behaviour.
- Mandatory: `p_settle_limit => 0` · clean-on-entry (the engine never deletes its own prior
  generations) · non-vacuity (three `no_picks` summaries are trivially identical) · the
  ADR §8 obligation-3 tripwire that live `pod_refills` / `pod_refill_plan` counts do not move **at
  all** (absolute, not scoped to plan_date).

### S5 — spot-buy race: receive + bind concurrent with pack, no double debit

- **Under test:** `create_spot_purchase_v3(...)` and `receive_spot_fill_po_v3(...)` — both carry a
  `p_dry_run` argument, which is the safe way in.
- **Driver: `external`** (two connections, deliberately interleaved).
- **Pass:** warehouse stock is debited **exactly once** across the race; no dispatch line binds
  twice; conservation exact end-to-end.
- ⛔ Touches `warehouse_inventory` (Appendix A) — **its own Cody review**, and any plant carries
  `provenance_reason='snapshot'` (S-189). ⛔ Note S-202 is open and independent: `authenticated`
  still holds INSERT/UPDATE/DELETE/TRUNCATE on `warehouse_inventory`; do **not** fold that revoke
  into S5.

#### ⛔ DESIGN CORRECTED, leg 123 — THE "BINDS TWICE" CRITERION IS ALREADY RED (S-237)

**The race axis is `bind_dispatch_fefo` vs `pack_dispatch_line`, not the two spot RPCs against each
other.** Read live from `pg_proc`, leg 123:

- `create_spot_purchase_v3` **credits** `warehouse_inventory` (INSERT of a fresh Active batch) and
  then calls `bind_dispatch_fefo` at step 6, machine-scoped.
- `receive_spot_fill_po_v3` **never touches `warehouse_inventory` at all** — that is D-E, stated in
  its own body. Its phase-2 write is a NET-ZERO re-bucket on `shelf_composition` guarded by
  `status='received'` under `SELECT ... FOR UPDATE`. ⛔ **So "no double debit" cannot be asserted
  against this RPC.** An S5 that races the two spot RPCs and calls it a debit test is vacuous — the
  S-132 sin, in the same shape S6 nearly shipped with.
- The only warehouse **debit** on the pack path is `pack_dispatch_line`.

⭐ **`pack_dispatch_line` IS CLEAN AND S5 SHOULD PROVE IT POSITIVELY:** `FOR UPDATE` on the dispatch
row _before_ the `packed` test, and a relative-delta debit (`warehouse_stock = warehouse_stock -
qty`) under `FOR UPDATE` on the batch. Pack-vs-pack cannot lose an update or double-debit.

⛔ **`bind_dispatch_fefo` IS NOT — S-237, proven empirically, reproducer
`scripts/prd110_s5_epq_rebind_probe.sh`.** Its `packed=false` and `from_wh_inventory_id IS NULL`
predicates live in the `targets` CTE, while the final UPDATE joins on `dispatch_id` alone; the
EvalPlanQual recheck after a lock wait re-evaluates **only the UPDATE's quals**, so a line packed
mid-flight is still re-bound. Measured: B blocked 3.0 s on P's lock, released the instant P
committed, and re-bound a `packed=true` row reporting `bound=1`.

⛔ **THEREFORE:** S5's pass criterion _"no dispatch line binds twice"_ is **RED against current
code**. ⏸️ **D-46 is the open ask** — pin the defect as a sensor (fixture-9 / D-45 idiom) or fix the
binder's two predicates first under its own Cody pass. **Nothing waits on it to start building**;
the plant and barrier machinery is identical either way.

⭐ **Build notes carried forward for whoever ships S5:**

- **Server-side clock barrier is mandatory (S-234)** and the S3 idiom transfers directly. The
  additional S5 requirement is an _offset_ barrier, not a common one: the bind contender must
  enter ~2 s AFTER the pack contender so it snapshots before the pack commits. **The witness is
  the bind side's lock-wait duration** — no wait means no race, and the suite must fail rather
  than pass on it.
- ⛔ **A planted `warehouse_inventory` batch is pickable by REAL dispatch lines.** Set
  `reserved_for_machine_id` to the synthetic test machine: both `bind_dispatch_fefo` and
  `pack_dispatch_line` honour `reserved_for_machine_id IS NULL OR = machine_id`, which fences the
  plant off from the live fleet. ⛔ Plus S-189 `provenance_reason='snapshot'`.
- ⛔ **CORRECTION, leg 125 (S-238) — THAT FENCE IS NOT DURABLE AND THE BULLET ABOVE OVERSTATES IT.**
  `release_stale_wh_pins` (**cron 34, `50 * * * *`**) nulls `reserved_for_machine_id` on any batch
  with **no packed-and-not-yet-picked-up** dispatch line for that machine+product. A plant whose
  lines are still unpacked is therefore un-fenced at the next `:50` and becomes visible to the whole
  fleet. Leg 124's plant was released 15 minutes after it was made. ⛔ **Re-pin immediately before
  the waves and re-measure `setup_ok`; a handle rebuilt from a stale plant lies.** ⭐ Once the waves
  pack both lines the pins become permanent, because `packed=true, picked_up=false` is the cron's
  own exemption. ⛔ There is **no canonical writer** for that column — re-pinning is a named harness
  exemption (Cody, leg 125), not a precedent for engine code.
- ⛔ **S5 cannot be a rollback probe.** The pack contender MUST commit for the bind contender to
  unblock and observe the new row version — that is the whole experiment. Bank pre-existing counts
  and use strict equality, per S-235.
- ⭐ Carry the S-223 cron-window refusal (:36–:48 UTC, cron 44) and the S-213 midnight-UTC rule.

### S6 — blocked_demand volume: 500 open rows, procurement view + aging correct

- **Under test:** `v_blocked_demand_open`, `v_procurement_blocked_products`,
  `record_blocked_demand_v3`.
- **Current state, measured:** `blocked_demand` 44 rows, 20 open.
- ⛔ **THE RESERVED-DATE PLAN DOES NOT WORK HERE, AND THE VIEW DEFINITION IS WHY.** Read live from
  `pg_get_viewdef`, not assumed:
  `WHERE bd.resolved_at IS NULL AND bd.plan_date < '2030-01-01'::date`. **The view deliberately
  excludes the whole synthetic 2030 band.** Planting 500 rows on 2030-11-06 yields **zero** view
  rows — S6 would pass vacuously, which is the S-132 sin. ⭐ **S6 must therefore plant on a real
  past date inside a rollback-restored subtransaction** (the fixture-31 / fixture-8 idiom, proven
  four times): a `DO` block that plants, measures, and ends in `RAISE EXCEPTION` carrying the metric
  payload — `RAISE WARNING` does not return through the API. The metric is then recorded into
  `golden.stress_runs` by a **separate** statement. Nothing persists in `blocked_demand`.
  ⛔ Do **not** instead relax the view's 2030 guard to make the reserved date work: that guard is
  what keeps every fixture's synthetic blocked rows out of the live procurement worklist.
- ⛔ **`age_bucket` IS COMPUTED OFF `plan_date`, NOT `created_at`** — `CURRENT_DATE - bd.plan_date`,
  bucketed `>=14 critical · >=7 aging · >=3 watch · else fresh`. So the plant controls the bucket by
  choosing `plan_date` offsets, and the bucket-edge assertions must be written against
  `CURRENT_DATE - plan_date` at exactly 2/3, 6/7 and 13/14 days.
- ⛔ **`v_procurement_blocked_products` IS NOT THE `blocked_demand` CONSUMER.** It selects from
  `boonz_products` where `boonz_product_block_reason(product_id) IS NOT NULL` and never references
  `blocked_demand` at all — a product-level block-reason report, a different object with a
  confusingly similar name. **The goal command's "procurement view" for S6 is
  `v_blocked_demand_open` plus the weekly-procurement skill that reads it.** Asserting over
  `v_procurement_blocked_products` would prove nothing about blocked demand.
- ⚠️ `record_blocked_demand_v3` is the table's **only deleter** and does delete-then-insert per
  `(plan_date, source)`. Inside the rollback probe this cannot bite, but it is why a persisted
  plant would have been unsafe.
- **Pass:** the view returns all 500 planted rows · the four aging buckets partition them exactly
  (sum = 500) with correct behaviour on both sides of each edge · no fan-out in the join
  (⛔ never through `product_mapping` — DATA-SOURCE LAW) · `blocked_demand` count is **identical
  before and after** the probe.
- **This is still the cheapest suite. Good first unit for a short leg.**
- ✅ **SHIPPED AND GREEN, leg 117** — `golden.stress_s6_v1(p_n, p_record, p_note)`,
  migration `20260804020719`, **16 pass / 0 fail**, `stress_run_id` 55c12f45. Every premise above
  held on live re-derivation. ⛔ **One the design did not have:** `uq_blocked_demand_open` UNIQUE
  `(plan_date, machine_id, shelf_id, pod_product_id, source) WHERE resolved_at IS NULL` — the plant
  must be distinct on that 5-tuple. ⭐ Built on `CURRENT_DATE - off` offsets, never absolute dates,
  so it is re-runnable on any day (S-213).

### S7 — `golden.run_all()` ×3 consecutive, identical results

- ⛔ **Must be LAST.** Any fixture or assertion added by S1–S6 work changes the population and
  invalidates an earlier S7.
- ⛔ **`run_all()` itself TIMES OUT** through the API — S7 is executed as a per-fixture sweep over the
  58 fixtures in `scripts/prd110_s7_fixtures.txt`, three rounds into `r0/`, `r1/`, `r2/`.
- ⭐ **THE RUNNER AND THE COMPARATOR ARE BOTH CHECKED IN NOW - USE THESE TWO AND NOTHING ELSE:**
  `scripts/prd110_s7_golden_determinism_sweep.sh <round>` (leg 126/127; byte-identical to the
  `/tmp/prd110_leg127_s7.sh` that produced the banked sweep) and `scripts/prd110_s7_compare_rounds.py`
  (leg 128). ⛔ `prd110_s7.sh`, `prd110_sweep.sh`, `prd110_leg116_sweep.sh`, `prd110_leg117_sweep.sh`
  and `/tmp/prd110_leg127_compare.py` are **ALL superseded** — the last of those carries the S-242
  defect below. Drive the three rounds strictly sequentially; **two concurrent sweeps on one fixture
  population destroy the determinism measurement silently** (S-241).
- ⭐ The runner carries three guards worth preserving in any successor: a per-round output subdir
  (S-210), a per-round **freshness floor** on the read-back so a stale same-note row can never be
  adopted as fresh, and a **cron-44 straddle guard** refusing to start a fixture in minutes [37,40]
  (S-223) because fixtures 2/19/20/21/22/27 each pin a `shelf_composition` count that cron 44
  rewrites at `:40`.
- ⛔ **`fixtures_evaluated = fixtures_enabled` is a PRECONDITION** (S-201). A fixture cancelled by
  `statement_timeout` contributes **zero** to `n_fail` and therefore reads as green — that is how
  fixture 48 hid for ~25 legs. The runner sets `statement_timeout = '600s'` per call; fixture 48
  needs ~71 s.
- ⛔ **S-204 is the class that makes S7 fail**: an assertion pinning a count over a table that a
  **non-reclaiming** fixture writes to drifts _between rounds_, not within one. Before pinning any
  constant, ask who writes that population and whether it cleans up.
- **Pass:** three rounds, 58/58 evaluated each, identical `(fixture_id, n_eval, n_pass, n_fail)`
  across all three, zero failures.
- ⛔ **S-212 (leg 117) — THE RUNNER MUST NOT TAKE THE VERDICT FROM THE RESPONSE BODY.** Measured:
  fixture 42 completed server-side in 107.5 s and COMMITTED its `golden.runs` row, but the gateway
  cut the response at 79 s; fixture 7 took 101.8 s in the same round and returned fine. Flaky
  transport, not a ceiling — **no `statement_timeout` fixes it, the query already succeeded**. An
  error blob contributes 0 to `n_fail` and reads as a green. ⭐ **Use
  `/tmp/prd110_leg117_sweep.sh`**: fire the run, discard the response, read `n_pass`/`n_fail`/
  `detail` back from `golden.runs`. ⛔ `prd110_s7.sh`, `prd110_sweep.sh` and
  `prd110_leg116_sweep.sh` are all superseded.
- ⛔ **S-213 (leg 117) — DO NOT LET A ROUND BOUNDARY CROSS 00:00 UTC.** `days_since_visit` and every
  other `CURRENT_DATE`-derived term steps at the rollover; fixture 42 went green→red across it with
  no migration. Three rounds span hours, so schedule them clear of 00:00 UTC (avoid 03:00–05:00
  Dubai) and record the UTC window in the `stress_runs` note.
- ⛔ **S-242 (leg 128) — THE READ-BACK IS NOT THE VERDICT CHANNEL EITHER. S-212 IN MIRROR IMAGE.**
  S-212 established that the FIRE's response body can be dropped while the query succeeds
  server-side. The identical thing happens to the runner's **READ-BACK**. Measured, leg 127 round 0:
  fixture 37 ran green **30/30 in 71.9 s and COMMITTED** to `golden.runs`, while the fire and all
  twelve read-back attempts returned **zero bytes** across a ~95 min gateway blackout
  (~06:54Z–08:29Z; `pg_stat_activity` carried no long-running statement throughout). The local
  `r0/f37.json` was left empty. ⛔ **A comparator that scores a missing local file as a missing
  verdict returns S7 FAIL on a fixture that passed** — which is exactly what the superseded
  `/tmp/prd110_leg127_compare.py` does. ⭐ **`golden.runs` is the ONLY verdict channel**; the local
  JSON is a cache. In `scripts/prd110_s7_compare_rounds.py` a **cache hole** (DB has it, file does
  not) is reported as a transport artifact and is explicitly **NOT** a failure, while a **numeric
  conflict** between the two IS one. Read the fixture population from `golden.fixtures`, never
  hardcoded, so the denominator cannot silently shrink.
- ⭐ **ROUND 0 BANKED, leg 117** (`b7051cfb`, passed=false): **58/58 fixtures and 2085/2085
  assertions evaluated** — the first sweep where both preconditions hold — **1 failure, fixture 42
  seq 60 only** (see D-44). Server-time sum 18.8 min.

## Order of execution

**S6 → S1 → S4 → S2 → S3 → S5 → S7.** ✅ S6 ✅ S1 ✅ S4 ✅ S2 ✅ S3 — **S5 next (design corrected leg 123, see S-237/D-46 above; not yet built), then S7 strictly last.** Cheapest and most self-contained first; the two
`external`-driver races (S3, S5) late, because they need a driver harness neither of the others
needs; S7 strictly last.

---

## ✅ S7 CLOSED — leg 131, 2026-08-04

**PASS.** Three rounds (leg 127's chain), **58/58 fixtures and 2094/2094 assertions evaluated in
every round, 0 fail, 0 skip**. Determinism md5 over `fixture_id:n_eval:n_pass:n_fail` for all 58
fixtures = **`da378010046d0de43470f13caa96b27c`** for r0, r1 AND r2.
Windows (S-213, single UTC day): r0 `06:36:13.98Z / 08:37:23.23Z` · r1 `08:41:29.20Z / 09:13:09.29Z`
· r2 `09:13:13.81Z / 09:36:40.67Z`.
Banked `golden.stress_runs` **`03794cbf-857f-46e4-85af-a0347237b8c5`**, `passed=true`, **6282 / 0**,
driver `external`, six seq'd pass criteria in `detail`.

⛔ **THE VERDICT WAS READ FROM `golden.runs`, NEVER FROM A RESPONSE BODY OR A PROGRESS LOG**
(S-212 + S-242), and every banked number was recomputed server-side inside the banking SQL rather
than transcribed from the comparator's stdout — two independent derivations that agree.

### ✅ Order of execution — COMPLETE

**S6 ✅ → S1 ✅ → S4 ✅ → S2 ✅ → S3 ✅ → S5 ✅ → S7 ✅.** All seven suites banked green.
