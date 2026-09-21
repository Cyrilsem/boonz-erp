-- REPO HYGIENE RECONSTRUCTION (see the reconciliation audit that added this file).
--
-- supabase_migrations.schema_migrations records this exact version (20260919182948) under the
-- name "prd128_08c_delivery_verification_perf_index", applied live. No file for it existed
-- anywhere in the repo. Unlike its neighboring migrations in this cluster, this one is fully
-- recoverable: it created an index, and indexes are not silently superseded the way
-- CREATE OR REPLACE FUNCTION/VIEW bodies are -- the exact index this migration created is still
-- live today, confirmed via pg_indexes immediately before writing this file.
--
-- Per DECISIONS-2026-09-19.md D-010 fix #2: weimi_prev/weimi_next lookups moved from a
-- DISTINCT ON over a pre-joined range set to a per-row LATERAL "ORDER BY snapshot_at DESC LIMIT
-- 1", which needs a matching (machine_id, normalized_slot_code, snapshot_at DESC) index to avoid
-- a Bitmap Heap Scan + external sort per row. Confirmed measured effect: 714ms -> 125ms for the
-- weimi lookup half of v_delivery_verification.

CREATE INDEX IF NOT EXISTS idx_weimi_aisle_snapshots_norm_slot_at
  ON public.weimi_aisle_snapshots
  USING btree (machine_id, (regexp_replace(slot_code, '^([A-Za-z]+)0*(\d+)$', '\1\2')), snapshot_at DESC);
