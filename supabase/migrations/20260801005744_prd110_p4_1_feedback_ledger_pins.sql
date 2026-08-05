SET LOCAL statement_timeout = '90s';

-- ============================================================================
-- PRD-110 P4.1 + P4.2 — feedback ledger, gated proposal queue, planning pins.
-- Design: docs/prds/PRD-110-P4-DARA-feedback-pins-design.md (Dara)
-- Review: Cody ⚠️ approve-with-revisions, leg 79. All five revisions applied:
--   (1) cardinality() not array_length() — a NULL CHECK PASSES, so the
--       provenance invariant was inert as designed.
--   (2) view gets security_invoker + REVOKE from anon/PUBLIC/authenticated.
--   (3) system-expiry actor so a lapsed pin can leave the uniqueness slot.
--   (4) 'superseded' exempt from the reviewer check (system action).
--   (5) REVOKE before GRANT, privileges read back naming `authenticated`
--       (ADR-shadow-plan-tables §11.3: a GRANT is additive and cannot narrow).
-- Article 14: NOT a materialization — state no view can derive. No ADR (S-03).
-- ============================================================================

-- ---------- P4.1a  feedback_ledger_v3 ----------
CREATE TABLE IF NOT EXISTS public.feedback_ledger_v3 (
  feedback_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  channel            text NOT NULL CHECK (channel IN ('driver','client','cs','miner')),
  driver_rec_id      uuid REFERENCES public.driver_recommendations(rec_id) ON DELETE SET NULL,
  machine_id         uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id           uuid     REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id   uuid     REFERENCES public.boonz_products(product_id)     ON DELETE RESTRICT,
  intent             text NOT NULL CHECK (intent IN
                       ('dont_reduce','always_stock','never_stock','more_facings',
                        'less_facings','wrong_product','machine_issue','other')),
  note               text NOT NULL CHECK (length(trim(note)) >= 10),
  submitted_by       uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  status             text NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open','proposed','dismissed')),
  triaged_at         timestamptz,
  triage_note        text,
  CONSTRAINT chk_fbl_v3_driver_channel
    CHECK ((channel = 'driver') = (driver_rec_id IS NOT NULL)),
  CONSTRAINT chk_fbl_v3_triage
    CHECK ((status = 'open') = (triaged_at IS NULL))
);
COMMENT ON TABLE public.feedback_ledger_v3 IS
  'PRD-110 P4.1. Append-only raw feedback, all channels. Driver rows WRAP driver_recommendations (driver_rec_id) rather than restating them. RPC-only writers. Design doc: docs/prds/PRD-110-P4-DARA-feedback-pins-design.md';

-- ---------- P4.1b  feedback_proposals_v3 ----------
CREATE TABLE IF NOT EXISTS public.feedback_proposals_v3 (
  proposal_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date          date NOT NULL,
  proposed_at        timestamptz NOT NULL DEFAULT now(),
  machine_id         uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id           uuid     REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id   uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  pin_kind           text NOT NULL CHECK (pin_kind IN
                       ('min_facing','protect_depth','always_stock','never_stock')),
  pin_value          integer CHECK (pin_value IS NULL OR pin_value >= 0),
  pin_mode           text NOT NULL CHECK (pin_mode IN ('perpetual','until')),
  pin_expires_at     timestamptz,
  feedback_ids       uuid[] NOT NULL,
  trigger_reason     text NOT NULL,
  scoring_breakdown  jsonb NOT NULL DEFAULT '{}'::jsonb,
  status             text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','approved','rejected','superseded')),
  reviewed_by        uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  reviewed_at        timestamptz,
  review_note        text,
  applied_pin_id     uuid,
  -- Cody revision (1): cardinality(), because array_length('{}',1) IS NULL and a
  -- CHECK evaluating to NULL PASSES. As designed this constraint was inert.
  CONSTRAINT chk_fpr_v3_evidence CHECK (cardinality(feedback_ids) >= 1),
  CONSTRAINT chk_fpr_v3_mode  CHECK ((pin_mode = 'until') = (pin_expires_at IS NOT NULL)),
  CONSTRAINT chk_fpr_v3_value CHECK (
    (pin_kind IN ('min_facing','protect_depth') AND pin_value IS NOT NULL AND pin_value >= 1)
 OR (pin_kind IN ('always_stock','never_stock')  AND pin_value IS NULL)),
  -- Cody revision (4): supersede is a SYSTEM action and carries no reviewer.
  CONSTRAINT chk_fpr_v3_review CHECK (
    (status = 'pending'    AND reviewed_at IS NULL)
 OR (status = 'superseded')
 OR (status IN ('approved','rejected') AND reviewed_at IS NOT NULL))
);
COMMENT ON TABLE public.feedback_proposals_v3 IS
  'PRD-110 P4.1. Gated proposal queue. Column order and status vocabulary deliberately mirror rotation_proposals_v3 / facing_proposals_v3 / reallocation_proposals_v3 so one CS board renders all four.';

