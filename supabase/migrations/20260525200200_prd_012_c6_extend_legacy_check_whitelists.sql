-- PRD-012 C.6 hotfix: extend two pre-existing CHECKs on inventory_control_attempt
-- that reject the new pod-side INSERT shapes. Forward-only DROP+ADD with strict
-- widening. Same pattern as the P1.A whitelist-extension hotfix; Cody-approved.

-- (1) Supersede ica_target_path_coherence with the conditional CHECK that
--     covers both warehouse-side and pod-side paths. Strict superset of the
--     legacy constraint: every row that passed the old also passes the new,
--     plus the new pod_by_id and pod_by_edit_id cases.
ALTER TABLE public.inventory_control_attempt
  DROP CONSTRAINT IF EXISTS ica_target_path_coherence;

ALTER TABLE public.inventory_control_attempt
  ADD CONSTRAINT ica_target_path_coherence CHECK (
    (target_path = 'by_id'                       AND wh_inventory_id  IS NOT NULL) OR
    (target_path = 'by_product_warehouse_expiry' AND boonz_product_id IS NOT NULL AND warehouse_id IS NOT NULL) OR
    (target_path = 'pod_by_id'                   AND pod_inventory_id IS NOT NULL) OR
    (target_path = 'pod_by_edit_id'              AND edit_id          IS NOT NULL)
  );

-- (2) Widen field_changed whitelist to include the new pod-add markers.
ALTER TABLE public.inventory_control_attempt
  DROP CONSTRAINT IF EXISTS inventory_control_attempt_field_changed_check;

ALTER TABLE public.inventory_control_attempt
  ADD CONSTRAINT inventory_control_attempt_field_changed_check CHECK (
    field_changed = ANY (ARRAY[
      'warehouse_stock','consumer_stock','status','expiration_date',
      'wh_location','batch_id','create',
      'pod_add_approved','pod_add_rejected'
    ])
  );
