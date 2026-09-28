-- Rollback for R5a (driver_confirm_remove expiry breakdown requirement), captured live
-- 2026-09-28 night window, immediately before applying
-- supabase/migrations/20260925140000_loopv2_r5a_require_expiry_breakdown.sql.
--
-- Restores driver_confirm_remove to its pre-R5a body: p_batch_breakdown stays fully optional, no
-- enforcement on a NULL/near-expiry bound expiry_date, and the em dash in the mutation_reason
-- format string is restored (this was the live behaviour before R5a's incidental no-em-dash fix).

CREATE OR REPLACE FUNCTION public.driver_confirm_remove(p_dispatch_id uuid, p_qty_removed numeric, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_driver_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
BEGIN
  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.action <> 'Remove' THEN
    RAISE EXCEPTION 'driver_confirm_remove only works for action=Remove (got %)', v_dispatch.action;
  END IF;
  IF NOT v_dispatch.packed THEN RAISE EXCEPTION 'Dispatch not yet packed'; END IF;
  IF NOT v_dispatch.picked_up THEN RAISE EXCEPTION 'Dispatch not yet picked up'; END IF;
  IF v_dispatch.driver_confirmed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Dispatch already driver-confirmed at % with qty %',
      v_dispatch.driver_confirmed_at, v_dispatch.driver_confirmed_qty;
  END IF;
  IF v_dispatch.item_added OR v_dispatch.returned THEN
    RAISE EXCEPTION 'Dispatch already terminal (item_added=% returned=%)',
      v_dispatch.item_added, v_dispatch.returned;
  END IF;
  IF p_qty_removed IS NULL OR p_qty_removed < 0 THEN
    RAISE EXCEPTION 'p_qty_removed must be >= 0 (use return_dispatch_line if no items removed)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'driver_confirm_remove', true);
  PERFORM set_config('app.mutation_reason',
    format('driver_confirm_remove by %s: %s units removed%s',
      COALESCE(p_driver_id::text, 'driver'), p_qty_removed,
      CASE WHEN p_notes IS NOT NULL THEN ' — ' || p_notes ELSE '' END), true);

  UPDATE refill_dispatching SET
    driver_confirmed_qty = p_qty_removed,
    driver_confirmed_at = now(),
    driver_confirmed_by = p_driver_id,
    driver_confirmed_breakdown = p_batch_breakdown,
    dispatched = true,  -- driver-side complete
    comment = COALESCE(comment, '') ||
              CASE WHEN p_notes IS NOT NULL THEN E'\n[Driver: ' || p_notes || ']' ELSE '' END
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'status', 'driver_confirmed_pending_wh_approval',
    'dispatch_id', p_dispatch_id,
    'qty_removed', p_qty_removed,
    'driver_id', p_driver_id,
    'next_step', 'WH manager reviews in Inventory tab and calls wh_approve_remove_receipt'
  );
END;
$function$;
