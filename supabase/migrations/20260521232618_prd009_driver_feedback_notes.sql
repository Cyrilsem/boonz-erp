-- ============================================================================
-- PRD-009 — driver_feedback_notes append-only capture table
--
-- Source PRD: docs/prds/refill-pipeline/PRD-009-driver-feedback-ingest.md
--
-- Greenfield: this migration delivers only AC#1 ("driver_feedback_notes table
-- exists with the columns above"). The four remaining acceptance criteria
-- (driver app capture, engine read, admin feedback inbox, reconcile credits)
-- are out of scope here — they require either FE/n8n work or RPC bodies that
-- live in the live DB. Schema is shipped now so those follow-ups can land
-- against a stable target.
--
-- Design call-outs from the PRD Decisions section:
--   - granularity: BOTH per-shelf (slot_code) AND per-machine (slot_code NULL)
--   - confidence: 1..3 self-rating
--   - signal_source enum: observation | customer_request | sale_anomaly
--     (engine weights 1× / 3× / 2× when this table is wired into scoring)
--   - intent vs note: brain still respects strategic_intents; conflicts surface
--     in the upstream weekly session (not enforced in this schema — that's an
--     engine-side decision once wired)
--   - append-only: rows are immutable except for `superseded_at` set via an
--     explicit RPC (deferred — that RPC is the next step alongside the FE)
--
-- Cody Article 7: RLS UPDATE/DELETE blocked at the policy layer.
-- Cody Article 14: this is a new, non-protected table (not in Appendix A).
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.driver_feedback_notes (
  feedback_id       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id        uuid        NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  slot_code         text,                                                 -- NULL = machine-level note
  boonz_product_id  uuid        REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  direction         text        CHECK (direction IS NULL OR direction IN ('more', 'fewer', 'replace')),
  signal_source     text        NOT NULL DEFAULT 'observation'
                                CHECK (signal_source IN ('observation', 'customer_request', 'sale_anomaly')),
  confidence        smallint    NOT NULL DEFAULT 1
                                CHECK (confidence BETWEEN 1 AND 3),
  note_text         text        NOT NULL CHECK (length(btrim(note_text)) > 0),
  created_by        uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  -- supersedence: when the driver replaces a note, the old row stays for audit
  -- and superseded_at is set. Only active rows (superseded_at IS NULL) feed the brain.
  superseded_at     timestamptz,
  superseded_by     uuid        REFERENCES public.driver_feedback_notes(feedback_id) ON DELETE SET NULL
);

COMMENT ON TABLE public.driver_feedback_notes IS
  'PRD-009: append-only driver feedback capture. Each row is one note from one driver visit. '
  'Granularity: per-shelf when slot_code is set, per-machine when slot_code is NULL. '
  'Append-only: never DELETE; supersede by setting superseded_at + superseded_by via the '
  'supersede RPC (deferred follow-up).';

COMMENT ON COLUMN public.driver_feedback_notes.signal_source IS
  'Engine weighting: observation 1x, sale_anomaly 2x, customer_request 3x. '
  'customer_request is the strongest because it bypasses the engine''s observation blind spot.';

COMMENT ON COLUMN public.driver_feedback_notes.superseded_at IS
  'NULL while the note is the driver''s current standing opinion. When the driver replaces '
  'the note, this timestamp is set and superseded_by points at the replacement row. '
  'The original row is never DELETED — audit trail preserved.';

-- ── Indexes serving the read patterns the brain + admin will hit ────────────

-- Brain ENGINE ADD lookback: per-machine, recent active notes
CREATE INDEX IF NOT EXISTS idx_dfn_active_by_machine_created
  ON public.driver_feedback_notes (machine_id, created_at DESC)
  WHERE superseded_at IS NULL;

-- Brain shelf-level lookup
CREATE INDEX IF NOT EXISTS idx_dfn_active_by_machine_slot
  ON public.driver_feedback_notes (machine_id, slot_code, created_at DESC)
  WHERE superseded_at IS NULL AND slot_code IS NOT NULL;

