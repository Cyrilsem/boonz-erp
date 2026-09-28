-- Loop 2026-09-25 C2 (PRD-134): knowledge tables, seed data only, no scoring logic reads these
-- yet. product_lane_fit, sku_intents and cannibal_pairs all reference real, verified pod_products
-- and boonz_products rows (checked live before writing any seed row, none guessed):
--   Dubai Popcorn      31c78eac-d859-41d7-8ba1-6d5cee5381ff (pod)
--   Vitamin Well       ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239 (pod)
--   Zigi               da115e6f-8d9b-48ab-b998-531cb81d3faa (pod, the generic line; it has 7
--                      boonz flavour variants, so the fleet-wide temp_out intent is recorded at
--                      the pod level, not pinned to one arbitrary flavour)
--   Krambals           27444f0d-7d3c-4480-bbdc-4faf60acbdbc (pod, same reasoning: 5 flavours)
--   Smart Gourmet Hummus 13f4681e-999a-4f66-b778-fd398ae0a446 (pod)
--   Nutella Biscuits T3  0e74abc0-da3e-43ac-b462-1425bd26dc5e (pod)
--   Nutella Biscuits T12 7998f596-3cb3-45ea-81d2-2eb1fe1eded9 (pod)
--   Red Bull - 355ML   e21bae75-cdeb-42a9-b6ad-df8f5d4166dc (boonz SKU, the specific variant this
--                      intent is about; machine-scoped to AMZ-1029-3003-O1 f1a528fb-15e8-4f20-
--                      b4e2-ebb2e6852198, the same machine and product this loop's A6 step
--                      already worked with)
--
-- RLS posture is deliberately different from the earlier B1/B4 tables in this loop: those wanted
-- no client write path at all (writes only via elevated/service-role access), so INSERT/UPDATE/
-- DELETE were revoked from authenticated entirely. Here the task asks for a real, working
-- operator_admin write path, so authenticated KEEPS its default write grant and an RLS policy
-- restricts actual use to operator_admin/superadmin, the same role-lookup pattern already used
-- elsewhere in this codebase (EXISTS against user_profiles.role). anon and PUBLIC get nothing.

CREATE TABLE public.product_lane_fit (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pod_product_id uuid NOT NULL REFERENCES public.pod_products(pod_product_id),
  shelf_code     text NOT NULL,
  note           text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid,
  UNIQUE (pod_product_id, shelf_code)
);

CREATE TABLE public.sku_intents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  boonz_product_id  uuid REFERENCES public.boonz_products(product_id),
  pod_product_id    uuid REFERENCES public.pod_products(pod_product_id),
  machine_id        uuid REFERENCES public.machines(machine_id),
  intent            text NOT NULL CHECK (intent IN ('deplete','temp_out','keep','push')),
  threshold         integer,
  eta_date          date,
  note              text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid,
  CHECK (boonz_product_id IS NOT NULL OR pod_product_id IS NOT NULL)
);

CREATE TABLE public.cannibal_pairs (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pod_product_a_id   uuid NOT NULL REFERENCES public.pod_products(pod_product_id),
  pod_product_b_id   uuid NOT NULL REFERENCES public.pod_products(pod_product_id),
  note               text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  CHECK (pod_product_a_id <> pod_product_b_id)
);

ALTER TABLE public.product_lane_fit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sku_intents      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cannibal_pairs   ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.product_lane_fit FROM anon, PUBLIC;
REVOKE ALL ON public.sku_intents      FROM anon, PUBLIC;
REVOKE ALL ON public.cannibal_pairs   FROM anon, PUBLIC;

CREATE POLICY product_lane_fit_authenticated_select ON public.product_lane_fit
  FOR SELECT TO authenticated USING (true);
CREATE POLICY product_lane_fit_operator_admin_write ON public.product_lane_fit
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles
                  WHERE user_profiles.id = (SELECT auth.uid())
                    AND user_profiles.role IN ('operator_admin','superadmin')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
                        WHERE user_profiles.id = (SELECT auth.uid())
                          AND user_profiles.role IN ('operator_admin','superadmin')));

CREATE POLICY sku_intents_authenticated_select ON public.sku_intents
  FOR SELECT TO authenticated USING (true);
CREATE POLICY sku_intents_operator_admin_write ON public.sku_intents
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles
                  WHERE user_profiles.id = (SELECT auth.uid())
                    AND user_profiles.role IN ('operator_admin','superadmin')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
                        WHERE user_profiles.id = (SELECT auth.uid())
                          AND user_profiles.role IN ('operator_admin','superadmin')));

CREATE POLICY cannibal_pairs_authenticated_select ON public.cannibal_pairs
  FOR SELECT TO authenticated USING (true);
CREATE POLICY cannibal_pairs_operator_admin_write ON public.cannibal_pairs
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles
                  WHERE user_profiles.id = (SELECT auth.uid())
                    AND user_profiles.role IN ('operator_admin','superadmin')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
                        WHERE user_profiles.id = (SELECT auth.uid())
                          AND user_profiles.role IN ('operator_admin','superadmin')));

INSERT INTO public.product_lane_fit (pod_product_id, shelf_code, note) VALUES
  ('31c78eac-d859-41d7-8ba1-6d5cee5381ff', 'A15', 'Dubai Popcorn fits A15 and A16 only'),
  ('31c78eac-d859-41d7-8ba1-6d5cee5381ff', 'A16', 'Dubai Popcorn fits A15 and A16 only');

INSERT INTO public.sku_intents (boonz_product_id, pod_product_id, machine_id, intent, threshold, eta_date, note) VALUES
  ('e21bae75-cdeb-42a9-b6ad-df8f5d4166dc', NULL, 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198',
   'deplete', 4, NULL, 'Red bull 355ML deplete on AMZ-1029-3003-O1, threshold 4'),
  (NULL, 'da115e6f-8d9b-48ab-b998-531cb81d3faa', NULL,
   'temp_out', NULL, '2026-10-02', 'Zigi temp_out fleet-wide, ETA 2026-10-02'),
  (NULL, '13f4681e-999a-4f66-b778-fd398ae0a446', NULL,
   'temp_out', NULL, NULL, 'Smart Gourmet Hummus temp_out fleet-wide'),
  (NULL, '27444f0d-7d3c-4480-bbdc-4faf60acbdbc', NULL,
   'keep', NULL, NULL, 'Krambals keep'),
  (NULL, 'ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239', NULL,
   'push', NULL, NULL, 'Vitamin Well push to top machines');

INSERT INTO public.cannibal_pairs (pod_product_a_id, pod_product_b_id, note) VALUES
  ('0e74abc0-da3e-43ac-b462-1425bd26dc5e', '7998f596-3cb3-45ea-81d2-2eb1fe1eded9',
   'Nutella Biscuits T3 vs Nutella Biscuits T12');
