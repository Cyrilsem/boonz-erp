-- PRD-120 follow-up G2: guard against negative refill_dispatching.quantity recurring,
-- without touching the 2,272 historical negative-quantity rows found last session (all
-- legacy pre-migration-era data, all either cancelled or already dispatched, zero live).
--
-- Task asked literally for CHECK (quantity > 0). Dara flagged this as too strict: 134
-- existing rows have quantity = 0 legitimately (74 Remove legs), including two live
-- canonical writers (push_plan_to_dispatch, add_dispatch_row) that deliberately INSERT
-- quantity=0 "[NO LOT ON SHELF -- nothing to remove here]" fallback legs, plus operator
-- "WIND DOWN" placeholder Remove lines. NOT VALID only grandfathers EXISTING rows -- it
-- does not exempt new inserts/updates, so a literal `> 0` constraint would have started
-- rejecting those two live write paths on their very next call.
--
-- Fix: CHECK (quantity >= 0) instead -- blocks only the real bug class (negative), leaves
-- legitimate zero-quantity rows alone. Constraint renamed chk_dispatch_qty_nonnegative to
-- match (a name that says "positive" on a column that legitimately holds 0 is a landmine).
--
-- Cody: approve. Articles 1 (not a write path, no writer affected), 12 (forward-only
-- ADD CONSTRAINT ... NOT VALID, does not validate or touch the 2,272 historical rows).

ALTER TABLE public.refill_dispatching
  ADD CONSTRAINT chk_dispatch_qty_nonnegative CHECK (quantity >= 0) NOT VALID;
