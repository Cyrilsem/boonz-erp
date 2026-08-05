-- PRD-110 P3.3 corrective — ON CONFLICT column list was ambiguous against the OUT parameters.
--
-- ⛔ S-76. `RETURNS TABLE (... plan_date date, source_shelf_id uuid, target_shelf_id uuid ...)`
--    declares PL/pgSQL variables with exactly the names of the target table's columns. In the
--    INSERT body every column reference is either in a column-list position or qualified, so
--    all of them resolve -- EXCEPT the `ON CONFLICT (plan_date, source_shelf_id,
--    target_shelf_id)` inference list, where PL/pgSQL cannot tell the variable from the column:
--       ERROR 42702: column reference "plan_date" is ambiguous
--    Naming the CONSTRAINT instead of inferring from a column list removes the ambiguity
--    entirely and is strictly more precise: it binds to rp_v3_unique_heartbeat by name rather
--    than re-deriving which index matches.
--
-- ⭐ WHY THIS SURVIVED A CLEAN DRY RUN, and it is the transferable half: the smoke test called
--    the function with p_dry_run => true, and p_dry_run SKIPS THE INSERT. It returned 25 rows
--    and looked like proof the function worked. It had never executed the write path at all.
--    A dry-run test of a writer tests everything except the thing that writes.
--
-- ⭐ WHAT CAUGHT IT: fixture 43's S-70 wrappers. The aborted scenario rolled back and left the
--    PREVIOUS run's scratch in place, so the assertions were reading stale data from an older
--    run. Unwrapped "count the violations, expect 0" assertions would have found no 'out' row,
--    counted 0, and reported PASS on a function that was erroring on every call. The wrappers
--    turned it into 30 visible failures instead.

CREATE OR REPLACE FUNCTION public.propose_rotations_v3(
  p_plan_date date,
  p_limit     integer DEFAULT NULL,
  p_dry_run   boolean DEFAULT false
)
RETURNS TABLE (
  proposal_id            uuid,
  plan_date              date,
  source_machine_id      uuid,
  source_shelf_id        uuid,
  source_pod_product_id  uuid,
  source_qty_on_shelf    integer,
  source_velocity        numeric,
  source_days_to_sell    numeric,
  target_machine_id      uuid,
  target_shelf_id        uuid,
  target_velocity        numeric,
  target_headroom        integer,
  proposed_qty           integer,
  trigger_reason         text,
  fit_score              numeric,
  projected_days_to_sell numeric,
  scoring_breakdown      jsonb,
  status                 text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_slow    numeric;
  v_minqty  integer;
  v_spd     numeric;
  v_minfit  numeric;
  v_maxprop integer;
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
         rot_min_fit_score, rot_max_proposals
    INTO v_slow, v_minqty, v_spd, v_minfit, v_maxprop
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
    'fit_formula',         'target_velocity / GREATEST(source_velocity, rot_slow_velocity_per_day/10)',
    'params', jsonb_build_object('slow', v_slow, 'min_qty', v_minqty,
                                 'min_speedup', v_spd, 'min_fit', v_minfit,
                                 'max_proposals', v_maxprop),
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
           LEAST(src.stock, tgt.headroom) AS qty,
           round(tgt.v / GREATEST(src.v, v_slow/10.0), 4) AS fit,
           round(LEAST(src.stock, tgt.headroom)::numeric / tgt.v, 2) AS pdays,
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
      AND LEAST(src.stock, tgt.headroom) > 0
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
$fn$;

COMMENT ON FUNCTION public.propose_rotations_v3(date, integer, boolean) IS
'PRD-110 P3.3 rotation heartbeat. Proposes moving stranded slow-moving stock to a machine where the SAME pod product demonstrably sells. ADVISORY: writes rotation_proposals_v3 rows at status pending and nothing else - no plan row, no dispatch leg, no machines_to_visit row. p_dry_run computes a full answer and writes nothing (⛔ so a dry-run smoke test does NOT exercise the write path - S-76). Idempotent per rp_v3_unique_heartbeat. Velocity from v_shelf_instock_velocity_split_v3 ONLY (NEVER v_shelf_state.velocity_instock - still NULL post-P2.1, S-73). Expiry horizon from CURRENT_DATE, never p_plan_date (S-75). Pinned by golden fixture 43.';

REVOKE ALL ON FUNCTION public.propose_rotations_v3(date, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.propose_rotations_v3(date, integer, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.propose_rotations_v3(date, integer, boolean) TO service_role;
