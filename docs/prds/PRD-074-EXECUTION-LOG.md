# PRD-074 Execution Log - Priority single source of truth

Run 2026-07-04, AUTO mode. Hard gates held: engine_add_pod `ca074e57…`, engine_swap_pod
`90f26896…`, pick_machines_for_refill `48cc1844…` md5 byte-identical before/after;
v_machine_priority md5 `a49cd7d37e1ebf088f36351d54f646ac` UNCHANGED (view not touched).
All DDL dry-proofed in a rolled-back transaction before apply. npm run build green.

## FE call-site proof (gate: no key removed/renamed)

`get_machine_health`: exactly TWO call sites, both `src/app/(app)/refill/page.tsx`
(lines ~426 initial fetch, ~1078 re-fetch after toggle), both cast to the `MachineHealth`
type (page.tsx 109-143) which enumerates all 32 output keys. No other consumer in src/,
edge functions, or n8n. Therefore: all 32 keys KEPT, 4 keys APPENDED only.
`get_stale_visit_signals`: one call site, `refill/SignalsTab.tsx` ~186, reads
machine_name / last_refill_date / days_since_last_refill - output names kept.
`auto_generate_refill_plan`: ZERO callers (FE/n8n/edge grep + cron.job scan; only inert
mention is the enforce_canonical_dispatch_write allowlist string).

## get_machine_health field-by-field: v2 -> v3

| Field                                          | v2 source                                                                   | v3 source                                                                                                                                |
| ---------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| days_since_visit                               | MAX(approved refill_plan_output.plan_date) - WRONG (approve is not a visit) | **v_machine_health_signals.days_since_visit** (executed dispatch: picked_up OR returned OR dispatched+packed); -1 sentinel kept for null |
| last_plan_date / last_plan_days                | (new)                                                                       | APPENDED - the old approved-plan notion, renamed and labeled informational                                                               |
| urgency_breakdown                              | (new; FE had 8 hardcoded formulas)                                          | APPENDED jsonb [{label, pts}]; pts sum == v_machine_priority.urgency exactly                                                             |
| reasons_arr                                    | (new)                                                                       | APPENDED pass-through of v_machine_priority.reasons_arr                                                                                  |
| daily_velocity                                 | v_machine_velocity (already canonical)                                      | unchanged                                                                                                                                |
| expired/expiring                               | v_machine_expiry_summary (already canonical)                                | unchanged                                                                                                                                |
| priority_tier / priority_score / service_track | v_machine_priority pass-through                                             | unchanged                                                                                                                                |
| all other keys                                 | WEIMI-direct / own formulas                                                 | unchanged (remainder below)                                                                                                              |

**Breakdown limitation (HIGHLIGHTED):** v_machine_priority does not expose s_runout /
s_capacity / s_expiry / s_stale as columns and this PRD's gate forbids modifying it
(PRD-073 just shipped). The breakdown therefore has exact chips for 'empty shelves'
(w_empty x s_empty) and 'low-fill sellers' (w_lowfill x s_lowfill) plus ONE lumped
'core urgency (runout+capacity+expiry+stale)' chip = urgency residual, so the sum is
exact by construction. Future one-liner PRD: append the 4 s_* columns to the view and
split the core chip.

**WEIMI-direct / own-formula remainder (kept deliberately, no canonical equivalent or
calibrated-threshold risk):** total_stock, max_capacity, total_slots, slots_at_zero,
slots_below_25pct, fill_pct (health_tier/health_sort thresholds are calibrated on the
raw-WEIMI aggregation; signals' fill_pct is eligibility-filtered and would flip tiers for
grading-blind machines), has_sensor_errors, dead_stock_count + local_hero_count (blended
heat formulas; registry already flags dead-stock for future reconcile), daily_revenue ->
machine_health_label / machine_strategy, days_until_empty (WEIMI stock / canonical
velocity, 999 sentinel).

## Shipped

- `prd074_p1_health_v3_stale_v2_canonical_clocks` APPLIED: get_machine_health v3
  (DROP+recreate for the 4 appended RETURNS columns; grants re-issued),
  get_stale_visit_signals v2 (thin signals-view SELECT, threshold =
  pick_urgency_params.stale_override_days).
- `prd074_p2_deprecate_legacy_generator_and_guard` APPLIED: auto_generate_refill_plan
  deprecated (Article 13: SECURITY INVOKER + REVOKE ALL; ACL now postgres-only; DROP
  eligible 2026-10-04), check_priority_surface_consistency() created.
- FE (refill/page.tsx): 8 chip formulas DELETED - chips render urgency_breakdown verbatim
  - reasons_arr tags + the two 0-pt info chips (dead stock, heroes); labelOrder block
    deleted - status sort uses backend health_sort; cards show split clocks
    ("last visit Nd" canonical amber-warned, "last plan Nd" muted). SignalsTab labels
    updated (server-side params threshold). MachineHealth type +4 fields.
- FE (lifecycle/page.tsx): z-scale clamps (3 sites) + computeFamilyScore + aggregateSlots
  annotated DISPLAY-ONLY accepted approximations (chart layout, feeds no decision
  surface). Moving them to view fields was NOT cheap (bespoke chart-grain aggregation);
  logged per PRD as the accepted path.
- Registry versions realigned by UPDATE to committed filenames (20260704150000/150100).

## T-tests (dry-proofed rolled-back, re-verified live post-apply)

| Test | Result                                                                                                                                                                                  |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1   | PASS - check_priority_surface_consistency() = 0 rows fleet-wide (visit clock, score, tier, track, breakdown-sum), dry AND live post-apply.                                              |
| T2   | PASS - VOXMCC-1005-0201-B0: last visit **22d** / last plan **3d** (live values 2026-07-04) - the exact outage contradiction, now two labeled fields.                                    |
| T3   | PASS - chip sum == urgency on all 5 samples: AMZ-1038 56.58, VOXMCC-1005 71.31, MC-2004 15.74, NOOK-1019 30.87, VML-1003 0.68.                                                          |
| T4   | PASS - stale list (7 machines: VOXMCC-1011 28d, IFLYMCC-1024/VOXMCC-1005/ACTIVATEMCC-1037/MPMCC-1054/MPMCC-1058/ACTIVATE-2005 22d) == the 7 machines with stale_overdue in reasons_arr. |
| T5   | PASS - build green; formula-pattern grep clean (sole hit = the comment naming the removed labelOrder block).                                                                            |

## Skips / notes

1. Lifecycle F3 stays client-side as annotated display-only approximation (accepted per PRD).
2. dead_stock_count formula divergence vs signals dead_slot_pct: pre-existing METRICS_REGISTRY
   "reconcile" flag, unchanged here (different unit, count vs pct; no canonical count object).
3. Guard fn is SECURITY DEFINER (consistent audit snapshot regardless of caller RLS); read-only.
4. VOX on-the-spot venue refills produce neither plans nor dispatches - both clocks miss them
   (PRD gate: out of scope, future field-capture PRD).
