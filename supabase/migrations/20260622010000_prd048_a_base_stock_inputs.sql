-- PRD-048 Step A: base-stock sizing INPUTS (additive config only, no protected entity touched)
-- machine_service_policy (route interval T, fallback z, class) + refill_policy_params (singleton, holds kill-switch flag)
-- Dara design (✅) -> Cody review -> applied via Supabase MCP. NOT git-committed in this pass.

-- 1) Per-machine service policy
CREATE TABLE IF NOT EXISTS public.machine_service_policy (
  machine_id         uuid PRIMARY KEY REFERENCES public.machines(machine_id) ON DELETE CASCADE,
  machine_class      text NOT NULL CHECK (machine_class IN ('busy','standard','backup')),
  trip_interval_days int  NOT NULL CHECK (trip_interval_days BETWEEN 1 AND 90),
  z_default          numeric NOT NULL DEFAULT 1.65,
  source             text NOT NULL DEFAULT 'seed_velocity_tertile',
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.machine_service_policy IS
  'PRD-048 ADD-brain base-stock: per-machine route interval T (days) + fallback service z. Class seeded by velocity tertile (busy>=0.278/day=12d, standard 0.128..0.278=21d, backup<0.128=30d). CS-tunable.';

-- 2) Global policy params (singleton). refill_sizing_mode is the kill-switch: legacy => byte-identical to v18.
CREATE TABLE IF NOT EXISTS public.refill_policy_params (
  id                  int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  refill_sizing_mode  text NOT NULL DEFAULT 'legacy' CHECK (refill_sizing_mode IN ('legacy','base_stock')),
  min_fill_pct        numeric NOT NULL DEFAULT 0.70,
  seller_wk_threshold numeric NOT NULL DEFAULT 1.5,
  ewma_w7             numeric NOT NULL DEFAULT 0.7,
  ewma_w30            numeric NOT NULL DEFAULT 0.3,
  z_low               numeric NOT NULL DEFAULT 1.28,
  z_mid               numeric NOT NULL DEFAULT 1.65,
  z_high              numeric NOT NULL DEFAULT 2.05,
  margin_low_cut      numeric NOT NULL DEFAULT 0.371,
  margin_high_cut     numeric NOT NULL DEFAULT 0.514,
  spoilage_factor     numeric NOT NULL DEFAULT 0.8,
  cold_start_days     int     NOT NULL DEFAULT 14,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL
);
COMMENT ON TABLE public.refill_policy_params IS
  'PRD-048 singleton policy bag. refill_sizing_mode=legacy keeps engine_add_pod byte-identical to v18; base_stock activates the service-level order-up-to policy. CS-tunable without code change.';

-- RLS: read any authenticated; write operator_admin/superadmin (engine reads via SECURITY DEFINER, RLS never gates it)
ALTER TABLE public.machine_service_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refill_policy_params   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS msp_select ON public.machine_service_policy;
DROP POLICY IF EXISTS msp_write  ON public.machine_service_policy;
CREATE POLICY msp_select ON public.machine_service_policy FOR SELECT TO authenticated USING (true);
CREATE POLICY msp_write  ON public.machine_service_policy FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role = ANY(ARRAY['operator_admin','superadmin'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role = ANY(ARRAY['operator_admin','superadmin'])));

DROP POLICY IF EXISTS rpp_select ON public.refill_policy_params;
DROP POLICY IF EXISTS rpp_write  ON public.refill_policy_params;
CREATE POLICY rpp_select ON public.refill_policy_params FOR SELECT TO authenticated USING (true);
CREATE POLICY rpp_write  ON public.refill_policy_params FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role = ANY(ARRAY['operator_admin','superadmin'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role = ANY(ARRAY['operator_admin','superadmin'])));

-- 3) Seed singleton (flag OFF / legacy by default)
INSERT INTO public.refill_policy_params (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

-- 4) Seed machine_service_policy for active, include_in_refill machines by velocity tertile
INSERT INTO public.machine_service_policy (machine_id, machine_class, trip_interval_days, z_default, source)
SELECT mv.machine_id,
       CASE WHEN mv.daily_vel >= 0.278 THEN 'busy'
            WHEN mv.daily_vel >= 0.128 THEN 'standard'
            ELSE 'backup' END AS machine_class,
       CASE WHEN mv.daily_vel >= 0.278 THEN 12
            WHEN mv.daily_vel >= 0.128 THEN 21
            ELSE 30 END AS trip_interval_days,
       1.65, 'seed_velocity_tertile'
FROM (
  SELECT m.machine_id, COALESCE(SUM(sl.velocity_30d),0)/30.0 AS daily_vel
  FROM public.machines m
  LEFT JOIN public.slot_lifecycle sl
    ON sl.machine_id=m.machine_id AND sl.is_current = true AND sl.archived = false
  WHERE m.status='Active' AND m.include_in_refill = true
  GROUP BY m.machine_id
) mv
ON CONFLICT (machine_id) DO NOTHING;
