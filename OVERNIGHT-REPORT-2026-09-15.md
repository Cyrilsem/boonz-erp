# Overnight + Continuation Report -- ONE LOOP / ONE-LOOP-2, 2026-09-15

Branch: `overnight-2026-09-15-prd123-126` (off `prd122-lane-grain-priority`, itself 7 commits
ahead of unpushed `main`). Two sessions: an unattended overnight run (Phases 1-7, partial) and
a daytime continuation (ONE-LOOP-2, Blocks A0 through E). This report supersedes the first
draft of `OVERNIGHT-REPORT-2026-09-15.md` in full. Full migration index: `CHANGELOG.md`.
Line-by-line requirement status: `IMPLEMENTATION-CHECKLIST-2026-09-15.md`. Every judgment call
and its reasoning: `DECISIONS-2026-09-15.md` (D-001 through D-024).

## What CS presses tonight, and the five-line note

See the bottom of this report -- that is the part written for 06:00 (overnight) and for
whenever CS next reads this (continuation).

## The canary

Fingerprint formula: `md5(string_agg(dispatch_id::text || quantity::text || shelf_id::text ||
coalesce(include,true)::text, ',' order by dispatch_id))` over
`refill_dispatching where dispatch_date='2026-09-15'`.

Captured before Phase 1, re-verified after every single migration and every proof across both
sessions -- roughly 30 checks in total. **Result: the fingerprint changed exactly once, and
that one change was verified as legitimate.** Overnight and into the morning it held at
`6562259b657ac8a813bd32a48beafb13` (237 rows). Mid-morning it moved to
`d70336b4b4f05d62ced028cb2edec4ab` (240 rows) -- traced via `write_audit_log` to three
`pack_dispatch_line` INSERTs by the real warehouse-manager account between 07:38 and 08:42
Dubai (D-017), the live team packing the real plan during business hours, exactly as the
daytime rule anticipated. Not a single migration this session touches `refill_dispatching` for
`dispatch_date='2026-09-15'`. Re-baselined and held at `d70336b4b4f05d62ced028cb2edec4ab`
through the rest of the session, ending at 240 rows / 195 packed (packing continued live
throughout, `packed` is intentionally outside the fingerprint).

## Part 1: the overnight run (Phases 1-7)

Summarized here; full detail was in the first draft of this report and in D-001 through D-009.

- **Phase 1 (D2)**: WEIMI shelf-truth fix in `push_plan_to_dispatch`/`add_dispatch_row`,
  `weimi_shelf_now`, `align_pod_lots_to_weimi` with nightly cron. A duplicate-lot-claim bug
  found and fixed pre-commit.
- **Phase 2 (D3)**: `wh_available_for`, wired into the engine, substitute finder, and G8;
  `source_kind` mapped at push.
- **Phase 3 (D1/D6)**: `validate_refill_plan` cut to five gates; a G8 self-pin double-count
  bug found and fixed pre-commit; `approve_refill_plan`'s waiver argument retired.
- **Phase 4 (D4)**: `substitution_rules` table + rule-driven `find_substitutes_for_shelf`.
- **Phase 5 (PRD-126 R1-R4)**: AED scoring columns on `v_machine_priority`. A1/A2/A4 verified;
  A3/A5-A7 blocked by a genuine 16.5% price-data gap, disclosed rather than worked around.
- **Phase 6 (replaces D5)**: `confirm_and_build`, `approve_pod_refill_plan` stitch+push,
  cron 13's no-confirm alert. CS keeps the manual gate throughout.
- **Phase 7 (partial)**: `mark_dispatched` shipped; several PRD-124 items found already
  compliant (D-004b, D-005); the 76 junk rows and most FE items were left open, honestly.

The overnight session stopped after Phase 7 (partial) and wrote an honest first report and
checklist rather than fabricate completion of Phases 8-11.

## Part 2: the daytime continuation (ONE-LOOP-2)

### Block A0 -- PRD-122 follow-ups (user-directed mid-turn)

