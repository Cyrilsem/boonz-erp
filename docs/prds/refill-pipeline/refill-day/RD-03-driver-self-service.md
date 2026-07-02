---
id: RD-03
title: Driver self-service — report outcome and propose adjustments that auto-update driver tasks
status: Draft
owners: { design: Dara, review: Cody, implement: Stax }
protected_entities: [refill_dispatching, dispatch_plan]
depends_on: []
---

# RD-03 — Driver self-service (replace the WhatsApp loop)

## Problem

On the road the driver hits reality the plan didn't predict: an item wasn't on the truck, a shelf was
already full, a machine was offline, a partner asked for something extra. Today the driver reports
this on WhatsApp and someone manually edits tasks later. CS wants the driver to record, in the field
app: (a) whether each dispatched line was actually done ("got it / didn't"), and (b) a recommendation
("MINDSHARE needs Vitamin Well next visit") that **automatically updates the driver tasks / feeds the
next plan** — no WhatsApp, no manual transcription.

## Current state

- `refill_dispatching` carries `dispatched` / `picked_up` flags; the field pickup/packing pages read it.
- `driver_confirm_remove` exists (narrow: confirm a REMOVE). `driver_feedback` + `action_tracker`
  tables exist but the field app does not write structured outcomes/recommendations to them, and they
  are not wired into the next draft (the long-pending G5 Track D / v2 F2).
- Driver role = `field_staff`.

## Dara — schema design

Two write surfaces. (1) A per-line outcome on dispatch. (2) A structured recommendation row.

```sql
-- (1) outcome on the dispatch line (state machine, Article 5)
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS driver_outcome text
    CHECK (driver_outcome IN ('done','partial','not_done','machine_offline','no_stock_on_truck')),
  ADD COLUMN IF NOT EXISTS driver_outcome_qty int,          -- actual qty placed when 'partial'
  ADD COLUMN IF NOT EXISTS driver_outcome_at timestamptz,
  ADD COLUMN IF NOT EXISTS driver_outcome_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL;

-- (2) structured driver recommendation -> feeds action_tracker + driver_feedback (existing tables)
CREATE TABLE IF NOT EXISTS public.driver_recommendations (
  rec_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by    uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  machine_id    uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id      uuid REFERENCES public.shelf_configurations(shelf_id) ON DELETE SET NULL,
  kind          text NOT NULL CHECK (kind IN ('needs_product','overstocked','wrong_product','machine_issue','other')),
  boonz_product_id uuid,
  note          text NOT NULL,
  status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open','actioned','dismissed')),
  source        text NOT NULL DEFAULT 'driver_app'
);
CREATE INDEX IF NOT EXISTS idx_driver_rec_machine_open
  ON public.driver_recommendations (machine_id) WHERE status = 'open';
```

RLS shape: `field_staff` may INSERT outcomes/recs only for dispatch rows on **their** assigned
dispatch (join `dispatch_plan`), and may SELECT their own; operator/superadmin/warehouse SELECT all.
No UPDATE/DELETE by field_staff. Cody handoff: Articles 2, 3, 4, 5, 7, 8, 12, 14 (+ add
`driver_recommendations` to Appendix A? — see Cody).

**RPC contracts:**

- `driver_report_dispatch_outcome(p_dispatch_id uuid, p_outcome text, p_actual_qty int DEFAULT NULL) RETURNS jsonb`
  — sets the outcome columns; on `not_done`/`no_stock_on_truck` it auto-creates an `action_tracker`
  punch-item ("re-dispatch X to machine Y") so nothing is silently dropped; on `partial` records the
  real qty. Role: `field_staff` (own dispatch) + operator/superadmin.
- `driver_propose_adjustment(p_machine_id uuid, p_kind text, p_note text, p_boonz_product_id uuid DEFAULT NULL, p_shelf_id uuid DEFAULT NULL) RETURNS jsonb`
  — writes `driver_recommendations` (status `open`) AND mirrors to `driver_feedback` + `action_tracker`
  (per `reference_action_tracker_vs_driver_feedback`: write BOTH). The next draft picks it up (v2 F2
  wiring) as a flagged recommended row for that machine.

