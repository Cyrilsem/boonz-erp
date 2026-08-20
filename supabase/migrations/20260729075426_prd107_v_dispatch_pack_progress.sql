-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-107 Pack-stage truth, step 3/5. Recovered verbatim via pg_get_viewdef against live prod.
-- Source: docs/prds/PRD-107-EXECUTION-LOG.md Phase 1/3; docs/architecture/MIGRATIONS_REGISTRY.md:685.
-- Canonical pack-close object (Article 16): packable_n (Refill/Add New/Add), resolved_n,
-- driver_action_n, orphaned_swap_legs (shelf-grain, un-skipped Removes whose paired Add
-- New/Add all died as not_filled), ready_to_pack_close. Registered METRICS_REGISTRY row for
-- v_machine_pack_status.is_pack_complete is repointed at this view below so only one
-- pack-readiness object survives (Cody block #1, Article 16).

CREATE OR REPLACE VIEW public.v_dispatch_pack_progress AS
WITH base AS (
  SELECT rd.dispatch_id, rd.machine_id, rd.shelf_id, rd.pod_product_id, rd.boonz_product_id,
         rd.dispatch_date, rd.action, rd.quantity, rd.filled_quantity, rd.expiry_date,
         rd.item_added, rd.dispatched, rd.comment, rd.include, rd.created_at, rd.packed,
         rd.picked_up, rd.returned, rd.return_reason, rd.expiry_warning, rd.from_warehouse_id,
         rd.to_warehouse_id, rd.from_wh_inventory_id, rd.driver_confirmed_qty,
         rd.driver_confirmed_at, rd.driver_confirmed_by, rd.driver_confirmed_breakdown,
         rd.wh_approved_at, rd.wh_approved_by, rd.is_m2m, rd.m2m_partner_id, rd.m2m_transfer_id,
         rd.source_origin, rd.from_machine_id, rd.original_quantity, rd.original_boonz_product_id,
         rd.original_shelf_id, rd.edit_count, rd.last_edited_by, rd.last_edited_by_role,
         rd.last_edited_at, rd.source_kind, rd.source_warehouse_id, rd.source_machine_id,
         rd.created_by_edit, rd.cancelled, rd.cancelled_at, rd.cancelled_by,
         rd.cancellation_reason, rd.pinned_at_plan_time, rd.skipped, rd.skip_reason,
         rd.skipped_at, rd.skipped_by, rd.driver_outcome, rd.driver_outcome_qty,
         rd.driver_outcome_at, rd.driver_outcome_by, rd.pack_outcome, rd.not_filled_reason,
         rd.needs_review, rd.review_reason, rd.review_status, rd.reviewed_by, rd.reviewed_at,
         rd.remainder_credited, rd.m2m_approved_at, rd.bind_fail_reason, rd.bind_fail_at,
         rd.action = ANY (ARRAY['Refill'::text,'Add New'::text,'Add'::text]) AS is_packable
    FROM public.refill_dispatching rd
   WHERE COALESCE(rd.cancelled, false) = false AND COALESCE(rd.include, true) = true
),
orphan_legs AS (
  SELECT b.machine_id, b.dispatch_date,
         jsonb_agg(jsonb_build_object(
           'dispatch_id', b.dispatch_id, 'shelf_id', b.shelf_id,
           'boonz_product_id', b.boonz_product_id, 'quantity', b.quantity,
           'reason', 'orphaned_swap_leg', 'proposed_action', 'skip'
         ) ORDER BY b.shelf_id, b.dispatch_id) AS legs
    FROM base b
   WHERE b.action = 'Remove'::text AND COALESCE(b.skipped, false) = false AND b.shelf_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM base a WHERE a.machine_id = b.machine_id AND a.dispatch_date = b.dispatch_date
                   AND a.shelf_id = b.shelf_id AND a.action = ANY (ARRAY['Add New'::text,'Add'::text]))
     AND NOT EXISTS (SELECT 1 FROM base a WHERE a.machine_id = b.machine_id AND a.dispatch_date = b.dispatch_date
                       AND a.shelf_id = b.shelf_id AND a.action = ANY (ARRAY['Add New'::text,'Add'::text])
                       AND COALESCE(a.skipped, false) = false
                       AND a.pack_outcome IS DISTINCT FROM 'not_filled'::public.pack_outcome_enum)
   GROUP BY b.machine_id, b.dispatch_date
),
agg AS (
  SELECT b.machine_id, b.dispatch_date,
         count(*) AS total_included,
         count(*) FILTER (WHERE b.is_packable) AS packable_n,
         count(*) FILTER (WHERE b.is_packable AND (b.packed OR b.skipped OR b.pack_outcome = 'not_filled'::public.pack_outcome_enum)) AS resolved_n,
         count(*) FILTER (WHERE NOT b.is_packable) AS driver_action_n,
         count(*) FILTER (WHERE b.pack_outcome = 'not_filled'::public.pack_outcome_enum) AS not_filled_n,
         count(*) FILTER (WHERE b.pack_outcome = 'partial'::public.pack_outcome_enum) AS partial_n,
         count(*) FILTER (WHERE b.pack_outcome = 'no_pack_needed'::public.pack_outcome_enum) AS no_pack_needed_n,
         count(*) FILTER (WHERE b.skipped) AS skipped_n
    FROM base b
   GROUP BY b.machine_id, b.dispatch_date
)
SELECT a.machine_id, a.dispatch_date, m.official_name AS machine_name,
       a.total_included, a.packable_n, a.resolved_n, a.driver_action_n, a.not_filled_n,
       a.partial_n, a.no_pack_needed_n, a.skipped_n,
       COALESCE(o.legs, '[]'::jsonb) AS orphaned_swap_legs,
       COALESCE(jsonb_array_length(o.legs), 0) AS orphaned_swap_leg_n,
       a.resolved_n = a.packable_n AS ready_to_pack_close
  FROM agg a
  JOIN public.machines m ON m.machine_id = a.machine_id
  LEFT JOIN orphan_legs o ON o.machine_id = a.machine_id AND o.dispatch_date = a.dispatch_date;

