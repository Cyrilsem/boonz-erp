# Claude Code /goal Command — PRD-010a

```
/goal Implement PRD-010a (v9.1 patch) for the boonz-erp Supabase backend. Read the PRD first: docs/prds/refill-pipeline/PRD-010a-swap-guard-shelf-fix-ac4-widen.md

Two changes in one migration file.

## Fix 1: engine_swap_pod — product-name match instead of shelf_code

The current v9 planned_swap guard in engine_swap_pod JOINs on shelf_code, but planned_swaps stores WEIMI-format codes (0-A06, 1-A04) while shelf_configurations uses logical codes (A06, B05). They never match for dual-cabinet machines.

Fix: Replace the shelf_code-based check with a product-name match. In the Pass 2 autonomous loop, when the engine is about to REMOVE a product from a shelf and ADD_NEW a Pearson substitute, check:

SELECT 1 FROM planned_swaps ps
WHERE ps.machine_id = <current_machine_id>
  AND ps.status = 'pending'
  AND ps.remove_pod_product_name = <name of the product currently on the shelf being swapped>

If found, skip this shelf (don't insert ADD_NEW or REMOVE). Log it in the pass2_skipped_planned_swap counter.

Find the existing shelf_code-based JOIN in the swap guard code and replace it with this product-name approach. The variable holding the current product's name should already be available in the loop context (it's the product being removed).

## Fix 2: engine_finalize_pod — widen capacity warning filter

Find the capacity_mismatch_warnings query in engine_finalize_pod. The high-velocity signal filter currently checks:

signal IN ('STAR', 'DOUBLE DOWN', 'KEEP GROWING')

Add 'KEEP' to the list:

signal IN ('STAR', 'DOUBLE DOWN', 'KEEP GROWING', 'KEEP')

This ensures products like Coca Cola Zero (signal=KEEP, v30=1.53, highest on its machine) trigger capacity warnings when stuck on small shelves.

## Output

Write one migration: supabase/migrations/YYYYMMDDHHMMSS_engine_v9_1_product_match_capacity_filter.sql

After writing, apply to prod (project eizcexopcuoycuosittm) and verify:
1. Rerun engine_swap_pod for plan_date=CURRENT_DATE+1 on MC-2004 — pass2_skipped_planned_swap should be >= 4 (the Plaay shelves)
2. Check engine_finalize_pod capacity_mismatch_warnings — MC-2004 Coca Cola Zero should appear
3. Show the migration diff before committing
```
