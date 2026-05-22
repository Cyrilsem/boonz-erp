-- ============================================================================
-- PRD-003 — Phantom MCC WH inventory: provenance + quarantine scaffolding
--
-- Source PRD: docs/prds/refill-pipeline/PRD-003-phantom-mcc-wh-inventory.md
-- Dara design: see EXECUTION-LOG.md entry for PRD-003 (2026-05-22)
-- Cody review: ⚠️ Approve with revisions (Articles 1, 4, 6, 7, 8, 12, 13, 14)
--   Revisions applied below:
--     (a) inventory_audit_log no-update/no-delete RLS policies (idempotent guards)
--     (b) WITH (security_invoker = true) on both views
--     (c) Header comment on set_warehouse_inventory_provenance declaring trigger-only
--     (d) CREATE OR REPLACE auto_audit_warehouse_inventory (UPDATE) to populate the
--         two new audit columns from the BEFORE-trigger-annotated NEW.* row.
--         NOT modifying auto_audit_warehouse_inventory_insert — its body is in the
--         live DB and not in the source tree. Tracked as PRD-003 follow-up #1.
--     (e) Migration comment documenting the M2M dup-event-id deferral.
--
-- Design intent: QUARANTINE, NOT REJECT. The 11 existing canonical writers
-- (receive_purchase_order, return_dispatch_line, pack_dispatch_line, etc.)
-- have function bodies in the live DB. They are not patched here because
-- their source is not in this repo. Until a follow-up migration patches each
-- writer to call PERFORM set_config('app.provenance_reason', '<reason>', true);
-- their writes will land with provenance_reason=NULL and the row will be
-- quarantined via the GENERATED column. CS unquarantines per the PRD Decision
-- (physical recount → adjust_warehouse_stock with explicit provenance).
--
-- DEFERRED (acknowledged):
--   - Forensic root-cause naming for the existing Hunters / Rice Cake / Perrier
--     rows requires live DB queries — out of scope for this migration.
--   - Patching the 11 canonical writers to set the new GUC — one follow-up
--     migration per writer, owned by CS post-physical-recount.
--   - "Same source_event_id referenced twice — allowed only for M2M legs":
--     per Cody review, deferred to per-RPC enforcement. A partial unique index
--     cannot cleanly express the "twice if m2m_*, else once" rule.
--   - 4h pg_cron schedule for refresh_wh_provenance_mv() — Stax follow-up.
--   - Admin "needs review" FE screen — Stax follow-up.
-- ============================================================================

BEGIN;

-- ── 1. warehouse_inventory: provenance + quarantine columns ─────────────────

ALTER TABLE public.warehouse_inventory
  ADD COLUMN IF NOT EXISTS provenance_reason text,
  ADD COLUMN IF NOT EXISTS source_event_id   uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'wh_provenance_reason_enum'
      AND conrelid = 'public.warehouse_inventory'::regclass
  ) THEN
    ALTER TABLE public.warehouse_inventory
      ADD CONSTRAINT wh_provenance_reason_enum CHECK (
        provenance_reason IS NULL OR provenance_reason IN (
          'po_receive',          -- receive_purchase_order
          'dispatch_return',     -- return_dispatch_line / return_all_dispatches_for_machine
          'dispatch_pack',       -- pack_dispatch_line (consumer_stock movement)
          'dispatch_receive',    -- receive_dispatch_line (consumer drain)
          'm2m_return',          -- swap_between_machines (legacy/correction path)
          'wh_transfer',         -- transfer_warehouse_stock (both legs)
          'manual_adjust',       -- adjust_warehouse_stock / log_manual_refill
          'snapshot',            -- upsert_refill_stock_snapshot / sanity_check
          'status_flip',         -- confirm_warehouse_status_proposal
          'unknown_pre_migration' -- backfill marker for rows that pre-date PRD-003
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'wh_provenance_event_required'
      AND conrelid = 'public.warehouse_inventory'::regclass
  ) THEN
    ALTER TABLE public.warehouse_inventory
      ADD CONSTRAINT wh_provenance_event_required CHECK (
        provenance_reason IS NULL
        OR provenance_reason IN ('manual_adjust', 'snapshot', 'status_flip', 'unknown_pre_migration')
        OR source_event_id IS NOT NULL
      );
  END IF;
END $$;

-- Generated quarantine column. Adding LAST so the CHECK above applies first.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'warehouse_inventory'
      AND column_name = 'quarantined'
  ) THEN
    ALTER TABLE public.warehouse_inventory
      ADD COLUMN quarantined boolean
        GENERATED ALWAYS AS (
          provenance_reason IS NULL
          OR provenance_reason = 'unknown_pre_migration'
        ) STORED;
  END IF;