-- Admin feedback inbox + product-centric review ("how many notes for KitKat?")
CREATE INDEX IF NOT EXISTS idx_dfn_by_product_created
  ON public.driver_feedback_notes (boonz_product_id, created_at DESC)
  WHERE boonz_product_id IS NOT NULL;

-- Same-driver dedup window (60s per PRD edge case)
CREATE INDEX IF NOT EXISTS idx_dfn_created_by_recent
  ON public.driver_feedback_notes (created_by, created_at DESC)
  WHERE created_by IS NOT NULL;

-- ── RLS: append-only with selective SELECT ──────────────────────────────────

ALTER TABLE public.driver_feedback_notes ENABLE ROW LEVEL SECURITY;

-- Anyone authenticated reads (drivers see their own + others for context;
-- CS reads in the admin inbox).
DROP POLICY IF EXISTS dfn_select_authenticated ON public.driver_feedback_notes;
CREATE POLICY dfn_select_authenticated
  ON public.driver_feedback_notes
  FOR SELECT TO authenticated USING (true);

-- INSERT: any authenticated user (drivers capture their own notes; CS can also
-- backfill). created_by must be the caller — guarded by WITH CHECK.
DROP POLICY IF EXISTS dfn_insert_self ON public.driver_feedback_notes;
CREATE POLICY dfn_insert_self
  ON public.driver_feedback_notes
  FOR INSERT TO authenticated
  WITH CHECK (
    created_by IS NULL                            -- service_role / backfill
    OR created_by = (SELECT auth.uid())          -- self-attributed write
  );

-- Article 7: append-only.
DROP POLICY IF EXISTS dfn_no_update ON public.driver_feedback_notes;
CREATE POLICY dfn_no_update
  ON public.driver_feedback_notes
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS dfn_no_delete ON public.driver_feedback_notes;
CREATE POLICY dfn_no_delete
  ON public.driver_feedback_notes
  FOR DELETE TO authenticated USING (false);

-- ── Convenience view: active notes only ─────────────────────────────────────

CREATE OR REPLACE VIEW public.v_driver_feedback_active
WITH (security_invoker = true) AS
SELECT
  dfn.feedback_id,
  dfn.machine_id,
  m.official_name AS machine_official_name,
  dfn.slot_code,
  dfn.boonz_product_id,
  bp.name AS product_name,
  dfn.direction,
  dfn.signal_source,
  dfn.confidence,
  dfn.note_text,
  dfn.created_by,
  dfn.created_at
FROM public.driver_feedback_notes dfn
LEFT JOIN public.machines        m  ON m.machine_id = dfn.machine_id
LEFT JOIN public.boonz_products  bp ON bp.product_id = dfn.boonz_product_id
WHERE dfn.superseded_at IS NULL;

COMMENT ON VIEW public.v_driver_feedback_active IS
  'PRD-009: active (non-superseded) driver feedback notes. security_invoker=true preserves '
  'underlying RLS. The brain consumes this view; the admin feedback inbox UI reads it too.';

COMMIT;

-- ============================================================================
-- POST-APPLY VERIFICATION
--   1. INSERT a note as driver: row arrives.
--   2. Try UPDATE: rejected by dfn_no_update.
--   3. Try DELETE: rejected by dfn_no_delete.
--   4. INSERT with created_by != auth.uid(): rejected by dfn_insert_self.
--   5. INSERT with confidence=4 or direction='abandon': rejected by CHECK.
--
-- DEFERRED FOLLOW-UPS for PRD-009:
--   - supersede_driver_feedback(p_feedback_id, p_new_text, ...) RPC — SECURITY DEFINER,
--     atomic insert-then-flip via app.via_rpc, the only way to set superseded_at.
--   - field PWA capture surface: dialog at end-of-visit per machine (Stax).
--   - admin feedback inbox page reading v_driver_feedback_active.
--   - engine_add_pod read: 14-day decay, signal_source weighting (1/2/3x).
--   - reconcile credit: attribute fills that follow "more X" notes to feedback signal.
--   - dedup-window (60s same driver same text) at INSERT — application-side check
--     before insert; not enforced in schema.
-- ============================================================================