-- Article-16 dedup: v_machine_pack_status.is_pack_complete now reads this view instead of
-- carrying an inline (buggy) resolved/total_included predicate. Recovered verbatim from live prod.
CREATE OR REPLACE VIEW public.v_machine_pack_status AS
WITH lines AS (
  SELECT rd.machine_id, rd.dispatch_date,
         count(*) FILTER (WHERE COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS total_included,
         count(*) FILTER (WHERE COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)
                             AND (rd.packed OR rd.skipped OR rd.pack_outcome = 'not_filled'::public.pack_outcome_enum)) AS resolved,
         count(*) FILTER (WHERE rd.packed AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS physical,
         count(*) FILTER (WHERE rd.pack_outcome = 'not_filled'::public.pack_outcome_enum AND NOT COALESCE(rd.cancelled, false)) AS not_filled,
         count(*) FILTER (WHERE rd.pack_outcome = 'partial'::public.pack_outcome_enum AND NOT COALESCE(rd.cancelled, false)) AS partial,
         count(*) FILTER (WHERE rd.skipped AND NOT COALESCE(rd.cancelled, false)) AS skipped,
         count(*) FILTER (WHERE rd.packed AND rd.picked_up AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS picked_up_physical,
         count(*) FILTER (WHERE rd.packed AND rd.dispatched AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS dispatched_physical
    FROM public.refill_dispatching rd
   GROUP BY rd.machine_id, rd.dispatch_date
)
SELECT l.machine_id, l.dispatch_date, m.official_name AS machine_name,
       l.total_included, l.resolved, l.physical, l.not_filled, l.partial, l.skipped,
       l.picked_up_physical, l.dispatched_physical,
       COALESCE(p.ready_to_pack_close, false) AS is_pack_complete,
       l.picked_up_physical = l.physical AS is_pickup_complete,
       l.dispatched_physical = l.physical AS is_dispatch_complete,
       c.machine_id IS NOT NULL AS pack_confirmed,
       c.confirmed_at, c.confirmed_by,
       COALESCE(c.final, true) AS pack_final,
       CASE
         WHEN c.machine_id IS NULL THEN 'open'::text
         WHEN COALESCE(c.final, true) AND NOT COALESCE(p.ready_to_pack_close, false) THEN 'needs_reconfirm'::text
         WHEN COALESCE(c.final, true) THEN 'completed'::text
         ELSE 'in_progress'::text
       END AS pack_state,
       c.machine_id IS NOT NULL AND COALESCE(c.final, true) AND NOT COALESCE(p.ready_to_pack_close, false) AS needs_reconfirm,
       GREATEST(COALESCE(p.packable_n, 0::bigint) - COALESCE(p.resolved_n, 0::bigint), 0::bigint) AS unresolved_n
  FROM lines l
  JOIN public.machines m ON m.machine_id = l.machine_id
  LEFT JOIN public.dispatch_pack_confirmation c ON c.machine_id = l.machine_id AND c.dispatch_date = l.dispatch_date
  LEFT JOIN public.v_dispatch_pack_progress p ON p.machine_id = l.machine_id AND p.dispatch_date = l.dispatch_date;
