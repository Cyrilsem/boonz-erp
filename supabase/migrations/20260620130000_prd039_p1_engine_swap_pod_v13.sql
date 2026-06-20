-- PRD-039 Phase 1: engine_swap_pod Pass-3 rewrite (WS-A/B/C/D).
-- Forward-only CREATE OR REPLACE on the canonical engine_swap_pod (same name + signature).
-- NO parallel engine_swap_pod_v13 function. Pass-1 (strategic tags), dead-tag resolution, and
-- Pass-2b (driver recommendations) are reproduced byte-for-byte from v12. ONLY the final
-- score-swap loop is replaced. engine_add_pod stays FROZEN. swaps_enabled stays false in prod;
-- the kill switch (_swaps_disabled_machines) is preserved unchanged -> T7 holds.
-- DEPENDS ON Phase 0 applied first: public.product_slot_capacity_units(text,text),
-- public.get_candidate_affinity(uuid,uuid). Author-only until CS says apply phase 1.
--
-- WS-A broad universe: candidates = v_wh_pickable (stock > seed min, in-date, reservation-clean),
--   not on machine, coexistence-clean, not travel-locked, not 30-day intro cooldown, not suppressed.
--   find_substitutes is NO LONGER the gate. Pearson is the w3 term only (w_sister .5 > w_global .3 > w_pearson .2).
-- WS-B candidate-specific cap: floor(product_slot_capacity_units(cand.physical_type, shelf.shelf_size) x 0.85),
--   overridden by slot_capacity_max.override_max_stock, fallback shelf_configurations.max_capacity. KEEP uses incumbent cap, same rule.
-- WS-C top-N + greedy unique assignment: each product used at most once per machine per cycle;
--   maximise total machine V; honour <= p_max_swaps_per_machine, fleet <= 10, 14-day cooldown.
-- WS-D homogenisation: a product newly introduced into at most v_K machines per cycle, 1 slot/machine.

