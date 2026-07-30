# PRD-107 — Pack Stage: Remove Legs, Skip Semantics, Progress Truth

**Status:** DRAFT — needs Stax (FE) + Dara (constraint) + Cody review
**Author:** CS via assistant session, 2026-07-29
**Trigger incident:** Plan 2026-07-29. Warehouse finished packing HUAWEI-2003 (27/28) and MC-2004 (32/39) but the board stayed on "Mark All Packed" and the team could not advance to dispatch. Recurring problem (also NOOK 07-20 family).

## Root cause (verified in DB + function source)

1. **FE and backend disagree on what "packable" means.** `confirm_machine_packed` counts unresolved lines with `action IN ('Refill','Add New','Add')` only — Remove legs are correctly excluded server-side. But the FE progress bar and the "Mark All Packed" button gate count Remove legs in the denominator. A machine whose only unpacked lines are Removes is done per the backend but forever incomplete per the FE.
2. **Remove legs have no pack state machine.** Nothing in WH to pack: packers either leave them (packed=false, outcome NULL — stuck look) or toggle them (packed=true, outcome NULL — 10 such inconsistent rows on 07-29). Both states are wrong; there is no canonical "no pack needed" outcome.
3. **Skip semantics are overloaded.** `skipped` was designed for "warehouse skips this line"; for a Remove leg, skipping silently drops a driver-side machine action (dead stock stays on shelf, swap leg breaks). On 07-29 skipping A15 removes was CORRECT only because the paired swap-in was not_filled — that pairing logic lives in nobody's head but ops'.
4. **Broken swap pairs ship.** When an ADD_NEW swap-in goes `not_filled` (WH empty), its paired REMOVE still ships → shelf goes out EMPTY. No auto-detection of orphaned swap legs at pack time.

## Requirements

R1. **One source of truth for packable.** A SQL predicate/view `v_dispatch_pack_progress` (per machine+date: packable_n, resolved_n, remove_n, not_filled_n, skipped_n, ready_to_dispatch bool) used by BOTH `confirm_machine_packed` AND the FE board. FE must not re-implement the denominator.

R2. **Remove/M2W-source legs auto-resolve at push.** New pack_outcome enum value `no_pack_needed` stamped at push_plan_to_dispatch for actions that draw nothing from WH (Remove, M2W, M2M source leg). They stay on the driver manifest regardless of pack state. Progress = resolved(packed|partial|not_filled|skipped|no_pack_needed) ÷ total_included.

R3. **Consistency constraint.** CHECK/trigger: `packed=true` requires `pack_outcome IS NOT NULL`. Migrate the historical NULL-outcome packed rows.

R4. **Orphaned swap-leg guard at pack close.** At `confirm_machine_packed(final=true)`: for each shelf with a REMOVE + ADD_NEW pair where the ADD_NEW resolved `not_filled`/`skipped`, auto-flag the REMOVE with `needs_review='orphaned_swap_leg'` and surface in the confirm response. Default proposal: skip the REMOVE (keep shelf stocked) with one-tap accept, never silent.

R5. **Driver manifest independence.** Driver app line inclusion must depend only on include/cancelled/skipped — never on packed/pack_outcome — so Remove legs always reach the machine.

R6. **FE board buttons.** "Mark All Packed" enabled when v_dispatch_pack_progress.ready_to_pack_close = true (all packable resolved), not when 100% of all lines packed. Progress bar shows packable-based percentage with removes listed separately ("+N driver actions").

## Interim workaround (until built)

When the board looks stuck at P n/N with only Remove legs unpacked: run `confirm_machine_packed(machine, date, actor, reason, final=>true)` directly — it passes. If a swap-in went not_filled, FIRST `skip_dispatch_line` the paired REMOVE lines so the shelf doesn't go out empty (07-29: MC A15 Dubai Popcorn ×4 skipped for exactly this).

## Acceptance

- Replay 07-29 MC-2004: board shows ready-to-close with 32/32 packable resolved and "7 driver actions" listed; confirm succeeds first click; A15 orphaned REMOVE auto-flagged.
- Zero rows fleet-wide with packed=true AND pack_outcome IS NULL (post-migration + constraint).
- Driver app shows Remove legs for a machine that was pack-closed with those legs untouched.
- pgTAP: predicate parity between view and confirm_machine_packed; orphan-pair detection; constraint.
