# PRD-040 Track B — Backend Hygiene: designs, plans, CS-decision gates

**Status:** Designs + plans. NOTHING applied. Each item: Dara design -> Cody verdict -> BEGIN..ROLLBACK replay -> STOP for CS apply. B2 and B3 have a CS DECISION gate BEFORE replay (family map / cost source). `swaps_enabled` stays false; `engine_add_pod` stays byte-identical unless B3 explicitly changes its margin source (then T12 re-baselined with CS sign-off).

---

## B1 — Affinity metric (Article 16) + find_substitutes convergence PLAN

**Done (doc):** Registered "Candidate basket affinity (Pearson co-purchase)" in `METRICS_REGISTRY.md` with canonical object `get_candidate_affinity(machine, cand_pod)` (PRD-039 P0, live).

**Convergence PLAN (do NOT execute here; one behaviour-diffed pass, Cody-verdicted before apply):**

- Today `find_substitutes_for_shelf` computes `basket_corr` inline = the SAME math as `get_candidate_affinity` (per-machine `correlation_pod_per_machine`, loc-type fallback, averaged over the velocity>0 basket). Dual definition = the exact Article-16 disease.
- **Target:** `find_substitutes_for_shelf` calls `public.get_candidate_affinity(p_machine_id, c.cand)` in place of its inline `basket_corr` subquery. Single source of the affinity number.
- **Risk:** `find_substitutes` is a hot path (called per dead/rotate shelf in `engine_swap_pod` Pass-1/dead-tag). A per-candidate scalar call could regress performance vs the current set-based subquery. Mitigation: keep `find_substitutes` set-based by joining a `LATERAL get_candidate_affinity` only over its already-shortlisted candidates (small N per shelf), OR inline-but-reference: extract the basket-corr CTE so both share one SQL fragment. Decide at build time which keeps `find_substitutes` output byte-identical AND non-regressed.
- **Behaviour-diff replay (the ONE pass):** for every (machine, anchor) pair exercised by the live dead-tag path on a gate-clean date, assert `find_substitutes_for_shelf(...)` output (rank, pod_product_id, pearson_score, source) is byte-identical before/after the convergence. Zero diff is the acceptance bar. Do NOT half-migrate (PRD-039/028 lesson: half-migrating WH/affinity re-introduces line/alert disagreement).
- **engine_swap_pod v13:** its Pass-3 set-based affinity mirror stays (performance); document it as the vectorized equivalent of the canonical scalar. Reconcile (single SQL fragment shared by helper + engine + find_substitutes) at this convergence, not before.
- **Cody:** verdict the convergence migration (class b/c, read-only) before apply. STOP for CS.

---

## B2 — product_family_id backfill (0/307) + Rule 2 family-keying

**Grounding (live):** `boonz_products.product_family_id` = 0/307. BUT `pod_products.product_family_id` = 112 set, and **218/307 boonz products inherit a family via an Active `product_mapping` -> `pod_products`**. Family infra already exists: tables `product_families`, `curated_product_families`, view `v_product_family_members`. `coexistence_rules` Rule 2 (max-1-per-family) is currently **brand-proxied** (`a_match_type='product_brand'`).

### Design (Dara)

1. **Source the family from the existing taxonomy**, do not invent a new one: backfill `boonz_products.product_family_id` from the mapped `pod_products.product_family_id` (the dominant family across Active mappings; tie-break by mix_weight then most-recent). Covers 218/307 deterministically.
2. **The 89 uncovered:** fall back to a family derived from `curated_product_families`/brand grouping, OR leave NULL and let Rule 2 keep using the brand proxy for those only (hybrid). CS picks (decision below).
3. **Backfill is a forward UPDATE** of `boonz_products.product_family_id` (a new/existing column; confirm it is a real column + FK to `product_families`). No deletes; supersede-only. Cody verdict (writes a protected-entity column).
4. **Flip Rule 2:** add/replace the `coexistence_rules` Rule 2 rows to match on `family_id` (`a_match_type='product_family_id'`) instead of `product_brand`. `_coexistence_blocks` already reads `coexistence_rules`; confirm it resolves the new match_type (may need a small forward `CREATE OR REPLACE` of the helper to compare family ids — behaviour-diff replay required: same machine baskets, assert no NEW blocks except the intended family-true ones, no LOST brand blocks that were correct).

