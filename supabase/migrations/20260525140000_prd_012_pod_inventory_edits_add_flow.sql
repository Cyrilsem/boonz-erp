-- PRD-012 A.1: extend pod_inventory_edits for the driver pod add flow.
-- See: docs/prds/inventory/prd_012_driver_pod_add_workflow.md section 6.A.1
-- Cody verdict: approve with revisions (em dashes stripped, pre-apply checks run).
-- CS sign-off at G1: 2026-05-25.
-- Idempotent forward-only DDL.

BEGIN;

-- 1. New columns

ALTER TABLE public.pod_inventory_edits
  ADD COLUMN IF NOT EXISTS requested_expiration_date date NULL;
COMMENT ON COLUMN public.pod_inventory_edits.requested_expiration_date IS
  'Required when edit_type=''add_new_product''. The expiry the driver entered for the new pod_inventory row that will be created on approval. Enforced by the add-flow CHECK constraint below.';

ALTER TABLE public.pod_inventory_edits
  ADD COLUMN IF NOT EXISTS correlation_id uuid NOT NULL DEFAULT gen_random_uuid();
COMMENT ON COLUMN public.pod_inventory_edits.correlation_id IS
  'D5 idempotency token. Client generates per submit attempt. RPC propose_pod_inventory_add dedupes within 60s by this value.';

ALTER TABLE public.pod_inventory_edits
  ADD COLUMN IF NOT EXISTS expired_at timestamptz NULL;
COMMENT ON COLUMN public.pod_inventory_edits.expired_at IS
  'D6 auto-expire bookkeeping. Set by cron pod_add_proposals_auto_expire when it flips status to ''expired''. NULL for any other status.';

-- 2. Column-comment update for the reused destination_shelf_id

COMMENT ON COLUMN public.pod_inventory_edits.destination_shelf_id IS
  'Target shelf for the edit. Swap/move flow: the shelf the existing row is moving TO. Add flow: the shelf the new row is being CREATED on. Single semantic across both flows. See PRD-012 section 6.A.1 for the reuse rationale.';

-- 3. Add-flow CHECK constraint
-- Material-implication form (NOT A OR B). Existing rows with edit_type !=
-- 'add_new_product' are unaffected; they pass the LHS and skip the AND chain.

ALTER TABLE public.pod_inventory_edits
  DROP CONSTRAINT IF EXISTS pod_inventory_edits_add_new_product_required_fields;

ALTER TABLE public.pod_inventory_edits
  ADD CONSTRAINT pod_inventory_edits_add_new_product_required_fields CHECK (
    edit_type <> 'add_new_product'
    OR (
      pod_inventory_id IS NULL
      AND requested_expiration_date IS NOT NULL
      AND destination_shelf_id IS NOT NULL
      AND quantity_update IS NOT NULL
      AND quantity_update > 0
    )
  );

-- 4. Indexes

-- 4a. D5: one pending add per (machine, shelf, product).
--     Serves the case-4 (duplicate proposal) test.
CREATE UNIQUE INDEX IF NOT EXISTS idx_pie_one_pending_add_per_target
  ON public.pod_inventory_edits (machine_id, destination_shelf_id, boonz_product_id)
  WHERE edit_type = 'add_new_product' AND status = 'pending';

-- 4b. D5: correlation_id lookup for the 60s dedupe inside propose RPC.
--     Composite with created_at DESC so the RPC's "most recent attempt with
--     this correlation_id" query is index-only.
CREATE INDEX IF NOT EXISTS idx_pie_correlation_id_recent
  ON public.pod_inventory_edits (correlation_id, created_at DESC);

-- 4c. Operator review queue: pending adds, oldest first per PRD section 8 C.5.
CREATE INDEX IF NOT EXISTS idx_pie_pending_adds_oldest_first
  ON public.pod_inventory_edits (created_at)
  WHERE edit_type = 'add_new_product' AND status = 'pending';

COMMIT;
