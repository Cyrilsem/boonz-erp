-- Loop 2026-09-25/28 (CS ADD, W4): venue binding guard.
--
-- DRAFTED 2026-09-28 daytime (D4), NOT YET APPLIED. Part (b) patches push_plan_to_dispatch, a
-- dispatch function; this loop's hard rule restricts migrations touching dispatch functions to
-- the 22:00-06:00 Dubai window. Part (a) is a new read-only check function plus a cron
-- registration, both allowed any time, but bundled into this one file per CS's own instruction
-- ("write the migration for W4... so the window only has to apply"), applied together in the
-- window, after R3, since part (b)'s patch anchors on push_plan_to_dispatch's post-R3 body.
--
-- Context (from CS, this loop): ACTIVATEMCC-1037-0000-L0, MPMCC-1054-0000-M0, MPMCC-1058-0000-R0
-- were moved to primary_warehouse_id=WH_MCC earlier today because their venue_team product_mapping
-- rows had zero Active stock at their OLD primary warehouse. Root cause of "packing not showing to
-- the team": a vox_at_venue line's from_wh_inventory_id is NULL by design (v_pin_eligible requires
-- source_origin='warehouse'), but the packing screen (fixed separately in W5) was treating that
-- NULL/zero-availability the same as a real out-of-stock warehouse line, defaulting the packer's
-- quantity to 0 and marking the line not_filled with no visibility. This is the proactive guard
-- half: catch this CLASS of gap (a venue-team product with no matching warehouse stock backing it,
-- which is the actual thing CS fixed manually for these 3 machines) before it recurs, plus a
-- lightweight visibility signal on every push.
--
-- Verified live before writing anything: re-ran the exact gap check against ACTIVATEMCC-1037,
-- MPMCC-1054, MPMCC-1058 post-fix; all now show has_wh_stock=true at their new WH_MCC warehouse,
-- confirming the check's own logic correctly detects this class of issue (it would have flagged
-- all 3 before today's manual fix, and shows clean now).

-- (a) Check function + nightly cron. Modeled on the existing
-- check_far_future_picked_visits_nightly pattern (20260908191820): STABLE-free plpgsql, jsonb
-- result, safe_monitoring_alert on violation, registered via cron.schedule. Read-only, no writes
-- beyond the alert row; safe to apply any time (not gated).
CREATE OR REPLACE FUNCTION public.check_venue_binding_gaps()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n int;
BEGIN
  WITH candidates AS (
    SELECT m.machine_id, m.official_name, pm.boonz_product_id, bp.boonz_product_name,
           m.primary_warehouse_id
      FROM public.machines m
      JOIN public.product_mapping pm
        ON pm.machine_id = m.machine_id
       AND pm.status = 'Active'
       AND pm.source_of_supply = 'venue_team'
      JOIN public.boonz_products bp ON bp.product_id = pm.boonz_product_id
     WHERE m.status = 'Active'
  ),
  gaps AS (
    SELECT c.* FROM candidates c
     WHERE NOT EXISTS (
       SELECT 1 FROM public.warehouse_inventory wi
        WHERE wi.warehouse_id = c.primary_warehouse_id
          AND wi.boonz_product_id = c.boonz_product_id
          AND wi.status = 'Active'
          AND COALESCE(wi.warehouse_stock,0) > 0
     )
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'machine_id', g.machine_id, 'official_name', g.official_name,
           'boonz_product_id', g.boonz_product_id, 'boonz_product_name', g.boonz_product_name,
           'primary_warehouse_id', g.primary_warehouse_id)), '[]'::jsonb),
         COUNT(*)
    INTO v_rows, v_n
    FROM gaps g;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('venue_binding_gap', 'warning',
      jsonb_build_object('checked_at', now(), 'count', v_n, 'rows', v_rows));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'venue_binding_gap_count', v_n, 'rows', v_rows);
END;
$function$;

SELECT cron.schedule(
  'check_venue_binding_gaps_nightly',
  '30 20 * * *',
  $$ SELECT public.check_venue_binding_gaps(); $$
);

-- (b) push_plan_to_dispatch: raise a monitoring_alert (never a block) when a vox_at_venue
-- Refill/Add New line lands with no warehouse-side stock pin. Honest note on this specific
-- condition, since CS's instruction names it exactly: v_pin_eligible already requires
-- source_origin='warehouse', so a vox_at_venue line NEVER gets pinned by design; this alert will
-- fire on every such line, every push. That makes it a visibility list (every at-venue line this
-- push, for whoever wants to audit them), not an anomaly detector -- the real anomaly detector for
-- "no backing stock" is part (a) above. Severity is 'info' precisely because firing on every line
-- is expected, not alarming; do not raise this to 'warning' without checking with CS first, since
-- that would alert on normal operation every single push.
--
-- Patch-style (DO block on the live body), same pattern as this loop's 2026-09-28 VOX migrations:
-- anchors on the exact text between the existing pin-eligibility block's closing END IF and the
-- plain Refill/Add New INSERT, which is unique in this function and stable across R3 (R3 only
-- touches the Remove/M2W lot lookup earlier in the function, not this section).
DO $patch$
DECLARE
  v_src text; v_new text;
  old_anchor text := $anchor$    END IF;

    INSERT INTO refill_dispatching (
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity, include, comment,
      from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
      source_origin, from_machine_id, source_kind, source_warehouse_id,
      packed, picked_up, dispatched, returned, item_added
    ) VALUES ($anchor$;
  new_anchor text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'push_plan_to_dispatch';

  IF position(old_anchor in v_src) = 0 THEN
    RAISE EXCEPTION 'push_plan_to_dispatch W4 patch: anchor not found (has the pin-eligible block changed since R3?)';
  END IF;

  new_anchor := $anchor$    END IF;

    IF v_action IN ('Refill','Add New')
       AND COALESCE(line.source_origin::text,'warehouse') = 'vox_at_venue' THEN
      PERFORM public.safe_monitoring_alert('vox_at_venue_no_wh_pin', 'info',
        jsonb_build_object(
          'title', format('VOX at-venue line, no WH-side stock pin: %s @ %s', line.boonz_product_name, p_machine_name),
          'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
          'boonz_product_id', v_boonz_product_id, 'shelf', v_normalized_shelf,
          'note', 'vox_at_venue lines are never WH-pinned by design; this is a per-push visibility signal, not an anomaly. See check_venue_binding_gaps for the real gap detector.',
          'detected_by', 'push_plan_to_dispatch_W4_venue_guard', 'detected_at', now()));
    END IF;

    INSERT INTO refill_dispatching (
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity, include, comment,
      from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
      source_origin, from_machine_id, source_kind, source_warehouse_id,
      packed, picked_up, dispatched, returned, item_added
    ) VALUES ($anchor$;

  v_new := replace(v_src, old_anchor, new_anchor);
  IF v_new = v_src THEN
    RAISE EXCEPTION 'push_plan_to_dispatch W4 patch: replace produced no change';
  END IF;
  EXECUTE v_new;
END
$patch$;
