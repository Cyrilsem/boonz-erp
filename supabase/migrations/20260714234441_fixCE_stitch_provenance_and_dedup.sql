-- fixCE_stitch_provenance_and_dedup
-- Defect C: carry source_origin + from_machine_id through the stitch into refill_plan_output.
-- Defect E: fix action-blind pull_raw dedup collision + never-silent underfill shortfall.
-- Method: transform the LIVE function bodies via exact-match replace() with single-occurrence
-- assertions (byte-identity of untouched regions guaranteed), then EXECUTE. Cody-approved.
DO $mig$
DECLARE
  v_stitch text; v_wrp text; v_old text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_stitch
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE p.proname='stitch_pod_to_boonz' AND n.nspname='public';
  SELECT pg_get_functiondef(p.oid) INTO v_wrp
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE p.proname='write_refill_plan' AND n.nspname='public';
  IF v_stitch IS NULL OR v_wrp IS NULL THEN RAISE EXCEPTION 'source function(s) not found'; END IF;

  -- ============ STITCH C1: emit source_origin + from_machine_id in lines_agg ============
  v_old := $o$'boonz_product_id',al.boonz_product_id,
    'shelf_code',$o$;
  v_new := $n$'boonz_product_id',al.boonz_product_id,
    'source_origin', al.source_origin,
    'from_machine_id', (SELECT m3.machine_id FROM public.machines m3 WHERE m3.official_name = al.from_machine),
    'shelf_code',$n$;
  IF (length(v_stitch)-length(replace(v_stitch,v_old,'')))/length(v_old) <> 1 THEN RAISE EXCEPTION 'stitch C1 occ<>1'; END IF;
  v_stitch := replace(v_stitch,v_old,v_new);

  -- ============ STITCH E1a: deterministic dedup tiebreak (append a.qty DESC) ============
  v_old := $o$                      pm.is_global_default DESC, pm.boonz_product_id
           ) AS rnk
      FROM approved a
      JOIN public.product_mapping pm$o$;
  v_new := $n$                      pm.is_global_default DESC, a.qty DESC, pm.boonz_product_id
           ) AS rnk
      FROM approved a
      JOIN public.product_mapping pm$n$;
  IF (length(v_stitch)-length(replace(v_stitch,v_old,'')))/length(v_old) <> 1 THEN RAISE EXCEPTION 'stitch E1a occ<>1'; END IF;
  v_stitch := replace(v_stitch,v_old,v_new);

  -- ============ STITCH E1b: drop zero-qty noise lines from pull_raw ============
  v_old := $o$     WHERE a.action IN ('REFILL','ADD_NEW')
  ),
  pull AS (SELECT * FROM pull_raw WHERE rnk=1),$o$;
  v_new := $n$     WHERE a.action IN ('REFILL','ADD_NEW')
       AND a.qty > 0
  ),
  pull AS (SELECT * FROM pull_raw WHERE rnk=1),$n$;
  IF (length(v_stitch)-length(replace(v_stitch,v_old,'')))/length(v_old) <> 1 THEN RAISE EXCEPTION 'stitch E1b occ<>1'; END IF;
  v_stitch := replace(v_stitch,v_old,v_new);

  -- ============ STITCH E2a: pull_underfill CTE (never-silent underfill net) ============
  v_old := $o$       AND MAX(residual_pool) > 0
  ),
  lines_agg AS ($o$;
  v_new := $n$       AND MAX(residual_pool) > 0
  ),
  pull_underfill AS (
    SELECT a.plan_date, a.machine_id, a.shelf_id, a.pod_product_id,
           MAX(a.machine_name)     AS machine_name,
           MAX(a.shelf_code)       AS shelf_code,
           MAX(a.pod_product_name) AS pod_product_name,
           SUM(a.qty)::int         AS pod_qty,
           NULL::text              AS donor_names,
           (SUM(a.qty) - COALESCE((SELECT SUM(pl.variant_final) FROM pull_lines pl
              WHERE pl.machine_id=a.machine_id AND pl.shelf_id=a.shelf_id
                AND pl.pod_product_id=a.pod_product_id),0))::int AS unfilled_units,
           'underfilled_vs_pod_plan'::text AS reason
      FROM approved a
     WHERE a.action IN ('REFILL','ADD_NEW')
       AND COALESCE(a.source_origin,'warehouse') = 'warehouse'
     GROUP BY a.plan_date,a.machine_id,a.shelf_id,a.pod_product_id
    HAVING SUM(a.qty) - COALESCE((SELECT SUM(pl.variant_final) FROM pull_lines pl
              WHERE pl.machine_id=a.machine_id AND pl.shelf_id=a.shelf_id
                AND pl.pod_product_id=a.pod_product_id),0) > 0
       AND NOT EXISTS (SELECT 1 FROM pull_unfilled pu
                        WHERE pu.machine_id=a.machine_id AND pu.shelf_id=a.shelf_id
                          AND pu.pod_product_id=a.pod_product_id)
       AND NOT EXISTS (SELECT 1 FROM pull_stockout ps
                        WHERE ps.machine_id=a.machine_id AND ps.shelf_id=a.shelf_id
                          AND ps.pod_product_id=a.pod_product_id)
  ),
  lines_agg AS ($n$;
  IF (length(v_stitch)-length(replace(v_stitch,v_old,'')))/length(v_old) <> 1 THEN RAISE EXCEPTION 'stitch E2a occ<>1'; END IF;
  v_stitch := replace(v_stitch,v_old,v_new);

  -- ============ STITCH E2b: UNION pull_underfill into unfilled_agg source ============
  v_old := $o$      FROM (SELECT * FROM pull_unfilled UNION ALL SELECT * FROM pull_stockout) u$o$;
  v_new := $n$      FROM (SELECT * FROM pull_unfilled UNION ALL SELECT * FROM pull_stockout UNION ALL SELECT * FROM pull_underfill) u$n$;
  IF (length(v_stitch)-length(replace(v_stitch,v_old,'')))/length(v_old) <> 1 THEN RAISE EXCEPTION 'stitch E2b occ<>1'; END IF;
  v_stitch := replace(v_stitch,v_old,v_new);

  -- ============ WRITE_REFILL_PLAN C: add source_origin + from_machine_id columns ============
  v_old := $o$      machine_id, shelf_id, pod_product_id, boonz_product_id
    ) VALUES ($o$;
  v_new := $n$      machine_id, shelf_id, pod_product_id, boonz_product_id,
      source_origin, from_machine_id
    ) VALUES ($n$;
  IF (length(v_wrp)-length(replace(v_wrp,v_old,'')))/length(v_old) <> 1 THEN RAISE EXCEPTION 'wrp W1 occ<>1'; END IF;
  v_wrp := replace(v_wrp,v_old,v_new);

  v_old := $o$        WHERE lower(trim(bp.boonz_product_name)) = lower(trim(line->>'boonz_product_name')) LIMIT 1)
    );$o$;
  v_new := $n$        WHERE lower(trim(bp.boonz_product_name)) = lower(trim(line->>'boonz_product_name')) LIMIT 1),
      COALESCE(NULLIF(line->>'source_origin','')::public.source_origin_enum, 'warehouse'::public.source_origin_enum),
      NULLIF(line->>'from_machine_id','')::uuid
    );$n$;
  IF (length(v_wrp)-length(replace(v_wrp,v_old,'')))/length(v_old) <> 1 THEN RAISE EXCEPTION 'wrp W2 occ<>1'; END IF;
  v_wrp := replace(v_wrp,v_old,v_new);

  -- Apply (check_function_bodies validates both bodies on EXECUTE)
  EXECUTE v_stitch;
  EXECUTE v_wrp;
END
$mig$;