## Cody — constitutional review

**Verdict:** ⚠️ Approve with revisions.
**Articles:** 3 (field*staff must NOT write `refill_dispatching` directly — only via the outcome RPC,
scoped to their own dispatch), 5 (outcome is a state transition via RPC; cannot move a `picked_up`/
finalized line backwards), 7 (`driver_recommendations` is operational, not an audit log — normal RLS,
not append-only-locked, but writes via RPC), 8 (both tables get audit), 4 (role gate + ownership
check + valid enum), 14 (new table, not a `_v2`).
**Revisions / ruling:** (a) the ownership check is mandatory — a driver may only report on dispatch
rows belonging to a `dispatch_plan` assigned to them; (b) `driver_report_dispatch_outcome` must not
mutate `quantity`/`action` (those are operator edits — RD only records \_what happened*, the engine
reacts next cycle); (c) `driver_recommendations` does **not** need Appendix A protection (it's a
proposal feed, not a source of truth), but its writer RPC still sets `app.via_rpc`.

## Stax — FE / wiring

**Files:** `src/app/(field)/field/pickup/...` and `.../dispatching/[machineId]/page.tsx` (a per-line
"Done / Partial / Couldn't" control + a "Recommend" sheet), `src/app/(field)/field/_actions.ts`
(`reportDispatchOutcome`, `proposeAdjustment`). Field app is a PWA — optimistic with rollback (S8),
offline-queue the outcome and flush on reconnect.

```tsx
// (field) _actions.ts ('use server')
export async function reportDispatchOutcome(
  dispatchId: string,
  outcome: string,
  actualQty?: number,
) {
  const sb = createServerClient();
  const { error } = await sb.rpc("driver_report_dispatch_outcome", {
    p_dispatch_id: dispatchId,
    p_outcome: outcome,
    p_actual_qty: actualQty ?? null,
  });
  if (error) throw new Error(error.message);
  revalidatePath("/field");
}
```

Rules: S1, S7, S8, S9 (RLS may scope rows to the driver — handle 0-rows). Cody handoff: confirm no
`.from('refill_dispatching').update(...)` in the field app; confirm ownership scoping in the RPC.

## Edge cases (tested)

| #   | Case                                          | Expected                                                                                             |
| --- | --------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| E1  | Driver reports `not_done`                     | Outcome set; `action_tracker` item auto-created for re-dispatch; not silently lost                   |
| E2  | `partial` with actual qty                     | qty recorded; difference visible to operator; engine sees true placement next cycle                  |
| E3  | Driver reports on a line not theirs           | Forbidden (ownership scope)                                                                          |
| E4  | Line already `picked_up`/finalized            | Outcome refused or appended as note only — cannot reverse a finalized line                           |
| E5  | Offline at time of report                     | Queued in PWA; flushed on reconnect; no double-write (idempotent on dispatch_id+outcome)             |
| E6  | Recommendation for a machine not on any plan  | Stored `open`; surfaces on that machine's next draft regardless                                      |
| E7  | Duplicate recommendation same machine/product | Allowed but deduped in the next-draft surfacing (one flagged row)                                    |
| E8  | Recommendation references unmapped product    | Stored as free-note rec; flagged so operator maps before it can become a plan row (ties RD-02/FIX-5) |

## Acceptance tests

- A1: a logged `not_done` outcome produces an `action_tracker` punch-item and is visible to the operator.
- A2: `driver_propose_adjustment` writes `driver_recommendations` + `driver_feedback` + `action_tracker` (all three).
- A3: that recommendation appears as a flagged recommended row in the machine's next draft (F2 wiring).
- A4: a `field_staff` user cannot affect another driver's dispatch (ownership enforced).
- A5: no direct `.from('refill_dispatching')` write in `(field)` (grep clean).
- A6: offline report flushes exactly once on reconnect.

## Out of scope / dependencies

The deterministic learning adjustment from these signals is v2 F7/FIX-10. RD-03 captures + routes the
signal and auto-updates tasks; converging the engine numbers is the learning loop's job. Soft
dependency on v2 F2 for the next-draft surfacing.
