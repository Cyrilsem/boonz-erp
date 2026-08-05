-- PRD-110 P3.3 / D-26 — propose_rotations_v3 honours the CS keep-floor. GREEN for fixture 43
-- seq 54 (the D-26 contract), and re-greens seqs 20/21/22/24 which the fixture reddened first.
--
-- ⛔ Cody revision 1 (RISK 101): signature pinned to (date, integer, boolean) with
--    pronargdefaults = 2. Changing it would ORPHAN fixture 43's 1-, 2- and 3-arg call sites.
-- ⛔ Cody revision 2: GREATEST(..., 0) before LEAST. Without it a shelf below the floor yields a
--    negative qty and hence a negative projected_days_to_sell, which passes the LAW-7 expiry
--    guard (expiry - CURRENT_DATE) >= pdays VACUOUSLY. The rule would stop binding, not error.
-- ⛔ Cody revision 3: scoring_breakdown.params carries keep_floor, so a stored proposal records
--    the policy it was scored under -- fit and pdays are materialized query results whose only
--    provenance is what the row itself carries.
--
-- LAW 3: versioned, additive, no destructive change. Writes rotation_proposals_v3 ONLY.

CREATE OR REPLACE FUNCTION public.propose_rotations_v3(p_plan_date date, p_limit integer DEFAULT NULL::integer, p_dry_run boolean DEFAULT false)
 RETURNS TABLE(proposal_id uuid, plan_date date, source_machine_id uuid, source_shelf_id uuid, source_pod_product_id uuid, source_qty_on_shelf integer, source_velocity numeric, source_days_to_sell numeric, target_machine_id uuid, target_shelf_id uuid, target_velocity numeric, target_headroom integer, proposed_qty integer, trigger_reason text, fit_score numeric, projected_days_to_sell numeric, scoring_breakdown jsonb, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_slow    numeric;
  v_minqty  integer;
  v_spd     numeric;
  v_minfit  numeric;
  v_maxprop integer;
  v_floor   integer;
  v_limit   integer;
  v_gaps    jsonb;
  v_break   jsonb;
BEGIN
  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'propose_rotations_v3: p_plan_date is required';
  END IF;
  IF p_limit IS NOT NULL AND p_limit <= 0 THEN
    RAISE EXCEPTION 'propose_rotations_v3: p_limit must be positive, got %', p_limit;
  END IF;

  PERFORM set_config('app.via_rpc',  'true',                  true);
  PERFORM set_config('app.rpc_name', 'propose_rotations_v3',  true);

  SELECT rot_slow_velocity_per_day, rot_min_source_qty, rot_min_speedup,
         rot_min_fit_score, rot_max_proposals, rot_keep_floor
    INTO v_slow, v_minqty, v_spd, v_minfit, v_maxprop, v_floor
  FROM public.refill_policy_params LIMIT 1;

  IF v_slow IS NULL THEN
    RAISE EXCEPTION 'propose_rotations_v3: refill_policy_params holds no row';
  END IF;

  v_limit := LEAST(COALESCE(p_limit, v_maxprop), v_maxprop);

  CREATE TEMP TABLE IF NOT EXISTS pr_v3_sh (
    machine_id uuid, shelf_id uuid, pod_product_id uuid, sourcing text,
    stock integer, headroom integer, v numeric, velocity_status text, exp_date date
  ) ON COMMIT DROP;
  DELETE FROM pr_v3_sh;

  INSERT INTO pr_v3_sh
  SELECT s.machine_id, s.shelf_id, s.pod_product_id, s.sourcing,
         COALESCE(s.current_stock, 0),
         GREATEST(COALESCE(s.max_stock,0) - COALESCE(s.current_stock,0), 0),
         vel.velocity_instock_shelf,
         vel.velocity_status,
         s.oldest_expiry_est::date
  FROM public.v_shelf_state s
  LEFT JOIN public.v_shelf_instock_velocity_split_v3 vel ON vel.shelf_id = s.shelf_id
  WHERE s.pod_product_id IS NOT NULL;

  SELECT jsonb_build_object(
           'shelves_considered',     count(*),
           'no_velocity_shelves',    count(*) FILTER (WHERE v IS NULL),
           'below_floor_shelves',    count(*) FILTER (WHERE velocity_status = 'below_floor'),
           'out_of_scope_shelves',   count(*) FILTER (WHERE velocity_status = 'out_of_canonical_scope'),
           'unknown_expiry_shelves', count(*) FILTER (WHERE exp_date IS NULL))
    INTO v_gaps
  FROM pr_v3_sh;

  v_break := jsonb_build_object(
    'velocity_source',     'v_shelf_instock_velocity_split_v3',
    'shelf_state_source',  'v_shelf_state',
    'threshold_basis',     'POLICY, not measured - rot_* params on refill_policy_params',
    'expiry_basis',        'CURRENT_DATE, not p_plan_date (S-75)',
    'qty_formula',         'LEAST(GREATEST(source_stock - rot_keep_floor, 0), target_headroom) -- D-26, CS 2026-07-31',
    'fit_formula',         'target_velocity / GREATEST(source_velocity, rot_slow_velocity_per_day/10)',
    'params', jsonb_build_object('slow', v_slow, 'min_qty', v_minqty,
                                 'min_speedup', v_spd, 'min_fit', v_minfit,
                                 'max_proposals', v_maxprop,
                                 'keep_floor', v_floor),
    'coverage_gaps',       v_gaps);

  CREATE TEMP TABLE IF NOT EXISTS pr_v3_out (
    s_shelf uuid, s_mach uuid, pod uuid, s_stock integer, s_v numeric, s_exp date,
    t_shelf uuid, t_mach uuid, t_v numeric, t_head integer,
    qty integer, fit numeric, pdays numeric, reason text
  ) ON COMMIT DROP;
  DELETE FROM pr_v3_out;

  INSERT INTO pr_v3_out
  WITH pairs AS (
    SELECT src.shelf_id AS s_shelf, src.machine_id AS s_mach, src.pod_product_id AS pod,
           src.stock AS s_stock, src.v AS s_v, src.exp_date AS s_exp,
           tgt.shelf_id AS t_shelf, tgt.machine_id AS t_mach, tgt.v AS t_v,
           tgt.headroom AS t_head,
           LEAST(GREATEST(src.stock - v_floor, 0), tgt.headroom) AS qty,
           round(tgt.v / GREATEST(src.v, v_slow/10.0), 4) AS fit,
           round(LEAST(GREATEST(src.stock - v_floor, 0), tgt.headroom)::numeric / tgt.v, 2) AS pdays,
           CASE WHEN src.v = 0 THEN 'dead_stock' ELSE 'stranded_slow_mover' END AS reason
    FROM pr_v3_sh src
    JOIN pr_v3_sh tgt
      ON  tgt.pod_product_id = src.pod_product_id
      AND tgt.machine_id <> src.machine_id
    WHERE src.velocity_status = 'ok'
      AND src.v < v_slow
      AND src.stock >= v_minqty
      AND src.sourcing IS DISTINCT FROM 'venue'
      AND tgt.velocity_status = 'ok'
      AND tgt.v > 0
      AND tgt.headroom > 0
      AND tgt.sourcing IS DISTINCT FROM 'venue'
      AND tgt.v >= src.v * v_spd
      AND LEAST(GREATEST(src.stock - v_floor, 0), tgt.headroom) > 0
  ),
  kept AS (
    SELECT * FROM pairs
    WHERE fit >= v_minfit
      AND (s_exp IS NULL OR (s_exp - CURRENT_DATE) >= pdays)
  ),
  best_src AS (
    SELECT *, row_number() OVER (PARTITION BY s_shelf ORDER BY fit DESC, qty DESC, t_shelf) rn
    FROM kept
  ),
  best_tgt AS (
    SELECT *, row_number() OVER (PARTITION BY t_shelf ORDER BY fit DESC, qty DESC, s_shelf) rn2
    FROM best_src WHERE rn = 1
  )
  SELECT s_shelf, s_mach, pod, s_stock, s_v, s_exp, t_shelf, t_mach, t_v, t_head,
         qty, fit, pdays, reason
  FROM best_tgt WHERE rn2 = 1
  ORDER BY fit DESC, qty DESC, s_shelf, t_shelf
  LIMIT v_limit;

  IF NOT p_dry_run THEN
    INSERT INTO public.rotation_proposals_v3 AS rp (
      plan_date, source_machine_id, source_shelf_id, source_pod_product_id,
      source_qty_on_shelf, source_velocity, source_days_to_sell,
      target_machine_id, target_shelf_id, target_velocity, target_headroom,
      proposed_qty, trigger_reason, fit_score, projected_days_to_sell, scoring_breakdown)
    SELECT p_plan_date, o.s_mach, o.s_shelf, o.pod,
           o.s_stock, o.s_v,
           CASE WHEN o.s_v > 0 THEN round(o.s_stock::numeric / o.s_v, 2) END,
           o.t_mach, o.t_shelf, o.t_v, o.t_head,
           o.qty, o.reason, o.fit, o.pdays, v_break
    FROM pr_v3_out o
    -- S-76: name the CONSTRAINT. A column inference list here is ambiguous against the
    -- identically-named OUT parameters.
    ON CONFLICT ON CONSTRAINT rp_v3_unique_heartbeat DO NOTHING;
  END IF;

  RETURN QUERY
  SELECT COALESCE(r.proposal_id, gen_random_uuid()),
         p_plan_date, o.s_mach, o.s_shelf, o.pod,
         o.s_stock, o.s_v,
         CASE WHEN o.s_v > 0 THEN round(o.s_stock::numeric / o.s_v, 2) END,
         o.t_mach, o.t_shelf, o.t_v, o.t_head,
         o.qty, o.reason, o.fit, o.pdays, v_break,
         COALESCE(r.status, 'pending')
  FROM pr_v3_out o
  LEFT JOIN public.rotation_proposals_v3 r
    ON r.plan_date = p_plan_date
   AND r.source_shelf_id = o.s_shelf
   AND r.target_shelf_id = o.t_shelf
  ORDER BY o.fit DESC, o.qty DESC, o.s_shelf, o.t_shelf;
END
$function$
;