### CS DECISION GATE (before ANY write) — show the family map

Before backfilling, produce and present the full `(boonz_product, proposed family_id, family_name, source: pod-inherited|brand-fallback|manual)` map for CS approval. **No write until CS approves the map.** Decision needed:

- **D-B2a:** for the 89 not pod-inherited, use brand-fallback families, or leave NULL (Rule 2 stays brand-proxied for those)?

### Replay (after CS approves map)

- Backfill in BEGIN..ROLLBACK; assert 218 (or 218+fallback) families set, 0 FK violations.
- Rule 2 flip: replay `_coexistence_blocks` over current machine baskets before/after; print added/removed blocks; assert the delta is exactly the intended family-vs-brand reclassification (CS reviews the delta list).

---

## B3 — True gross-profit margin source (value-model-affecting)

**Grounding (live):** `avg_30days_cost` is NULL/0 for **90/307**. A best-available-cost coalesce chain `COALESCE(avg_30days_cost, avg_cost, AVG(product_mapping.avg_cost), AVG(pod_products.purchasing_cost))` reaches **249/307** (fills 32 of the 90); **58 still costless**.

### Design (Dara)

1. **Define a canonical cost source** as a read-only object `get_product_landed_cost(boonz_product_id)` (or a view `v_product_cost`) = the coalesce chain above, optionally extended with `supplier_products` landed cost. ONE object; the engine consumes it (Article 16 friendly). Margin = `price - landed_cost`.
2. **engine_swap_pod V():** replace the inline `price - avg_30days_cost` with `price - get_product_landed_cost(...)` for BOTH the incumbent KEEP cap and candidate margin. This is **value-model-affecting** -> full replay required.
3. **engine_add_pod:** PRD-035 made ADD qty STANCE-FREE and velocity-driven; it does NOT consume margin for qty (margin is display/advisory). CONFIRM via the live v18 body before touching it. If v18 does not consume margin, **engine_add_pod stays byte-identical (T12 holds)** and B3 touches only `engine_swap_pod`. If it does, T12 must be re-baselined with CS sign-off (hard rule).
4. **The 58 still-costless:** the value model already does `GREATEST(margin,0)` so a costless product gets `margin = price - 0 = price` (over-credited) OR `margin = 0` if we treat missing-cost as exclude. CS decides (below) — this materially changes which products win swaps.

### CS DECISION GATE (before replay) — cost source + missing-cost policy

- **D-B3a:** canonical cost = the 4-source coalesce chain (249/307), or extend with `supplier_products` to chase the last 58?
- **D-B3b:** for products with no cost at all, treat margin as (i) `price - 0 = price` (current behavior, over-credits costless SKUs), (ii) `0` (costless SKUs never win a swap), or (iii) a category-median cost imputation? This changes swap outcomes.

### Replay (after CS decisions) — FULL, value-model-affecting

- Re-run PRD-039 U1/U2/C1/C2/A1/A2/H1 + R1 AND PRD-037 T1-T13 in BEGIN..ROLLBACK on the gate-clean date, swaps forced true, with the new margin source. Print PASS/FAIL + the swap-set delta vs the avg_30days_cost baseline (which swaps changed because cost coverage improved). Cody verdict the engine_swap_pod V() rewrite. STOP for CS apply.

---

## B4 — Stitch WH-read unification (one behaviour-diffed migration)

**Grounding (METRICS_REGISTRY TODO, PRD-035 A):** `stitch_pod_to_boonz` reads WH inline in **4 places** — `pull_overlaid.wh_avail_variant`, `pull_with_wh`, the alert `supply` CTE, and `diag` — using `Active + stock>0 + not-quarantined` but WITHOUT the in-date filter that canonical `v_wh_pickable` applies. Half-migrating re-introduces line/alert disagreement.

### Design (Dara) + replay PLAN