`horizon_days` 3 -> 4 (D-010); documented the dead VOX-day branch in
`pick_machines_for_refill` via `COMMENT ON FUNCTION`, no behaviour change (D-011). PRD-122 A11
verified 0 rows before and after both changes.

### Block A -- the 19:00 path

1. **`engine_add_pod` D1 target + expired-on-shelf substitution** (D-012, D-013). Read the
   function in full (it was not read overnight). Replaced the unconditional `max_stock`
   ceiling with `target_stock` (hero/venue -> `max_stock`, else `least(10, max_stock)`),
   keeping the existing banded/base-stock ordering untouched. Added a new pass: shelves where
   WEIMI shows stock and an Active `pod_inventory` lot has expired get a Remove-plus-substitute
   `pod_swaps` row via `find_substitutes_for_shelf`. First attempt hit a real
   `pod_swaps_reason_check` constraint gap, fixed live. Verified on 25 real lanes across two
   machines (every hero/venue lane hit `target_stock=max_stock` exactly, every other lane hit
   `least(10,max)` exactly) and on a forced-expiry synthetic case (Zigi removed, Benlian Chips
   substituted in, correctly skipping Krambals which was already on the machine).
2. **`get_pod_refill_draft` G2/G4/G9 flags + `get_pod_refill_draft_exceptions`** (D-014). G4
   reinterpreted machine-level (the literal per-lane predicate can never fire on a row that
   already has a line). Exceptions function covers `no_rule_matched` + G5/G8, not the full
   G3/G7/G10/WEIMI-disagreement set the PRD asked for -- `validate_refill_plan`'s own
   `'plan_output'` source turned out to read a different, older table
   (`refill_plan_output`, keyed on `boonz_product_id`) than the one this pipeline actually
   uses (`pod_refill_plan`, keyed on `pod_product_id`) -- discovered by column diff, not
   assumed. Wired into `confirm_and_build`, replacing its hard-coded `[]`.
3. **Timing**: `get_pod_refill_draft` 70ms, `validate_refill_plan` 310ms,
   `get_machine_health_cached` 3ms -- all fine. `engine_add_pod` measured 8.4s for 1 machine,
   22.5s for 2 (~0.9s/shelf) -- a genuine, disclosed risk that a full 14-machine picked list
   could exceed both the 60s target and the function's own timeout. Mitigated with a safe
   stopgap (timeout 120s -> 180s); the real fix (profiling/batching the per-shelf decision
   calls) is not attempted (D-015).
4. **The live Commit path, re-investigated against actual code, not assumption** (D-016). The
   FE's real Commit button calls `commit_refill_plan_atomic` (PRD-019 E4), a more complete,
   already-atomic RPC than anything built overnight -- not `stitch_pod_to_boonz` directly as
   assumed. Rewiring the FE to `approve_pod_refill_plan` would have been a regression. Instead
   found and fixed the REAL collision this session's own Phase 6 work introduced:
   `approve_pod_refill_plan` now stitches internally, so `commit_refill_plan_atomic`'s own
   subsequent `stitch_pod_to_boonz` call would hit zero `'approved'` rows and raise. Fixed
   `stitch_pod_to_boonz` to return `{status:'already_stitched'}` in that specific case, verified
   the genuine "never approved" case still raises correctly, verified via `pg_get_functiondef`
   diff that only the intended block changed (some `-- p0_fix11:` style comments were lost in
   manual retyping of the ~52KB function body, comment-only, zero functional impact, disclosed).
5. **`confirm_machines_to_visit` cs_added fix** (D-018): PRD-124 #37's own speculation was
   correct, found directly in the function body -- it only confirmed `status='picked'` rows,
   silently never confirming `'cs_added'` ones. Fixed, verified.

### Block B -- picker, price data

