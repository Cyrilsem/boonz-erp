---
id: PRD-013-refill-pipeline
program: PROGRAM-2026-05-25
title: Engine FEFO — investigate why Inactive product was planned
status: Investigation-Done-fix-pending-CS-approval
investigation_done_at: 2026-05-30
investigation_summary: |
  Two distinct sub-bugs identified, NOT the single V3 hypothesis.
  Bug A: VOX-sourced products planned through WH path at VOX venues
  (engine ignores venue_group + canonical VOX list).
  Bug B: Variant-assignment loop does not subtract prior allocations
  within the same plan run, causing engine to plan 4x what WH can supply.
  See "Findings 2026-05-26" section. Proposed fixes documented but NOT
  shipped per program rule 8 — engine is hot path, needs CS approval +
  parallel dry-run validation before any change.
severity: P0
reported: 2026-05-25
source: PROGRAM-2026-05-25 Phase 1 P0 #2 (semantic name PRD-004-refill-pipeline)
routing: [Cody]
---

## V3 finding nuance (verified live 2026-05-25)

Original V3 hypothesis: "Engine FEFO filter is not applying
`status='Active' AND warehouse_stock>0`."

Verified false. The engine `auto_generate_refill_plan` already filters:

```sql
WHERE wi.status='Active' AND wi.warehouse_id=v_machine.primary_warehouse_id
  AND wi.warehouse_stock>=1
  AND (wi.expiration_date IS NULL OR wi.expiration_date>v_plan_date+7)
```

Same predicate is present in both the swap-candidate and the
REFILL variant-assignment loops. So why did Vitamin Well Care get planned?

## Live state observed

- All 6 `warehouse_inventory` rows for Vitamin Well Care at WH_CENTRAL are
  `status='Inactive'`, `warehouse_stock=0`.
- 14 `refill_dispatching` rows for Vitamin Well Care in 2026-05-20..25
  range — of these, ~5 are engine-generated (`item_added=false`) and the
  rest are manual driver/operator additions (`item_added=true`).
- Engine-generated rows all have `from_wh_inventory_id=NULL` AND
  `expiry_date=NULL` — the same stitch-v12 NULL-bind pattern from V1.

## Hypotheses to investigate

1. **Snapshot/timing race:** WH state at plan-generation time was Active,
   then became Inactive after the plan was published. Check
   `inventory_audit_log` for status flips on these wh_inventory_ids in the
   plan-publish window.
2. **NULL-bind bypass:** The engine's variant-assignment loop reads from
   `warehouse_inventory` directly with the right filter, BUT `push_plan_to_dispatch`
   inserts rows without pinning to a specific `wh_inventory_id` — only
   `from_warehouse_id`. So even though the engine found "0 viable
   variants" (no_stock alert), the dispatch row got created anyway
   somewhere else.
3. **Manual add then engine merge:** The dispatching FE allows manual
   additions; if a manual Vitamin Well Care row exists for a machine, the
   engine might be detecting it via `v_live_shelf_stock` and trying to
   refill it.

## Proposed instrumentation (Phase 1)

Before any migration, run these audits and report back:

```sql
-- Was Vitamin Well Care ever Active at WH_CENTRAL in last 30 days?
SELECT audit_id, wh_inventory_id, old_status, new_status, occurred_at,
       rpc_name, actor_role
FROM warehouse_inventory_status_history -- or audit table that tracks status
WHERE wh_inventory_id IN (
  'bd8d6efd-9dbb-4f34-8e75-890ddd1c032d','bc9949f0-e9e1-4a07-83f1-ca6b665a218c',
  'a360e19e-e3ad-4ff5-b0a7-d2db1bd945e6','a121fb5b-5cc1-4090-84ab-2c6176db2a16',
  '49056649-5592-410b-bf03-577dad6a7bca','feb87f4d-fa8e-4e37-9b78-141274ffefc7'
)
ORDER BY occurred_at DESC;
```

## Proposed fix (Phase 2 — pending Phase 1 result)

- If hypothesis 1: harden the engine to re-validate stock at
  `push_plan_to_dispatch` time, refusing to push rows whose variant no
  longer has Active stock.
- If hypothesis 2: hard-block `push_plan_to_dispatch` from emitting rows
  with NULL `from_wh_inventory_id` for Refill/Add New actions — require
  the FEFO pin at push time (the V1 fix from PRD-011).
