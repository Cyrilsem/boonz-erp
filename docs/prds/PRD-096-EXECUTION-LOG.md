# PRD-096 Execution Log — Within-pod relocation proposals (PARKED)

Run 2026-07-09 overnight, AUTO. **Status: PARKED (rule F: spec drift). NOT shipped.**

## Why parked

096 assumes `engine_finalize_pod`'s `capacity_mismatch_warnings` contain hv→lv **pairs**
(`high_velocity_product`, `current_shelf`, `candidate_shelf`) to turn into a RELOCATE proposal.
The live warnings are **per-shelf**, not pairs — keys are
`{machine_id, shelf_id, shelf_code, pod_product_id, pod_product_name, qty, reason, action, warning_type}`.
A trial (rolled back) added a flag-gated `within_pod_relocation_proposals` field to the RETURN
(proposals-only, diff-inert), but it produced **0 proposals** because the pairing data isn't there.
Building the hv-small ↔ lv-big pairing from scratch requires Dara design of the pairing rule +
`warning_type` semantics. The additive-return-field mechanism itself is sound and reusable.

## Needed to un-park

Dara defines the within-pod pairing (which `warning_type`s pair, hv/lv selection), then emit the
proposal from the paired set behind `pod_reloc_v1`. Proposals-only (return jsonb) keeps it diff-inert.

## Status: PARKED (rule F: capacity warnings are per-shelf, not hv/lv pairs). Owner: Dara + CS.
