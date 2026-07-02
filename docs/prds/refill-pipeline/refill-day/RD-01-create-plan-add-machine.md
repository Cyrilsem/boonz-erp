---
id: RD-01
title: Create a refill plan / add a machine to the plan on refill day
status: Draft
owners: { design: Dara, review: Cody, implement: Stax }
protected_entities: [machines_to_visit, pod_refill_plan]
depends_on: []
---

# RD-01 — Create a plan / add a machine on the day

## Problem

On refill day the operator/warehouse manager often needs to service a machine the 8pm picker did
NOT select (a partner call-in, a machine that just went empty, a sibling on the same route), or to
spin up a one-off plan for a date that has no draft. Today the only entry point is the nightly
picker; `machines_to_visit` has a `cs_added` status value referenced by `bulk_set_machine_inclusion`
but there is **no RPC to create that row or to seed a plan ad-hoc**. The operator resorts to waiting
for the next cron or raw inserts.

## Current state

- `pick_machines_for_refill` (v6) is the only writer of `machines_to_visit` (status `picked`).
- `is_included` toggle + `build_draft_for_confirmed` exist but operate on already-picked machines.
- No `create_refill_plan` / `add_machine_to_plan`. `cs_added` status is consumed but never produced.

## Dara — schema design

No new table. Extend the state machine on `machines_to_visit` and add two canonical writers.

```sql
-- machines_to_visit.status already allows 'picked' | 'superseded'; add 'cs_added' formally.
ALTER TABLE public.machines_to_visit
  DROP CONSTRAINT IF EXISTS machines_to_visit_status_check;
ALTER TABLE public.machines_to_visit
  ADD CONSTRAINT machines_to_visit_status_check
  CHECK (status IN ('picked','cs_added','superseded'));
-- add_source provenance so the engine/diff can tell operator-added from picker-picked
ALTER TABLE public.machines_to_visit
  ADD COLUMN IF NOT EXISTS add_source text NOT NULL DEFAULT 'picker'
  CHECK (add_source IN ('picker','operator','sibling','driver_callout'));
```

Index: existing `(plan_date, machine_id)` PK covers it. No new index.
RLS shape: writes only via the two RPCs below (Article 3); `add_source` set inside the RPC, never
by FE. Cody handoff: Articles 2, 4, 5, 12, 14.

**RPC signatures (bodies → Cody review, Dara designs the contract):**

- `add_machine_to_plan(p_plan_date date, p_machine_id uuid, p_confirm boolean DEFAULT true) RETURNS jsonb`
  — inserts a `machines_to_visit` row with `status='cs_added'`, `add_source='operator'`,
  `is_included=true`, and `confirmed_at = now()` when `p_confirm` (so it joins the confirmed set
  immediately). Pulls the same health snapshot columns the picker writes (via
  `v_machine_health_signals`). Idempotent on `(plan_date, machine_id)` — re-add re-includes.
- `create_refill_plan(p_plan_date date, p_machine_ids uuid[]) RETURNS jsonb`
  — convenience wrapper: calls `add_machine_to_plan` for each id, then leaves the engine build to
  the normal `build_draft_for_confirmed` path (does NOT auto-run the engine — preserves the
  human-confirm gate, `feedback_cron_keep_human_confirm`).

## Cody — constitutional review (design verdict)

**Verdict:** ✅ Approve the contract.
**Articles:** 4 (DEFINER sets `app.via_rpc`/`app.rpc_name`, role-gated `operator_admin`/`superadmin`/
`warehouse`, validates machine exists + not repurposed), 5 (status transitions only via these RPCs —
`cs_added` is a legal new state, not an arbitrary flip), 8 (machines_to_visit audit trigger present),
12 (forward-only), 14 (no `_v2` table — evolves the canonical table).
**Constraint:** must NOT run the engine inside these RPCs (keeps the confirm gate). Must NOT let FE
write `add_source` or `status` directly (Article 3).

## Stax — FE / wiring

**Files:** `src/app/(app)/refill/RefillPlanningTab.tsx` (an "+ Add machine" control above the card
list → machine picker modal), `src/app/(app)/refill/_actions.ts` (server action `addMachineToPlan`).

```tsx
// _actions.ts ('use server')
export async function addMachineToPlan(planDate: string, machineId: string) {
  const sb = createServerClient();
  const { error } = await sb.rpc("add_machine_to_plan", {
    p_plan_date: planDate,
    p_machine_id: machineId,
    p_confirm: true,
  });
  if (error) throw new Error(error.message);
  revalidatePath("/refill");
}
```

Rules: S1 (RPC only), S7 (server action), S2 (greppable). The added machine appears in the list as a
`cs_added` card; the existing build/commit flow then includes it.

## Edge cases (tested)

| #   | Case                                            | Expected                                                                |
| --- | ----------------------------------------------- | ----------------------------------------------------------------------- |
| E1  | Machine already in plan (picked)                | Re-include if excluded; no duplicate row; return `already_in_plan`      |
| E2  | Machine is repurposed/inactive                  | Refuse with clear message; no row created                               |
| E3  | plan_date has no draft yet                      | Row created; `build_draft_for_confirmed` later builds it                |
| E4  | Engine already ran for the date                 | Adding does not retro-build; operator re-runs build for the new machine |
| E5  | `create_refill_plan` with a bad id in the array | Whole call rolls back; report the offending id (atomic)                 |
| E6  | field_staff (driver) calls it                   | Forbidden (role gate) — driver uses RD-03 callout instead               |

## Acceptance tests

- A1: `add_machine_to_plan` on an un-picked machine → one `machines_to_visit` row, `status='cs_added'`,
  `add_source='operator'`, `is_included=true`, `confirmed_at` set; audit row written.
- A2: re-adding the same machine is idempotent (still one row).
- A3: `build_draft_for_confirmed` after add includes the new machine in the draft.
- A4: a repurposed machine is refused; zero rows written.
- A5: no raw write to `machines_to_visit` anywhere in FE (grep clean).

## Out of scope / dependencies

Auto-suggesting _which_ machine to add (that's the picker / learning loop). No dependency on FIX-1.
