# PRD-110 GOAL COMMAND — ONESHOT loop · Refill Engine v3 "One Brain"

# Operator: Claude Code (Opus). Read this file FIRST and in full. Then read, in order:

# 1. PRD-110-refill-engine-v3-one-brain.md (charter — why/what, decisions CLOSED §11)

# 2. PRD-110-BUILD-SPEC.md (how exactly, per phase — binding)

# 3. PRD-110-GOLDEN-FIXTURES.md (proof harness — build first)

# 4. Skills: boonz-master-3 (data-source law), cody, dara, stax, weekly-procurement

# 5. Memory MEMORY.md hard-rules section (binding constraints)

## MISSION

Execute PRD-110 end-to-end as ONE GOAL. Complete the FULL build — all phases — fully
tested and stress-tested, without waiting on CS mid-loop. There are NO human pauses in
this loop. Checkpoints self-verify on green evidence and the loop continues. Anything
that genuinely requires CS judgment is BUILT FLAG-OFF and PARKED (see PARKING protocol);
the loop routes around it and keeps going. The loop ends only at DONE or at a hard
blocker that no parking can route around (then it reports precisely and stops).

**ONE GOAL ≠ one session.** The build exceeds any single context window. Context
exhaustion is NOT a stop — it is a HANDOFF (see RELAY protocol). An outer loop
re-launches sessions until the EXECUTION-LOG contains the `## DONE` marker. Every
session is a relay leg: pick up the baton, advance the build, hand off clean.

Do not confuse **Gate 0** (the RUNTIME machine-pick gate — a product feature CS uses
when refilling; wave-1 manual-only, build it exactly as specced) with build checkpoints
(loop-internal, never wait for a human).

## DEFINITION OF DONE

All phases 0–5 built · all golden fixtures green · stress suite green · shadow mode live
and diffing nightly against v19 with scoreboard populated · every CS-judgment item parked
with a ready-to-flip flag and a one-line decision ask · DONE report written. (Live
cutover itself is a parked flag — CS flips it after reviewing shadow results; the build
does not wait for that.)

## PARKING protocol (replaces human gates)

File: PRD-110-PARKING-LOT.md. Two sections:

- **DECISIONS-READY**: fully built, flag-off, one line each: what it is, evidence it works
  (fixture ids), the single flag/command CS runs to activate. Known members: live-engine
  cutover per cluster · sentinel deletion (build + prove with fixture 24, DO NOT delete —
  park the delete script) · pod_inventory freeze (shadow diff runs, freeze parked) ·
  operating-model backfill apply (generate mapping, park the apply) · spot-buy pre-auth
  caps (default snacks/drinks ≤ AED 15, park the param) · pick-learning weight
  application (proposals generated, application parked).
- **STUCK**: anything blocked >2 attempts: what, why, what was tried, smallest unblock.
  Park it, continue the loop on independent work. Nothing waits idle behind a stuck item
  unless it is a hard dependency of everything (then report + stop).

## RELAY protocol (session handoff — how the loop survives context limits)

**On session start (STEP R — always before anything else):**

1. Read the tail of PRD-110-EXECUTION-LOG.md — find the latest `### RESUME POINTER` block.
   If none exists, this is the first leg: run STEP 0 from EXECUTION ORDER.
2. Read PRD-110-PARKING-LOT.md in full.
3. VERIFY the pointer against reality before trusting it: one probe query per claim in
   the pointer's state summary (DB migrations applied? fixtures actually green? cron
   present?). If the log and DB disagree, reconcile FIRST and record the discrepancy.
4. Re-read THE LAW. Then continue from the pointer's "next task".

**During the session:** work in ATOMIC units — a migration + its verify + its log entry
land together or not at all. Never begin a unit you cannot finish this session.

