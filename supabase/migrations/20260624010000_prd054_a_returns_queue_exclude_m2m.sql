-- PRD-054 (1a): exclude M2M transfers from the WH "Returns awaiting approval" queue.
-- v_pending_wh_remove_confirmations leaked machine-to-machine transfer legs (e.g. the 7
-- PRD-052 Vitamin Well rows, is_m2m=true, transfer_id 1538f35f-...) into the returns-approval
-- panel. Those are NOT warehouse returns; receive is already M2M-aware, but they are noise and
-- an approval foot-gun. Forward CREATE OR REPLACE VIEW: based byte-for-byte on the live def,
-- the ONLY change is the added predicate `AND COALESCE(rd.is_m2m, false) = false`. Columns and
-- ordering unchanged. Read-only view; no writer/table change (Constitution Art 1/12).
--
-- PRD-054 (1b) note: the durable venue_team (VOX) receive guard is ALREADY LIVE in
-- receive_dispatch_line's Remove branch (detects product_mapping.source_of_supply='venue_team'
-- for the dispatch machine+boonz, skips ALL warehouse_inventory credit, logs vox_return_log,
-- path 'remove_venue_team_no_wh_credit', marks item_added=true). wh_approve_remove_receipt and
-- wh_approve_remove_receipt_multivariant both delegate the credit to receive_dispatch_line, so
-- the guard covers all three receive paths. No function change required; proven by T2-T6.

CREATE OR REPLACE VIEW public.v_pending_wh_remove_confirmations AS
 SELECT rd.dispatch_id,
    m.official_name AS machine,
    bp.boonz_product_name,
    rd.quantity AS planned_qty,
    rd.driver_confirmed_qty,
    rd.driver_confirmed_breakdown,
    rd.driver_confirmed_at,
    rd.driver_confirmed_by,
    rd.expiry_date AS dispatch_expiry,
    rd.comment,
    EXTRACT(epoch FROM now() - rd.driver_confirmed_at) / 3600.0 AS hours_awaiting_approval
   FROM refill_dispatching rd
     JOIN machines m ON m.machine_id = rd.machine_id
     JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
  WHERE rd.action = 'Remove'::text
    AND rd.driver_confirmed_at IS NOT NULL
    AND rd.wh_approved_at IS NULL
    AND COALESCE(rd.item_added, false) = false
    AND COALESCE(rd.returned, false) = false
    AND COALESCE(rd.is_m2m, false) = false
  ORDER BY rd.driver_confirmed_at;
