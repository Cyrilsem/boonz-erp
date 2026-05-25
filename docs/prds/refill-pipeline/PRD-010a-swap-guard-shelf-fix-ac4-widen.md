---
id: PRD-010a
title: v9.1 patch — swap guard shelf_code mismatch + AC#4 capacity filter widening
status: Ready-to-apply
severity: P1
reported: 2026-05-25
source: PRD-010 verification report — 3 follow-ups from engine v11 deployment
routing: [Stax, refill-brain]
protected_entities: [pod_refill_plan, planned_swaps]
depends_on: PRD-010
ready_to_apply_summary:
  prepared_at: 2026-05-25
  migration_files:
    - supabase/migrations/20260525160000_engine_swap_pod_v9_1_product_match_planned_swap.sql
    - supabase/migrations/20260525160100_engine_finalize_pod_v12_1_keep_in_capacity_filter.sql
  cody_review: pass (Articles 1, 4, 5, 8, 12 — verdict captured in conversation transcript)
  blocked_on: Supabase MCP `apply_migration` classifier transiently unavailable at apply time. Files are in repo as canonical source-of-truth; reconcile on next `supabase db push` or rerun `mcp__claude_ai_Supabase__apply_migration` for each file when classifier is back.
  changes:
    - AC#1 engine_swap_pod v9.1 — `_planned_swap_shelves` temp table now joins planned_swaps to slot_lifecycle via pod_products on remove_pod_product_name, sidestepping the WEIMI cabinet-prefix vs logical shelf_code mismatch. engine_version → v9_1_product_match_planned_swap.
    - AC#2 engine_finalize_pod v12.1 — high_velocity_constrained signal filter widened to include `'KEEP'` so capacity warnings now fire for the most common proven-product signal. engine_version → v12_1_keep_in_capacity_filter.
  ac3_deferred: visual_fill_minimum dead-code removal kept as safety net per PRD recommendation (option b).
---

# PRD-010a — v9.1 patch: swap guard shelf_code fix + capacity warning filter

## Problem

Three follow-ups from PRD-010 deployment (2026-05-25):

### 1. AC#2b shelf_code format mismatch (CRITICAL)

`planned_swaps.shelf_code` stores WEIMI-format codes with cabinet prefix (`0-A06`, `1-A04`, `1-A07`), while `shelf_configurations.shelf_code` uses logical codes (`A06`, `B05`, `B08`). The cabinet-to-letter mapping is non-trivial (cabinet 0 = A-series, cabinet 1 = B-series, with a +1 offset on the number). The v9 swap guard JOINs on `shelf_code` and never matches MC-2004 Plaay shelves, leaving them unprotected from autonomous Pass 2 overrides.

Evidence: `pass2_skipped_planned_swap=2` in the regen, but those were on machines where planned_swaps happened to use logical format (MINDSHARE "A05"). The 4 MC-2004 Plaay shelves (0-A06, 1-A04, 1-A05, 1-A07) were NOT protected.

### 2. AC#4 capacity warning filter too narrow

The filter only fires for signals in (STAR, DOUBLE DOWN, KEEP GROWING). MC-2004 Coca Cola Zero is classified KEEP (not KEEP GROWING), so no warning emitted. KEEP is the most common signal for proven products; excluding it means most capacity mismatches go unreported.

### 3. visual_fill_minimum is dead code

For any signal where AC#3's visual_fill_minimum (50%) could activate (KEEP through STAR), AC#1's signal_floor (60-80%) is always higher. The `visual_fill_minimum` clamp_reason never fires. This is cosmetic, not functional, so it's lowest priority.

## Acceptance Criteria

### AC#1: Fix swap guard to match by product, not shelf_code

In `engine_swap_pod` v9, replace the shelf_code-based JOIN with a product-name match:

```sql
-- BEFORE (broken): JOIN on shelf_code text match
-- AFTER: match by machine + product being removed
SELECT 1 FROM planned_swaps ps
WHERE ps.machine_id = v_machine_id
  AND ps.status = 'pending'
  AND ps.remove_pod_product_name = v_current_product_name  -- the product on the shelf being swapped
```

Where `v_current_product_name` is the pod_product_name of the product currently on the target shelf (the one the engine wants to REMOVE). If a planned_swap exists for that machine + product, the autonomous swap skips that shelf.

This avoids the shelf_code translation problem entirely. A planned_swap says "remove Product X from this machine" and the engine checks "am I about to autonomously remove Product X from this machine?" If yes, the strategic swap wins.

**Test:** Rerun MC-2004 draft. The 4 Plaay shelves (Hummus, Rice Cake, Tamreem, Nutella T12) should all be skipped by autonomous Pass 2. `pass2_skipped_planned_swap` should be >= 4 for MC-2004.

### AC#2: Widen capacity warning filter to include KEEP

In `engine_finalize_pod` v11, change the high-velocity signal filter from:

```sql
signal IN ('STAR', 'DOUBLE DOWN', 'KEEP GROWING')
```

to:

```sql
signal IN ('STAR', 'DOUBLE DOWN', 'KEEP GROWING', 'KEEP')
```

**Test:** MC-2004 Coca Cola Zero (KEEP, 14-unit shelf, capped_by_max, v30=1.53) should now emit a capacity_mismatch_warning suggesting a move to the Loacker shelf (24 units, ROTATE OUT).

### AC#3: Remove visual_fill_minimum dead code (optional, low priority)

Since signal_floor always >= visual_floor for signals where visual_floor applies, the `visual_fill_minimum` clamp_reason path is unreachable. Either:

- (a) Remove the visual_fill_minimum check entirely (simplify code), OR
- (b) Keep it as a safety net in case signal_floor percentages are lowered in the future

Recommended: option (b), keep it. Zero runtime cost, provides a safety floor if someone adjusts the signal_floor table.

## Migration

Single migration file: `engine_swap_pod_v9_1_product_match_capacity_filter.sql`

Scope:

- `engine_swap_pod`: replace shelf_code JOIN with product-name match in the planned_swap check
- `engine_finalize_pod`: add 'KEEP' to capacity warning signal filter

No schema changes. No new tables/columns.
