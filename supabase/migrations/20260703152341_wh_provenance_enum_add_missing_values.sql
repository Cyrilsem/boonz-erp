-- Fix: check constraint wh_provenance_reason_enum was never updated when newer canonical
-- writers were added. credit_dispatch_remainder stamps 'dispatch_partial_remainder'
-- (partial-fill remainder credit — the driver "return 1, can't fit shelf" flow) and
-- warehouse_expire_writeoff stamps 'expiry_writeoff'. Both inserts violate the constraint,
-- killing the whole dispatch-save transaction ("Receive failed ... wh_provenance_reason_enum").
alter table public.warehouse_inventory drop constraint wh_provenance_reason_enum;
alter table public.warehouse_inventory add constraint wh_provenance_reason_enum
check (provenance_reason is null or provenance_reason = any (array[
  'po_receive','dispatch_return','dispatch_pack','dispatch_receive','m2m_return',
  'wh_transfer','manual_adjust','snapshot','status_flip','unknown_pre_migration',
  'dispatch_return_unverified','dispatch_partial_remainder','expiry_writeoff'
]));
