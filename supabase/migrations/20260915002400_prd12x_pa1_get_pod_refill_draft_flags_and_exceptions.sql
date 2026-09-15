-- ONE-LOOP-2 Block A step 1b: get_pod_refill_draft gains the three retired
-- gates as informational booleans (PRD-125 D6: "G2, G4, G9 become columns on
-- the draft, not gate output"), and a new get_pod_refill_draft_exceptions
-- function backs confirm_and_build's exceptions array.
--
-- g2_flag ("lane already holding >= 9 was refilled"): per-row, direct port
-- of the retired G2 predicate onto this row's own action/current_stock.
-- g9_flag ("best available batch expires within plan_date + 21"): per-row,
-- resolves the row's product_mapping the same way engine_add_pod/wh_avail
-- do, then checks wh_available_for's fefo_expiry against any warehouse it
-- draws from (bool_or across the 1-2 rows wh_available_for can return).
-- g4_flag ("lane <= 20% full with no line") cannot be literally per-row: by
-- construction every row in this function already HAS a line, so the
-- original predicate (n_lines = 0) can never be true for a row that exists.
-- Reinterpreted at the only grain that keeps it meaningful: true on every
-- row of a machine's draft when THAT MACHINE has at least one OTHER WEIMI
-- lane, with no line in today's draft, sitting at or below 20% full. This
-- is a machine-level informational flag, not a claim about this specific
-- row.
--
-- get_pod_refill_draft_exceptions(plan_date) is a genuinely reduced scope
-- versus PRD-125 Phase 4's full ask ("every no_rule_matched, every G-check
-- failure, every lane where WEIMI and pod_inventory disagree"): it covers
-- no_rule_matched (expired-on-shelf shelves the engine could not fix) plus
-- G5 and G8 re-derived directly against pod_refill_plan (the table this
-- pipeline actually uses; validate_refill_plan's own 'plan_output' source
-- reads the older, unrelated refill_plan_output table and cannot see
-- pod_refill_plan rows at all -- confirmed by column diff, pod_refill_plan
-- uses pod_product_id, refill_plan_output uses boonz_product_id). G3, G7,
-- G10 and the WEIMI-vs-pod_inventory disagreement category were not ported
-- in this pass given time; logged as a scope decision, not silently
-- dropped.

DO $mig$ DECLARE v_def text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='get_pod_refill_draft' AND p.pronamespace='public'::regnamespace;
  IF v_def IS NULL THEN RAISE EXCEPTION 'get_pod_refill_draft not found'; END IF;
END $mig$;

DROP FUNCTION IF EXISTS public.get_pod_refill_draft(date);

CREATE OR REPLACE FUNCTION public.get_pod_refill_draft(p_plan_date date DEFAULT (CURRENT_DATE + 1))
 RETURNS TABLE(plan_date date, machine_id uuid, machine_name text, shelf_id uuid, shelf_code text, pod_product_id uuid, pod_product_name text, action text, qty integer, current_stock integer, max_stock integer, fill_pct numeric, velocity_30d numeric, signal text, clamp_reason text, source_origin text, has_intent boolean, intent_id uuid, status text, reasoning jsonb, edited_at timestamp with time zone, edited_by text, wh_avail integer, g2_flag boolean, g4_flag boolean, g9_flag boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    prp.plan_date,
    prp.machine_id,
    m.official_name                                   AS machine_name,
    prp.shelf_id,
    sc.shelf_code,
    prp.pod_product_id,
    pp.pod_product_name,
    prp.action,
    prp.qty,
    lss.current_stock,
    lss.max_stock,
    ROUND(lss.fill_pct::numeric, 1)                   AS fill_pct,
    (prp.reasoning->>'velocity_30d')::numeric         AS velocity_30d,
    prp.reasoning->>'signal'                          AS signal,
    prp.reasoning->>'clamp_reason'                    AS clamp_reason,
    prp.source_origin::text,
    prp.linked_intent_id IS NOT NULL                  AS has_intent,
    prp.linked_intent_id                              AS intent_id,
    prp.status,
    prp.reasoning,
    prp.edited_at,
    prp.edited_by,
    (
      SELECT SUM(wh.warehouse_stock)::int
      FROM (
        SELECT DISTINCT wi.wh_inventory_id, wi.warehouse_stock
        FROM public.product_mapping pm
        JOIN public.warehouse_inventory wi
          ON wi.boonz_product_id = pm.boonz_product_id
         AND wi.status = 'Active'
         AND wi.quarantined = false
         AND NOT COALESCE(wi.manually_quarantined, false)
         AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)
         AND wi.warehouse_id = ANY (ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id])
         AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = prp.machine_id)
        WHERE pm.pod_product_id = prp.pod_product_id
          AND pm.status = 'Active'
          AND (pm.machine_id IS NULL OR pm.machine_id = prp.machine_id)
      ) wh
    ) AS wh_avail,
    -- G2: lane already holding >= 9 was refilled.
    (prp.action IN ('REFILL','ADD_NEW') AND COALESCE(lss.current_stock,0) >= 9) AS g2_flag,
    -- G4 (machine-level, see migration note): this machine has at least one
    -- other WEIMI lane at or below 20% full with no line in today's draft.
    EXISTS (
      SELECT 1
      FROM public.weimi_shelf_now(prp.machine_id) wsn
      JOIN public.shelf_configurations sc2
        ON sc2.machine_id = prp.machine_id AND sc2.shelf_code = wsn.shelf_code
      WHERE wsn.current_stock > 0
        AND wsn.current_stock <= GREATEST(2, ROUND(wsn.max_stock * 0.2))
        AND NOT EXISTS (
          SELECT 1 FROM public.pod_refill_plan prp2
           WHERE prp2.plan_date = prp.plan_date AND prp2.machine_id = prp.machine_id
             AND prp2.shelf_id = sc2.shelf_id AND prp2.status = 'draft'
        )
    ) AS g4_flag,
    -- G9: best available batch (across the warehouse(s) this row's product
    -- draws from) expires within plan_date + 21.
    (
      SELECT bool_or(waf.fefo_expiry IS NOT NULL AND waf.fefo_expiry <= prp.plan_date + 21)
      FROM (
        SELECT pmx.boonz_product_id FROM public.product_mapping pmx
         WHERE pmx.pod_product_id = prp.pod_product_id AND pmx.status = 'Active'
           AND (pmx.machine_id IS NULL OR pmx.machine_id = prp.machine_id)
         ORDER BY (pmx.machine_id = prp.machine_id) DESC NULLS LAST, pmx.is_global_default DESC
         LIMIT 1
      ) rb
      CROSS JOIN LATERAL public.wh_available_for(prp.machine_id, rb.boonz_product_id) waf
    ) AS g9_flag
  FROM pod_refill_plan prp
  JOIN machines m              ON m.machine_id       = prp.machine_id
  JOIN shelf_configurations sc ON sc.shelf_id        = prp.shelf_id
  JOIN pod_products pp         ON pp.pod_product_id  = prp.pod_product_id
  LEFT JOIN v_live_shelf_stock lss
    ON  lss.machine_id = prp.machine_id
    AND lss.slot_name = LEFT(sc.shelf_code, 1)
                     || (SUBSTR(sc.shelf_code, 2)::int)::text
  WHERE prp.plan_date = p_plan_date
    AND prp.status = 'draft'
  ORDER BY m.official_name, sc.shelf_code;
