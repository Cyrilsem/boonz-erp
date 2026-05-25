---
id: PRD-011-refill-pipeline
program: PROGRAM-2026-05-25
title: Packing FE — re-pin WH batch, no-stock override, edit-during-pack
status: Blocked
blocked_summary: Autonomous apply blocked — needs Cody review of new repair_unbound_dispatch RPC + Stax review of packing FE drawer extension. Spec complete; root cause verified. Daylight CS to invoke Cody/Stax Skills and ship.
severity: P0
reported: 2026-05-25
source: PROGRAM-2026-05-25 Phase 1 P0 #1 (semantic name PRD-003-refill-pipeline)
routing:
  [
    Dara (no schema change),
    Cody (no new RPC needed for the minimum),
    Stax (FE diff),
  ]
---

## Problem

Verified live 2026-05-25 — `refill_dispatching` rows for NOVO-1023 22-May Pepsi
Black (4u, dispatch_id `9c2ccac4-...`) and Pepsi Regular (3u, `dbf2c649-...`)
have `from_wh_inventory_id=NULL` AND `expiry_date=NULL` despite
`packed=true / dispatched=true / picked_up=true`. The packing FE then can't
render expiry or commit the WH debit cleanly.

Root cause (per program-doc V1 finding): the WH-decouple migration
(memory entry `project_engine_v10_stitch_v12_decouple`) intentionally stopped
the stitch step from pre-pinning a specific WH batch. Pack-time should be
where the pinning happens via `pack_dispatch_line`, but rows ended up with
`packed=true` while their `from_wh_inventory_id` is still NULL — meaning
`pack_dispatch_line` was bypassed. The same anonymous-UPDATE pattern flagged
in Phase G P4 A.8 audit (M2M flip) is the suspected mechanism.

## Acceptance criteria

1. **Visible symptom fixed:** The packing FE renders a usable picker for any
   dispatch row where `line.expiry_date IS NULL` AND there is live WH stock
   for the product. The picker FEFO-orders the available batches and pack
   via the canonical `pack_dispatch_line` RPC binds `from_wh_inventory_id`
   AND `expiry_date` correctly on the row.

2. **Hard-block bypass at the RPC layer:** No new direct-UPDATE writer on
   `refill_dispatching.packed`. This is enforced today by RLS + the audit
   trigger; the audit (A.8) finding is the open question of who is
   bypassing, not whether the RPC works. Pinned in the carve-out follow-up
   (CARVEOUT_A7).

3. **Edit-during-pack:** The packing FE allows qty + expiry override on a
   dispatch line before the user confirms the pack. The override flows
   through `pack_dispatch_line` (already supports `wh_inventory_id` per pick
   and arbitrary qty per pick).

4. **"Mark as packed (manual)" affordance:** When stitch couldn't bind a
   batch (NULL `from_wh_inventory_id`) AND the line is `packed=true`, surface
   a "Re-pin this row" button visible to WH manager / operator_admin /
   superadmin that calls a new repair RPC (see below).

## Proposed solution

### Backend (one new repair RPC)

`repair_unbound_dispatch(p_dispatch_id uuid, p_wh_inventory_id uuid, p_reason text)`
SECURITY DEFINER:

- Validates caller role (warehouse / operator_admin / superadmin / manager).
- Refuses if `p_dispatch_id` is not `packed=true` (the row is fine for
  normal pack_dispatch_line; repair is only for the post-hoc fix-up case).
- Refuses if `from_wh_inventory_id` is already non-NULL (no
  retro-rewrite of an already-bound row — that's a different operation
  guarded by per-row CS sign-off).
- Looks up `warehouse_inventory` row by `p_wh_inventory_id` FOR UPDATE,
  verifies `boonz_product_id` matches the dispatch row, verifies
  `warehouse_stock >= quantity`.
- Sets `app.via_rpc / app.rpc_name / app.provenance_reason='dispatch_pack' / app.mutation_reason=p_reason`.
- Decrements `warehouse_stock` by `quantity`, increments `consumer_stock` by
  same.
- Updates dispatch row: `from_wh_inventory_id = p_wh_inventory_id`,
  `expiry_date = wh_row.expiration_date`.
- Returns jsonb summary.

Note: this is a **canonical writer** that follows Article 1/3/4/6/8 — Cody
review required before apply. Migration name candidate:
`phaseG_followup_repair_unbound_dispatch`.

### FE (single drawer extension on packing page)

`src/app/(field)/field/packing/[machineId]/page.tsx`:

1. When rendering a line whose `expiry_date IS NULL` AND batchMap has
   entries for the product, surface a "Manual batch selection" section
   showing the FEFO-ordered batches with click-to-bind affordance.
2. When the line is `packed=true` AND `from_wh_inventory_id IS NULL`,
   surface a yellow "Stitch did not bind this row" chip with a
   "Re-pin this row" button that opens a confirm dialog calling
   `repair_unbound_dispatch`.
3. Add an inline "Edit qty / expiry" affordance available to WH manager
   role on un-packed lines that uses `pack_dispatch_line` with the chosen
   wh_inventory_id and the override qty.

## Out of scope (deferred to follow-up)

- **Backend re-pin at publish time** (have stitch do the binding before any
  dispatch row is INSERTed). This is the deeper fix but requires
  Cody review of the entire stitch path and could destabilize Engine v11.
  Tracked separately. The repair RPC above + FE fallback closes the
  user-visible bug without that.

## Verification

- Smoke: dispatch NULL-binding case — for the two NOVO Pepsi rows,
  WH manager opens the packing FE, sees the yellow chip, clicks "Re-pin",
  binds to a live batch, confirms — verify `from_wh_inventory_id` and
  `expiry_date` are now set, and `warehouse_inventory.warehouse_stock` /
  `consumer_stock` adjusted by the qty.
- `npx tsc --noEmit` / `npm run build` clean.
- `inventory_audit_log` row written via the trigger chain.

## Rollback

- Drop the new repair RPC: `DROP FUNCTION repair_unbound_dispatch(uuid,uuid,text);`
- Revert the FE PR.

## Linked

- [[project_engine_v10_stitch_v12_decouple]] — the WH-decouple work whose
  side effects this PRD addresses.
- [[CARVEOUT_A7]] — the hard-block direct UPDATE that would have prevented
  the anonymous-flip pattern (still pending).
- A.8 M2M flow audit — same anonymous-UPDATE class.