END $$;

COMMENT ON COLUMN public.warehouse_inventory.provenance_reason IS
  'PRD-003: classification of the originating event for this row''s last write. '
  'Populated by BEFORE trigger from app.provenance_reason GUC. NULL means the '
  'writing RPC has not yet been patched to set the GUC — row will be quarantined.';
COMMENT ON COLUMN public.warehouse_inventory.source_event_id IS
  'PRD-003: FK-like reference to the originating event (po line, dispatch_id, '
  'transfer_id, status_proposal_id). UUID alone — polymorphic FK is an anti-pattern; '
  'provenance_reason is the lookup hint.';
COMMENT ON COLUMN public.warehouse_inventory.quarantined IS
  'PRD-003: GENERATED. True when provenance is missing or pre-migration. Refill '
  'brain MUST skip quarantined rows.';

-- ── 2. inventory_audit_log: provenance mirror columns + append-only RLS ─────

ALTER TABLE public.inventory_audit_log
  ADD COLUMN IF NOT EXISTS provenance_reason text,
  ADD COLUMN IF NOT EXISTS source_event_id   uuid;

-- Idempotent no-update / no-delete RLS (Cody Article 7 — audit append-only).
-- Uses DROP IF EXISTS + CREATE rather than CREATE IF NOT EXISTS (not supported
-- for policies in older PG; safe pattern that does not destroy data).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname='public' AND tablename='inventory_audit_log'
               AND policyname='ial_no_update') THEN
    DROP POLICY ial_no_update ON public.inventory_audit_log;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname='public' AND tablename='inventory_audit_log'
               AND policyname='ial_no_delete') THEN
    DROP POLICY ial_no_delete ON public.inventory_audit_log;
  END IF;
END $$;

CREATE POLICY ial_no_update ON public.inventory_audit_log
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY ial_no_delete ON public.inventory_audit_log
  FOR DELETE TO authenticated USING (false);

-- ── 3. BEFORE trigger: annotate row with provenance from GUC ────────────────

-- Trigger function — NOT a callable RPC. Article 4's input-validation and
-- `app.via_rpc` requirements apply to callable DEFINERs, not to trigger-only
-- functions. This function only reads two GUCs and copies them onto NEW.*.
CREATE OR REPLACE FUNCTION public.set_warehouse_inventory_provenance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason text := current_setting('app.provenance_reason', true);
  v_event  text := current_setting('app.source_event_id', true);
BEGIN
  -- Only overwrite when GUC is explicitly set on this transaction.
  -- Un-patched RPCs continue to write; their rows land quarantined.
  IF v_reason IS NOT NULL AND v_reason <> '' THEN
    NEW.provenance_reason := v_reason;
  END IF;
  IF v_event IS NOT NULL AND v_event <> '' THEN
    BEGIN
      NEW.source_event_id := v_event::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      -- Defensive: do not block the write on a malformed GUC value.
      NEW.source_event_id := NULL;
    END;
  END IF;
  RETURN NEW;
END
$$;

REVOKE EXECUTE ON FUNCTION public.set_warehouse_inventory_provenance() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_set_wh_provenance ON public.warehouse_inventory;
CREATE TRIGGER trg_set_wh_provenance
  BEFORE INSERT OR UPDATE ON public.warehouse_inventory
  FOR EACH ROW
  EXECUTE FUNCTION public.set_warehouse_inventory_provenance();

