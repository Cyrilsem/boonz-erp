/goal PRD-100: empty-shelf signal (per-shelf holes, not per-product runout). Spec: boonz-erp/docs/prds/PRD-100-empty-shelf-signal.md. MODE AUTO; STOP before any apply (canonical v_machine_priority). DEPENDS ON PRD-063.

PROBLEM: v_shelf_sales_identity is keyed on (machine_id, pod_product_id), so it pools stock across facings and an empty row is averaged away. Live: ACTIVATE-2005 carries Aquafina on 7 rows, 2 at ZERO, pooled 53u / 22.1 per day = 2.40 days > the 2-day horizon, so urgency 14.5 = P3_OK while two water rows on the fleet's fastest seller sit empty. An empty row fires P1 today only when the product has NO other facing (OMDCW, NISSAN: pooled DOS 0.00, both P1).

Do NOT fake a per-shelf runout or re-grain v_shelf_sales_identity: pooled DOS is the CORRECT runout metric. Emptiness is a SEPARATE, present-tense, per-shelf signal. Measure both.

PRE: git pull --rebase main; branch feat/prd-100-empty-shelf-signal; fetch live view bodies first.

BUILD (Dara -> Cody -> apply; forward-only):
WS1 extend pick_urgency_params (id=1): hole_frac 0.15, hole_wt_a/b/c/d 1.0/0.8/0.6/0.4, holes_norm 3, w_holes 0.30, p1_holes_min 2, p2_holes_min 1. Re-seed: w_runout 0.50->0.35, w_capacity 0.15->0.10, w_expiry 0.20->0.12, w_stale 0.15->0.13. Sum = 1.00.
WS2 new v_shelf_holes, grain = SHELF. Reads v_live_shelf_stock (enabled, not broken) joined to v_shelf_sales_identity for the product's velocity/grade ONLY. is_hole = current_stock = 0 OR current_stock / NULLIF(max_stock,0) <= hole_frac. Fraction of capacity, NEVER a flat count. Grade A >= 0.5/day, B >= 0.2, C > 0, D = dead. Emit is_hole, grade, hole_wt.
WS3 v_machine_priority (PRD-063 body): add s_holes = 100 * LEAST(1, SUM(hole_wt over holes)/holes_norm) to urgency at w_holes. Overrides: P1 if holes_a >= 1 OR holes_total >= p1_holes_min (2); P2 if holes_total >= 1. An empty DEAD row is a hole and gets FILLED, not routed to SWAP (CS: "2+ is severe, no need to swap just refill"). Expose holes_total/holes_a/b/c/d + reason tokens empty_hero_row, empty_rows_2plus, hole_row. KEEP all existing output columns (picker + get_machine_health).

TEST (all pass; STOP on fail):
T1 v_shelf_holes flags the 2 zero Aquafina rows on ACTIVATE-2005 + the third A-row under 15%; does NOT flag Fade Fit (8/8, 8/12).
T2 ACTIVATE-2005 becomes P1, reasons empty_hero_row + empty_rows_2plus.
T3 fleet sim: only 9 machines have any hole; 1 new P1 (ACTIVATE), 6 promoted P3->P2; OMDCW + NISSAN stay P1; MC-2004 / ALJLT-0200 / NOVO do NOT return to P1.
T4 GOLDEN: w_holes=0 + PRD-063 weights restored => v_machine_priority byte-identical to PRD-063 (additive + dialable).
T5 hole_frac is a ratio: 6-slot row w/ 2u NOT a hole, 25-slot row w/ 2u IS.
T6 full fleet < 800 ms. T7 engines byte-identical, swaps_enabled false. T8 single-row param guard holds.

CLOSE: update CHANGELOG + MIGRATIONS_REGISTRY + METRICS_REGISTRY (v_shelf_holes; v_machine_priority s_holes + hole cols + tokens; 8 new params); set PRD-100 status; update boonz-master-3 Stage-1 Picker row.

HARD SAFETY: do NOT apply onto the OLD (pre-063) v_machine_priority. The weight rebalance re-scores the WHOLE fleet, not just the 9 hole machines: give CS a full before/after tier table BEFORE apply, gated on the T4 golden. Article-16 canonical -> Dara + Cody first; STOP for CS with the diff. No DELETE/DROP/stock zeroing; one-migration rollback. Do NOT push to main without my explicit go-ahead. OUT OF SCOPE: per-facing velocity allocation (rejected), PRD-064 assortment (parked).