- If hypothesis 3: tighten `v_live_shelf_stock` to exclude manual-add rows
  that have no corresponding WH stock.

## Why this PRD is "Needs-investigation" not "Ready-to-ship"

V3 was assumed to be a missing filter. The filter is present. The bug is
real but the root cause is elsewhere. Phase 1 instrumentation must run
first — under CS supervision because the audit query touches large tables.

## Linked

- [[PRD-011-refill-pipeline]] — packing FE NULL-bind fix; shares root
  cause hypothesis 2.
- [[project_engine_v10_stitch_v12_decouple]] — the WH-decouple work whose
  side effects are felt here.

---

## Findings 2026-05-26 — autonomous investigation run

Ran the two diagnostic queries from PROGRAM-2026-05-26 Phase 3 against
prod live. Two **distinct** sub-bugs surface; the original V3 single-cause
framing was incomplete.

### Pattern 1 hits — engine planned product whose WH is 100% Inactive

> =90 rows in 2026-05-19..23 window. Top offenders:

- **Aquafina - Regular** — planned at IFLYMCC, MPMCC, ACTIVATE, ACTIVATEMCC
  (multiple times each on 19-May). VOX-sourced product, should never have
  been engine-planned through WH at VOX venues.
- **Vitamin Well - Care / Antioxidant / Hydrate** — planned 5-10x per day
  across AMZ, OMDBB, NOVO, VML, NISSAN. All warehouse_inventory rows for
  Vitamin Well are Inactive (no new procurement since Q1).
- **Barebells - Cookies And Cream / White Almond Chocolate / Cookies and Caramel**
  — variants where the WH variant has been depleted but the engine kept
  planning siblings.
- **Be-kind Bar - Peanut Butter / Almond & Sea Salt** — same pattern.
- **Healthy Cola, Pocari Sweat, Zigi** — products with one historical
  batch that's long gone.
- **Ice Tea - Peach** — at VOX/OMDCW/USH/IFLY — again VOX-sourced.
- **Fade Fit - Peanut Butter / Hazelnut / Salted Caramel** — VOX-sourced.

### Pattern 2 hits — engine planned more than total Active WH

Top shortfalls (planned > available_at_now):

| product                  | plan_date  | planned | wh_active_now | shortfall |
| ------------------------ | ---------- | ------- | ------------- | --------- |
| Aquafina - Regular       | 2026-05-19 | 80      | 0             | 80        |
| Evian - Regular          | 2026-05-21 | 30      | 0             | 30        |
| Coca Cola - Regular      | 2026-05-20 | 29      | 0             | 29        |
| Nutella - Biscuit T12    | 2026-05-21 | 32      | 3             | 29        |
| Ice Tea - Peach          | 2026-05-19 | 28      | 0             | 28        |
| Evian - Regular          | 2026-05-19 | 24      | 0             | 24        |
| Zigi - Honey Mustard     | 2026-05-20 | 24      | 0             | 24        |
| Bounty - Regular         | 2026-05-21 | 18      | 0             | 18        |
| Kinder Bueno - Hazelnut  | 2026-05-21 | 16      | 0             | 16        |
| M&M - Chocolate Nuts     | 2026-05-21 | 15      | 0             | 15        |
| Ice Tea - Peach          | 2026-05-21 | 13      | 0             | 13        |
| Barebells - Creamy Crisp | 2026-05-19 | 12      | 0             | 12        |
| ... (60+ more rows)      |            |         |               |           |

### Root cause analysis — two distinct bugs

**Bug A: VOX-sourced products being planned through WH path.**

Per [[reference_vox_sourced_products]] the canonical 9-product VOX list is:
Pepsi, Ice Tea, M&M Bags, Aquafina, Maltesers, Fade Fit, Chocolate Bar,
Skittles Bag, Soft Drinks Mix (7up). For machines in VOX venues
(VOX-_, IFLY_, ACTIVATE*, MP*) these products should:

- Be planned with `source_origin='vox_at_venue'` at plan-write time
- Skip the WH stock check entirely
- Skip the WH debit at pack time

