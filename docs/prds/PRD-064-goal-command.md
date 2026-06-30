/goal PRD-064: assortment/variety refill signal for multi-SKU shelves. Sales don't record flavor (generic name, NULL boonz_product_id, all flavors share one slot), so the picker can't see that a multi-SKU shelf's loved high-share SKUs are gone while laggards remain. Recover per-SKU demand from the REFILL records (which DO carry SKU) + driver feedback, and add a share-weighted, capacity-ratio assortment floor to the urgency. Full spec: boonz-erp/docs/prds/PRD-064-assortment-variety-signal.md. MODE AUTO; STOP for CS before any apply (touches canonical v_machine_priority). DEPENDS ON PRD-063 (extends its urgency view).

CONTEXT (live eizcexopcuoycuosittm 2026-06-28): multi-SKU shelves collapse to ~1 SKU in stock between visits (Chocolate Bar 8 SKUs→1.5 in stock, Vitamin Well 7→1.0, Barebells 7→1.5, Zigi 7→0.6). refill_dispatching.boonz_product_id + packed/picked_up and refill_plan_output.boonz_product_name+quantity carry the SKU we load. product_mapping.split_pct carries intended mix per SKU (VW 5-50%, no nulls, heroes high / laggards low). v_driver_feedback_demand exists.

PRE: git pull --rebase main; branch feat/prd-064-assortment-signal. Fetch live view/fn bodies before editing.

BUILD (Dara → Cody → apply; forward-only):
WS-A v_sku_demand_from_refill: per (machine, SKU) consumption between visits = Σ(loaded from refill_dispatching picked_up/packed) − current per-SKU pod_inventory stock; accumulate to a per-SKU velocity proxy. Fold in v_driver_feedback_demand. Output per-(machine,SKU) demand. Directional only (POS lacks flavor).
WS-B1 v_shelf_assortment: per (machine, pod_product family): SKUs, intended share w_s=split_pct/100 NORMALIZED per machine×family to sum 1 (drop split_pct=0 placeholders), target_s=w_s×shelf_capacity, coverage_s=min(stock_s/target_s,1), assortment_health=Σ(w_s×coverage_s) [0..1], weakest high-share SKU. Reads product_mapping + pod_inventory + shelf capacity.
WS-B2 extend pick_urgency_params (PRD-063) with w_assortment, assortment_health_p2, assortment_min_capacity. Seed w_assortment so default is additive-zero / behavior-neutral.
WS-B3 v_machine_priority (PRD-063 body) consumes v_shelf_assortment: add s_assortment=100×(1−assortment_health) capped, gated to shelves ≥ min capacity, as a tunable-weighted urgency component (and/or P2 trigger when health<threshold). SHARE-WEIGHTED CAPACITY RATIO, never a raw SKU count.

TEST (all pass; STOP on fail):
T1 assortment_health drops sharply when a HIGH-share SKU is out vs a low-share one (verify Vitamin Well + Chocolate Bar).
T2 with w_assortment=0, v_machine_priority byte-identical to PRD-063 (golden; floor is additive+dialable).
T3 dial up surfaces variety-depleted multi-SKU shelves as P2/P1; p_score delta == param delta.
T4 split_pct normalized sums to 1 per machine×family; 0-share SKUs excluded.
T5 engine_add_pod/engine_swap_pod byte-identical; swaps_enabled false.

DATA CAVEATS (validate before trusting the floor): split_pct has zeros (exclude); mix_weight has a known normalization bug (use split_pct, ref bug_stitch_mix_weight_not_normalized); pod_inventory per-SKU Active may undercount post-PRD-059 (spot-check physical); WS-A proxy noisy where decrement assigns flavor-less sales heuristically.

CLOSE: update CHANGELOG.md, MIGRATIONS_REGISTRY.md, METRICS_REGISTRY.md (v_shelf_assortment, v_sku_demand_from_refill new objects; v_machine_priority gains assortment component); set PRD-064 status.

HARD SAFETY: depends on PRD-063 — do not apply standalone onto the OLD v_machine_priority. Default behavior-neutral (w_assortment=0; T2 golden gates deploy). Canonical Article-16 → Dara+Cody before apply; STOP for CS with before/after. engines byte-identical; swaps_enabled false. Forward-only; one-migration rollback; do NOT push to main without my explicit go-ahead.

OUT OF SCOPE: POS flavor capture (WEIMI dispense → sales_history.boonz_product_id) = the true long-term fix, separate ticket; procurement mix changes.
