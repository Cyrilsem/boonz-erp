# Claude Code /goal — Learning Loop (Layer 3: make the brain improve)

Run this LAST in the chain: FIX-1 ✅ → PRD-UNIFY → RD-day → **learning loop**. It depends on
PRD-UNIFY (the `decision` + `final_score`) being applied. Copy everything inside the fences (<4000).

```
/goal Build the Boonz refill LEARNING LOOP (v2 F7 / FIX-10). Read first: docs/prds/refill-pipeline/PRD_refill_system_v2.md (F7) + PRD-UNIFY-stance-dosage-scoring.md (the decision it learns on) + BUILD-ORDER.md. This is Layer 3 — it consumes the unified decision and the operator's edits to make the next draft better. Depends on PRD-UNIFY applied (decision jsonb + final_score on pod_refill_plan).

GOVERNANCE per step: Dara → Cody verdict → migration FILE → Stax wire → Cody diff. APPLY NOTHING to prod; output SQL+diff per step; run to completion, STOP at end. Update CHANGELOG/MIGRATIONS_REGISTRY/RPC_REGISTRY.

RULES
- Forward-only; no _v2 tables. DEFINER writers set app.via_rpc/app.rpc_name + role/input validation + audit. Read fns SECURITY INVOKER.
- engine_add_pod is a CORE writer: any change is DIFF-GATED vs live; the loop's bias is an INPUT to the decision, BOUNDED + reversible, never a silent re-tune (same rule as PRD-UNIFY).
- ⛔ Calibration of PRD-UNIFY knobs (velocity blend, days_cover, final-score weights) is PROPOSE-ONLY: write recommended values to a table for CS approval; NEVER auto-apply to the engine.
- Protected: pod_refill_plan, refill_plan_output. Cody verdict each writer.

BUILD ORDER
1 (Dara+Cody) engine_recommendation_snapshot table: immutable per (plan_date, machine_id, shelf_id, pod_product_id) — captures the engine's decision (stance, target_units, refill_qty, final_score, velocity, cover_mult, floor_pct) at draft time. Append-only RLS (no UPDATE/DELETE). Written by the engine right after it builds the draft (PRD-UNIFY decision = the snapshot payload).
2 (Dara+Cody) refill_edit_signals table: one row per operator edit, typed — qty_raised/qty_lowered (+delta), item_added, item_removed, swap_rejected, source_changed — with (machine,shelf,product, plan_date, old, new, by, at). Populated by diffing the committed pod_refill_plan vs its snapshot at commit time (a capture_refill_edit_signals(plan_date) writer, called in the commit chain).
3 (refill-brain+Cody) Ingest driver signals: wire driver_recommendations / driver_feedback / action_tracker (from RD-03) so a logged "machine X needs Y" surfaces as a FLAGGED recommended row in X's next draft (v2 F2). Flag source; do not auto-commit qty.
4 (refill-brain+Cody) Bounded deterministic feedback into the decision: per (machine, shelf, product) maintain a qty_bias (rolling mean of recent qty_raised/lowered deltas, CLAMPED to ±N units), a suppress flag after K repeated swap_rejected, and a raise flag after K repeated item_added(missed). compute_refill_decision applies bias within cover/floor bounds; capped, decays, fully reversible. DIFF-GATE the engine touch.
5 (Dara+Stax) Calibration recommender (PROPOSE-ONLY): a weekly job + view that, from snapshot-vs-final history, recommends the PRD-UNIFY open-Q knobs — velocity blend weights (start 0.6·v7+0.4·v30), days_cover, final-score weights (STANCE_W/global_w/local_w) — and writes them to refill_calibration_proposals for CS to review/apply. NEVER auto-applies.
6 (Stax) FE: a "Engine vs final" diff view per plan_date (snapshot vs committed, one click) + a weekly "systematic misses" report (top shelves the engine under/over-refills by avg N). npx next build.

ACCEPTANCE (parent PRD): after K cycles of the operator raising a given shelf's qty, the engine's recommendation for that shelf converges toward the operator's number WITHOUT manual edits (bounded by the cap); repeatedly-rejected swaps stop being proposed; repeatedly-added missed items appear in the next draft; the snapshot is immutable; the calibration recommender only proposes (no auto-apply); engine diff = bias-input + snapshot emission only (no multiplier re-tune).

OUTPUT per step: Cody verdict, SQL+diff, FE diff, matching acceptance checks, apply order. Final summary; I review + apply.
```
