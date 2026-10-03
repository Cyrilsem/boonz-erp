# ONE-SHOT FIX BATCH, 2026-10-03, run state

Five scoped fixes. Surgical only: no refactors, no new overloads, canonical RPCs only, never
override the packed-row guard. Field-app / warehouse-confirmation function migrations apply only
22:00-06:00 Dubai. Cody review on every SECURITY DEFINER change. Commit every migration to main.

Started 21:17 Dubai (pre-window). Investigating all 5 fixes in parallel before drafting.

## Fixes

1. Pack screen FEFO ignores sibling rows (wrong expiries into pod_inventory). Field-app function,
   night window.
2. Split by expiry on warehouse returns review. Warehouse-confirmation function, night window.
3. Slot guard per-machine override (assert_weimi_slot_match). Plan-validation pipeline, pending
   classification.
4. G8 venue_team stock check hardcoded warehouse list. Plan-validation pipeline.
5. Empty-lane relabel deadlock (V8 vs G10). Plan-validation pipeline, write_refill_plan V8 stays
   unchanged.

## Status (updated)

- FIX 3: DONE. Applied `20261003172747_fix3_weimi_slot_guard_per_machine.sql`. Cody ✅. Verified
  live on MOE (override 'warn' beats global 'block') vs AMZ-1038 (no override, still blocks).
  Committed to main (9921d0c) with FIX 4/5.
- FIX 4: DONE. Applied `20261003180518_fix4_g8_venue_team_warehouse.sql`. Cody ✅. Verified
  rolled-back against real MOE/Aqua Panna data, isolated from the pre-existing WH_MCC 999-unit
  sentinel (batch_ids VOXSOURCE-WH_MCC-AQUAPANNA-999/-REDBULL-999/-REDBULLDIET-999 -- follow-up:
  move these to WH_MOE via the canonical transfer/adjust RPC, then re-validate 2026-10-04).
  Committed to main.
- FIX 5: DONE. Applied `20261003183304_fix5_g10_empty_lane_relabel.sql`. Cody ✅. Verified live on
  real MOE shelves A02 (0-stock, passes) vs A06 (stocked, still blocks). Committed to main.
- FIX 1: DONE (pure FE, no migration). Root cause was narrower than "the FIFO suggestion logic
  has no netting at all" -- Step 4 of `fetchData()` already decremented a shared `batchPool` across
  sibling lines, but (a) sorted by `dispatch_id` (an arbitrary UUID) instead of shelf_code, (b)
  never skipped already-packed lines so it double-subtracted their already-physically-decremented
  stock, and (c) its correctly-netted output (`fifoMap`/`allocations`) was never actually wired
  into the Pick Qty auto-fill -- that instead came from `fillBatches()`, which reads each batch's
  raw un-decremented `stock` per line independently, so every sibling line suggested the identical
  earliest batch regardless of Step 4's work. Fix: sort Step 4 by shelf_code (dispatch_id
  tiebreaker), skip DB-already-packed lines in that pass, and wire the Pick Qty default straight
  from each line's own `allocations` instead of re-running `fillBatches` against raw stock (venue
  -sourced synthetic batches excepted, they keep the old direct fill by design). "In Stock" display
  also corrected via a new `siblingCommittedByBatch` map merged into the existing `committedForBatch`
  helper (single funnel, all 8 render call sites updated), and the post-fill "top-up" pass gained
  the same sibling-aware subtraction so it can't silently re-add stock a sibling already took.
  `npx tsc --noEmit` clean; `eslint` on the file shows only the pre-existing unrelated
  `react-hooks/set-state-in-effect` warning (confirmed present before this change too, via
  `git stash`). Manually traced against the task's stated repro structure (FEFO stable order,
  shared decrement) -- matches exactly once A01/A02's own unstated dispatch quantities are
  back-solved from the stated expected split. Live 2026-10-04 ACTIVATEMOE-2007-0000-B0 data has
  drifted far from the original clean two-row-per-shelf repro (many more historical test rows
  accumulated on A07 etc. across prior sessions), so a live browser walkthrough against the exact
  original numbers was not possible -- this is a pre-existing data-staleness condition, already
  flagged by Fork 1 earlier this session, not something this fix needed to correct.
- FIX 2: in progress. Inside the 22:00-06:00 Dubai window -- building and applying tonight.
