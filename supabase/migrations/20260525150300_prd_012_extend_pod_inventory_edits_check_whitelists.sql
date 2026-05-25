-- PRD-012 P1.A hotfix: extend edit_type and status whitelists on pod_inventory_edits.
-- Forward-only: DROP and re-ADD each CHECK with the new value added (strict widening).
-- 'add_new_product' needed by propose_pod_inventory_add INSERT (P1.B).
-- 'expired' needed by auto_expire_pod_add_proposals cron (P3.A).
-- Cody verdict: approve (Article 12 forward-only honored, Article 5 binding flagged for A.5 cron review).

ALTER TABLE public.pod_inventory_edits
  DROP CONSTRAINT IF EXISTS pod_inventory_edits_edit_type_check;

ALTER TABLE public.pod_inventory_edits
  ADD CONSTRAINT pod_inventory_edits_edit_type_check
  CHECK (edit_type = ANY (ARRAY[
    'in_stock','sold','partial_sold','expired','return_to_warehouse','transfer',
    'add_new_product'
  ]));

ALTER TABLE public.pod_inventory_edits
  DROP CONSTRAINT IF EXISTS pod_inventory_edits_status_check;

ALTER TABLE public.pod_inventory_edits
  ADD CONSTRAINT pod_inventory_edits_status_check
  CHECK (status = ANY (ARRAY[
    'pending','approved','rejected',
    'expired'
  ]));
