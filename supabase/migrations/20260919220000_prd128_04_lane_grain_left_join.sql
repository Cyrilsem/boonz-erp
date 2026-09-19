-- PRD-128 step 04: a lane with no v_shelf_sales_identity row (no sales history yet, or the
-- identity resolver hasn't matched it) used to vanish entirely from v_lane_grain because of
-- the inner JOIN. LEFT JOIN plus an outer COALESCE(...,0) on the velocity expression makes it
-- reappear, graded D, with lane_dvel 0 -- exactly the same as a genuinely dead lane, which is
-- the correct treatment (a lane the engine knows nothing about is not a lane to hide).
--
-- Every occurrence of `i.dvel / NULLIF(i.facings, 0)::numeric` is wrapped in an outer
-- COALESCE(...,0) -- this also makes a facings=0 row on a MATCHED identity resolve to 0
-- instead of NULL, a small, harmless side effect of the same fix (previously such a row still
-- graded D via the CASE's ELSE branch, just with lane_dvel=NULL instead of 0). Every other
-- line is byte-for-byte identical to the pre-PRD-128 body (see
-- 20260919211500_prd128_00_rollback_snapshot.sql).

CREATE OR REPLACE VIEW public.v_lane_grain AS
 SELECT vls.machine_id,
    vls.slot_name AS lane_id,
    vls.pod_product_id,
    vls.current_stock,
    vls.max_stock,
    i.dos,
    COALESCE(i.dvel / NULLIF(i.facings, 0)::numeric, 0) AS lane_dvel,
        CASE
            WHEN COALESCE(i.dvel / NULLIF(i.facings, 0)::numeric, 0) >= pp.a_floor THEN 'A'::text
            WHEN COALESCE(i.dvel / NULLIF(i.facings, 0)::numeric, 0) >= pp.b_floor THEN 'B'::text
            WHEN COALESCE(i.dvel / NULLIF(i.facings, 0)::numeric, 0) > 0::numeric THEN 'C'::text
            ELSE 'D'::text
        END AS grade,
        CASE
            WHEN COALESCE(i.dvel / NULLIF(i.facings, 0)::numeric, 0) >= pp.a_floor THEN pp.grade_wt_a
            WHEN COALESCE(i.dvel / NULLIF(i.facings, 0)::numeric, 0) >= pp.b_floor THEN pp.grade_wt_b
            WHEN COALESCE(i.dvel / NULLIF(i.facings, 0)::numeric, 0) > 0::numeric THEN pp.grade_wt_c
            ELSE pp.lane_wt_d
        END AS w,
    vls.current_stock::numeric / NULLIF(vls.max_stock, 0)::numeric AS fill_ratio,
    vls.current_stock = 0 AS is_empty,
    (vls.current_stock::numeric / NULLIF(vls.max_stock, 0)::numeric) > 0::numeric AND (vls.current_stock::numeric / NULLIF(vls.max_stock, 0)::numeric) <= pp.quasi_fill_floor AS is_quasi
   FROM v_live_shelf_stock vls
     LEFT JOIN v_shelf_sales_identity i ON i.machine_id = vls.machine_id AND i.pod_product_id = vls.pod_product_id
     CROSS JOIN pick_urgency_params pp
  WHERE vls.is_enabled AND NOT COALESCE(vls.is_broken, false) AND vls.is_eligible_machine AND vls.pod_product_id IS NOT NULL;
