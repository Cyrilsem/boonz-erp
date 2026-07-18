-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260714003217  name: wh_routing_gap_monitor
-- Warehouse routing-gap monitor: surfaces "right stock, wrong warehouse" gaps.
-- Read-only view + monitoring_alerts summariser (mirrors cron_slot_binding_drift_alert).

CREATE OR REPLACE VIEW public.v_wh_routing_gaps AS
WITH params AS (
  SELECT horizon_days::numeric AS trip_days FROM public.pick_urgency_params LIMIT 1
),
-- one row per live shelf (v_shelf_slot_identity is DISTINCT ON machine_id, shelf_id)
live AS (
  SELECT ssi.machine_id,
         m.official_name           AS machine_official_name,
         ssi.shelf_id,
         ssi.shelf_code,
         ssi.pod_product_id,
         ssi.pod_product_name,
         sc.shelf_size,
         ssi.current_stock,
         ssi.max_stock,
         m.primary_warehouse_id,
         m.secondary_warehouse_id,
         psf.min_refill_qty,
         psf.cap_typical,
         COALESCE(vel.velocity, 0)::numeric AS velocity
  FROM public.v_shelf_slot_identity ssi
  JOIN public.machines m            ON m.machine_id = ssi.machine_id
  JOIN public.shelf_configurations sc ON sc.shelf_id = ssi.shelf_id
  LEFT JOIN public.product_size_fit psf
         ON psf.pod_product_id = ssi.pod_product_id
        AND psf.shelf_size     = sc.shelf_size
  LEFT JOIN LATERAL (
        SELECT COALESCE(sl.velocity_7d, sl.velocity_14d, sl.velocity_30d) AS velocity
        FROM public.slot_lifecycle sl
        WHERE sl.machine_id = ssi.machine_id
          AND sl.shelf_id   = ssi.shelf_id
          AND sl.pod_product_id = ssi.pod_product_id
          AND sl.is_current = true
          AND sl.archived   = false
        ORDER BY sl.last_evaluated_at DESC NULLS LAST
        LIMIT 1
  ) vel ON true
  WHERE ssi.pod_product_id IS NOT NULL
    AND COALESCE(ssi.is_enabled, true) = true
    AND COALESCE(ssi.is_broken, false) = false
    AND m.include_in_refill = true
),
-- shelves below a healthy level; need = units to reach the pod's target fill
starved AS (
  SELECT l.*,
         GREATEST(
           GREATEST(COALESCE(l.cap_typical, l.max_stock, 0), COALESCE(l.min_refill_qty, 0))
             - l.current_stock, 0) AS need_units
  FROM live l, params p
  WHERE (
          (l.min_refill_qty IS NOT NULL AND l.current_stock < l.min_refill_qty)     -- below min refill
          OR (l.velocity > 0 AND l.current_stock < l.velocity * p.trip_days)         -- days-of-cover < a trip
        )
    AND GREATEST(
          GREATEST(COALESCE(l.cap_typical, l.max_stock, 0), COALESCE(l.min_refill_qty, 0))
            - l.current_stock, 0) > 0
),
-- DISTINCT boonz SKU set per pod (never fan out over product_mapping rows)
pod_boonz AS (
  SELECT DISTINCT pod_product_id, boonz_product_id
  FROM public.product_mapping
  WHERE status = 'Active'
),
-- pickable per (pod, warehouse), summed over DISTINCT wh_inventory batches (v_wh_pickable is unique per wh_inventory_id)
pod_wh_pick AS (
  SELECT pb.pod_product_id, wp.warehouse_id, SUM(wp.warehouse_stock) AS pickable
  FROM pod_boonz pb
  JOIN public.v_wh_pickable wp ON wp.boonz_product_id = pb.boonz_product_id
  GROUP BY pb.pod_product_id, wp.warehouse_id
),
-- pickable in the machine's OWN warehouse(s): primary + secondary
own_pick AS (
  SELECT s.machine_id, s.shelf_id, COALESCE(SUM(pwp.pickable), 0) AS own_wh_pickable
  FROM starved s
  LEFT JOIN pod_wh_pick pwp
         ON pwp.pod_product_id = s.pod_product_id
        AND (pwp.warehouse_id = s.primary_warehouse_id
             OR pwp.warehouse_id = s.secondary_warehouse_id)
  GROUP BY s.machine_id, s.shelf_id
),
-- best single OTHER (non-serving) active warehouse holding the pod
other_pick AS (
  SELECT DISTINCT ON (s.machine_id, s.shelf_id)
         s.machine_id, s.shelf_id,
         w.name        AS other_wh_name,
         pwp.pickable  AS other_wh_pickable
  FROM starved s
  JOIN pod_wh_pick pwp
        ON pwp.pod_product_id = s.pod_product_id
       AND pwp.warehouse_id IS DISTINCT FROM s.primary_warehouse_id
       AND pwp.warehouse_id IS DISTINCT FROM s.secondary_warehouse_id
  JOIN public.warehouses w ON w.warehouse_id = pwp.warehouse_id AND w.is_active
  ORDER BY s.machine_id, s.shelf_id, pwp.pickable DESC
)
SELECT s.machine_official_name,
       s.machine_id,
       s.pod_product_id,
       s.pod_product_name,
       s.shelf_code,
       s.need_units,
       op.own_wh_pickable,
       otp.other_wh_name,
       otp.other_wh_pickable,
       LEAST(GREATEST(s.need_units - op.own_wh_pickable, 0), otp.other_wh_pickable) AS suggested_transfer_units,
       s.velocity,
       ROUND(GREATEST(s.need_units - op.own_wh_pickable, 0) * s.velocity, 3)        AS priority
FROM starved s
JOIN own_pick   op  ON op.machine_id  = s.machine_id AND op.shelf_id  = s.shelf_id
JOIN other_pick otp ON otp.machine_id = s.machine_id AND otp.shelf_id = s.shelf_id
WHERE op.own_wh_pickable  < s.need_units        -- own warehouse(s) cannot cover the need
  AND otp.other_wh_pickable >= s.need_units     -- but some OTHER warehouse can
ORDER BY priority DESC, need_units DESC;


CREATE OR REPLACE FUNCTION public.cron_wh_routing_gap_alert()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_n    int;
  v_rows jsonb;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'cron_wh_routing_gap_alert', true);

  SELECT COUNT(*) INTO v_n FROM public.v_wh_routing_gaps;

  IF v_n > 0 THEN
    SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'machine_official_name', machine_official_name,
               'machine_id',            machine_id,
               'pod_product_id',        pod_product_id,
               'pod_product_name',      pod_product_name,
               'shelf_code',            shelf_code,
               'need_units',            need_units,
               'own_wh_pickable',       own_wh_pickable,
               'other_wh_name',         other_wh_name,
               'other_wh_pickable',     other_wh_pickable,
               'suggested_transfer_units', suggested_transfer_units,
               'velocity',              velocity,
               'priority',              priority) AS x
      FROM public.v_wh_routing_gaps
      ORDER BY priority DESC, need_units DESC
      LIMIT 20
    ) t;

    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('wh_routing_gap',
            'warning',
            jsonb_build_object(
              'title', format('%s warehouse routing gap(s): pod starved at machine while >= need units sit pickable in a NON-serving warehouse (right stock, wrong warehouse) -> transfer/rebalance signal', v_n),
              'gap_count',   v_n,
              'top_gaps',    v_rows,
              'detected_by', 'cron_wh_routing_gap_alert',
              'detected_at', now()));
  END IF;

  RETURN jsonb_build_object('status', 'ok', 'routing_gaps', v_n);
END;
$function$;
