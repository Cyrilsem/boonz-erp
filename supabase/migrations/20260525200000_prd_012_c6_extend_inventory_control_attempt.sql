-- PRD-012 C.6: extend inventory_control_attempt to capture pod_inventory operations.
-- Amendment 007 created this table with a warehouse-only target shape; C.6 adds
-- pod_inventory_id + edit_id columns + a per-target_path conditional CHECK so
-- the approve / reject pod_inventory_add RPCs can attribute session-scoped
-- attempts to the right pod-side row.
-- Cody verdict: approve with revisions (edit_id column + tighter CHECK added).
-- Amendment 009 paragraph filed alongside this migration in 01_constitution.html.

ALTER TABLE public.inventory_control_attempt
  ADD COLUMN IF NOT EXISTS pod_inventory_id uuid NULL;
COMMENT ON COLUMN public.inventory_control_attempt.pod_inventory_id IS
  'Target pod_inventory row when this attempt is a pod-side write (PRD-012 C.6). NULL for warehouse-side attempts. Mutually exclusive with wh_inventory_id via the per-target_path CHECK.';

ALTER TABLE public.inventory_control_attempt
  ADD COLUMN IF NOT EXISTS edit_id uuid NULL;
COMMENT ON COLUMN public.inventory_control_attempt.edit_id IS
  'Target pod_inventory_edits row when this attempt records a propose/approve/reject decision (PRD-012 C.6). NULL for warehouse-side attempts and for pod attempts that target a pod_inventory row directly.';

ALTER TABLE public.inventory_control_attempt
  DROP CONSTRAINT IF EXISTS inventory_control_attempt_target_path_check;

ALTER TABLE public.inventory_control_attempt
  ADD CONSTRAINT inventory_control_attempt_target_path_check CHECK (
    target_path = ANY (ARRAY[
      'by_id',
      'pod_by_id',
      'pod_by_edit_id'
    ])
  );

ALTER TABLE public.inventory_control_attempt
  DROP CONSTRAINT IF EXISTS inventory_control_attempt_target_id_present;

-- Per-target_path conditional CHECK: each target_path requires its matching id column.
ALTER TABLE public.inventory_control_attempt
  ADD CONSTRAINT inventory_control_attempt_target_id_present CHECK (
    (target_path = 'by_id'          AND wh_inventory_id  IS NOT NULL) OR
    (target_path = 'pod_by_id'      AND pod_inventory_id IS NOT NULL) OR
    (target_path = 'pod_by_edit_id' AND edit_id          IS NOT NULL)
  );
