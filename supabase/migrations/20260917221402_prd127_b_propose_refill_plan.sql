-- PRD-127 Block B: refill_swap_params (the two tunable constants
-- propose_refill_plan would otherwise inline, per D-010) and
-- propose_refill_plan itself -- a read-only, chat-native "what would happen"
-- proposal built from the full WEIMI lane list of every in-scope machine,
-- reusing wh_available_for (D3) and wh_fefo_for_line's canonical
-- phantom/reservation/quarantine predicates (D-009) rather than re-deriving
-- them a third time.

CREATE TABLE IF NOT EXISTS public.refill_swap_params (
  id                          integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  expired_priority_boost_aed  numeric NOT NULL DEFAULT 500,
  min_substitute_stock_units  integer NOT NULL DEFAULT 3,
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  updated_by                  uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL
);
INSERT INTO public.refill_swap_params (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.refill_swap_params ENABLE ROW LEVEL SECURITY;
CREATE POLICY refill_swap_params_select ON public.refill_swap_params
  FOR SELECT TO authenticated USING (true);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.refill_swap_params FROM authenticated;
REVOKE ALL ON public.refill_swap_params FROM anon, PUBLIC;
GRANT SELECT ON public.refill_swap_params TO authenticated;

CREATE OR REPLACE FUNCTION public.propose_refill_plan(
  p_plan_date date,
  p_machine_names text[] DEFAULT NULL,
  p_overrides jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout = '120s'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_role    text;
  v_t0      timestamptz := clock_timestamp();
  v_unknown_names text[];
  v_result  jsonb;
  v_null_reason_count int;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'propose_refill_plan: forbidden for role %', COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'propose_refill_plan: p_plan_date is required';
  END IF;
  IF p_overrides IS NULL OR jsonb_typeof(p_overrides) <> 'array' THEN
    RAISE EXCEPTION 'propose_refill_plan: p_overrides must be a jsonb array (got %)', COALESCE(jsonb_typeof(p_overrides), 'null');
  END IF;

  IF p_machine_names IS NOT NULL THEN
    SELECT array_agg(n) INTO v_unknown_names
      FROM unnest(p_machine_names) n
     WHERE NOT EXISTS (SELECT 1 FROM public.machines m WHERE m.official_name = n);
    IF v_unknown_names IS NOT NULL THEN
      RAISE EXCEPTION 'propose_refill_plan: unknown machine name(s): %', array_to_string(v_unknown_names, ', ');
    END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.machines_to_visit mtv
       WHERE mtv.plan_date = p_plan_date AND mtv.status IN ('picked','cs_added')
    ) THEN
      RAISE EXCEPTION 'propose_refill_plan: no picked/cs_added machines for % and no p_machine_names given', p_plan_date;
    END IF;
  END IF;

  WITH params AS (
    SELECT
      COALESCE((SELECT hero_velocity_floor FROM public.refill_policy_params WHERE id = 1), 3)      AS hero_velocity_floor,
      COALESCE((SELECT horizon_days       FROM public.pick_urgency_params LIMIT 1), 4)              AS horizon_days,
      COALESCE((SELECT expired_priority_boost_aed FROM public.refill_swap_params WHERE id = 1), 500) AS expired_priority_boost_aed,
      COALESCE((SELECT min_substitute_stock_units FROM public.refill_swap_params WHERE id = 1), 3)   AS min_substitute_stock_units
  ),
  scope_machines AS (
    SELECT m.machine_id, m.official_name,
           mtv.car_no
      FROM public.machines m
      LEFT JOIN public.machines_to_visit mtv
        ON mtv.machine_id = m.machine_id AND mtv.plan_date = p_plan_date
     WHERE (p_machine_names IS NOT NULL AND m.official_name = ANY(p_machine_names))
        OR (p_machine_names IS NULL AND mtv.status IN ('picked','cs_added'))
  ),
  directive_block_machine AS (
    SELECT target_id AS machine_id FROM public.refill_directives
     WHERE active AND directive_type = 'block' AND target_kind = 'machine'
  ),
  directive_block_product AS (
    SELECT target_kind, target_id FROM public.refill_directives
     WHERE active AND directive_type = 'block' AND target_kind IN ('pod_product','boonz_product')
  ),
  overrides_parsed AS (
    SELECT (o->>'machine_name') AS machine_name, (o->>'shelf_code') AS shelf_code,
           (o->>'qty')::numeric AS qty
      FROM jsonb_array_elements(p_overrides) o
  ),
  lanes_weimi AS (
    SELECT sm.machine_id, sm.official_name, sm.car_no,
           wsn.shelf_code, wsn.pod_product_id, wsn.current_stock, wsn.max_stock
      FROM scope_machines sm
      CROSS JOIN LATERAL public.weimi_shelf_now(sm.machine_id) wsn
     WHERE sm.machine_id NOT IN (SELECT machine_id FROM directive_block_machine)
  ),
  lanes_identity AS (
    SELECT lw.*, sc.shelf_id, pp.pod_product_name,
           rmap.boonz_product_id, rmap.source_of_supply,
           bp.boonz_product_name
      FROM lanes_weimi lw
      JOIN public.shelf_configurations sc
        ON sc.machine_id = lw.machine_id AND sc.shelf_code = lw.shelf_code AND sc.is_phantom = false
      LEFT JOIN public.pod_products pp ON pp.pod_product_id = lw.pod_product_id
      LEFT JOIN LATERAL (
        SELECT pm.boonz_product_id, pm.source_of_supply
          FROM public.product_mapping pm
         WHERE pm.pod_product_id = lw.pod_product_id AND pm.status = 'Active'
           AND (pm.machine_id IS NULL OR pm.machine_id = lw.machine_id)
         ORDER BY (pm.machine_id = lw.machine_id) DESC NULLS LAST, pm.is_global_default DESC
         LIMIT 1
      ) rmap ON true
      LEFT JOIN public.boonz_products bp ON bp.product_id = rmap.boonz_product_id
  ),
  -- v_lane_grain and v_current_price_filled are both keyed finer than
  -- (machine_id, pod_product_id) alone: a pod product occupying several
  -- physical shelves of the same machine gets one v_lane_grain row PER
  -- shelf (same velocity value, repeated), and a pod product mapped to
  -- several boonz flavours gets one v_current_price_filled row PER flavour.
  -- Joining a single WEIMI lane straight onto either by (machine_id,
  -- pod_product_id) alone fans that lane out once per duplicate row on the
  -- other side. Collapse each to exactly one row per key first.
  lane_velocity AS (
    SELECT machine_id, pod_product_id, AVG(lane_dvel) AS lane_dvel
      FROM public.v_lane_grain
     GROUP BY machine_id, pod_product_id
  ),
  -- v_current_price_filled is also not unique per (machine, pod_product,
  -- boonz_product) -- its own fallback tiers can surface several rows for
  -- the same triple. Same DISTINCT ON collapse v_machine_priority's own
  -- price_by_boonz CTE uses for the identical reason.
  lane_price AS (
    SELECT DISTINCT ON (machine_id, pod_product_id, boonz_product_id)
      machine_id, pod_product_id, boonz_product_id, effective_price_aed
      FROM public.v_current_price_filled
     ORDER BY machine_id, pod_product_id, boonz_product_id, effective_price_aed DESC NULLS LAST
  ),
  lanes_velocity_price AS (
    SELECT li.*,
           COALESCE(lv.lane_dvel, 0)::numeric AS lane_dvel,
           COALESCE(vcf.effective_price_aed, 0)::numeric AS price_aed
      FROM lanes_identity li
      LEFT JOIN lane_velocity lv
        ON lv.machine_id = li.machine_id AND lv.pod_product_id = li.pod_product_id
      LEFT JOIN lane_price vcf
        ON vcf.machine_id = li.machine_id AND vcf.pod_product_id = li.pod_product_id
       AND vcf.boonz_product_id = li.boonz_product_id
  ),
  lanes_expired AS (
    SELECT lvp.*,
           (ex.pod_inventory_id IS NOT NULL AND lvp.current_stock > 0) AS has_expired_on_shelf
      FROM lanes_velocity_price lvp
      LEFT JOIN LATERAL (
        SELECT pi.pod_inventory_id
          FROM public.pod_inventory pi
         WHERE pi.machine_id = lvp.machine_id AND pi.shelf_id = lvp.shelf_id
           AND pi.status = 'Active' AND pi.expiration_date IS NOT NULL
           AND pi.expiration_date < CURRENT_DATE AND pi.current_stock > 0
         LIMIT 1
      ) ex ON true
  ),
  -- Restricting find_substitutes_for_shelf to only the (typically handful of)
  -- expired-on-shelf lanes first -- matching engine_add_pod's own CTE shape --
  -- rather than calling it unconditionally in a LATERAL over every lane, which
  -- would still execute the function per row before any WHERE could filter it.
  substitute_lookup AS (
    SELECT le.machine_id, le.shelf_id, le.pod_product_id,
           sub.pod_product_id AS sub_pod_product_id,
           sub.pod_product_name AS sub_pod_product_name,
           sub.wh_stock_units AS sub_wh_stock_units
      FROM lanes_expired le
      CROSS JOIN params pr
      LEFT JOIN LATERAL (
        SELECT fs.pod_product_id, fs.pod_product_name, fs.wh_stock_units
          FROM public.find_substitutes_for_shelf(p_plan_date, le.machine_id, le.shelf_id, le.pod_product_id) fs
         WHERE COALESCE(fs.wh_stock_units, 0) >= pr.min_substitute_stock_units
         ORDER BY fs.rank
         LIMIT 1
      ) sub ON true
     WHERE le.has_expired_on_shelf
  ),
  lanes_substitute AS (
    SELECT le.*, sl.sub_pod_product_id, sl.sub_pod_product_name, sl.sub_wh_stock_units
      FROM lanes_expired le
      LEFT JOIN substitute_lookup sl
        ON sl.machine_id = le.machine_id AND sl.shelf_id = le.shelf_id AND sl.pod_product_id = le.pod_product_id
  ),
  lanes_target AS (
    SELECT ls.*, pr.horizon_days, pr.expired_priority_boost_aed,
      (CASE WHEN ls.lane_dvel >= pr.hero_velocity_floor OR ls.source_of_supply = 'venue_team'
            THEN ls.max_stock ELSE LEAST(10, ls.max_stock) END)::int AS target_stock,
      (ls.lane_dvel = 0) AS is_dead
    FROM lanes_substitute ls CROSS JOIN params pr
  ),
  lanes_need AS (
    SELECT lt.*,
      (CASE WHEN lt.is_dead THEN 0 ELSE GREATEST(lt.target_stock - lt.current_stock, 0) END)::int AS need_raw,
      (CASE WHEN lt.lane_dvel > 0
            THEN lt.lane_dvel * lt.price_aed * GREATEST(0, lt.horizon_days - lt.current_stock / NULLIF(lt.lane_dvel, 0))
            ELSE NULL END) AS aed_at_risk_raw
    FROM lanes_target lt
  ),
  lanes_flagged AS (
    SELECT ln.*,
      COALESCE(ln.aed_at_risk_raw, 0) + (CASE WHEN ln.has_expired_on_shelf AND ln.sub_pod_product_id IS NOT NULL
                                              THEN ln.expired_priority_boost_aed ELSE 0 END) AS aed_at_risk,
      EXISTS (SELECT 1 FROM directive_block_product dbp
               WHERE (dbp.target_kind = 'pod_product' AND dbp.target_id = ln.pod_product_id)
                  OR (dbp.target_kind = 'boonz_product' AND dbp.target_id = ln.boonz_product_id)) AS blocked_by_directive,
      ov.qty AS override_qty
    FROM lanes_need ln
    LEFT JOIN overrides_parsed ov
      ON ov.machine_name = ln.official_name AND ov.shelf_code = ln.shelf_code
  ),
  wh_pool_base AS (
    SELECT DISTINCT ON (lf.boonz_product_id, COALESCE(lf.source_of_supply,'default'))
      lf.boonz_product_id, lf.source_of_supply, lf.machine_id AS rep_machine_id
    FROM lanes_flagged lf
    WHERE lf.boonz_product_id IS NOT NULL AND lf.need_raw > 0
      AND NOT lf.blocked_by_directive AND lf.override_qty IS NULL
    ORDER BY lf.boonz_product_id, COALESCE(lf.source_of_supply,'default'), lf.machine_id
  ),
  wh_pool_per_class AS (
    SELECT wpb.boonz_product_id,
           COALESCE((SELECT SUM(waf.free_stock) FROM public.wh_available_for(wpb.rep_machine_id, wpb.boonz_product_id) waf), 0) AS pool
      FROM wh_pool_base wpb
  ),
  wh_pool AS (
    SELECT boonz_product_id, SUM(pool) AS wh_avail_total
      FROM wh_pool_per_class GROUP BY boonz_product_id
  ),
  allocated AS (
    SELECT lf.*, wp.wh_avail_total,
      COALESCE(SUM(CASE WHEN lf.blocked_by_directive OR lf.override_qty IS NOT NULL THEN 0 ELSE lf.need_raw END)
        OVER (PARTITION BY lf.boonz_product_id
              ORDER BY lf.aed_at_risk DESC, lf.machine_id, lf.shelf_code
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS prior_need
    FROM lanes_flagged lf
    LEFT JOIN wh_pool wp ON wp.boonz_product_id = lf.boonz_product_id
  ),
  final_lanes AS (
    SELECT a.*,
      (CASE
         WHEN a.override_qty IS NOT NULL THEN a.override_qty
         WHEN a.blocked_by_directive THEN 0
         WHEN a.boonz_product_id IS NULL THEN 0
         WHEN a.need_raw = 0 THEN 0
         ELSE LEAST(a.need_raw, GREATEST(COALESCE(a.wh_avail_total,0) - a.prior_need, 0))
       END)::int AS final_qty,
      (CASE
         WHEN a.boonz_product_id IS NULL                                THEN 'no_active_mapping'
         WHEN a.override_qty IS NOT NULL                                THEN 'override_applied'
         WHEN a.blocked_by_directive                                    THEN 'blocked_directive'
         WHEN a.has_expired_on_shelf AND a.sub_pod_product_id IS NOT NULL THEN 'expired_on_shelf_substitute'
         WHEN a.has_expired_on_shelf AND a.sub_pod_product_id IS NULL     THEN 'expired_on_shelf_no_rule'
         WHEN a.is_dead                                                 THEN 'dead_no_velocity'
         WHEN a.need_raw = 0                                            THEN 'ok_at_target'
         WHEN a.need_raw > 0 AND LEAST(a.need_raw, GREATEST(COALESCE(a.wh_avail_total,0) - a.prior_need, 0)) = 0
                                                                         THEN 'refill_blocked_no_wh'
         WHEN a.need_raw > 0 AND LEAST(a.need_raw, GREATEST(COALESCE(a.wh_avail_total,0) - a.prior_need, 0)) < a.need_raw
                                                                         THEN 'refill_partial_wh_short'
         WHEN a.need_raw > 0                                            THEN 'refill_recommended'
         ELSE NULL
       END) AS reason_code
    FROM allocated a
  ),
  rendered AS (
    SELECT fl.*,
      CASE fl.reason_code
        WHEN 'refill_recommended' THEN
          format('%s: Refill %s, %s -> %s (+%s)', fl.shelf_code, fl.boonz_product_name,
                 fl.current_stock, fl.current_stock + fl.final_qty, fl.final_qty)
        WHEN 'refill_partial_wh_short' THEN
          format('%s: Refill %s, %s -> %s (+%s, warehouse short: only %s of %s available)', fl.shelf_code,
                 fl.boonz_product_name, fl.current_stock, fl.current_stock + fl.final_qty, fl.final_qty,
                 fl.final_qty, fl.need_raw)
        WHEN 'expired_on_shelf_substitute' THEN
          format('%s: Remove %s (expired on shelf) -> %s, add %s', fl.shelf_code, fl.pod_product_name,
                 fl.sub_pod_product_name, LEAST(fl.target_stock, fl.sub_wh_stock_units::int))
        WHEN 'override_applied' THEN
          format('%s: %s set to %s by override (was %s)', fl.shelf_code, fl.boonz_product_name,
                 fl.final_qty, fl.current_stock)
        ELSE NULL
      END AS fill_line,
      CASE fl.reason_code
        WHEN 'expired_on_shelf_no_rule' THEN
          format('%s: %s expired on shelf, no substitute found -- needs a human call', fl.shelf_code, fl.pod_product_name)
        WHEN 'refill_blocked_no_wh' THEN
          format('%s: %s needs %s, 0 available at the warehouse', fl.shelf_code, fl.boonz_product_name, fl.need_raw)
        WHEN 'no_active_mapping' THEN
          format('%s: %s has no Active product mapping -- cannot act', fl.shelf_code,
                 COALESCE(NULLIF(fl.pod_product_name, ''), '(no product identified on this lane)'))
        ELSE NULL
      END AS exception_line
    FROM final_lanes fl
  ),
  per_machine AS (
    SELECT r.machine_id, r.official_name, r.car_no,
      COALESCE(jsonb_agg(r.fill_line) FILTER (WHERE r.fill_line IS NOT NULL), '[]'::jsonb) AS fill,
      COALESCE(jsonb_agg(r.exception_line) FILTER (WHERE r.exception_line IS NOT NULL), '[]'::jsonb) AS exceptions,
      count(*) FILTER (WHERE r.fill_line IS NOT NULL) AS fill_count,
      count(*) FILTER (WHERE r.exception_line IS NOT NULL) AS exception_count
    FROM rendered r
    GROUP BY r.machine_id, r.official_name, r.car_no
  ),
  by_reason AS (
    SELECT reason_code, count(*) AS n FROM final_lanes GROUP BY reason_code
  ),
  directives_applied AS (
    SELECT jsonb_agg(DISTINCT jsonb_build_object('directive_id', rd.directive_id, 'target_name', rd.target_name, 'note', rd.note)) AS j
      FROM final_lanes fl
      JOIN public.refill_directives rd ON rd.active AND rd.directive_type = 'block'
       AND ((rd.target_kind = 'pod_product' AND rd.target_id = fl.pod_product_id)
         OR (rd.target_kind = 'boonz_product' AND rd.target_id = fl.boonz_product_id))
     WHERE fl.blocked_by_directive
  ),
  overrides_applied AS (
    SELECT jsonb_agg(jsonb_build_object('machine_name', official_name, 'shelf_code', shelf_code, 'qty', final_qty)) AS j
      FROM final_lanes WHERE reason_code = 'override_applied'
  ),
  overrides_unresolved AS (
    SELECT jsonb_agg(jsonb_build_object('machine_name', op.machine_name, 'shelf_code', op.shelf_code, 'qty', op.qty)) AS j
      FROM overrides_parsed op
     WHERE NOT EXISTS (SELECT 1 FROM lanes_flagged lf WHERE lf.official_name = op.machine_name AND lf.shelf_code = op.shelf_code)
  )
  SELECT jsonb_build_object(
    'plan_date', p_plan_date,
    'machines', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'machine_name', pm.official_name, 'car_no', pm.car_no,
        'header', format('%s%s -- %s fill line(s), %s exception(s)', pm.official_name,
                          CASE WHEN pm.car_no IS NOT NULL THEN format(' (car %s)', pm.car_no) ELSE '' END,
                          pm.fill_count, pm.exception_count),
        'fill', pm.fill, 'exceptions', pm.exceptions
      ) ORDER BY pm.official_name) FROM per_machine pm), '[]'::jsonb),
    'directives_applied', COALESCE((SELECT j FROM directives_applied), '[]'::jsonb),
    'overrides_applied', COALESCE((SELECT j FROM overrides_applied), '[]'::jsonb),
    'overrides_unresolved', COALESCE((SELECT j FROM overrides_unresolved), '[]'::jsonb),
    'totals', jsonb_build_object(
      'machines', (SELECT count(*) FROM per_machine),
      'lanes_total', (SELECT count(*) FROM final_lanes),
      'fills', (SELECT count(*) FROM final_lanes WHERE reason_code IN ('refill_recommended','refill_partial_wh_short','expired_on_shelf_substitute','override_applied')),
      'exceptions', (SELECT count(*) FROM final_lanes WHERE reason_code IN ('expired_on_shelf_no_rule','refill_blocked_no_wh','no_active_mapping')),
      'blocked_by_directive', (SELECT count(*) FROM final_lanes WHERE blocked_by_directive),
      'by_reason_code', COALESCE((SELECT jsonb_object_agg(reason_code, n) FROM by_reason), '{}'::jsonb)
    ),
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  ), (SELECT count(*) FILTER (WHERE reason_code IS NULL) FROM final_lanes)
  INTO v_result, v_null_reason_count;

  IF v_null_reason_count > 0 THEN
    RAISE EXCEPTION 'propose_refill_plan: % lane(s) got a NULL reason_code -- engine logic incomplete, refusing to return a silently-unclassified lane',
      v_null_reason_count;
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.propose_refill_plan(date, text[], jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.propose_refill_plan(date, text[], jsonb) TO authenticated;
