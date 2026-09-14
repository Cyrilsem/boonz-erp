-- PRD-125 D2 / ONE-LOOP Phase 1 -- WEIMI is the shelf truth.
--
-- align_pod_lots_to_weimi(p_machine_id, p_dry_run): for each WEIMI lane on a
-- machine, reconciles pod_inventory to match. Move: an Active lot for the
-- same product sits elsewhere on the machine -- relocate it to the WEIMI
-- shelf, keep its expiry. Create: WEIMI shows stock, nothing Active anywhere
-- for that product -- new lot, expiration_date NULL, batch_id
-- 'WEIMI-ALIGN-<date>'. Retire: an Active lot sits on a shelf WEIMI shows
-- empty, or holding a different product than WEIMI says -- set Inactive,
-- removal_reason 'weimi_align'. This is the nightly job that keeps
-- pod_inventory's shelf assignment honest without ever letting it decide
-- placement during the day (that's D2's push_plan_to_dispatch /
-- add_dispatch_row fix, migrations 000100/000300).
--
-- BUG CAUGHT AND FIXED BEFORE THIS MIGRATION: the first draft re-queried
-- "an Active lot elsewhere on the machine" fresh on every shelf iteration.
-- In dry-run mode nothing is actually written, so a single lot got proposed
-- as the "move" target for every later shelf that shared its product --
-- verified live on ACTIVATEMCC-1037 (one lot proposed for A01, A04, and A05
-- simultaneously). Fixed with an in-pass v_claimed uuid[] so a lot claimed by
-- an earlier shelf in the same call can never be proposed again, whether or
-- not the run is a dry run.
--
-- Verified live (rolled back): ACTIVATEMCC-1037 dry run -- 20 lanes, 9
-- product-mismatch retirements, 1 empty-lane retirement, 2 moves, 9 creates,
-- 4 unchanged, zero duplicate pod_inventory_id across the whole detail list.
-- Confirms real, large pre-existing pod_inventory/WEIMI drift on this
-- machine (consistent with PRD-124's own "pod_inventory drifts and nothing
-- says so" -- this is that drift, made visible).
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
      v_created := v_created + 1;
      v_details := v_details || jsonb_build_object('shelf', v_lane.shelf_code, 'action', 'create',
        'boonz_product_id', v_weimi_boonz, 'current_stock', v_lane.current_stock);
      IF NOT p_dry_run THEN
        INSERT INTO public.pod_inventory
          (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock,
           estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at, weimi_aisle_code)
        VALUES
          (p_machine_id, v_this_shelf_id, v_weimi_boonz, CURRENT_DATE, v_lane.current_stock,
           v_lane.current_stock, NULL, 'WEIMI-ALIGN-' || CURRENT_DATE::text, 'Active', now(), now(), v_lane.shelf_code)
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

-- Wire the nightly alignment sweep, one machine at a time, real writes
-- (p_dry_run := false), for every machine flagged include_in_refill=true.
-- PRD-125 asked for this "after the aisle snapshot"; there is no discrete
-- pg_cron job that performs that ingestion (it lands via an external
-- process directly into weimi_aisle_snapshots, once daily around 19:59 UTC
-- -- verified live), so this is scheduled at the literal requested time
-- (22:00 UTC), safely after that daily ingestion.
CREATE OR REPLACE FUNCTION public.cron_align_pod_lots_to_weimi_nightly()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_machine RECORD;
  v_result  jsonb;
BEGIN
  FOR v_machine IN SELECT machine_id, official_name FROM public.machines WHERE include_in_refill = true LOOP
    BEGIN
      v_result := public.align_pod_lots_to_weimi(v_machine.machine_id, false);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.monitoring_alerts (source, severity, payload)
      VALUES ('align_pod_lots_to_weimi_failure', 'warning', jsonb_build_object(
        'title', format('align_pod_lots_to_weimi failed for %s', v_machine.official_name),
        'machine_id', v_machine.machine_id, 'error', SQLERRM, 'detected_at', now()));
    END;
  END LOOP;
END
$function$;

SELECT cron.schedule('align_pod_lots_to_weimi_nightly', '0 22 * * *',
  'SELECT public.cron_align_pod_lots_to_weimi_nightly();');
