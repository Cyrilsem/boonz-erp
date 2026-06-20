-- PRD-035 Phase E (WS-B) - score-driven SWAP: optimize each low-rank slot for returns.
--
-- CS decisions (2026-06-18):
--   B1 = DROP + FLAG: the displaced incumbent returns to WH and is stamped relocation_candidate=true
--        (relocation to a better machine is a later cross-machine optimization, not done here).
--   B2 = swap only when candidate projected score beats incumbent by >= 25 AND candidate >= 50.
--
-- WHAT CHANGES (engine_swap_pod v10_2 -> v11): purely ADDITIVE. The three existing passes
--   (1 strategic tags, 2 dead/rotate resolution, 2b driver recommendations) are reproduced VERBATIM.
--   A new Pass 3 runs last, before RETURN:
--     - Rank every shelf of each picked machine by compute_refill_decision.final_score WITHIN the machine
--       (same rank signal as PRD-035 WS-A) and target the BOTTOM third (low-rank slots).
--     - For each low-rank shelf, take the top in-stock candidate from find_substitutes_for_shelf, filtered
--       by the SAME guards Pass 2 uses (already-present / suppressed / introduction-cooldown).
--     - Project BOTH incumbent and candidate onto a comparable 0-100 fit scale via the canonical
--       score_machine_for_product (Engine-2). NOTE: compute_refill_decision.final_score cannot be computed
--       for a product that is not on the shelf (it reads slot_lifecycle velocity for that machine/shelf),
--       so score_machine_for_product is the faithful "projected return in this slot" tool for the candidate;
--       the incumbent is scored the same way so the gap is apples-to-apples.
--     - If candidate is not hard-blocked here AND candidate_fit >= 50 AND (candidate_fit - incumbent_fit) >= 25,
--       insert a SWAP (REMOVE incumbent + ADD candidate), incumbent -> WH, flagged relocation_candidate.
--   This REPLACES the stance-based swap trigger with a score/returns-based one (the legacy dead-tag handoff
--   for engine_add_pod v15/v16 is left untouched; v17+/v18 dead tags were already not consumed by Pass 2).
--
-- Respects every existing guard: per-machine cap (p_max_swaps_per_machine across all passes), swaps disabled,
-- committed machines, removal/introduction cooldowns, suppressed (3x-rejected) subs. Idempotent: the opening
-- DELETE wipes prior score swaps; ON CONFLICT DO NOTHING within a run. Signature UNCHANGED (B2 thresholds are
-- local constants to avoid a PostgreSQL overload of engine_swap_pod). SECURITY DEFINER guards preserved.
-- Writes only the non-protected staging table pod_swaps. Forward-only CREATE OR REPLACE.

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
  -- PRD-035 WS-B Pass 3 (score-driven swap)
  v_score_swaps        integer := 0;
  v_min_gap            numeric := 25;   -- CS B2: min candidate-minus-incumbent fit gap
  v_min_cand           numeric := 50;   -- CS B2: min absolute candidate fit
  v_incumbent_boonz    uuid;
  v_cand_boonz         uuid;
  v_cand_eval          jsonb;
  v_cand_score         numeric;
  v_cand_block         text;
  v_incumbent_score    numeric;
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

  -- PRD-019 D1b/F1: lock guard only (NULL scope). Committed machines skipped below.
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
                       'engine_version','v10_narrow_trigger')
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
               'resolved_by','engine_swap_pod_v10_2',
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
                                   'resolved_by','engine_swap_pod_v10_2',
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
                           'resolved_by','engine_swap_pod_v10_2',
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
                         'rec_id', r.rec_id, 'resolved_by','engine_swap_pod_v10_2',
                         'return_to_warehouse', true, 'engine_version','v10_narrow_trigger')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO UPDATE
      SET pod_product_id_in = EXCLUDED.pod_product_id_in,
          qty_in            = EXCLUDED.qty_in,
          reason            = 'rotate_out',
          substitute_source = 'driver_recommendation',
          reasoning         = public.pod_swaps.reasoning || EXCLUDED.reasoning;
    v_driver_rec_swaps := v_driver_rec_swaps + 1;
  END LOOP;

  -- ===================== PRD-035 WS-B Pass 3: score-driven swap =====================
  -- Low-rank slots (bottom third by final_score within the machine) where a candidate's projected fit
  -- materially beats the incumbent (B2: gap >= v_min_gap AND candidate >= v_min_cand) are swapped.
  FOR r IN
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
     WHERE band = 3 AND shelf_n >= 3   -- only differentiate rank on machines with >= 3 shelves
     ORDER BY machine_id, incumbent_final_score ASC, shelf_id
  LOOP
    -- per-machine swap cap across ALL passes
    SELECT COUNT(*) INTO v_machine_swap_n
      FROM public.pod_swaps psx
     WHERE psx.plan_date = p_plan_date AND psx.machine_id = r.machine_id
       AND psx.pod_product_id_in IS NOT NULL;
    CONTINUE WHEN v_machine_swap_n >= p_max_swaps_per_machine;

    -- skip shelves already touched by a swap this run (strategic / dead / driver)
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.pod_swaps ps2
       WHERE ps2.plan_date = p_plan_date AND ps2.machine_id = r.machine_id AND ps2.shelf_id = r.shelf_id);

    -- top in-stock candidate, same guards as Pass 2 (present / suppressed / introduction-cooldown)
    SELECT fs.pod_product_id, fs.pod_product_name, fs.pearson_score, fs.source, fs.wh_stock_units
      INTO v_sub
      FROM public.find_substitutes_for_shelf(p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id, 5, 50) fs
      LEFT JOIN _machine_present_pods mpp ON mpp.machine_id = r.machine_id AND mpp.pod_product_id = fs.pod_product_id
      LEFT JOIN _suppressed_swap_subs sss ON sss.machine_id = r.machine_id AND sss.pod_in = fs.pod_product_id
      LEFT JOIN _r5_introduction_cooldown rc ON rc.machine_id = r.machine_id AND rc.pod_product_id = fs.pod_product_id
     WHERE mpp.pod_product_id IS NULL AND sss.pod_in IS NULL AND rc.pod_product_id IS NULL
       AND COALESCE(fs.wh_stock_units,0) > 0
     ORDER BY fs.rank
     LIMIT 1;

    CONTINUE WHEN v_sub.pod_product_id IS NULL;

    -- map incumbent + candidate pod -> primary boonz (machine-specific else global default)
    SELECT pm.boonz_product_id INTO v_incumbent_boonz
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = r.pod_product_id AND pm.status = 'Active'
       AND (pm.machine_id = r.machine_id OR pm.machine_id IS NULL)
     ORDER BY (pm.machine_id = r.machine_id) DESC NULLS LAST, pm.is_global_default DESC, pm.split_pct DESC NULLS LAST
     LIMIT 1;
    SELECT pm.boonz_product_id INTO v_cand_boonz
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_sub.pod_product_id AND pm.status = 'Active'
       AND (pm.machine_id = r.machine_id OR pm.machine_id IS NULL)
     ORDER BY (pm.machine_id = r.machine_id) DESC NULLS LAST, pm.is_global_default DESC, pm.split_pct DESC NULLS LAST
     LIMIT 1;
    CONTINUE WHEN v_cand_boonz IS NULL;

    SELECT GREATEST(COALESCE(MAX(sms.max_stock_weimi)::int, 8), 1) INTO v_shelf_cap
      FROM public.v_shelf_max_stock sms WHERE sms.shelf_id = r.shelf_id;

    -- project candidate + incumbent onto the canonical 0-100 fit scale (score_machine_for_product)
    v_cand_eval  := public.score_machine_for_product(r.machine_id, v_cand_boonz, p_days_cover, v_shelf_cap);
    v_cand_score := COALESCE((v_cand_eval->>'score')::numeric, 0);
    v_cand_block := v_cand_eval->>'hard_block';
    v_incumbent_score := CASE
      WHEN v_incumbent_boonz IS NULL THEN 0
      ELSE COALESCE((public.score_machine_for_product(r.machine_id, v_incumbent_boonz, p_days_cover, v_shelf_cap)->>'score')::numeric, 0)
    END;

    CONTINUE WHEN v_cand_block IS NOT NULL;                          -- candidate hard-blocked here
    CONTINUE WHEN v_cand_score < v_min_cand;                         -- B2 absolute floor
    CONTINUE WHEN (v_cand_score - v_incumbent_score) < v_min_gap;    -- B2 gap

    INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
      qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
    VALUES (
      p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id, v_sub.pod_product_id,
      GREATEST(COALESCE((SELECT MAX(sls.current_stock) FROM _shelf_live_stock sls
                          WHERE sls.machine_id = r.machine_id AND sls.shelf_id = r.shelf_id), 1), 1)::int,
      LEAST(GREATEST(v_shelf_cap, 1), COALESCE(v_sub.wh_stock_units, 0)::int),
      'score_swap', COALESCE(v_sub.source, 'score_driven'), v_sub.pearson_score, NULL::uuid,
      jsonb_build_object(
        'pass','3', 'source','score_driven_swap', 'resolved_by','engine_swap_pod_v11',
        'incumbent_pod', r.pod_product_name,
        'incumbent_final_score', r.incumbent_final_score,
        'incumbent_fit_score', v_incumbent_score,
        'candidate_fit_score', v_cand_score,
        'fit_gap', (v_cand_score - v_incumbent_score),
        'min_gap', v_min_gap, 'min_candidate', v_min_cand,
        'projection_basis', 'score_machine_for_product_0_100',
        'relocation_candidate', true,                    -- B1: displaced incumbent flagged for relocation review
        'displaced_pod_product_id', r.pod_product_id,
        'return_to_warehouse', true,
        'engine_version', 'v11_score_driven_swap')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING;
    v_score_swaps := v_score_swaps + 1;
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
    'score_swap_min_gap', v_min_gap, 'score_swap_min_candidate', v_min_cand,
    'total_swaps', v_tag_swaps + v_dead_resolved + v_driver_rec_swaps + v_score_swaps,
    'total_m2w', v_tag_m2w + v_dead_m2w,
    'engine_version','v11_score_driven_swap_f1_per_machine',
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int);
END;
$function$;
