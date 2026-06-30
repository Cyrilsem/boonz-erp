-- Phase F: shelf-level service-level prioritisation, shadow/diagnostic only.
-- GENERATED FROM LIVE PROD for git parity (PRD-ALL overnight run, 2026-06-30).
-- Already applied as supabase_migrations version 20260625203113. Idempotent. Do not re-run.
--
-- Additive: new config table + read-only view. Does NOT touch v_machine_priority,
-- get_machine_health, or pick_machines_for_refill. Cody-approved (Arts 2,4,12,13,14).
-- Deprecation note: promote via a separate Dara->Cody cutover within ~30 days, else REVOKE/DROP.

CREATE TABLE IF NOT EXISTS public.service_priority_params (
  id              int PRIMARY KEY DEFAULT 1 CHECK (id = 1),  -- singleton config row
  horizon_days    numeric NOT NULL DEFAULT 7,    -- A/B shelf "at risk" if it empties within this many days
  a_floor_day     numeric NOT NULL DEFAULT 0.5,  -- daily velocity >= this => A-item (>=15/mo)
  b_floor_day     numeric NOT NULL DEFAULT 0.2,  -- daily velocity >= this => B-item (>=6/mo)
  p1_rev_floor    numeric NOT NULL DEFAULT 15,   -- AED/day at risk to justify a P1 visit
  a_crit_dos      numeric NOT NULL DEFAULT 3,    -- an A-item under this DoS can force P1
  a_crit_min_rev  numeric NOT NULL DEFAULT 5,    -- ...but only if that shelf earns >= this AED/day (revenue gate)
  vel_recent_days int     NOT NULL DEFAULT 30,   -- velocity averaging window
  coverage_days   int     NOT NULL DEFAULT 180,  -- "ever sold" window for name-match coverage diagnostic
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL
);
COMMENT ON TABLE public.service_priority_params IS
  'Phase F service-level prioritisation dials (singleton). Tunable without migration.';

