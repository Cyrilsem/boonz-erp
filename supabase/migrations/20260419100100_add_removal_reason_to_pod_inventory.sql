-- BUG-5: Add removal_reason to pod_inventory so that the reason
-- collected in the Removals UI (Expired / Damaged / Other) is persisted.

ALTER TABLE pod_inventory
  ADD COLUMN IF NOT EXISTS removal_reason text NULL;

COMMENT ON COLUMN pod_inventory.removal_reason IS
  'Reason for removal: Expired, Damaged, or Other. Populated by the field Removals flow.';
