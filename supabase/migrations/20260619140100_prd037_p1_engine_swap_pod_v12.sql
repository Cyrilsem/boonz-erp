-- PRD-037 Phase 1: engine_swap_pod v11 -> v12 (score-driven Pass-3 rewrite).
-- NOT APPLIED. Author-only; apply after CS sign-off + Cody verdict on this body.
-- Forward-only CREATE OR REPLACE. engine_add_pod is UNTOUCHED (T12 holds trivially).
-- swaps_enabled is NOT flipped here (stays false in refill_settings).
--
-- Built byte-for-byte on the live v11 body (pg_get_functiondef 2026-06-19); the ONLY
-- change is Pass-3 (the autonomous score-driven swap), rewritten to the PRD §0 value
-- model. Passes 1 (strategic tags), dead-tag resolution, and 2b (driver recs) are
-- preserved verbatim. DOUBLE-DOWN and Redeploy(I) are Phase 2 (this phase does
-- KEEP-vs-SWAP only). Kill switch (T7) is inherited from v11: _swaps_disabled_machines
-- empties the picked set when swaps_enabled='false'.
--
-- WS-1 eligibility (before scoring): candidate must come from find_substitutes_for_shelf
--   (in v_wh_pickable, not already on machine, intro-cooldown clean) AND be
--   coexistence-clean vs every on-machine product via public._coexistence_blocks() AND
--   not travel-scope-locked away from M.
-- WS-2 projected velocity for a candidate (no local history):
--   w2*sister_velocity(same location_type) + w1*global_velocity + w3*pearson_bonus,
--   w2=0.5 > w1=0.3 > w3=0.2 (pearson scaled by global velocity to stay in units/day).
-- WS-3 V(P,S,M) = margin(P) * min(velocity(P,M)*D, cap(S)), cap = floor(max_stock_weimi*0.85).
--   SWAP only if V(P*) >= V(I) * (1 + theta) with theta = 0.15 and V(P*) > 0. Then rate
--   limits: <= p_max_swaps_per_machine/machine, fleet <= 10/cycle, 14-day slot cooldown.
-- Inert gates noted: product_family_id is NULL fleet-wide (Rule 2 runs via product_brand
--   in coexistence_rules); lifecycle_archetype has no phase-out value yet (WS-1.6 inert).

