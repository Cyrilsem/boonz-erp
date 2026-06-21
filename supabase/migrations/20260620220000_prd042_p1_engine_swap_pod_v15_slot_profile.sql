-- PRD-042 P1: engine_swap_pod v14 -> v15_slot_profile. Pass-3 becomes a machine-level pick from the
-- precomputed, size-appropriate slot_profile_pool instead of a product-level swap over the raw WH
-- universe with a bolt-on candidate cap. Physical fit and quantity are correct by construction: the
-- pool only holds in-lane products, each carrying its own profile fill_qty.
--
-- Forward-only CREATE OR REPLACE of the canonical engine_swap_pod (NO parallel _v15 fn). Single
-- structural change in the _p3_pairs `capd` CTE: intersect the per-machine candidate universe
-- (_p3_cand, which already applies WH-stock + coexistence + travel + intro-cooldown + on-machine
-- exclusion guardrails live) with slot_profile_pool for the slot's (lane_family, shelf_size), and
-- take cand_cap from the pool fill_qty (the profile quantity) instead of the candidate's own
-- form-factor cap. If the incumbent physical_type is NULL/unmapped, the lane_family subquery is NULL
-- so the pool join matches nothing -> no candidates -> KEEP (never strand).
--
-- The value model is unchanged and already matches the PRD: V = margin * min(proj_vel*D, cand_cap),
-- proj_vel = 0.5*sister + 0.3*global + 0.2*affinity*global, KEEP unless best >= keep_v*1.15, greedy
-- <=2/machine, fleet<=10, no dup, homogenisation<=3. Only cand_cap now = profile fill_qty.
-- Passes 1 / dead-tag / 2b unchanged (only their engine_version write-tag bumps v14->v15_slot_profile).
-- engine_add_pod UNTOUCHED (T12). swaps_enabled stays false (Pass-3 a no-op until Track D).
--
-- Surgical DO-block (B4 / B3-part2 pattern): fetch live def, one anchored block replace + version
-- bump, drift guards, EXECUTE.

DO $do$
DECLARE v text;
BEGIN
  SELECT pg_get_functiondef('public.engine_swap_pod(date,integer,numeric,integer)'::regprocedure) INTO v;

  v := replace(v,
    E'           GREATEST(COALESCE(\n'
    || E'             (SELECT scm.override_max_stock FROM public.slot_capacity_max scm\n'
    || E'               WHERE scm.machine_id=k.machine_id AND scm.aisle_code=k.shelf_code LIMIT 1),\n'
    || E'             FLOOR(public.product_slot_capacity_units(cc.cand_phys, k.shelf_size)*0.85)::int,\n'
    || E'             (SELECT sc.max_capacity FROM public.shelf_configurations sc WHERE sc.shelf_id=k.shelf_id LIMIT 1),\n'
    || E'             8),1) AS cand_cap\n'
    || E'      FROM _p3_slot_keep k\n'
    || E'      JOIN _p3_cand cc ON cc.machine_id = k.machine_id',
    E'           spp.fill_qty AS cand_cap\n'
    || E'      FROM _p3_slot_keep k\n'
    || E'      JOIN _p3_cand cc ON cc.machine_id = k.machine_id\n'
    || E'      JOIN public.slot_profile_pool spp\n'
    || E'        ON spp.boonz_product_id = cc.cand_boonz\n'
    || E'       AND spp.shelf_size = k.shelf_size\n'
    || E'       AND spp.lane_family = (SELECT lf.lane_family FROM public.physical_type_lane_family lf WHERE lf.physical_type = k.inc_phys)');

  v := replace(v, 'v14_landed_cost_margin', 'v15_slot_profile');

  IF position('slot_profile_pool spp' in v) = 0 THEN
    RAISE EXCEPTION 'PRD-042 P1: slot_profile_pool join not injected (capd block drifted).';
  END IF;
  IF position('product_slot_capacity_units(cc.cand_phys' in v) > 0 THEN
    RAISE EXCEPTION 'PRD-042 P1: old candidate-cap expression still present.';
  END IF;
  IF position('v14_landed_cost_margin' in v) > 0 THEN
    RAISE EXCEPTION 'PRD-042 P1: v14 version string remains after bump.';
  END IF;

  EXECUTE v;
END $do$;
