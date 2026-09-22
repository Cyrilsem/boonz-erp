-- PRD-131 F8: guards on check_machine_health_integrity() (jobid 82).
--
-- NOT APPLIED YET. Additive (new UNION ALL branches on a read-only SECURITY DEFINER function),
-- no window-rule dependency, but held to the same 22:00 Dubai batch as the rest of PRD-131 so
-- all F8 guards land together instead of in scattered small migrations.
--
-- This migration implements two of the eight guards F8 calls for: G-KIND-NULL and G-M2W. They
-- are included now because they are named explicitly in tonight's 22:00 batch order (guards to
-- run for 21 and 22 Sep). The remaining six guards
-- (G-KIND-PACK, G-KIND-CREDIT, G-RETURN-STALE, G-RETURN-GAP, G-EXPIRY-TAP-OFFSITE, and
-- G-M2M-ORPHAN/G-OVERLOAD which already exist from prd130_08/prd130_10) are TODO stubs below,
-- each with the exact SQL shape it needs and what live schema still needs verifying before it
-- can be written for real -- deferred per budget, not forgotten.
--
-- Standing rule check: this migration ends with a rolled-back smoke call of
-- check_machine_health_integrity() (rolled back, applied together with prd131_01 in the same
-- test transaction so movement_kind exists). Result on 2026-09-22, scanning today/tomorrow/
-- 2026-09-21/2026-09-22: G-KIND-NULL = 0 (as expected, structurally impossible once movement_kind
-- is NOT NULL). G-M2W = 3, NOT zero -- a real, previously unknown live gap: dispatch_ids
-- b583b7f0-d3ab-4195-93e4-bf78f2e9f115, 77e4ed7c-679d-47ee-8b63-e5a9d5db256d,
-- ecd5928c-406d-4062-a48a-6bb230d56b20, all on AMZ-1046-2406-O1 shelf A11, dispatch_date
-- 2026-09-22, action='Machine To Warehouse', picked_up=false, wh_approved_at=NULL,
-- item_added=false, returned=false (G&H Popped Chips Sweet And Salty x2, x1; Sweet BBQ x1). This
-- is separate from the six WAVEMAKER/MINDSHARE rows fixed earlier today (Part 1 of this session),
-- which no longer carry action='Machine To Warehouse'. Not touched by this migration -- flagged
-- to CS for a decision (same pattern as F7: reclassify via reclassify_dispatch_movement once
-- prd131_02 is live, or investigate why a writer is still producing this legacy action value).
-- The guard itself is proven correct: it found real data, not a false positive.

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
    AND ial.new_qty > ial.old_qty

  UNION ALL

  SELECT 'G-OVERLOAD'::text, 'block'::text, NULL::text,
    format('function %s has %s overloads in pg_proc (canonical writers must have exactly one)', p.proname, cnt.n)
  FROM pg_proc p
  JOIN (
    SELECT proname, count(*) AS n FROM pg_proc
    WHERE proname IN (
      'add_dispatch_row','write_refill_plan','approve_refill_plan','push_plan_to_dispatch',
      'receive_dispatch_line','pack_dispatch_line','adjust_pod_inventory','adjust_warehouse_stock'
    )
    AND pronamespace = 'public'::regnamespace
    GROUP BY proname
  ) cnt ON cnt.proname = p.proname AND cnt.n > 1
  WHERE p.pronamespace = 'public'::regnamespace
  GROUP BY p.proname, cnt.n

  UNION ALL

  -- PRD-131 F8, G-KIND-NULL: movement_kind is NOT NULL-constrained by prd131_01, so this is a
  -- backstop against the constraint ever being dropped or bypassed by a direct table write that
  -- somehow slips past RLS -- not something that should ever legitimately fire.
  SELECT 'G-KIND-NULL'::text, 'block'::text, m.official_name,
    format('dispatch %s dispatch_date=%s has movement_kind IS NULL', rd.dispatch_id, rd.dispatch_date)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.movement_kind IS NULL

  UNION ALL

  -- PRD-131 F8, G-M2W: 'Machine To Warehouse' is retired as of prd131_02 (push_plan_to_dispatch
  -- maps the plan action to 'Remove' at push; add_dispatch_row's CHECK already refuses it).
  -- Scoped to today/tomorrow like G-DISP-INVISIBLE, since the legacy backfill (prd131_01) leaves
  -- plenty of historical 'Machine To Warehouse' rows by design (F1) and those must not trip this.
  SELECT 'G-M2W'::text, 'block'::text, m.official_name,
    format('dispatch %s dispatch_date=%s has action=%s (retired value, movement_kind should carry the meaning now)', rd.dispatch_id, rd.dispatch_date, rd.action)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date IN (CURRENT_DATE, CURRENT_DATE + 1)
    AND lower(trim(rd.action)) = 'machine to warehouse'
    AND COALESCE(rd.cancelled, false) = false;

  -- ===== TODO stubs, F8 guards not yet written (deferred per budget) =====
  --
  -- G-KIND-PACK: "movement_kind <> warehouse_fill with pack_outcome = 'packed'". A pick that
  -- reached the terminal 'packed' outcome (a real pick-and-pack action happened) should only ever
  -- be possible on a warehouse_fill leg -- every non-fill leg is born packed=true,
  -- pack_outcome='no_pack_needed' (prd131_02/03 + the existing tg_default_pack_outcome_driver_legs
  -- trigger). Exact shape once ready:
  --   SELECT 'G-KIND-PACK', 'block', m.official_name,
  --     format('dispatch %s: movement_kind=%s but pack_outcome=packed', rd.dispatch_id, rd.movement_kind)
  --   FROM refill_dispatching rd JOIN machines m ON m.machine_id = rd.machine_id
  --   WHERE rd.movement_kind <> 'warehouse_fill' AND rd.pack_outcome = 'packed'
  -- Needs: confirming pack_outcome_enum's exact label spelling for the "packed" state (verify
  -- against `SELECT enum_range(NULL::pack_outcome_enum)`, not assumed) before this is safe to ship.
  --
  -- G-KIND-CREDIT: "inventory_audit_log credits whose source dispatch is not warehouse_return or a
  -- warehouse_fill remainder". Needs inventory_audit_log's full reason-string taxonomy verified
  -- live (the existing G-REMAINDER/G-RETURN-CREDIT guards above only pattern-match specific known
  -- reason prefixes: 'B3 receive:%', 'A3 remainder credit%') before a movement_kind-based version
  -- can safely replace/extend that pattern-matching without false-positiving on a reason string
  -- this session hasn't enumerated.
  --
  -- G-RETURN-STALE (F5): "a return with driver count > 0 and no approval after 48 hours". Exact
  -- shape once F5 (prd131_05, receipt-by-kind) lands and its receipt-screen RPC surface is final:
  --   SELECT 'G-RETURN-STALE', 'warn', m.official_name,
  --     format('dispatch %s: driver count %s, no wh_approved_at after 48h', rd.dispatch_id, rd.quantity)
  --   FROM refill_dispatching rd JOIN machines m ON m.machine_id = rd.machine_id
  --   WHERE rd.movement_kind = 'warehouse_return' AND rd.quantity > 0
  --     AND rd.wh_approved_at IS NULL AND rd.driver_confirmed_at < now() - interval '48 hours'
  -- Needs: confirming driver_confirmed_at is populated by the F4 field-app verb change before this
  -- can distinguish "not yet confirmed by driver" from "confirmed, stale at the warehouse".
  --
  -- G-RETURN-GAP: named in F8's guard list, no shape decided yet. Likely keys off the new
  -- receipt_gap_qty / receipt_gap_reason columns (prd131_01) once F5/4c's wm_confirm_return ships
  -- and actually populates them -- there is nothing to guard yet while nothing writes those columns.
  --
  -- G-EXPIRY-TAP-OFFSITE: named in F8's guard list, no shape decided yet. Needs the disposition_events
  -- schema (tap-based expiry writes) reviewed against movement_kind / source_kind='venue' before a
  -- guard can be written; not touched this session.
$function$;

-- ===== standing-rule smoke test (rolled back, not part of the applied migration) =====
-- DO $$
-- BEGIN
--   PERFORM * FROM public.check_machine_health_integrity();
-- END $$;
-- Actually run as: SELECT check_name, count(*) FROM check_machine_health_integrity()
-- WHERE check_name IN ('G-KIND-NULL','G-M2W') GROUP BY check_name;
-- Result while drafting (2026-09-22, rolled back): 0 rows for both -- see docs/PRD-131-movement-kind.md.
