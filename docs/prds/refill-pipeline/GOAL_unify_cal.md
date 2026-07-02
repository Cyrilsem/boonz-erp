# Claude Code /goal — PRD-UNIFY-CAL (lock the decision dials)

Run alongside / just before PRD-UNIFY Step 3. Copy everything inside the fences (<4000).

```
/goal Apply PRD-UNIFY-CAL for boonz-erp (Supabase eizcexopcuoycuosittm): lock the unified-decision dials to the delta-validated values. Read first: docs/prds/refill-pipeline/PRD-UNIFY-CAL-dials-calibration.md + PRD-UNIFY-stance-dosage-scoring.md. Depends on PRD-UNIFY Steps 1-2 applied (pod_refill_plan.decision + compute_refill_decision exist — they are live).

GOVERNANCE: Dara → Cody verdict → migration FILE → (engine touch) diff-gate → STOP for CS green light before applying the engine change. APPLY the read-only function change; HOLD the engine change for CS sign-off. Output SQL + the delta proof. Update CHANGELOG/MIGRATIONS_REGISTRY.

THE CHANGE (only three constants; everything else identical):
- days_cover default: 7 → 10
- KEEP floor_pct: 0.60 → 0.70
- RAMPING floor_pct: 0.50 → 0.60
Unchanged: all cover_mults, the other floors (STAR/DD 0.80, KG 0.70, WATCH 0.40, WIND DOWN 0.00, ROTATE/DEAD 0.00), the WIND DOWN/ROTATE/DEAD drain rule (target ≤ current), and ALL final-score weights.

RULES
- Fetch live compute_refill_decision via pg_get_functiondef; re-CREATE with ONLY the three constants changed (diff must show exactly those). Read-only / SECURITY INVOKER — safe to apply.
- engine_add_pod (PRD-UNIFY Step 3, v13→v14) must call compute_refill_decision with days_cover := 10. This is a CORE writer: DIFF-GATE vs live, Hard Rule 10 — do NOT apply; produce the file + diff and STOP for CS green light.
- Forward-only; no _v2 tables. No other dial/logic change (the learning loop tunes further later — propose-only).

STEPS
1 (refill-brain+Cody) Re-CREATE OR REPLACE compute_refill_decision with days_cover DEFAULT 10, KEEP floor 0.70, RAMPING floor 0.60. Apply (read-only, safe).
2 (verify) Re-run the by-stance delta on plan 2026-06-05 (status='stitched', action IN REFILL/ADD_NEW), comparing compute_refill_decision(...,10)->>'refill_qty' to pod_refill_plan.qty. Confirm: WIND DOWN/DEAD/ROTATE = 0; KEEP within ~−15% of v13; total ≥ ~310 (vs the untuned 227). Output the table.
3 (refill-brain+Cody) Update the engine_add_pod Step-3 migration FILE to pass days_cover := 10 to compute_refill_decision; diff-gate vs live; STOP for CS green light (do not apply).
4 (docs) Update PRD-UNIFY's dials table + canonical block to days_cover 10 / KEEP 0.70 / RAMPING 0.60 so the PRD and the function agree.

ACCEPTANCE: compute_refill_decision diff = exactly the three constants; delta shows the Tuned profile (KEEP ≈ −26, total ≈ 316, drains = 0); engine change held as a file for CS sign-off.

OUTPUT: Cody verdict, the function diff, the delta table, the held engine diff, apply order. Final summary; I review + apply the engine change.
```