-- CHANGELOG 2026-06-20 (still author-only, not applied): added Pass-3 intra-cycle
-- swap-in dedup (NOT EXISTS pod_swaps.pod_product_id_in = candidate) so one product
-- cannot be proposed into two slots on the same machine in a single cycle. Found during
-- the T13 faithful replay on ADDMIND-1007 (A08 and A15 both argmax Be-kind Bar). The
-- dead-tag pass already had this guard; Pass-3 was missing it.
--
-- Helper: does candidate boonz product C conflict with machine M under coexistence_rules?
-- Returns true if any hard rule is violated vs a product currently on M, or a TCCC
-- venue-exclusion applies. SECURITY DEFINER read-only; no writes.
CREATE OR REPLACE FUNCTION public._coexistence_blocks(p_machine_id uuid, p_cand_boonz uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
  WITH cand AS (
    SELECT bp.product_id AS boonz_id, bp.product_brand AS brand, bp.brand_owner AS owner, bp.boonz_product_name AS nm
    FROM public.boonz_products bp WHERE bp.product_id = p_cand_boonz
  ),
  mv AS (SELECT m.venue_group FROM public.machines m WHERE m.machine_id = p_machine_id),
  onm AS (  -- products currently on the machine (live + lifecycle), resolved to brand/owner/name
    SELECT DISTINCT bp.product_brand AS brand, bp.brand_owner AS owner, bp.boonz_product_name AS nm
    FROM (
      SELECT pm.boonz_product_id FROM public.slot_lifecycle sl
        JOIN public.product_mapping pm ON pm.pod_product_id = sl.pod_product_id AND pm.status='Active'
       WHERE sl.machine_id = p_machine_id AND sl.archived=false AND sl.is_current=true
      UNION
      SELECT pm.boonz_product_id FROM public.v_live_shelf_stock vls
        JOIN public.product_mapping pm ON pm.pod_product_id = vls.pod_product_id AND pm.status='Active'
       WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
    ) b JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
  )
  SELECT
    -- Rule 1: TCCC venue exclusion
    EXISTS (
      SELECT 1 FROM cand c, mv
      JOIN public.coexistence_rules cr ON cr.rule_group='rule1_tccc_venue_exclusion'
      WHERE c.owner = cr.a_match_value AND mv.venue_group = ANY (cr.venue_groups)
    )
    OR
    -- Groups 1-7: candidate vs an on-machine product matches a hard machine-scope rule (either direction)
    EXISTS (
      SELECT 1 FROM cand c
      JOIN public.coexistence_rules cr ON cr.scope='machine' AND cr.rule_type='hard'
      JOIN onm o ON
        ( (cr.a_match_type='product_brand' AND c.brand = cr.a_match_value) OR
          (cr.a_match_type='brand_owner'  AND c.owner = cr.a_match_value) OR
          (cr.a_match_type='name'         AND c.nm    = cr.a_match_value) OR
          (cr.a_match_type='product_id'   AND c.boonz_id::text = cr.a_match_value) )
        AND
        ( (cr.b_match_type='product_brand' AND o.brand = cr.b_match_value) OR
          (cr.b_match_type='brand_owner'  AND o.owner = cr.b_match_value) OR
          (cr.b_match_type='name'         AND o.nm    = cr.b_match_value) OR
          (cr.b_match_type='product_id'   AND o.brand = cr.b_match_value) )
    )
    OR
    EXISTS (  -- reverse direction (rules are bidirectional)
      SELECT 1 FROM cand c
      JOIN public.coexistence_rules cr ON cr.scope='machine' AND cr.rule_type='hard'
      JOIN onm o ON
        ( (cr.b_match_type='product_brand' AND c.brand = cr.b_match_value) OR
          (cr.b_match_type='brand_owner'  AND c.owner = cr.b_match_value) OR
          (cr.b_match_type='name'         AND c.nm    = cr.b_match_value) )
        AND
        ( (cr.a_match_type='product_brand' AND o.brand = cr.a_match_value) OR
          (cr.a_match_type='brand_owner'  AND o.owner = cr.a_match_value) OR
          (cr.a_match_type='name'         AND o.nm    = cr.a_match_value) )
    );
$fn$;

-- Helper: is boonz product C travel-scope-locked away from machine M? (VOX 8-SKU list
-- + "VOX " name prefix may only live in venue_group='VOX'.)
CREATE OR REPLACE FUNCTION public._travel_scope_blocks(p_machine_id uuid, p_cand_boonz uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM public.boonz_products bp, public.machines m
    WHERE bp.product_id = p_cand_boonz AND m.machine_id = p_machine_id
      AND m.venue_group <> 'VOX'
      AND ( bp.boonz_product_name ILIKE 'VOX %'
            OR bp.boonz_product_name IN (
              'Aquafina','Maltesers Chocolate Bag','Skittles Bag','VOX Cotton Candy',
              'VOX Lollies','VOX Popcorn Caramel','VOX Popcorn Cheese','VOX Popcorn Salt')
            OR bp.product_brand IN ('Aquafina') )
  );
$fn$;

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
  -- PRD-037 v12 Pass-3 (value model) locals
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
                       'engine_version','v12_value_model')
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
               'resolved_by','engine_swap_pod_v12',
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
                                   'resolved_by','engine_swap_pod_v12',
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
                           'resolved_by','engine_swap_pod_v12',
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
                         'rec_id', r.rec_id, 'resolved_by','engine_swap_pod_v12',
                         'return_to_warehouse', true, 'engine_version','v12_value_model')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO UPDATE
      SET pod_product_id_in = EXCLUDED.pod_product_id_in,
          qty_in            = EXCLUDED.qty_in,
          reason            = 'rotate_out',
          substitute_source = 'driver_recommendation',
          reasoning         = public.pod_swaps.reasoning || EXCLUDED.reasoning;
    v_driver_rec_swaps := v_driver_rec_swaps + 1;
  END LOOP;

  -- ── Pass 3 (PRD-037 v12): value-model KEEP-vs-SWAP ──────────────────────
  -- WS-3 V(P,S,M) = margin(P) * min(velocity(P,M)*D, cap(S)). Swap only when the best
  -- eligible candidate (WS-1 coexistence/travel-clean, WS-2 projected velocity) beats
  -- KEEP by theta. Rate-limited per machine and fleet-wide. DOUBLE-DOWN/Redeploy = Phase 2.
  SELECT COUNT(*) INTO v_fleet_swaps FROM public.pod_swaps
   WHERE plan_date = p_plan_date AND reason = 'score_swap' AND pod_product_id_in IS NOT NULL;

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
     WHERE band = 3 AND shelf_n >= 3
     ORDER BY machine_id, incumbent_final_score ASC, shelf_id
  LOOP
    CONTINUE WHEN v_fleet_swaps >= v_fleet_cap;                          -- T11 fleet cap
    SELECT COUNT(*) INTO v_machine_swap_n FROM public.pod_swaps psx
     WHERE psx.plan_date = p_plan_date AND psx.machine_id = r.machine_id AND psx.pod_product_id_in IS NOT NULL;
    CONTINUE WHEN v_machine_swap_n >= p_max_swaps_per_machine;           -- T11 per-machine cap
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.pod_swaps ps2
       WHERE ps2.plan_date = p_plan_date AND ps2.machine_id = r.machine_id AND ps2.shelf_id = r.shelf_id);
    CONTINUE WHEN EXISTS (SELECT 1 FROM _r5_removal_cooldown rc           -- T10 14-day cooldown
       WHERE rc.machine_id = r.machine_id AND rc.pod_product_id = r.pod_product_id);

    SELECT GREATEST(FLOOR(COALESCE(MAX(sms.max_stock_weimi),8) * 0.85)::int, 1) INTO v_cap
      FROM public.v_shelf_max_stock sms WHERE sms.shelf_id = r.shelf_id;
    SELECT location_type INTO v_loc_type FROM public.machines WHERE machine_id = r.machine_id;

    -- incumbent value V(I)
    SELECT pm.boonz_product_id INTO v_incumbent_boonz FROM public.product_mapping pm
     WHERE pm.pod_product_id = r.pod_product_id AND pm.status='Active' AND (pm.machine_id = r.machine_id OR pm.machine_id IS NULL)
     ORDER BY (pm.machine_id = r.machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;
    SELECT COALESCE(sl.velocity_30d,0) INTO v_inc_vel FROM public.slot_lifecycle sl
     WHERE sl.machine_id=r.machine_id AND sl.shelf_id=r.shelf_id AND sl.pod_product_id=r.pod_product_id
       AND sl.archived=false AND sl.is_current=true LIMIT 1;
    SELECT COALESCE((SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.machine_id=r.machine_id AND pg.pod_product_id=r.pod_product_id AND pg.is_active=true),
                    (SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.pod_product_id=r.pod_product_id AND pg.is_active=true), 0)
         - COALESCE((SELECT bp.avg_30days_cost FROM public.boonz_products bp WHERE bp.product_id=v_incumbent_boonz),0)
      INTO v_inc_margin;
    v_v_keep := GREATEST(v_inc_margin,0) * LEAST(GREATEST(COALESCE(v_inc_vel,0),0) * p_days_cover, v_cap);

    v_best_v := NULL; v_best_pod := NULL; v_best_src := NULL; v_best_pearson := NULL; v_best_wh := NULL;
    FOR v_sub IN
      SELECT fs.pod_product_id, fs.pod_product_name, fs.pearson_score, fs.source, fs.wh_stock_units
        FROM public.find_substitutes_for_shelf(p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id, 10, 50) fs
        LEFT JOIN _machine_present_pods mpp ON mpp.machine_id = r.machine_id AND mpp.pod_product_id = fs.pod_product_id
        LEFT JOIN _suppressed_swap_subs sss ON sss.machine_id = r.machine_id AND sss.pod_in = fs.pod_product_id
        LEFT JOIN _r5_introduction_cooldown rc ON rc.machine_id = r.machine_id AND rc.pod_product_id = fs.pod_product_id
       WHERE mpp.pod_product_id IS NULL AND sss.pod_in IS NULL AND rc.pod_product_id IS NULL
         AND COALESCE(fs.wh_stock_units,0) > 0
         -- PRD-037 fix (2026-06-20): no duplicate swap-in across slots in one cycle.
         -- Mirrors the dead-tag pass guard; without it two slots on the same machine
         -- can both argmax the same product (e.g. ADDMIND-1007 A08 and A15 both -> Be-kind Bar).
         AND NOT EXISTS (
           SELECT 1 FROM public.pod_swaps ps2
            WHERE ps2.plan_date = p_plan_date AND ps2.machine_id = r.machine_id
              AND ps2.pod_product_id_in = fs.pod_product_id)
    LOOP
      SELECT pm.boonz_product_id INTO v_cand_boonz FROM public.product_mapping pm
       WHERE pm.pod_product_id = v_sub.pod_product_id AND pm.status='Active' AND (pm.machine_id = r.machine_id OR pm.machine_id IS NULL)
       ORDER BY (pm.machine_id = r.machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;
      CONTINUE WHEN v_cand_boonz IS NULL;
      CONTINUE WHEN public._coexistence_blocks(r.machine_id, v_cand_boonz);   -- WS-1 T1/T2/T3/T4
      CONTINUE WHEN public._travel_scope_blocks(r.machine_id, v_cand_boonz);  -- WS-1 travel scope

      -- WS-2 projected velocity (sister dominates), proxied onto units/day
      SELECT COALESCE(SUM(sh.qty),0) / 30.0 INTO v_sister_vel
        FROM public.v_sales_history_resolved sh
        JOIN public.machines mm ON mm.machine_id = sh.machine_id
       WHERE sh.pod_product_id = v_sub.pod_product_id AND mm.location_type = v_loc_type
         AND mm.machine_id <> r.machine_id AND sh.transaction_date >= p_plan_date - 30;
      SELECT COALESCE(avg_v30,0) INTO v_global_vel FROM _fleet_velocity WHERE pod_product_id = v_sub.pod_product_id;
      v_proj_vel := v_w_sister*COALESCE(v_sister_vel,0) + v_w_global*COALESCE(v_global_vel,0)
                  + v_w_pearson*GREATEST(COALESCE(v_sub.pearson_score,0),0)*COALESCE(v_global_vel,0);

      SELECT COALESCE((SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.pod_product_id = v_sub.pod_product_id AND pg.is_active=true),0)
           - COALESCE((SELECT bp.avg_30days_cost FROM public.boonz_products bp WHERE bp.product_id = v_cand_boonz),0)
        INTO v_cand_margin;
      v_v_cand := GREATEST(v_cand_margin,0) * LEAST(GREATEST(v_proj_vel,0) * p_days_cover, v_cap);

      IF v_best_v IS NULL OR v_v_cand > v_best_v THEN
        v_best_v := v_v_cand; v_best_pod := v_sub.pod_product_id; v_best_src := v_sub.source;
        v_best_pearson := v_sub.pearson_score; v_best_wh := v_sub.wh_stock_units;
      END IF;
    END LOOP;

    CONTINUE WHEN v_best_pod IS NULL;                                    -- T6 no-substitute: KEEP
    CONTINUE WHEN NOT (v_best_v > 0 AND v_best_v >= v_v_keep * (1 + v_theta));  -- T5 theta gate -> KEEP

    INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
      qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
    VALUES (
      p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id, v_best_pod,
      GREATEST(COALESCE((SELECT MAX(sls.current_stock) FROM _shelf_live_stock sls
                          WHERE sls.machine_id = r.machine_id AND sls.shelf_id = r.shelf_id), 1), 1)::int,
      LEAST(GREATEST(v_cap, 1), COALESCE(v_best_wh, 0)::int),
      'score_swap', COALESCE(v_best_src, 'value_model'), v_best_pearson, NULL::uuid,
      jsonb_build_object(
        'pass','3', 'source','value_model_swap', 'resolved_by','engine_swap_pod_v12',
        'incumbent_pod', r.pod_product_name, 'incumbent_final_score', r.incumbent_final_score,
        'v_keep', round(v_v_keep,2), 'v_candidate', round(v_best_v,2),
        'theta', v_theta, 'days_cover', p_days_cover, 'cap', v_cap,
        'projection_basis', 'w_sister0.5_global0.3_pearson0.2',
        'displaced_pod_product_id', r.pod_product_id, 'return_to_warehouse', true,
        'engine_version', 'v12_value_model')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING;
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
    'theta', v_theta, 'fleet_cap', v_fleet_cap,
    'total_swaps', v_tag_swaps + v_dead_resolved + v_driver_rec_swaps + v_score_swaps,
    'total_m2w', v_tag_m2w + v_dead_m2w,
    'engine_version','v12_value_model',
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int);
END;
$function$;
