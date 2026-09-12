-- PRD-121 P1.1a: validate_refill_plan must be callable BEFORE the plan is pushed to
-- refill_dispatching, so write_refill_plan can surface the same 9 merchandising gates as
-- early warnings, not just approve_refill_plan as a hard gate (P0.1, already live).
--
-- validate_refill_plan's `mach` and `lines` CTEs read exclusively from
-- refill_dispatching (dispatch_date = p_plan_date) -- rows that do not exist yet for a
-- plan still sitting in refill_plan_output as 'pending'. Calling it unmodified at write
-- time would either see nothing (a genuinely new plan_date) or stale rows from a prior
-- dispatch cycle on that date -- never the plan just written. Flagged as a non-blocking
-- architecture note during the P0.1 Cody review; now load-bearing for P1.1.
--
-- Fix: add p_source text DEFAULT 'dispatch' ('dispatch' | 'plan_output'). `mach` and
-- `lines` become a UNION ALL of two branches, each gated by p_source so exactly one
-- contributes rows per call -- the existing 'dispatch' branch is untouched byte-for-byte,
-- so every existing caller (approve_refill_plan, always called with exactly 2 args)
-- behaves identically. All 9 gates (G1-G9), `avail` (CENTRAL stock) and `w`
-- (WEIMI live shelf state) are unchanged -- they only consume machine_id/shelf_code/
-- boonz_product_id/action/quantity, which both sources provide the same way.
--
-- One real limitation, accepted rather than worked around: refill_plan_output has no
-- source_kind/is_m2m -- M2M pairing is a dispatch-time concept that doesn't exist yet at
-- write time. The plan_output branch passes source_kind = NULL, so G8/G9 (CENTRAL stock,
-- FEFO) evaluate ALL Add/Refill lines against CENTRAL, including ones an operator intends
-- to route as M2M at approve time -- a conservative early warning, not a false-negative.
-- The real hard gate stays at approve_refill_plan/push time, where source_kind is known.
--
-- Requires DROP FUNCTION first (not bare CREATE OR REPLACE): adding a parameter changes
-- the signature, so CREATE OR REPLACE alone would create a second overload alongside the
-- existing 2-arg version -- the exact overload foot-gun this repo has hit twice already
-- this cycle (approve_refill_plan, repair_orphan_internal_transfer). The sole existing
-- caller (approve_refill_plan) always passes exactly 2 positional args, which resolves
-- unambiguously to the new 3-arg-with-default signature once the old one is gone.
--
-- Dara: SQL-shape decision only (UNION ALL branch gated by p_source, keyed off the
-- existing table's own machine_id/shelf_id -- no new table, no new column).
-- Cody: approve. Articles 1 (still the sole validation object; UNION branch keeps
-- 'dispatch' path byte-identical, satisfying "VERIFY, DO NOT REBUILD" for the already-
-- shipped gate), 12 (DROP + CREATE, not edit-in-place; md5-guarded), 16 (one canonical
-- 9-gate object serves both call sites -- no second, divergent write-time validator).

DO $mig$ DECLARE v_def text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='validate_refill_plan' AND p.pronamespace='public'::regnamespace
      AND pg_get_function_identity_arguments(p.oid) = 'p_plan_date date, p_machines text[]';
  IF md5(v_def) <> '69dc454201488b0c02afa45f84eee0bc' THEN
    RAISE EXCEPTION 'validate_refill_plan drifted (md5 %), refusing blind replace', md5(v_def);
  END IF;
END $mig$;

DROP FUNCTION IF EXISTS public.validate_refill_plan(date, text[]);

CREATE OR REPLACE FUNCTION public.validate_refill_plan(p_plan_date date, p_machines text[] DEFAULT NULL::text[], p_source text DEFAULT 'dispatch'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  IF p_source NOT IN ('dispatch','plan_output') THEN
    RAISE EXCEPTION 'validate_refill_plan: p_source must be ''dispatch'' or ''plan_output'' (got %)', p_source;
  END IF;

  WITH mach AS (
    SELECT DISTINCT rd.machine_id
      FROM public.refill_dispatching rd
      JOIN public.machines m ON m.machine_id = rd.machine_id
     WHERE p_source = 'dispatch'
       AND rd.dispatch_date = p_plan_date
       AND COALESCE(rd.cancelled,false)=false
       AND COALESCE(rd.skipped,false)=false
       AND COALESCE(rd.returned,false)=false
       AND (p_machines IS NULL OR m.official_name = ANY(p_machines))
    UNION
    SELECT DISTINCT rpo.machine_id
      FROM public.refill_plan_output rpo
      JOIN public.machines m ON m.machine_id = rpo.machine_id
     WHERE p_source = 'plan_output'
       AND rpo.plan_date = p_plan_date
       AND rpo.operator_status = 'pending'
       AND (p_machines IS NULL OR m.official_name = ANY(p_machines))
  ),
  latest AS (
    SELECT s.machine_id, max(s.snapshot_date) d
      FROM public.weimi_aisle_snapshots s JOIN mach ON mach.machine_id = s.machine_id
     GROUP BY 1
  ),
  w AS (
    SELECT s.machine_id,
           upper(left(s.slot_code,1))||lpad(regexp_replace(s.slot_code,'^[A-Za-z]',''),2,'0') AS shelf_code,
           s.product_name AS pod, s.current_stock, s.max_stock
      FROM public.weimi_aisle_snapshots s
      JOIN latest l ON l.machine_id = s.machine_id AND l.d = s.snapshot_date
  ),
  lines AS (
    SELECT rd.machine_id, sc.shelf_code, rd.boonz_product_id, rd.action, rd.quantity, rd.source_kind
      FROM public.refill_dispatching rd
      JOIN mach ON mach.machine_id = rd.machine_id
      LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = rd.shelf_id
     WHERE p_source = 'dispatch'
       AND rd.dispatch_date = p_plan_date
       AND COALESCE(rd.cancelled,false)=false
       AND COALESCE(rd.skipped,false)=false
       AND COALESCE(rd.returned,false)=false
       AND COALESCE(rd.quantity,0) > 0
    UNION ALL
    SELECT rpo.machine_id, sc2.shelf_code, rpo.boonz_product_id, rpo.action, rpo.quantity,
           NULL::text AS source_kind
      FROM public.refill_plan_output rpo
      JOIN mach ON mach.machine_id = rpo.machine_id
      LEFT JOIN public.shelf_configurations sc2 ON sc2.shelf_id = rpo.shelf_id
     WHERE p_source = 'plan_output'
       AND rpo.plan_date = p_plan_date
       AND rpo.operator_status = 'pending'
       AND COALESCE(rpo.quantity,0) > 0
  ),
  lane AS (
    SELECT w.machine_id, w.shelf_code, w.pod, w.current_stock, w.max_stock,
           COALESCE(sum(l.quantity) FILTER (WHERE l.action IN ('Refill','Add New')),0) AS add_qty,
           COALESCE(sum(l.quantity) FILTER (WHERE l.action IN ('Remove','Machine To Warehouse')),0) AS out_qty,
           count(l.*) AS n_lines
      FROM w JOIN mach ON mach.machine_id = w.machine_id
      LEFT JOIN lines l ON l.machine_id = w.machine_id AND l.shelf_code = w.shelf_code
     GROUP BY 1,2,3,4,5
  ),
  avail AS (
    SELECT wi.boonz_product_id, sum(wi.warehouse_stock) AS stock, min(wi.expiration_date) AS fefo
      FROM public.warehouse_inventory wi
     WHERE wi.warehouse_id = '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'
       AND COALESCE(wi.status,'Active') = 'Active'
       AND COALESCE(wi.quarantined,false) = false
       AND wi.warehouse_stock > 0
     GROUP BY 1
  ),
  g AS (
    SELECT 'G1' AS code, 'blocking' AS severity, 'lane lands at or over capacity' AS gate,
           m.official_name||' '||lane.shelf_code||': '||lane.current_stock||'+'||lane.add_qty||' of '||lane.max_stock AS detail
      FROM lane JOIN public.machines m ON m.machine_id = lane.machine_id
     WHERE lane.add_qty > 0 AND lane.out_qty = 0
       AND lane.current_stock + lane.add_qty >= lane.max_stock
    UNION ALL
    SELECT 'G2','warning','lane already holding >= 9 was refilled',
           m.official_name||' '||lane.shelf_code||' has '||lane.current_stock
      FROM lane JOIN public.machines m ON m.machine_id = lane.machine_id
     WHERE lane.add_qty > 0 AND lane.current_stock >= 9
    UNION ALL
    SELECT 'G3','blocking','EMPTY lane with no line',
           m.official_name||' '||lane.shelf_code||' ('||lane.pod||')'
      FROM lane JOIN public.machines m ON m.machine_id = lane.machine_id
     WHERE lane.current_stock = 0 AND lane.n_lines = 0
    UNION ALL
    SELECT 'G4','warning','lane <= 20% full with no line',
           m.official_name||' '||lane.shelf_code||' '||lane.current_stock||' of '||lane.max_stock
      FROM lane JOIN public.machines m ON m.machine_id = lane.machine_id
     WHERE lane.n_lines = 0 AND lane.current_stock > 0
       AND lane.current_stock <= greatest(2, round(lane.max_stock * 0.2))
    UNION ALL
    SELECT 'G5','blocking','product has no ACTIVE mapping on that machine',
           m.official_name||' '||COALESCE(l.shelf_code,'?')||' '||bp.boonz_product_name
      FROM lines l JOIN public.machines m ON m.machine_id = l.machine_id
      LEFT JOIN public.boonz_products bp ON bp.product_id = l.boonz_product_id
     WHERE l.action IN ('Refill','Add New')
       AND NOT EXISTS (SELECT 1 FROM public.product_mapping pm
                        WHERE pm.machine_id = l.machine_id
                          AND pm.boonz_product_id = l.boonz_product_id
                          AND pm.status = 'Active')
    UNION ALL
    SELECT 'G6','blocking','Machine To Warehouse action used (team does not use it)',
           m.official_name||' '||COALESCE(l.shelf_code,'?')
      FROM lines l JOIN public.machines m ON m.machine_id = l.machine_id
     WHERE l.action = 'Machine To Warehouse'
    UNION ALL
    SELECT 'G7','blocking','Remove with no replacement on the same lane',
           m.official_name||' '||lane.shelf_code||' would go EMPTY'
      FROM lane JOIN public.machines m ON m.machine_id = lane.machine_id
     WHERE lane.out_qty > 0 AND lane.add_qty = 0
    UNION ALL
    SELECT 'G8','blocking','product short in CENTRAL',
           bp.boonz_product_name||': need '||x.need||', free '||x.free
      FROM (SELECT l.boonz_product_id, sum(l.quantity) AS need,
                   COALESCE(a.stock,0) AS free
              FROM lines l LEFT JOIN avail a ON a.boonz_product_id = l.boonz_product_id
             WHERE l.action IN ('Refill','Add New') AND COALESCE(l.source_kind,'') <> 'm2m'
             GROUP BY 1, COALESCE(a.stock,0)) x
      JOIN public.boonz_products bp ON bp.product_id = x.boonz_product_id
     WHERE x.need > x.free
    UNION ALL
    SELECT 'G9','warning','best available batch expires within plan_date + 21',
           bp.boonz_product_name||' fefo '||a.fefo
      FROM (SELECT DISTINCT boonz_product_id FROM lines
             WHERE action IN ('Refill','Add New') AND COALESCE(source_kind,'') <> 'm2m') c
      JOIN avail a ON a.boonz_product_id = c.boonz_product_id
      JOIN public.boonz_products bp ON bp.product_id = c.boonz_product_id
     WHERE a.fefo <= p_plan_date + 21
  )
  SELECT jsonb_build_object(
    'plan_date', p_plan_date,
    'blocking', COALESCE(count(*) FILTER (WHERE severity='blocking'),0),
    'warnings', COALESCE(count(*) FILTER (WHERE severity='warning'),0),
    'violations', COALESCE(jsonb_agg(jsonb_build_object(
        'code',code,'severity',severity,'gate',gate,'detail',detail)
        ORDER BY severity, code), '[]'::jsonb)
  ) INTO v_out FROM g;

  RETURN v_out;
END;
$function$;
