# APPLY_ORDER — Batch 1 (RC-01 + RC-08) — apply-ready, NOT applied

**Project:** `eizcexopcuoycuosittm` · **Date:** 2026-07-18 · **Author:** DARA
All verification below is **read-only / body-inspection / predictive** — NO engine run,
NO approve executed. Nothing here is applied by DARA.

---

## 0. The two windows

| Window | Files | Atomic? | When |
| --- | --- | --- | --- |
| **W1 — ATOMIC (B5)** | `20260718090001_rc08a_…` → `20260718090002_rc01_…` (→ `20260718090003_rc08b_…` recommended same window) | **A and RC-01 MUST land together, A first.** push's pin does not switch off inline logic until `wh_fefo_for_line` exists. | **OFF-PEAK ONLY** (B4): never during the 8pm Dubai engine, never during a field packing window. |
| **W2 — PHASE 2, CS-GATED (S1)** | `20260718093000_rc08_consumer_cutover_stitch_warnonly.sql` | No. Separate, later. | Only after CS reviews the plan-vs-route-fill delta. Warn-only; never reduces published qty. The file has a hard guard that RAISES until a human removes it. |

**Ordering rule:** A defines `wh_fefo_for_line`; RC-01's `push` binds it. Apply A, then
RC-01, in the same transaction window. B (propagation + literals) may ride the same
window (recommended, so `from_warehouse_id` propagation and the credit-target fix land
together) or immediately after; it is not part of the pin-atomicity requirement.

---

## 1. PRE-APPLY (run first; abort on any failure)

### 1a. Off-peak confirmation (B4)
Confirm the engine is not mid-run and no machine is in a packing window. The index in
RC-01 is **non-concurrent inline** — brief ACCESS EXCLUSIVE on `refill_dispatching`.

### 1b. **MANDATORY** partial-index 0-collision re-verify (B4)
```sql
SELECT count(*) AS colliding_groups, COALESCE(max(c),0) AS max_multiplicity
FROM (
  SELECT dispatch_date, machine_id, shelf_id, boonz_product_id, action, count(*) c
  FROM public.refill_dispatching
  WHERE include=true AND action IN ('Refill','Add New')
    AND COALESCE(filled_quantity,0)=0
    AND packed=false AND item_added=false AND returned=false
    AND skipped=false AND cancelled=false AND created_by_edit=false AND is_m2m=false
  GROUP BY 1,2,3,4,5 HAVING count(*)>1
) g;
```
**Gate:** `colliding_groups=0` AND `max_multiplicity=0`. If >0 → STOP, clean data first.
Last DARA run 2026-07-18: **0 / 0.** ✅

### 1c. RC-08-A dependency exists for RC-01 (B5)
After applying A and BEFORE relying on RC-01's pin, confirm the signature:
```sql
SELECT to_regprocedure('public.wh_fefo_for_line(uuid,uuid,date,numeric,uuid[])') IS NOT NULL AS ok;  -- expect true
```

### 1d. Literal inventory baseline (B3)
```sql
SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.prosrc LIKE '%4bebef68-9e36-4a5c-9c2c-142f8dbdae85%'
ORDER BY 1;
```
Expect the 9 sites (incl. `approve_refill_plan`). 2026-07-18: approve_refill_plan,
auto_generate_refill_plan, bind_dispatch_fefo, inject_swap, pack_dispatch_line,
receive_dispatch_line, receive_purchase_order, return_dispatch_line, set_machine_warehouse.

---

## 2. APPLY (W1, in order)

1. `20260718090001_rc08a_canonical_wh_availability.sql`
2. `20260718090002_rc01_single_writer_bridge.sql`
3. `20260718090003_rc08b_dispatch_wh_propagation_literals.sql`  *(recommended same window)*

Do **not** apply `20260718093000_…` here (PHASE 2).

---

## 3. POST-APPLY verification (read-only; no engine run)

