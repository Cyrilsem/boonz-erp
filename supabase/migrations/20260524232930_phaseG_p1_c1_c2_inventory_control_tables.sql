-- Migration: phaseG_p1_c1_c2_inventory_control_tables
-- PRD v2 Phase G, Workstream C tables C.1 and C.2.
-- Articles: 2 (RLS), 5 (status state machine), 7 (audit append-only),
--           12 (forward-only), 14 (no shadow tables),
--           15 (PR declares invariants; Appendix A amendment to follow within Phase 1 close).
-- Dara designed. Cody approved with Option Y revision (no 'pending' result, pure append).

-- =====================================================================
-- C.1  inventory_control_session
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.inventory_control_session (
  session_id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  session_slug        text        UNIQUE,
  started_at          timestamptz NOT NULL DEFAULT now(),
  started_by          uuid        NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  scope_warehouse_id  uuid        NOT NULL REFERENCES public.warehouses(warehouse_id) ON DELETE RESTRICT,
  scope_product_ids   uuid[],
  status              text        NOT NULL DEFAULT 'open'
                                  CHECK (status IN ('open','closed','aborted')),
  closed_at           timestamptz,
  closed_by           uuid        REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  summary             jsonb,
  CONSTRAINT ics_closed_when_not_open
    CHECK ((status = 'open' AND closed_at IS NULL)
        OR (status IN ('closed','aborted') AND closed_at IS NOT NULL))
);

COMMENT ON TABLE public.inventory_control_session IS
  'Phase G Workstream C.1. One row per inventory-control sitting by a WH manager. Append-only by RLS. Status transitions only via start_inventory_session and close_inventory_session RPCs.';
COMMENT ON COLUMN public.inventory_control_session.session_slug IS
  'Optional human-readable id (example: inventory_session_2026-05-23_makeup). Set by start_inventory_session caller.';
COMMENT ON COLUMN public.inventory_control_session.scope_product_ids IS
  'Optional product whitelist for this sitting. NULL means all products in scope_warehouse_id.';
COMMENT ON COLUMN public.inventory_control_session.summary IS
  'Set by close_inventory_session: counts by result, by product, by error class. NULL while status=open.';

-- =====================================================================
-- C.2  inventory_control_attempt
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.inventory_control_attempt (
  attempt_id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id            uuid        NOT NULL REFERENCES public.inventory_control_session(session_id) ON DELETE RESTRICT,
  attempted_at          timestamptz NOT NULL DEFAULT now(),
  attempted_by          uuid        NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,

  target_path           text        NOT NULL
                                    CHECK (target_path IN ('by_id','by_product_warehouse_expiry')),
  wh_inventory_id       uuid        REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE SET NULL,
  boonz_product_id      uuid        REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  warehouse_id          uuid        REFERENCES public.warehouses(warehouse_id) ON DELETE SET NULL,
  expiration_date       date,

  field_changed         text        NOT NULL
                                    CHECK (field_changed IN ('warehouse_stock','consumer_stock','status','expiration_date','wh_location','batch_id','create')),
  old_value             jsonb,
  new_value             jsonb,

  rpc_called            text        NOT NULL,
  rpc_response          jsonb,
  -- Option Y per Cody: pure append. 'pending' deliberately omitted; wrappers INSERT once with terminal result.
  result                text        NOT NULL
                                    CHECK (result IN ('success','blocked_rls','blocked_trigger','rpc_error','validation_error','network_error','other')),
  error_message         text,
  client_correlation_id uuid        NOT NULL,
  reason                text        NOT NULL,

  CONSTRAINT ica_target_path_coherence
    CHECK (
      (target_path = 'by_id' AND wh_inventory_id IS NOT NULL)
      OR
      (target_path = 'by_product_warehouse_expiry' AND boonz_product_id IS NOT NULL AND warehouse_id IS NOT NULL)
    )
);

COMMENT ON TABLE public.inventory_control_attempt IS
  'Phase G Workstream C.2. One row per attempted mutation inside a session. Append-only by RLS. Captures success and failure with full diff and RPC response. One row per attempt (Option Y, post-Cody).';
COMMENT ON COLUMN public.inventory_control_attempt.result IS
  'Terminal outcome only. Wrappers INSERT once after the SAVEPOINT closes (success or one of the failure classes). No pending state.';
COMMENT ON COLUMN public.inventory_control_attempt.client_correlation_id IS
  'FE-provided idempotency token. Lets the FE de-dupe retries; lets the session viewer group network-error + retry attempts.';

-- =====================================================================
-- Indexes
-- =====================================================================
-- C.1
CREATE INDEX IF NOT EXISTS idx_ics_started_by_started_at
  ON public.inventory_control_session (started_by, started_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ics_one_open_per_user
  ON public.inventory_control_session (started_by)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_ics_warehouse_started_at
  ON public.inventory_control_session (scope_warehouse_id, started_at DESC);

-- C.2
CREATE INDEX IF NOT EXISTS idx_ica_session_attempted_at
  ON public.inventory_control_attempt (session_id, attempted_at DESC);

CREATE INDEX IF NOT EXISTS idx_ica_wh_inventory_attempted_at
  ON public.inventory_control_attempt (wh_inventory_id, attempted_at DESC)
  WHERE wh_inventory_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ica_result_attempted_at
  ON public.inventory_control_attempt (result, attempted_at DESC)
  WHERE result <> 'success';

CREATE INDEX IF NOT EXISTS idx_ica_product_attempted_at
  ON public.inventory_control_attempt (boonz_product_id, attempted_at DESC)
  WHERE boonz_product_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ica_correlation
  ON public.inventory_control_attempt (client_correlation_id);

CREATE INDEX IF NOT EXISTS idx_ica_attempted_by_attempted_at
  ON public.inventory_control_attempt (attempted_by, attempted_at DESC);

-- =====================================================================
-- RLS
-- =====================================================================
ALTER TABLE public.inventory_control_session ENABLE ROW LEVEL SECURITY;

CREATE POLICY ics_select ON public.inventory_control_session
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE id = (SELECT auth.uid())
        AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])
    )
  );

CREATE POLICY ics_insert ON public.inventory_control_session
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE id = (SELECT auth.uid())
        AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])
    )
  );

CREATE POLICY ics_no_update ON public.inventory_control_session
  FOR UPDATE USING (false);

CREATE POLICY ics_no_delete ON public.inventory_control_session
  FOR DELETE USING (false);

ALTER TABLE public.inventory_control_attempt ENABLE ROW LEVEL SECURITY;

CREATE POLICY ica_select ON public.inventory_control_attempt
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE id = (SELECT auth.uid())
        AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])
    )
  );

CREATE POLICY ica_insert ON public.inventory_control_attempt
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE id = (SELECT auth.uid())
        AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])
    )
    AND EXISTS (
      SELECT 1 FROM public.inventory_control_session ics
      WHERE ics.session_id = inventory_control_attempt.session_id
        AND ics.status = 'open'
    )
  );

CREATE POLICY ica_no_update ON public.inventory_control_attempt
  FOR UPDATE USING (false);

CREATE POLICY ica_no_delete ON public.inventory_control_attempt
  FOR DELETE USING (false);
