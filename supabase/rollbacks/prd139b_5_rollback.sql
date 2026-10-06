-- Rollback for 20261006062029_prd139b_5_v_machine_pack_status.sql: restores both
-- views to their exact pre-fix definitions (fetched via pg_get_viewdef before any
-- edit). Reintroduces the vacuous-completion bug for total_included/packable_n = 0
-- and the pack_state NOOK case -- only use this if the fix caused a real regression.

CREATE OR REPLACE VIEW public.v_dispatch_pack_progress AS
 WITH base AS (
         SELECT rd.*,
            rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text, 'Add'::text]) AS is_packable
           FROM refill_dispatching rd
          WHERE COALESCE(rd.cancelled, false) = false AND COALESCE(rd.include, true) = true
        ), orphan_legs AS (
         SELECT b.machine_id, b.dispatch_date,
            jsonb_agg(jsonb_build_object('dispatch_id', b.dispatch_id, 'shelf_id', b.shelf_id, 'boonz_product_id', b.boonz_product_id, 'quantity', b.quantity, 'reason', 'orphaned_swap_leg', 'proposed_action', 'skip') ORDER BY b.shelf_id, b.dispatch_id) AS legs
           FROM base b
          WHERE b.action = 'Remove'::text AND COALESCE(b.skipped, false) = false AND b.shelf_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM base a_1
                  WHERE a_1.machine_id = b.machine_id AND a_1.dispatch_date = b.dispatch_date AND a_1.shelf_id = b.shelf_id AND (a_1.action = ANY (ARRAY['Add New'::text, 'Add'::text])))) AND NOT (EXISTS ( SELECT 1
                   FROM base a_1
                  WHERE a_1.machine_id = b.machine_id AND a_1.dispatch_date = b.dispatch_date AND a_1.shelf_id = b.shelf_id AND (a_1.action = ANY (ARRAY['Add New'::text, 'Add'::text])) AND COALESCE(a_1.skipped, false) = false AND a_1.pack_outcome IS DISTINCT FROM 'not_filled'::pack_outcome_enum))
          GROUP BY b.machine_id, b.dispatch_date
        ), agg AS (
         SELECT b.machine_id, b.dispatch_date,
            count(*) AS total_included,
            count(*) FILTER (WHERE b.is_packable) AS packable_n,
            count(*) FILTER (WHERE b.is_packable AND (b.packed OR b.skipped OR b.pack_outcome = 'not_filled'::pack_outcome_enum)) AS resolved_n,
            count(*) FILTER (WHERE NOT b.is_packable) AS driver_action_n,
            count(*) FILTER (WHERE b.pack_outcome = 'not_filled'::pack_outcome_enum) AS not_filled_n,
            count(*) FILTER (WHERE b.pack_outcome = 'partial'::pack_outcome_enum) AS partial_n,
            count(*) FILTER (WHERE b.pack_outcome = 'no_pack_needed'::pack_outcome_enum) AS no_pack_needed_n,
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
     JOIN machines m ON m.machine_id = a.machine_id
     LEFT JOIN orphan_legs o ON o.machine_id = a.machine_id AND o.dispatch_date = a.dispatch_date;

CREATE OR REPLACE VIEW public.v_machine_pack_status AS
 WITH lines AS (
         SELECT rd.machine_id, rd.dispatch_date,
            count(*) FILTER (WHERE COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS total_included,
            count(*) FILTER (WHERE COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false) AND (rd.packed OR rd.skipped OR rd.pack_outcome = 'not_filled'::pack_outcome_enum)) AS resolved,
            count(*) FILTER (WHERE rd.packed AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS physical,
            count(*) FILTER (WHERE rd.pack_outcome = 'not_filled'::pack_outcome_enum AND NOT COALESCE(rd.cancelled, false)) AS not_filled,
            count(*) FILTER (WHERE rd.pack_outcome = 'partial'::pack_outcome_enum AND NOT COALESCE(rd.cancelled, false)) AS partial,
            count(*) FILTER (WHERE rd.skipped AND NOT COALESCE(rd.cancelled, false)) AS skipped,
            count(*) FILTER (WHERE rd.packed AND rd.picked_up AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS picked_up_physical,
            count(*) FILTER (WHERE rd.packed AND rd.dispatched AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS dispatched_physical
           FROM refill_dispatching rd
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
     JOIN machines m ON m.machine_id = l.machine_id
     LEFT JOIN dispatch_pack_confirmation c ON c.machine_id = l.machine_id AND c.dispatch_date = l.dispatch_date
     LEFT JOIN v_dispatch_pack_progress p ON p.machine_id = l.machine_id AND p.dispatch_date = l.dispatch_date;