### 3a. Body inspection — RC-01 single writer
```sql
SELECT
  (pg_get_functiondef('public.approve_refill_plan(date,text[])'::regprocedure) NOT LIKE '%DELETE FROM refill_dispatching%') AS approve_no_delete,             -- expect true
  (pg_get_functiondef('public.approve_refill_plan(date,text[])'::regprocedure) NOT LIKE '%4bebef68%') AS approve_no_literal,                                  -- expect true (B3)
  (pg_get_functiondef('public.approve_refill_plan(date,text[])'::regprocedure) LIKE '%rpc_name%approve_refill_plan%') AS approve_restamps,                     -- expect true
  (pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure) LIKE '%wh_fefo_for_line%') AS push_binds_canonical,                            -- expect true
  (pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure) LIKE '%ON CONFLICT%uq is implicit via predicate%' OR
   pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure) LIKE '%ON CONFLICT (dispatch_date, machine_id, shelf_id, boonz_product_id, action)%') AS push_upserts;  -- expect true
```
Also assert the preserve predicate no longer preserves dead rows:
```sql
SELECT pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure)
       NOT LIKE '%created_by_edit OR rd.edit_count > 0 OR rd.cancelled OR rd.skipped%' AS preserve_fixed;  -- expect true
```

### 3b. Index exists with the exact partial predicate
```sql
SELECT indexdef FROM pg_indexes
WHERE schemaname='public' AND indexname='uq_dispatch_unstarted_wh_refill';
```

### 3c. Literal count now 0 (B3 — 8 sites closed by B, approve by RC-01)
```sql
SELECT count(*) AS literal_sites_remaining
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.prosrc LIKE '%4bebef68-9e36-4a5c-9c2c-142f8dbdae85%';  -- expect 0
```
(RC-08-B's B-7 assertion also enforces this at apply time.)

### 3d. Cold routing preserved (B1(c)) — push resolves cold→central
```sql
SELECT pg_get_functiondef('public.push_plan_to_dispatch(date,text)'::regprocedure)
       LIKE '%storage_temp_requirement%wh_central_id()%' AS push_cold_routes;  -- expect true
```

### 3e. **Cross-machine oversubscription prediction (Cody-required)**
Prove `wh_fefo_for_line` blocks two machines pinning the same batch beyond stock.
This is a PREDICTION over the netting math; it does not write.
```sql
-- Pick any recent product+date with route stock, simulate a second machine's pin
-- AFTER the first machine already committed the whole pool: is_satisfiable must be false.
WITH sample AS (
  SELECT rd.boonz_product_id, rd.dispatch_date, rd.machine_id
  FROM refill_dispatching rd
  WHERE rd.action IN ('Refill','Add New') AND rd.source_origin='warehouse'
    AND rd.dispatch_date >= CURRENT_DATE - 14
  ORDER BY rd.created_at DESC LIMIT 1
)
SELECT s.*,
       (SELECT bool_or(is_satisfiable)
          FROM public.wh_fefo_for_line(s.machine_id, s.boonz_product_id, s.dispatch_date,
                 -- request the ENTIRE route pool + 1 as a second machine would after the first drained it
                 (SELECT COALESCE(total_pickable,0)+1 FROM public.wh_fefo_for_line(
                    s.machine_id, s.boonz_product_id, s.dispatch_date, 1, NULL) LIMIT 1),
                 NULL)) AS satisfiable_when_over_pool   -- expect false (never oversubscribe)
FROM sample s;
```
Baseline blast radius today (before pins survive): **0 multi-machine competing pools /
0 fleet-wide oversubscribed** in the last 30 days (DARA 2026-07-18) — the hazard is
**latent**, activated the moment pins survive (i.e. after RC-01). The netting is the guard
that makes surviving pins safe.

### 3f. **VOX cold-line coverage check (Cody-required)**
Confirm cold lines on VOX-routed machines pin against WH_CENTRAL's REAL pool (not the
sentinel-inflated VOX staging WHs), and surface a procurement_gap when central can't cover.
```sql
-- Real cold stock lives in WH_CENTRAL (94 units 2026-07-18); VOX staging WHs hold
-- sentinel-inflated cold (1,998). For a VOX machine + a cold SKU, wh_fefo_for_line with
-- ARRAY[WH_CENTRAL] must read the central pool only.
WITH vox_machine AS (
  SELECT machine_id FROM machines
  WHERE status NOT IN ('Inactive','Warehouse')
    AND primary_warehouse_id <> public.wh_central_id() LIMIT 1
), cold_sku AS (
  SELECT product_id FROM boonz_products WHERE storage_temp_requirement='cold' LIMIT 1
)
SELECT (SELECT machine_id FROM vox_machine) AS vox_machine,
       (SELECT product_id FROM cold_sku)     AS cold_sku,
       (SELECT COALESCE(max(total_pickable),0)
          FROM public.wh_fefo_for_line((SELECT machine_id FROM vox_machine),
                 (SELECT product_id FROM cold_sku), CURRENT_DATE+1, 1,
                 ARRAY[public.wh_central_id()])) AS central_pool_seen,   -- reads central only
       (SELECT COALESCE(max(total_pickable),0)
          FROM public.wh_fefo_for_line((SELECT machine_id FROM vox_machine),
                 (SELECT product_id FROM cold_sku), CURRENT_DATE+1, 1, NULL)) AS default_route_pool;  -- machine primary/secondary
-- Expect central_pool_seen to reflect WH_CENTRAL only; a cold line whose qty > central_pool_seen
-- yields is_satisfiable=false -> push logs procurement_gap (S1 never-drop applies downstream).
```

