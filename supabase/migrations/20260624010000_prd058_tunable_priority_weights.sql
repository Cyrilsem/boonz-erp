-- PRD-058: tunable P1/P2 priority weights + dead-stock dial.
-- ONE config table (refill_priority_params, single row) feeding the ONE canonical
-- view v_machine_priority (Article 16). Seeded EXACTLY to today's baked-in literals so
-- the view is byte-identical on deploy (golden test T1: fleet md5 unchanged).
-- No consumer change: get_machine_health() + pick_machines_for_refill read the view as-is.
-- Dara design ✅ -> Cody review -> applied via Supabase MCP ONLY after CS go-ahead. Forward-only.

-- ── 1) config table ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.refill_priority_params (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  w_empty_base        numeric NOT NULL DEFAULT 50,
  w_empty_step        numeric NOT NULL DEFAULT 12,
  w_empty_cap         numeric NOT NULL DEFAULT 36,
  w_runway_lt2        numeric NOT NULL DEFAULT 40,
  w_runway_strong_lt4 numeric NOT NULL DEFAULT 35,
  w_runway_lt3        numeric NOT NULL DEFAULT 28,
  w_runway_lt5_vel30  numeric NOT NULL DEFAULT 15,
  w_fill_lt40_vel20   numeric NOT NULL DEFAULT 30,
  w_fill_lt50_vel20   numeric NOT NULL DEFAULT 22,
  w_fill_lt60_vel50   numeric NOT NULL DEFAULT 15,
  w_under25_step      numeric NOT NULL DEFAULT 10,
  w_under25_cap       numeric NOT NULL DEFAULT 30,
  w_high_velocity     numeric NOT NULL DEFAULT 8,
  w_stale_21          numeric NOT NULL DEFAULT 10,
  w_stale_14          numeric NOT NULL DEFAULT 6,
  w_stale_10          numeric NOT NULL DEFAULT 3,
  w_expired_now        numeric NOT NULL DEFAULT 20,
  w_dead_slot_30       numeric NOT NULL DEFAULT 10,
  w_dead_slot_15       numeric NOT NULL DEFAULT 5,
  dead_stock_forces_p1 boolean NOT NULL DEFAULT true,
  p1_expired_min_skus  numeric NOT NULL DEFAULT 1,
  p2_dead_slot_pct     numeric NOT NULL DEFAULT 30,
  p2_stale_days        numeric NOT NULL DEFAULT 14,
  p1_runway_crit    numeric NOT NULL DEFAULT 3,
  p1_strong_units   numeric NOT NULL DEFAULT 50,
  p1_strong_runway  numeric NOT NULL DEFAULT 4,
  p1_fill_pct       numeric NOT NULL DEFAULT 50,
  p1_fill_units     numeric NOT NULL DEFAULT 20,
  p1_under25_count  numeric NOT NULL DEFAULT 2,
  p1_under25_units  numeric NOT NULL DEFAULT 20,
  w_intent          numeric NOT NULL DEFAULT 5,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL
);
COMMENT ON TABLE public.refill_priority_params IS
  'PRD-058 single-row tunable weights/thresholds for v_machine_priority (P1/P2). One row (id=1). Seeded to the values baked into the view as of 2026-06-24; defaults => byte-identical p_tier/p_score. dead_stock_forces_p1=false + w_expired_now=0 deprioritizes dead stock out of P1.';

