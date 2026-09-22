-- PRD-129R step 04. G-AUDIT-STALE returned 145, all warehouse_audit_baseline rows with
-- audit_date=2026-09-14 and counted_units still NULL -- a recount batch opened and never
-- counted. No existing RPC closes/cancels an audit batch (checked pg_proc for
-- %audit%close%/%audit%cancel%/%audit%abandon%, none found). Per CS instruction: do not
-- fabricate counted_units. Adds a real abandonment marker instead of inventing a count.
--
-- close_abandoned_warehouse_audit(p_audit_date, p_reason, p_caller_id): marks every
-- still-uncounted row for that audit_date as abandoned (abandoned_at/by/reason), leaving
-- counted_units NULL (accurate -- it really was never counted) so no downstream reader can
-- mistake this for a real count. G-AUDIT-STALE is updated to exclude abandoned rows, since an
-- abandoned batch is a closed decision, not an open one waiting on staff.

ALTER TABLE public.warehouse_audit_baseline
  ADD COLUMN IF NOT EXISTS abandoned_at timestamptz,
  ADD COLUMN IF NOT EXISTS abandoned_by uuid,
  ADD COLUMN IF NOT EXISTS abandoned_reason text;

CREATE OR REPLACE FUNCTION public.close_abandoned_warehouse_audit(
  p_audit_date date,
  p_reason text,
  p_caller_id uuid DEFAULT NULL::uuid
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_count   int;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'close_abandoned_warehouse_audit: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'close_abandoned_warehouse_audit: p_reason must be at least 10 characters';
  END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','close_abandoned_warehouse_audit', true);
  PERFORM set_config('app.mutation_reason',
    format('PRD-129R step 04: close abandoned audit %s by=%s: %s', p_audit_date, v_user_id, p_reason), true);

  UPDATE public.warehouse_audit_baseline
     SET abandoned_at = now(), abandoned_by = v_user_id, abandoned_reason = p_reason
   WHERE audit_date = p_audit_date
     AND counted_units IS NULL
     AND abandoned_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object('status','ok','audit_date',p_audit_date,'rows_abandoned',v_count,'reason',p_reason);
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_machine_health_integrity()
 RETURNS TABLE(check_name text, severity text, machine_name text, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH health AS MATERIALIZED (
    SELECT * FROM get_machine_health()
  ),
  health_all AS MATERIALIZED (
    SELECT * FROM get_machine_health(true)
  ),
  mp_full AS MATERIALIZED (
    SELECT * FROM v_machine_priority
  ),
  surface AS (
    SELECT g.machine_name, d.field, d.hv, d.cv
    FROM health g
    JOIN machines m ON m.machine_id = g.machine_id AND m.status = 'Active'
    LEFT JOIN mp_full mp ON mp.machine_id = g.machine_id
    CROSS JOIN LATERAL (VALUES
      ('priority_tier', g.priority_tier,
         CASE WHEN NOT COALESCE(m.include_in_refill, true)
                   OR COALESCE(m.status, 'Active') IN ('Warehouse','Inactive') THEN 'excluded'
              WHEN mp.p_tier_aed = 'P1' THEN 'P1_RESTOCK'
              WHEN mp.p_tier_aed = 'P2' THEN 'P2_MAINTAIN'
              ELSE 'skip' END),
      ('urgency_breakdown_sum',
         round(COALESCE((SELECT sum((e->>'aed')::numeric) FROM jsonb_array_elements(g.urgency_breakdown) e), 0), 2)::text,
         round(COALESCE(mp.p_score_aed, 0), 2)::text)
    ) d(field, hv, cv)
  )
  SELECT 'G-REV'::text, 'block'::text, mp.official_name,
    format('daily_revenue_aed=%s vs sales_history_30d_avg=%s (%s pct off)',
      round(mp.daily_revenue_aed,2), round(sh.avg_30d,2),
      round(100 * abs(mp.daily_revenue_aed - sh.avg_30d) / NULLIF(sh.avg_30d,0), 1))
  FROM mp_full mp
  JOIN machines m ON m.machine_id = mp.machine_id AND m.status = 'Active'
  CROSS JOIN LATERAL (
    SELECT COALESCE(SUM(s.paid_amount), 0) / 30.0 AS avg_30d
    FROM sales_history s
    WHERE s.machine_id = mp.machine_id AND s.delivery_status IN ('Success','Successful')
      AND s.transaction_date >= now() - interval '30 days'
  ) sh
  WHERE machine_cohort(m.operating_model, m.service_model) IN ('boonz','vox')
    AND sh.avg_30d > 20
    AND abs(mp.daily_revenue_aed - sh.avg_30d) / NULLIF(sh.avg_30d, 0) > 0.20

  UNION ALL

  SELECT 'G-FANOUT'::text, 'block'::text, NULL::text,
    format('v_lane_grain has %s rows, the price-deduped join has %s', lg.n, lp.n)
  FROM (SELECT count(*) AS n FROM v_lane_grain) lg
  CROSS JOIN (
    SELECT count(*) AS n
    FROM v_lane_grain lg2
    LEFT JOIN (
      SELECT DISTINCT ON (vcf.machine_id, vcf.pod_product_id) vcf.machine_id, vcf.pod_product_id, vcf.effective_price_aed
      FROM v_current_price_filled vcf
      ORDER BY vcf.machine_id, vcf.pod_product_id, vcf.effective_price_aed DESC NULLS LAST
    ) pbp ON pbp.machine_id = lg2.machine_id AND pbp.pod_product_id = lg2.pod_product_id
  ) lp
  WHERE lg.n <> lp.n

  UNION ALL

  SELECT 'G-TIER'::text, 'block'::text, s.machine_name,
    format('health=%s canonical=%s', s.hv, s.cv)
  FROM surface s
  WHERE s.field = 'priority_tier' AND s.hv IS DISTINCT FROM s.cv

  UNION ALL

  SELECT 'G-CHIPS'::text, 'block'::text, s.machine_name,
    format('urgency_breakdown_sum=%s priority_score=%s', s.hv, s.cv)
  FROM surface s
  WHERE s.field = 'urgency_breakdown_sum'
    AND abs(NULLIF(s.hv,'')::numeric - NULLIF(s.cv,'')::numeric) > 0.01

  UNION ALL

  SELECT 'G-LANES'::text, 'warn'::text, g.machine_name,
    format('%s unresolved lane(s)', g.unresolved_lane_count)
  FROM health g
  WHERE g.unresolved_lane_count > 0

  UNION ALL

  SELECT 'G-COHORT'::text, 'block'::text, m.official_name,
    'operating_model/service_model do not resolve to a cohort'::text
  FROM machines m
  WHERE m.status = 'Active' AND machine_cohort(m.operating_model, m.service_model) = 'unclassified'

  UNION ALL

  SELECT 'G-LANE-SALES'::text, 'block'::text, m.official_name,
    format('slot %s (%s): rendered units_sold_7d=0 but v_shelf_sales_identity.units_7d=%s',
      g.slot, g.product, vsi.units_7d)
  FROM machines m
  CROSS JOIN LATERAL public.get_machine_slots_with_expiry(m.official_name) g
  JOIN public.v_shelf_sales_identity vsi
    ON vsi.machine_id = m.machine_id
   AND vsi.pod_product_id = COALESCE(
         (SELECT pa.column2
          FROM (VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid, '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)) pa(column1, column2)
          WHERE pa.column1 = g.pod_product_id),
         g.pod_product_id)
  WHERE m.status = 'Active'
    AND vsi.resolved = true
    AND vsi.units_7d > 0
    AND g.units_sold_7d = 0

  UNION ALL

  SELECT 'G-NAME'::text, 'block'::text, m.official_name,
    format('get_machine_health() [default] machine_name=%s vs machines.official_name=%s', g.machine_name, m.official_name)
  FROM health g
  JOIN machines m ON m.machine_id = g.machine_id
  WHERE g.machine_name IS DISTINCT FROM m.official_name

  UNION ALL

  SELECT 'G-NAME'::text, 'block'::text, m.official_name,
    format('get_machine_health(true) [include_inactive] machine_name=%s vs machines.official_name=%s', g.machine_name, m.official_name)
  FROM health_all g
  JOIN machines m ON m.machine_id = g.machine_id
  WHERE g.machine_name IS DISTINCT FROM m.official_name

  UNION ALL

  SELECT 'G-REMAINDER'::text, 'block'::text, m.official_name,
    format('dispatch %s: credited %s but remainder is %s (quantity=%s filled=%s)',
      rd.dispatch_id, cr.total_credited, GREATEST(COALESCE(rd.quantity,0) - COALESCE(rd.filled_quantity,0), 0),
      rd.quantity, rd.filled_quantity)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  CROSS JOIN LATERAL (
    SELECT COALESCE(SUM(GREATEST(ial.new_qty - ial.old_qty, 0)), 0) AS total_credited
    FROM inventory_audit_log ial
    WHERE ial.source_event_id = rd.dispatch_id
      AND (ial.reason ILIKE 'B3 receive:%' OR ial.reason ILIKE 'A3 remainder credit%')
  ) cr
  WHERE rd.item_added = true
    AND rd.action IN ('Refill','Add New','Add')
    AND NOT COALESCE(rd.is_m2m, false)
    AND NOT COALESCE(rd.returned, false)
    AND cr.total_credited > GREATEST(COALESCE(rd.quantity,0) - COALESCE(rd.filled_quantity,0), 0)

  UNION ALL

  SELECT 'G-AUDIT-STALE'::text, 'warn'::text, NULL::text,
    format('warehouse_audit_baseline %s: boonz_product_id=%s audit_date=%s still has no counted_units after 48+ hours',
      wab.baseline_id, wab.boonz_product_id, wab.audit_date)
  FROM warehouse_audit_baseline wab
  WHERE wab.counted_units IS NULL
    AND wab.abandoned_at IS NULL
    AND wab.audit_date::timestamptz < now() - interval '48 hours'

  UNION ALL

  SELECT 'G-DISP-INVISIBLE'::text, 'block'::text, m.official_name,
    format('dispatch %s dispatch_date=%s created_by_edit=true but dispatched=false', rd.dispatch_id, rd.dispatch_date)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date IN (CURRENT_DATE, CURRENT_DATE + 1)
    AND COALESCE(rd.created_by_edit, false) = true
    AND COALESCE(rd.dispatched, false) = false
    AND COALESCE(rd.cancelled, false) = false

  UNION ALL

  SELECT 'G-M2M-ORPHAN'::text, 'block'::text, m.official_name,
    format('dispatch %s: is_m2m=%s source_kind=%s but m2m_transfer_id is NULL', rd.dispatch_id, rd.is_m2m, rd.source_kind)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE (COALESCE(rd.is_m2m, false) = true OR rd.source_kind IN ('m2m','truck_transfer','intra_machine'))
    AND rd.m2m_transfer_id IS NULL
    AND COALESCE(rd.cancelled, false) = false

  UNION ALL

  SELECT 'G-SPLIT'::text, 'warn'::text, m.official_name,
    format('dispatch %s (child, created_by_edit=true) is packed=false source_kind=wh while a packed sibling exists for the same machine/shelf/product/date', child.dispatch_id)
  FROM refill_dispatching child
  JOIN machines m ON m.machine_id = child.machine_id
  WHERE COALESCE(child.created_by_edit, false) = true
    AND COALESCE(child.packed, false) = false
    AND child.source_kind = 'wh'
    AND COALESCE(child.cancelled, false) = false
    AND EXISTS (
      SELECT 1 FROM refill_dispatching parent
      WHERE parent.dispatch_id <> child.dispatch_id
        AND parent.machine_id = child.machine_id
        AND parent.shelf_id = child.shelf_id
        AND parent.pod_product_id = child.pod_product_id
        AND parent.dispatch_date = child.dispatch_date
        AND COALESCE(parent.packed, false) = true
    )

  UNION ALL

  SELECT 'G-RETURN-CREDIT'::text, 'block'::text, m.official_name,
    format('dispatch %s (source_kind=%s) has a warehouse credit in inventory_audit_log: audit_id=%s new_qty=%s old_qty=%s',
      rd.dispatch_id, rd.source_kind, ial.audit_id, ial.new_qty, ial.old_qty)
  FROM inventory_audit_log ial
  JOIN refill_dispatching rd ON rd.dispatch_id = ial.source_event_id
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.source_kind IN ('m2m','truck_transfer','intra_machine')
    AND ial.new_qty > ial.old_qty;
$function$;
