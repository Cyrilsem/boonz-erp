-- REPO HYGIENE RECONSTRUCTION (see the reconciliation audit that added this file).
--
-- supabase_migrations.schema_migrations records this exact version (20260920171507) under the
-- name "prd124_p1_product_mapping_redbull_repair", applied live. No file for it existed anywhere
-- in the repo, and no trace of it exists in git history or docs -- this predates every session
-- with a visible transcript.
--
-- Fully recoverable from data, not guessed: exactly six product_mapping rows share
-- updated_at = 2026-09-20 17:15:07.329233+00, matching this migration's own timestamp to the
-- microsecond. All six are Red Bull rows (pod_product_name = 'Red Bull'), three machine-specific
-- (machine_id f1a528fb-15e8-4f20-b4e2-ebb2e6852198) and three global-default. The repair set the
-- machine-specific rows to 100 percent "Red Bull - 355ML" (deactivating the Regular/Diet
-- machine-specific rows), leaving the global default (80 percent Regular, 20 percent Diet, 355ML
-- inactive) untouched. This reads as a single-machine flavour correction, not a global mapping
-- change.
--
-- Reconstructed as the exact resulting row state (an UPDATE per row, keyed on mapping_id),
-- verified against live data immediately before writing this file. This is the RESULT of the
-- migration, not necessarily its original SQL text (which is not recoverable), but the two are
-- equivalent for a repair of this shape: running these UPDATEs again is a no-op against the
-- current live rows.

UPDATE public.product_mapping SET boonz_product_id = 'e21bae75-cdeb-42a9-b6ad-df8f5d4166dc', machine_id = 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198', split_pct = 100.00, is_global_default = false, status = 'Active'
  WHERE mapping_id = '2af31944-1a39-4bdf-9e8e-73abcff230d7';
UPDATE public.product_mapping SET boonz_product_id = 'd8096c9b-1dd7-42bf-96b8-a9aaae7132dc', machine_id = 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198', split_pct = 0.00, is_global_default = false, status = 'Inactive'
  WHERE mapping_id = '56f692e6-8971-4764-a6f9-57e3e1bc675a';
UPDATE public.product_mapping SET boonz_product_id = 'c54791c0-3c08-4fe8-87c1-2c7e26243827', machine_id = 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198', split_pct = 0.00, is_global_default = false, status = 'Inactive'
  WHERE mapping_id = '444350d4-a238-4112-abc5-dd2d8481d4fb';
UPDATE public.product_mapping SET boonz_product_id = 'd8096c9b-1dd7-42bf-96b8-a9aaae7132dc', machine_id = NULL, split_pct = 80.00, is_global_default = true, status = 'Active'
  WHERE mapping_id = 'e1b843d5-3bc6-4029-a798-17ddc54f7d51';
UPDATE public.product_mapping SET boonz_product_id = 'c54791c0-3c08-4fe8-87c1-2c7e26243827', machine_id = NULL, split_pct = 20.00, is_global_default = true, status = 'Active'
  WHERE mapping_id = '4b23dfee-7655-405a-843f-2e0d170e6a50';
UPDATE public.product_mapping SET boonz_product_id = 'e21bae75-cdeb-42a9-b6ad-df8f5d4166dc', machine_id = NULL, split_pct = 0.00, is_global_default = true, status = 'Inactive'
  WHERE mapping_id = 'b7a28d17-7b75-4b70-8c17-9848e8fb57bf';
