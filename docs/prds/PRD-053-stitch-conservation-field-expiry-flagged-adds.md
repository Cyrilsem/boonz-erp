# PRD-053 - Stitch conservation, field per-expiry split, flagged additions

Three rules:

1. **NO LEAKAGE** - after stitch, the boonz lines for a pod instruction must sum to the original pod qty, always. A publish-time check refuses any non-conserving stitch.
2. The driver can **split a line across real expiry dates** with the TOTAL LOCKED to plan.
3. The driver can **ADD beyond plan** but every addition is FLAGGED for Head Office (CS) review, never silently changing the books.

**Status:** Shipped - COMPLETE (Phase A applied 2026-06-24: stitch v28 + push conservation verified live in prod 2026-07-02; FE B/C shipped to prod db21023, on main; driver_add_flagged_row live and wired in main FE). PRD-071 sweep 2026-07-02; salvage branch deleted after coverage proof. **STOPPED for CS review** before apply. Phases B + C pending.

## Root cause (verified 2026-06-23, VML-1004-0500-O1 shelf A03 Ice Tea)

`pod_refill_plan` REMOVE = 13 (correct, = live WEIMI shelf). `refill_dispatching` REMOVE summed to 6. `stitch_pod_to_boonz` sized the boonz REMOVE child from `v_pod_inventory_latest.current_stock` via `... ELSE LEAST( (FEFO distribution), current_stock )::int ...`, so 13 → `LEAST(13, 6 Active)` = 6; **7 leaked**. Single-variant (Ice Tea → 100% Ice Tea - Peach), so not a flavor split and not the engine qty-guard.

## Phase A - conservation invariant (migration `20260624000000_prd053_a_stitch_conservation.sql`)

1. `stitch_leakage` telemetry table (append-only, RLS, instruction + delta).
2. `check_pod_conservation(date)` read-only: per REMOVE/M2W instruction, parent pod qty vs SUM(dispatch children); returns the non-conserving rows.
3. `stitch_pod_to_boonz` surgical patch (DO-block over the live body; guard RAISEs if the target drifts): **drop the `LEAST(..., current_stock)` cap** on the REMOVE child so it sizes from the pod plan total. `engine_version` v26 → v27_remove_conservation.
4. `push_plan_to_dispatch(date,text)`: REMOVE/M2W children are **split across the shelf's known Active pod_inventory batches by FEFO**; any remainder not attributable to a known batch is written as ONE more line with `expiry_date = NULL` (expiry-to-confirm) so the children always sum to the plan. A **publish-time conservation assert** then refuses to ship (RAISE → full rollback) when SUM(children) ≠ parent for any REMOVE/M2W instruction, and logs the delta.

See `PRD-053-EXECUTION-LOG.md` for the per-AC verification.

## Phase B - field per-expiry edit (total locked) — PENDING

Canonical RPC sets a per-expiry breakdown on a dispatch line (reuse the `p_batch_breakdown` shape `receive_dispatch_line` takes), enforcing SUM(rows) = line total; total immutable, only the expiry distribution changes. Stax wires it onto the driver dispatching/packing line.

## Phase C - flagged additions to Head Office — PENDING

Extend the add path to stamp `needs_review=true` / `review_reason='driver_addition'` on driver additions beyond plan; never block. Stax surfaces a Head Office review queue.
