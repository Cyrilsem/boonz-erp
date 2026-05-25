-- PRD-012 P1.A hotfix #2: relax add-flow CHECK to allow pod_inventory_id linkage post-approval.
-- The approve RPC sets pod_inventory_id after INSERTing into pod_inventory; the original CHECK
-- requirement that pod_inventory_id IS NULL for add_new_product rows blocked that UPDATE.
-- Forward-only: DROP and re-ADD with the NULL clause removed (strict relaxation).
-- Cody verdict: approve (Article 12 forward-only honored; strictly looser constraint).

ALTER TABLE public.pod_inventory_edits
  DROP CONSTRAINT IF EXISTS pod_inventory_edits_add_new_product_required_fields;

ALTER TABLE public.pod_inventory_edits
  ADD CONSTRAINT pod_inventory_edits_add_new_product_required_fields CHECK (
    edit_type <> 'add_new_product'
    OR (
      requested_expiration_date IS NOT NULL
      AND destination_shelf_id IS NOT NULL
      AND quantity_update IS NOT NULL
      AND quantity_update > 0
    )
  );
