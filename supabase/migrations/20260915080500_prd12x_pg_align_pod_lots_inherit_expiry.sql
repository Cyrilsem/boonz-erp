-- ONE-LOOP-3 Job 3 addition (mid-turn CS instruction): align_pod_lots_to_weimi
-- ran live at 22:00 UTC on 14 Sep and, on AMZ-1057-2403-O1 A08, created a
-- WEIMI-ALIGN lot with expiration_date NULL while Inactive lots for the same
-- product on the same shelf carried 2026-09-25 -- the "create" branch below
-- always hardcoded NULL instead of checking for a real expiry to inherit.
--
-- Fix: when creating a lot for a lane with stock and no Active lot to move,
-- inherit expiration_date from the most recent lot (any status) of the same
-- boonz_product_id on the same machine, if one exists; NULL only when there
-- truly is none. "Most recent" = highest created_at.
--
-- NOT applied yet -- CS asked for this after 22:00 Dubai (18:00 UTC), ~10h
-- from when this was written (08:00 UTC). Written and dry-run-verified now;
-- the live DROP/CREATE happens later in this same session once that time has
-- actually passed, immediately before cron 77's 22:00 UTC live run tonight.

CREATE OR REPLACE FUNCTION public.align_pod_lots_to_weimi(p_machine_id uuid, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_lane          RECORD;
  v_weimi_boonz   uuid;
  v_lot           RECORD;
  v_moved         int := 0;
  v_created       int := 0;
  v_retired       int := 0;
  v_unchanged     int := 0;
  v_details       jsonb := '[]'::jsonb;
  v_shelf_lot     RECORD;
  v_claimed       uuid[] := '{}';
  v_this_shelf_id uuid;
  v_inherit_expiry date;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'align_pod_lots_to_weimi', true);

  IF p_machine_id IS NULL THEN
    RAISE EXCEPTION 'align_pod_lots_to_weimi: p_machine_id is required';
  END IF;

  FOR v_lane IN SELECT * FROM public.weimi_shelf_now(p_machine_id) LOOP
    SELECT shelf_id INTO v_this_shelf_id
      FROM public.shelf_configurations
     WHERE machine_id = p_machine_id AND shelf_code = v_lane.shelf_code;

    -- Resolve WEIMI's pod_product_id to the boonz_product_id pod_inventory keys on
    -- (machine-specific Active mapping first, global Active default second).
    SELECT pm.boonz_product_id INTO v_weimi_boonz
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_lane.pod_product_id AND pm.status = 'Active'
       AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
     ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, pm.is_global_default DESC
     LIMIT 1;

    -- Lot already sitting on THIS shelf, if any (regardless of product match).
    SELECT pil.pod_inventory_id, pil.boonz_product_id, pil.expiration_date
      INTO v_shelf_lot
      FROM public.v_pod_inventory_latest pil
     WHERE pil.machine_id = p_machine_id AND pil.shelf_id = v_this_shelf_id
       AND pil.status = 'Active'
     LIMIT 1;

    IF v_lane.pod_product_id IS NULL OR v_weimi_boonz IS NULL THEN
      v_unchanged := v_unchanged + 1;
      CONTINUE;
    END IF;

    IF v_lane.current_stock = 0 THEN
      IF v_shelf_lot.pod_inventory_id IS NOT NULL THEN
        v_retired := v_retired + 1;
        v_details := v_details || jsonb_build_object('shelf', v_lane.shelf_code, 'action', 'retire',
          'reason', 'weimi_empty', 'pod_inventory_id', v_shelf_lot.pod_inventory_id);
        v_claimed := v_claimed || v_shelf_lot.pod_inventory_id;
        IF NOT p_dry_run THEN
          UPDATE public.pod_inventory SET status = 'Inactive', removal_reason = 'weimi_align'
           WHERE pod_inventory_id = v_shelf_lot.pod_inventory_id;
        END IF;
      ELSE
        v_unchanged := v_unchanged + 1;
      END IF;
      CONTINUE;
    END IF;

    IF v_shelf_lot.pod_inventory_id IS NOT NULL AND v_shelf_lot.boonz_product_id = v_weimi_boonz THEN
      v_unchanged := v_unchanged + 1;
      v_claimed := v_claimed || v_shelf_lot.pod_inventory_id;
      CONTINUE;
    END IF;

    IF v_shelf_lot.pod_inventory_id IS NOT NULL AND v_shelf_lot.boonz_product_id <> v_weimi_boonz THEN
      v_retired := v_retired + 1;
      v_details := v_details || jsonb_build_object('shelf', v_lane.shelf_code, 'action', 'retire',
        'reason', 'weimi_product_mismatch', 'pod_inventory_id', v_shelf_lot.pod_inventory_id);
      v_claimed := v_claimed || v_shelf_lot.pod_inventory_id;
      IF NOT p_dry_run THEN
        UPDATE public.pod_inventory SET status = 'Inactive', removal_reason = 'weimi_align'
         WHERE pod_inventory_id = v_shelf_lot.pod_inventory_id;
      END IF;
    END IF;

    -- Is there an Active lot for this product elsewhere on the SAME machine,
    -- not already claimed by an earlier shelf in this same pass? (dry_run
    -- never commits, so without the exclusion the same lot would be proposed
    -- as the "move" target for every later shelf sharing its product.)
    SELECT pil.pod_inventory_id, pil.expiration_date INTO v_lot
      FROM public.v_pod_inventory_latest pil
     WHERE pil.machine_id = p_machine_id
       AND pil.boonz_product_id = v_weimi_boonz
       AND pil.status = 'Active'
       AND pil.shelf_id <> v_this_shelf_id
       AND NOT (pil.pod_inventory_id = ANY(v_claimed))
     ORDER BY pil.expiration_date ASC NULLS LAST
     LIMIT 1;

    IF v_lot.pod_inventory_id IS NOT NULL THEN
      v_moved := v_moved + 1;
      v_details := v_details || jsonb_build_object('shelf', v_lane.shelf_code, 'action', 'move',
        'pod_inventory_id', v_lot.pod_inventory_id, 'expiry_kept', v_lot.expiration_date);
      v_claimed := v_claimed || v_lot.pod_inventory_id;
      IF NOT p_dry_run THEN
        UPDATE public.pod_inventory
           SET shelf_id = v_this_shelf_id, weimi_aisle_code = v_lane.shelf_code
         WHERE pod_inventory_id = v_lot.pod_inventory_id;
      END IF;
    ELSE
      -- ONE-LOOP-3 Job 3 fix: no movable lot exists, so a new one is being
      -- created from scratch. Before defaulting to NULL, check for the most
      -- recent lot of this product ANYWHERE on this machine (any status) --
      -- a retired/Inactive lot still carries a real physical expiry that is a
      -- far better guess than NULL, and is exactly what bit AMZ-1057-2403-O1
      -- A08 on the 14 Sep live run.
      -- Exclude the 2099-12-31 sentinel (a known placeholder elsewhere in this
      -- codebase, e.g. wm_confirm_line_split's own rejection of it) -- a lot
      -- stamped with that value is not a real expiry worth inheriting.
      SELECT pi2.expiration_date INTO v_inherit_expiry
        FROM public.pod_inventory pi2
       WHERE pi2.machine_id = p_machine_id AND pi2.boonz_product_id = v_weimi_boonz
         AND pi2.expiration_date IS DISTINCT FROM '2099-12-31'::date
       ORDER BY pi2.created_at DESC NULLS LAST
       LIMIT 1;

      v_created := v_created + 1;
      v_details := v_details || jsonb_build_object('shelf', v_lane.shelf_code, 'action', 'create',
        'boonz_product_id', v_weimi_boonz, 'current_stock', v_lane.current_stock,
        'inherited_expiry', v_inherit_expiry);
      IF NOT p_dry_run THEN
        INSERT INTO public.pod_inventory
          (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock,
           estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at, weimi_aisle_code)
        VALUES
          (p_machine_id, v_this_shelf_id, v_weimi_boonz, CURRENT_DATE, v_lane.current_stock,
           v_lane.current_stock, v_inherit_expiry, 'WEIMI-ALIGN-' || CURRENT_DATE::text, 'Active', now(), now(), v_lane.shelf_code)
        RETURNING pod_inventory_id INTO v_lot.pod_inventory_id;
        v_claimed := v_claimed || v_lot.pod_inventory_id;
      END IF;
    END IF;
  END LOOP;

  IF NOT p_dry_run AND (v_moved + v_created + v_retired) > 5 THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('align_pod_lots_to_weimi', 'warning', jsonb_build_object(
      'title', format('align_pod_lots_to_weimi moved/retired/created %s lots on machine %s', v_moved + v_created + v_retired, p_machine_id),
      'machine_id', p_machine_id, 'moved', v_moved, 'created', v_created, 'retired', v_retired,
      'detected_at', now()));
  END IF;

  RETURN jsonb_build_object(
    'machine_id', p_machine_id, 'dry_run', p_dry_run,
    'moved', v_moved, 'created', v_created, 'retired', v_retired, 'unchanged', v_unchanged,
    'details', v_details);
END
$function$;
