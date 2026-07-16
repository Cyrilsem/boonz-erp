CREATE OR REPLACE FUNCTION public.rank_slot_suitability(
  p_plan_date          date,
  p_machine_id         uuid,
  p_shelf_id           uuid,
  p_out_pod_product_id uuid,
  p_limit              int      DEFAULT 8,
  p_pending_pods       uuid[]   DEFAULT '{}'
)
RETURNS TABLE(
  pod_product_id   uuid,
  pod_product_name text,
  suitability      numeric,
  size_fit         text,
  wh_pickable      int,
  min_refill_qty   int,
  cover_days       numeric,
  proven_local     numeric,
  lookalike        numeric,
  margin_band      numeric,
  basket           numeric,
  avail_conf       numeric,
  freshness        numeric,
  is_size_up       boolean,
  rank             int
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
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
BEGIN
  IF p_machine_id IS NULL OR p_shelf_id IS NULL THEN
    RETURN;
  END IF;

  -- Resolve target-shelf size + machine warehouse/loc context + trip interval.
  SELECT sc.shelf_size INTO v_shelf_size
    FROM public.shelf_configurations sc WHERE sc.shelf_id = p_shelf_id;

  SELECT m.primary_warehouse_id, m.secondary_warehouse_id, m.location_type
    INTO v_wh_pri, v_wh_sec, v_loc_type
    FROM public.machines m WHERE m.machine_id = p_machine_id;

  v_trip := COALESCE(
    (SELECT msp.trip_interval_days FROM public.machine_service_policy msp
      WHERE msp.machine_id = p_machine_id), 21);

  -- Outgoing pod -> boonz (machine-scoped preferred, else global) and its price.
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
    RETURN;   -- unknown/phantom shelf -> empty pool
  END IF;

  RETURN QUERY
  WITH
  -- On-machine present set (slot_lifecycle is_current UNION live shelf stock > 0)
  present AS (
    SELECT DISTINCT pod_product_id FROM (
      SELECT sl.pod_product_id FROM public.slot_lifecycle sl
       WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
      UNION
      SELECT vls.pod_product_id FROM public.v_live_shelf_stock vls
       WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
    ) u WHERE pod_product_id IS NOT NULL
  ),
  -- Distinct pod<->boonz active mappings (machine-scoped or global) for WH dedup + coexistence.
  pod_boonz AS (
    SELECT DISTINCT pm.pod_product_id, pm.boonz_product_id
      FROM public.product_mapping pm
     WHERE pm.status = 'Active' AND (pm.machine_id IS NULL OR pm.machine_id = p_machine_id)
  ),
  -- HARD GATE 1 (size-fit): pods that fit at the target shelf size.
  -- min_refill_qty gate value: COALESCE(min_refill_qty, ceil(0.7*cap_typical), 1).
  sizefit AS (
    SELECT psf.pod_product_id,
           COALESCE(psf.min_refill_qty, CEIL(0.7 * psf.cap_typical), 1)::int AS min_qty_eff,
           psf.cap_typical
      FROM public.product_size_fit psf
     WHERE psf.shelf_size = v_shelf_size AND psf.fits = true
  ),
  -- Real pickable WH stock, deduped by wh_inventory_id via v_wh_pickable
  -- (Active, not quarantined, not expired, stock>0), scoped to the machine's
  -- primary/secondary warehouse and not reserved for another machine.
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
  -- Candidate universe: size-fit true AND real pickable WH stock AND not catchall AND not the outgoing pod.
  universe AS (
    SELECT sf.pod_product_id, sf.min_qty_eff, sf.cap_typical, w.wh_pickable, w.min_exp
      FROM sizefit sf
      JOIN wh w ON w.pod_product_id = sf.pod_product_id
      JOIN public.pod_products pp ON pp.pod_product_id = sf.pod_product_id AND COALESCE(pp.is_catchall,false) = false
     WHERE sf.pod_product_id <> p_out_pod_product_id
  ),
  -- Candidate primary boonz (for price/cost/margin).
  cand_primary_boonz AS (
    SELECT u.pod_product_id,
      (SELECT pm.boonz_product_id FROM public.product_mapping pm
        WHERE pm.pod_product_id = u.pod_product_id AND pm.status = 'Active'
          AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
        ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, pm.is_global_default DESC, pm.updated_at DESC
        LIMIT 1) AS boonz
    FROM universe u
  ),
  -- proven_local raw: units / active-day ON THIS machine over trailing 90d.
  proven AS (
    SELECT sh.pod_product_id,
           SUM(sh.qty) / NULLIF(COUNT(DISTINCT (sh.transaction_date AT TIME ZONE 'Asia/Dubai')::date),0) AS ppad
      FROM public.v_sales_history_resolved sh
     WHERE sh.machine_id = p_machine_id AND sh.delivery_status = 'Successful'
       AND sh.transaction_date >= p_plan_date - INTERVAL '90 days'
       AND sh.pod_product_id IS NOT NULL
     GROUP BY sh.pod_product_id
  ),
  -- Machine-wide proven-velocity percentile (drives the TRUE-HERO size-up gate:
  -- "a genuine top seller HERE" = proven_local percentile >= 0.80 across the machine's
  -- selling pods). Computed pre-gate so there is no circular dependency with eligibility.
  proven_pctile AS (
    SELECT pv.pod_product_id, percent_rank() OVER (ORDER BY pv.ppad) AS proven_machine_pctile
      FROM proven pv
  ),
  -- lookalike raw: avg velocity_30d across machines of same location_type where candidate is live.
  lookalike AS (
    SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS ll
      FROM public.slot_lifecycle sl
      JOIN public.machines m2 ON m2.machine_id = sl.machine_id AND m2.location_type = v_loc_type
     WHERE sl.archived = false AND sl.is_current = true
     GROUP BY sl.pod_product_id
  ),
  -- Global fleet velocity (fallback for expected velocity).
  fleetvel AS (
    SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS gv
      FROM public.slot_lifecycle sl WHERE sl.archived = false AND sl.is_current = true
     GROUP BY sl.pod_product_id
  ),
  -- Machine live sellers (basket) for basket correlation.
  basket_set AS (
    SELECT sl.pod_product_id FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
       AND (COALESCE(sl.velocity_7d,0) > 0 OR COALESCE(sl.velocity_30d,0) > 0)
  ),
  -- On-machine current stock + velocity for the SIZE-UP test.
  on_machine_stock AS (
    SELECT vls.pod_product_id,
           SUM(vls.current_stock)::numeric        AS cur_stock,
           SUM(GREATEST(vls.max_stock,0))::numeric AS onmach_cap   -- actual full on-machine slot capacity
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
  -- HARD GATE 3a (on-machine coexistence): block if ANY of the candidate's boonz conflict.
  cand_coex AS (
    SELECT pb.pod_product_id, bool_or(public._coexistence_blocks(p_machine_id, pb.boonz_product_id)) AS coex_block
      FROM pod_boonz pb
     WHERE pb.pod_product_id IN (SELECT pod_product_id FROM universe)
     GROUP BY pb.pod_product_id
  ),
  -- HARD GATE 3b (pending / in-run coexistence): resolve p_pending_pods to boonz and
  -- block candidates that conflict with any pending pick under the machine-scope hard
  -- mutual-exclusion rules (both directions). Closes the in-run blind spot.
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
           EXISTS(SELECT 1 FROM public.strategic_intents si
                   WHERE si.intent_type='decommission' AND si.status IN ('queued','in_progress')
                     AND si.scope_pod_product_id = u.pod_product_id)                   AS is_decomm,
           COALESCE(cc.coex_block,false)          AS coex_block,
           (u.pod_product_id IN (SELECT pod_product_id FROM pending_block))            AS pend_block,
           u.cap_typical                          AS cap_typical,
           COALESCE(ppc.proven_machine_pctile,0)  AS proven_machine_pctile,
           -- Blended/aggregate pods are barred from the size-up path (kept as normal
           -- substitutes if not present; general is_catchall exclusion still applies in universe).
           (pp.pod_product_name ILIKE '%Mix%'
             OR pp.pod_product_name IN ('Soft Drinks Mix','Coca Cola Mix','Pepsi Mix','Chocolate Bar','Snack Bar')
           )                                       AS is_blended
      FROM universe u
      JOIN public.pod_products pp ON pp.pod_product_id = u.pod_product_id
      LEFT JOIN cand_primary_boonz cpb ON cpb.pod_product_id = u.pod_product_id
      LEFT JOIN proven pv           ON pv.pod_product_id  = u.pod_product_id
      LEFT JOIN proven_pctile ppc   ON ppc.pod_product_id = u.pod_product_id
      LEFT JOIN lookalike ll        ON ll.pod_product_id  = u.pod_product_id
      LEFT JOIN fleetvel fv         ON fv.pod_product_id  = u.pod_product_id
      LEFT JOIN on_machine_stock oms ON oms.pod_product_id = u.pod_product_id
      LEFT JOIN on_machine_vel omv   ON omv.pod_product_id = u.pod_product_id
      LEFT JOIN cand_coex cc         ON cc.pod_product_id  = u.pod_product_id
  ),
  -- TRUE-HERO SIZE-UP (tightened): the candidate is currently live AND ALL of:
  --   (1) a completely FULL shelf still can't cover the trip:
  --       full_shelf_units / max(machine_velocity,0.1) < trip_interval_days, where
  --       full_shelf_units = GREATEST(cap_typical at this shelf size, actual on-machine
  --       slot capacity). cap_typical from product_size_fit is a per-facing figure and
  --       understates deep-slot / multi-facing heroes (e.g. Al Ain Zero cap_typical=10 but
  --       real slot capacity=28), so it is floored by the product's actual full on-machine
  --       capacity (max_stock). This is the faithful "a completely FULL shelf sells out"
  --       signal that it needs another facing.
  --   (2) it is a genuine top seller HERE: proven_local machine-percentile >= 0.80;
  --   (3) it is NOT a blended/aggregate pod.
  -- (cap_typical coalesced to 8 when missing/zero.)
  flagged AS (
    SELECT e.*,
           ( e.is_present
             AND (GREATEST(COALESCE(NULLIF(e.cap_typical,0),8), e.onmach_cap)::numeric
                    / GREATEST(e.machine_vel,0.1)) < v_trip
             AND e.proven_machine_pctile >= 0.80
             AND NOT e.is_blended
           ) AS is_size_up
      FROM enriched e
  ),
  -- Apply HARD GATES: min-qty(2), decommission(4), not-present-except-size-up(5),
  -- on-machine coexistence(3a; size-ups exempt from self-block), pending coexistence(3b).
  gated AS (
    SELECT f.*, GREATEST(f.proven_raw, f.lookalike_raw, f.global_vel) AS exp_vel
      FROM flagged f
     WHERE f.wh_pickable >= f.min_qty_eff
       AND NOT f.is_decomm
       AND (NOT f.is_present OR f.is_size_up)
       AND (f.is_size_up OR NOT f.coex_block)
       AND NOT f.pend_block
  ),
  -- Normalize signals 0-1 within the eligible (gated) set.
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
           -- 7-signal weighted model (incrementality folded to flat 0.5), + small capped size-up nudge.
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
           s.is_size_up
      FROM scored s
  )
  SELECT f.pod_product_id, f.pod_product_name, f.suitability, f.size_fit, f.wh_pickable,
         f.min_refill_qty, f.cover_days, f.proven_local, f.lookalike, f.margin_band,
         f.basket, f.avail_conf, f.freshness, f.is_size_up,
         (ROW_NUMBER() OVER (ORDER BY f.suitability DESC, f.wh_pickable DESC))::int AS rank
    FROM final f
   ORDER BY f.suitability DESC, f.wh_pickable DESC
   LIMIT p_limit;
