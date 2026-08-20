-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-106b size-up gating. Source: docs/architecture/CHANGELOG.md:2961-2963 and
-- docs/architecture/MIGRATIONS_REGISTRY.md:696.
-- This migration's semantic delta: the Wave-2 TRUE-HERO size-up path requires the candidate's
-- existing facing be explicitly flagged DOUBLE DOWN in slot_lifecycle (CS rule, incident
-- 2026-07-29: Barebells/Coca Cola Zero sized-up onto KEEP-only facings). Root cause of all 3
-- 07-29 duplicate-swap dups. engine_swap_pod itself untouched; PRD-094/095 freeze intact.
--
-- CANNOT BE RECOVERED EXACTLY: this function was FURTHER modified the same day by
-- 20260729084619 (prd106b2, Evian-1L exclusion) and then completely DROP+CREATE'd by
-- 20260729102850 (prd108_rank_slot_suitability_volume_tests, replacing the
-- `proven_machine_pctile >= 0.80` test with the T1/T2/T3 volume tests and adding
-- `sizeup_rationale`). The pre-PRD-108 intermediate body (is_dd added, but still
-- percentile-gated) no longer exists anywhere to recover from. Per the audit brief's explicit
-- instruction, this file carries the CURRENT CUMULATIVE body (recovered via
-- pg_get_functiondef against live prod, post all of prd106b/prd106b2/prd108) rather than a
-- reconstructed intermediate state. CREATE OR REPLACE is idempotent, so re-applying the same
-- final body across this and the following 3 migrations that touch this function is safe on
-- replay. The `is_dd` requirement this migration introduced is visible in the `decided` CTE
-- below (`AND t.is_dd -- PRD-106b: human authorisation still required`).