1. **One forward `CREATE OR REPLACE` of `stitch_pod_to_boonz`** that replaces ALL FOUR inline WH reads with reads of `v_wh_pickable` (batch grain; Active, not-quarantined, in-date Dubai-or-NULL, stock>0), aggregated per (boonz, serving WH, reservation-aware) identically to today EXCEPT the intended in-date exclusion now applies uniformly.
2. **Reservation handling:** preserve the existing per-machine reservation netting (reserved-to-this-machine-or-unreserved) on top of `v_wh_pickable` — `v_wh_pickable` exposes `reserved_for_machine_id`, so the netting moves onto it.
3. **Behaviour-diff replay (the acceptance bar):** run `stitch_pod_to_boonz(plan_date, dry-run/false)` before and after on a gate-clean date in BEGIN..ROLLBACK; capture the LINE output (`pod_refill_plan` variant resolution) and the ALERT output. Assert: the ONLY differences are rows where a WH batch is expired-but-Active (the intended in-date exclusion) — every such diff must be a line/alert that SHOULD have excluded that batch. Zero unintended diffs. Print the diff list for CS.
4. **Cody** verdict the stitch rewrite (class b writer) before apply. STOP for CS.

> Stitch is a large function; this item is scoped as ONE migration (no partial). The replay must prove line AND alert parity-except-in-date, because the whole point of the metric registry note is that half-migrating splits line vs alert.

---

## Decision summary needed from CS (gates the rest of Track B)

- **D-B2a** family fallback for the 89 non-pod-inherited products.
- **D-B3a** canonical cost source breadth (4-source vs +supplier_products).
- **D-B3b** missing-cost margin policy (price / 0 / imputed).

Once decided, the order is: B1 convergence (independent) -> B2 (map approval -> backfill -> Rule 2) -> B4 (stitch unify) -> B3 (margin, full value-model replay). Each STOPs for its own "apply <item>".

## Parked

- 70/30 core-flex = PRD-038. Phase-3 enable = Track D runbook (supervised cycles).

---

## B4 + B3-part2 — exact build specs (replay-validated; mechanical rewrite pending)

### B4 surgical sites (stitch_pod_to_boonz, 39KB / ~750 lines)

The 4 inline WH reads to repoint onto `v_wh_pickable` (each currently `SUM(wi.warehouse_stock) FROM warehouse_inventory wi WHERE ... status='Active' ... quarantined=false`, NO in-date):

- **#1 pull_overlaid.wh_avail_variant** — lines ~150-153.
- **#2 pull_with_wh** — the with-WH variant pull (same predicate shape).
- **#3 alert supply CTE** — lines ~530-537 (`... quarantined=false) = 0` zero-WH alert).
- **#4 diag** — lines ~747-749 (`FROM warehouse_inventory wi ... quarantined=false`).
  Replace each with a read of `public.v_wh_pickable vp` (Active + not-quarantined + in-date Dubai-or-NULL + stock>0), preserving the per-machine reservation netting (`vp.reserved_for_machine_id IS NULL OR = machine`). ONE migration, all 4 in one pass (no half-migrate).
  **Behaviour proof (data-level, validated):** inline-predicate vs v_wh_pickable availability per (boonz, warehouse) = 119=119, 0 pairs differ, 0 units dropped (0 expired-but-Active batches today). The in-date exclusion is forward-looking, currently a no-op.
  **Remaining at build:** author the full CREATE OR REPLACE with the 4 edits; run `stitch_pod_to_boonz(plan_date, true)` (dry-run) before/after in BEGIN..ROLLBACK and assert LINE + ALERT outputs are byte-identical (0 expired batches today => must be 0 diff). Cody body-level verdict. Then "apply B4".

### B3-part2 (engine_swap_pod V() consumes landed cost)

- In the Pass-3 candidate margin AND the incumbent KEEP cap, replace `price - boonz_products.avg_30days_cost` with `price - public.v_product_landed_cost.landed_cost` (join on boonz_product_id). `v_product_landed_cost` is B3-part1 (built, 307/307).
- engine_add_pod UNTOUCHED (confirm v18 body does not reference avg_30days_cost for qty -> T12 holds).
- **Remaining at build:** forward CREATE OR REPLACE on canonical engine_swap_pod; full value-model replay PRD-039 U1/U2/C1/C2/A1/A2/H1 + R1 and PRD-037 T1-T13 (swaps forced true, gate-clean date) with PASS/FAIL + the swap-set delta vs the avg_30days_cost baseline (which swaps changed because cost coverage went 217->307). Cody body-level verdict. Then "apply B3-part2".

Both are deliberately left as mechanical-rewrite-plus-replay steps (not transcribed mid-session) to keep the core-function edits replay-verified rather than rushed.