END;
$function$;

COMMENT ON FUNCTION public.rank_slot_suitability(date,uuid,uuid,uuid,int,uuid[]) IS
  'Wave-2 read-only helper. Returns the gated, ranked substitute pool for one dead/rotate-out shelf. '
  'Gates: size-fit, min-refill-qty, on-machine+pending coexistence, active decommission, not-already-present '
  '(except TRUE-HERO size-up: live AND full-shelf GREATEST(cap_typical,on-machine slot capacity)/vel < trip '
  'AND proven machine-pctile>=0.80 AND not a blended/aggregate pod). 7-signal suitability (proven_local .28 / lookalike .20 / margin_band .16 / '
  'basket .12 / avail_conf .10 / incrementality flat .5 @ .08 / freshness .06) + capped .05 size-up nudge. '
  'SECURITY INVOKER, STABLE, no writes. Register in RPC_REGISTRY as read-only helper.';


-- ============================================================================
-- BUILD PIECE B — public.engine_swap_pod  (post p0_fix12 source, Pass 2a rewired)
--   ONLY Pass 2a substitute-selection changed: find_substitutes_for_shelf(...)
--   replaced by rank_slot_suitability(...) with per-machine in-run pending array.
--   Everything else preserved byte-identical.
-- ============================================================================;