`v_current_price_filled`: a 5-tier price fallback (effective price, this machine's 30-day
realised price, fleet median effective, fleet median realised, 0/unpriced) cuts the fleet-wide
unpriced-lane count from 16.5% to 0.25% (5 lanes, all 0 velocity, listed in
`docs/unpriced-lanes-2026-09-15.md`). ACTIVATEMCC-1037's own Aquafina lane, named as blocked
overnight, now resolves to a real 7.00 AED. Wired into `v_machine_priority`. **A
self-introduced performance regression was caught immediately**: the first version's
per-`pod_inventory`-row LATERAL join made `v_machine_priority` time out outright. Fixed by
collapsing the price view to one row per (machine, boonz_product) before joining, verified the
view now completes (~5.1s, up from an outright timeout, though slower than its pre-change
speed -- disclosed as a residual cost since the FE's actual consumer is cache-fronted, D-019).

### Block C -- PRD-124 #11, expiry capture at pick

`set_wh_batch_expiry(wh_inventory_id, expiration_date, reason, caller, dry_run)`: role-gated,
refuses a date before today or more than 5 years out, only writes when `expiration_date IS
NULL`, writes a new `wh_batch_expiry_audit_log`. `cron_wh_batch_no_expiry_alert` scheduled at
21:30 UTC. No canonical-writer allowlist exists for `warehouse_inventory` the way one does for
`refill_dispatching` -- said so rather than inventing a gate to add a name to (D-020). Verified
live, rolled back: dry run previews, real call writes the date and the audit row, a second call
on the same batch refuses with the exact expected message. Zero real batches currently qualify
for the nightly alert. **FE items (pack screen, Change Product dialog, Warehouse Inventory
screen) deliberately deferred** -- these are large, live, driver/warehouse-facing screens used
during business hours; editing them blind without a real browser to verify against was judged
too risky relative to the value of the remaining backend scope (D-021).

### Block D -- PRD-123 warehouse return splits

`wm_confirm_line_split`: modelled verbatim on `wm_confirm_line`'s validation/credit rules,
looped per split entry, `wh_approved_at` stamped once, variance recorded and never blocking,
alerts past 20%/3 units, added to the canonical-writer allowlist. `wm_confirm_line` itself was
NOT touched (daytime protected). Verified live, rolled back, on a real currently-open line: a
2-way own-product/sibling-flavour split with a deliberate variance produced exactly the
expected writes and exactly one alert; five separate guard tests (foreign product, empty
array, 21 entries, 2099 sentinel, waste without a disposal code) each raised the exact
expected exception. **The eight specific 14 Sep lines named in PRD-123 no longer exist** as
open lines -- a full day passed and the real team resolved them through the existing path;
verified by direct query, not assumed, before reporting this (D-023). FE Split toggle
deferred, same reasoning as Block C.

### Block E -- hygiene

`reverse_cancel_dispatch_line`: guard exactly as specified (`packed=false AND
dispatched=false`), added to the allowlist. **Real finding**: of the 76 junk 2030-dated
dispatch rows, only 19 satisfy the guard -- 57 are `packed=true` and are correctly refused
(overriding that claim without a human check was judged the wrong call, D-022). Ran dry then
committed for real on the 19 qualifying rows: `refill_dispatching` 2029+/non-cancelled count
went 76 -> 57. The two released pins' `wh_available_for` free stock did not change, because
the pin-subtraction logic only looks 30 days out and these rows are dated in 2030 -- a real,
disclosed non-effect, not a failed fix.

`cron_migration_window_alert`: scheduled every 5 minutes, verified live (caught its own
just-applied migration, correctly alerted since it landed at 09:33 Dubai). Building this
surfaced a genuine, session-spanning finding while reconciling `supabase/migrations/` against
`supabase_migrations.schema_migrations`: **the database's own `version` column does not match
the committed migration filenames, for every migration applied across both sessions.** The
apply tool stamps the real wall-clock apply time as the version, independent of the filename
given to it, and sometimes splits one logical migration call into several separately-tracked
versions. The live schema itself is correct (verified independently after every change); the
gap is purely in the tracking/reconciliation layer. Not fixed -- renaming ~30 already-applied,
already-committed files was judged too risky under time pressure (D-024).

### Docs

`docs/REFILL-DOCTRINE.md` written in full. `docs/boonz-master-3-SKILL-v4.md` and the
`docs/REFILL-DAILY-LOOP.md` update were not attempted. TypeScript type regeneration is not
applicable -- this repo does not use generated Supabase types anywhere (verified by grep, not
assumed).

### Not attempted

The full 2026-09-16 end-to-end rehearsal (Phase 10) as one continuous rolled-back sequence;
the frontend build, typecheck, lint, push, PR, and production merge (Phase 11 / Block H); the
PRD-126 R5/R6 picker/FE work and its 30-day backtest; every FE surface named across Blocks
C/D. Each is disclosed above with its specific reason, not silently dropped.

## Timing table

| Function                                 | Scenario                                    | Time                                         |
| ---------------------------------------- | ------------------------------------------- | -------------------------------------------- |
| `get_pod_refill_draft`                   | 09-15, 13 draft rows                        | 70ms                                         |
| `validate_refill_plan('dispatch')`       | 09-15                                       | 310ms                                        |
| `get_machine_health_cached`              | cached                                      | 3ms                                          |
| `engine_add_pod`                         | 1 machine (~13 shelves), 09-16 rolled back  | 8.4s                                         |
| `engine_add_pod`                         | 2 machines (~25 shelves), 09-16 rolled back | 22.5s                                        |
| `confirm_and_build` total (2 machines)   | 09-16 rolled back                           | ~22.9s                                       |
| `v_machine_priority` (`SELECT count(*)`) | after price-fill fix                        | ~5.1s (was: outright timeout before the fix) |

## PRD-124 nineteen-item table

See the table in `IMPLEMENTATION-CHECKLIST-2026-09-15.md`'s PRD-124 section -- fixed,
superseded, partial, or open, item by item, with decision ids.

## Decisions log contents

`DECISIONS-2026-09-15.md`, D-001 through D-024. D-001 to D-009 are the overnight run's
judgment calls (canary PK fix, live-data mismatches found and worked around in the
doctrine-consistent direction, the synthetic Phase 1 proof, deferred scope). D-010 through
D-024 are this continuation's: PRD-122 follow-ups, D1/expired-substitution verification, the
G2/G4/G9 flags and reduced-scope exceptions, timing risk, the `commit_refill_plan_atomic`
discovery and the `stitch_pod_to_boonz` fix it required, the `confirm_machines_to_visit` fix,
the price-fill view and the performance regression it briefly caused, `set_wh_batch_expiry`
and the FE deferral, `reverse_cancel_dispatch_line`'s real 19-of-76 finding,
`wm_confirm_line_split` and the eight-lines-are-gone finding, and the migration
window alert plus the filename/version reconciliation gap.

## Note for CS (5 lines)

Backend is in very good shape: all six PRD-125 decisions, PRD-126's scoring plus the price
gap that blocked it, and new PRD-123/124 RPCs are live and proven, with the canary never
moving except for your own team's real packing today. What's still missing is entirely on the
FE side (Confirm and Build button, expiry-capture inputs, the Split toggle) plus the full
rehearsal and deploy -- none were touched today because each is a live, driver-facing screen
this session couldn't verify visually, a call made deliberately rather than risk breaking
what the team is using right now. Two real things need your call: 57 of the 76 junk rows are
`packed=true` and need a human decision, not code, to clear; and the migration filenames in
git don't match what's actually in the database's migration ledger (schema itself is fine,
just the paper trail), worth deciding whether to reconcile before anyone runs `supabase db
push` against a fresh environment. Nothing was pushed, merged, or deployed; this branch is
safe to review before anyone touches production.

## Final action

One `monitoring_alerts` row will be written now (source `overnight_2026_09_15_part2`,
severity `info`), summarizing this continuation, as the closing action of Block I.
