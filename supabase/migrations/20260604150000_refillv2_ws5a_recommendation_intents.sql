-- Refill reliability / WS5a - recommendation_intents table (Dara design). STATUS: DRAFT - NOT APPLIED.
--
-- Purpose (PRD WS5): a typed, human-in-the-loop bridge from free-text recommendations (driver / CS / Jojo /
-- Simran) to system wiring. Claude parses the text into one row per intent; a human confirms; only then does
-- an apply RPC write product_mapping.mix_weight (boonz-level) or route to the swap/decommission flow
-- (pod-level). This table is the audit-able intent ledger; it is NOT itself a refill protected entity, but it
-- gates real writes so it follows the same discipline (RLS on, writes via DEFINER RPCs only, status machine).
--
-- Status machine (Article 5): proposed -> confirmed -> applied | rejected. Set only by the WS5b RPCs.

CREATE TABLE IF NOT EXISTS public.recommendation_intents (
  intent_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id       uuid REFERENCES public.machines(machine_id) ON DELETE CASCADE,
  shelf_id         uuid REFERENCES public.shelf_configurations(shelf_id) ON DELETE SET NULL,
  level            text NOT NULL CHECK (level IN ('boonz','pod')),
  boonz_product_id uuid REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  pod_product_id   uuid REFERENCES public.pod_products(pod_product_id) ON DELETE SET NULL,
  action           text NOT NULL CHECK (action IN ('increase_weight','decrease_weight','add','remove','set_qty')),
  magnitude        numeric,                                   -- weight delta (boonz) or qty (set_qty); NULL = unspecified
  source           text NOT NULL CHECK (source IN ('driver','cs','jojo','simran','system')),
  raw_text         text NOT NULL,                             -- the original free-text the intent was parsed from
  status           text NOT NULL DEFAULT 'proposed'
                     CHECK (status IN ('proposed','confirmed','applied','rejected')),
  created_by       uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  confirmed_by     uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  confirmed_at     timestamptz,
  applied_at       timestamptz,
  apply_result     jsonb,                                     -- structured result of the apply (before/after weights)
  note             text,
  -- a boonz-level intent needs a boonz target; a pod-level intent needs a pod target
  CONSTRAINT rec_intent_target_coherence CHECK (
    (level = 'boonz' AND boonz_product_id IS NOT NULL) OR
    (level = 'pod'   AND pod_product_id   IS NOT NULL)
  )
);

COMMENT ON TABLE public.recommendation_intents IS
  'WS5: typed, human-confirmed recommendations parsed from free text. boonz-level -> product_mapping.mix_weight via apply_mix_weight_recommendation; pod-level -> swap/decommission flow. Status machine proposed->confirmed->applied|rejected, set only by WS5b RPCs.';

-- Indexes for the two access patterns: "intents for a machine by status" and "the proposed queue".
CREATE INDEX IF NOT EXISTS idx_rec_intents_machine_status ON public.recommendation_intents (machine_id, status);
CREATE INDEX IF NOT EXISTS idx_rec_intents_status_created ON public.recommendation_intents (status, created_at DESC);

ALTER TABLE public.recommendation_intents ENABLE ROW LEVEL SECURITY;

-- Read for operator/manager roles; NO direct writes (all writes go through the WS5b DEFINER RPCs).
DROP POLICY IF EXISTS rec_intents_select ON public.recommendation_intents;
CREATE POLICY rec_intents_select ON public.recommendation_intents
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = (SELECT auth.uid())
      AND up.role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ));

DROP POLICY IF EXISTS rec_intents_no_insert ON public.recommendation_intents;
CREATE POLICY rec_intents_no_insert ON public.recommendation_intents FOR INSERT TO authenticated WITH CHECK (false);
DROP POLICY IF EXISTS rec_intents_no_update ON public.recommendation_intents;
CREATE POLICY rec_intents_no_update ON public.recommendation_intents FOR UPDATE TO authenticated USING (false);
DROP POLICY IF EXISTS rec_intents_no_delete ON public.recommendation_intents;
CREATE POLICY rec_intents_no_delete ON public.recommendation_intents FOR DELETE TO authenticated USING (false);
