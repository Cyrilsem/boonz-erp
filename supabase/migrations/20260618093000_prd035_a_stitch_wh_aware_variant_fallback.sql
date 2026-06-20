-- PRD-035 Phase A (WS-C) - flavor-aware stitch: WH-aware sibling fallback, no silent 0-fills.
-- phaseF_stitch_wh_aware_variant_fallback
--
-- BUG (confirmed bug_stitch_onshelf_variant_silent_drop): stitch_pod_to_boonz v23 REFILL line-builder
-- only admits a variant as residual when on_shelf=true once any mapped variant is on the shelf
-- (shelf_has_known_variant). If the on-shelf flavor has 0 pickable WH, the line drops to 0 boonz output
-- at pull_lines (variant_final>0 AND wh_avail=0 AND source='warehouse' => filtered out). The
-- procurement_alerts CTE uses raw split x WH (ignores on_shelf) so it never agrees with the line-builder
-- -> silent 0-fill. Hit Red Bull / Healthy Cola / Hunter for 2026-06-18.
--
-- FIX (priority order CS set: right-qty+right-SKU > right-qty via sibling > empty):
--   1. Compute per-variant WH availability (wh_avail_variant) BEFORE residual selection
--      (same measure the existing line-builder uses: status='Active', warehouse_stock>0, quarantined=false).
--   2. Residual-variant selection becomes WH-aware for REFILL warehouse-sourced lines:
--        - has_onshelf_wh => keep on-shelf variants (UNCHANGED behaviour).
--        - NOT has_onshelf_wh => FALL BACK to in-stock siblings of the same pod (wh_avail_variant>0),
--          and exclude the OOS on-shelf variant so the whole residual pool lands on the sibling
--          (keeps quantity + pod visual). If no sibling has WH either => empty shelf (worst case,
--          still alerted by the existing wh_zero path).
--   3. Every sibling-fallback line is flagged (is_sibling_fallback) and carries the dropped ideal
--      flavour name(s) -> a dispatch comment names the substitution, and a procurement_alert
--      ('variant_substituted') is raised from the SAME emitted line set so the line-builder and
--      alert-builder can never disagree.
--
-- Non-warehouse (internal_transfer / vox_at_venue) and ADD_NEW paths are UNCHANGED (WH is not the
-- gating constraint there). Only the documented REFILL-warehouse on-shelf-OOS branch changes behaviour.
--
-- Forward-only CREATE OR REPLACE. SECURITY DEFINER writer: sets app.via_rpc + app.rpc_name, validates
-- operator_admin role, hits the existing audit path via write_refill_plan/confirm_stitched_plan. No
-- deletes of plan rows; supersede-only semantics preserved (write_refill_plan re-emits pending rows).

