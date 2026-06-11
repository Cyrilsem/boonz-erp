-- Refill reliability (PRD_refill_reliability_2026-06-03) / WS1b - stitch REMOVE/M2W one-pass dispatch.
--
-- STATUS: DRAFT - NOT APPLIED. Built file only (no operational write). Pending, before apply:
--   (1) boonz-master-3 conductor load + CS sign-off (stitch writes refill_plan_output, a protected entity);
--   (2) VML Evian->Popit swap verification in a rolled-back tx.
--
-- WS1b has TWO halves. This migration ships ONLY the safe, grounded half:
--
--   HALF 1 (HERE) - SKIP qty-0 REMOVE.
--     The physical-fallback CTE (remove_lines_physical_fallback) ignores the planned qty and emits a
--     "clear the whole shelf" line (qty = v_live_shelf_stock.current_stock) for ANY approved REMOVE/M2W
--     that has physical stock but no Active pod_inventory match - INCLUDING rows the engine planned at
--     qty 0. So an engine "remove 0" becomes a driver instruction to remove everything physically there.
--     Today's plan (2026-06-03) has 47 REMOVE/M2W rows, 2 of them qty 0 - this is live.
--     FIX: add `AND a.qty > 0` to the physical-fallback WHERE so a qty-0 planned REMOVE emits no line.
--     This is exactly the "(or skip qty-0 REMOVE)" branch of WS1b. It can only SUPPRESS phantom lines;
--     it never creates or enlarges a remove, so it is inventory-safe.
--
--   HALF 2 (NOT HERE - proposal, needs postmortem) - RESOLVE physical-fallback REMOVE to a CONCRETE
--     boonz variant so a swap's REMOVE stitches+dispatches in one pass. This is deliberately omitted:
--     v14's comment logic emits `[PHYSICAL REMOVE - no WH credit]` precisely WHEN boonz_product_id IS
--     NULL (line ~248). Resolving the variant makes boonz_product_id non-null, which drops that branch
--     and reclassifies the line as a normal warehouse remove -> it would CREDIT warehouse_inventory on
--     receive. Whether a physical-fallback REMOVE should credit WH is an inventory-ledger semantic that
--     refill_postmortem_2026-06-03.md governs and that doc is unreadable from this sandbox. Resolution
--     source is ready (pod_inventory history for the (machine,shelf,pod): ORDER BY created_at DESC,
--     expiration_date ASC NULLS LAST for FEFO; even +/-1 split; fall back to product_mapping default;
--     keep NULL-boonz legacy when unresolvable) - hold until CS/postmortem confirms the WH-credit rule.
--
-- Verbatim reproduction of stitch_pod_to_boonz v14 (20260601130000), diff-gated to exactly:
--   * remove_lines_physical_fallback WHERE: + `AND a.qty > 0`.
--   * engine_version 'v14_remove_qty_capped' -> 'v15_ws1b_skip_qty0_physical_remove'.
-- No schema change, no role/gate change, no new write path, no change to the mapped remove path.

