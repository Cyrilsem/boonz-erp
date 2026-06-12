# PRD-028 WS3 - WH pickable + dispatch availability design note (Dara)

**Date:** 2026-06-12 · **Status:** Proposed, pending Cody review · **Driver:** METRICS_REGISTRY.md rows "WH pickable stock" + "Dispatch committed / available"

## Current state (measured 2026-06-12)

1. **No `v_wh_pickable` exists.** The pickable predicate (Active, not quarantined, in-date) lives inline in two places:
   - `v_dispatch_availability.wh_avail` CTE (DB)
   - packing FE batch fetch (`warehouse_inventory ... .eq("status","Active")`) - which MISSES `quarantined=false` and the in-date rule entirely (quarantined-but-Active and expired-but-Active batches leak into the pick pool).
2. **`v_dispatch_availability` exists but has ZERO consumers** (no FE refs, no RPC refs) - built, never wired. Its definition is close to the registry rule: wh_avail = Active + not-quarantined + in-date + serving warehouses (primary/secondary) + reservation-aware; commitments (`reserved_by_earlier`) = earlier same-product same-date lines with `packed = false`, warehouse-origin Refill/Add New.
3. **The packing FE double-counts commitments**: pack PHYSICALLY DEBITS `warehouse_inventory` (the page has a restore-on-skip helper proving it), yet `committedByProduct` counts `packed=true, dispatched=false` lines of other machines - stock that was already debited from the WH rows. Result: WH (post-debit) minus packed-again = the "Available: 0" bug class. The on-screen copy even documents the wrong assumption ("even though WH still physically holds it").

## Design

### 1. `v_wh_pickable` (NEW, canonical batch-grain pickable stock)

`warehouse_inventory` WHERE `status='Active' AND NOT COALESCE(quarantined,false) AND (expiration_date >= dubai_today OR expiration_date IS NULL) AND warehouse_stock > 0`.
Exposes wh_inventory_id, boonz_product_id, warehouse_id, wh_location, batch_id, warehouse_stock, expiration_date, reserved_for_machine_id, snapshot_date.

- `WITH (security_invoker = true)`: consumers (field PWA) already pass `warehouse_inventory` RLS; the view must not widen access through owner privileges. New view, no legacy consumers to break.
- Machine-agnostic by design: serving-warehouse scoping and reservation logic are MACHINE-scoped concerns and live in `v_dispatch_availability` (which consumes this view).
- Dubai operational date, consistent with WS1/WS2.

### 2. `v_dispatch_availability` (REPLACE - consume the canonical predicate)

- `wh_avail` CTE now joins `v_wh_pickable` (predicate deleted inline) + keeps serving-warehouse + reservation filters.
- Commitment condition gains `AND rd.picked_up = false` (registry rule: commitments = unpacked + unpicked, current dispatch_date only - the per-date window partition already scopes by date).
- Output columns unchanged. Zero consumers today, so zero blast radius; packing FE wiring starts here.

### 3. Packing FE (`src/app/(field)/field/packing/[machineId]/page.tsx`)

- Batch fetch: `warehouse_inventory` -> `v_wh_pickable` (same column names; drops the now-redundant `.eq("status","Active")`). Quarantined + expired batches stop leaking into the pick pool and the WH badge.
- Committed fetch: `packed=true, dispatched=false` -> `packed=false, picked_up=false` (claimed-but-not-yet-debited). Kills the double-count permanently: packed lines are already debited from WH stock and must not be subtracted again.
- Available badge: product-grain `max(0, WH - Committed)` (`lineAvailable` clamped) instead of the per-batch sum, matching the registry definition `available = pickable - commitments`. Per-batch pick CAPS keep their per-batch clamping (B3.1 Issue 7 behavior preserved for picking).
- "Reserved to" copy updated to describe claims (planned, unpacked) instead of the wrong "packed but still physically present" story.
- Page already uses `getDubaiDate()` for dispatch_date - consistent.

## AC note

The PRD AC ("Sunblast Apple WH_CENTRAL renders 5 | 0 | 5") encoded the 2026-06-11 stock state. Live 2026-06-12: Sun Blast - Apple has WH_CENTRAL rows that are ALL Expired/quarantined/Inactive or zero-stock (pickable 0 there) and two Active WH_MCC batches (5+5). The invariant the AC tests is: WH badge = sum(v_wh_pickable) for the machine's allowed warehouses; Committed counts only unpacked+unpicked claims (a fully packed-elsewhere product shows Committed 0, not WH-minus-packed=0 Available); Available = WH - Committed. Verified live post-apply with the current equivalent case (see execution record).

## Before/after

- `v_dispatch_availability`: diffed pre/post for the current plan date (see execution record; expected changes only where packed-but-unpicked lines previously counted as commitments).
- Packing FE WH badge: drops quarantined/expired Active batches (today: e.g. WH_CENTRAL quarantined Inactive Sun Blast rows were already excluded by the Active filter; the leak class is quarantined-or-expired-but-Active rows).
- Packing FE Available: rises wherever other machines had packed (already-debited) lines today.

## Execution record (2026-06-12)

- Cody verdict: ✅ approve (Articles 2, 3, 12, 14). Separate pre-existing finding flagged, NOT fixed here (scope rule): the packing page's restore helper writes `warehouse_inventory` (incl. `status`) directly from FE - Article 3/6 violation predating WS3; ticket to Stax/Phase B.
- Applied to prod as `prd028_ws3_wh_pickable_dispatch_availability` (version `20260612070658`; repo file matches).
- `v_wh_pickable` live: 139 pickable batches of 167 Active-stock batches; 28 leak-class rows (quarantined or expired but Active) now excluded - the Simran bug class, quantified.
- `v_dispatch_availability` before/after distribution for dispatch_date >= 2026-06-11: IDENTICAL (no packed-but-unpicked same-date interference in current data) - the redefinition is value-stable today and structural for the bug class.
- FE: batch fetch -> `v_wh_pickable`; committed fetch -> `packed=false AND picked_up=false AND dispatched=false`; Available badge -> product-grain `max(0, WH - Committed)`; reserved-to copy corrected. `npx tsc --noEmit` clean; `npm run build` green.
- AC (numbers were stale, see AC note): live Sun Blast - Apple check post-change: WH_MCC pickable 10 (2 batches x5), WH_CENTRAL pickable 0 (all rows Expired/quarantined/Inactive/zero) - badge chain now reads canonical pickable and commitments without double-count; a product fully packed by another machine renders Committed 0 (was: WH-minus-packed, the 5|5|0 class).
- Note: the WS3 commit also carries the uncommitted "WS7 reserved-to" display (reservedMachinesByProduct + machines(official_name) embed) found in the working tree from a concurrent session - entangled in the same hunks, builds green, attributed in the commit message.
