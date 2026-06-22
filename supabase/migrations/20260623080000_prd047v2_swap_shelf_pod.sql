-- PRD-047 v2 PHASE 2: pod-level whole-shelf swap.
--
-- Two objects:
--   1. spread_pod_qty(machine, shelf, pod, target) -> (boonz_product_id, qty)
--      A read-only helper that REPLICATES the stitch v26 multi-variant
--      distribution: normalized split_pct over WH-available mapped variants,
--      FLOOR base + largest-remainder top-up, on-shelf tie-break, conservation
--      (SUM(qty) == target). It is a faithful copy of the `pull_*` CTE chain in
--      stitch_pod_to_boonz; stitch still inlines its own copy because that engine
--      must stay byte-equivalent (Art 12), so the two MUST be kept in sync. This
--      helper is the single source of truth for the SWAP path.
--   2. swap_shelf_pod(...) -> the DEFINER writer. Atomic in one transaction:
--      (a) Remove every current Refill/Add dispatch line on the shelf at its
--          current qty (whole-shelf swap; clears the old pod).
--      (b) target = shelf capacity (max_stock_weimi).
--      (c) spread the target across the NEW pod's WH-available mapped variants
--          via spread_pod_qty.
--      (d) write one Add New line per variant (title-case, source_kind='wh' =
--          machine primary warehouse; FEFO chosen at pack).
--      Composes the canonical add_dispatch_row twice (Art 1) -> inherits its
--      guards + edit-log audit (Art 4/8). Forward-only (Art 12).
--
-- swaps_enabled is untouched; this only writes dispatch lines, same contract as
-- the P0 swap_dispatch_shelf it generalises.

-- ── 1. read-only distribution helper ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.spread_pod_qty(
  p_machine_id uuid,
  p_shelf_id uuid,
  p_pod_product_id uuid,
  p_target_qty integer
)
RETURNS TABLE(boonz_product_id uuid, qty integer)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
  WITH m_raw AS (
    -- machine-specific mapping wins over global default (stitch rnk=1 dedup)
    SELECT pm.boonz_product_id, pm.split_pct,
           ROW_NUMBER() OVER (
             PARTITION BY pm.boonz_product_id
             ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST,
                      pm.is_global_default DESC, pm.boonz_product_id
           ) AS rnk
    FROM public.product_mapping pm
    WHERE pm.pod_product_id = p_pod_product_id
      AND pm.status = 'Active'
      AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
  ),
  m AS (SELECT * FROM m_raw WHERE rnk = 1),
  wh AS (
    SELECT m.boonz_product_id, m.split_pct,
           COALESCE((SELECT SUM(vp.warehouse_stock)::int
                       FROM public.v_wh_pickable vp
                      WHERE vp.boonz_product_id = m.boonz_product_id), 0) AS wh_avail,
           EXISTS (SELECT 1 FROM public.v_pod_inventory_latest pil
                    WHERE pil.machine_id = p_machine_id
                      AND pil.shelf_id = p_shelf_id
                      AND pil.status = 'Active'
                      AND pil.boonz_product_id = m.boonz_product_id) AS on_shelf
    FROM m
  ),
  -- WH-available variants only (stitch warehouse-sourced eligibility)
  elig AS (SELECT * FROM wh WHERE wh_avail > 0),
  n_pre AS (
    SELECT e.*,
           SUM(COALESCE(split_pct, 0)) OVER () AS total_split,
           COUNT(*) OVER () AS variant_n
    FROM elig e
  ),
  n AS (
    SELECT np.*,
           CASE WHEN total_split = 0 THEN 1.0 / NULLIF(variant_n, 0)
                ELSE COALESCE(split_pct, 0) / NULLIF(total_split, 0) END AS norm_split
    FROM n_pre np
  ),
  b AS (
    SELECT n.*,
           FLOOR(p_target_qty * norm_split)::int AS base_qty,
           (p_target_qty * norm_split) - FLOOR(p_target_qty * norm_split)::numeric AS remainder_score
    FROM n WHERE norm_split > 0
  ),
  r AS (
    SELECT b.*, p_target_qty - SUM(base_qty) OVER ()::int AS slot_remainder FROM b
  ),
  rk AS (
    SELECT r.*,
           ROW_NUMBER() OVER (
             ORDER BY remainder_score DESC, on_shelf DESC, norm_split DESC, boonz_product_id
           ) AS rank_remainder
    FROM r
  )
  SELECT rk.boonz_product_id,
         (rk.base_qty + CASE WHEN rk.rank_remainder <= rk.slot_remainder THEN 1 ELSE 0 END)::int AS qty
  FROM rk
  WHERE (rk.base_qty + CASE WHEN rk.rank_remainder <= rk.slot_remainder THEN 1 ELSE 0 END) > 0;
$function$;

COMMENT ON FUNCTION public.spread_pod_qty(uuid, uuid, uuid, integer) IS
  'PRD-047 v2: read-only replica of stitch v26 multi-variant distribution (normalized split_pct over WH-available mapped variants, largest-remainder + on-shelf tie-break, conserves SUM==target). Used by swap_shelf_pod. Keep in sync with stitch_pod_to_boonz pull_* CTEs.';

