/goal PRD-058: make P1/P2 machine priority config-driven so CS can prioritize or deprioritize dead stock and rebalance the weights on stock availability, velocity, and time since last refill. ONE canonical view + ONE params table. No consumer code change. Full spec: boonz-erp/docs/prds/PRD-058-tunable-priority-weights.md. MODE AUTO but STOP for CS before applying any migration.

CONTEXT (verified live, eizcexopcuoycuosittm): P1/P2 is decided ONLY in view public.v_machine_priority. It is consumed by get_machine_health() (Stock Snapshot cards) AND pick_machines_for_refill v8 (picker references the view directly). Both p_tier thresholds and the additive p_score are hard-coded literals. Dead stock enters as: expired_skus_now>=1 forces P1 (+20 in score) and dead_slot_pct>=30 pushes P2 (+10) — no knob to tune. Inputs (fill_pct, runway_days, empty_shelves_count, units_last_7d, days_since_visit) come from v_machine_health_signals; only the weights are frozen.

PRE: git pull --rebase main; branch feat/prd-058-tunable-priority-weights.

BUILD (phased; STOP for CS between phases):
P1 Dara design: new single-row config table refill_priority_params (id smallint PK CHECK id=1). Columns = one numeric per literal currently in v_machine_priority (availability: empty base/step/cap, runway tiers, fill tiers, under25 step/cap; velocity: high_velocity; recency: stale_21/14/10; dead stock dial: w_expired_now, w_dead_slot_30/15, dead_stock_forces_p1 bool, p1_expired_min_skus, p2_dead_slot_pct, p2_stale_days; tier thresholds: p1_runway_crit, p1_strong_units/runway, p1_fill_pct/units, p1_under25_count/units; w_intent; updated_at/by). Seed the row with EXACTLY today's baked-in values.
P2 Dara: rewrite v_machine_priority to CROSS JOIN refill_priority_params and replace every literal in the p_tier CASE and p_score sum with the matching column. reasons_arr unchanged. dead_stock_forces_p1 gates whether expired_skus_now>=p1_expired_min_skus may enter the P1 branch.
P3 Cody review (Article 16 canonical-writer change, Hard Rule 6). Forward-only migration. STOP and show CS the migration + a before/after p_tier/p_score fleet diff BEFORE apply.
P4 Apply after CS go-ahead. No change to get_machine_health() or pick_machines_for_refill.

TEST (all must pass; STOP on any failure):
T1 GOLDEN: with seeded defaults, SELECT machine*id,p_tier,p_score,reasons_arr FROM v_machine_priority is byte-identical to a pre-change full-fleet snapshot (zero drift on deploy).
T2 DIAL DOWN: dead_stock_forces_p1=false + w_expired_now=0 -> machines whose only P1 reason was expired_now leave P1; no other tier changes.
T3 DIAL UP: raise w_expired_now -> affected p_score rises by exactly the delta; tier unchanged unless a threshold crossed.
T4 REBALANCE: bump w_high_velocity / w_stale*\* / availability weights -> p_score deltas equal the param deltas (arithmetic check).
T5 PICKER PARITY: pick_machines_for_refill for a test date returns the same machine set under default params as before.
T6 single-row guard: second insert into refill_priority_params rejected.

CLOSE: update CHANGELOG.md, MIGRATIONS_REGISTRY.md, METRICS_REGISTRY.md (v_machine_priority now param-driven), set PRD-058 status with migration names.

HARD SAFETY: default-seeded behavior byte-identical (T1 gates deploy); swaps_enabled stays false; engine_add_pod + engine_swap_pod untouched; forward-only; rebase --autostash; do NOT push to main without my explicit go-ahead; pause for CS before applying the migration. Rollback = reset the params row to seeded defaults.
