---
id: PROGRAM-2026-06-02
parent: PROGRAM-2026-05-30
title: Pod recount flow + cleanup primitives (structural fix for 30-May pain)
status: Ready-for-design
severity: P1
opened: 2026-05-30
target_design_complete: 2026-06-02
target_ship: 2026-06-09 (week of)
source: 30-May pod recount loop. We applied 29 of ~80 doc lines mechanically. The remaining 50 needed Claude to bridge plain-prose "Simran physically counted X" to a 7-parameter RPC call per line, with 4 sources of shelf truth that drift apart and 7 dispatch flags that have no single "closed" state. The recount took 6 hours of back-and-forth instead of 30 minutes because the schema is happy-path-only.
---

## Problem statement (one paragraph)

Operator-driven inventory recounts (HUAWEI-2003 + MC-2004, 30 May) take all day because the bridge between physical recount and system state is built ad-hoc each time. There is no recount verb in the canonical RPC layer, no force-close verb for legacy cleanup, and pod_inventory.shelf_id is nullable so every recount loop spends time resolving "which shelf is this actually on" across four sources (doc, pod_inventory, planogram, WEIMI aisle stock). The fix is three small additive pieces that together kill 80% of the manual loops.

## What we ship

Three RPCs (Dara design, Cody review, no FE-only piece) plus one FE app slice (Stax).

### 1. recount_pod_inventory(p_machine_id uuid, p_snapshot jsonb, p_reason text)

A single transactional reconciliation between operator's physical count and current pod state. Returns the diff for inventory_control_attempt audit.

Input shape:

```jsonb
{
  "snapshot_taken_at": "2026-05-30T18:00:00+04:00",
  "lines": [
    {
      "shelf_code": "A10",
      "boonz_product_id": "uuid",
      "expiration_date": "2026-10-29",
      "physical_qty": 6
    },
    ...
  ]
}
```

Behavior per line, in one transaction:

- Look up active pod_inventory row at (machine, shelf, product).
- If exists with same expiry: UPDATE current_stock = physical_qty (no merge math — operator is source of truth).
- If exists with different expiry: archive existing (status='Inactive', removal_reason='recount_2026-05-30'), INSERT new row.
- If absent: INSERT new row with physical_qty + expiry.
- Lines not in the snapshot but currently Active on the machine: archive with removal_reason='recount_2026-05-30_absent'.

Validation:

- Role: warehouse / operator_admin / superadmin / manager.
- p_reason >= 10 chars.
- Every line's shelf_id must exist on the machine (FK enforced).
- p_snapshot.lines must be non-empty.

Audit: writes one inventory_control_attempt per line + one summary row.

This collapses today's "submit 50 add_stock edits and self-approve" into one call where the operator-supplied truth wins.

### 2. force_close_dispatch(p_dispatch_id uuid, p_reason text)

A single verb for cleanup of legacy dispatches regardless of state combo. Sets `include=false`, writes a new column `closed_admin=true` + `closed_admin_reason=p_reason` + `closed_admin_at=now()` + `closed_admin_by=auth.uid()`. Does NOT credit warehouse, does NOT touch pod_inventory, does NOT call return_dispatch_line. Pure system-side close.

Use cases:

