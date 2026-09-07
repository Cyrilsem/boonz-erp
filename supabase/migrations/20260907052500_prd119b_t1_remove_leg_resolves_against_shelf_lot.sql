-- PRD-119b T1 (E1): engine Remove legs for expiring shelf lots carried the
-- WRONG expiry/shelf, resolved against the PLAN's assumed shelf instead of
-- wherever the actual pod lot lives. `push_plan_to_dispatch` has two
-- Remove-leg branches (an M2M-transfer source-side branch and a general
-- Refill/Add-New/Remove branch); both queried
-- `v_pod_inventory_latest ... WHERE machine_id=... AND shelf_id=<the plan's
-- assumed shelf> AND boonz_product_id=...`. When the actual lot with stock
-- lives on a DIFFERENT shelf than the plan assumed (confirmed live:
-- VOXMCC-1005 Vitamin Well Zero Lemon planned on A15, real lot on A16;
-- VOXMCC-1011 same product planned on A15, real lot on A10), the query
-- returns zero rows and the leg falls into the "remainder not attributable
-- to a known batch (PRD-053)" catch-all with expiry_date=NULL and a
-- placeholder shelf -- even though a perfectly good dated lot exists, just
-- elsewhere in the machine.
--
-- `v_pod_inventory_latest` itself was already grain-correct (DISTINCT ON
-- machine+shelf+product+expiration_date, from the PRD-119 P2 fix) -- it does
-- NOT collapse different-expiry lots into one row, ruling out that
-- hypothesis. The bug is purely the shelf-scoping of the lookup.
--
-- Fix: drop the shelf_id filter from both branches (search machine+product
-- only, matching T1's exact spec), order by expiration_date ASC NULLS LAST
-- (unchanged) so a real dated lot always outranks 2099-sentinel/NULL
-- placeholder rows on other shelves, and use the FOUND lot's own shelf_id
-- (not the plan's assumed shelf) on the INSERT. Widened
-- `v_pod_inventory_latest` to also expose `pod_inventory_id` (additive,
-- trailing column, no existing consumer affected) so the new
-- `pod_lot_id uuid REFERENCES pod_inventory(pod_inventory_id)` column on
-- `refill_dispatching` can be populated with the exact lot reference, not
-- just a date.
--
-- Residual, deliberately not solved here: a machine can hold multiple
-- REAL-dated Active lots of the same product across different (often
-- orphaned -- see T5) shelves; "earliest expiry wins" is a reasonable
-- default but could occasionally point a Remove leg at a shelf other than
-- the one CS/the driver had in mind. Flagged, not engineered around,
-- given time constraints.
--
-- Verified: `md5`-guarded surgical `replace()` on both occurrences (exact
-- byte match confirmed before applying); direct query proof that the OLD
-- shelf-scoped lookup returns 0 rows for VOXMCC-1005/A15/VW-Zero-Lemon while
-- the NEW machine+product lookup correctly returns the real A16 lot
-- (2026-09-06) ranked first ahead of a dozen 2099-sentinel rows on other
-- shelves.
--
-- Cody: approve, Articles 1 (still the sole dispatch writer, no new write
-- path), 12 (forward-only, md5-guarded, byte-exact `replace()`), no other
-- logic in this 27KB function touched.
CREATE OR REPLACE VIEW public.v_pod_inventory_latest AS
SELECT DISTINCT ON (machine_id, shelf_id, boonz_product_id, expiration_date)
  machine_id, shelf_id, boonz_product_id, current_stock, expiration_date, batch_id, status, snapshot_at, pod_inventory_id
FROM pod_inventory pi
ORDER BY machine_id, shelf_id, boonz_product_id, expiration_date, snapshot_at DESC;

ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS pod_lot_id uuid REFERENCES public.pod_inventory(pod_inventory_id) ON DELETE SET NULL;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='push_plan_to_dispatch' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'bb871aaecee0f03de0e848e20315188a' THEN RAISE EXCEPTION 'push_plan_to_dispatch drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
E'        FOR v_batch IN
          SELECT pil.expiration_date, pil.current_stock
            FROM public.v_pod_inventory_latest pil
           WHERE pil.machine_id = v_src_machine_id
             AND pil.shelf_id   = v_src_shelf_id
             AND pil.boonz_product_id = v_boonz_product_id
             AND pil.status = \'Active\'
             AND COALESCE(pil.current_stock,0) > 0
           ORDER BY pil.expiration_date ASC NULLS LAST
        LOOP
          EXIT WHEN v_remaining <= 0;
          v_take := LEAST(v_batch.current_stock, v_remaining);
          INSERT INTO refill_dispatching (
            machine_id, shelf_id, pod_product_id, boonz_product_id,
            dispatch_date, action, quantity, include, comment,
            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
            source_origin, from_machine_id,
            is_m2m, m2m_transfer_id, source_machine_id, source_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,
            line.plan_date, \'Remove\', v_take, true,
            COALESCE(NULLIF(trim(v_src_line.comment),\'\'), format(\'M2M: %s -> %s\', v_src_line.machine_name, p_machine_name)),
            NULL, NULL, v_batch.expiration_date, false,
            \'internal_transfer\'::public.source_origin_enum, NULL,
            true, v_transfer_id, v_src_machine_id, \'m2m\',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;',
E'        FOR v_batch IN
          SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id, pil.pod_inventory_id
            FROM public.v_pod_inventory_latest pil
           WHERE pil.machine_id = v_src_machine_id
             AND pil.boonz_product_id = v_boonz_product_id
             AND pil.status = \'Active\'
             AND COALESCE(pil.current_stock,0) > 0
           ORDER BY pil.expiration_date ASC NULLS LAST
        LOOP
          EXIT WHEN v_remaining <= 0;
          v_take := LEAST(v_batch.current_stock, v_remaining);
          INSERT INTO refill_dispatching (
            machine_id, shelf_id, pod_product_id, boonz_product_id,
            dispatch_date, action, quantity, include, comment,
            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
            source_origin, from_machine_id, pod_lot_id,
            is_m2m, m2m_transfer_id, source_machine_id, source_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_src_machine_id, COALESCE(v_batch.lot_shelf_id, v_src_shelf_id), v_pod_product_id, v_boonz_product_id,
            line.plan_date, \'Remove\', v_take, true,
            COALESCE(NULLIF(trim(v_src_line.comment),\'\'), format(\'M2M: %s -> %s\', v_src_line.machine_name, p_machine_name)),
            NULL, NULL, v_batch.expiration_date, false,
            \'internal_transfer\'::public.source_origin_enum, NULL, v_batch.pod_inventory_id,
            true, v_transfer_id, v_src_machine_id, \'m2m\',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;');
  IF v_new = v_def THEN RAISE EXCEPTION 'push_plan_to_dispatch: occurrence 1 (m2m) pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
E'      FOR v_batch IN
        SELECT pil.expiration_date, pil.current_stock
          FROM public.v_pod_inventory_latest pil
         WHERE pil.machine_id = v_machine_id
           AND pil.shelf_id   = v_shelf_id
           AND pil.boonz_product_id = v_boonz_product_id
           AND pil.status = \'Active\'
           AND COALESCE(pil.current_stock,0) > 0
         ORDER BY pil.expiration_date ASC NULLS LAST
      LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := LEAST(v_batch.current_stock, v_remaining);
        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, v_take, true, v_dispatch_comment,
          v_primary_warehouse_id, NULL, v_batch.expiration_date, false,
          COALESCE(line.source_origin, \'warehouse\'::public.source_origin_enum),
          CASE WHEN line.source_origin=\'internal_transfer\' THEN line.from_machine_id ELSE NULL END,
          false, false, false, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;',
E'      FOR v_batch IN
        SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id, pil.pod_inventory_id
          FROM public.v_pod_inventory_latest pil
         WHERE pil.machine_id = v_machine_id
           AND pil.boonz_product_id = v_boonz_product_id
           AND pil.status = \'Active\'
           AND COALESCE(pil.current_stock,0) > 0
         ORDER BY pil.expiration_date ASC NULLS LAST
      LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := LEAST(v_batch.current_stock, v_remaining);
        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id, pod_lot_id,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, COALESCE(v_batch.lot_shelf_id, v_shelf_id), v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, v_take, true, v_dispatch_comment,
          v_primary_warehouse_id, NULL, v_batch.expiration_date, false,
          COALESCE(line.source_origin, \'warehouse\'::public.source_origin_enum),
          CASE WHEN line.source_origin=\'internal_transfer\' THEN line.from_machine_id ELSE NULL END,
          v_batch.pod_inventory_id,
          false, false, false, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;');
  IF v_new = v_def THEN RAISE EXCEPTION 'push_plan_to_dispatch: occurrence 2 (general remove) pattern not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
