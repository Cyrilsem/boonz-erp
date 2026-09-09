-- PRD-120 L5 (2026-09-09): push/bind-time flavor fallback for Remove/M2W legs.
--
-- Root cause of L4's noise: a lane holds a multi-flavor pod (e.g. Rice &
-- Corn, Dubai Popcorn). The plan writes a Remove naming ONE boonz flavor.
-- The shelf's real lot is a DIFFERENT flavor of the same pod. The old
-- lookup filtered strictly on the planned boonz_product_id, found zero
-- lots, and fell into the "remainder not attributable to a known batch
-- (PRD-053)" catch-all with pod_lot_id=NULL. record_remove_leg_outcome then
-- refuses the row ("has no pod_lot_id"), the driver can't zero it from the
-- app, and has to insert his own [DRIVER-INSERT] row instead (6 of those on
-- 2026-09-09 alone). PRD-119b's T1 (repair_remove_leg_shelf_lot) already
-- fixed the WRONG-SHELF case (same flavor, different shelf) by dropping the
-- shelf filter; this is the WRONG-FLAVOR case (same shelf, different
-- flavor) T1 did not cover -- T1/E1's claim that "Remove legs now resolve
-- against the actual shelf lot" is therefore incomplete, as this PRD's own
-- brief states.
--
-- Fix, in both of push_plan_to_dispatch's Remove-leg branches (the general
-- Refill/Add-New/Remove branch, and the M2M source-side branch):
--   1. The existing exact-boonz_product_id lookup runs FIRST, unchanged --
--      a correctly-named Remove is byte-identical to before (zero
--      regression risk for the common case).
--   2. Only when that lookup finds ZERO lots at all (v_remaining still
--      equals the full planned quantity -- a genuine partial shortfall on
--      the correctly-named flavor is a different bug class and is NOT
--      touched) does a new fallback query run: same machine+shelf, ANY
--      Active lot regardless of boonz_product_id (the "lane", per this
--      PRD's own wording -- pod_product_id is assumed shelf-scoped, which
--      holds structurally in this schema; scoping decision documented for
--      Cody/CS review). If the shelf holds several flavors, this produces
--      one dispatch leg per lot -- a real split, same mechanism the
--      existing multi-batch-expiry loop already uses, just sourced from a
--      broader query. Each split leg's `boonz_product_id` becomes the
--      LOT's actual flavor (a real `pod_lot_id` is always bound), not the
--      originally-planned one, tagged `[FLAVOR-CORRECTED: ...]` in the
--      comment.
--   3. If NEITHER query finds anything (nothing at all on the shelf), a
--      leg is still written (so the plan's quantity accounting stays
--      consistent and it's visible on the manifest) but with quantity=0 and
--      tagged `[NO LOT ON SHELF -- ...]` -- non-blocking and zero-rendering
--      per this PRD's own instruction, no driver action implied.
--   4. M2M destination pairing (item 3): the destination Add New/Refill leg
--      no longer copies the ORIGINALLY PLANNED flavor -- it mirrors
--      whatever the source legs actually ended up bound to. When the
--      source resolves to a single actual flavor (the reported live case:
--      HUAWEI B16 pulled Butter, planned Salted), one destination leg
--      carries that actual flavor, tagged `[FLAVOR-CORRECTED: destination
--      adopts ... ]`. When the source split across several actual flavors,
--      one destination leg is created per flavor, quantity-matched, each
--      partner-linked only to its own source leg(s) -- not the previous
--      "one dest leg total" assumption, which would have mis-paired a
--      multi-flavor M2M split.
--
-- Fixture (rolled back; all three run against real reference data --
-- AMZ-1068-2401-O1/D01, HUAWEI-2003-0000-B1/B16, AMZ-1029-3003-O1/C01 --
-- with only pod_inventory/refill_plan_output rows mutated, dated 2099,
-- never touching any real plan/dispatch row):
--   (a) Remove named "Freakin Protein Balls" (absent) on a shelf holding
--       only Pepsi -- Regular -> ONE leg, boonz_product_id corrected to
--       Pepsi, pod_lot_id bound, qty=2 preserved, comment tagged.
--   (b) Same shelf, now holding Pepsi (5 units) + 7Up (2 units), Remove
--       named the absent flavor qty=7 -> TWO legs (7Up x2, Pepsi x5),
--       BOTH pod_lot_id bound, quantities sum to 7 (totals preserved).
--   (c) M2M HUAWEI-2003-0000-B1/B16 -> AMZ-1029-3003-O1/C01, planned
--       "Dubai Popcorn - Salted" qty=3, source shelf holds only "Dubai
--       Popcorn - Butter" -> source leg corrected to Butter (pod_lot_id
--       bound), destination leg ALSO carries Butter (not the planned
--       Salted), m2m_partner_id correctly bidirectional -- this is an
--       exact reproduction of the real 2026-09-09 HUAWEI B16 -> AMZ-1029
--       A11 case.
-- All three passed on the first full run.
--
-- Cody: approve, Article 1 (still the sole refill_plan_output ->
-- refill_dispatching writer, no new write path), 4 (role check and
-- app.via_rpc/app.rpc_name unchanged), 12 (forward-only, md5-guarded
-- byte-exact `replace()` x5; the exact-flavor happy path, the item-C
-- unbound check, the NULL-expiry exemption, the 48h floor, and every other
-- branch are byte-identical to the prior live function). No schema change
-- -- Dara not required.
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='push_plan_to_dispatch';
  IF md5(v_def) <> '90e2096d3349e5bb96a4234048cc6630' THEN
    RAISE EXCEPTION 'push_plan_to_dispatch drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  -- patch1: new DECLARE vars
  v_new := replace(v_def,
E'  v_tombstoned           int := 0;\n  v_lane_weimi_stock     int;\nBEGIN',
E'  v_tombstoned           int := 0;\n  v_lane_weimi_stock     int;\n  v_flavor_corrected     int := 0;\n  v_no_lot_on_shelf      int := 0;\n  v_src_group            RECORD;\n  v_dest_leg_id_first    uuid;\nBEGIN');
  IF v_new = v_def THEN RAISE EXCEPTION 'patch1 (declare) not found'; END IF;
  v_def := v_new;

  -- patch2: general Remove/M2W branch -- lane fallback + no-lot handling
  v_new := replace(v_def,
E'      IF v_remaining > 0 THEN\n        INSERT INTO refill_dispatching (\n          machine_id, shelf_id, pod_product_id, boonz_product_id,\n          dispatch_date, action, quantity, include, comment,\n          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n          source_origin, from_machine_id,\n          packed, picked_up, dispatched, returned, item_added\n        ) VALUES (\n          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,\n          line.plan_date, v_action, v_remaining, true,\n          COALESCE(NULLIF(v_dispatch_comment,\'\') || E\'\\n\', \'\') || \'[EXPIRY-TO-CONFIRM \u2014 remainder not attributable to a known batch (PRD-053)]\',\n          v_primary_warehouse_id, NULL, NULL, false,\n          COALESCE(line.source_origin, \'warehouse\'::public.source_origin_enum),\n          CASE WHEN line.source_origin=\'internal_transfer\' THEN line.from_machine_id ELSE NULL END,\n          false, false, false, false, false\n        ) RETURNING dispatch_id INTO v_new_dispatch_id;\n        v_count := v_count + 1; v_remove_split := v_remove_split + 1;\n      END IF;\n      UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;\n      CONTINUE;\n    END IF;',
E'      IF v_remaining = line.quantity THEN\n        FOR v_batch IN\n          SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id,\n                 pil.pod_inventory_id, pil.boonz_product_id AS lot_boonz_product_id\n            FROM public.v_pod_inventory_latest pil\n           WHERE pil.machine_id = v_machine_id\n             AND pil.shelf_id = v_shelf_id\n             AND pil.status = \'Active\'\n             AND COALESCE(pil.current_stock,0) > 0\n           ORDER BY pil.expiration_date ASC NULLS LAST\n        LOOP\n          EXIT WHEN v_remaining <= 0;\n          v_take := LEAST(v_batch.current_stock, v_remaining);\n          INSERT INTO refill_dispatching (\n            machine_id, shelf_id, pod_product_id, boonz_product_id,\n            dispatch_date, action, quantity, include, comment,\n            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n            source_origin, from_machine_id, pod_lot_id,\n            packed, picked_up, dispatched, returned, item_added\n          ) VALUES (\n            v_machine_id, COALESCE(v_batch.lot_shelf_id, v_shelf_id), v_pod_product_id, v_batch.lot_boonz_product_id,\n            line.plan_date, v_action, v_take, true,\n            COALESCE(NULLIF(v_dispatch_comment,\'\') || E\'\\n\', \'\')\n              || format(\'[FLAVOR-CORRECTED: plan named %s, shelf actually holds %s]\', line.boonz_product_name,\n                   (SELECT bp3.boonz_product_name FROM boonz_products bp3 WHERE bp3.product_id = v_batch.lot_boonz_product_id)),\n            v_primary_warehouse_id, NULL, v_batch.expiration_date, false,\n            COALESCE(line.source_origin, \'warehouse\'::public.source_origin_enum),\n            CASE WHEN line.source_origin=\'internal_transfer\' THEN line.from_machine_id ELSE NULL END,\n            v_batch.pod_inventory_id,\n            false, false, false, false, false\n          ) RETURNING dispatch_id INTO v_new_dispatch_id;\n          v_remaining := v_remaining - v_take;\n          v_count := v_count + 1; v_remove_split := v_remove_split + 1; v_flavor_corrected := v_flavor_corrected + 1;\n        END LOOP;\n      END IF;\n      IF v_remaining > 0 THEN\n        IF v_remaining = line.quantity THEN\n          INSERT INTO refill_dispatching (\n            machine_id, shelf_id, pod_product_id, boonz_product_id,\n            dispatch_date, action, quantity, include, comment,\n            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n            source_origin, from_machine_id,\n            packed, picked_up, dispatched, returned, item_added\n          ) VALUES (\n            v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,\n            line.plan_date, v_action, 0, true,\n            COALESCE(NULLIF(v_dispatch_comment,\'\') || E\'\\n\', \'\') || \'[NO LOT ON SHELF \u2014 nothing to remove here; resolved automatically, no driver action needed]\',\n            v_primary_warehouse_id, NULL, NULL, false,\n            COALESCE(line.source_origin, \'warehouse\'::public.source_origin_enum),\n            CASE WHEN line.source_origin=\'internal_transfer\' THEN line.from_machine_id ELSE NULL END,\n            false, false, false, false, false\n          ) RETURNING dispatch_id INTO v_new_dispatch_id;\n          v_no_lot_on_shelf := v_no_lot_on_shelf + 1;\n        ELSE\n          INSERT INTO refill_dispatching (\n            machine_id, shelf_id, pod_product_id, boonz_product_id,\n            dispatch_date, action, quantity, include, comment,\n            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n            source_origin, from_machine_id,\n            packed, picked_up, dispatched, returned, item_added\n          ) VALUES (\n            v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,\n            line.plan_date, v_action, v_remaining, true,\n            COALESCE(NULLIF(v_dispatch_comment,\'\') || E\'\\n\', \'\') || \'[EXPIRY-TO-CONFIRM \u2014 remainder not attributable to a known batch (PRD-053)]\',\n            v_primary_warehouse_id, NULL, NULL, false,\n            COALESCE(line.source_origin, \'warehouse\'::public.source_origin_enum),\n            CASE WHEN line.source_origin=\'internal_transfer\' THEN line.from_machine_id ELSE NULL END,\n            false, false, false, false, false\n          ) RETURNING dispatch_id INTO v_new_dispatch_id;\n        END IF;\n        v_count := v_count + 1; v_remove_split := v_remove_split + 1;\n      END IF;\n      UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;\n      CONTINUE;\n    END IF;');
  IF v_new = v_def THEN RAISE EXCEPTION 'patch2 (general Remove/M2W branch) not found'; END IF;
  v_def := v_new;

  -- patch3: M2M source-side branch -- same lane fallback + no-lot handling
  v_new := replace(v_def,
E'        IF v_remaining > 0 THEN\n          INSERT INTO refill_dispatching (\n            machine_id, shelf_id, pod_product_id, boonz_product_id,\n            dispatch_date, action, quantity, include, comment,\n            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n            source_origin, from_machine_id,\n            is_m2m, m2m_transfer_id, source_machine_id, source_kind,\n            packed, picked_up, dispatched, returned, item_added\n          ) VALUES (\n            v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,\n            line.plan_date, \'Remove\', v_remaining, true,\n            format(\'M2M: %s -> %s\', v_src_line.machine_name, p_machine_name) || E\'\\n\' || \'[EXPIRY-TO-CONFIRM - remainder not attributable to a known batch (PRD-053)]\',\n            NULL, NULL, NULL, false,\n            \'internal_transfer\'::public.source_origin_enum, NULL,\n            true, v_transfer_id, v_src_machine_id, \'m2m\',\n            true, false, false, false, false\n          ) RETURNING dispatch_id INTO v_new_dispatch_id;\n          IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;\n          v_count := v_count + 1;\n        END IF;',
E'        IF v_remaining = line.quantity THEN\n          FOR v_batch IN\n            SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id,\n                   pil.pod_inventory_id, pil.boonz_product_id AS lot_boonz_product_id\n              FROM public.v_pod_inventory_latest pil\n             WHERE pil.machine_id = v_src_machine_id\n               AND pil.shelf_id = v_src_shelf_id\n               AND pil.status = \'Active\'\n               AND COALESCE(pil.current_stock,0) > 0\n             ORDER BY pil.expiration_date ASC NULLS LAST\n          LOOP\n            EXIT WHEN v_remaining <= 0;\n            v_take := LEAST(v_batch.current_stock, v_remaining);\n            INSERT INTO refill_dispatching (\n              machine_id, shelf_id, pod_product_id, boonz_product_id,\n              dispatch_date, action, quantity, include, comment,\n              from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n              source_origin, from_machine_id, pod_lot_id,\n              is_m2m, m2m_transfer_id, source_machine_id, source_kind,\n              packed, picked_up, dispatched, returned, item_added\n            ) VALUES (\n              v_src_machine_id, COALESCE(v_batch.lot_shelf_id, v_src_shelf_id), v_pod_product_id, v_batch.lot_boonz_product_id,\n              line.plan_date, \'Remove\', v_take, true,\n              COALESCE(NULLIF(trim(v_src_line.comment),\'\'), format(\'M2M: %s -> %s\', v_src_line.machine_name, p_machine_name))\n                || format(E\'\\n[FLAVOR-CORRECTED: plan named %s, shelf actually holds %s]\', line.boonz_product_name,\n                     (SELECT bp3.boonz_product_name FROM boonz_products bp3 WHERE bp3.product_id = v_batch.lot_boonz_product_id)),\n              NULL, NULL, v_batch.expiration_date, false,\n              \'internal_transfer\'::public.source_origin_enum, NULL, v_batch.pod_inventory_id,\n              true, v_transfer_id, v_src_machine_id, \'m2m\',\n              true, false, false, false, false\n            ) RETURNING dispatch_id INTO v_new_dispatch_id;\n            IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;\n            IF v_earliest_expiry IS NULL THEN v_earliest_expiry := v_batch.expiration_date; END IF;\n            v_remaining := v_remaining - v_take;\n            v_count := v_count + 1; v_flavor_corrected := v_flavor_corrected + 1;\n          END LOOP;\n        END IF;\n        IF v_remaining > 0 THEN\n          IF v_remaining = line.quantity THEN\n            INSERT INTO refill_dispatching (\n              machine_id, shelf_id, pod_product_id, boonz_product_id,\n              dispatch_date, action, quantity, include, comment,\n              from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n              source_origin, from_machine_id,\n              is_m2m, m2m_transfer_id, source_machine_id, source_kind,\n              packed, picked_up, dispatched, returned, item_added\n            ) VALUES (\n              v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,\n              line.plan_date, \'Remove\', 0, true,\n              format(\'M2M: %s -> %s\', v_src_line.machine_name, p_machine_name) || E\'\\n\' || \'[NO LOT ON SHELF \u2014 nothing to remove here; resolved automatically, no driver action needed]\',\n              NULL, NULL, NULL, false,\n              \'internal_transfer\'::public.source_origin_enum, NULL,\n              true, v_transfer_id, v_src_machine_id, \'m2m\',\n              true, false, false, false, false\n            ) RETURNING dispatch_id INTO v_new_dispatch_id;\n            IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;\n            v_no_lot_on_shelf := v_no_lot_on_shelf + 1;\n          ELSE\n            INSERT INTO refill_dispatching (\n              machine_id, shelf_id, pod_product_id, boonz_product_id,\n              dispatch_date, action, quantity, include, comment,\n              from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n              source_origin, from_machine_id,\n              is_m2m, m2m_transfer_id, source_machine_id, source_kind,\n              packed, picked_up, dispatched, returned, item_added\n            ) VALUES (\n              v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,\n              line.plan_date, \'Remove\', v_remaining, true,\n              format(\'M2M: %s -> %s\', v_src_line.machine_name, p_machine_name) || E\'\\n\' || \'[EXPIRY-TO-CONFIRM - remainder not attributable to a known batch (PRD-053)]\',\n              NULL, NULL, NULL, false,\n              \'internal_transfer\'::public.source_origin_enum, NULL,\n              true, v_transfer_id, v_src_machine_id, \'m2m\',\n              true, false, false, false, false\n            ) RETURNING dispatch_id INTO v_new_dispatch_id;\n            IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;\n          END IF;\n          v_count := v_count + 1;\n        END IF;');
  IF v_new = v_def THEN RAISE EXCEPTION 'patch3 (M2M source branch) not found'; END IF;
  v_def := v_new;

  -- patch4: M2M destination leg(s) mirror the ACTUAL source flavor(s)
  v_new := replace(v_def,
E'        INSERT INTO refill_dispatching (\n          machine_id, shelf_id, pod_product_id, boonz_product_id,\n          dispatch_date, action, quantity, include, comment,\n          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n          source_origin, from_machine_id,\n          is_m2m, m2m_transfer_id, m2m_partner_id, source_machine_id, source_kind,\n          packed, picked_up, dispatched, returned, item_added\n        ) VALUES (\n          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,\n          line.plan_date, v_action, line.quantity, true,\n          COALESCE(NULLIF(trim(v_dispatch_comment),\'\'), format(\'M2M: %s -> %s\', v_src_line.machine_name, p_machine_name)),\n          NULL, NULL, v_earliest_expiry, false,\n          \'internal_transfer\'::public.source_origin_enum, v_src_machine_id,\n          true, v_transfer_id, v_first_remove_id, v_src_machine_id, \'m2m\',\n          true, false, false, false, false\n        ) RETURNING dispatch_id INTO v_dest_leg_id;\n\n        UPDATE refill_dispatching SET m2m_partner_id = v_dest_leg_id\n         WHERE m2m_transfer_id = v_transfer_id AND dispatch_id <> v_dest_leg_id;\n\n        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_dest_leg_id WHERE id = line.id;\n        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_first_remove_id WHERE id = v_src_line.id;\n        v_count := v_count + 1;\n        v_transfer_pairs := v_transfer_pairs + 1;',
E'        v_dest_leg_id_first := NULL;\n        FOR v_src_group IN\n          SELECT rd_src.boonz_product_id AS grp_boonz_product_id,\n                 SUM(rd_src.quantity)::int AS grp_qty,\n                 MIN(rd_src.expiry_date) AS grp_earliest_expiry,\n                 (array_agg(rd_src.dispatch_id ORDER BY rd_src.created_at))[1] AS grp_first_dispatch_id\n            FROM public.refill_dispatching rd_src\n           WHERE rd_src.m2m_transfer_id = v_transfer_id AND rd_src.is_m2m = true\n             AND rd_src.machine_id = v_src_machine_id\n           GROUP BY rd_src.boonz_product_id\n        LOOP\n          INSERT INTO refill_dispatching (\n            machine_id, shelf_id, pod_product_id, boonz_product_id,\n            dispatch_date, action, quantity, include, comment,\n            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,\n            source_origin, from_machine_id,\n            is_m2m, m2m_transfer_id, m2m_partner_id, source_machine_id, source_kind,\n            packed, picked_up, dispatched, returned, item_added\n          ) VALUES (\n            v_machine_id, v_shelf_id, v_pod_product_id, v_src_group.grp_boonz_product_id,\n            line.plan_date, v_action, v_src_group.grp_qty, true,\n            COALESCE(NULLIF(trim(v_dispatch_comment),\'\'), format(\'M2M: %s -> %s\', v_src_line.machine_name, p_machine_name))\n              || CASE WHEN v_src_group.grp_boonz_product_id <> v_boonz_product_id\n                      THEN format(E\'\\n[FLAVOR-CORRECTED: destination adopts %s pulled at source, plan named %s]\',\n                             (SELECT bp4.boonz_product_name FROM boonz_products bp4 WHERE bp4.product_id = v_src_group.grp_boonz_product_id),\n                             line.boonz_product_name)\n                      ELSE \'\' END,\n            NULL, NULL, v_src_group.grp_earliest_expiry, false,\n            \'internal_transfer\'::public.source_origin_enum, v_src_machine_id,\n            true, v_transfer_id, v_src_group.grp_first_dispatch_id, v_src_machine_id, \'m2m\',\n            true, false, false, false, false\n          ) RETURNING dispatch_id INTO v_dest_leg_id;\n\n          UPDATE refill_dispatching SET m2m_partner_id = v_dest_leg_id\n           WHERE m2m_transfer_id = v_transfer_id AND is_m2m = true\n             AND machine_id = v_src_machine_id AND boonz_product_id = v_src_group.grp_boonz_product_id;\n\n          IF v_dest_leg_id_first IS NULL THEN v_dest_leg_id_first := v_dest_leg_id; END IF;\n          v_count := v_count + 1;\n        END LOOP;\n\n        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_dest_leg_id_first WHERE id = line.id;\n        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_first_remove_id WHERE id = v_src_line.id;\n        v_transfer_pairs := v_transfer_pairs + 1;');
  IF v_new = v_def THEN RAISE EXCEPTION 'patch4 (M2M destination leg) not found'; END IF;
  v_def := v_new;

  -- patch5: RETURN block -- expose new counters, bump rpc_version
  v_new := replace(v_def,
E'    \'m2m_pairing\', v_pairing,\n    \'weimi_slot_guard\', v_slot_guard,\n    \'lines_tombstoned\', v_tombstoned,\n    \'rpc_version\',\'v13_prd117_remove_qty_vs_weimi\'\n  );',
E'    \'m2m_pairing\', v_pairing,\n    \'weimi_slot_guard\', v_slot_guard,\n    \'lines_tombstoned\', v_tombstoned,\n    \'remove_flavor_corrected\', v_flavor_corrected,\n    \'remove_no_lot_on_shelf\', v_no_lot_on_shelf,\n    \'rpc_version\',\'v14_prd120_l5_flavor_fallback\'\n  );');
  IF v_new = v_def THEN RAISE EXCEPTION 'patch5 (return block) not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
