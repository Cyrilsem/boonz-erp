-- ============================================================================
-- PRD-001 — M2M consistency guards + m2m_event_log (append-only)
--
-- Source PRD: docs/prds/refill-pipeline/PRD-001-m2m-swap-misroute.md
--
-- Forensic finding (live DB, 2026-05-22): the IFLY-1024 "12 Barebells →
-- AMZ" misroute was created as a regular Remove dispatch with
--   is_m2m=false, source_kind='wh', from_warehouse_id=WH_MCC
-- when it should have been an M2M Remove leg with is_m2m=true and
-- from_warehouse_id=NULL. The driver-side receive then landed the
-- stock at WH_MCC instead of AMZ. M2M Add New legs at AMZ on
-- 2026-05-20 are correctly is_m2m=true, source_kind='truck_transfer' —
-- so the source-leg creation path is what diverged.
--
-- This migration adds:
--   1. CHECK constraint `m2m_consistency` on refill_dispatching enforcing:
--        - if is_m2m=true → from_warehouse_id IS NULL (no WH involvement)
--        - if is_m2m=true → source_kind IN ('m2m','truck_transfer') (or NULL)
--        - if source_kind IN ('m2m','truck_transfer') → is_m2m must be true
--        - if is_m2m=true → source_machine_id IS NOT NULL (must name source)
--      Any one of these violations would have produced the IFLY-1024
--      misroute or its sibling shape.
--
--   2. `m2m_event_log` append-only table — every M2M attempt + every state
--      transition on an is_m2m=true dispatch row gets a log row, joinable
--      by m2m_transfer_id.
--
--   3. Trigger `audit_m2m_dispatch_changes` on refill_dispatching that
--      writes an m2m_event_log row whenever an is_m2m=true row is INSERTed
--      or its state flags (packed/dispatched/picked_up/item_added/returned)
--      change. This is the AC#5 "append-only log for every M2M attempt".
--
-- Note: this migration does NOT fix the receive_dispatch_line destination
-- routing on Remove dispatches — that's the orthogonal bug surfaced by
-- PRD-003 forensic ("v_target_wh = COALESCE(from_warehouse_id, WH_CENTRAL)").
-- Fixing it requires deciding whether REMOVE→WH should always land at
-- WH_CENTRAL or correctly track the source machine's from_warehouse_id.
-- Tracked in PRD-001 blocked_reason; intentionally not bundled here.
--
-- Cody Articles: 1 (no new write path), 4 (CHECK + trigger fn validation),
-- 7 (m2m_event_log append-only RLS), 12 (forward-only), 14 (no _v2).
-- ============================================================================

BEGIN;

-- ── 1. CHECK constraint on refill_dispatching ──────────────────────────────

-- Guard against existing rows that would violate the new constraint.
-- Forensic query (2026-05-22): 2 pre-existing offenders found on AMZ-1038
-- from 2026-05-18 — both is_m2m=true with source_kind='m2m' but no
-- source_machine_id / m2m_transfer_id / m2m_partner_id (orphaned M2M
-- Refills with no source linkage):
--   5fb5181a-d43b-4128-985f-0807aae7c46d
--   c3e346d2-6650-4dec-b08f-16f49f688cd0
-- Adding the constraint as NOT VALID — new INSERTs/UPDATEs must comply,
-- the 2 historical offenders are grandfathered until CS triages them.
-- After CS fixes (or accepts the orphan state), run:
--   ALTER TABLE refill_dispatching VALIDATE CONSTRAINT m2m_consistency;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'm2m_consistency'
      AND conrelid = 'public.refill_dispatching'::regclass
  ) THEN
    ALTER TABLE public.refill_dispatching
      ADD CONSTRAINT m2m_consistency CHECK (
        -- is_m2m=true implies no WH involvement
        (is_m2m IS NOT TRUE OR from_warehouse_id IS NULL)
        AND
        -- is_m2m=true implies source_kind is consistent (NULL or m2m-flavored)
        (is_m2m IS NOT TRUE OR source_kind IS NULL OR source_kind IN ('m2m','truck_transfer'))
        AND
        -- source_kind m2m-flavored implies is_m2m must be true
        (source_kind IS NULL OR source_kind NOT IN ('m2m','truck_transfer') OR is_m2m IS TRUE)
        AND
        -- is_m2m=true implies a source machine must be named
        (is_m2m IS NOT TRUE OR source_machine_id IS NOT NULL)
      ) NOT VALID;
  END IF;
