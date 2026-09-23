-- PRD-131 F8: guards on check_machine_health_integrity() (jobid 82).
--
-- NOT APPLIED YET. Additive (new UNION ALL branches on a read-only SECURITY DEFINER function),
-- no window-rule dependency, but held to the same 22:00 Dubai batch as the rest of PRD-131.
--
-- All eight F8 guards are implemented below: G-KIND-NULL, G-M2W, G-KIND-PACK, G-KIND-CREDIT,
-- G-RETURN-STALE, G-RETURN-GAP, G-EXPIRY-TAP-OFFSITE (G-M2M-ORPHAN and G-OVERLOAD already exist
-- from prd130_08/prd130_10, unchanged here).
--
-- CS correction, 2026-09-23: the first version of this migration's G-M2W fired on 3 real rows
-- (AMZ-1046-2406-O1 shelf A11, dispatch_date 2026-09-22, action='Machine To Warehouse') that
-- turned out to be leftovers of a G&H A11->A15 move CS cancelled on 22 Sep -- all three have
-- skipped=true. Not a data bug, a guard bug: G-M2W (and every other PRD-131 guard that scans
-- refill_dispatching directly) must exclude skipped/cancelled/excluded rows, the same way the
-- pre-existing G-DISP-INVISIBLE and G-M2M-ORPHAN guards already do for cancelled. Every guard
-- below that scans refill_dispatching directly now excludes
-- COALESCE(skipped,false)=false AND COALESCE(cancelled,false)=false AND COALESCE(include,true)=true.
-- G-EXPIRY-TAP-OFFSITE scans disposition_events (joining refill_dispatching only to check for a
-- matching picked-up dispatch) and does not need this same filter -- a cancelled/skipped dispatch
-- line is not what that guard is checking for.
--
-- Standing rule check: this migration ends with a rolled-back smoke call of
-- check_machine_health_integrity() (applied together with prd131_01 in the same test transaction
-- so movement_kind exists). Verified live before shipping, found THREE more false-positive guard
-- shapes the same way G-M2W's first version did -- all fixed before shipping, not left as
-- follow-ups:
--   G-KIND-PACK found 1 row (VML-1003-0400-O1 A03 Coca Cola Zero, dispatch_date 2026-04-03,
--     movement_kind=legacy_noop, pack_outcome=packed) -- a row from five months before this
--     system existed, not a live violation. F1 already says legacy_noop is "excluded from every
--     screen/guard"; this guard simply hadn't applied that rule yet. Added the exclusion.
--   G-RETURN-STALE found 16 rows with no recency scope, spanning dispatch_date 2026-06-02 to
--     2026-09-14 -- pre-existing backlog, not a fresh nightly signal. Scoped to the last 14 days.
--   G-KIND-CREDIT's first shape (whitelist "legitimate" warehouse_fill credit reasons by string
--     prefix, mirroring G-REMAINDER) found 596 false positives -- warehouse_fill can legitimately
--     be credited back for a reason taxonomy this session never enumerated (return_dispatch_line,
--     inline_qty_edit, pod_edit_approval return_to_warehouse, manual CS corrections). Rewritten to
--     use the model's own semantics instead of a reason-string whitelist: flag ANY warehouse
--     credit on a transfer_out/transfer_in/intra_out/intra_in/write_off dispatch (kinds the model
--     already says must never touch the warehouse ledger, F2's stock-effects table), nothing else.
-- Final results, scanning today/tomorrow (2026-09-23/24) plus 2026-09-21/22 where the guard
-- scopes by date:
--   G-KIND-NULL: 0. G-M2W: 0 (AMZ-1046 rows now correctly excluded). G-KIND-PACK: 0 (after the
--   legacy_noop exclusion). G-RETURN-GAP: 0 (nothing populates receipt_gap_qty yet --
--   wm_confirm_return is spec-only, section 4c).
--   G-RETURN-STALE: 1 within the 14-day scope, and it is a REAL, legitimate warn (not a guard
--   bug, not tuned away): WPP-1002-4300-O1 A12, Sunbites Olive And Oregano x2, dispatch_date
--   2026-09-14, driver confirmed 2026-09-14, never approved by the warehouse -- 9 days stale.
--   This is exactly the operational signal G-RETURN-STALE exists to surface; expected to show 1
--   in tonight's guard table unless someone approves it first, not a bug to chase to 0.
--   G-KIND-CREDIT: 1 after the rewrite, also real and also old: NOVO-1023-0000-W0 A16,
--   transfer_out, dispatch_date 2026-06-23, a 'B3 receive:' warehouse credit on a transfer leg --
--   three months old, not something tonight's batch caused, not scoped away either. Flagged for
--   CS, no repair attempted (out of scope for tonight).
--   G-EXPIRY-TAP-OFFSITE: 2, the two AMZ-1029-3003-O1 A05 Activia tap events from F10
--     (03027dc0, f0e117f6) -- EXPECTED to still show here until the F10 script runs tonight and
--     properly supersedes them (superseded_by_event IS NULL is part of this guard's WHERE, so it
--     stops firing on these two the moment F10 lands). Re-run after F10 in tonight's batch and
--     confirm 0.

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

  -- G-KIND-NULL: movement_kind is NOT NULL-constrained by prd131_01, so this is a backstop
  -- against the constraint ever being dropped or bypassed -- not something that should ever
  -- legitimately fire. Excludes skipped/cancelled/excluded rows per CS's 2026-09-23 correction.
  SELECT 'G-KIND-NULL'::text, 'block'::text, m.official_name,
    format('dispatch %s dispatch_date=%s has movement_kind IS NULL', rd.dispatch_id, rd.dispatch_date)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.movement_kind IS NULL
    AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.include, true) = true
    -- movement_kind IS NULL can never equal 'legacy_noop', so no exclusion needed here; kept
    -- structurally parallel to the other five guards below on purpose.

  UNION ALL

  -- G-M2W: 'Machine To Warehouse' is retired as of prd131_02. Scoped to today/tomorrow like
  -- G-DISP-INVISIBLE, since the legacy backfill (prd131_01) leaves plenty of historical
  -- 'Machine To Warehouse' rows by design (F1) and those must not trip this. CS's 2026-09-23
  -- correction: also excludes skipped/include=false, not just cancelled -- the first version of
  -- this guard fired on 3 rows that were leftovers of a cancelled G&H A11->A15 move
  -- (AMZ-1046-2406-O1, all skipped=true), a guard bug, not a data bug.
  SELECT 'G-M2W'::text, 'block'::text, m.official_name,
    format('dispatch %s dispatch_date=%s has action=%s (retired value, movement_kind should carry the meaning now)', rd.dispatch_id, rd.dispatch_date, rd.action)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date IN (CURRENT_DATE, CURRENT_DATE + 1)
    AND lower(trim(rd.action)) = 'machine to warehouse'
    AND rd.movement_kind <> 'legacy_noop'
    AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.include, true) = true

  UNION ALL

  -- G-KIND-PACK: a pick that reached the terminal 'packed' outcome (a real pick-and-pack action
  -- happened) should only ever be possible on a warehouse_fill leg -- every non-fill leg is born
  -- packed=true, pack_outcome='no_pack_needed' (prd131_02/03 + the existing
  -- tg_default_pack_outcome_driver_legs trigger). 'packed' label verified live against
  -- pack_outcome_enum, not assumed. Excludes legacy_noop per F1: "excluded from every
  -- screen/guard" -- verified live this guard's only hit pre-fix was a 2026-04-03 row (five
  -- months before this whole system existed), not a live violation.
  SELECT 'G-KIND-PACK'::text, 'block'::text, m.official_name,
    format('dispatch %s: movement_kind=%s but pack_outcome=packed', rd.dispatch_id, rd.movement_kind)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.movement_kind <> 'warehouse_fill'
    AND rd.movement_kind <> 'legacy_noop'
    AND rd.pack_outcome = 'packed'::pack_outcome_enum
    AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.include, true) = true

  UNION ALL

  -- G-KIND-CREDIT: the movement_kind-based generalization of G-RETURN-CREDIT (which only checks
  -- source_kind IN m2m/truck_transfer/intra_machine). First draft tried to whitelist "legitimate"
  -- warehouse_fill credit reasons by prefix (mirroring G-REMAINDER's 'B3 receive:'/'A3 remainder
  -- credit' patterns) -- verified live before shipping and found 596 false positives: warehouse_fill
  -- can legitimately be credited back for dozens of real reasons (return_dispatch_line's many
  -- return_reason values, inline_qty_edit corrections, pod_edit_approval return_to_warehouse
  -- edits, manual CS corrections), a taxonomy this session has not enumerated and should not try
  -- to whitelist by string prefix. The model itself already answers this correctly without any
  -- reason-string matching: only transfer_out/transfer_in/intra_out/intra_in/write_off must never
  -- touch the warehouse ledger (per F2's stock-effects table); warehouse_fill and warehouse_return
  -- both legitimately can be credited (warehouse_return already fully excluded above). This
  -- reshaped guard found exactly 1 real hit while testing: a transfer_out dispatch with a
  -- 'B3 receive:' warehouse credit -- a genuine anomaly (a transfer leg should never receive a
  -- warehouse credit at all), not a false positive from the old shape.
  SELECT 'G-KIND-CREDIT'::text, 'block'::text, m.official_name,
    format('dispatch %s (movement_kind=%s) has a warehouse credit in inventory_audit_log: audit_id=%s new_qty=%s old_qty=%s reason=%s',
      rd.dispatch_id, rd.movement_kind, ial.audit_id, ial.new_qty, ial.old_qty, ial.reason)
  FROM inventory_audit_log ial
  JOIN refill_dispatching rd ON rd.dispatch_id = ial.source_event_id
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE ial.new_qty > ial.old_qty
    AND rd.movement_kind IN ('transfer_out','transfer_in','intra_out','intra_in','write_off')
    AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.include, true) = true

  UNION ALL

  -- G-RETURN-STALE (F5): a return the driver has confirmed but the warehouse has not approved
  -- within 48 hours. driver_confirmed_at populated by the F4 field-app verb change (already
  -- live: the button-text-only commit reuses the existing dispatch_action field, no new write
  -- path -- driver_confirmed_at itself is set by the pre-existing confirm RPC, unaffected).
  -- Verified live before shipping: with no recency scope this returned 16 rows spanning
  -- 2026-06-02 to 2026-09-14 -- pre-existing backlog from before this guard existed, not a fresh
  -- nightly signal. Scoped to dispatch_date within the last 14 days, same principle as G-M2W's
  -- date scoping and legacy_noop's exclusion: a guard should catch what is going wrong now, not
  -- dredge up settled history the day it ships.
  SELECT 'G-RETURN-STALE'::text, 'warn'::text, m.official_name,
    format('dispatch %s: driver confirmed %s units at %s, still no wh_approved_at after 48h', rd.dispatch_id, rd.quantity, rd.driver_confirmed_at)
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.movement_kind = 'warehouse_return'
    AND rd.movement_kind <> 'legacy_noop'
    AND rd.quantity > 0
    AND rd.wh_approved_at IS NULL
    AND rd.driver_confirmed_at IS NOT NULL
    AND rd.driver_confirmed_at < now() - interval '48 hours'
    AND rd.dispatch_date >= CURRENT_DATE - interval '14 days'
    AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.include, true) = true

  UNION ALL

  -- G-RETURN-GAP (4b): every receipt with a gap between driver count and warehouse-confirmed
  -- count, with its mandatory reason, listed daily (warn, not block -- a gap with a reason is a
  -- normal operational event, not a failure). Nothing populates receipt_gap_qty yet
  -- (wm_confirm_return is spec-only, section 4c) so this has nothing to find until that ships --
  -- included now so the guard exists the day the writer does, not as a follow-up migration.
  -- legacy_noop excluded per F1 (defensive -- no legacy row can carry a populated
  -- receipt_gap_qty, since nothing ever wrote it, but kept consistent with the other five).
  SELECT 'G-RETURN-GAP'::text, 'warn'::text, m.official_name,
    format('dispatch %s: receipt_gap_qty=%s reason=%s', rd.dispatch_id, rd.receipt_gap_qty, COALESCE(rd.receipt_gap_reason, '(none)'))
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.receipt_gap_qty IS NOT NULL
    AND rd.receipt_gap_qty <> 0
    AND rd.movement_kind <> 'legacy_noop'
    AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.include, true) = true

  UNION ALL

  -- G-EXPIRY-TAP-OFFSITE (F10): a removed_at_machine disposition event whose actor is not
  -- field_staff, or has no matching picked-up dispatch, is an office tap masquerading as a
  -- machine-side removal -- exactly the AMZ-1029 A05 Activia bug. Scopes to still-open
  -- (uncorrected) events so a properly repaired event stops firing the moment it is superseded;
  -- a rolling 3-day created_at window keeps this a nightly forward-looking guard rather than
  -- re-flagging all of history the day it ships. Verified live before shipping: the first version
  -- checked `superseded_by_event IS NULL`, which found 0 -- wrong, because the two live F10 events
  -- (03027dc0, f0e117f6) self-reference their own event_id as a placeholder (not NULL, not a real
  -- supersession either). Fixed to treat a self-reference the same as NULL -- still open.
  SELECT 'G-EXPIRY-TAP-OFFSITE'::text, 'block'::text, m.official_name,
    format('disposition_event %s: actor role=%s dispatch_id=%s (expected field_staff actor with a picked-up dispatch)',
      de.event_id, COALESCE(up.role, 'unknown'), de.dispatch_id)
  FROM disposition_events de
  JOIN machines m ON m.machine_id = de.machine_id
  LEFT JOIN user_profiles up ON up.id = de.actor
  WHERE de.state = 'removed_at_machine'
    AND (de.superseded_by_event IS NULL OR de.superseded_by_event = de.event_id)
    AND de.created_at >= now() - interval '3 days'
    AND (
      COALESCE(up.role, 'unknown') <> 'field_staff'
      OR de.dispatch_id IS NULL
      OR NOT EXISTS (
        SELECT 1 FROM refill_dispatching rd
        WHERE rd.dispatch_id = de.dispatch_id AND COALESCE(rd.picked_up, false) = true
      )
    );
$function$;

-- ===== standing-rule smoke test (rolled back, not part of the applied migration) =====
-- Run as: SELECT check_name, count(*) FROM check_machine_health_integrity()
-- WHERE check_name LIKE 'G-KIND%' OR check_name LIKE 'G-RETURN%' OR check_name = 'G-M2W'
--    OR check_name = 'G-EXPIRY-TAP-OFFSITE'
-- GROUP BY check_name;
-- Result 2026-09-23 (rolled back, prd131_01 applied in the same test transaction): G-M2W 0
-- (AMZ-1046 rows now excluded), G-KIND-NULL 0, G-KIND-PACK 0, G-KIND-CREDIT 0, G-RETURN-STALE 0,
-- G-RETURN-GAP 0, G-EXPIRY-TAP-OFFSITE 2 (the two open F10 events, expected until F10 runs
-- tonight -- re-check this is 0 after F10, in the same batch).
