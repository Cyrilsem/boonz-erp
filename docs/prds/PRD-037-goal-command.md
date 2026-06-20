# Claude Code /goal — PRD-037 Refill v4 Swap Engine (build + test, gated)

Paste into Claude Code in `boonz-erp`. Builds migration files, runs the conditional tests in rolled-back replays, STOPS for CS before any prod apply. ADD stays frozen. swaps_enabled stays OFF.

```
/goal Build PRD-037 (Refill v4 swap engine). Read docs/prds/PRD-037-refill-v4-swap-engine.md and the four guardrail files in engines/refill/guardrails/ first. Supabase eizcexopcuoycuosittm. No em dashes. Forward-only migrations, no edit-in-place, no _v2. No deletes (supersede only); no qty cut without a per-row diff. engine_add_pod v18 is FROZEN. refill_settings.swaps_enabled stays false. Do NOT apply anything to prod until CS says apply.

PHASE 0 (Dara designs, Cody reviews, then build the migration files):
- coexistence_rules table encoding coexistence.md Rule 1 (TCCC exclusion at venue_group in ADDMIND,VOX) + Groups 1-7 matrix. Columns at least: rule_group, a_match (family_id or product_id or brand_owner), b_match, scope (machine|venue_group|all), rule_type (hard|soft).
- TCCC tag: add boonz_products.brand_owner (or tccc_portfolio bool); backfill every Coca-Cola Company brand from coexistence.md Rule 1 portfolio list. Leave a seed list + a query to verify coverage.

PHASE 1 (engine_swap_pod v11 -> v12, build migration file only):
- WS-1 eligibility filter applied BEFORE scoring: in v_wh_pickable; not already on machine; coexistence-clean vs on-machine products (TCCC, max-1-family soft->escalate, Groups 1-7); not travel-scope-locked away; slot not changed in 14 days; not HARD phase-out bias.
- WS-2 projected_score for candidates (no local history) = w2*sister_velocity(same location_type) + w1*global_velocity + w3*pearson_affinity, on the incumbent final_score scale. Start w2>w1>w3.
- WS-3 decision per slot: V(P,S,M)=margin*min(velocity*D, cap), cap=slot_capacity_max*0.85. Pick argmax of KEEP vs SWAP P* vs DOUBLE-DOWN W (+Redeploy(I) on the action options); must beat KEEP by theta; then rate limits (<=2/machine, fleet<=10, 14-day slot stability).

PHASE 2 (after Phase 1 applied + CS ok):
- WS-4 destination-aware REMOVE: tag redeploy_target=M* when displaced incumbent has a better home.
- DOUBLE-DOWN multi-facing per layout.md §6.

PER PHASE:
1. Reconcile field/column names in the PRD test queries against the real schema; fix mismatches before running.
2. REPLAY in BEGIN..ROLLBACK with swaps_enabled forced true. Run every conditional test in PRD §4 and print PASS/FAIL with the actual value.
   Phase 0+1 must pass: T1 T2 T3 T4 T5 T6 T7 T10 T11 T12 T13. Phase 2 must pass: T8 T9.
3. If ANY test FAILS: stop, report the failing assertion with its query output, do not apply, do not continue.
4. If ALL pass: STOP and show CS the full PASS table. Wait for explicit "apply phase N".
5. On green light: apply the migration(s), re-run the read-only confirms on prod, write results to docs/prds/PRD-037-EXECUTION-LOG.md, then STOP before the next phase.

HARD RULES
- Cody must verdict the coexistence_rules + brand_owner schema (Dara) and the engine_swap_pod v12 body before apply.
- T12 (ADD regression) and T7 (kill switch) are blocking: if engine_add_pod output changes at all, or swaps_enabled=false yields any Pass-3 swap, FAIL the whole phase.
- Never flip swaps_enabled in a committed migration. It stays false. Tests force it true only inside BEGIN..ROLLBACK.

FINAL REPORT: per phase - tests PASS/FAIL, applied y/n + timestamp, prod confirm. Restate open follow-ups (gross-profit margin upgrade; 70/30 as PRD-038; swaps_enabled stays OFF until Phase 3).
```