-- ── 4. Re-emit auto_audit_warehouse_inventory (UPDATE) to include new cols ──
-- Source body taken from migration 20260416140000_b1_inventory_audit_trail_and_repair.sql.
-- Cody-mandated revision: include provenance_reason and source_event_id in the audit
-- INSERT. The values come from NEW.* — the BEFORE trigger has already populated them
-- (trigger ordering: alphabetical, set_wh_provenance < auto_audit_warehouse_inventory,
-- AFTER fires after BEFORE in any case).
CREATE OR REPLACE FUNCTION public.auto_audit_warehouse_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason text;
  v_uid uuid;
BEGIN
  IF OLD.warehouse_stock IS DISTINCT FROM NEW.warehouse_stock
     OR OLD.consumer_stock IS DISTINCT FROM NEW.consumer_stock THEN

    v_uid := (SELECT auth.uid());
    v_reason := COALESCE(
      current_setting('app.mutation_reason', true),
      CASE
        WHEN v_uid IS NULL THEN 'service_role_write_unattributed'
        ELSE 'authenticated_write_no_reason_set'
      END
    );

    INSERT INTO inventory_audit_log
      (wh_inventory_id, boonz_product_id, adjusted_by,
       old_qty, new_qty, reason, audited_at,
       provenance_reason, source_event_id)
    VALUES
      (NEW.wh_inventory_id, NEW.boonz_product_id, v_uid,
       OLD.warehouse_stock, NEW.warehouse_stock, v_reason, now(),
       NEW.provenance_reason, NEW.source_event_id);
  END IF;
  RETURN NEW;
END
$$;

-- Trigger binding unchanged from b1 migration; re-create idempotently.
DROP TRIGGER IF EXISTS trg_audit_wh_inventory ON public.warehouse_inventory;
CREATE TRIGGER trg_audit_wh_inventory
  AFTER UPDATE ON public.warehouse_inventory
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_audit_warehouse_inventory();

-- NOTE: auto_audit_warehouse_inventory_insert is NOT rewritten here because its
-- function body is not in the source tree. PRD-003 follow-up #1 must re-emit it
-- once recovered. Until then, INSERT audit rows will carry NULL provenance.

-- ── 5. Backfill: every pre-existing row is quarantined ──────────────────────

UPDATE public.warehouse_inventory
SET provenance_reason = 'unknown_pre_migration'
WHERE provenance_reason IS NULL;

-- ── 6. Views: live + materialized ───────────────────────────────────────────

-- security_invoker=true (Cody Article 7) — RLS on warehouse_inventory applies.
CREATE OR REPLACE VIEW public.v_wh_inventory_provenance
WITH (security_invoker = true) AS
SELECT
  wi.wh_inventory_id,
  wi.warehouse_id,
  w.name              AS warehouse_name,
  wi.boonz_product_id,
  bp.boonz_product_name AS product_name,
  wi.warehouse_stock,
  wi.consumer_stock,
  wi.expiration_date,
  wi.batch_id,
  wi.status,
  wi.provenance_reason,
  wi.source_event_id,
  wi.quarantined,
  (SELECT ial.audited_at FROM public.inventory_audit_log ial
     WHERE ial.wh_inventory_id = wi.wh_inventory_id
     ORDER BY ial.audited_at DESC NULLS LAST LIMIT 1) AS last_audit_at,
  (SELECT ial.reason FROM public.inventory_audit_log ial
     WHERE ial.wh_inventory_id = wi.wh_inventory_id
     ORDER BY ial.audited_at DESC NULLS LAST LIMIT 1) AS last_audit_reason
FROM public.warehouse_inventory wi
LEFT JOIN public.warehouses     w  ON w.warehouse_id  = wi.warehouse_id
LEFT JOIN public.boonz_products bp ON bp.product_id   = wi.boonz_product_id;

