-- Migration: set physical_type NOT NULL on boonz_products
-- CC-20-CC1 step 3 of 3 — only applied after null check confirmed 0 nulls

ALTER TABLE boonz_products
ALTER COLUMN physical_type SET NOT NULL;