-- ---------- P4.2  planning_pins_v3 ----------
CREATE TABLE IF NOT EXISTS public.planning_pins_v3 (
  pin_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  machine_id         uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  shelf_id           uuid     REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  boonz_product_id   uuid NOT NULL REFERENCES public.boonz_products(product_id) ON DELETE RESTRICT,
  kind               text NOT NULL CHECK (kind IN
                       ('min_facing','protect_depth','always_stock','never_stock')),
  value              integer CHECK (value IS NULL OR value >= 0),
  mode               text NOT NULL CHECK (mode IN ('perpetual','until')),
  expires_at         timestamptz,
  source             text NOT NULL DEFAULT 'feedback'
                       CHECK (source IN ('feedback','cs_direct')),
  feedback_ids       uuid[] NOT NULL DEFAULT '{}'::uuid[],
  proposal_id        uuid REFERENCES public.feedback_proposals_v3(proposal_id) ON DELETE RESTRICT,
  created_by         uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  revoked_at         timestamptz,
  revoked_by         uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  revoke_reason      text,
  CONSTRAINT chk_pin_v3_mode  CHECK ((mode = 'until') = (expires_at IS NOT NULL)),
  CONSTRAINT chk_pin_v3_value CHECK (
    (kind IN ('min_facing','protect_depth') AND value IS NOT NULL AND value >= 1)
 OR (kind IN ('always_stock','never_stock')  AND value IS NULL)),
  -- Cody revision (1) again: cardinality(), same NULL-CHECK trap.
  CONSTRAINT chk_pin_v3_provenance CHECK (
    source = 'cs_direct' OR cardinality(feedback_ids) >= 1),
  -- Cody revision (3): a lapsed pin must be able to LEAVE the uniqueness slot.
  -- The partial unique index below cannot test expiry (now() is not IMMUTABLE),
  -- so expiry is materialised by stamping revoked_at with revoke_reason
  -- 'expired_system' and NO human revoker. Without this exemption an until-mode
  -- pin would occupy its slot forever and could never be re-minted.
  CONSTRAINT chk_pin_v3_revoke CHECK (
    (revoked_at IS NULL  AND revoked_by IS NULL AND revoke_reason IS NULL)
 OR (revoked_at IS NOT NULL AND revoke_reason = 'expired_system' AND revoked_by IS NULL)
 OR (revoked_at IS NOT NULL AND revoke_reason IS NOT NULL AND revoke_reason <> 'expired_system'
     AND revoked_by IS NOT NULL))
);
COMMENT ON TABLE public.planning_pins_v3 IS
  'PRD-110 P4.2. Standing planning constraints. Revocation is a SUPERSEDE (revoked_at), never UPDATE-in-place and never DELETE, so the fixture-16 provenance chain survives. Engines read v_planning_pins_active_v3, never this table.';

ALTER TABLE public.feedback_proposals_v3
  DROP CONSTRAINT IF EXISTS fpr_v3_applied_pin_fk;
ALTER TABLE public.feedback_proposals_v3
  ADD CONSTRAINT fpr_v3_applied_pin_fk
  FOREIGN KEY (applied_pin_id) REFERENCES public.planning_pins_v3(pin_id) ON DELETE SET NULL;

-- ---------- indexes ----------
CREATE INDEX IF NOT EXISTS ix_fbl_v3_machine_open
  ON public.feedback_ledger_v3 (machine_id, created_at DESC) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS ix_fpr_v3_pending
  ON public.feedback_proposals_v3 (plan_date, proposed_at DESC) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS ix_pin_v3_lookup
  ON public.planning_pins_v3 (machine_id, boonz_product_id, kind) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_pin_v3_active_one_per_kind
  ON public.planning_pins_v3
     (machine_id, coalesce(shelf_id,'00000000-0000-0000-0000-000000000000'::uuid),
      boonz_product_id, kind)
  WHERE revoked_at IS NULL;
-- The contradiction guard as pure DDL: always_stock and never_stock share ONE
-- uniqueness bucket, so an incoherent pair raises 23505 rather than needing a
-- trigger that is racy and droppable.
CREATE UNIQUE INDEX IF NOT EXISTS ux_pin_v3_stock_policy_exclusive
  ON public.planning_pins_v3
     (machine_id, coalesce(shelf_id,'00000000-0000-0000-0000-000000000000'::uuid),
      boonz_product_id)
  WHERE revoked_at IS NULL AND kind IN ('always_stock','never_stock');

