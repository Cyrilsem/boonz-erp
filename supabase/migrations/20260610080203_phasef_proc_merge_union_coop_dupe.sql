-- PRD-5 (Procurement Brain v3) — data hygiene: merge duplicate "Union Coop" supplier.
-- Migration name: phasef_proc_merge_union_coop_dupe
-- Articles: 1 (single canonical supplier), 8 (audit trail), 12 (forward-only). NO deletes.
--
-- Duplicate  3cec0b3a-be06-4104-a88b-6a69e8f247d7 (Inactive, 19 PO lines, 18 supplier_products)
-- Canonical  31b6355d-c4e6-4bdc-842a-7df8807e64d8 (Active,   334 PO lines, 94 supplier_products)
-- Both are the same real walk-in supplier "Union Coop".
--
-- supplier_products overlap (verified 2026-06-10): of the dupe's 18 rows, 16 products already
-- exist on canonical (retire in place — repointing would violate the UNIQUE(supplier_id,
-- boonz_product_id) key) and 2 do NOT exist on canonical (repoint). 3 dupe rows are is_preferred;
-- the partial-unique index uq_supplier_products_one_preferred (boonz_product_id WHERE is_preferred)
-- forces us to clear the dupe's preferred flags BEFORE repointing / promoting, to avoid a clash.
--
-- Outcome:
--   * 19 PO lines repointed dupe -> canonical (history preserved, just re-attributed).
--   * 2 supplier_products (Barkthins Dark Choco Pretzel + Almond) repointed to canonical, stay preferred.
--   * 16 overlap supplier_products retired on the dupe (status=Inactive, is_preferred=false); kept for history.
--   * Coco Water - Regular: its sole preferred was the dupe row; promote canonical's Coco Water row to preferred
--     so the product keeps a preferred supplier (now canonical Union Coop).
--   * Dupe supplier renamed + left Inactive (no delete).
--   * Full audit trail in write_audit_log.

-- Provenance for any attribution triggers.
SELECT set_config('app.via_rpc',  'true', true);
SELECT set_config('app.rpc_name', 'prd5_union_coop_merge', true);

-- ── 1. Audit the 19 PO-line repoints BEFORE mutating (one row per affected line). ──────────────
INSERT INTO public.write_audit_log
  (table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload)
SELECT
  'purchase_orders', 'UPDATE', po.po_line_id::text, NULL, 'system',
  true, 'prd5_union_coop_merge',
  jsonb_build_object(
    'reason',   'PRD-5 Union Coop dupe merge',
    'po_id',    po.po_id,
    'before',   jsonb_build_object('supplier_id', '3cec0b3a-be06-4104-a88b-6a69e8f247d7'),
    'after',    jsonb_build_object('supplier_id', '31b6355d-c4e6-4bdc-842a-7df8807e64d8')
  )
FROM public.purchase_orders po
WHERE po.supplier_id = '3cec0b3a-be06-4104-a88b-6a69e8f247d7';

-- ── 2. Repoint the PO lines. ───────────────────────────────────────────────────────────────────
UPDATE public.purchase_orders
   SET supplier_id = '31b6355d-c4e6-4bdc-842a-7df8807e64d8'
 WHERE supplier_id = '3cec0b3a-be06-4104-a88b-6a69e8f247d7';

-- ── 3. Clear the dupe's preferred flags first (so repoint/promote can't trip the partial index). ─
UPDATE public.supplier_products
   SET is_preferred = false
 WHERE supplier_id = '3cec0b3a-be06-4104-a88b-6a69e8f247d7'
   AND is_preferred;

-- ── 4. Repoint the 2 supplier_products that canonical does NOT already have. ──────────────────────
UPDATE public.supplier_products sp
   SET supplier_id = '31b6355d-c4e6-4bdc-842a-7df8807e64d8'
 WHERE sp.supplier_id = '3cec0b3a-be06-4104-a88b-6a69e8f247d7'
   AND NOT EXISTS (
     SELECT 1 FROM public.supplier_products c
      WHERE c.supplier_id = '31b6355d-c4e6-4bdc-842a-7df8807e64d8'
        AND c.boonz_product_id = sp.boonz_product_id
   );

-- ── 5. Restore preferred on the 2 repointed Barkthins rows (now sole rows for those products). ───
UPDATE public.supplier_products
   SET is_preferred = true
 WHERE supplier_id = '31b6355d-c4e6-4bdc-842a-7df8807e64d8'
   AND boonz_product_id IN (
     '43f0c1d5-7695-4874-aa4c-5921826bb075',  -- Barkthins - Dark Choco Pretzel
     '772b4fee-424f-4c67-bb6d-ef7db4a7451b'   -- Barkthins - Dark Choco Almond
   );

-- ── 6. Retire the remaining dupe supplier_products (the 16 overlap rows). Keep for history. ──────
UPDATE public.supplier_products
   SET status = 'Inactive'
 WHERE supplier_id = '3cec0b3a-be06-4104-a88b-6a69e8f247d7'
   AND status <> 'Inactive';

-- ── 7. Promote canonical's Coco Water to preferred (it lost its only preferred in step 3). ───────
UPDATE public.supplier_products
   SET is_preferred = true
 WHERE supplier_id = '31b6355d-c4e6-4bdc-842a-7df8807e64d8'
   AND boonz_product_id = 'c82ab22e-8618-47a1-a9e0-a2b8ed386af4'  -- Coco Water - Regular
   AND NOT EXISTS (
     SELECT 1 FROM public.supplier_products p
      WHERE p.boonz_product_id = 'c82ab22e-8618-47a1-a9e0-a2b8ed386af4'
        AND p.is_preferred
   );

-- ── 8. Rename the dupe supplier (kept Inactive, NOT deleted). ────────────────────────────────────
UPDATE public.suppliers
   SET supplier_name = 'Union Coop (DUP merged to 31b6355d on 2026-06-10)'
 WHERE supplier_id = '3cec0b3a-be06-4104-a88b-6a69e8f247d7';

-- ── 9. Audit summary for the supplier_products + supplier-rename changes. ────────────────────────
INSERT INTO public.write_audit_log
  (table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload)
VALUES
  ('suppliers', 'UPDATE', '3cec0b3a-be06-4104-a88b-6a69e8f247d7', NULL, 'system',
   true, 'prd5_union_coop_merge',
   jsonb_build_object(
     'reason', 'PRD-5 Union Coop dupe merge',
     'po_lines_repointed', 19,
     'supplier_products_repointed', 2,
     'supplier_products_retired', 16,
     'canonical_supplier_id', '31b6355d-c4e6-4bdc-842a-7df8807e64d8',
     'before', jsonb_build_object('supplier_name', 'Union Coop', 'status', 'Inactive'),
     'after',  jsonb_build_object('supplier_name', 'Union Coop (DUP merged to 31b6355d on 2026-06-10)', 'status', 'Inactive')
   ));