The engine `auto_generate_refill_plan` does NOT consult venue_group or
the VOX product list when filtering candidates. It treats every product
identically — Active WH stock required. This means VOX venues planning
Aquafina/Ice Tea get the `no_stock` alert and fall through to the dispatch
row creation anyway (V1 NULL-bind class) — `from_wh_inventory_id=NULL`,
expiry blank, packing FE breaks. mark_dispatch_vox_sourced was created to
mop up but the engine never tags them in the first place.

**Bug B: Engine reads a stale snapshot for non-VOX products.**

For Vitamin Well, Barebells, Be-kind, Bounty, Kinder Bueno, Nutella,
Smart Gourmet, etc., the engine planned more than the Active WH could
satisfy. Without seeing engine internals at plan-time vs verification at
push-time, two hypotheses:

1. **Engine plans first, dispatches later, no re-check.** The
   auto_generate_refill_plan SELECT against warehouse_inventory happens
   at plan generation. If hours pass before `push_plan_to_dispatch` runs,
   other dispatches may have consumed the stock.
2. **Engine plans across multiple machines using same total**
   without subtracting prior allocations. The variant-assignment loop
   inside `auto_generate_refill_plan` runs per slot per machine, but the
   SUM(warehouse_stock) computed per variant does NOT decrement as
   previous machines in the same plan run claim units. So the engine can
   plan 5+5+5+5 = 20 units of Vitamin Well Care across 4 machines when
   only 8 units are available.

Hypothesis 2 is more likely given how concentrated the shortfalls are
on the same product within a single plan_date.

### Proposed fix (DO NOT SHIP without CS approval per program rule)

**For Bug A:**

```sql
-- New CTE in auto_generate_refill_plan that joins venue_group + VOX list:
WITH vox_sourced_at_venue AS (
  SELECT m.machine_id, bp.product_id AS boonz_product_id
  FROM machines m
  CROSS JOIN reference_vox_sourced_products v
  JOIN boonz_products bp ON bp.boonz_product_name ILIKE v.product_pattern
  WHERE LOWER(m.venue_group) LIKE '%vox%'
     OR m.venue_group ILIKE '%ifly%'
     OR m.venue_group ILIKE '%magic planet%'
     OR m.venue_group ILIKE '%activate%'
)
-- In the variant-assignment loop, if (machine_id, boonz_product_id) is in
-- vox_sourced_at_venue, write the plan row with source_origin='vox_at_venue'
-- AND skip the WH stock check, AND skip the variant-assignment loop entirely.
```

Prerequisite: a `reference_vox_sourced_products` table to hold the canonical
9-product list. Currently this is in memory only.

**For Bug B:**

Add a running tally inside the FOR machine LOOP:

```sql
DECLARE
  v_allocated_so_far_per_product hstore := hstore('');
BEGIN
  ...
  FOR v_variant IN (
    SELECT wi.boonz_product_id,
           SUM(wi.warehouse_stock)::int AS total_stock,
           MIN(wi.expiration_date) AS earliest_expiry
    FROM warehouse_inventory wi
    WHERE wi.status='Active' AND wi.warehouse_id = v_machine.primary_warehouse_id
      AND wi.warehouse_stock >= 1
      AND (wi.expiration_date IS NULL OR wi.expiration_date > v_plan_date+7)
    GROUP BY wi.boonz_product_id
  ) LOOP
    -- Subtract what was already allocated this plan run
    v_remaining_supply := v_variant.total_stock
      - COALESCE((v_allocated_so_far_per_product -> v_variant.boonz_product_id::text)::int, 0);
    IF v_remaining_supply <= 0 THEN CONTINUE; END IF;
    ...
    -- After deciding allocation v_alloc:
    v_allocated_so_far_per_product := v_allocated_so_far_per_product
      || hstore(v_variant.boonz_product_id::text,
                (COALESCE(...)::int + v_alloc)::text);
  END LOOP;
END;
```

### Risk

Engine code is hot path. Any change blocks every refill cycle. **Do NOT
ship without CS approval and a parallel-dry-run validation**: run the
patched function in dry-run for 3 days, diff against the current engine's
output, confirm shortfalls drop to zero for non-VOX and that VOX
products are correctly tagged.

### Status

Investigation complete. Proposed fix documented. NOT shipped per program
rule 8 (production verification gate requires CS approval for engine
changes). Hand off to CS for design call.