CREATE OR REPLACE FUNCTION public.rank_slot_suitability(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_out_pod_product_id uuid, p_limit integer DEFAULT 8, p_pending_pods uuid[] DEFAULT '{}'::uuid[])
 RETURNS TABLE(pod_product_id uuid, pod_product_name text, suitability numeric, size_fit text, wh_pickable integer, min_refill_qty integer, cover_days numeric, proven_local numeric, lookalike numeric, margin_band numeric, basket numeric, avail_conf numeric, freshness numeric, is_size_up boolean, rank integer, sizeup_rationale jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_shelf_size text;
  v_wh_pri     uuid;
  v_wh_sec     uuid;
  v_loc_type   text;
  v_trip       int;
  v_out_boonz  uuid;
  v_out_price  numeric;
  -- PRD-108
  v_t1         numeric;
  v_t2         numeric;
  v_t3         numeric;
  v_floor      numeric;
  v_machine_wk numeric;
BEGIN
  IF p_machine_id IS NULL OR p_shelf_id IS NULL THEN
    RETURN;
  END IF;

  SELECT sc.shelf_size INTO v_shelf_size
    FROM public.shelf_configurations sc WHERE sc.shelf_id = p_shelf_id;

  SELECT m.primary_warehouse_id, m.secondary_warehouse_id, m.location_type
    INTO v_wh_pri, v_wh_sec, v_loc_type
    FROM public.machines m WHERE m.machine_id = p_machine_id;

  v_trip := COALESCE(
    (SELECT msp.trip_interval_days FROM public.machine_service_policy msp
      WHERE msp.machine_id = p_machine_id), 21);

  -- PRD-108: thresholds are param-driven, never hardcoded.
  SELECT rpp.sizeup_min_vel_per_day, rpp.sizeup_overflow_factor,
         rpp.sizeup_vs_alternative_factor, rpp.sizeup_min_machine_units_wk
    INTO v_t1, v_t2, v_t3, v_floor
    FROM public.refill_policy_params rpp ORDER BY rpp.id LIMIT 1;
  v_t1    := COALESCE(v_t1, 1.25);
  v_t2    := COALESCE(v_t2, 1.25);
  v_t3    := COALESCE(v_t3, 1.3);
  v_floor := COALESCE(v_floor, 30);

  -- PRD-108 machine floor: canonical object (METRICS_REGISTRY.md:33).
  SELECT COALESCE(mv.daily_velocity_30d,0) * 7 INTO v_machine_wk
    FROM public.v_machine_velocity mv WHERE mv.machine_id = p_machine_id;
  v_machine_wk := COALESCE(v_machine_wk, 0);

  SELECT pm.boonz_product_id INTO v_out_boonz
    FROM public.product_mapping pm
   WHERE pm.pod_product_id = p_out_pod_product_id AND pm.status = 'Active'
     AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
   ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, pm.is_global_default DESC, pm.updated_at DESC
   LIMIT 1;

  SELECT MAX(vcp.effective_price_aed) INTO v_out_price
    FROM public.v_current_price vcp
   WHERE vcp.machine_id = p_machine_id AND vcp.boonz_product_id = v_out_boonz;

  IF v_shelf_size IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH
  present AS (
    SELECT DISTINCT pod_product_id FROM (
      SELECT sl.pod_product_id FROM public.slot_lifecycle sl
       WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
      UNION
      SELECT vls.pod_product_id FROM public.v_live_shelf_stock vls
       WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
    ) u WHERE pod_product_id IS NOT NULL
  ),
  pod_boonz AS (
    SELECT DISTINCT pm.pod_product_id, pm.boonz_product_id
      FROM public.product_mapping pm
     WHERE pm.status = 'Active' AND (pm.machine_id IS NULL OR pm.machine_id = p_machine_id)
  ),
  sizefit AS (
    SELECT psf.pod_product_id,
           COALESCE(psf.min_refill_qty, CEIL(0.7 * psf.cap_typical), 1)::int AS min_qty_eff,
           psf.cap_typical
      FROM public.product_size_fit psf
     WHERE psf.shelf_size = v_shelf_size AND psf.fits = true
  ),
  wh AS (
    SELECT pb.pod_product_id,
           SUM(vp.warehouse_stock)::int AS wh_pickable,
           MIN(vp.expiration_date)      AS min_exp
      FROM pod_boonz pb
      JOIN public.v_wh_pickable vp
        ON vp.boonz_product_id = pb.boonz_product_id
       AND vp.warehouse_id IN (v_wh_pri, v_wh_sec)
       AND (vp.reserved_for_machine_id IS NULL OR vp.reserved_for_machine_id = p_machine_id)
     GROUP BY pb.pod_product_id
    HAVING SUM(vp.warehouse_stock) > 0
  ),
  universe AS (
    SELECT sf.pod_product_id, sf.min_qty_eff, sf.cap_typical, w.wh_pickable, w.min_exp
      FROM sizefit sf
      JOIN wh w ON w.pod_product_id = sf.pod_product_id
      JOIN public.pod_products pp ON pp.pod_product_id = sf.pod_product_id AND COALESCE(pp.is_catchall,false) = false
     WHERE sf.pod_product_id <> p_out_pod_product_id
       -- PRD-106b2: Evian - 1L is never a swap-in (standing CS guardrail).
       AND sf.pod_product_id <> '990461ff-ff92-4b3f-aedb-cde0e951aaf8'::uuid
  ),
  cand_primary_boonz AS (
    SELECT u.pod_product_id,
      (SELECT pm.boonz_product_id FROM public.product_mapping pm
        WHERE pm.pod_product_id = u.pod_product_id AND pm.status = 'Active'
          AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
        ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, pm.is_global_default DESC, pm.updated_at DESC
        LIMIT 1) AS boonz
    FROM universe u
  ),
  proven AS (
    SELECT sh.pod_product_id,
           SUM(sh.qty) / NULLIF(COUNT(DISTINCT (sh.transaction_date AT TIME ZONE 'Asia/Dubai')::date),0) AS ppad
      FROM public.v_sales_history_resolved sh
     WHERE sh.machine_id = p_machine_id AND sh.delivery_status = 'Successful'
       AND sh.transaction_date >= p_plan_date - INTERVAL '90 days'
       AND sh.pod_product_id IS NOT NULL
     GROUP BY sh.pod_product_id
  ),
  -- PRD-108: calendar-day velocity. Same source as `proven`, divided by the 90-day
  -- WINDOW rather than by the count of selling days. Used ONLY by the size-up tests.
  proven_cal AS (
    SELECT sh.pod_product_id, SUM(sh.qty) / 90.0 AS pcal
      FROM public.v_sales_history_resolved sh
     WHERE sh.machine_id = p_machine_id AND sh.delivery_status = 'Successful'
       AND sh.transaction_date >= p_plan_date - INTERVAL '90 days'
       AND sh.pod_product_id IS NOT NULL
     GROUP BY sh.pod_product_id
  ),
  -- PRD-108 / Article 16: canonical per (machine, product) calendar velocity.
  ssi AS (
    SELECT v.pod_product_id, v.dvel
      FROM public.v_shelf_sales_identity v
     WHERE v.machine_id = p_machine_id
  ),
  proven_pctile AS (
    SELECT pv.pod_product_id, percent_rank() OVER (ORDER BY pv.ppad) AS proven_machine_pctile
      FROM proven pv
  ),
  lookalike AS (
    SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS ll
      FROM public.slot_lifecycle sl
      JOIN public.machines m2 ON m2.machine_id = sl.machine_id AND m2.location_type = v_loc_type
     WHERE sl.archived = false AND sl.is_current = true
     GROUP BY sl.pod_product_id
  ),
  fleetvel AS (
    SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS gv
      FROM public.slot_lifecycle sl WHERE sl.archived = false AND sl.is_current = true
     GROUP BY sl.pod_product_id
  ),
  basket_set AS (
    SELECT sl.pod_product_id FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
       AND (COALESCE(sl.velocity_7d,0) > 0 OR COALESCE(sl.velocity_30d,0) > 0)
  ),
  on_machine_stock AS (
    SELECT vls.pod_product_id,
           SUM(vls.current_stock)::numeric        AS cur_stock,
           SUM(GREATEST(vls.max_stock,0))::numeric AS onmach_cap
      FROM public.v_live_shelf_stock vls
     WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL
       AND (vls.current_stock > 0 OR vls.max_stock > 0)
     GROUP BY vls.pod_product_id
  ),
  on_machine_vel AS (
    SELECT sl.pod_product_id, MAX(COALESCE(sl.velocity_30d,0)) AS vel
      FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
     GROUP BY sl.pod_product_id
  ),
  cand_coex AS (
    SELECT pb.pod_product_id, bool_or(public._coexistence_blocks(p_machine_id, pb.boonz_product_id)) AS coex_block
      FROM pod_boonz pb
     WHERE pb.pod_product_id IN (SELECT pod_product_id FROM universe)
     GROUP BY pb.pod_product_id
  ),
  pending_boonz AS (
    SELECT DISTINCT pm.boonz_product_id AS boonz
      FROM unnest(p_pending_pods) AS t(pod)
      JOIN public.product_mapping pm
        ON pm.pod_product_id = t.pod AND pm.status = 'Active'
       AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
  ),
  cand_boonz_attr AS (
    SELECT pb.pod_product_id, bp.product_id AS boonz, bp.product_brand AS brand,
           bp.brand_owner AS owner, bp.boonz_product_name AS nm, bp.product_family_id AS fam
      FROM pod_boonz pb JOIN public.boonz_products bp ON bp.product_id = pb.boonz_product_id
     WHERE pb.pod_product_id IN (SELECT pod_product_id FROM universe)
  ),
  pend_attr AS (
    SELECT bp.product_id AS boonz, bp.product_brand AS brand, bp.brand_owner AS owner,
           bp.boonz_product_name AS nm, bp.product_family_id AS fam
      FROM pending_boonz pgb JOIN public.boonz_products bp ON bp.product_id = pgb.boonz
  ),
  pending_block AS (
    SELECT DISTINCT c.pod_product_id
      FROM cand_boonz_attr c
      JOIN public.coexistence_rules cr ON cr.scope='machine' AND cr.rule_type='hard' AND cr.is_active
      JOIN pend_attr o ON
        ( ( (cr.a_match_type='product_brand' AND c.brand = cr.a_match_value)
            OR (cr.a_match_type='brand_owner' AND c.owner = cr.a_match_value)
            OR (cr.a_match_type='name'        AND c.nm    = cr.a_match_value)
            OR (cr.a_match_type='product_id'  AND c.boonz::text = cr.a_match_value)
            OR (cr.a_match_type='family_id'   AND c.fam IS NOT NULL AND c.fam::text = cr.a_match_value) )
          AND
          ( (cr.b_match_type='product_brand' AND o.brand = cr.b_match_value)
            OR (cr.b_match_type='brand_owner' AND o.owner = cr.b_match_value)
            OR (cr.b_match_type='name'        AND o.nm    = cr.b_match_value)
            OR (cr.b_match_type='family_id'   AND o.fam IS NOT NULL AND o.fam::text = cr.b_match_value) ) )
        OR
        ( ( (cr.b_match_type='product_brand' AND c.brand = cr.b_match_value)
            OR (cr.b_match_type='brand_owner' AND c.owner = cr.b_match_value)
            OR (cr.b_match_type='name'        AND c.nm    = cr.b_match_value)
            OR (cr.b_match_type='family_id'   AND c.fam IS NOT NULL AND c.fam::text = cr.b_match_value) )
          AND
          ( (cr.a_match_type='product_brand' AND o.brand = cr.a_match_value)
            OR (cr.a_match_type='brand_owner' AND o.owner = cr.a_match_value)
            OR (cr.a_match_type='name'        AND o.nm    = cr.a_match_value)
            OR (cr.a_match_type='family_id'   AND o.fam IS NOT NULL AND o.fam::text = cr.a_match_value) ) )
  ),
  enriched AS (
    SELECT u.pod_product_id, u.min_qty_eff, u.wh_pickable, u.min_exp,
           pp.pod_product_name, cpb.boonz AS cand_boonz,
           COALESCE(pv.ppad,0)  AS proven_raw,
           COALESCE(ll.ll,0)    AS lookalike_raw,
           COALESCE(fv.gv,0)    AS global_vel,
           COALESCE(pc.pcal,0)  AS proven_cal,
           (SELECT MAX(vcp.effective_price_aed) FROM public.v_current_price vcp
             WHERE vcp.machine_id = p_machine_id AND vcp.boonz_product_id = cpb.boonz) AS cand_price,
           (SELECT lc.landed_cost FROM public.v_product_landed_cost lc
             WHERE lc.boonz_product_id = cpb.boonz)                                    AS cand_cost,
           COALESCE(
             (SELECT AVG(cm.pearson) FROM public.correlation_pod_per_machine cm
               WHERE cm.machine_id = p_machine_id AND cm.pod_product_b = u.pod_product_id
                 AND cm.pod_product_a IN (SELECT pod_product_id FROM basket_set)),
             (SELECT AVG(cl.pearson) FROM public.correlation_pod_per_loc_type cl
               WHERE cl.location_type = v_loc_type AND cl.pod_product_b = u.pod_product_id
                 AND cl.pod_product_a IN (SELECT pod_product_id FROM basket_set)),
             0)                                                                        AS basket_raw,
           (u.pod_product_id IN (SELECT pod_product_id FROM present))                  AS is_present,
           COALESCE(oms.cur_stock,0)              AS cur_stock,
           COALESCE(oms.onmach_cap,0)             AS onmach_cap,
           COALESCE(omv.vel, pv.ppad, 0)          AS machine_vel,
           -- PRD-108 T1 velocity: canonical v_shelf_sales_identity.dvel for a product
           -- ON the machine, 90d calendar rate otherwise. NEVER ppad.
           COALESCE(ssi.dvel, pc.pcal, 0)         AS vel_cal,
           EXISTS(SELECT 1 FROM public.strategic_intents si
                   WHERE si.intent_type='decommission' AND si.status IN ('queued','in_progress')
                     AND si.scope_pod_product_id = u.pod_product_id)                   AS is_decomm,
           COALESCE(cc.coex_block,false)          AS coex_block,
           (u.pod_product_id IN (SELECT pod_product_id FROM pending_block))            AS pend_block,
           u.cap_typical                          AS cap_typical,
           COALESCE(ppc.proven_machine_pctile,0)  AS proven_machine_pctile,
           EXISTS(SELECT 1 FROM public.slot_lifecycle sl2
                   WHERE sl2.machine_id = p_machine_id AND sl2.pod_product_id = u.pod_product_id
                     AND sl2.archived = false AND sl2.is_current = true
                     AND sl2.signal = 'DOUBLE DOWN')                                   AS is_dd,
           (pp.pod_product_name ILIKE '%Mix%'
             OR pp.pod_product_name IN ('Soft Drinks Mix','Coca Cola Mix','Pepsi Mix','Chocolate Bar','Snack Bar')
           )                                       AS is_blended
      FROM universe u
      JOIN public.pod_products pp ON pp.pod_product_id = u.pod_product_id
      LEFT JOIN cand_primary_boonz cpb ON cpb.pod_product_id = u.pod_product_id
      LEFT JOIN proven pv           ON pv.pod_product_id  = u.pod_product_id
      LEFT JOIN proven_cal pc       ON pc.pod_product_id  = u.pod_product_id
      LEFT JOIN ssi                 ON ssi.pod_product_id = u.pod_product_id
      LEFT JOIN proven_pctile ppc   ON ppc.pod_product_id = u.pod_product_id
      LEFT JOIN lookalike ll        ON ll.pod_product_id  = u.pod_product_id
      LEFT JOIN fleetvel fv         ON fv.pod_product_id  = u.pod_product_id
      LEFT JOIN on_machine_stock oms ON oms.pod_product_id = u.pod_product_id
      LEFT JOIN on_machine_vel omv   ON omv.pod_product_id = u.pod_product_id
      LEFT JOIN cand_coex cc         ON cc.pod_product_id  = u.pod_product_id
  ),
  -- ── PRD-108 T3 benchmark ────────────────────────────────────────────────
  -- The alternative to a second facing is the candidate that would WIN this shelf
  -- if we did not size up. Non-present candidates never depend on is_size_up for
  -- their eligibility, so ranking them alone is well-defined and non-circular.
  -- The scoring below mirrors the main chain exactly; keep the two in step.
  nc_pool AS (
    SELECT e.*, GREATEST(e.proven_cal, e.lookalike_raw, e.global_vel) AS exp_vel_cal
      FROM enriched e
     WHERE NOT e.is_present
       AND e.wh_pickable >= e.min_qty_eff
       AND NOT e.is_decomm
       AND NOT e.coex_block
       AND NOT e.pend_block
  ),
  nc_normed AS (
    SELECT n.*,
           percent_rank() OVER (ORDER BY n.proven_raw)    AS proven_n,
           percent_rank() OVER (ORDER BY n.lookalike_raw) AS lookalike_n,
           (COALESCE(n.cand_price,0) - COALESCE(n.cand_cost,0))                   AS margin_aed,
           MIN(COALESCE(n.cand_price,0) - COALESCE(n.cand_cost,0)) OVER ()        AS mn_margin,
           MAX(COALESCE(n.cand_price,0) - COALESCE(n.cand_cost,0)) OVER ()        AS mx_margin,
           (n.wh_pickable::numeric / GREATEST(GREATEST(n.proven_raw, n.lookalike_raw, n.global_vel),0.1)) AS cover_days_wh,
           CASE WHEN n.min_exp IS NULL THEN 1.0
                ELSE LEAST(1.0, GREATEST(0.0, ((n.min_exp - p_plan_date)::numeric - 14) / (90-14))) END AS freshness_n,
           GREATEST(COALESCE(n.basket_raw,0),0)                                   AS basket_n
      FROM nc_pool n
  ),
  nc_scored AS (
    SELECT x.*,
           (0.6 * CASE WHEN x.mx_margin > x.mn_margin
                       THEN (x.margin_aed - x.mn_margin)/(x.mx_margin - x.mn_margin) ELSE 0.5 END
            + 0.4 * CASE WHEN x.cand_price > 0 AND v_out_price > 0
                         THEN exp( -abs(ln(x.cand_price) - ln(v_out_price)) / ln(1.5) ) ELSE 0.5 END) AS margin_band_n,
           LEAST(1.0, ln(1 + GREATEST(x.cover_days_wh,0)) / ln(22))                                   AS avail_conf_n
      FROM nc_normed x
  ),
  nc_best AS (
    SELECT s.exp_vel_cal, s.pod_product_name
      FROM nc_scored s
     ORDER BY LEAST(1.0,
                 0.28*s.proven_n + 0.20*s.lookalike_n + 0.16*s.margin_band_n
               + 0.12*s.basket_n + 0.10*s.avail_conf_n + 0.08*0.5 + 0.06*s.freshness_n) DESC,
              s.wh_pickable DESC
     LIMIT 1
  ),
  flagged AS (
    SELECT e.*,
           GREATEST(COALESCE(NULLIF(e.cap_typical,0),8), e.onmach_cap)::numeric AS full_shelf_units,
           COALESCE((SELECT nb.exp_vel_cal FROM nc_best nb), 0)                 AS newc_exp,
           (SELECT nb.pod_product_name FROM nc_best nb)                         AS newc_name
      FROM enriched e
  ),
  tested AS (
    SELECT f.*,
           GREATEST(0, f.vel_cal - f.full_shelf_units / GREATEST(v_trip,1)) AS incremental_per_day,
           (f.vel_cal >= v_t1)                                               AS t1_pass,
           (f.vel_cal * v_trip > f.full_shelf_units * v_t2)                   AS t2_pass,
           (GREATEST(0, f.vel_cal - f.full_shelf_units / GREATEST(v_trip,1))
              >= v_t3 * f.newc_exp)                                           AS t3_pass,
           (v_machine_wk > v_floor)                                           AS floor_pass
      FROM flagged f
  ),
  decided AS (
    SELECT t.*,
           ( t.is_present
             AND t.floor_pass          -- machine-level guard: zombies never concentrate
             AND t.t1_pass             -- T1 absolute velocity floor
             AND t.t2_pass             -- T2 demonstrated overflow with margin (coverage, fallback form)
             AND t.t3_pass             -- T3 opportunity cost vs the best newcomer
             AND NOT t.is_blended
             AND t.is_dd               -- PRD-106b: human authorisation still required
           ) AS is_size_up
      FROM tested t
  ),
  gated AS (
    SELECT f.*, GREATEST(f.proven_raw, f.lookalike_raw, f.global_vel) AS exp_vel
      FROM decided f
     WHERE f.wh_pickable >= f.min_qty_eff
       AND NOT f.is_decomm
       AND (NOT f.is_present OR f.is_size_up)
       AND (f.is_size_up OR NOT f.coex_block)
       AND NOT f.pend_block
  ),
  normed AS (
    SELECT g.*,
           percent_rank() OVER (ORDER BY g.proven_raw)    AS proven_n,
           percent_rank() OVER (ORDER BY g.lookalike_raw)  AS lookalike_n,
           (COALESCE(g.cand_price,0) - COALESCE(g.cand_cost,0))                    AS margin_aed,
           MIN(COALESCE(g.cand_price,0) - COALESCE(g.cand_cost,0)) OVER ()          AS mn_margin,
           MAX(COALESCE(g.cand_price,0) - COALESCE(g.cand_cost,0)) OVER ()          AS mx_margin,
           (g.wh_pickable::numeric / GREATEST(g.exp_vel,0.1))                       AS cover_days_wh,
           CASE WHEN g.min_exp IS NULL THEN 1.0
                ELSE LEAST(1.0, GREATEST(0.0, ((g.min_exp - p_plan_date)::numeric - 14) / (90-14))) END AS freshness_n,
           GREATEST(COALESCE(g.basket_raw,0),0)                                     AS basket_n
      FROM gated g
  ),
  scored AS (
    SELECT n.*,
           (0.6 * CASE WHEN n.mx_margin > n.mn_margin
                       THEN (n.margin_aed - n.mn_margin)/(n.mx_margin - n.mn_margin) ELSE 0.5 END
            + 0.4 * CASE WHEN n.cand_price > 0 AND v_out_price > 0
                         THEN exp( -abs(ln(n.cand_price) - ln(v_out_price)) / ln(1.5) ) ELSE 0.5 END) AS margin_band_n,
           LEAST(1.0, ln(1 + GREATEST(n.cover_days_wh,0)) / ln(22))                                   AS avail_conf_n
      FROM normed n
  ),
  final AS (
    SELECT s.pod_product_id,
           s.pod_product_name,
           LEAST(1.0,
                 0.28*s.proven_n + 0.20*s.lookalike_n + 0.16*s.margin_band_n
               + 0.12*s.basket_n + 0.10*s.avail_conf_n + 0.08*0.5 + 0.06*s.freshness_n
               + CASE WHEN s.is_size_up THEN 0.05 ELSE 0 END)::numeric AS suitability,
           v_shelf_size::text                        AS size_fit,
           s.wh_pickable::int                        AS wh_pickable,
           s.min_qty_eff::int                        AS min_refill_qty,
           round(s.cover_days_wh::numeric,2)         AS cover_days,
           round(s.proven_n::numeric,4)              AS proven_local,
           round(s.lookalike_n::numeric,4)           AS lookalike,
           round(s.margin_band_n::numeric,4)         AS margin_band,
           round(s.basket_n::numeric,4)              AS basket,
           round(s.avail_conf_n::numeric,4)          AS avail_conf,
           round(s.freshness_n::numeric,4)           AS freshness,
           s.is_size_up,
           -- PRD-108: every size-up decision is auditable from its own inputs.
           jsonb_build_object(
             'engine','rank_slot_suitability_prd108',
             'is_present', s.is_present, 'is_dd', s.is_dd, 'is_blended', s.is_blended,
             'trip_interval_days', v_trip,
             'machine_units_wk', round(v_machine_wk,2),
             'vel_day', round(s.vel_cal,4),
             'full_shelf_units', s.full_shelf_units,
             'demand_over_trip', round(s.vel_cal * v_trip,3),
             'incremental_per_day', round(s.incremental_per_day,4),
             'newcomer_name', s.newc_name,
             'newcomer_exp_vel', round(s.newc_exp,4),
             'thresholds', jsonb_build_object(
               'sizeup_min_vel_per_day', v_t1, 'sizeup_overflow_factor', v_t2,
               'sizeup_vs_alternative_factor', v_t3, 'sizeup_min_machine_units_wk', v_floor),
             'tests', jsonb_build_object(
               'machine_floor', s.floor_pass, 't1_velocity', s.t1_pass,
               't2_overflow', s.t2_pass, 't3_vs_alternative', s.t3_pass)
           ) AS sizeup_rationale
      FROM scored s
  )
  SELECT f.pod_product_id, f.pod_product_name, f.suitability, f.size_fit, f.wh_pickable,
         f.min_refill_qty, f.cover_days, f.proven_local, f.lookalike, f.margin_band,
         f.basket, f.avail_conf, f.freshness, f.is_size_up,
         (ROW_NUMBER() OVER (ORDER BY f.suitability DESC, f.wh_pickable DESC))::int AS rank,
         f.sizeup_rationale
    FROM final f
   ORDER BY f.suitability DESC, f.wh_pickable DESC
   LIMIT p_limit;
END;
$function$;