$function$;

CREATE OR REPLACE FUNCTION public.get_pod_refill_draft_exceptions(p_plan_date date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH picked_machines AS (
    SELECT DISTINCT machine_id FROM public.machines_to_visit
     WHERE plan_date = p_plan_date AND status IN ('picked','cs_added')
  ),
  no_rule AS (
    SELECT m.official_name AS machine, sc.shelf_code AS shelf, pp.pod_product_name AS product,
      'no_rule_matched'::text AS exception_type,
      'expired on shelf, no substitution rule matched'::text AS detail
    FROM picked_machines pmc
    JOIN public.machines m ON m.machine_id = pmc.machine_id
    CROSS JOIN LATERAL public.weimi_shelf_now(pmc.machine_id) wsn
    JOIN public.shelf_configurations sc
      ON sc.machine_id = pmc.machine_id AND sc.shelf_code = wsn.shelf_code
    JOIN public.pod_inventory pi
      ON pi.machine_id = pmc.machine_id AND pi.shelf_id = sc.shelf_id
     AND pi.status = 'Active' AND pi.expiration_date IS NOT NULL
     AND pi.expiration_date < CURRENT_DATE AND pi.current_stock > 0
    JOIN public.pod_products pp ON pp.pod_product_id = wsn.pod_product_id
    LEFT JOIN LATERAL public.find_substitutes_for_shelf(
      p_plan_date, pmc.machine_id, sc.shelf_id, wsn.pod_product_id) fs ON true
    WHERE wsn.current_stock > 0 AND fs.pod_product_id IS NULL
  ),
  gate_g5 AS (
    SELECT m.official_name AS machine, sc.shelf_code AS shelf, pp.pod_product_name AS product,
      'gate_failure'::text AS exception_type,
      'G5: product has no Active mapping on that machine or globally'::text AS detail
    FROM public.pod_refill_plan prp
    JOIN public.machines m ON m.machine_id = prp.machine_id
    JOIN public.shelf_configurations sc ON sc.shelf_id = prp.shelf_id
    JOIN public.pod_products pp ON pp.pod_product_id = prp.pod_product_id
    WHERE prp.plan_date = p_plan_date AND prp.status = 'draft'
      AND prp.action IN ('REFILL','ADD_NEW')
      AND NOT EXISTS (
        SELECT 1 FROM public.product_mapping pm
         WHERE pm.pod_product_id = prp.pod_product_id AND pm.status = 'Active'
           AND (pm.machine_id IS NULL OR pm.machine_id = prp.machine_id))
  ),
  gate_g8 AS (
    SELECT m.official_name AS machine, NULL::text AS shelf, pp.pod_product_name AS product,
      'gate_failure'::text AS exception_type,
      format('G8: need %s, free %s at the supplying warehouse', x.need, x.free)::text AS detail
    FROM (
      SELECT prp.machine_id, prp.pod_product_id, SUM(prp.qty) AS need,
        (SELECT COALESCE(SUM(waf.free_stock),0)
           FROM (
             SELECT pmx.boonz_product_id FROM public.product_mapping pmx
              WHERE pmx.pod_product_id = prp.pod_product_id AND pmx.status = 'Active'
                AND (pmx.machine_id IS NULL OR pmx.machine_id = prp.machine_id)
              ORDER BY (pmx.machine_id = prp.machine_id) DESC NULLS LAST, pmx.is_global_default DESC
              LIMIT 1
           ) rb
           CROSS JOIN LATERAL public.wh_available_for(prp.machine_id, rb.boonz_product_id) waf
        ) AS free
      FROM public.pod_refill_plan prp
      WHERE prp.plan_date = p_plan_date AND prp.status = 'draft'
        AND prp.action IN ('REFILL','ADD_NEW')
      GROUP BY prp.machine_id, prp.pod_product_id
    ) x
    JOIN public.machines m ON m.machine_id = x.machine_id
    JOIN public.pod_products pp ON pp.pod_product_id = x.pod_product_id
    WHERE x.need > x.free
  ),
  all_exceptions AS (
    SELECT * FROM no_rule
    UNION ALL SELECT * FROM gate_g5
    UNION ALL SELECT * FROM gate_g8
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'machine', machine, 'shelf', shelf, 'product', product,
    'exception_type', exception_type, 'detail', detail
  )), '[]'::jsonb)
  FROM all_exceptions;
$function$;