-- seed the single row with all defaults (= today's literals). MUST exist: v_machine_priority
-- CROSS JOINs this row, so an absent row would empty the view (cards + picker).
INSERT INTO public.refill_priority_params (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.refill_priority_params ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rpp_prio_select ON public.refill_priority_params;
DROP POLICY IF EXISTS rpp_prio_write  ON public.refill_priority_params;
-- SELECT unconditional (true): the view CROSS JOINs this row; a role-scoped SELECT that
-- hid it would silently empty v_machine_priority for that reader. Never narrow this.
CREATE POLICY rpp_prio_select ON public.refill_priority_params FOR SELECT TO authenticated USING (true);
CREATE POLICY rpp_prio_write  ON public.refill_priority_params FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role = ANY(ARRAY['operator_admin','superadmin','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role = ANY(ARRAY['operator_admin','superadmin','manager'])));

-- ── 2) param-driven v_machine_priority ───────────────────────────────────────
-- CROSS JOIN refill_priority_params p; every tunable literal replaced by p.<col>.
-- Score-internal comparison constants without a named param (runway<2/<5, units>=30,
-- fill<40/<60, dead_slot>=15, days>=21/>=10) stay literal per PRD (only weights + tier
-- gates + dead dial are tunable). reasons_arr is UNCHANGED.
CREATE OR REPLACE VIEW public.v_machine_priority AS
 WITH shelf_u25 AS (
   SELECT vls.machine_id,
     count(*) FILTER (WHERE vls.is_enabled AND vls.current_stock > 0 AND vls.fill_pct < 25) AS under25
   FROM v_live_shelf_stock vls
   GROUP BY vls.machine_id
 )
 SELECT s.machine_id,
   s.official_name, s.venue_group, s.location_type, s.building_id, s.dead_slot_pct,
   s.empty_shelf_pct, s.fill_pct, s.hero_slot_count, s.expired_skus_now, s.expired_skus_30d,
   s.days_since_visit, s.units_last_7d, s.is_ramping, s.active_intent_count, s.tier,
   s.empty_shelves_count, s.cur_stock, s.expired_skus_3d, s.expired_skus_7d, s.runway_days,
   m.include_in_refill,
   COALESCE(m.status, 'Active'::text) AS machine_status,
   COALESCE(u.under25, 0::bigint) AS under25,
   CASE WHEN s.venue_group = 'VOX'::text THEN 'vox'::text ELSE 'main'::text END AS svc_track,
   CASE
     WHEN s.units_last_7d > 0 AND (
            s.empty_shelves_count >= 1
            OR (s.runway_days IS NOT NULL AND s.runway_days < p.p1_runway_crit)
            OR (s.units_last_7d >= p.p1_strong_units AND s.runway_days IS NOT NULL AND s.runway_days < p.p1_strong_runway)
            OR (s.fill_pct < p.p1_fill_pct AND s.units_last_7d >= p.p1_fill_units)
            OR (COALESCE(u.under25, 0::bigint) >= p.p1_under25_count AND s.units_last_7d >= p.p1_under25_units)
            OR (p.dead_stock_forces_p1 AND s.expired_skus_now >= p.p1_expired_min_skus)
          ) THEN 'P1_RESTOCK'::text
     WHEN s.dead_slot_pct >= p.p2_dead_slot_pct
            OR s.days_since_visit >= p.p2_stale_days
            OR s.active_intent_count > 0
            OR (s.empty_shelves_count >= 1 AND COALESCE(s.units_last_7d, 0) = 0) THEN 'P2_MAINTAIN'::text
     ELSE 'P3_OK'::text
   END AS p_tier,
   (
     CASE WHEN s.empty_shelves_count >= 1 THEN p.w_empty_base + LEAST((s.empty_shelves_count - 1) * p.w_empty_step, p.w_empty_cap) ELSE 0 END
     + CASE
         WHEN s.runway_days < 2::numeric THEN p.w_runway_lt2
         WHEN s.units_last_7d >= p.p1_strong_units AND s.runway_days < p.p1_strong_runway THEN p.w_runway_strong_lt4
         WHEN s.runway_days < p.p1_runway_crit THEN p.w_runway_lt3
         WHEN s.runway_days < 5::numeric AND s.units_last_7d >= 30 THEN p.w_runway_lt5_vel30
         ELSE 0 END
     + CASE
         WHEN s.fill_pct < 40::numeric AND s.units_last_7d >= p.p1_fill_units THEN p.w_fill_lt40_vel20
         WHEN s.fill_pct < p.p1_fill_pct AND s.units_last_7d >= p.p1_fill_units THEN p.w_fill_lt50_vel20
         WHEN s.fill_pct < 60::numeric AND s.units_last_7d >= p.p1_strong_units THEN p.w_fill_lt60_vel50
         ELSE 0 END
     + CASE WHEN s.units_last_7d >= p.p1_under25_units THEN LEAST(COALESCE(u.under25, 0::bigint) * p.w_under25_step, p.w_under25_cap) ELSE 0 END
     + CASE WHEN p.dead_stock_forces_p1 AND s.expired_skus_now >= p.p1_expired_min_skus THEN p.w_expired_now ELSE 0 END
     + CASE WHEN s.units_last_7d >= p.p1_strong_units THEN p.w_high_velocity ELSE 0 END
     + CASE
         WHEN s.days_since_visit >= 21 THEN p.w_stale_21
         WHEN s.days_since_visit >= p.p2_stale_days THEN p.w_stale_14
         WHEN s.days_since_visit >= 10 THEN p.w_stale_10
         ELSE 0 END
     + CASE
         WHEN s.dead_slot_pct >= p.p2_dead_slot_pct THEN p.w_dead_slot_30
         WHEN s.dead_slot_pct >= 15::numeric THEN p.w_dead_slot_15
         ELSE 0 END
     + CASE WHEN s.active_intent_count > 0 THEN p.w_intent ELSE 0 END
   )::numeric(6,2) AS p_score,
   array_remove(ARRAY[
     CASE WHEN s.empty_shelves_count > 1 THEN 'empty_multi'::text ELSE NULL::text END,
     CASE WHEN s.empty_shelves_count = 1 THEN 'empty_one'::text ELSE NULL::text END,
     CASE WHEN s.runway_days IS NOT NULL AND s.runway_days < 3::numeric THEN 'runway_critical'::text ELSE NULL::text END,
     CASE WHEN s.units_last_7d >= 50 AND s.runway_days IS NOT NULL AND s.runway_days < 4::numeric THEN 'strong_seller_low_runway'::text ELSE NULL::text END,
     CASE WHEN s.fill_pct < 50::numeric AND s.units_last_7d >= 20 THEN 'low_fill'::text ELSE NULL::text END,
     CASE WHEN s.units_last_7d >= 20 AND COALESCE(u.under25, 0::bigint) >= 2 THEN 'shelves_under25'::text ELSE NULL::text END,
     CASE WHEN s.expired_skus_now >= 1 THEN 'expired_now'::text ELSE NULL::text END,
     CASE WHEN s.units_last_7d >= 50 THEN 'high_velocity'::text ELSE NULL::text END,
     CASE WHEN s.dead_slot_pct >= 30::numeric THEN 'dead_slots'::text ELSE NULL::text END,
     CASE WHEN s.days_since_visit >= 14 THEN 'stale'::text ELSE NULL::text END,
     CASE WHEN s.active_intent_count > 0 THEN 'intent'::text ELSE NULL::text END], NULL::text) AS reasons_arr,
   COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster
  FROM v_machine_health_signals s
    JOIN machines m ON m.machine_id = s.machine_id
    LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
    CROSS JOIN public.refill_priority_params p;