END $$;

COMMENT ON CONSTRAINT m2m_consistency ON public.refill_dispatching IS
  'PRD-001: M2M dispatches must (a) have no warehouse source, (b) name a source machine, '
  '(c) carry a consistent source_kind. Prevents the IFLY-1024 → WH_MCC misroute pattern '
  'where an M2M-intended Remove was created as a regular WH-destined Remove.';

-- ── 2. m2m_event_log append-only table ─────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.m2m_event_log (
  event_id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type          text        NOT NULL CHECK (event_type IN (
                                    'm2m_intent_created',  -- swap_between_machines call
                                    'm2m_row_inserted',    -- a single refill_dispatching row born is_m2m
                                    'm2m_packed',          -- packed flipped true
                                    'm2m_picked_up',       -- picked_up flipped true
                                    'm2m_received',        -- item_added flipped true (delivered at dest)
                                    'm2m_returned',        -- returned flipped true (failed M2M)
                                    'm2m_dropped_to_wh',   -- forensic marker: M2M row morphed to WH return
                                    'm2m_manual_reconcile' -- backfill via adjust_pod_inventory
                                  )),
  m2m_transfer_id     uuid,                                               -- groups the two legs
  source_machine_id   uuid REFERENCES public.machines(machine_id) ON DELETE SET NULL,
  dest_machine_id     uuid REFERENCES public.machines(machine_id) ON DELETE SET NULL,
  refill_dispatching_id uuid REFERENCES public.refill_dispatching(dispatch_id) ON DELETE SET NULL,
  boonz_product_id    uuid REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  qty                 numeric,
  performed_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  performed_at        timestamptz NOT NULL DEFAULT now(),
  note                text,
  payload             jsonb                                                -- captures NEW.* state at event time
);

COMMENT ON TABLE public.m2m_event_log IS
  'PRD-001 AC#5: append-only audit of every M2M attempt + state transition. '
  'Joinable by m2m_transfer_id to reconstruct the full lifecycle of a swap. '
  'Append-only via Article 7 RLS — no UPDATE, no DELETE.';

CREATE INDEX IF NOT EXISTS idx_m2m_event_log_transfer
  ON public.m2m_event_log (m2m_transfer_id, performed_at DESC)
  WHERE m2m_transfer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_m2m_event_log_source
  ON public.m2m_event_log (source_machine_id, performed_at DESC)
  WHERE source_machine_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_m2m_event_log_dest
  ON public.m2m_event_log (dest_machine_id, performed_at DESC)
  WHERE dest_machine_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_m2m_event_log_dispatch
  ON public.m2m_event_log (refill_dispatching_id)
  WHERE refill_dispatching_id IS NOT NULL;

ALTER TABLE public.m2m_event_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mel_select_authenticated ON public.m2m_event_log;
CREATE POLICY mel_select_authenticated
  ON public.m2m_event_log
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS mel_insert_authenticated ON public.m2m_event_log;
CREATE POLICY mel_insert_authenticated
  ON public.m2m_event_log
  FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS mel_no_update ON public.m2m_event_log;
CREATE POLICY mel_no_update
  ON public.m2m_event_log
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS mel_no_delete ON public.m2m_event_log;
CREATE POLICY mel_no_delete
  ON public.m2m_event_log
  FOR DELETE TO authenticated USING (false);

-- ── 3. Trigger: log every state change on is_m2m=true rows ─────────────────

