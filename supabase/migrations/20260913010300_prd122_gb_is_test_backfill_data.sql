-- PRD-122 Phase 2, Guard G-B (data): flag existing TEST/E2E products as is_test.
-- 10 boonz_products rows matched (name ILIKE 'TEST%' OR ILIKE '%E2E%') and were flagged.
-- Separate from the DDL migration per project convention (DDL and data in separate calls).

UPDATE public.boonz_products
SET is_test = true
WHERE boonz_product_name ILIKE 'TEST%' OR boonz_product_name ILIKE '%E2E%';