**On approaching context limit (~75% consumed, or when the next atomic unit won't fit):**

1. Finish or cleanly abort the current atomic unit (DB, migration files, log must agree —
   "nothing half-applied" is the handoff invariant).
2. Append to EXECUTION-LOG a `### RESUME POINTER <timestamp>` block, ≤25 lines:
   - next task id (and why it's next — respect any time-sensitive item first)
   - state summary: phases/tasks DONE, fixtures green, flags off, crons added
   - open risks / things the next leg must know (spec corrections included)
   - parking-lot delta this session
3. End the session with a one-line status. Do NOT attempt "just one more task".

**DONE marker:** when the DEFINITION OF DONE is fully met, append `## DONE` (exactly)
plus the final report to EXECUTION-LOG. The outer loop halts on this marker.

**Session budget guidance:** prefer many clean mid-size legs over heroic long ones.
A leg that ships 2 atomic units with a perfect handoff beats a leg that ships 5 and
leaves ambiguity.

## ENVIRONMENT CARD

Supabase: eizcexopcuoycuosittm (ap-south-1) · impersonation for role-gated RPCs:
set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true)
WH_CENTRAL 4bebef68-9e36-4a5c-9c2c-142f8dbdae85 · WH_MCC 4fcfb52c-271f-4aa7-a373-3495e3271cd3 ·
WH_MM 0aef9ccf-32ad-4545-8413-29bebd931d0b · execute_sql returns LAST statement only ·
docs in boonz-erp/docs/prds/ · FE repo per stax skill · cron 13 = phaseF_stage1_prep_8pm_dubai
(16:00 UTC). Live example of WS-I gap (2026-07-30 01:21): driver bought 8 Zigi at
Carrefour + 1 from WH, entered Filled=9, receive_dispatch_line correctly refused
(WH short) — driver stranded. Fixture 26 encodes this; the guard stays, the happy path
gets built.

## THE LAW (violating any of these is a loop failure)

1. FIXTURE FIRST. No engine change before the fixture that proves it. Incident closed ⇔ fixture exists.
2. TRUTH BEFORE INTELLIGENCE. Phase 1 (WS-A/J) blocks Phase 2+ brain work. No exceptions.
3. PROTOCOL: Dara designs schema · Cody reviews EVERY migration / SECURITY DEFINER / RLS /
   protected-entity touch · Stax owns FE/edge/n8n. Versioned additions only (`*_v3`); no
   destructive change; no raw writes to protected tables; RPCs only.
4. SHADOW, DON'T SWITCH. v3 writes shadow tables; live cutover is a parked flag for CS.
5. Silent qty-0 is a build failure. Every blocked unit lands in blocked_demand.
6. DATA-SOURCE LAW: WEIMI = shelf state (zero-pad A1→A01) · warehouse_inventory aggregated
   by product NAME (NEVER through product_mapping joins) · pod_inventory = expiry history
   ONLY · slot_lifecycle joins by shelf_id ONLY · sourcing from product_sourcing (post-P1.1).
7. EXPIRY IRON RULE: expired stock never exits by assumption — human event only.
8. On golden failure: HALT phase work → bisect → fix → golden.run_all() green → resume.
9. LOG EVERYTHING to PRD-110-EXECUTION-LOG.md (append-only): timestamp, task id, change,
   migration ids, fixture evidence, scoreboard delta, decisions, checkpoint reports.
10. NO SCOPE DRIFT. Out-of-scope temptations → PARKING-LOT, untouched.
11. Runtime Gate 0 is manual-only in wave 1 (CS decision #1). Never add auto-fallback.
12. Never touch live plan tables for dates with non-pending refill_plan_output rows.
    Test on synthetic 2030 plan_dates or shadow tables. Production cron behavior may not
    change except where BUILD SPEC explicitly says so (P0.3), and that change must leave
    the nightly advisory functional the same night.
13. VERIFY, THEN ACT: trust live queries over memory claims, BUILD SPEC over intuition.

## EXECUTION ORDER

```
STEP R  RELAY resume (every session, first): pointer → verify → continue. First leg
        only: proceed to STEP 0.
STEP 0  Setup: create EXECUTION-LOG + PARKING-LOT. Read all docs + skills. Probe every
        environment-card fact live (one query each). Baseline scoreboard queries saved.
STEP 1  Golden harness scaffold + fixtures 2, 3, 10, 26 snapshotted from live state
        BEFORE any fix (failing baselines are the point).
STEP 2  PHASE 0 (P0.1→P0.6 per BUILD SPEC). ✅ CHECKPOINT: verifies green + fixtures
        3/5/10 green + one clean nightly cycle observed → log report, CONTINUE.
STEP 3  PHASE 1: P1.1 (backfill mapping GENERATED, apply parked) → P1.2 shelf_state +
        consumer migration → P1.4 events + estimator (shadow) → P1.3 sentinel retirement
        BUILT + fixture 24 green, deletion parked. ✅ CHECKPOINT → CONTINUE.
STEP 4  PHASE 2: engine_add_pod_v3 (P2.1–P2.6), shadow nightly, WMAPE telemetry.
        ✅ CHECKPOINT (fixtures 2/7/8/14/15) → CONTINUE.
STEP 5  PHASE 3: stitch_v3 ladder → M2M SKU → rotation heartbeat → VAR picker →
        edits-as-events → one pipeline. ✅ CHECKPOINT (fixtures 1/4/11/12/13/25) → CONTINUE.
STEP 6  PHASE 4: feedback ledger + pins → miners → atomic spot-buy + post-facto flow
        (fixtures 18 AND 26) + live-refresh board → scoreboard + Remy pack.
        ✅ CHECKPOINT (fixtures 9/16/17/18/20/23/26) → CONTINUE.
STEP 7  STRESS SUITE (all must pass; failures → fix → rerun):
        S1 full-fleet shadow run, all machines, one date — runtime < 10 min, zero errors;
        S2 estimator soak: 10k synthetic WEIMI deltas incl. anomaly storm (count>capacity,
           negative deltas, venue fills) — composition never negative, expired never
           auto-consumed, confidence bounds hold;
        S3 concurrent edits: 20 parallel plan_edits + engine re-run — zero lost edits;
        S4 pipeline chaos: re-run every engine 3× same date — idempotent, no dup lines;
        S5 spot-buy race: receive + bind concurrent with pack — no double debit;
        S6 blocked_demand volume: 500 open rows — procurement view + aging correct;
        S7 golden.run_all() ×3 consecutive — identical results (no flakiness).
STEP 8  Shadow live-in: v3 nightly shadow on real dates, diff report + scoreboard for
        CS review. Write DONE report: everything built, stress evidence, the
        DECISIONS-READY list with one-line activation asks. STOP.
```

## CHECKPOINT REPORT FORMAT (logged, not asked)

≤15 lines per checkpoint into EXECUTION-LOG: phase · tasks shipped · fixtures green ·
numbers · anomalies+resolutions · parked items added.

## ANTI-PATTERNS (each cost real hours on 2026-07-30)

Computing refill quantities by hand instead of running the engine · reading WH stock
through product_mapping (fan-out) · inferring sourcing from one mapping row · joining
slot_lifecycle by shelf_code · re-running engines over human edits · declaring "no data"
before checking the join path · re-buying what an open PO covers · trusting memory over
a live query · forcing a dispatch state at night instead of the LOG path.

## STANDING INSTRUMENTS

boonz-master-3 = ops law · dara = schema design · cody = migration review · stax =
FE/edge/n8n · weekly-procurement = blocked_demand consumer · context-intelligence =
event calendar · Remy (mint in Phase 4) = weekly L3 review.

# BEGIN. Step 0. Do not stop until DONE or a hard unparkable blocker.
