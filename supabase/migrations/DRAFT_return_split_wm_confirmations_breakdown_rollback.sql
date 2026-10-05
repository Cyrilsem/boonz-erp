-- Rollback for DRAFT_return_split_wm_confirmations_breakdown.sql: restore v_wm_confirmations
-- to its exact prior definition (no driver_breakdown column).

CREATE OR REPLACE VIEW public.v_wm_confirmations AS
 WITH dubai AS (
         SELECT ((now() AT TIME ZONE 'Asia/Dubai'::text))::date AS today
        ), dispatch_candidates AS (
         SELECT rd.dispatch_id AS line_id,
            'dispatch_return'::text AS source,
            rd.machine_id,
            rd.shelf_id,
            rd.boonz_product_id,
            rd.pod_product_id,
            COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity) AS qty,
            NULLIF(rd.expiry_date, '2099-12-31'::date) AS expiry_date,
            rd.from_wh_inventory_id,
            rd.dispatch_id,
            rd.dispatch_date,
            COALESCE(rd.driver_confirmed_at, rd.driver_outcome_at, rd.last_edited_at, rd.created_at) AS left_machine_at
           FROM refill_dispatching rd
          WHERE ((rd.action = 'Remove'::text) AND (rd.picked_up = true) AND (rd.wh_approved_at IS NULL) AND (COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity, (0)::numeric) > (0)::numeric) AND (COALESCE(rd.returned, false) = false) AND (COALESCE(rd.item_added, false) = false) AND (COALESCE(rd.cancelled, false) = false) AND (COALESCE(rd.skipped, false) = false) AND (rd.boonz_product_id IS NOT NULL) AND (NOT COALESCE(is_internal_move_dispatch(rd.dispatch_id), false)) AND (NOT (COALESCE(rd.is_m2m, false) AND (rd.m2m_transfer_id IS NOT NULL) AND (EXISTS ( SELECT 1
                   FROM refill_dispatching paired
                  WHERE ((paired.m2m_transfer_id = rd.m2m_transfer_id) AND (paired.dispatch_id <> rd.dispatch_id) AND (paired.action = ANY (ARRAY['Refill'::text, 'Add'::text, 'Add New'::text]))))))))
        ), refill_return_ack_candidates AS (
         SELECT rd.dispatch_id AS line_id,
            'refill_return_ack'::text AS source,
            rd.machine_id,
            rd.shelf_id,
            rd.boonz_product_id,
            rd.pod_product_id,
            rd.quantity AS qty,
            NULLIF(rd.expiry_date, '2099-12-31'::date) AS expiry_date,
            rd.from_wh_inventory_id,
            rd.dispatch_id,
            rd.dispatch_date,
            COALESCE(rd.last_edited_at, rd.created_at) AS left_machine_at
           FROM refill_dispatching rd
          WHERE ((rd.action = ANY (ARRAY['Refill'::text, 'Add'::text, 'Add New'::text])) AND (COALESCE(rd.returned, false) = true) AND (rd.wh_approved_at IS NULL) AND (COALESCE(rd.quantity, (0)::numeric) > (0)::numeric) AND (COALESCE(rd.cancelled, false) = false) AND (rd.boonz_product_id IS NOT NULL))
        ), quarantine_candidates AS (
         SELECT wi.wh_inventory_id AS line_id,
            'quarantine_batch'::text AS source,
            NULL::uuid AS machine_id,
            NULL::uuid AS shelf_id,
            wi.boonz_product_id,
            NULL::uuid AS pod_product_id,
            wi.warehouse_stock AS qty,
            NULLIF(wi.expiration_date, '2099-12-31'::date) AS expiry_date,
            NULL::uuid AS from_wh_inventory_id,
            NULL::uuid AS dispatch_id,
            wi.snapshot_date AS dispatch_date,
            wi.created_at AS left_machine_at
           FROM warehouse_inventory wi
          WHERE ((wi.provenance_reason = 'dispatch_return_unverified'::text) AND (wi.quarantined = true) AND (wi.status = 'Active'::text) AND (COALESCE(wi.warehouse_stock, (0)::numeric) > (0)::numeric))
        ), tap_candidates AS (
         SELECT de.event_id AS line_id,
            de.source,
            de.machine_id,
            de.shelf_id,
            de.boonz_product_id,
            NULL::uuid AS pod_product_id,
            de.qty,
            NULLIF(de.expiration_date, '2099-12-31'::date) AS expiry_date,
            NULL::uuid AS from_wh_inventory_id,
            NULL::uuid AS dispatch_id,
            (de.created_at)::date AS dispatch_date,
            de.created_at AS left_machine_at
           FROM disposition_events de
          WHERE ((de.source = ANY (ARRAY['driver_expiry_check'::text, 'reconcile'::text])) AND (de.state = 'removed_at_machine'::text) AND (de.superseded_by_event IS NULL) AND (COALESCE(de.qty, (0)::numeric) > (0)::numeric))
        ), candidates AS (
         SELECT dispatch_candidates.line_id,
            dispatch_candidates.source,
            dispatch_candidates.machine_id,
            dispatch_candidates.shelf_id,
            dispatch_candidates.boonz_product_id,
            dispatch_candidates.pod_product_id,
            dispatch_candidates.qty,
            dispatch_candidates.expiry_date,
            dispatch_candidates.from_wh_inventory_id,
            dispatch_candidates.dispatch_id,
            dispatch_candidates.dispatch_date,
            dispatch_candidates.left_machine_at
           FROM dispatch_candidates
        UNION ALL
         SELECT refill_return_ack_candidates.line_id,
            refill_return_ack_candidates.source,
            refill_return_ack_candidates.machine_id,
            refill_return_ack_candidates.shelf_id,
            refill_return_ack_candidates.boonz_product_id,
            refill_return_ack_candidates.pod_product_id,
            refill_return_ack_candidates.qty,
            refill_return_ack_candidates.expiry_date,
            refill_return_ack_candidates.from_wh_inventory_id,
            refill_return_ack_candidates.dispatch_id,
            refill_return_ack_candidates.dispatch_date,
            refill_return_ack_candidates.left_machine_at
           FROM refill_return_ack_candidates
        UNION ALL
         SELECT quarantine_candidates.line_id,
            quarantine_candidates.source,
            quarantine_candidates.machine_id,
            quarantine_candidates.shelf_id,
            quarantine_candidates.boonz_product_id,
            quarantine_candidates.pod_product_id,
            quarantine_candidates.qty,
            quarantine_candidates.expiry_date,
            quarantine_candidates.from_wh_inventory_id,
            quarantine_candidates.dispatch_id,
            quarantine_candidates.dispatch_date,
            quarantine_candidates.left_machine_at
           FROM quarantine_candidates
        UNION ALL
         SELECT tap_candidates.line_id,
            tap_candidates.source,
            tap_candidates.machine_id,
            tap_candidates.shelf_id,
            tap_candidates.boonz_product_id,
            tap_candidates.pod_product_id,
            tap_candidates.qty,
            tap_candidates.expiry_date,
            tap_candidates.from_wh_inventory_id,
            tap_candidates.dispatch_id,
            tap_candidates.dispatch_date,
            tap_candidates.left_machine_at
           FROM tap_candidates
        ), proposal AS (
         SELECT c.line_id,
            c.source,
            c.machine_id,
            c.shelf_id,
            c.boonz_product_id,
            c.pod_product_id,
            c.qty,
            c.expiry_date,
            c.from_wh_inventory_id,
            c.dispatch_id,
            c.dispatch_date,
            c.left_machine_at,
                CASE
                    WHEN ((c.expiry_date IS NULL) OR (c.expiry_date <= ( SELECT dubai.today
                       FROM dubai))) THEN true
                    ELSE false
                END AS expired_or_undated,
            best.target_machine_id,
            best.daily_rate
           FROM (candidates c
             LEFT JOIN LATERAL ( SELECT sl.machine_id AS target_machine_id,
                    (sl.velocity_30d / 30.0) AS daily_rate
                   FROM (slot_lifecycle sl
                     JOIN product_mapping pm ON (((pm.pod_product_id = sl.pod_product_id) AND (pm.boonz_product_id = c.boonz_product_id) AND (pm.status = 'Active'::text))))
                  WHERE ((sl.machine_id <> c.machine_id) AND (sl.is_current = true) AND (sl.archived = false) AND (c.expiry_date IS NOT NULL) AND (c.expiry_date > ( SELECT dubai.today
                           FROM dubai)) AND ((sl.velocity_30d / 30.0) >= (c.qty / (GREATEST(((c.expiry_date - ( SELECT dubai.today
                           FROM dubai)) - 2), 1))::numeric)))
                  ORDER BY sl.velocity_30d DESC
                 LIMIT 1) best ON (true))
        )
 SELECT p.line_id,
    p.source,
    p.dispatch_id,
    p.machine_id,
    m.official_name AS machine_name,
    p.shelf_id,
    sc.shelf_code,
    p.boonz_product_id,
    bp.boonz_product_name,
    p.pod_product_id,
    p.qty,
    p.expiry_date,
    p.from_wh_inventory_id,
    p.dispatch_date,
    p.left_machine_at,
        CASE
            WHEN p.expired_or_undated THEN 'waste'::text
            WHEN (p.target_machine_id IS NOT NULL) THEN 'redeploy'::text
            ELSE 'waste'::text
        END AS proposed_outcome,
    p.target_machine_id AS proposed_target_machine_id,
    tm.official_name AS proposed_target_machine_name,
        CASE
            WHEN (p.target_machine_id IS NOT NULL) THEN (p.expiry_date - 2)
            ELSE NULL::date
        END AS proposed_waste_by,
    (EXTRACT(epoch FROM (now() - COALESCE(p.left_machine_at, now()))) / 3600.0) AS age_hours
   FROM ((((proposal p
     LEFT JOIN machines m ON ((m.machine_id = p.machine_id)))
     LEFT JOIN shelf_configurations sc ON ((sc.shelf_id = p.shelf_id)))
     LEFT JOIN boonz_products bp ON ((bp.product_id = p.boonz_product_id)))
     LEFT JOIN machines tm ON ((tm.machine_id = p.target_machine_id)));
