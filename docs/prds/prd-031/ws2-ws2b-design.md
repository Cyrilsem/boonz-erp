# PRD-031 WS-2 + WS-2b — stitch off-shelf redistribution + scoped-authoritative mapping (Dara design, for Cody)

**Date:** 2026-06-14 · Layers on the live `stitch_pod_to_boonz` **v21** (md5 `52a6d3b139fc5cb5542ab733f848a01e`, PRD-024 split-normalization already in). Same two mapping CTEs WS-2 and WS-2b both touch.

## 0. WS-1 audit outcome (drives this design)

Live `product_mapping` already has **zero** `(pod,boonz,machine)` duplicates, the UNIQUE constraint already exists, and the "80 Red Bull rows" are 38 distinct per-machine scoped rows + global per SKU — not duplicates. So the Red Bull leak is **not** a dedup problem; it is the two stitch faults below.

## 1. The on-shelf signal (Dara decision)

"SKUs present on the target shelf" at boonz-variant granularity = distinct `boonz_product_id` in `v_pod_inventory_latest` for `(machine_id, shelf_id)` with `status='Active'`. `planogram` is pod-level only (no boonz) so it cannot constrain variants. Concrete: AMZ-1029 A14 `v_pod_inventory_latest` resolves to a single Red Bull variant; the pod maps to both Diet + Regular; today stitch fans ~80% to the off-shelf variant and drops it.

**Fallback:** when the shelf has NO active `v_pod_inventory_latest` row (genuinely empty / no snapshot), there is no boonz-variant signal — keep the full mapped set (current v21 behaviour), so an empty shelf is never starved. Off-shelf restriction only _narrows_ allocation when we positively know which variant(s) are on the shelf.

## 2. WS-2b — machine-scoped mapping is authoritative (the `pull_raw` join + the procurement `pm_per_row` join)

Live `pull_raw` join (the leak):

```
JOIN public.product_mapping pm
  ON pm.pod_product_id=a.pod_product_id AND pm.status='Active'
 AND (pm.machine_id IS NULL OR pm.machine_id=a.machine_id)   -- UNION of global + scoped
```

plus `ROW_NUMBER() PARTITION BY ...,pm.boonz_product_id ORDER BY (pm.machine_id=a.machine_id) DESC` and `pull = rnk=1` (per-SKU scoped-over-global). The union admits global-only SKUs onto curated machines.

**Change (set-level precedence):** gate global rows with NOT EXISTS on a scoped row for the same (pod, machine):

```
 AND ( pm.machine_id = a.machine_id
   OR (pm.machine_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.product_mapping pms
                       WHERE pms.pod_product_id = a.pod_product_id
                         AND pms.machine_id     = a.machine_id
                         AND pms.status='Active')) )
```

If any active scoped row exists for (pod, machine) → only scoped rows survive; else → global set. The existing ROW_NUMBER dedup stays (harmless once the set is correct; a machine never has two active scoped rows for the same boonz — UNIQUE constraint). Identical edit in the procurement/demand CTE (`pm_per_row`) which has the same `(pm.machine_id IS NULL OR pm.machine_id = prp.machine_id)` predicate, so the WH-demand alert math matches the emitted lines.

Verify: AMZ-1057 Snack Bar (scoped Delice+KitKat) → emits only Delice+KitKat, no global McVities/Oreo. AMZ-1068 (scoped McVities set) keeps its set. A machine with NO scoped Snack Bar mapping still gets the global set.

## 3. WS-2 — off-shelf redistribution (the normalization CTEs)

After WS-2b narrows the mapping set, add an `on_shelf` boolean to `pull_raw`:

```
, EXISTS (SELECT 1 FROM public.v_pod_inventory_latest pil
          WHERE pil.machine_id=a.machine_id AND pil.shelf_id=a.shelf_id
            AND pil.status='Active' AND pil.boonz_product_id=pm.boonz_product_id) AS on_shelf
```

and a per-(machine,shelf,pod) flag `shelf_has_known_variant = bool_or(on_shelf)` (windowed). Then in `pull_resid` change the residual-eligibility predicate so an absent variant is excluded from the residual pool **only when the shelf's variant set is known**:

```
is_residual_variant := (pin_qty = 0 AND COALESCE(split_pct,0) > 0
                        AND (on_shelf OR NOT shelf_has_known_variant))
```

The PRD-024 `pull_norm_pre.total_split` window already sums split only over `is_residual_variant`, so excluding off-shelf variants automatically renormalizes the remaining (on-shelf) variants to 1.0 and the largest-remainder distributor hands them the full `residual_pool`. **No unit is dropped; it redistributes to the on-shelf variants.** When the shelf variant set is unknown (empty inventory), `shelf_has_known_variant=false` → all mapped variants stay eligible → identical to v21. Same on-shelf narrowing mirrored in the deviation `m_raw/n` CTEs so the deviation "expected" matches emit.

Conservation (the WS-4 law, enforced as a hard invariant in WS-2): for each REFILL/ADD_NEW shelf-pod, `SUM(emitted variant_final) = pod_qty − genuine_wh_shortfall`, where genuine_wh_shortfall is only the units an on-shelf variant could not be filled because WH stock for that variant ran out (already surfaced as `[WH_WARNING]`/`wh_avail`). Off-shelf no longer contributes to shortfall.

## 4. Engine version + scope

`v21_ws5_real_stock` → `v22_onshelf_scoped`. Edits confined to: `pull_raw` (join predicate + on_shelf), `pull_norm_pre` (shelf_has_known_variant window), `pull_resid` (residual predicate), deviation `m_raw` (join predicate + on_shelf mirror), procurement `pm_per_row` (join predicate). Everything else (driver overlay, pin first-claim, largest-remainder, WH redistribution, REMOVE paths, real-stock emit) verbatim. Forward-only CREATE OR REPLACE, no `_v2`. >24h since the last stitch rewrite (PRD-024 06-12), so no Hard-Rule-10 gate.

## 5. Battery (rolled-back / non-live date — never regenerate a live plan)

- B-redbull: synthetic approved pod row, AMZ-1029 A14 Red Bull pod 6, shelf-variant = the single on-shelf Red Bull SKU, WH ample → emits 6 to that one SKU, 0 to the off-shelf variant, deviations 0.
- B-curated: AMZ-1057 Snack Bar pod row (scoped Delice+KitKat) → emits only Delice+KitKat. An uncurated machine with the same pod → global set still emitted.
- B-fallback: empty-inventory shelf → identical to v21 (no starvation).
- B-conservation: across a verification set, `SUM(variant_final)=pod_qty` (minus genuine WH shortfall only).
- B-procurement-match: demand-alert CTE consumes the same narrowed set (no global-SKU phantom demand on curated machines).