- Decommission cleanup (today's Ritz scenario, 87 rows on 6 non-MP machines).
- Test dispatches that never ran (e.g. WH1-2002 6c38dfad).
- Stale `dispatched=true filled_quantity=N driver_confirmed_qty=NULL` rows older than 60 days.

Validation:

- Role: operator_admin / superadmin only (this is admin-only; field staff cannot self-close).
- p_reason >= 20 chars.
- Refuses if row is already `closed_admin=true` (idempotent).

Schema addition (Dara, additive):

```sql
ALTER TABLE refill_dispatching
  ADD COLUMN closed_admin boolean NOT NULL DEFAULT false,
  ADD COLUMN closed_admin_at timestamptz,
  ADD COLUMN closed_admin_by uuid REFERENCES user_profiles(id),
  ADD COLUMN closed_admin_reason text;
```

Every alert / view that currently filters "is this stuck" gets one extra condition: `AND NOT closed_admin`. Single point of truth for "human said done, leave it alone."

### 3. shelf_id NOT NULL backfill + constraint

Today pod_inventory has ~30 active rows with shelf_id=NULL, accumulated from past direct writes that bypassed the shelf-pinning path. Backfill from product_mapping (each Active pod_inventory has a pod_product on a known shelf via planogram). Then ALTER COLUMN SET NOT NULL.

Risks:

- Some Active rows may have a pod_product that's mapped to multiple shelves (multi-position machines). Pick the most-recently-used shelf and surface those for CS review before the ALTER.

Migration is two-step: backfill in one migration (forward-only, has its own audit), then NOT NULL in a second migration after CS confirms zero NULL rows.

### 4. Field-app pod recount slice (Stax)

`/field/inventory/recount/[machineId]` page that:

- Loads current pod_inventory for the machine (one row per shelf+product).
- Renders each shelf with current_stock + expiry as a defaulted input.
- Operator adjusts qty + expiry per row; "+" button adds a new product to a shelf (planogram-suggested).
- Submit calls recount_pod_inventory with the full snapshot.

No more pasting Markdown docs. No more Claude parsing prose.

## Constitutional fit (Cody handoff checklist)

- Article 1: recount_pod_inventory becomes the second canonical writer for pod_inventory (alongside the existing per-edit path); not a parallel scheme, a higher-grain verb for the same write target. Document in RPC_REGISTRY.
- Article 3: force_close_dispatch routes the admin-cleanup path through an RPC instead of direct UPDATE. Net Article-3 win.
- Article 4: both new RPCs set app.via_rpc + app.rpc_name, role-gated, input-validated, audited.
- Article 5: shelf_id NOT NULL is the same status-as-state-machine logic applied to placement.
- Article 12: forward-only; backfill + NOT NULL in two migrations.
- Article 14: no \_v2 tables.

## Not in scope

- Multi-machine batch recount (one machine per call; operator can run twice).
- Reading photo evidence (separate idea, ties to pod_inventory_edits.photo_path).
- WEIMI auto-reconcile (different problem; this one is for physical recounts that contradict WEIMI).

## Acceptance

- A 50-line HUAWEI recount completes in 1 RPC call + 1 audit summary instead of 50 edit submissions + 50 approvals.
- force_close_dispatch can close any of the 88 stale Ritz rows with a single call per row (or a bulk loop), no special-casing per state combo.
- Zero NULL shelf_id rows in pod_inventory; constraint enforced.
- Simran can finish a recount on her phone without sending CS a Markdown doc.

## Open questions for Dara + Cody

1. Should recount_pod_inventory accept a partial snapshot (subset of shelves) with explicit `p_full_or_partial` flag, or always full? Risk: partial = drift opportunity; full = operator has to count everything. Recommend partial with a required `p_scope_shelves uuid[]` so operator declares scope explicitly.
2. force_close_dispatch on a `Remove` action — does it need to reverse pod_inventory? Recommend no (the Remove already debited pod when it was originally packed); force_close just closes the row.
3. shelf_id NOT NULL: do we accept a default fallback (e.g. 'A00') for any unresolvable row, or surface and CS-decides per-row? Recommend per-row surface; "A00" everywhere would silently lose data.

## Sequence

1. Dara: full design doc (this is the high-level brief, not the spec).
2. Cody: review against the 6 articles above.
3. Stax: shelf_id backfill migration (lowest-risk first).
4. Stax: force_close_dispatch (next-lowest; admin-only, additive).
5. Stax: recount_pod_inventory (biggest; needs the FE slice in parallel).
6. Field-app slice: ships with recount RPC.

Target ship: week of 2026-06-09. First test customer: Simran's next visit.