CREATE OR REPLACE FUNCTION public.stitch_pod_to_boonz(p_plan_date date DEFAULT (CURRENT_DATE + 1), p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id uuid; v_t0 timestamptz := clock_timestamp();
  v_lines jsonb := '[]'::jsonb; v_line_count integer := 0;
  v_deviation_n integer := 0; v_alert_n integer := 0;
  v_write_res jsonb := NULL; v_confirm_res jsonb := NULL;
  v_remove_violations jsonb := '[]'::jsonb;
  v_disagreement_n integer := 0;
  v_diagnostics jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','stitch_pod_to_boonz',true);
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id=v_user_id AND up.role='operator_admin'
  ) THEN RAISE EXCEPTION 'stitch_pod_to_boonz: caller % lacks operator_admin role', v_user_id; END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pod_refill_plan
                  WHERE plan_date=p_plan_date AND status='approved')
    THEN RAISE EXCEPTION 'no approved rows'; END IF;

  SELECT COUNT(*) INTO v_disagreement_n
    FROM public.pod_refill_plan prp
   WHERE prp.plan_date = p_plan_date
     AND prp.status = 'approved'
     AND (
       (prp.source_origin::text <> 'warehouse'
        AND prp.reasoning->>'source_origin' IS DISTINCT FROM prp.source_origin::text)
       OR
       (prp.source_origin::text = 'warehouse'
        AND prp.reasoning->>'source_origin' IS NOT NULL
        AND prp.reasoning->>'source_origin' <> 'warehouse')
     );
  IF v_disagreement_n > 0 THEN
    RAISE NOTICE 'stitch v12: source_origin column/JSONB disagreement on % rows for plan_date %', v_disagreement_n, p_plan_date;
  END IF;

  DELETE FROM public.refill_plan_deviations WHERE plan_date=p_plan_date;
  DELETE FROM public.procurement_alerts WHERE plan_date=p_plan_date AND acknowledged_at IS NULL;

  WITH approved AS (
    SELECT
      prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action,
      prp.qty, prp.reasoning, prp.status,
      m.official_name AS machine_name,
      sc.shelf_code,
      pp.pod_product_name,
      COALESCE(
        NULLIF(prp.source_origin::text, 'warehouse'),
        prp.reasoning->>'source_origin'
      ) AS source_origin,
      COALESCE(
        (SELECT m2.official_name FROM public.machines m2 WHERE m2.machine_id = prp.from_machine_id),
        prp.reasoning->>'from_machine'
      ) AS from_machine
      FROM public.pod_refill_plan prp
      JOIN public.machines m ON m.machine_id=prp.machine_id
      JOIN public.shelf_configurations sc ON sc.shelf_id=prp.shelf_id
      JOIN public.pod_products pp ON pp.pod_product_id=prp.pod_product_id
     WHERE prp.plan_date=p_plan_date AND prp.status='approved'
  ),
  pull_raw AS (
    SELECT a.plan_date,a.machine_id,a.shelf_id,a.pod_product_id,a.action,
           a.machine_name,a.shelf_code,a.pod_product_name,a.qty AS pod_qty,
           a.source_origin, a.from_machine,
           pm.boonz_product_id,bp.boonz_product_name,pm.split_pct,
           ROW_NUMBER() OVER (
             PARTITION BY a.machine_id,a.shelf_id,a.pod_product_id,pm.boonz_product_id
             ORDER BY (pm.machine_id=a.machine_id) DESC NULLS LAST,
                      pm.is_global_default DESC, pm.boonz_product_id
           ) AS rnk
      FROM approved a
      JOIN public.product_mapping pm
        ON pm.pod_product_id=a.pod_product_id AND pm.status='Active'
       AND (pm.machine_id IS NULL OR pm.machine_id=a.machine_id)
      JOIN public.boonz_products bp ON bp.product_id=pm.boonz_product_id
     WHERE a.action IN ('REFILL','ADD_NEW')
  ),
  pull AS (SELECT * FROM pull_raw WHERE rnk=1),
  pull_norm_pre AS (
    SELECT p.*,
           SUM(COALESCE(p.split_pct,0)) OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS total_split,
           COUNT(*) OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS variant_n
      FROM pull p
  ),
  pull_norm AS (
    SELECT pnp.*,
           CASE WHEN total_split=0 THEN 100.0/variant_n ELSE COALESCE(pnp.split_pct,0) END AS norm_split
      FROM pull_norm_pre pnp
  ),
  pull_base AS (
    SELECT pn.*,
           FLOOR(pod_qty*norm_split/100.0)::int AS base_qty,
           (pod_qty*norm_split/100.0)-FLOOR(pod_qty*norm_split/100.0)::numeric AS remainder_score
      FROM pull_norm pn WHERE norm_split>0
  ),
  pull_slot_rem AS (
    SELECT pb.*, pod_qty - SUM(base_qty) OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id)::int AS slot_remainder
      FROM pull_base pb
  ),
  pull_ranked AS (
    SELECT psr.*, ROW_NUMBER() OVER (
      PARTITION BY plan_date,machine_id,shelf_id,pod_product_id
      ORDER BY remainder_score DESC, norm_split DESC, boonz_product_id
    ) AS rank_remainder FROM pull_slot_rem psr
  ),
  pull_target AS (
    SELECT pr.*, (base_qty + CASE WHEN rank_remainder<=slot_remainder THEN 1 ELSE 0 END)::int AS variant_target
      FROM pull_ranked pr
  ),
  pull_with_wh AS (
    SELECT pt.*,
           COALESCE((SELECT SUM(wi.warehouse_stock)::int FROM public.warehouse_inventory wi
                      WHERE wi.boonz_product_id=pt.boonz_product_id
                        AND wi.status='Active' AND wi.warehouse_stock>0
                        AND wi.quarantined = false), 0) AS wh_avail,
           pt.variant_target::int AS variant_final
      FROM pull_target pt
  ),
  pull_lines AS (
    SELECT plan_date,machine_id,shelf_id,pod_product_id,action,
           machine_name,shelf_code,pod_product_name,
           boonz_product_id,boonz_product_name,norm_split AS split_pct,
           pod_qty,variant_target,variant_final,wh_avail,
           source_origin, from_machine
      FROM pull_with_wh WHERE variant_final>0
  ),
  remove_lines_raw AS (
    SELECT a.plan_date,a.machine_id,a.shelf_id,a.pod_product_id,a.action,
           a.machine_name,a.shelf_code,a.pod_product_name,
           pil.boonz_product_id,bp.boonz_product_name,
           a.qty AS pod_qty,
           pil.current_stock,
           pil.expiration_date,
           a.source_origin, a.from_machine,
           COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id) AS variant_count,
           ROW_NUMBER() OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id
                              ORDER BY pil.expiration_date NULLS LAST, pil.boonz_product_id) AS variant_rank
      FROM approved a
      JOIN public.v_pod_inventory_latest pil
        ON pil.machine_id=a.machine_id AND pil.shelf_id=a.shelf_id AND pil.status='Active'
      JOIN public.boonz_products bp ON bp.product_id=pil.boonz_product_id
     WHERE a.action IN ('REMOVE','M2W')
       AND pil.current_stock>0
       AND EXISTS (
         SELECT 1 FROM public.product_mapping pm
          WHERE pm.boonz_product_id = pil.boonz_product_id
            AND pm.pod_product_id   = a.pod_product_id
            AND pm.status = 'Active'
            AND (pm.machine_id IS NULL OR pm.machine_id = a.machine_id)
       )
  ),
  remove_lines AS (
    SELECT plan_date,machine_id,shelf_id,pod_product_id,action,
           machine_name,shelf_code,pod_product_name,
           boonz_product_id,boonz_product_name,
           NULL::numeric AS split_pct,
           pod_qty,
           NULL::int AS variant_target,
           CASE WHEN source_origin = 'internal_transfer'
             THEN (FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int
                   + CASE WHEN variant_rank <=
                          (pod_qty - FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int * variant_count)
                          THEN 1 ELSE 0 END)::int
             ELSE LEAST(
                   (FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int
                    + CASE WHEN variant_rank <=
                           (pod_qty - FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int * variant_count)
                           THEN 1 ELSE 0 END)::int,
                   current_stock)::int
           END AS variant_final,
           NULL::int AS wh_avail,
           source_origin, from_machine
      FROM remove_lines_raw
  ),
  remove_lines_filtered AS (
    SELECT * FROM remove_lines WHERE variant_final > 0
  ),
  remove_lines_physical_fallback AS (
    SELECT a.plan_date,a.machine_id,a.shelf_id,a.pod_product_id,a.action,
           a.machine_name,a.shelf_code,a.pod_product_name,
           NULL::uuid AS boonz_product_id, a.pod_product_name AS boonz_product_name,
           NULL::numeric AS split_pct,
           a.qty AS pod_qty,
           NULL::int AS variant_target,
           vls.current_stock::int AS variant_final,
           NULL::int AS wh_avail,
           a.source_origin, a.from_machine
      FROM approved a
      JOIN public.v_live_shelf_stock vls
        ON vls.machine_id = a.machine_id
       AND vls.slot_name = LEFT(a.shelf_code,1) || (SUBSTR(a.shelf_code,2)::int)::text
       AND vls.current_stock > 0
     WHERE a.action IN ('REMOVE','M2W')
       AND a.qty > 0                                    -- WS1b: skip qty-0 planned REMOVE (no phantom clear-shelf line)
       AND COALESCE(a.source_origin, 'warehouse') <> 'internal_transfer'
       AND NOT EXISTS (
         SELECT 1 FROM remove_lines_filtered rlf
          WHERE rlf.machine_id = a.machine_id AND rlf.shelf_id = a.shelf_id
            AND rlf.pod_product_id = a.pod_product_id
       )
  ),
  all_lines AS (
    SELECT * FROM pull_lines
    UNION ALL
    SELECT * FROM remove_lines_filtered
    UNION ALL
    SELECT * FROM remove_lines_physical_fallback
  )
  SELECT jsonb_agg(jsonb_build_object(
    'machine_name',machine_name,'machine_priority',0,'shelf_code',shelf_code,
    'pod_product_name',pod_product_name,'boonz_product_name',boonz_product_name,
    'action',CASE action WHEN 'REFILL' THEN 'Refill' WHEN 'ADD_NEW' THEN 'Add New'
                          WHEN 'REMOVE' THEN 'Remove' WHEN 'M2W' THEN 'Machine To Warehouse' END,
    'quantity',variant_final,'current_stock',0,'max_stock',0,
    'smart_target',variant_final,'tier','phase_f_stitch',
    'global_score',NULL,'sold_7d',0,'fill_pct',NULL,
    'comment', CASE
      WHEN source_origin='vox_at_venue'
        THEN '[VOX-SOURCED — do not debit WH] Driver picks at venue from VOX truck'
      WHEN source_origin='internal_transfer' AND from_machine IS NOT NULL
        THEN '[TRUCK-TRANSFER from ' || from_machine || ' — do not debit WH]'
      WHEN source_origin='internal_transfer'
        THEN '[TRUCK-TRANSFER — do not debit WH]'
      WHEN action='REMOVE' AND boonz_product_id IS NULL
        THEN '[PHYSICAL REMOVE — untracked in pod_inventory; clear shelf, no WH credit]'
      WHEN action='M2W' AND boonz_product_id IS NULL
        THEN 'Return to warehouse (untracked stock — no WH credit)'
      WHEN action='M2W'
        THEN 'Return to warehouse (no substitute)'
      WHEN action IN ('REFILL','ADD_NEW') AND COALESCE(wh_avail,0) = 0
        THEN '[WH_STOCK_UNKNOWN — no warehouse rows for this product]'
      WHEN action IN ('REFILL','ADD_NEW') AND wh_avail < variant_final
        THEN '[WH_WARNING — warehouse stock ' || wh_avail::text || ' < planned ' || variant_final::text || ']'
      ELSE NULL
    END
  )) INTO v_lines FROM all_lines;

  v_line_count := COALESCE(jsonb_array_length(v_lines), 0);

  WITH approved AS (
    SELECT prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action, prp.qty,
           m.official_name AS machine_name, sc.shelf_code, pp.pod_product_name
      FROM public.pod_refill_plan prp
      JOIN public.machines m ON m.machine_id=prp.machine_id
      JOIN public.shelf_configurations sc ON sc.shelf_id=prp.shelf_id
      JOIN public.pod_products pp ON pp.pod_product_id=prp.pod_product_id
     WHERE prp.plan_date=p_plan_date AND prp.status='approved'
  ),
  diag AS (
    SELECT a.machine_name, a.shelf_code, a.pod_product_name, a.action, a.qty,
           CASE
             WHEN a.action IN ('REFILL','ADD_NEW') THEN
               CASE
                 WHEN NOT EXISTS (
                   SELECT 1 FROM public.product_mapping pm
                    WHERE pm.pod_product_id = a.pod_product_id
                      AND pm.status = 'Active'
                      AND (pm.machine_id IS NULL OR pm.machine_id = a.machine_id)
                 ) THEN 'no_active_mapping'
                 WHEN COALESCE((SELECT SUM(wi.warehouse_stock)::int FROM public.warehouse_inventory wi
                                JOIN public.product_mapping pm2
                                  ON pm2.boonz_product_id = wi.boonz_product_id
                                 AND pm2.pod_product_id = a.pod_product_id
                                 AND pm2.status = 'Active'
                                 AND (pm2.machine_id IS NULL OR pm2.machine_id = a.machine_id)
                                WHERE wi.status='Active' AND wi.warehouse_stock>0
                                  AND wi.quarantined = false), 0) = 0
                      THEN 'resolved_no_wh_stock_warning'
                 ELSE 'resolved'
               END
             WHEN a.action IN ('REMOVE','M2W') THEN
               CASE
                 WHEN NOT EXISTS (
                   SELECT 1 FROM public.v_pod_inventory_latest pil
                    WHERE pil.machine_id=a.machine_id AND pil.shelf_id=a.shelf_id
                      AND pil.status='Active' AND pil.current_stock>0
                      AND EXISTS (
                        SELECT 1 FROM public.product_mapping pm
                         WHERE pm.boonz_product_id = pil.boonz_product_id
                           AND pm.pod_product_id   = a.pod_product_id
                           AND pm.status = 'Active'
                           AND (pm.machine_id IS NULL OR pm.machine_id = a.machine_id)
                      )
                 ) THEN 'no_inventory_to_remove'
                 ELSE 'resolved'
               END
             ELSE 'unknown_action'
           END AS stitch_result
      FROM approved a
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'machine_name',   diag.machine_name,
    'shelf_code',     diag.shelf_code,
    'pod_product_name', diag.pod_product_name,
    'action',         diag.action,
    'qty',            diag.qty,
    'stitch_result',  diag.stitch_result
  ) ORDER BY diag.machine_name, diag.shelf_code, diag.pod_product_name), '[]'::jsonb)
  INTO v_diagnostics
  FROM diag;

  WITH expected AS (
    SELECT prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.qty AS expected_qty
    FROM public.pod_refill_plan prp
    WHERE prp.plan_date = p_plan_date
      AND prp.status = 'approved'
      AND prp.action IN ('REMOVE','M2W')
      AND COALESCE(
            NULLIF(prp.source_origin::text, 'warehouse'),
            prp.reasoning->>'source_origin'
          ) = 'internal_transfer'
  ),
  actual AS (
    SELECT rl.machine_id, rl.shelf_id, rl.pod_product_id,
           SUM(rl.variant_final)::int AS actual_qty
    FROM (
      SELECT a.machine_id, a.shelf_id, a.pod_product_id, a.action, a.qty,
             pil.boonz_product_id,
             COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id) AS variant_count,
             ROW_NUMBER() OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id
                                ORDER BY pil.expiration_date NULLS LAST, pil.boonz_product_id) AS variant_rank,
             (FLOOR(a.qty::numeric / NULLIF(COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id), 0))::int
              + CASE WHEN ROW_NUMBER() OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id
                                              ORDER BY pil.expiration_date NULLS LAST, pil.boonz_product_id) <=
                     (a.qty - FLOOR(a.qty::numeric / NULLIF(COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id), 0))::int
                              * COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id))
                     THEN 1 ELSE 0 END)::int AS variant_final
      FROM public.pod_refill_plan a
      JOIN public.v_pod_inventory_latest pil
        ON pil.machine_id=a.machine_id AND pil.shelf_id=a.shelf_id AND pil.status='Active'
      WHERE a.plan_date=p_plan_date AND a.status='approved'
        AND a.action IN ('REMOVE','M2W')
        AND COALESCE(
              NULLIF(a.source_origin::text, 'warehouse'),
              a.reasoning->>'source_origin'
            ) = 'internal_transfer'
        AND pil.current_stock > 0
    ) rl
    WHERE rl.variant_final IS NOT NULL AND rl.variant_final > 0
    GROUP BY rl.machine_id, rl.shelf_id, rl.pod_product_id
  )
  SELECT jsonb_agg(jsonb_build_object(
    'machine_id', e.machine_id,
    'shelf_id',   e.shelf_id,
    'pod_product_id', e.pod_product_id,
    'expected_qty', e.expected_qty,
    'actual_qty',   COALESCE(a.actual_qty, 0)
  ))
  INTO v_remove_violations
  FROM expected e
  LEFT JOIN actual a USING (machine_id, shelf_id, pod_product_id)
  WHERE e.expected_qty <> COALESCE(a.actual_qty, 0);

  IF v_remove_violations IS NOT NULL AND jsonb_array_length(v_remove_violations) > 0 THEN
    RAISE EXCEPTION 'stitch invariant violation (v12): REMOVE/M2W internal_transfer fan-out mismatch on % shelf-products: %',
                    jsonb_array_length(v_remove_violations), v_remove_violations;
  END IF;

  WITH approved AS (
    SELECT prp.plan_date,prp.machine_id,prp.shelf_id,prp.pod_product_id,prp.qty
    FROM public.pod_refill_plan prp
    WHERE prp.plan_date=p_plan_date AND prp.status='approved'
      AND prp.action IN ('REFILL','ADD_NEW')
      AND (
        COALESCE(
          NULLIF(prp.source_origin::text, 'warehouse'),
          prp.reasoning->>'source_origin'
        ) IS NULL
        OR COALESCE(
             NULLIF(prp.source_origin::text, 'warehouse'),
             prp.reasoning->>'source_origin'
           ) NOT IN ('internal_transfer','vox_at_venue')
      )
  ),
  m_raw AS (
    SELECT a.plan_date,a.machine_id,a.shelf_id,a.pod_product_id,a.qty AS pod_qty,
           pm.boonz_product_id,pm.split_pct,
           ROW_NUMBER() OVER (
             PARTITION BY a.machine_id,a.shelf_id,a.pod_product_id,pm.boonz_product_id
             ORDER BY (pm.machine_id=a.machine_id) DESC NULLS LAST,
                      pm.is_global_default DESC, pm.boonz_product_id
           ) AS rnk
      FROM approved a JOIN public.product_mapping pm
        ON pm.pod_product_id=a.pod_product_id AND pm.status='Active'
       AND (pm.machine_id IS NULL OR pm.machine_id=a.machine_id)
  ),
  m AS (SELECT * FROM m_raw WHERE rnk=1),
  n_pre AS (
    SELECT m.*, SUM(COALESCE(m.split_pct,0)) OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS total_split,
                COUNT(*) OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS variant_n FROM m
  ),
  n AS (SELECT np.*, CASE WHEN total_split=0 THEN 100.0/variant_n ELSE COALESCE(np.split_pct,0) END AS norm_split FROM n_pre np),
  b AS (
    SELECT n.*, FLOOR(pod_qty*norm_split/100.0)::int AS base_qty,
                (pod_qty*norm_split/100.0)-FLOOR(pod_qty*norm_split/100.0)::numeric AS remainder_score
      FROM n WHERE norm_split>0
  ),
  r AS (SELECT b.*, pod_qty-SUM(base_qty) OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id)::int AS slot_remainder FROM b),
  rk AS (
    SELECT r.*, ROW_NUMBER() OVER (
      PARTITION BY plan_date,machine_id,shelf_id,pod_product_id
      ORDER BY remainder_score DESC, norm_split DESC, boonz_product_id
    ) AS rank_remainder FROM r
  ),
  ex_final AS (
    SELECT rk.*, (base_qty + CASE WHEN rank_remainder<=slot_remainder THEN 1 ELSE 0 END)::int AS variant_target,
           (base_qty + CASE WHEN rank_remainder<=slot_remainder THEN 1 ELSE 0 END)::int AS variant_final
      FROM rk
  ),
  slot_dev AS (
    SELECT machine_id,shelf_id,pod_product_id,
           jsonb_object_agg(boonz_product_id::text,variant_target) AS expected_split,
           jsonb_object_agg(boonz_product_id::text,variant_final)  AS actual_split,
           SUM(variant_target) AS expected_qty, SUM(variant_final) AS actual_qty
      FROM ex_final GROUP BY machine_id,shelf_id,pod_product_id
  )
  INSERT INTO public.refill_plan_deviations(
    plan_date,machine_id,shelf_id,pod_product_id,action,
    pod_qty_target,pod_qty_delivered,expected_split,actual_split,deviation_type,note
  )
  SELECT p_plan_date,sd.machine_id,sd.shelf_id,sd.pod_product_id,'REFILL',
         sd.expected_qty::int,sd.actual_qty::int,
         sd.expected_split,sd.actual_split,'mapping_gap',
         'v12 stitch — WH decoupled; deviation tracks unmapped pod_product fanout only'
    FROM slot_dev sd WHERE sd.expected_qty>sd.actual_qty;
  GET DIAGNOSTICS v_deviation_n = ROW_COUNT;

  WITH pm_per_row AS (
    SELECT DISTINCT ON (prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, pm.boonz_product_id)
           prp.plan_date, prp.machine_id, prp.pod_product_id,
           pm.boonz_product_id,
           prp.qty,
           COALESCE(NULLIF(pm.split_pct, 0), 20)::numeric AS split_pct
    FROM public.pod_refill_plan prp
    JOIN public.product_mapping pm
      ON pm.pod_product_id = prp.pod_product_id
     AND pm.status = 'Active'
     AND (pm.machine_id IS NULL OR pm.machine_id = prp.machine_id)
    WHERE prp.plan_date = p_plan_date
      AND prp.status = 'approved'
      AND prp.action IN ('REFILL','ADD_NEW')
      AND (
        COALESCE(
          NULLIF(prp.source_origin::text, 'warehouse'),
          prp.reasoning->>'source_origin'
        ) IS NULL
        OR COALESCE(
             NULLIF(prp.source_origin::text, 'warehouse'),
             prp.reasoning->>'source_origin'
           ) NOT IN ('internal_transfer','vox_at_venue')
      )
    ORDER BY prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, pm.boonz_product_id,
             (pm.machine_id = prp.machine_id) DESC NULLS LAST,
             pm.is_global_default DESC
  ),
  demand AS (
    SELECT boonz_product_id, pod_product_id,
           SUM(FLOOR(qty * split_pct / 100.0)::int) AS demand_pod_qty,
           COUNT(DISTINCT machine_id) AS affected_machines
    FROM pm_per_row
    GROUP BY boonz_product_id, pod_product_id
  ),
  supply AS (
    SELECT wi.boonz_product_id, SUM(wi.warehouse_stock)::int AS wh_stock_now
    FROM public.warehouse_inventory wi
    WHERE wi.status='Active' AND wi.warehouse_stock>0
      AND wi.quarantined = false
    GROUP BY wi.boonz_product_id
  )
  INSERT INTO public.procurement_alerts(
    plan_date,boonz_product_id,pod_product_id,alert_type,severity,
    wh_stock_now,demand_pod_qty,affected_machines,note
  )
  SELECT p_plan_date,d.boonz_product_id,d.pod_product_id,
         CASE WHEN COALESCE(s.wh_stock_now,0)=0 THEN 'wh_zero' ELSE 'wh_low_vs_demand' END,
         CASE WHEN COALESCE(s.wh_stock_now,0)=0 THEN 'critical'
              WHEN COALESCE(s.wh_stock_now,0)<d.demand_pod_qty/2 THEN 'critical' ELSE 'warning' END,
         COALESCE(s.wh_stock_now,0),d.demand_pod_qty::int,d.affected_machines::int,
         'Generated by Phase F Stage 3 Stitch v12 (informational; WH decoupled from line generation)'
    FROM demand d LEFT JOIN supply s ON s.boonz_product_id=d.boonz_product_id
   WHERE COALESCE(s.wh_stock_now,0)<d.demand_pod_qty AND d.demand_pod_qty>0;
  GET DIAGNOSTICS v_alert_n = ROW_COUNT;

  IF p_dry_run THEN
    v_write_res   := jsonb_build_object('mode','dry_run','lines_would_write', v_line_count);
    v_confirm_res := jsonb_build_object('mode','dry_run','status_unchanged', true);
  ELSE
    v_write_res   := public.write_refill_plan(p_plan_date,v_lines);
    v_confirm_res := public.confirm_stitched_plan(p_plan_date);
  END IF;

  RETURN jsonb_build_object(
    'plan_date',p_plan_date,'dry_run',p_dry_run,
    'engine_version','v15_ws1b_skip_qty0_physical_remove',
    'lines_built',v_line_count,'deviations',v_deviation_n,'procurement_alerts',v_alert_n,
    'source_origin_disagreements', v_disagreement_n,
    'diagnostics', v_diagnostics,
    'write_result',v_write_res,'confirm_result',v_confirm_res,
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int
  );
END;
$function$;