-- ── 2. pod-level whole-shelf swap (DEFINER writer) ──────────────────────────
CREATE OR REPLACE FUNCTION public.swap_shelf_pod(
  p_plan_date date,
  p_machine_id uuid,
  p_shelf_id uuid,
  p_new_pod_product_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid := auth.uid();
  v_role         text;
  v_shelf_code   text;
  v_wh           uuid;
  v_cap          int;
  v_spread_total int := 0;
  v_n_spread     int := 0;
  v_removed      jsonb := '[]'::jsonb;
  v_added        jsonb := '[]'::jsonb;
  r              record;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'swap_shelf_pod', true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'swap_shelf_pod: forbidden for role %', COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL OR p_new_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'swap_shelf_pod: plan_date, machine_id, shelf_id, new_pod_product_id are required';
  END IF;
  IF COALESCE(p_reason, '') = '' OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'swap_shelf_pod: p_reason required (>= 10 chars)';
  END IF;

  SELECT shelf_code INTO v_shelf_code
    FROM public.shelf_configurations
   WHERE shelf_id = p_shelf_id AND machine_id = p_machine_id;
  IF v_shelf_code IS NULL THEN
    RAISE EXCEPTION 'swap_shelf_pod: shelf % not found on machine %', p_shelf_id, p_machine_id;
  END IF;

  SELECT primary_warehouse_id INTO v_wh FROM public.machines WHERE machine_id = p_machine_id;
  IF v_wh IS NULL THEN
    RAISE EXCEPTION 'swap_shelf_pod: machine % has no primary_warehouse_id (cannot WH-source the new pod)', p_machine_id;
  END IF;

  -- (b) target = shelf capacity
  SELECT MAX(max_stock_weimi)::int INTO v_cap FROM public.v_shelf_max_stock WHERE shelf_id = p_shelf_id;
  IF COALESCE(v_cap, 0) <= 0 THEN
    RAISE EXCEPTION 'swap_shelf_pod: shelf % has no positive capacity (max_stock)', p_shelf_id;
  END IF;

  -- Validate the new pod yields a non-empty WH-available spread BEFORE any write,
  -- so an impossible swap never strands the shelf with Removes and no Adds.
  SELECT COALESCE(SUM(qty), 0), COUNT(*) INTO v_spread_total, v_n_spread
    FROM public.spread_pod_qty(p_machine_id, p_shelf_id, p_new_pod_product_id, v_cap);
  IF v_n_spread = 0 OR v_spread_total = 0 THEN
    RAISE EXCEPTION 'swap_shelf_pod: new pod % has no WH-available mapped variants to fill capacity % on shelf %',
      p_new_pod_product_id, v_cap, v_shelf_code;
  END IF;

  PERFORM set_config('app.mutation_reason', p_reason, true);

  -- (a) Remove every current Refill/Add line on the shelf at its current qty.
  FOR r IN
    SELECT rd.boonz_product_id, rd.quantity
      FROM public.refill_dispatching rd
     WHERE rd.machine_id = p_machine_id
       AND rd.shelf_id = p_shelf_id
       AND rd.dispatch_date = p_plan_date
       AND rd.include = true
       AND COALESCE(rd.skipped, false) = false
       AND COALESCE(rd.cancelled, false) = false
       AND rd.action IN ('Refill', 'Add New')
       AND COALESCE(rd.quantity, 0) > 0
       AND rd.pod_product_id IS DISTINCT FROM p_new_pod_product_id
  LOOP
    v_removed := v_removed || public.add_dispatch_row(
      p_machine_id, v_shelf_code, r.boonz_product_id, r.quantity, 'Remove',
      p_plan_date, 'unknown', NULL, NULL, COALESCE(v_role, 'system'), p_reason, NULL);
  END LOOP;

  -- (c,d) Add New the new pod spread at capacity (WH-sourced, FEFO at pack).
  FOR r IN
    SELECT boonz_product_id, qty
      FROM public.spread_pod_qty(p_machine_id, p_shelf_id, p_new_pod_product_id, v_cap)
  LOOP
    v_added := v_added || public.add_dispatch_row(
      p_machine_id, v_shelf_code, r.boonz_product_id, r.qty, 'Add New',
      p_plan_date, 'wh', v_wh, NULL, COALESCE(v_role, 'system'), p_reason, NULL);
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'ok',
    'shelf_code', v_shelf_code,
    'capacity', v_cap,
    'new_pod_product_id', p_new_pod_product_id,
    'spread_total', v_spread_total,
    'spread_variants', v_n_spread,
    'removed', v_removed,
    'added', v_added,
    'reason', p_reason
  );
END;
$function$;

COMMENT ON FUNCTION public.swap_shelf_pod(date, uuid, uuid, uuid, text) IS
  'PRD-047 v2: pod-level whole-shelf swap. Removes every current Refill/Add line on the shelf, then Adds New the chosen pod spread across WH-available mapped variants at shelf capacity via spread_pod_qty. Composes add_dispatch_row (Art 1/4/8). swaps_enabled untouched.';

GRANT EXECUTE ON FUNCTION public.spread_pod_qty(uuid, uuid, uuid, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.swap_shelf_pod(date, uuid, uuid, uuid, text) TO authenticated, service_role;