COMMENT ON VIEW public.v_wh_inventory_provenance IS
  'PRD-003 live audit view. Joins warehouse_inventory to its latest inventory_audit_log row '
  'plus warehouses + boonz_products labels. security_invoker=true preserves underlying RLS.';

-- Materialized view drops + recreates idempotently. Article 12 forward-only is
-- preserved because the MV is a derived projection, not source data.
DROP MATERIALIZED VIEW IF EXISTS public.mv_wh_inventory_provenance;
CREATE MATERIALIZED VIEW public.mv_wh_inventory_provenance AS
SELECT * FROM public.v_wh_inventory_provenance;

-- UNIQUE index is required for REFRESH MATERIALIZED VIEW CONCURRENTLY.
CREATE UNIQUE INDEX mv_wh_provenance_pk
  ON public.mv_wh_inventory_provenance (wh_inventory_id);

CREATE INDEX mv_wh_provenance_quarantined
  ON public.mv_wh_inventory_provenance (warehouse_id, boonz_product_id)
  WHERE quarantined = true;

-- ── 7. MV refresh function (cron entry: Stax follow-up) ─────────────────────

CREATE OR REPLACE FUNCTION public.refresh_wh_provenance_mv()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_wh_inventory_provenance;
$$;

REVOKE EXECUTE ON FUNCTION public.refresh_wh_provenance_mv() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_wh_provenance_mv() TO authenticated, service_role;

-- ── 8. Indexes on the base table ────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_wh_inv_quarantined
  ON public.warehouse_inventory (warehouse_id, boonz_product_id)
  WHERE quarantined = true;
COMMENT ON INDEX public.idx_wh_inv_quarantined IS
  'Serves the admin "needs review" screen — filter quarantined rows by warehouse + product.';

CREATE INDEX IF NOT EXISTS idx_wh_inv_source_event
  ON public.warehouse_inventory (source_event_id)
  WHERE source_event_id IS NOT NULL;
COMMENT ON INDEX public.idx_wh_inv_source_event IS
  'Reverse lookup from a PO line / dispatch_id / transfer_id back to the WH row(s) it created.';

CREATE INDEX IF NOT EXISTS idx_ial_provenance
  ON public.inventory_audit_log (provenance_reason, audited_at DESC)
  WHERE provenance_reason IS NOT NULL;
COMMENT ON INDEX public.idx_ial_provenance IS
  'Audit timeline filtered by provenance class.';

COMMIT;

-- ============================================================================
-- POST-APPLY EXPECTATIONS (verify after CS applies):
--   1. SELECT count(*) FILTER (WHERE quarantined) FROM warehouse_inventory;
--      → equals total row count (all backfilled rows quarantined).
--   2. INSERT into warehouse_inventory without provenance GUC set → succeeds,
--      row arrives quarantined=true.
--   3. PERFORM set_config('app.provenance_reason','po_receive',true);
--      PERFORM set_config('app.source_event_id', '<some_po_line_uuid>', true);
--      INSERT into warehouse_inventory(...) → row arrives quarantined=false.
--   4. Attempt provenance_reason='po_receive' with source_event_id=NULL
--      → rejected by wh_provenance_event_required.
--   5. SELECT * FROM v_wh_inventory_provenance WHERE quarantined → returns the
--      list CS will physically recount.
--
-- FOLLOW-UPS REQUIRED BEFORE PRD-003 CAN BE CLOSED:
--   FU#1 — Re-emit auto_audit_warehouse_inventory_insert to populate provenance_reason
--           and source_event_id (body must be recovered from live DB).
--   FU#2..#12 — Patch each canonical writer to call
--           PERFORM set_config('app.provenance_reason','<reason>', true);
--           PERFORM set_config('app.source_event_id', <event_id>::text, true);
--   FU#13 — pg_cron schedule for refresh_wh_provenance_mv() at the 4h cadence.
--   FU#14 — Admin "needs review" FE screen reading v_wh_inventory_provenance.
--   FU#15 — Forensic root-cause query on existing phantom rows (live data work).
-- ============================================================================