### 3g. Coverage flip count (RC-08 §5a alignment)
```sql
-- For recent pinned warehouse lines, how many would flip pinned -> procurement_gap under
-- the netted, route-scoped, plan-date-valid coverage. Read-only prediction.
SELECT rd.dispatch_date, count(*) AS lines,
       count(*) FILTER (WHERE NOT COALESCE(f.is_satisfiable, false)) AS would_gap
FROM refill_dispatching rd
JOIN machines m ON m.machine_id = rd.machine_id
LEFT JOIN LATERAL (
  SELECT bool_or(is_satisfiable) AS is_satisfiable
  FROM public.wh_fefo_for_line(
    rd.machine_id, rd.boonz_product_id, rd.dispatch_date, rd.quantity,
    ARRAY[ CASE WHEN bp.storage_temp_requirement='cold' THEN public.wh_central_id()
                ELSE m.primary_warehouse_id END ])
) f ON true
JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
WHERE rd.action IN ('Refill','Add New') AND rd.source_origin='warehouse'
  AND rd.dispatch_date >= CURRENT_DATE - 4
GROUP BY 1 ORDER BY 1;
```

---

## 4. ROLLBACK (W1)

Roll back in REVERSE dependency order:
1. `rollback/rc08b_rollback.sql` (restores 5 fns verbatim + re-magics 6 sites)
2. `rollback/rc01_rollback.sql` (drops index; restores approve + push verbatim — push
   reverts to the inline pin, so it no longer references `wh_fefo_for_line`)
3. `rollback/rc08a_rollback.sql` (drops the 3 new fns; restores `v_wh_pickable` columns;
   keep `wh_central_id()` if B not yet rolled back)

All pure DDL, no data migration, instant, no backfill. `from_warehouse_id` values written
in the interim remain valid after B rollback.

---

## 5. PHASE 2 (W2) — later, CS-gated

1. CS reviews the **plan-vs-route-fill delta** (3g above + the nightly metric).
2. A human pulls the LIVE `stitch_pod_to_boonz` body (`pg_get_functiondef`), edits in ONLY
   the warn-only signal block from `20260718093000_…`, captures the pre-body into
   `rollback/rc08_stitch_pod_to_boonz_PRE.sql`, removes the file's CS-gate guard, applies.
3. Published quantities are **never reduced** (S1). Unfulfillable-from-route lines are
   flagged `substitute_candidate` for the swap engine (RC-08-C follow-up for auto-injection).