INSERT INTO public.service_priority_params (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.service_priority_params ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS spp_select ON public.service_priority_params;
CREATE POLICY spp_select ON public.service_priority_params
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS spp_modify ON public.service_priority_params;
CREATE POLICY spp_modify ON public.service_priority_params
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles
                 WHERE id = (SELECT auth.uid())
                   AND role = ANY (ARRAY['operator_admin','superadmin','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
                 WHERE id = (SELECT auth.uid())
                   AND role = ANY (ARRAY['operator_admin','superadmin','manager'])));

CREATE OR REPLACE VIEW public.v_machine_service_priority AS
WITH p AS (SELECT * FROM public.service_priority_params WHERE id = 1),
sv AS (
  SELECT sh.machine_id, lower(trim(sh.pod_product_name)) AS pname,
         SUM(sh.qty) FILTER (WHERE sh.transaction_date >= now() - make_interval(days => (SELECT vel_recent_days FROM p))) AS u_recent
  FROM public.sales_history sh
  WHERE sh.delivery_status IN ('Success','Successful')
    AND sh.transaction_date >= now() - make_interval(days => (SELECT coverage_days FROM p))
  GROUP BY 1, 2
),
sb AS (
  SELECT vls.machine_id, vls.machine_name, vls.current_stock, vls.price_aed,
         COALESCE(sv.u_recent, 0) AS u_recent,
         (sv.pname IS NOT NULL) AS name_seen,
         COUNT(*) OVER (PARTITION BY vls.machine_id, lower(trim(vls.goods_name_raw))) AS dup
  FROM public.v_live_shelf_stock vls
  LEFT JOIN sv ON sv.machine_id = vls.machine_id
              AND sv.pname = lower(trim(vls.goods_name_raw))
  WHERE vls.is_enabled = true
),
sc AS (
  SELECT sb.*, p.horizon_days, p.a_floor_day, p.b_floor_day,
         p.a_crit_dos, p.a_crit_min_rev, p.p1_rev_floor,
         (sb.u_recent::numeric / p.vel_recent_days) / GREATEST(sb.dup,1) AS dvel
  FROM sb CROSS JOIN p
),
sc2 AS (
  SELECT *,
    CASE WHEN dvel > 0 THEN current_stock / NULLIF(dvel,0) END AS dos,
    dvel * price_aed AS rev_day,
    CASE WHEN dvel >= a_floor_day THEN 'A'
         WHEN dvel >= b_floor_day THEN 'B'
         WHEN dvel > 0 THEN 'C' ELSE 'D' END AS abc
  FROM sc
),
sc3 AS (
  SELECT *,
    (abc IN ('A','B') AND dos < horizon_days) AS at_risk,
    (abc = 'A' AND dos < a_crit_dos AND rev_day >= a_crit_min_rev) AS a_crit_shelf
  FROM sc2
),
m AS (
  SELECT machine_id, machine_name,
    COUNT(*)                                          AS enabled_shelves,
    COUNT(*) FILTER (WHERE abc='A')                   AS a_shelves,
    COUNT(*) FILTER (WHERE abc='B')                   AS b_shelves,
    COUNT(*) FILTER (WHERE abc='D')                   AS dead_shelves,
    COUNT(*) FILTER (WHERE abc='D' AND NOT name_seen) AS unmatched_shelves,
    COUNT(*) FILTER (WHERE at_risk)                   AS at_risk_shelves,
    ROUND(COALESCE(SUM(rev_day) FILTER (WHERE at_risk),0),2) AS at_risk_rev_day,
    ROUND(MIN(dos) FILTER (WHERE abc IN ('A','B')),1)       AS soonest_ab_dos,
    ROUND(COALESCE(SUM(rev_day),0),2)                       AS machine_rev_day,
    BOOL_OR(a_crit_shelf)                                   AS a_crit,
    MAX(p1_rev_floor)                                       AS p1_rev_floor
  FROM sc3 GROUP BY machine_id, machine_name
),
tiered AS (
  SELECT m.*,
    CASE WHEN at_risk_rev_day >= p1_rev_floor OR a_crit THEN 'P1_RESTOCK'
         WHEN at_risk_shelves > 0 THEN 'P2_MAINTAIN' ELSE 'SKIP' END AS new_tier
  FROM m
)
SELECT t.machine_id, t.machine_name, t.enabled_shelves,
       t.a_shelves, t.b_shelves, t.dead_shelves, t.unmatched_shelves,
       t.soonest_ab_dos, t.at_risk_shelves, t.at_risk_rev_day, t.machine_rev_day,
       t.new_tier, t.at_risk_rev_day AS new_rank,
       vp.p_tier AS old_tier, vp.p_score AS old_score,
       CASE
         WHEN (CASE t.new_tier WHEN 'P1_RESTOCK' THEN 1 WHEN 'P2_MAINTAIN' THEN 2 ELSE 3 END)
            < (CASE vp.p_tier WHEN 'P1_RESTOCK' THEN 1 WHEN 'P2_MAINTAIN' THEN 2 ELSE 3 END)
           THEN 'new_promotes'
         WHEN (CASE t.new_tier WHEN 'P1_RESTOCK' THEN 1 WHEN 'P2_MAINTAIN' THEN 2 ELSE 3 END)
            > (CASE vp.p_tier WHEN 'P1_RESTOCK' THEN 1 WHEN 'P2_MAINTAIN' THEN 2 ELSE 3 END)
           THEN 'new_demotes'
         ELSE 'agree' END AS shadow_delta
FROM tiered t
JOIN public.machines mc ON mc.machine_id = t.machine_id
LEFT JOIN public.v_machine_priority vp ON vp.machine_id = t.machine_id
WHERE COALESCE(mc.include_in_refill, true) = true
  AND COALESCE(mc.status, 'Active') NOT IN ('Warehouse','Inactive');

COMMENT ON VIEW public.v_machine_service_priority IS
  'Phase F shadow/diagnostic: shelf-level service-level prioritisation vs live v_machine_priority. '
  'READ-ONLY. Not wired to the picker. Promote via Dara->Cody cutover within ~30d or REVOKE/DROP (Art 13).';
