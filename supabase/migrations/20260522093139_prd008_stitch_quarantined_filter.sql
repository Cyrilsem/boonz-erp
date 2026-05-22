-- ============================================================================
-- PRD-008 — Stitch consumes `quarantined=false` filter on WH reads
--
-- Source PRDs:
--   docs/prds/refill-pipeline/PRD-008-refill-plan-shows-phantom-skus.md
--   docs/prds/refill-pipeline/PRD-003-phantom-mcc-wh-inventory.md (AC#6)
--
-- DEPENDS ON: 20260521230813_prd003_wh_inventory_provenance_quarantine.sql
-- (provides the warehouse_inventory.quarantined GENERATED column). CS must
-- apply the PRD-003 scaffolding migration BEFORE this one or the planner
-- will error on the missing column.
--
-- Patches stitch_pod_to_boonz (v11.1) to filter out quarantined warehouse_inventory
-- rows from its 3 WH availability subqueries. After this patch:
--   - Refill plans cannot pick from rows the brain shouldn't trust
--   - PRD-003 AC#6 ("not pickable by refill brain") satisfied for Stitch
--   - PRD-008 AC#2 ("Stitch can never write refill_plan_output line with qty >
--     pickable WH stock") tightened — quarantined rows now correctly excluded
--     from "pickable" computation
--
-- Body retrieved from pg_proc (engine_version 'v11.1_source_origin_column').
-- Only 3 lines added (all `AND wi.quarantined = false`). Function signature
-- and version string unchanged — bumped engine_version to 'v11.2_quarantine_filter'
-- so downstream consumers see the change in returned diagnostics.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.stitch_pod_to_boonz(
  p_plan_date date DEFAULT (CURRENT_DATE + 1),
  p_dry_run boolean DEFAULT true
)
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
    RAISE NOTICE 'stitch v11.2: source_origin column/JSONB disagreement on % rows for plan_date %', v_disagreement_n, p_plan_date;
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
           -- PRD-003/008: quarantined rows excluded from WH availability.
           COALESCE((SELECT SUM(wi.warehouse_stock)::int FROM public.warehouse_inventory wi
                      WHERE wi.boonz_product_id=pt.boonz_product_id
                        AND wi.status='Active' AND wi.warehouse_stock>0
                        AND wi.quarantined = false), 0) AS wh_avail,
           CASE
             WHEN pt.source_origin IN ('internal_transfer','vox_at_venue')
                 THEN pt.variant_target
             ELSE LEAST(pt.variant_target,
                        COALESCE((SELECT SUM(wi.warehouse_stock)::int FROM public.warehouse_inventory wi
                                   WHERE wi.boonz_product_id=pt.boonz_product_id
                                     AND wi.status='Active' AND wi.warehouse_stock>0
                                     AND wi.quarantined = false), 0))::int
           END AS variant_capped
      FROM pull_target pt
  ),
  pull_redistributed AS (
    SELECT pww.*,
           CASE WHEN pww.source_origin IN ('internal_transfer','vox_at_venue')
                THEN 0
                ELSE GREATEST(pww.wh_avail - pww.variant_capped, 0) END::int AS headroom,
           (pod_qty - SUM(variant_capped) OVER (
             PARTITION BY plan_date,machine_id,shelf_id,pod_product_id))::int AS slot_shortfall,
           COALESCE(SUM(
             CASE WHEN pww.source_origin IN ('internal_transfer','vox_at_venue') THEN 0
                  ELSE GREATEST(pww.wh_avail - pww.variant_capped, 0) END
           ) OVER (
             PARTITION BY plan_date,machine_id,shelf_id,pod_product_id
             ORDER BY GREATEST(pww.wh_avail - pww.variant_capped, 0) DESC, pww.boonz_product_id
             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
           ), 0)::int AS prior_cum_headroom
      FROM pull_with_wh pww
  ),
  pull_final AS (
    SELECT pr.*,
           pr.variant_capped + LEAST(
             pr.headroom,
             GREATEST(pr.slot_shortfall - pr.prior_cum_headroom, 0)
           )::int AS variant_final
      FROM pull_redistributed pr
  ),
  pull_lines AS (
    SELECT plan_date,machine_id,shelf_id,pod_product_id,action,
           machine_name,shelf_code,pod_product_name,
           boonz_product_id,boonz_product_name,norm_split AS split_pct,
           pod_qty,variant_target,variant_final,wh_avail,
           source_origin, from_machine
      FROM pull_final WHERE variant_final>0
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
           CASE
             WHEN source_origin='internal_transfer' THEN
               (FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int
                + CASE WHEN variant_rank <=
                       (pod_qty - FLOOR(pod_qty::numeric / NULLIF(variant_count, 0))::int * variant_count)
                       THEN 1 ELSE 0 END)::int
             ELSE
               current_stock::int
           END AS variant_final,
           NULL::int AS wh_avail,
           source_origin, from_machine
      FROM remove_lines_raw
  ),
  remove_lines_filtered AS (
    SELECT * FROM remove_lines WHERE variant_final > 0
  ),
  all_lines AS (
    SELECT * FROM pull_lines
    UNION ALL
    SELECT * FROM remove_lines_filtered
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
      WHEN action='M2W'
        THEN 'Return to warehouse (no substitute)'
      ELSE NULL
    END
  )) INTO v_lines FROM all_lines;

  v_line_count := COALESCE(jsonb_array_length(v_lines), 0);

  -- REMOVE/M2W invariant check (unchanged from v11.1) ----------------------
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
             COALESCE(
               NULLIF(a.source_origin::text, 'warehouse'),
               a.reasoning->>'source_origin'
             ) AS source_origin_resolved,
             pil.boonz_product_id, pil.expiration_date, pil.current_stock,
             COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id) AS variant_count,
             ROW_NUMBER() OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id
                                ORDER BY pil.expiration_date NULLS LAST, pil.boonz_product_id) AS variant_rank,
             CASE
               WHEN COALESCE(
                      NULLIF(a.source_origin::text, 'warehouse'),
                      a.reasoning->>'source_origin'
                    ) = 'internal_transfer' THEN
                 (FLOOR(a.qty::numeric / NULLIF(COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id), 0))::int
                  + CASE WHEN ROW_NUMBER() OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id
                                                  ORDER BY pil.expiration_date NULLS LAST, pil.boonz_product_id) <=
                         (a.qty - FLOOR(a.qty::numeric / NULLIF(COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id), 0))::int
                                  * COUNT(*) OVER (PARTITION BY a.machine_id, a.shelf_id, a.pod_product_id))
                         THEN 1 ELSE 0 END)::int
               ELSE NULL
             END AS variant_final
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
    RAISE EXCEPTION 'stitch invariant violation (v11.2): REMOVE/M2W internal_transfer fan-out mismatch on % shelf-products: %',
                    jsonb_array_length(v_remove_violations), v_remove_violations;
  END IF;

  -- Deviations + procurement alerts -------------------------------------------
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
  ex AS (
    SELECT rk.*, (base_qty + CASE WHEN rank_remainder<=slot_remainder THEN 1 ELSE 0 END)::int AS variant_target,
           -- PRD-003/008: quarantined rows excluded.
           COALESCE((SELECT SUM(wi.warehouse_stock)::int FROM public.warehouse_inventory wi
                      WHERE wi.boonz_product_id=rk.boonz_product_id
                        AND wi.status='Active' AND wi.warehouse_stock>0
                        AND wi.quarantined = false), 0) AS wh_avail FROM rk
  ),
  ex_redist AS (
    SELECT ex.*, LEAST(variant_target, wh_avail)::int AS variant_capped,
           GREATEST(wh_avail - LEAST(variant_target, wh_avail), 0)::int AS headroom,
           (pod_qty - SUM(LEAST(variant_target, wh_avail)) OVER (
             PARTITION BY plan_date,machine_id,shelf_id,pod_product_id))::int AS slot_shortfall,
           COALESCE(SUM(GREATEST(wh_avail - LEAST(variant_target, wh_avail), 0)) OVER (
             PARTITION BY plan_date,machine_id,shelf_id,pod_product_id
             ORDER BY GREATEST(wh_avail - LEAST(variant_target, wh_avail), 0) DESC, boonz_product_id
             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
           ), 0)::int AS prior_cum_headroom
      FROM ex
  ),
  ex_final AS (
    SELECT er.*,
           er.variant_capped + LEAST(er.headroom, GREATEST(er.slot_shortfall - er.prior_cum_headroom, 0))::int AS variant_final
      FROM ex_redist er
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
         sd.expected_split,sd.actual_split,'wh_shortage',
         'v11.2 stitch — WH-sourced rows only, quarantined excluded'
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
    -- PRD-003/008: quarantined rows excluded from procurement-alert supply.
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
         'Generated by Phase F Stage 3 Stitch v11.2 (quarantine-filtered supply)'
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
    'engine_version','v11.2_quarantine_filter',
    'lines_built',v_line_count,'deviations',v_deviation_n,'procurement_alerts',v_alert_n,
    'source_origin_disagreements', v_disagreement_n,
    'write_result',v_write_res,'confirm_result',v_confirm_res,
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int
  );
END;
$function$;

COMMIT;

-- ============================================================================
-- POST-APPLY VERIFICATION
--   SELECT engine_version FROM (...) — the next plan generation should report
--   'v11.2_quarantine_filter' in its result jsonb.
--
--   With the PRD-003 scaffolding applied and all existing rows backfilled to
--   provenance_reason='unknown_pre_migration' (quarantined=true), the next
--   stitch dry run should produce zero plan lines for quarantined-row products
--   AND a procurement_alert for each, surfacing the gap to CS.
--
--   This is the data-foundation transition: brain stops trusting unprovenanced
--   inventory. CS must then unquarantine via adjust_warehouse_stock per the
--   PRD-003 recount workflow.
-- ============================================================================