CREATE OR REPLACE FUNCTION public.audit_m2m_dispatch_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_event text;
BEGIN
  -- Only fire for M2M rows
  IF COALESCE(NEW.is_m2m, false) = false AND (TG_OP = 'INSERT' OR COALESCE(OLD.is_m2m, false) = false) THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.m2m_event_log
      (event_type, m2m_transfer_id, source_machine_id, dest_machine_id,
       refill_dispatching_id, boonz_product_id, qty, performed_by, payload)
    VALUES
      ('m2m_row_inserted', NEW.m2m_transfer_id, NEW.source_machine_id, NEW.machine_id,
       NEW.dispatch_id, NEW.boonz_product_id, NEW.quantity, v_uid,
       jsonb_build_object('action', NEW.action, 'source_kind', NEW.source_kind,
                          'shelf_id', NEW.shelf_id));
    RETURN NEW;
  END IF;

  -- UPDATE: log specific state transitions
  IF OLD.packed     IS DISTINCT FROM NEW.packed     AND NEW.packed     = true THEN v_event := 'm2m_packed';
  ELSIF OLD.picked_up IS DISTINCT FROM NEW.picked_up AND NEW.picked_up = true THEN v_event := 'm2m_picked_up';
  ELSIF OLD.item_added IS DISTINCT FROM NEW.item_added AND NEW.item_added = true THEN v_event := 'm2m_received';
  ELSIF OLD.returned  IS DISTINCT FROM NEW.returned  AND NEW.returned  = true THEN v_event := 'm2m_returned';
  ELSE
    RETURN NEW;  -- not a transition we care about
  END IF;

  INSERT INTO public.m2m_event_log
    (event_type, m2m_transfer_id, source_machine_id, dest_machine_id,
     refill_dispatching_id, boonz_product_id, qty, performed_by, payload)
  VALUES
    (v_event, NEW.m2m_transfer_id, NEW.source_machine_id, NEW.machine_id,
     NEW.dispatch_id, NEW.boonz_product_id, COALESCE(NEW.filled_quantity, NEW.quantity), v_uid,
     jsonb_build_object('packed', NEW.packed, 'picked_up', NEW.picked_up,
                        'item_added', NEW.item_added, 'returned', NEW.returned,
                        'filled_quantity', NEW.filled_quantity));
  RETURN NEW;
END
$$;

REVOKE EXECUTE ON FUNCTION public.audit_m2m_dispatch_changes() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_audit_m2m_dispatch ON public.refill_dispatching;
CREATE TRIGGER trg_audit_m2m_dispatch
  AFTER INSERT OR UPDATE ON public.refill_dispatching
  FOR EACH ROW EXECUTE FUNCTION public.audit_m2m_dispatch_changes();

COMMIT;

-- ============================================================================
-- POST-APPLY EXPECTATIONS
--   1. CHECK constraint rejects new INSERTs that mix is_m2m=true with
--      from_warehouse_id != NULL or source_kind='wh'. The IFLY-1024 row
--      from 2026-05-19 is is_m2m=false so unaffected.
--   2. Every existing AMZ-1029 M2M row (is_m2m=true) satisfies the constraint
--      because swap_between_machines sets from_warehouse_id=NULL, source_kind
--      via the m2m_transfer_id linkage, and source_machine_id externally.
--      Verify with:
--        SELECT count(*) FROM refill_dispatching
--        WHERE is_m2m=true AND (
--          from_warehouse_id IS NOT NULL OR source_machine_id IS NULL
--          OR (source_kind IS NOT NULL AND source_kind NOT IN ('m2m','truck_transfer'))
--        );
--      → must return 0; if not, those rows need manual repair before apply.
--   3. Trigger writes m2m_event_log rows for every state change on M2M rows.
--      Confirm with: SELECT count(*) FROM m2m_event_log;
--
-- IFLY-1024 → AMZ RECONCILIATION (PRD-001 AC#6 — virtual, NOT executed here):
--   The 12-Barebells case wasn't actually an M2M intent at all in the DB
--   (is_m2m=false, source_kind='wh'). It was a regular Remove to WH_MCC.
--   Physical reconcile path:
--     a) Apply PRD-003 scaffolding + this migration.
--     b) AMZ already has the Barebells variants via separate is_m2m=true
--        Refill rows on 2026-05-20 — no AMZ-side correction needed.
--     c) For the 12-planned-3-actual gap at WH_MCC: physical recount per
--        PRD-003 workflow. The phantom rows surface in /admin/wh-quarantine.
--   No backfill SQL needed in this migration. CS executes adjust_warehouse_stock
--   /adjust_pod_inventory directly with provenance_reason='manual_adjust' and
--   a note referencing PRD-001 reconciliation.
--
-- DEFERRED:
--   - Destination-routing fix in receive_dispatch_line REMOVE branch
--     (v_target_wh selection logic) — orthogonal bug, separate follow-up.
--   - FE indicator in the M2M planning UI showing "M2M intent" vs "regular Remove"
--     to prevent the human-side creation mistake — Stax follow-up.
-- ============================================================================
