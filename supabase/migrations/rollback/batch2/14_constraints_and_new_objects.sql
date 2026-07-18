-- ROLLBACK: undo Batch-2 DDL additions (constraints, new function, new columns, new view)
-- captured 2026-07-18 from eizcexopcuoycuosittm
--
-- PRE-STATE (live constraint definitions before Batch-2, verbatim from pg_get_constraintdef):
--   wh_provenance_event_required:
--     CHECK (((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY['manual_adjust'::text, 'snapshot'::text, 'status_flip'::text, 'unknown_pre_migration'::text])) OR (source_event_id IS NOT NULL)))
--   wh_provenance_reason_enum:
--     CHECK (((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY['po_receive'::text, 'dispatch_return'::text, 'dispatch_pack'::text, 'dispatch_receive'::text, 'm2m_return'::text, 'wh_transfer'::text, 'manual_adjust'::text, 'snapshot'::text, 'status_flip'::text, 'unknown_pre_migration'::text, 'dispatch_return_unverified'::text, 'dispatch_partial_remainder'::text, 'expiry_writeoff'::text]))))
-- Both were convalidated=true.
--
-- WARNING: restoring the original enum constraint will FAIL validation if any
-- rows have provenance_reason IN ('unattributed_write','refill_event') by the
-- time you roll back. Relabel those rows first (they are sentinel/event labels
-- introduced by Batch-2), e.g.:
--   UPDATE warehouse_inventory SET provenance_reason='unknown_pre_migration', source_event_id=NULL
--    WHERE provenance_reason IN ('unattributed_write','refill_event');

BEGIN;

-- 1) restore original provenance constraints
ALTER TABLE public.warehouse_inventory DROP CONSTRAINT IF EXISTS wh_provenance_reason_enum;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT wh_provenance_reason_enum
  CHECK (((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY['po_receive'::text, 'dispatch_return'::text, 'dispatch_pack'::text, 'dispatch_receive'::text, 'm2m_return'::text, 'wh_transfer'::text, 'manual_adjust'::text, 'snapshot'::text, 'status_flip'::text, 'unknown_pre_migration'::text, 'dispatch_return_unverified'::text, 'dispatch_partial_remainder'::text, 'expiry_writeoff'::text]))));

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT IF EXISTS wh_provenance_event_required;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT wh_provenance_event_required
  CHECK (((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY['manual_adjust'::text, 'snapshot'::text, 'status_flip'::text, 'unknown_pre_migration'::text])) OR (source_event_id IS NOT NULL)));

-- 2) drop Batch-2 additions (did not exist before Batch-2)
DROP VIEW IF EXISTS public.v_refill_events_recent;
DROP FUNCTION IF EXISTS public.set_write_context(text, text, text, text);
ALTER TABLE public.refill_event_lines DROP COLUMN IF EXISTS discrepancy;
ALTER TABLE public.refill_event_lines DROP COLUMN IF EXISTS wh_moves;

COMMIT;

-- RC-02 amendment rollback: restore refill_events_source_check pre-state
-- (verified live 2026-07-18 before Batch-2 apply)
ALTER TABLE public.refill_events DROP CONSTRAINT IF EXISTS refill_events_source_check;
ALTER TABLE public.refill_events ADD CONSTRAINT refill_events_source_check
  CHECK (source = ANY (ARRAY['driver_app'::text, 'cs'::text, 'venue_team'::text, 'reconcile'::text]));
