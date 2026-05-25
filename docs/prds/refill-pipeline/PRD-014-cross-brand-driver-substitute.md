---
id: PRD-014-refill-pipeline
program: PROGRAM-2026-05-25
title: Cross-brand driver substitute flow
status: Drafted
severity: P1
reported: 2026-05-25
source: PROGRAM-2026-05-25 Phase 2 P1 #2 (semantic name PRD-006-refill-pipeline)
routing: [Dara (one new table or extend variant_action_log), Cody, Stax]
---

## Problem

Driver scenario: at OMDBB the planned dispatch is "Hot & Sweet" but the
driver actually places "Himalayan Pink" (a different brand entirely). This
is a cross-family substitution — `record_variant_correction` (PRD-012)
explicitly refuses cross-family swaps unless `action_type='dispatch_extra_variant'`.

`dispatch_extra_variant` is for ADDING a variant alongside the planned one;
it does NOT replace the planned one. The cross-brand REPLACE case has no
RPC.

Drivers do the swap physically anyway — pod_inventory drifts, refill plans
stay wrong. The 22-May Refill Update lists this as a recurring scenario.

## Proposed solution

New canonical writer: `record_cross_brand_substitution(...)`.

Signature:

```sql
CREATE FUNCTION public.record_cross_brand_substitution(
  p_refill_dispatching_id uuid,
  p_planned_variant_id    uuid,    -- the original product
  p_substitute_variant_id uuid,    -- what was actually placed
  p_qty                   numeric,
  p_reason_code           text NOT NULL,  -- 'customer_request' | 'out_of_stock_field' | 'wrong_label' | 'other'
  p_free_text             text
) RETURNS jsonb SECURITY DEFINER
```

Behavior:

1. Role gate (`field_staff/warehouse/operator_admin/superadmin/manager`).
2. Reject NULL planned variant (cross-brand REPLACE requires both ends).
3. Append-only `variant_action_log` row with
   `action_type='cross_brand_substitution'` (new value — requires CHECK
   widening). Carries `planned_variant_id`, `new_variant_id` (substitute),
   `qty`, `reason_code`, `free_text`, `created_by`.
4. pod_inventory: decrement planned variant + increment / upsert substitute
   variant row (same pattern as `record_variant_correction`).
5. dispatch row: update `boonz_product_id` to the substitute? OR keep the
   original and let the variant_action_log carry the truth? **Open
   question — Dara/Cody decide.** Default proposal: keep dispatch row
   unchanged (it represents what was planned); the log carries the
   substitution.
6. `driver_feedback` insert with `feedback_kind='cross_brand_substitution'`
   so the engine's signal-learning loop sees the pattern.

Migration name candidate: `prd014_record_cross_brand_substitution_rpc`.

## FE

Driver flow on the dispatch line "edit" affordance:

- Existing: "Same-family variant correction" (PRD-012, once shipped).
- NEW: "Different product (cross-brand)" — opens a `boonz_products`
  picker (search by name) with a mandatory reason dropdown.
- On confirm: calls the new RPC.

## CHECK widening

`variant_action_log.action_type` CHECK currently:
`'return_variant_change' | 'return_variant_split' | 'dispatch_substitution' | 'dispatch_extra_variant'`.

Need to add `'cross_brand_substitution'`. Forward-only migration:
`ALTER TABLE ... DROP CONSTRAINT ...; ADD CONSTRAINT ... CHECK (...)`.
Note: must include ALL existing values + the new one.

## Out of scope

- WH-side warehouse_inventory adjustment for the substituted variant.
  Pod-vs-WH expiry scope rule applies: pod edits do NOT cascade to WH.
- Cross-brand on RETURN (driver returns Brand X when dispatch was Brand Y).
  Less common; tracked as a follow-up.

## Acceptance

- New RPC exists in pg_proc.
- variant_action_log CHECK includes the new value.
- FE picker live behind `field_staff` + WH manager roles.
- Smoke: OMDBB Hot & Sweet → Himalayan Pink scenario completes end-to-end.

## Linked

- [[PRD-012-rescue-record-variant-correction]] — must ship FIRST. This PRD
  reuses its variant_action_log table and shares pod_inventory write
  pattern.
