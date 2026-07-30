# /goal — PRD-106 Machine-Level Swap Recommendation

GOAL: Kill the per-shelf substitute picker. Build ONE machine-level swap recommender that returns K DISTINCT, warehouse-backed, in-machine-deduped swap-ins for a machine's K dead shelves. Read PRD-106-swap-machine-level-recommendation.md first. Supabase eizcexopcuoycuosittm. Cody review MANDATORY before apply (touches engine writer path).

WHY (incident 2026-07-28, MC-2004 plan 2026-07-29): find_substitutes_for_shelf returned the IDENTICAL ranked list for all 3 dead shelves; rank 1 = Coca Cola Mix, already live on the machine (A2+A4). Correlation is machine-grain, so per-shelf calls are noise. Also bug_swap_brain_within_machine_duplicate (Hunter A04 vs A10, 07-21) and RC-06 (engine_swap_pod hardcodes DEAD tags v15/v16 while add writes v18/v19 — substitution severed since 06-22).

BUILD:

1. New RPC public.recommend_swaps_for_machine(p_plan_date date, p_machine_id uuid, p_k int DEFAULT NULL) RETURNS TABLE(shelf_id, shelf_code, out_pod_product_id, out_pod_name, in_pod_product_id, in_pod_name, qty_suggested, rank_score, wh_available, rationale jsonb). K defaults to count of dead/swap-tagged shelves for that machine+plan_date.
2. Candidate universe: Active pod_products with Active product_mapping, MINUS (a) any pod_product on ANY shelf of the machine per latest weimi_aisle_snapshots (zero-pad A1→A01) — EXCEPTION: allow if engine_add_pod stance='DOUBLE DOWN' for its existing facing; (b) products under active decommission strategic_intent in scope; (c) slot-profile-incompatible per PRD-042 pools; (d) Evian 1L (never swap-in, standing rule); (e) VOX-sourced (venue_team) products on non-VOX machines.
3. wh_available: aggregate v_wh_pickable (fallback warehouse_inventory Active, warehouse_stock>0) by boonz_product_id FIRST, then map to pod grain. NEVER join product_mapping before aggregating — fan-out inflates ~10x (Red Bull 1599 vs real 39, observed 07-28). Respect machine's warehouse routing (from_warehouse resolution: VOX→WH_MM/WH_MCC, else CENTRAL).
4. rank_score = basket_corr (existing Pearson, min 0.3 with fallback tier) × ln(1+fleet_units_30d) × availability_factor (0 if wh_available < merchandising floor; boost if near-FEFO batch could dissolve). Expose components in rationale.
5. Assignment: rank shelves by shelf value (capacity × placement_mult desc), greedy-assign top DISTINCT candidates — no product repeated across the K rows. qty_suggested = min(shelf max_stock, wh_available).
6. Rewire engine_swap_pod to consume recommend_swaps_for_machine per machine instead of per-shelf find_substitutes_for_shelf. Keep find_substitutes_for_shelf for FE single-shelf UX but add p_exclude_in_machine boolean DEFAULT true.
7. Fix RC-06 in the same pass: DEAD-tag matching → source LIKE 'engine_add_pod%' (version-agnostic).
8. M2W is BANNED as an auto-outcome on dead shelves (CS rule 07-28): if no candidate clears the availability floor, emit qty-0 decision row reason='no_viable_swap_candidate' + procurement alert. Never write M2W, never auto-suppress.

GUARDRAILS: Read-only until Cody approves the migration. No raw DML on pod_refill_plan (RPCs only). Do not downgrade engine versions. Do not touch packed/dispatched rows. Test on a branch or with dry-run harness first.

ACCEPTANCE:

- MC-2004 replay (dead A11/B02/B03): 3 DISTINCT swap-ins, none already on machine, no Coca Cola Mix, all wh_available ≥ qty_suggested (deduped numbers).
- Zero blocked_no_wh at stitch for swap rows on a full-fleet dry run.
- Hunter scenario replay: no within-machine duplicate.
- engine_swap_pod resolves DEAD tags written by add v18/v19 (RC-06 gone).
- pgTAP or scripted asserts for: fan-out dedup, DOUBLE DOWN exception, distinct-K, decommission exclusion.
- EXECUTION-LOG written to boonz-erp/docs/prds/PRD-106-EXECUTION-LOG.md; Cody verdict recorded before apply.