CREATE OR REPLACE FUNCTION public.engine_swap_pod(p_plan_date date DEFAULT (CURRENT_DATE + 1), p_max_swaps_per_machine integer DEFAULT 2, p_min_pearson numeric DEFAULT 0.30, p_days_cover integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id            uuid;
  v_t0                 timestamptz := clock_timestamp();
  v_tag_swaps          integer := 0;
  v_tag_m2w            integer := 0;
  v_dead_resolved      integer := 0;
  v_dead_m2w           integer := 0;
  v_driver_rec_swaps   integer := 0;
  v_dead_deferred      integer := 0;
  v_dead_fallback      integer := 0;
  v_machine_swap_n     integer := 0;
  v_shelf_cap          integer;
  r                    record;
  v_sub                record;
  v_score_swaps        integer := 0;
  v_incumbent_boonz    uuid;
  v_cand_boonz         uuid;
  v_fleet_cap          integer := 10;
  v_fleet_swaps        integer := 0;
  v_theta              numeric := 0.15;
  v_w_sister           numeric := 0.5;
  v_w_global           numeric := 0.3;
  v_w_pearson          numeric := 0.2;
  v_cap                integer;
  v_inc_vel            numeric;
  v_inc_margin         numeric;
  v_v_keep             numeric;
  v_sister_vel         numeric;
  v_global_vel         numeric;
  v_proj_vel           numeric;
  v_cand_margin        numeric;
  v_v_cand             numeric;
  v_best_v             numeric;
  v_best_pod           uuid;
  v_best_src           text;
  v_best_pearson       numeric;
  v_best_wh            numeric;
  v_loc_type           text;
  -- PRD-039 additions:
  v_K                  integer := 3;     -- WS-D homogenisation: max machines a product may be newly introduced into per cycle
  v_top_n              integer := 10;    -- WS-C candidates kept per slot
  v_cand_min_stock     numeric := 3;     -- WS-A seed minimum WH stock
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','engine_swap_pod',true);
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id=v_user_id AND up.role='operator_admin'
  ) THEN RAISE EXCEPTION 'engine_swap_pod: caller % lacks operator_admin role', v_user_id; END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'engine_swap_pod: p_plan_date required'; END IF;
  IF p_days_cover IS NULL OR p_days_cover <= 0 THEN
    RAISE EXCEPTION 'engine_swap_pod: p_days_cover must be > 0';
  END IF;

  PERFORM public._assert_refill_plan_writable(p_plan_date);

  DELETE FROM public.pod_swaps
   WHERE plan_date = p_plan_date
     AND NOT (pod_product_id_in IS NULL AND reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16'));
  IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
                  WHERE plan_date=p_plan_date AND status IN ('picked','cs_added')) THEN
    RAISE EXCEPTION 'engine_swap_pod: no picked/cs_added machines for %', p_plan_date;
  END IF;
  PERFORM public._assert_gate_zero(p_plan_date);
  CREATE TEMP TABLE _r5_removal_cooldown ON COMMIT DROP AS
  SELECT DISTINCT m.machine_id, pp.pod_product_id
    FROM public.refill_plan_output rpo
    JOIN public.machines m ON m.official_name = rpo.machine_name
    JOIN public.pod_products pp ON pp.pod_product_name = rpo.pod_product_name
   WHERE rpo.action ILIKE 'Remove%' AND rpo.plan_date >= p_plan_date - interval '14 days';
  CREATE TEMP TABLE _r5_introduction_cooldown ON COMMIT DROP AS
  SELECT DISTINCT m.machine_id, pp.pod_product_id
    FROM public.refill_plan_output rpo
    JOIN public.machines m ON m.official_name = rpo.machine_name
    JOIN public.pod_products pp ON pp.pod_product_name = rpo.pod_product_name
   WHERE rpo.action ILIKE 'Remove%' AND rpo.plan_date >= p_plan_date - interval '30 days';
  CREATE TEMP TABLE _fleet_velocity ON COMMIT DROP AS
  SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric(8,3) AS avg_v30
    FROM public.slot_lifecycle sl
   WHERE sl.archived=false AND sl.is_current=true GROUP BY sl.pod_product_id;
  CREATE TEMP TABLE _shelf_live_stock ON COMMIT DROP AS
  SELECT vls.machine_id, sc.shelf_id, MAX(vls.current_stock)::int AS current_stock
  FROM public.v_live_shelf_stock vls
  JOIN public.shelf_configurations sc
    ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
   AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
  GROUP BY vls.machine_id, sc.shelf_id;
  CREATE TEMP TABLE _planned_swap_shelves ON COMMIT DROP AS
  SELECT DISTINCT sl.machine_id, sl.shelf_id
    FROM public.planned_swaps ps
    JOIN public.pod_products pp ON pp.pod_product_name = ps.remove_pod_product_name
    JOIN public.slot_lifecycle sl
      ON sl.machine_id = ps.machine_id AND sl.pod_product_id = pp.pod_product_id
     AND sl.archived = false AND sl.is_current = true
   WHERE ps.status = 'pending';
  CREATE TEMP TABLE _machine_present_pods ON COMMIT DROP AS
  SELECT DISTINCT machine_id, pod_product_id FROM (
    SELECT sl.machine_id, sl.pod_product_id
      FROM public.slot_lifecycle sl
     WHERE sl.archived = false AND sl.is_current = true
    UNION
    SELECT vls.machine_id, vls.pod_product_id
      FROM public.v_live_shelf_stock vls
     WHERE vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
  ) present;
  CREATE TEMP TABLE _swaps_disabled_machines ON COMMIT DROP AS
  SELECT m.machine_id
    FROM public.machines m
   WHERE COALESCE(
           (SELECT rs.setting_value FROM public.refill_settings rs
             WHERE rs.setting_key = 'swaps_enabled:' || m.machine_id::text),
           (SELECT rs.setting_value FROM public.refill_settings rs
             WHERE rs.setting_key = 'swaps_enabled'),
           'true'::jsonb
         ) = 'false'::jsonb;
  CREATE TEMP TABLE _committed_machines ON COMMIT DROP AS
  SELECT DISTINCT m.machine_id
    FROM public.refill_plan_output rpo
    JOIN public.machines m ON m.official_name = rpo.machine_name
   WHERE rpo.plan_date = p_plan_date AND rpo.operator_status = 'approved';
  CREATE TEMP TABLE _suppressed_swap_subs ON COMMIT DROP AS
  SELECT machine_id, pod_product_id AS pod_in
    FROM public.refill_edit_signals
   WHERE signal_type = 'swap_rejected'
     AND pod_product_id IS NOT NULL
     AND created_at >= now() - interval '30 days'
   GROUP BY machine_id, pod_product_id
  HAVING COUNT(*) >= 3;
  WITH picked AS (SELECT mtv.machine_id FROM public.machines_to_visit mtv
    WHERE mtv.plan_date=p_plan_date AND mtv.status IN ('picked','cs_added')
      AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = mtv.machine_id)
      AND NOT EXISTS (SELECT 1 FROM _committed_machines cm WHERE cm.machine_id = mtv.machine_id)),
  tag_targets AS (
    SELECT smt.tag_id, smt.strategic_intent_id AS intent_id, smt.machine_id, smt.pod_product_id AS pod_out,
           smt.action_directive, smt.substitute_pod_product_id AS pod_in, smt.priority,
           sl.shelf_id AS sl_shelf,
           ROW_NUMBER() OVER (PARTITION BY smt.machine_id
             ORDER BY smt.priority ASC, smt.proposed_at ASC, smt.tag_id) AS rnk
    FROM public.strategic_machine_tags smt
    JOIN picked p ON p.machine_id = smt.machine_id
    JOIN public.strategic_intents si ON si.intent_id = smt.strategic_intent_id
                                     AND si.status IN ('queued','in_progress')
    LEFT JOIN public.slot_lifecycle sl ON sl.machine_id = smt.machine_id
     AND sl.pod_product_id = smt.pod_product_id AND sl.archived = false AND sl.is_current = true
    WHERE smt.status = 'approved' AND smt.action_directive IN ('swap_out_with_substitute','swap_out_m2w')
  ),
  tag_capped AS (SELECT * FROM tag_targets WHERE rnk <= p_max_swaps_per_machine),
  tag_resolved AS (
    SELECT tc.*,
           COALESCE(tc.sl_shelf,
             (SELECT pil.shelf_id FROM public.v_pod_inventory_latest pil
                JOIN public.product_mapping pm ON pm.boonz_product_id = pil.boonz_product_id
                                                AND pm.status='Active' AND pm.pod_product_id = tc.pod_out
               WHERE pil.machine_id = tc.machine_id AND pil.status='Active'
               ORDER BY pil.current_stock DESC LIMIT 1)
           ) AS shelf_id_final
    FROM tag_capped tc
  )
  INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
    qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
  SELECT p_plan_date, tr.machine_id, tr.shelf_id_final, tr.pod_out,
    CASE WHEN tr.action_directive='swap_out_with_substitute' THEN tr.pod_in ELSE NULL END,
    COALESCE((SELECT GREATEST(SUM(vls.current_stock),1)::int FROM public.v_live_shelf_stock vls JOIN public.shelf_configurations sc ON sc.machine_id = vls.machine_id AND sc.is_phantom = false AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text WHERE vls.machine_id = tr.machine_id AND sc.shelf_id = tr.shelf_id_final AND vls.pod_product_id = tr.pod_out),1)::int,
    CASE WHEN tr.action_directive='swap_out_m2w' THEN NULL
         ELSE GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                                  WHERE sms.shelf_id = tr.shelf_id_final),8)/2,4)::int END,
    CASE WHEN tr.action_directive='swap_out_m2w' THEN 'm2w' ELSE 'intent_driven' END,
    'strategic_tag', NULL::numeric, tr.intent_id,
    jsonb_build_object('pass','1','source','strategic_machine_tag','tag_id', tr.tag_id,
                       'tag_directive', tr.action_directive, 'tag_priority', tr.priority,
                       'engine_version','v13_value_model_broad')
  FROM tag_resolved tr WHERE tr.shelf_id_final IS NOT NULL
  ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING;
  UPDATE public.strategic_machine_tags smt
     SET status = 'consumed', consumed_at = now(), consumed_at_plan_date = p_plan_date,
         consumed_via_swap_id = ps.swap_id
    FROM public.pod_swaps ps
   WHERE ps.plan_date = p_plan_date AND (ps.reasoning->>'source') = 'strategic_machine_tag'
     AND (ps.reasoning->>'tag_id')::uuid = smt.tag_id AND smt.status = 'approved';
  SELECT COUNT(*) FILTER (WHERE ps.reason='intent_driven'),
         COUNT(*) FILTER (WHERE ps.reason='m2w')
  INTO v_tag_swaps, v_tag_m2w
  FROM public.pod_swaps ps
  WHERE ps.plan_date = p_plan_date AND (ps.reasoning->>'source')='strategic_machine_tag';

  FOR r IN
    SELECT ps.swap_id, ps.machine_id, ps.shelf_id, ps.pod_product_id_out, ps.reason, ps.reasoning
      FROM public.pod_swaps ps
      JOIN public.machines_to_visit mtv
        ON mtv.machine_id = ps.machine_id AND mtv.plan_date = ps.plan_date
       AND mtv.status IN ('picked','cs_added')
      LEFT JOIN _shelf_live_stock sls
        ON sls.machine_id = ps.machine_id AND sls.shelf_id = ps.shelf_id
     WHERE ps.plan_date = p_plan_date
       AND ps.pod_product_id_in IS NULL
       AND ps.reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16')
       AND ps.reason IN ('dead','rotate_out')
       AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = ps.machine_id)
     ORDER BY ps.machine_id, COALESCE(sls.current_stock, 0) ASC, ps.swap_id
  LOOP
    SELECT COUNT(*) INTO v_machine_swap_n
      FROM public.pod_swaps psx
     WHERE psx.plan_date = p_plan_date
       AND psx.machine_id = r.machine_id
       AND ((psx.reasoning->>'source') = 'strategic_machine_tag'
            OR (psx.pod_product_id_in IS NOT NULL AND psx.reasoning ? 'resolved_by'));
    IF v_machine_swap_n >= p_max_swaps_per_machine THEN
      UPDATE public.pod_swaps
         SET reasoning = reasoning || jsonb_build_object(
               'resolved_by','engine_swap_pod_v13',
               'deferred_by_cap', true,
               'cap', p_max_swaps_per_machine)
       WHERE swap_id = r.swap_id;
      v_dead_deferred := v_dead_deferred + 1;
      CONTINUE;
    END IF;

    SELECT fs.pod_product_id, fs.pearson_score, fs.source, fs.wh_stock_units
      INTO v_sub
      FROM public.find_substitutes_for_shelf(
             p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id_out, 5, 50
           ) fs
      LEFT JOIN _machine_present_pods mpp
        ON mpp.machine_id = r.machine_id AND mpp.pod_product_id = fs.pod_product_id
      LEFT JOIN _suppressed_swap_subs sss
        ON sss.machine_id = r.machine_id AND sss.pod_in = fs.pod_product_id
      LEFT JOIN _r5_introduction_cooldown rc
        ON rc.machine_id = r.machine_id AND rc.pod_product_id = fs.pod_product_id
     WHERE mpp.pod_product_id IS NULL
       AND sss.pod_in IS NULL
       AND rc.pod_product_id IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM public.pod_swaps ps2
          WHERE ps2.plan_date = p_plan_date AND ps2.machine_id = r.machine_id
            AND ps2.pod_product_id_in = fs.pod_product_id)
     ORDER BY (COALESCE(fs.pearson_score, -1) >= p_min_pearson) DESC, fs.rank
     LIMIT 1;

    IF v_sub.pod_product_id IS NOT NULL THEN
      SELECT MAX(sms.max_stock_weimi)::int INTO v_shelf_cap
        FROM public.v_shelf_max_stock sms
       WHERE sms.shelf_id = r.shelf_id;
      UPDATE public.pod_swaps
         SET pod_product_id_in = v_sub.pod_product_id,
             qty_in            = LEAST(
                                   GREATEST(COALESCE(v_shelf_cap, 8), 1),
                                   COALESCE(v_sub.wh_stock_units,0)::int),
             substitute_source = CASE WHEN COALESCE(v_sub.pearson_score, -1) >= p_min_pearson
                                      THEN v_sub.source
                                      ELSE 'global_performer_fallback' END,
             substitute_score  = v_sub.pearson_score,
             reasoning         = reasoning || jsonb_build_object(
                                   'resolved_by','engine_swap_pod_v13',
                                   'swap_in_source', v_sub.source,
                                   'min_pearson', p_min_pearson,
                                   'below_pearson_threshold',
                                     (COALESCE(v_sub.pearson_score, -1) < p_min_pearson),
                                   'return_to_warehouse', true)
                                 || CASE WHEN v_shelf_cap IS NULL
                                        THEN jsonb_build_object('clamp_reason','default_capacity_8')
                                        ELSE '{}'::jsonb END
       WHERE swap_id = r.swap_id;
      IF COALESCE(v_sub.pearson_score, -1) < p_min_pearson THEN
        v_dead_fallback := v_dead_fallback + 1;
      END IF;
      v_dead_resolved := v_dead_resolved + 1;
    ELSE
      UPDATE public.pod_swaps
         SET reasoning = reasoning || jsonb_build_object(
                           'resolved_by','engine_swap_pod_v13',
                           'resolved_as','m2w',
                           'return_to_warehouse', true)
       WHERE swap_id = r.swap_id;
      v_dead_m2w := v_dead_m2w + 1;
    END IF;
  END LOOP;

  FOR r IN
    SELECT dr.rec_id, dr.machine_id, dr.shelf_id, dr.boonz_product_id,
           COALESCE(
             (SELECT pm.pod_product_id FROM public.product_mapping pm
               WHERE pm.boonz_product_id = dr.boonz_product_id
                 AND pm.machine_id = dr.machine_id AND pm.status = 'Active'
               ORDER BY pm.updated_at DESC LIMIT 1),
             (SELECT pm.pod_product_id FROM public.product_mapping pm
               WHERE pm.boonz_product_id = dr.boonz_product_id
                 AND pm.is_global_default = true AND pm.status = 'Active'
               ORDER BY pm.updated_at DESC LIMIT 1)
           ) AS pod_in,
           (SELECT sl.pod_product_id FROM public.slot_lifecycle sl
             WHERE sl.machine_id = dr.machine_id AND sl.shelf_id = dr.shelf_id
               AND sl.archived = false AND sl.is_current = true
             ORDER BY sl.pod_product_id LIMIT 1) AS pod_out
      FROM public.driver_recommendations dr
      JOIN public.machines_to_visit mtv
        ON mtv.machine_id = dr.machine_id AND mtv.plan_date = p_plan_date
       AND mtv.status IN ('picked','cs_added')
     WHERE dr.kind = 'wrong_product'
       AND dr.status = 'open'
       AND dr.shelf_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = dr.machine_id)
       AND NOT EXISTS (SELECT 1 FROM _committed_machines cm WHERE cm.machine_id = dr.machine_id)
  LOOP
    CONTINUE WHEN r.pod_in IS NULL OR r.pod_out IS NULL OR r.pod_in = r.pod_out;

    INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
      qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
    VALUES (
      p_plan_date, r.machine_id, r.shelf_id, r.pod_out, r.pod_in,
      GREATEST(COALESCE((SELECT MAX(vls.current_stock)::int FROM public.v_live_shelf_stock vls
                          JOIN public.shelf_configurations sc
                            ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
                           AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
                         WHERE vls.machine_id = r.machine_id AND sc.shelf_id = r.shelf_id
                           AND vls.pod_product_id = r.pod_out), 1), 1)::int,
      GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                          WHERE sms.shelf_id = r.shelf_id),8),1)::int,
      'rotate_out', 'driver_recommendation', NULL::numeric, NULL::uuid,
      jsonb_build_object('pass','2b','source','driver_recommendation',
                         'rec_id', r.rec_id, 'resolved_by','engine_swap_pod_v13',
                         'return_to_warehouse', true, 'engine_version','v13_value_model_broad')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO UPDATE
      SET pod_product_id_in = EXCLUDED.pod_product_id_in,
          qty_in            = EXCLUDED.qty_in,
          reason            = 'rotate_out',
          substitute_source = 'driver_recommendation',
          reasoning         = public.pod_swaps.reasoning || EXCLUDED.reasoning;
    v_driver_rec_swaps := v_driver_rec_swaps + 1;
  END LOOP;

  SELECT COUNT(*) INTO v_fleet_swaps FROM public.pod_swaps
   WHERE plan_date = p_plan_date AND reasoning->>'source' = 'value_model_swap_broad' AND pod_product_id_in IS NOT NULL;

  -- =====================================================================================
  -- PASS 3 (PRD-039 WS-A/B/C/D): broad universe + candidate cap + greedy unique assignment + homogenisation
  -- =====================================================================================

  -- WS-C/D fleet-level introduction counter (seeded from this cycle's already-placed score swaps).
  CREATE TEMP TABLE _p3_intro ON COMMIT DROP AS
  SELECT pm.boonz_product_id AS boonz, COUNT(DISTINCT ps.machine_id)::int AS n
    FROM public.pod_swaps ps
    JOIN public.product_mapping pm ON pm.pod_product_id = ps.pod_product_id_in AND pm.status='Active'
   WHERE ps.plan_date = p_plan_date AND ps.reasoning->>'source' = 'value_model_swap_broad' AND ps.pod_product_id_in IS NOT NULL
   GROUP BY pm.boonz_product_id;
  CREATE UNIQUE INDEX ON _p3_intro (boonz);

  -- Eligible Pass-3 slots: band-3 (worst third) incumbents, >=3 shelves, gate-clean machines.
  CREATE TEMP TABLE _p3_slots ON COMMIT DROP AS
  WITH picked AS (
    SELECT mtv.machine_id FROM public.machines_to_visit mtv
     WHERE mtv.plan_date = p_plan_date AND mtv.status IN ('picked','cs_added')
       AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = mtv.machine_id)
       AND NOT EXISTS (SELECT 1 FROM _committed_machines cm WHERE cm.machine_id = mtv.machine_id)
  ),
  incum AS (
    SELECT sl.machine_id, sl.shelf_id, sl.pod_product_id, pp.pod_product_name,
           (public.compute_refill_decision(sl.machine_id, sl.shelf_id, NULL::uuid, p_days_cover)->>'final_score')::numeric AS incumbent_final_score
      FROM public.slot_lifecycle sl
      JOIN picked p ON p.machine_id = sl.machine_id
      JOIN public.pod_products pp ON pp.pod_product_id = sl.pod_product_id
     WHERE sl.archived = false AND sl.is_current = true
  ),
  ranked AS (
    SELECT i.*,
           ntile(3) OVER (PARTITION BY i.machine_id ORDER BY i.incumbent_final_score DESC NULLS LAST) AS band,
           COUNT(*) OVER (PARTITION BY i.machine_id) AS shelf_n
      FROM incum i
  )
  SELECT machine_id, shelf_id, pod_product_id, pod_product_name, incumbent_final_score
    FROM ranked
   WHERE band = 3 AND shelf_n >= 3
     AND NOT EXISTS (SELECT 1 FROM _r5_removal_cooldown rc
                      WHERE rc.machine_id = ranked.machine_id AND rc.pod_product_id = ranked.pod_product_id);

  -- Enrich each eligible slot: shelf_size, location_type, incumbent boonz/margin/velocity, incumbent cap, KEEP value.
  CREATE TEMP TABLE _p3_slot_keep ON COMMIT DROP AS
  SELECT s.machine_id, s.shelf_id, s.pod_product_id, s.pod_product_name, s.incumbent_final_score,
         m.location_type AS loc_type,
         (SELECT pg.shelf_size FROM public.planogram pg
           WHERE pg.shelf_id = s.shelf_id AND pg.is_active = true
           ORDER BY pg.effective_from DESC NULLS LAST LIMIT 1) AS shelf_size,
         (SELECT sc.shelf_code FROM public.shelf_configurations sc WHERE sc.shelf_id = s.shelf_id LIMIT 1) AS shelf_code,
         (SELECT pm.boonz_product_id FROM public.product_mapping pm
           WHERE pm.pod_product_id = s.pod_product_id AND pm.status='Active' AND (pm.machine_id = s.machine_id OR pm.machine_id IS NULL)
           ORDER BY (pm.machine_id = s.machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1) AS inc_boonz,
         COALESCE((SELECT sl.velocity_30d FROM public.slot_lifecycle sl
                    WHERE sl.machine_id=s.machine_id AND sl.shelf_id=s.shelf_id AND sl.pod_product_id=s.pod_product_id
                      AND sl.archived=false AND sl.is_current=true LIMIT 1),0) AS inc_vel
    FROM _p3_slots s
    JOIN public.machines m ON m.machine_id = s.machine_id;

  -- Resolve the candidate-specific cap rule into a helper-free expression per slot (incumbent cap).
  -- cap = COALESCE(override_max_stock, floor(matrix(physical_type, shelf_size) x 0.85), shelf_configurations.max_capacity, 8), >= 1.
  ALTER TABLE _p3_slot_keep ADD COLUMN inc_phys text;
  UPDATE _p3_slot_keep k SET inc_phys = bp.physical_type
    FROM public.boonz_products bp WHERE bp.product_id = k.inc_boonz;
  ALTER TABLE _p3_slot_keep ADD COLUMN inc_cap int;
  UPDATE _p3_slot_keep k SET inc_cap = GREATEST(COALESCE(
      (SELECT scm.override_max_stock FROM public.slot_capacity_max scm
        WHERE scm.machine_id = k.machine_id AND scm.aisle_code = k.shelf_code LIMIT 1),
      FLOOR(public.product_slot_capacity_units(k.inc_phys, k.shelf_size) * 0.85)::int,
      (SELECT sc.max_capacity FROM public.shelf_configurations sc WHERE sc.shelf_id = k.shelf_id LIMIT 1),
      8), 1);
  ALTER TABLE _p3_slot_keep ADD COLUMN keep_v numeric;
  UPDATE _p3_slot_keep k SET keep_v = GREATEST(COALESCE(
      (SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.machine_id=k.machine_id AND pg.pod_product_id=k.pod_product_id AND pg.is_active=true),
      (SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.pod_product_id=k.pod_product_id AND pg.is_active=true), 0)
    - COALESCE((SELECT bp.avg_30days_cost FROM public.boonz_products bp WHERE bp.product_id = k.inc_boonz),0), 0)
    * LEAST(GREATEST(k.inc_vel,0) * p_days_cover, k.inc_cap);

  -- WS-2 projection inputs computed SET-BASED. sister velocity and affinity depend on (machine, candidate),
  -- NOT the slot, so a per-pair scalar call would be O(slots x universe) and needlessly re-scan sales /
  -- re-run the affinity function. Precompute each once.

  -- sister velocity per (location_type, pod): one pass over sales history for the relevant loc_types.
  CREATE TEMP TABLE _p3_sister ON COMMIT DROP AS
  SELECT m2.location_type AS loc_type, sh.pod_product_id AS pod, SUM(sh.qty)/30.0 AS vel
    FROM public.v_sales_history_resolved sh
    JOIN public.machines m2 ON m2.machine_id = sh.machine_id
   WHERE m2.location_type IN (SELECT DISTINCT loc_type FROM _p3_slot_keep)
     AND sh.transaction_date >= p_plan_date - 30
   GROUP BY 1,2;

  -- machine basket (velocity>0 on-machine pods) used for affinity.
  CREATE TEMP TABLE _p3_basket ON COMMIT DROP AS
  SELECT DISTINCT k.machine_id, sl.pod_product_id
    FROM (SELECT DISTINCT machine_id FROM _p3_slot_keep) k
    JOIN public.slot_lifecycle sl ON sl.machine_id = k.machine_id AND sl.archived=false AND sl.is_current=true
     AND (COALESCE(sl.velocity_7d,0)>0 OR COALESCE(sl.velocity_30d,0)>0);

  -- affinity per (machine, cand_pod): per-machine correlation, loc-type fallback, averaged over the basket.
  -- Set-based mirror of public.get_candidate_affinity (identical math); the scalar helper is retained for
  -- ad-hoc / external callers (PRD-039 follow-up registers it as the canonical affinity object).
  CREATE TEMP TABLE _p3_affinity ON COMMIT DROP AS
  WITH am AS (
    SELECT b.machine_id, cm.pod_product_b AS cand_pod, AVG(cm.pearson) AS score
      FROM _p3_basket b
      JOIN public.correlation_pod_per_machine cm ON cm.machine_id=b.machine_id AND cm.pod_product_a=b.pod_product_id
     GROUP BY 1,2),
  al AS (
    SELECT mk.machine_id, cl.pod_product_b AS cand_pod, AVG(cl.pearson) AS score
      FROM (SELECT DISTINCT machine_id, loc_type FROM _p3_slot_keep) mk
      JOIN _p3_basket b ON b.machine_id=mk.machine_id
      JOIN public.correlation_pod_per_loc_type cl ON cl.location_type=mk.loc_type AND cl.pod_product_a=b.pod_product_id
     GROUP BY 1,2)
  SELECT COALESCE(am.machine_id, al.machine_id) AS machine_id,
         COALESCE(am.cand_pod, al.cand_pod)     AS cand_pod,
         COALESCE(am.score, al.score, 0)        AS score
    FROM am FULL JOIN al ON al.machine_id=am.machine_id AND al.cand_pod=am.cand_pod;

  -- WS-A broad candidate universe per machine (pickable boonz above seed min, mapped to pod, all hard gates).
  CREATE TEMP TABLE _p3_cand ON COMMIT DROP AS
  WITH wh AS (
    SELECT vp.boonz_product_id AS boonz, SUM(vp.warehouse_stock) AS wh_stock
      FROM public.v_wh_pickable vp GROUP BY 1 HAVING SUM(vp.warehouse_stock) > v_cand_min_stock
  ),
  base AS (
    SELECT w.boonz, w.wh_stock, pm.pod_product_id AS cand_pod, bp.physical_type AS cand_phys,
           GREATEST(COALESCE((SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.pod_product_id=pm.pod_product_id AND pg.is_active=true),0)
                    - COALESCE(bp.avg_30days_cost,0), 0) AS cand_margin,
           COALESCE(fv.avg_v30,0) AS global_vel
      FROM wh w
      JOIN public.boonz_products bp ON bp.product_id = w.boonz
      JOIN LATERAL (SELECT pm.pod_product_id FROM public.product_mapping pm
                     WHERE pm.boonz_product_id = w.boonz AND pm.status='Active'
                     ORDER BY pm.is_global_default DESC, pm.updated_at DESC LIMIT 1) pm ON true
      JOIN public.pod_products pp ON pp.pod_product_id=pm.pod_product_id AND COALESCE(pp.is_catchall,false)=false
      LEFT JOIN _fleet_velocity fv ON fv.pod_product_id = pm.pod_product_id
  )
  SELECT mk.machine_id, mk.loc_type, b.boonz AS cand_boonz, b.cand_pod, b.cand_phys, b.wh_stock,
         b.cand_margin, b.global_vel,
         COALESCE(si.vel,0) AS sister_vel,
         GREATEST(COALESCE(af.score,0),0) AS affinity
    FROM (SELECT DISTINCT machine_id, loc_type FROM _p3_slot_keep) mk
    JOIN base b ON true
    LEFT JOIN _p3_sister si ON si.loc_type = mk.loc_type AND si.pod = b.cand_pod
    LEFT JOIN _p3_affinity af ON af.machine_id = mk.machine_id AND af.cand_pod = b.cand_pod
   WHERE NOT EXISTS (SELECT 1 FROM _machine_present_pods mpp WHERE mpp.machine_id=mk.machine_id AND mpp.pod_product_id=b.cand_pod)
     AND NOT EXISTS (SELECT 1 FROM _suppressed_swap_subs sss WHERE sss.machine_id=mk.machine_id AND sss.pod_in=b.cand_pod)
     AND NOT EXISTS (SELECT 1 FROM _r5_introduction_cooldown ic WHERE ic.machine_id=mk.machine_id AND ic.pod_product_id=b.cand_pod)
     AND EXISTS (SELECT 1 FROM public.v_wh_pickable vp2 WHERE vp2.boonz_product_id=b.boonz
                  AND (vp2.reserved_for_machine_id IS NULL OR vp2.reserved_for_machine_id=mk.machine_id))
     AND NOT public._coexistence_blocks(mk.machine_id, b.boonz)
     AND NOT public._travel_scope_blocks(mk.machine_id, b.boonz);

  -- WS-B candidate-specific cap + V; top-N per slot (each machine's slots join its own candidate set).
  CREATE TEMP TABLE _p3_pairs ON COMMIT DROP AS
  WITH capd AS (
    SELECT k.machine_id, k.shelf_id, k.pod_product_id AS inc_pod, k.shelf_size, k.keep_v,
           cc.cand_boonz, cc.cand_pod, cc.cand_phys, cc.wh_stock, cc.cand_margin, cc.global_vel, cc.sister_vel, cc.affinity,
           GREATEST(COALESCE(
             (SELECT scm.override_max_stock FROM public.slot_capacity_max scm
               WHERE scm.machine_id=k.machine_id AND scm.aisle_code=k.shelf_code LIMIT 1),
             FLOOR(public.product_slot_capacity_units(cc.cand_phys, k.shelf_size)*0.85)::int,
             (SELECT sc.max_capacity FROM public.shelf_configurations sc WHERE sc.shelf_id=k.shelf_id LIMIT 1),
             8),1) AS cand_cap
      FROM _p3_slot_keep k
      JOIN _p3_cand cc ON cc.machine_id = k.machine_id
  ),
  valued AS (
    SELECT c.*,
           c.cand_margin * LEAST(GREATEST(v_w_sister*c.sister_vel + v_w_global*c.global_vel + v_w_pearson*c.affinity*c.global_vel,0)*p_days_cover, c.cand_cap) AS v_cand
      FROM capd c
  ),
  topn AS (
    SELECT v.*, ROW_NUMBER() OVER (PARTITION BY v.machine_id, v.shelf_id ORDER BY v.v_cand DESC) AS rn
      FROM valued v
     WHERE v.v_cand > 0 AND v.v_cand >= v.keep_v * (1 + v_theta)
  )
  SELECT machine_id, shelf_id, inc_pod, cand_boonz, cand_pod, cand_cap, wh_stock, v_cand, keep_v, shelf_size
    FROM topn WHERE rn <= v_top_n;

  -- WS-C greedy unique assignment: highest V(slot,cand) first; each slot once, each product once/machine;
  -- honour per-machine cap, fleet cap, WS-D homogenisation cap K.
  FOR r IN
    SELECT * FROM _p3_pairs ORDER BY machine_id, v_cand DESC, shelf_id
  LOOP
    CONTINUE WHEN v_fleet_swaps >= v_fleet_cap;
    -- slot already assigned this cycle?
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.pod_swaps ps2
      WHERE ps2.plan_date=p_plan_date AND ps2.machine_id=r.machine_id AND ps2.shelf_id=r.shelf_id);
    -- product already used on this machine this cycle (any swap-in)?
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.pod_swaps ps2
      WHERE ps2.plan_date=p_plan_date AND ps2.machine_id=r.machine_id AND ps2.pod_product_id_in=r.cand_pod);
    -- per-machine swap cap
    SELECT COUNT(*) INTO v_machine_swap_n FROM public.pod_swaps psx
     WHERE psx.plan_date=p_plan_date AND psx.machine_id=r.machine_id AND psx.pod_product_id_in IS NOT NULL;
    CONTINUE WHEN v_machine_swap_n >= p_max_swaps_per_machine;
    -- WS-D homogenisation: this product newly introduced into < K machines this cycle
    CONTINUE WHEN COALESCE((SELECT n FROM _p3_intro WHERE boonz = r.cand_boonz),0) >= v_K;

    INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
      qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
    VALUES (
      p_plan_date, r.machine_id, r.shelf_id, r.inc_pod, r.cand_pod,
      GREATEST(COALESCE((SELECT MAX(sls.current_stock) FROM _shelf_live_stock sls
                          WHERE sls.machine_id=r.machine_id AND sls.shelf_id=r.shelf_id),1),1)::int,
      LEAST(GREATEST(r.cand_cap,1), COALESCE(r.wh_stock,0)::int),
      'rotate_out', 'value_model_broad', NULL::numeric, NULL::uuid,
      jsonb_build_object(
        'pass','3','source','value_model_swap_broad','resolved_by','engine_swap_pod_v13',
        'v_keep', round(r.keep_v,2), 'v_candidate', round(r.v_cand,2),
        'theta', v_theta, 'days_cover', p_days_cover, 'cap', r.cand_cap,
        'shelf_size', r.shelf_size,
        'projection_basis','w_sister0.5_global0.3_pearson0.2',
        'universe','v_wh_pickable_broad', 'homogenisation_k', v_K,
        'displaced_pod_product_id', r.inc_pod, 'return_to_warehouse', true,
        'engine_version','v13_value_model_broad')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING;

    -- maintain WS-D counter + tallies
    INSERT INTO _p3_intro(boonz, n) VALUES (r.cand_boonz, 1)
      ON CONFLICT (boonz) DO UPDATE SET n = _p3_intro.n + 1;
    v_score_swaps := v_score_swaps + 1;
    v_fleet_swaps := v_fleet_swaps + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'plan_date',p_plan_date, 'max_swaps_per_machine',p_max_swaps_per_machine,
    'min_pearson',p_min_pearson, 'days_cover',p_days_cover,
    'tag_swaps', v_tag_swaps, 'tag_m2w', v_tag_m2w,
    'dead_tags_resolved', v_dead_resolved, 'dead_tags_m2w', v_dead_m2w,
    'dead_tags_deferred_by_cap', v_dead_deferred,
    'dead_tags_below_pearson_fallback', v_dead_fallback,
    'driver_rec_swaps', v_driver_rec_swaps,
    'score_driven_swaps', v_score_swaps,
    'theta', v_theta, 'fleet_cap', v_fleet_cap, 'homogenisation_k', v_K,
    'total_swaps', v_tag_swaps + v_dead_resolved + v_driver_rec_swaps + v_score_swaps,
    'total_m2w', v_tag_m2w + v_dead_m2w,
    'engine_version','v13_value_model_broad',
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int);
END;
$function$;
