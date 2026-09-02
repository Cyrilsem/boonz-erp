-- PRD-119 P1 §4.1/§7: v_wm_confirmations — the single Warehouse Confirmations queue.
-- Today it surfaces the return flow (§7): a Remove-action line that physically left the
-- machine (picked_up) but hasn't been WH-approved yet, excluding genuine in-machine moves
-- and successfully-paired M2M legs. P3 will add driver-tap-originated lines once that
-- writer exists; P4 adds substitution-originated lines once item L ships. This is the
-- Article-16 canonical object both the FE tab and CS's read-only day-close summary read.
--
-- Sentinel handling: 2099-12-31 (the consignment/VOX-sourced placeholder date used
-- throughout the schema, see _is_phantom_wh_row_v3) is normalised to NULL on read so it
-- is never mistaken for a real far-future expiry — caught live during testing: an
-- unpatched version proposed "redeploy" for a 2099-dated row using it as the deadline.
CREATE VIEW public.v_wm_confirmations AS
WITH dubai AS (SELECT (now() AT TIME ZONE 'Asia/Dubai'::text)::date AS today),
candidates AS (
  SELECT rd.dispatch_id, rd.machine_id, rd.shelf_id, rd.boonz_product_id, rd.pod_product_id,
    COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity) AS qty,
    NULLIF(rd.expiry_date, '2099-12-31'::date) AS expiry_date,
    rd.from_wh_inventory_id, rd.dispatch_date,
    COALESCE(rd.driver_confirmed_at, rd.driver_outcome_at, rd.last_edited_at, rd.created_at) AS left_machine_at
  FROM public.refill_dispatching rd CROSS JOIN dubai d
  WHERE rd.action = 'Remove' AND rd.picked_up = true AND rd.wh_approved_at IS NULL
    AND COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity, 0) > 0
    AND COALESCE(rd.returned, false) = false AND COALESCE(rd.item_added, false) = false
    AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.skipped, false) = false
    AND rd.boonz_product_id IS NOT NULL
    AND NOT COALESCE(public.is_internal_move_dispatch(rd.dispatch_id), false)
    AND NOT (COALESCE(rd.is_m2m, false) AND rd.m2m_transfer_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.refill_dispatching paired WHERE paired.m2m_transfer_id = rd.m2m_transfer_id
        AND paired.dispatch_id <> rd.dispatch_id AND paired.action IN ('Refill','Add','Add New')))
),
proposal AS (
  SELECT c.*,
    CASE WHEN c.expiry_date IS NULL OR c.expiry_date <= (SELECT today FROM dubai) THEN true ELSE false END AS expired_or_undated,
    best.target_machine_id, best.daily_rate
  FROM candidates c
  LEFT JOIN LATERAL (
    SELECT sl.machine_id AS target_machine_id, (sl.velocity_30d / 30.0) AS daily_rate
    FROM public.slot_lifecycle sl
    WHERE sl.pod_product_id = c.pod_product_id AND sl.machine_id <> c.machine_id
      AND sl.is_current = true AND sl.archived = false
      AND c.expiry_date IS NOT NULL AND c.expiry_date > (SELECT today FROM dubai)
      AND (sl.velocity_30d / 30.0) >= (c.qty / GREATEST((c.expiry_date - (SELECT today FROM dubai)) - 2, 1))
    ORDER BY sl.velocity_30d DESC LIMIT 1
  ) best ON true
)
SELECT
  p.dispatch_id, p.machine_id, m.official_name AS machine_name, p.shelf_id, sc.shelf_code,
  p.boonz_product_id, bp.boonz_product_name, p.pod_product_id,
  p.qty, p.expiry_date, p.from_wh_inventory_id, p.dispatch_date, p.left_machine_at,
  CASE WHEN p.expired_or_undated THEN 'waste' WHEN p.target_machine_id IS NOT NULL THEN 'redeploy' ELSE 'waste' END AS proposed_outcome,
  p.target_machine_id AS proposed_target_machine_id, tm.official_name AS proposed_target_machine_name,
  CASE WHEN p.target_machine_id IS NOT NULL THEN p.expiry_date - 2 ELSE NULL END AS proposed_waste_by,
  (EXTRACT(EPOCH FROM (now() - COALESCE(p.left_machine_at, now()))) / 3600.0) AS age_hours
FROM proposal p
JOIN public.machines m ON m.machine_id = p.machine_id
LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = p.shelf_id
LEFT JOIN public.boonz_products bp ON bp.product_id = p.boonz_product_id
LEFT JOIN public.machines tm ON tm.machine_id = p.target_machine_id;
