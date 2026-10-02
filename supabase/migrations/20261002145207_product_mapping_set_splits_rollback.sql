-- Rollback for DRAFT_product_mapping_set_splits.sql

DROP FUNCTION IF EXISTS public.set_product_mapping_splits(uuid, uuid, jsonb, text, uuid);