-- PRD-035 WS-C: procurement_alerts.alert_type gains 'variant_substituted' so the sibling-fallback
-- alert (raised from the emitted line set) is accepted. procurement_alerts is non-protected; this is a
-- forward, additive extension of the existing CHECK (no value removed). Idempotent.
ALTER TABLE public.procurement_alerts DROP CONSTRAINT IF EXISTS procurement_alerts_alert_type_check;
ALTER TABLE public.procurement_alerts ADD CONSTRAINT procurement_alerts_alert_type_check
  CHECK (alert_type = ANY (ARRAY['wh_zero','wh_low_vs_demand','split_deviation','category_starved','variant_substituted']));

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
  v_subs_alert_n integer := 0;
  v_write_res jsonb := NULL; v_confirm_res jsonb := NULL;
  v_remove_violations jsonb := '[]'::jsonb;
  v_disagreement_n integer := 0;
  v_diagnostics jsonb := '[]'::jsonb;
  v_noncanon_shelf_n integer := 0;
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

  SELECT COUNT(*) INTO v_noncanon_shelf_n
    FROM public.pod_refill_plan prp
    JOIN public.shelf_configurations sc ON sc.shelf_id = prp.shelf_id
   WHERE prp.plan_date = p_plan_date
     AND prp.status = 'approved'
     AND COALESCE(sc.shelf_code,'') !~ '^[A-E][0-9]{2}$';
  IF v_noncanon_shelf_n > 0 THEN
    RAISE NOTICE 'stitch v19 shelfguard: % approved shelf_code(s) were non-canonical and were normalised on emit for plan_date %', v_noncanon_shelf_n, p_plan_date;
  END IF;

  DELETE FROM public.refill_plan_deviations WHERE plan_date=p_plan_date;
  DELETE FROM public.procurement_alerts WHERE plan_date=p_plan_date AND acknowledged_at IS NULL;

  WITH
  driver_overlay AS (
    SELECT machine_id, pod_product_id, boonz_product_id, SUM(COALESCE(qty,0))::int AS driver_qty
    FROM public.resolve_driver_intent(p_plan_date, NULL)
    WHERE resolved AND pod_product_id IS NOT NULL AND boonz_product_id IS NOT NULL AND COALESCE(qty,0) > 0
    GROUP BY machine_id, pod_product_id, boonz_product_id
  ),
  approved AS (
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
           pm.boonz_product_id,bp.boonz_product_name,pm.split_pct AS split_pct,
           (EXISTS (SELECT 1 FROM public.v_pod_inventory_latest pil
                      WHERE pil.machine_id=a.machine_id AND pil.shelf_id=a.shelf_id
                        AND pil.status='Active' AND pil.boonz_product_id=pm.boonz_product_id)) AS on_shelf,
           ROW_NUMBER() OVER (
             PARTITION BY a.machine_id,a.shelf_id,a.pod_product_id,pm.boonz_product_id
             ORDER BY (pm.machine_id=a.machine_id) DESC NULLS LAST,
                      pm.is_global_default DESC, pm.boonz_product_id
           ) AS rnk
      FROM approved a
      JOIN public.product_mapping pm
        ON pm.pod_product_id=a.pod_product_id AND pm.status='Active'
       AND ( pm.machine_id = a.machine_id
          OR (pm.machine_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.product_mapping pms
                              WHERE pms.pod_product_id = a.pod_product_id
                                AND pms.machine_id     = a.machine_id
                                AND pms.status = 'Active')) )
      JOIN public.boonz_products bp ON bp.product_id=pm.boonz_product_id
     WHERE a.action IN ('REFILL','ADD_NEW')
  ),
  pull AS (SELECT * FROM pull_raw WHERE rnk=1),
  pull_variants AS (
    SELECT p.plan_date,p.machine_id,p.shelf_id,p.pod_product_id,p.action,
           p.machine_name,p.shelf_code,p.pod_product_name,p.pod_qty,
           p.source_origin,p.from_machine,
           p.boonz_product_id,p.boonz_product_name,p.split_pct,p.on_shelf
      FROM pull p
    UNION ALL
    SELECT a.plan_date,a.machine_id,a.shelf_id,a.pod_product_id,a.action,
           a.machine_name,a.shelf_code,a.pod_product_name,a.qty AS pod_qty,
           a.source_origin,a.from_machine,
           do2.boonz_product_id,
           bp.boonz_product_name,
           0::numeric AS split_pct,
           true AS on_shelf
      FROM approved a
      JOIN driver_overlay do2
        ON do2.machine_id = a.machine_id
       AND do2.pod_product_id = a.pod_product_id
      JOIN public.boonz_products bp ON bp.product_id = do2.boonz_product_id
     WHERE a.action IN ('REFILL','ADD_NEW')
       AND NOT EXISTS (
         SELECT 1 FROM pull p2
          WHERE p2.machine_id = a.machine_id
            AND p2.shelf_id   = a.shelf_id
            AND p2.pod_product_id = a.pod_product_id
            AND p2.boonz_product_id = do2.boonz_product_id
       )
  ),
  pull_overlaid AS (
    SELECT pv.*,
           COALESCE(do3.driver_qty, 0) AS driver_qty_raw,
           (do3.boonz_product_id IS NOT NULL) AS is_driver_variant,
           EXISTS (
             SELECT 1 FROM driver_overlay do4
              WHERE do4.machine_id = pv.machine_id
                AND do4.pod_product_id = pv.pod_product_id
           ) AS is_overlay_pod,
           -- PRD-035 WS-C: per-variant warehouse availability, same measure the line-builder uses
           -- downstream (status Active, stock>0, not quarantined). Computed here so residual-variant
           -- selection can be WH-aware and fall back to in-stock siblings.
           COALESCE((SELECT SUM(wi.warehouse_stock)::int FROM public.warehouse_inventory wi
                      WHERE wi.boonz_product_id = pv.boonz_product_id
                        AND wi.status='Active' AND wi.warehouse_stock>0
                        AND wi.quarantined = false), 0) AS wh_avail_variant
      FROM pull_variants pv
      LEFT JOIN driver_overlay do3
        ON do3.machine_id = pv.machine_id
       AND do3.pod_product_id = pv.pod_product_id
       AND do3.boonz_product_id = pv.boonz_product_id
  ),
  pull_pins AS (
    SELECT po.*,
           CASE WHEN is_driver_variant THEN
             GREATEST(
               LEAST(
                 driver_qty_raw,
                 pod_qty - COALESCE(SUM(driver_qty_raw) FILTER (WHERE is_driver_variant) OVER (
                   PARTITION BY plan_date,machine_id,shelf_id,pod_product_id
                   ORDER BY driver_qty_raw DESC, boonz_product_id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 ), 0)
               ),
               0
             )
           ELSE 0 END AS pin_qty
      FROM pull_overlaid po
  ),
  pull_pins_tot AS (
    SELECT pp.*,
           SUM(pin_qty) OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS total_pinned
      FROM pull_pins pp
  ),
  -- PRD-035 WS-C: partition-level WH flags + the dropped-ideal identity, computed before residual
  -- selection so the sibling-fallback decision and its naming come from one source of truth.
  pull_resid_flags AS (
    SELECT pt.*,
           GREATEST(pod_qty - total_pinned, 0) AS residual_pool,
           bool_or(COALESCE(on_shelf,false) AND action='REFILL')
             OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS shelf_has_known_variant,
           bool_or(COALESCE(on_shelf,false) AND action='REFILL' AND COALESCE(wh_avail_variant,0) > 0)
             OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS has_onshelf_wh,
           string_agg(boonz_product_name, ', ') FILTER (WHERE COALESCE(on_shelf,false) AND action='REFILL')
             OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS onshelf_ideal_names,
           -- PostgreSQL has no min(uuid) aggregate; min over the text form then cast back (deterministic pick).
           (min(boonz_product_id::text) FILTER (WHERE COALESCE(on_shelf,false) AND action='REFILL')
             OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id))::uuid AS onshelf_ideal_boonz_id
      FROM pull_pins_tot pt
  ),
  pull_resid AS (
    SELECT prf.*,
           -- Residual eligibility. Branches 1-4 are IDENTICAL to v23 (on_shelf gating); only the
           -- final ELSE is new: when the on-shelf flavour(s) are all out of WH stock, admit in-stock
           -- siblings (wh_avail_variant>0) instead and drop the OOS on-shelf variant (wh=0) from the pool.
           (pin_qty = 0 AND COALESCE(split_pct,0) > 0) AND (
             CASE
               WHEN action <> 'REFILL' THEN true
               WHEN NOT shelf_has_known_variant THEN true
               WHEN COALESCE(source_origin,'warehouse') <> 'warehouse' THEN COALESCE(on_shelf,false)
               WHEN has_onshelf_wh THEN COALESCE(on_shelf,false)
               ELSE COALESCE(wh_avail_variant,0) > 0
             END
           ) AS is_residual_variant,
           -- Exactly the ELSE-branch residuals: REFILL, warehouse-sourced, shelf has a known on-shelf
           -- variant, none of the on-shelf variants have WH, and THIS variant is an in-stock sibling.
           (pin_qty = 0 AND COALESCE(split_pct,0) > 0
            AND action = 'REFILL'
            AND shelf_has_known_variant
            AND COALESCE(source_origin,'warehouse') = 'warehouse'
            AND NOT has_onshelf_wh
            AND COALESCE(wh_avail_variant,0) > 0) AS is_sibling_fallback
      FROM pull_resid_flags prf
  ),
  pull_norm_pre AS (
    SELECT pr.*,
           SUM(CASE WHEN is_residual_variant THEN COALESCE(pr.split_pct,0) ELSE 0 END)
             OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS total_split,
           COUNT(*) FILTER (WHERE is_residual_variant)
             OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id) AS variant_n
      FROM pull_resid pr
  ),
  pull_norm AS (
    SELECT pnp.*,
           CASE
             WHEN NOT is_residual_variant THEN 0::numeric
             WHEN total_split=0 THEN 1.0/NULLIF(variant_n,0)
             ELSE COALESCE(pnp.split_pct,0)/NULLIF(total_split,0)
           END AS norm_split
      FROM pull_norm_pre pnp
  ),
  pull_base AS (
    SELECT pn.*,
           CASE WHEN is_residual_variant THEN FLOOR(residual_pool*norm_split)::int ELSE 0 END AS base_qty,
           CASE WHEN is_residual_variant
                THEN (residual_pool*norm_split)-FLOOR(residual_pool*norm_split)::numeric
                ELSE 0::numeric END AS remainder_score
      FROM pull_norm pn
     WHERE is_residual_variant OR pin_qty > 0
  ),
  pull_slot_rem AS (
    SELECT pb.*,
           residual_pool
             - SUM(base_qty) FILTER (WHERE is_residual_variant)
                 OVER (PARTITION BY plan_date,machine_id,shelf_id,pod_product_id)::int AS slot_remainder
      FROM pull_base pb
  ),
  pull_ranked AS (
    SELECT psr.*, ROW_NUMBER() OVER (
      PARTITION BY plan_date,machine_id,shelf_id,pod_product_id
      ORDER BY remainder_score DESC, norm_split DESC, boonz_product_id
    ) AS rank_remainder FROM pull_slot_rem psr
  ),
  pull_target AS (
    SELECT pr.*,
           CASE
             WHEN pin_qty > 0 THEN pin_qty
             WHEN is_residual_variant
               THEN (base_qty + CASE WHEN rank_remainder<=slot_remainder THEN 1 ELSE 0 END)
             ELSE 0
           END::int AS variant_target
      FROM pull_ranked pr
  ),
  pull_with_wh AS (
    SELECT pt.*,
           pt.wh_avail_variant AS wh_avail,
           pt.variant_target::int AS variant_final
      FROM pull_target pt
  ),
  pull_lines AS (
    SELECT plan_date,machine_id,shelf_id,pod_product_id,action,
           machine_name,shelf_code,pod_product_name,
           boonz_product_id,boonz_product_name,norm_split AS split_pct,
           pod_qty,variant_target,variant_final,wh_avail,
           source_origin, from_machine,
           is_overlay_pod,
           is_sibling_fallback, onshelf_ideal_names, onshelf_ideal_boonz_id
      FROM pull_with_wh
     WHERE variant_final>0
       AND (COALESCE(wh_avail,0) > 0 OR COALESCE(source_origin,'warehouse') <> 'warehouse')
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
           source_origin, from_machine,
           false AS is_overlay_pod,
           false AS is_sibling_fallback,
           NULL::text AS onshelf_ideal_names,
           NULL::uuid AS onshelf_ideal_boonz_id
      FROM remove_lines_raw
  ),
  remove_lines_filtered AS (
    SELECT * FROM remove_lines WHERE variant_final > 0
  ),
  remove_phys_base AS (
    SELECT a.plan_date,a.machine_id,a.shelf_id,a.pod_product_id,a.action,
           a.machine_name,a.shelf_code,a.pod_product_name,
           a.source_origin, a.from_machine,
           vls.current_stock::int AS phys_stock
      FROM approved a
      JOIN public.v_live_shelf_stock vls
        ON vls.machine_id = a.machine_id
       AND vls.slot_name = LEFT(a.shelf_code,1) || (SUBSTR(a.shelf_code,2)::int)::text
       AND vls.current_stock > 0
     WHERE a.action IN ('REMOVE','M2W')
       AND a.qty > 0
       AND COALESCE(a.source_origin, 'warehouse') <> 'internal_transfer'
       AND NOT EXISTS (
         SELECT 1 FROM remove_lines_filtered rlf
          WHERE rlf.machine_id = a.machine_id AND rlf.shelf_id = a.shelf_id
            AND rlf.pod_product_id = a.pod_product_id
       )
  ),
  remove_phys_map AS (
    SELECT b.plan_date,b.machine_id,b.shelf_id,b.pod_product_id,b.action,
           b.machine_name,b.shelf_code,b.pod_product_name,
           b.source_origin,b.from_machine,b.phys_stock,
           pm.boonz_product_id, bp.boonz_product_name, pm.split_pct AS split_pct,
           ROW_NUMBER() OVER (
             PARTITION BY b.machine_id,b.shelf_id,b.pod_product_id,pm.boonz_product_id
             ORDER BY (pm.machine_id=b.machine_id) DESC NULLS LAST, pm.is_global_default DESC, pm.boonz_product_id
           ) AS rnk
      FROM remove_phys_base b
      JOIN public.product_mapping pm
        ON pm.pod_product_id=b.pod_product_id AND pm.status='Active'
       AND (pm.machine_id IS NULL OR pm.machine_id=b.machine_id)
      JOIN public.boonz_products bp ON bp.product_id=pm.boonz_product_id
  ),
  remove_phys_dedup AS (SELECT * FROM remove_phys_map WHERE rnk=1),
  remove_phys_norm AS (
    SELECT d.*,
           SUM(COALESCE(d.split_pct,0)) OVER (PARTITION BY machine_id,shelf_id,pod_product_id) AS total_split,
           COUNT(*) OVER (PARTITION BY machine_id,shelf_id,pod_product_id) AS variant_n
      FROM remove_phys_dedup d
  ),
  remove_phys_split AS (
    SELECT n.*,
           CASE WHEN total_split=0 THEN 1.0/variant_n ELSE COALESCE(n.split_pct,0)/NULLIF(total_split,0) END AS norm_split
      FROM remove_phys_norm n
  ),
  remove_phys_qty AS (
    SELECT s.*,
           FLOOR(phys_stock*norm_split)::int AS base_qty,
           (phys_stock*norm_split)-FLOOR(phys_stock*norm_split)::numeric AS remainder_score
      FROM remove_phys_split s WHERE norm_split>0
  ),
  remove_phys_rem AS (
    SELECT q.*, phys_stock - SUM(base_qty) OVER (PARTITION BY machine_id,shelf_id,pod_product_id)::int AS slot_remainder
      FROM remove_phys_qty q
  ),
  remove_phys_rank AS (
    SELECT r.*, ROW_NUMBER() OVER (
      PARTITION BY machine_id,shelf_id,pod_product_id
      ORDER BY remainder_score DESC, norm_split DESC, boonz_product_id
    ) AS rank_remainder FROM remove_phys_rem r
  ),
  remove_phys_final AS (
    SELECT plan_date,machine_id,shelf_id,pod_product_id,action,
           machine_name,shelf_code,pod_product_name,
           boonz_product_id, boonz_product_name,
           phys_stock AS pod_qty,
           (base_qty + CASE WHEN rank_remainder<=slot_remainder THEN 1 ELSE 0 END)::int AS variant_final,
           source_origin, from_machine
      FROM remove_phys_rank
  ),
  remove_lines_physical_fallback AS (
    SELECT plan_date,machine_id,shelf_id,pod_product_id,action,
           machine_name,shelf_code,pod_product_name,
           boonz_product_id, boonz_product_name,
           NULL::numeric AS split_pct,
           pod_qty,
           NULL::int AS variant_target,
           variant_final,
           NULL::int AS wh_avail,
           source_origin, from_machine,
           false AS is_overlay_pod,
           false AS is_sibling_fallback,
           NULL::text AS onshelf_ideal_names,
           NULL::uuid AS onshelf_ideal_boonz_id
      FROM remove_phys_final
     WHERE variant_final > 0
  ),
  all_lines AS (
    SELECT * FROM pull_lines
    UNION ALL
    SELECT * FROM remove_lines_filtered
    UNION ALL
    SELECT * FROM remove_lines_physical_fallback
  ),
  shelf_stock AS (
    SELECT vls.machine_id, sc.shelf_id, MAX(vls.current_stock)::int AS current_stock
      FROM public.v_live_shelf_stock vls
      JOIN public.shelf_configurations sc
        ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
       AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
     GROUP BY vls.machine_id, sc.shelf_id
  ),
  shelf_caps AS (
    SELECT sms.shelf_id, MAX(sms.max_stock_weimi)::int AS max_stock
      FROM public.v_shelf_max_stock sms
     GROUP BY sms.shelf_id
  ),
  wh_reservation AS (
    -- PRD-031 WS-5: reserve WH stock as it is allocated across machines so a shared SKU
    -- cannot read "covered" for five machines and pack dry. wh_remaining = wh_avail minus
    -- the variant_final already claimed by higher-ordered warehouse-sourced lines for the
    -- same boonz SKU. Warn-only (no qty cap); BUG-006 at pack time is the physical guard.
    SELECT machine_id AS r_machine_id, shelf_id AS r_shelf_id, pod_product_id AS r_pod_id,
           boonz_product_id AS r_boonz_id, action AS r_action,
           GREATEST(wh_avail - COALESCE(SUM(variant_final) OVER (
             PARTITION BY boonz_product_id
             ORDER BY machine_name, shelf_code, shelf_id, pod_product_id
             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0), 0) AS wh_remaining
      FROM pull_lines
     WHERE COALESCE(source_origin,'warehouse') = 'warehouse'
  )
  SELECT jsonb_agg(jsonb_build_object(
    'machine_name',machine_name,'machine_priority',0,
    'machine_id',al.machine_id,'pod_product_id',al.pod_product_id,'boonz_product_id',al.boonz_product_id,
    'shelf_code',
      CASE
        WHEN shelf_code ~ '^[A-E][0-9]{2}$' THEN shelf_code
        WHEN shelf_code ~ '^[A-E][0-9]+$' THEN LEFT(shelf_code,1) || LPAD(SUBSTR(shelf_code,2), 2, '0')
        ELSE UPPER(LEFT(regexp_replace(shelf_code,'^[01]-',''),1)) || LPAD(NULLIF(regexp_replace(shelf_code,'\D','','g'),''), 2, '0')
      END,
    'pod_product_name',pod_product_name,'boonz_product_name',boonz_product_name,
    'action',CASE action WHEN 'REFILL' THEN 'Refill' WHEN 'ADD_NEW' THEN 'Add New'
                          WHEN 'REMOVE' THEN 'Remove' WHEN 'M2W' THEN 'Machine To Warehouse' END,
    'quantity',variant_final,'current_stock',COALESCE(ss.current_stock,0),'max_stock',COALESCE(cap.max_stock,0),
    'smart_target',variant_final,'tier','phase_f_stitch',
    'global_score',NULL,'sold_7d',0,'fill_pct',NULL,
    'is_sibling_fallback',COALESCE(al.is_sibling_fallback,false),
    'dropped_ideal_names',al.onshelf_ideal_names,
    'dropped_ideal_boonz_id',al.onshelf_ideal_boonz_id,
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
      -- PRD-035 WS-C: sibling-fallback note (takes precedence over the WH-warning branches so the
      -- substitution is always named on the dispatch line). Reaches here only for REFILL warehouse lines.
      WHEN COALESCE(al.is_sibling_fallback,false)
        THEN '[SIBLING-FALLBACK] on-shelf flavor ' || COALESCE(al.onshelf_ideal_names,'(unknown)')
             || ' out of WH stock -> filled with in-stock sibling ' || boonz_product_name
      WHEN action IN ('REFILL','ADD_NEW') AND is_overlay_pod AND COALESCE(wh_avail,0) = 0
        THEN '[DRIVER-SKU-OVERLAY] [WH_STOCK_UNKNOWN — no warehouse rows for this product]'
      WHEN action IN ('REFILL','ADD_NEW') AND is_overlay_pod AND COALESCE(wr.wh_remaining, wh_avail) < variant_final
        THEN '[DRIVER-SKU-OVERLAY] [WH_WARNING — reserved WH ' || COALESCE(wr.wh_remaining, wh_avail)::text || ' < planned ' || variant_final::text || ']'
      WHEN action IN ('REFILL','ADD_NEW') AND is_overlay_pod
        THEN '[DRIVER-SKU-OVERLAY] driver SKU first-claim; remainder by split_pct'
      WHEN action IN ('REFILL','ADD_NEW') AND COALESCE(wh_avail,0) = 0
        THEN '[WH_STOCK_UNKNOWN — no warehouse rows for this product]'
      WHEN action IN ('REFILL','ADD_NEW') AND COALESCE(wr.wh_remaining, wh_avail) < variant_final
        THEN '[WH_WARNING — reserved WH ' || COALESCE(wr.wh_remaining, wh_avail)::text || ' < planned ' || variant_final::text || ']'
      ELSE NULL
    END
  )) INTO v_lines
  FROM all_lines al
  LEFT JOIN shelf_stock ss ON ss.machine_id = al.machine_id AND ss.shelf_id = al.shelf_id
  LEFT JOIN shelf_caps cap ON cap.shelf_id = al.shelf_id
  LEFT JOIN wh_reservation wr ON wr.r_machine_id = al.machine_id AND wr.r_shelf_id = al.shelf_id
       AND wr.r_pod_id = al.pod_product_id AND wr.r_boonz_id = al.boonz_product_id
       AND wr.r_action = al.action;

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
           pm.boonz_product_id,pm.split_pct AS split_pct,
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
  n AS (SELECT np.*, CASE WHEN total_split=0 THEN 1.0/variant_n ELSE COALESCE(np.split_pct,0)/NULLIF(total_split,0) END AS norm_split FROM n_pre np),
  b AS (
    SELECT n.*, FLOOR(pod_qty*norm_split)::int AS base_qty,
                (pod_qty*norm_split)-FLOOR(pod_qty*norm_split)::numeric AS remainder_score
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
           prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id,
           pm.boonz_product_id,
           prp.qty,
           COALESCE(pm.split_pct, 0)::numeric AS split_pct
    FROM public.pod_refill_plan prp
    JOIN public.product_mapping pm
      ON pm.pod_product_id = prp.pod_product_id
     AND pm.status = 'Active'
     AND ( pm.machine_id = prp.machine_id
        OR (pm.machine_id IS NULL
            AND NOT EXISTS (SELECT 1 FROM public.product_mapping pms
                            WHERE pms.pod_product_id = prp.pod_product_id
                              AND pms.machine_id     = prp.machine_id
                              AND pms.status = 'Active')) )
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
  pm_norm AS (
    SELECT p.*,
           SUM(split_pct) OVER (PARTITION BY plan_date, machine_id, shelf_id, pod_product_id) AS total_split,
           COUNT(*)       OVER (PARTITION BY plan_date, machine_id, shelf_id, pod_product_id) AS variant_n
    FROM pm_per_row p
  ),
  demand AS (
    SELECT boonz_product_id, pod_product_id,
           SUM(FLOOR(qty * CASE WHEN total_split = 0 THEN 1.0/NULLIF(variant_n,0)
                                ELSE split_pct/NULLIF(total_split,0) END)::int) AS demand_pod_qty,
           COUNT(DISTINCT machine_id) AS affected_machines
    FROM pm_norm
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

  -- PRD-035 WS-C: substitution alerts derived from the SAME emitted line set (v_lines) so the
  -- line-builder and alert-builder can never disagree. Every sibling-fallback line yields a
  -- 'variant_substituted' alert naming the dropped on-shelf ideal flavour and the substitute.
  WITH subs AS (
    SELECT (r->>'machine_id')::uuid                 AS machine_id,
           (r->>'pod_product_id')::uuid             AS pod_product_id,
           NULLIF(r->>'dropped_ideal_boonz_id','')::uuid AS ideal_boonz_id,
           r->>'dropped_ideal_names'                AS ideal_names,
           r->>'boonz_product_name'                 AS sub_name,
           (r->>'quantity')::int                    AS qty
      FROM jsonb_array_elements(COALESCE(v_lines,'[]'::jsonb)) r
     WHERE COALESCE((r->>'is_sibling_fallback')::boolean, false)
       AND NULLIF(r->>'dropped_ideal_boonz_id','') IS NOT NULL
  ),
  subs_g AS (
    SELECT pod_product_id, ideal_boonz_id,
           max(ideal_names)                         AS ideal_names,
           string_agg(DISTINCT sub_name, ', ')      AS sub_names,
           SUM(qty)::int                            AS total_qty,
           COUNT(DISTINCT machine_id)::int          AS affected_machines
      FROM subs
     GROUP BY pod_product_id, ideal_boonz_id
  )
  INSERT INTO public.procurement_alerts(
    plan_date,boonz_product_id,pod_product_id,alert_type,severity,
    wh_stock_now,demand_pod_qty,affected_machines,note
  )
  SELECT p_plan_date, sg.ideal_boonz_id, sg.pod_product_id, 'variant_substituted', 'warning',
         0, sg.total_qty, sg.affected_machines,
         'Stitch v24 WS-C sibling fallback: on-shelf flavor ' || COALESCE(sg.ideal_names,'(unknown)')
         || ' out of WH stock; filled ' || sg.total_qty::text || ' unit(s) with in-stock sibling(s) '
         || COALESCE(sg.sub_names,'(unknown)')
    FROM subs_g sg;
  GET DIAGNOSTICS v_subs_alert_n = ROW_COUNT;

  IF p_dry_run THEN
    v_write_res   := jsonb_build_object('mode','dry_run','lines_would_write', v_line_count);
    v_confirm_res := jsonb_build_object('mode','dry_run','status_unchanged', true);
  ELSE
    v_write_res   := public.write_refill_plan(p_plan_date,v_lines);
    IF COALESCE(v_write_res->>'status','') = 'ok' THEN
      v_confirm_res := public.confirm_stitched_plan(p_plan_date);
    ELSE
      v_confirm_res := jsonb_build_object(
        'status','skipped_write_failed',
        'reason','write_refill_plan did not return ok; pod plan NOT confirmed to prevent phantom stitched + empty dispatch',
        'write_status', v_write_res->>'status');
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'plan_date',p_plan_date,'dry_run',p_dry_run,
    'engine_version','v24_wh_aware_variant_fallback',
    'lines_built',v_line_count,'deviations',v_deviation_n,'procurement_alerts',v_alert_n,
    'substitution_alerts', v_subs_alert_n,
    'source_origin_disagreements', v_disagreement_n,
    'noncanonical_shelf_codes', v_noncanon_shelf_n,
    'diagnostics', v_diagnostics,
    'write_result',v_write_res,'confirm_result',v_confirm_res,
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int
  );
END;
$function$;
