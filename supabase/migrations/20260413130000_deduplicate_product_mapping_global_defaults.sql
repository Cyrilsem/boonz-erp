-- Deduplicate product_mapping global defaults
-- Root cause: UNIQUE (pod_product_id, boonz_product_id, machine_id) does not prevent duplicates
-- when machine_id IS NULL because PostgreSQL treats each NULL as distinct.
-- Fix: keep earliest created_at row per (pod_product_id, boonz_product_id) where machine_id IS NULL,
-- then add a partial unique index to enforce uniqueness going forward.

-- Step 1: Delete duplicates, keeping the row with the earliest created_at per pair
DELETE FROM public.product_mapping
WHERE mapping_id IN (
  SELECT mapping_id
  FROM (
    SELECT
      mapping_id,
      ROW_NUMBER() OVER (
        PARTITION BY pod_product_id, boonz_product_id
        ORDER BY created_at ASC, mapping_id ASC
      ) AS rn
    FROM public.product_mapping
    WHERE machine_id IS NULL
      AND is_global_default = true
  ) ranked
  WHERE rn > 1
);

-- Step 2: Add partial unique index to prevent future duplicates where machine_id IS NULL
-- (The existing UNIQUE constraint on (pod_product_id, boonz_product_id, machine_id) allows
-- multiple NULLs — this partial index closes that gap.)
CREATE UNIQUE INDEX IF NOT EXISTS product_mapping_global_default_unique
  ON public.product_mapping (pod_product_id, boonz_product_id)
  WHERE machine_id IS NULL;

-- Verification: after deletion each (pod_product_id, boonz_product_id) pair where
-- machine_id IS NULL should appear exactly once.
-- Run manually to confirm:
-- SELECT pod_product_id, boonz_product_id, COUNT(*) AS cnt
-- FROM product_mapping
-- WHERE machine_id IS NULL AND is_global_default = true
-- GROUP BY pod_product_id, boonz_product_id
-- HAVING COUNT(*) > 1;
-- Expected: 0 rows.
