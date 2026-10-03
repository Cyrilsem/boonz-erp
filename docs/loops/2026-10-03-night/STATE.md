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