-- ---------- canonical read object (Article 16) ----------
CREATE OR REPLACE VIEW public.v_planning_pins_active_v3
WITH (security_invoker = true) AS      -- Cody revision (2) / ADR §7
SELECT p.*,
       (p.expires_at IS NOT NULL) AS is_time_boxed,
       CASE WHEN p.expires_at IS NULL THEN NULL
            ELSE GREATEST(0, EXTRACT(day FROM p.expires_at - now())::int) END AS days_remaining
FROM public.planning_pins_v3 p
WHERE p.revoked_at IS NULL
  AND (p.expires_at IS NULL OR p.expires_at > now());
COMMENT ON VIEW public.v_planning_pins_active_v3 IS
  'PRD-110 P4.2 CANONICAL (Article 16). The ONLY definition of an active pin: not revoked AND not expired. Engines and L0 read this; never planning_pins_v3 directly.';

-- ---------- RLS + the ACL (S-88: RLS is not a write guard, THE GRANT is) ----------
ALTER TABLE public.feedback_ledger_v3    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feedback_proposals_v3 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.planning_pins_v3      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fbl_v3_select ON public.feedback_ledger_v3;
DROP POLICY IF EXISTS fpr_v3_select ON public.feedback_proposals_v3;
DROP POLICY IF EXISTS pin_v3_select ON public.planning_pins_v3;
CREATE POLICY fbl_v3_select ON public.feedback_ledger_v3    FOR SELECT TO authenticated USING (true);
CREATE POLICY fpr_v3_select ON public.feedback_proposals_v3 FOR SELECT TO authenticated USING (true);
CREATE POLICY pin_v3_select ON public.planning_pins_v3      FOR SELECT TO authenticated USING (true);

-- ⛔ REVOKE FIRST. Supabase default privileges have ALREADY granted ALL to
-- `authenticated` by the time CREATE TABLE returns, so a bare GRANT SELECT is a
-- no-op that reads like a lockdown (ADR §11.2). Cody revision (5) adds the view.
REVOKE ALL ON public.feedback_ledger_v3, public.feedback_proposals_v3,
              public.planning_pins_v3, public.v_planning_pins_active_v3
       FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.feedback_ledger_v3, public.feedback_proposals_v3,
                public.planning_pins_v3, public.v_planning_pins_active_v3
      TO authenticated;

-- ---------- read the privilege state BACK (ADR §11.3: the statement is not the state) ----------
DO $verify$
DECLARE
  v_bad text := '';
  v_obj text;
  v_sel int; v_dml int; v_anon int;
BEGIN
  FOREACH v_obj IN ARRAY ARRAY['feedback_ledger_v3','feedback_proposals_v3',
                               'planning_pins_v3','v_planning_pins_active_v3'] LOOP
    -- ⚠️ names `authenticated` explicitly. Fixture 36/37 passed vacuously by
    -- checking `anon`, which correctly held nothing while authenticated held ALL.
    SELECT count(*) INTO v_sel  FROM information_schema.role_table_grants
      WHERE table_schema='public' AND table_name=v_obj
        AND grantee='authenticated' AND privilege_type='SELECT';
    SELECT count(*) INTO v_dml  FROM information_schema.role_table_grants
      WHERE table_schema='public' AND table_name=v_obj
        AND grantee='authenticated' AND privilege_type <> 'SELECT';
    SELECT count(*) INTO v_anon FROM information_schema.role_table_grants
      WHERE table_schema='public' AND table_name=v_obj AND grantee IN ('anon','PUBLIC');
    IF v_sel <> 1 THEN v_bad := v_bad || format(' [%s: authenticated SELECT=%s want 1]', v_obj, v_sel); END IF;
    IF v_dml <> 0 THEN v_bad := v_bad || format(' [%s: authenticated non-SELECT=%s want 0]', v_obj, v_dml); END IF;
    IF v_anon <> 0 THEN v_bad := v_bad || format(' [%s: anon/PUBLIC grants=%s want 0]', v_obj, v_anon); END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'P4.1 ACL VERIFY FAILED:%', v_bad; END IF;

  -- prove the NULL-CHECK trap is actually closed, not just reworded
  BEGIN
    INSERT INTO public.feedback_proposals_v3
      (plan_date, machine_id, boonz_product_id, pin_kind, pin_value, pin_mode,
       feedback_ids, trigger_reason)
    VALUES (DATE '2030-06-01',
            (SELECT machine_id FROM public.machines LIMIT 1),
            (SELECT product_id FROM public.boonz_products LIMIT 1),
            'protect_depth', 3, 'perpetual', '{}'::uuid[], 'evidence-free probe');
    RAISE EXCEPTION 'P4.1 VERIFY FAILED: an evidence-free proposal was accepted';
  EXCEPTION
    WHEN check_violation THEN NULL;   -- expected: chk_fpr_v3_evidence bit
  END;

  RAISE NOTICE 'P4.1 verify OK: ACL tight on 4 objects, evidence CHECK bites.';
END
$verify$;
