# PRD-CLEAN-06 — One canonical dispatch state (v_dispatch_state)

Status: DONE (2026-07-11) — v_dispatch_state live: 8-status precedence grounded in the
combo census (returned lifted above cancelled/skipped: 7 physical-return rows),
effective_qty coalesce, single source lineage. 35,143 rows reconcile exactly vs raw
booleans, 0 NULL statuses. Consumer repoint skipped: no Gate-2 coverage check exists
(stale claim) and no monitor derivation is behavior-identical; FE follow-up out of scope.
Priority: P2 (read-path sanity; no column drops in this PRD)

## Problem

refill_dispatching has 68 columns encoding ≥4 overlapping state machines:
legacy booleans (include, dispatched, packed, picked_up, returned, item_added,
cancelled, skipped), driver_confirmed__, driver_outcome__, pack_outcome,
needs_review/review__, bind_fail__. Quantity exists in 5 shapes. Every consumer
re-derives "what state is this row in" differently.

## Design

CREATE VIEW public.v_dispatch_state AS one row per dispatch_id with:

- status (single text enum), resolved by strict precedence:
  cancelled → 'cancelled'
  skipped → 'skipped'
  returned → 'returned'
  driver_outcome IS NOT NULL OR dispatched → 'completed'
  picked_up → 'in_field'
  packed → 'packed'
  needs_review AND review_status IS DISTINCT FROM 'resolved' → 'review'
  ELSE 'pending'
- effective_qty = COALESCE(driver_outcome_qty, driver_confirmed_qty,
  filled_quantity, quantity)
- planned_qty = quantity, original_qty = original_quantity
- source (single text): derive one lineage value from
  source_origin/source_kind/is_m2m/from_machine_id/from_warehouse_id.
- Pass through: machine_id, shelf_id, pod_product_id, boonz_product_id,
  dispatch_date, action, expiry_date.

Before finalizing precedence: sample real rows for contradictory combinations
(e.g. cancelled AND driver_outcome set) — count each combo, encode the
precedence that matches operational truth, log combos found in DECISIONS.md.

## Consumers (this PRD)

- Repoint the post-Gate-2 dispatch coverage check and any monitoring/cron
  function that re-derives state (grep function bodies for 'packed = true' etc.)
  ONLY where behaviour-identical. FE migration to the view = follow-up, out of
  scope here.

## Verification battery

1. For today's + yesterday's dispatch dates: every row maps to exactly one
   status, zero rows fall through to NULL.
2. Row counts per status vs raw boolean queries reconcile (write the
   reconciliation query in DECISIONS.md).
3. No write behaviour changed anywhere.
