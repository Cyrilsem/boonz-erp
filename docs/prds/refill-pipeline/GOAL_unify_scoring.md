# Claude Code /goal — PRD-UNIFY (one refill decision + final score)

Copy everything inside the fences (<4000 chars).

```
/goal Implement PRD-UNIFY for boonz-erp (Supabase eizcexopcuoycuosittm). Read it first: docs/prds/refill-pipeline/PRD-UNIFY-stance-dosage-scoring.md. Goal: ONE blended refill decision (lifecycle=stance, recency=dosage) written by the engine + shown on the health page with a single Final Score; retire the competing health verdict.

GOVERNANCE per step: Dara → Cody verdict → migration FILE → Stax FE → Cody diff. APPLY NOTHING to prod; output SQL+diff per step; run to completion, STOP at end. Update CHANGELOG/MIGRATIONS_REGISTRY/RPC_REGISTRY.

RULES
- RPC/engine bodies live in Supabase. Fetch via pg_get_functiondef before editing. engine_add_pod is a CORE writer: CALIBRATION not rebuild — DIFF-GATE vs live, only dials + decision emission change (Hard Rule 10: needs CS green light).
- Forward-only; no _v2 tables. DEFINER writers set app.via_rpc/app.rpc_name + role/input validation + audit. compute_refill_decision = read-only INVOKER.
- ⛔ ONE source of truth: compute_refill_decision is the ONLY producer of target_units AND final_score. compute_strategy / get_machine_slots_with_expiry STOP emitting their own target/score (keep 💎/👑 as display badges only).
- Depends on v2 FIX-1 (aisle off-by-one) APPLIED. If not, build the fn + display but flag numbers suspect until FIX-1.

THE DECISION (exact algebra is in the PRD — use it verbatim). Per shelf = machine × product:
- stance = lifecycle signal (local, fallback global). Dials: STAR 2.0/0.80 · DOUBLE DOWN 1.5/0.80 · KEEP GROWING 1.0/0.70 · KEEP 1.0/0.60 · RAMPING 1.0/0.50 · WATCH 1.0/0.40 · WIND DOWN 1.0/0.00 · ROTATE OUT/DEAD 0/0 (cover_mult/floor_pct).
- velocity = 0.6·v7 + 0.4·v30 (Open Q1). target = LEAST(GREATEST(velocity·7·cover, floor·cap), cap); WIND DOWN/ROTATE/DEAD: target ≤ current (drain). refill = max(target−current,0). runway = current/velocity.
- FINAL SCORE = ROUND(demand_base × stance_mult × placement_mult × urgency_mult, 1) where demand_base = 4·u7d+0.5·u15d; stance_mult STAR/DD 1.5·KG 1.2·KEEP 1.0·WATCH 0.8·WIND 0.4·ROTATE/DEAD 0.1; placement_mult = global(💎1.2/📦1.0/🔻0.8)×local(👑1.2/✅1.0/🐕0.7/💀0.3); urgency_mult = 1+LEAST(0.5,GREATEST(0,(7−runway)/7)).

BUILD ORDER
1 (Dara+Cody) ALTER pod_refill_plan ADD COLUMN decision jsonb (stance, cover_mult, floor_pct, velocity, days_cover, velocity_target, visual_target, target_units, refill_qty, runway_days, global_badge, local_badge, units_7d, final_score, reasoning).
2 (Dara+Cody) compute_refill_decision(machine_id,shelf_id,boonz_product_id,days_cover int DEFAULT 7) RETURNS jsonb — canonical formula, SECURITY INVOKER, register read-only.
3 (refill-brain+Cody) Calibrate engine_add_pod to the dials + emit decision (incl final_score). VERBATIM DIFF vs live; only dials + decision emission change.
4 (Stax+Cody) Repoint get_machine_slots_with_expiry to return decision + final_score; stop emitting its own target/base_score; keep 💎/👑 + stance as display only. Diff-gate.
5 (Stax) Health page (AMZ modal) + RefillPlanningTab: replace Strategy(PROTECT/SUSTAIN)+Score columns with Global · Local · 7d Sales · Stance · Final Score (sort by Final Score desc; hover = breakdown). Read decision only, no FE recompute. npx next build.

ACCEPTANCE: card target==decision.target_units; Rice Cake WIND DOWN→refill 0 + score pushed down despite 💎; Gatorade DD low-velocity→capped ramp; Vitamin Well KEEP→velocity/floor-led < fill-to-max; compute_strategy emits no target/score; engine_add_pod diff = dials+decision only; near-empty hero floats up via urgency; final_score on card == picker rank value; health columns correct (no PROTECT/SUSTAIN col).

OUTPUT per step: Cody verdict, SQL+diff, FE diff, matching acceptance checks, apply order. Final summary; I review + apply.
```
