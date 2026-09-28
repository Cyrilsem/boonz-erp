-- Loop 2026-09-25 (CS ADD R5): require a per-variant expiry/qty breakdown on driver_confirm_remove
-- when the line's bound expiry is within 7 days or missing.
--
-- DEFERRED, NOT YET APPLIED. driver_confirm_remove is a field-app dispatch function; this loop's
-- own hard rule restricts migrations touching dispatch/field-app functions to the 22:00-06:00
-- Dubai window. Drafted and investigated now (11:11 Dubai) so it is ready to apply the moment the
-- window opens; STATE.md records this as DEFERRED.
--
-- Investigation before writing anything (per this loop's standing discipline):
--
-- R5a and R5b are NOT a greenfield build. Both already exist in the live schema:
--   - driver_confirm_remove(p_dispatch_id, p_qty_removed, p_batch_breakdown jsonb, p_driver_id,
--     p_notes) already accepts a JSONB batch breakdown and stages it verbatim into
--     refill_dispatching.driver_confirmed_breakdown. It does NOT yet require one; that is the one
--     real gap, closed below.
--   - wh_approve_remove_receipt_multivariant(p_parent_dispatch_id, p_variant_breakdown jsonb,
--     p_approved_by, p_reason) already exists, already validates the variant total against
--     driver_confirmed_qty, already creates one child refill_dispatching row per variant (each
--     with its own boonz_product_id and expiry_date), and already calls receive_dispatch_line per
--     child with a single-entry batch array [{expiry, qty}].
--   - receive_dispatch_line's own Remove-action branch, when given a batch breakdown, already does
--     exactly what R5b asks for: for each {expiry, qty} entry it looks for an Active
--     warehouse_inventory row at the target warehouse with that exact boonz_product_id and
--     expiration_date, credits it if found (credit_summary mode='existing'), and INSERTs a new
--     warehouse_inventory batch row if none exists (mode='inserted'). This is the "WH credit must
--     land on the batch matching the entered expiry; create the batch if none exists" rule R5b
--     asked for, already live.
--
-- So the only real gap is enforcement: driver_confirm_remove currently accepts p_batch_breakdown
-- as fully optional (default NULL) with no rule requiring it. Fixed here: driver_confirm_remove
-- now refuses to confirm a Remove line with no breakdown when the dispatch's own bound expiry_date
-- is NULL or within 7 days of today (Dubai), forcing the driver to enter what they read off the
-- pack in exactly those cases, per R5a. A line with a safely-distant bound expiry can still
-- confirm without a breakdown, unchanged from today's behaviour.
--
-- Incidental fix: driver_confirm_remove's own mutation_reason format string used a literal em
-- dash (' -- ' before this fix, U+2014) before p_notes. Replaced with a plain hyphen while
-- already rewriting this function body, per the loop's own no-em-dash hard rule.

CREATE OR REPLACE FUNCTION public.driver_confirm_remove(
  p_dispatch_id uuid,
  p_qty_removed numeric,
  p_batch_breakdown jsonb DEFAULT NULL::jsonb,
  p_driver_id uuid DEFAULT NULL::uuid,
  p_notes text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
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

  -- R5a: a per-variant expiry/qty breakdown is required when the line's own bound expiry is
  -- missing or within 7 days, so the driver enters what they actually read off the pack instead
  -- of the system trusting a stale or absent bound expiry.
  IF COALESCE(jsonb_array_length(p_batch_breakdown), 0) = 0
     AND (v_dispatch.expiry_date IS NULL OR v_dispatch.expiry_date <= v_today + 7) THEN
    RAISE EXCEPTION 'driver_confirm_remove: this line''s bound expiry is % (or missing) - enter the expiry and quantity read off the pack for each variant via p_batch_breakdown before confirming',
      COALESCE(v_dispatch.expiry_date::text, 'NULL');
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'driver_confirm_remove', true);
  PERFORM set_config('app.mutation_reason',
    format('driver_confirm_remove by %s: %s units removed%s',
      COALESCE(p_driver_id::text, 'driver'), p_qty_removed,
      CASE WHEN p_notes IS NOT NULL THEN ' - ' || p_notes ELSE '' END), true);

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
    'next_step', 'WH manager reviews in Inventory tab and calls wh_approve_remove_receipt or wh_approve_remove_receipt_multivariant'
  );
END;
$function$;
