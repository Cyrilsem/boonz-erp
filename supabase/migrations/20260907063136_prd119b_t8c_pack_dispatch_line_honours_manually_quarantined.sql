-- PRD-119b T8(c) (G2b, held from PRD-118): pack_dispatch_line/bind_dispatch_fefo
-- must honour manually_quarantined (the deliberate-hold flag from the PRD-118
-- G2 design, distinct from the generated `quarantined` provenance column).
--
-- Audited first: bind_dispatch_fefo and v_wh_pickable ALREADY correctly
-- exclude manually_quarantined (confirmed live, no change needed).
-- driver_substitute_dispatch_line's FEFO branch also already excludes it.
--
-- pack_dispatch_line did NOT: its initial re-validation of the FE-supplied
-- pick (`v_ok := FOUND AND status='Active' AND NOT quarantined AND ...`)
-- checked the generated `quarantined` column but never `manually_quarantined`.
-- Confirmed live with a real fixture (rolled back before this migration,
-- re-run after): a wh_inventory row with quarantined=false (real
-- provenance_reason, not the NULL/bad-enum default) and
-- manually_quarantined=true was accepted as a DIRECT pick and packed
-- successfully, with zero substitution attempted (rebinds=[]) -- the
-- manager's manual hold was silently bypassed. The fallback/substitution
-- path was already safe (sources candidates from v_wh_pickable, which does
-- exclude manually_quarantined) -- the gap was specifically the initial
-- direct-pick re-check trusting the FE-supplied wh_inventory_id without
-- re-verifying the hold.
--
-- Fix: add `AND NOT COALESCE(v_wh_row.manually_quarantined, false)` to the
-- v_ok check (md5-guarded surgical replace(), same discipline as every
-- other function-body patch this session), plus a new 'manually_quarantined'
-- branch in the bind-failure diagnostic CASE so a blocked driver/packer sees
-- a distinct, honest reason rather than being lumped into 'quarantined' or
-- silently substituted.
--
-- Verified after apply: identical fixture (manually_quarantined=true,
-- quarantined=false wh row, direct pick) now correctly falls through to the
-- substitution path -- v_wh_pickable found a legitimate alternative batch
-- for the same product and rebound the pick to it (the quarantined row
-- itself is never touched: its warehouse_stock is untouched, only the
-- alternative batch's stock is drawn). Never a hard block, per the
-- established doctrine -- the hold is honoured without blocking the driver
-- when a valid substitute exists; if no substitute existed, bind_fail_reason
-- would correctly report 'manually_quarantined' via the new CASE branch.
--
-- Cody: approve, Article 6-adjacent (a manager-set hold must not be
-- bypassable by any writer), 12 (md5-guarded byte-exact replace(), no other
-- logic in this function touched).
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='pack_dispatch_line' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '9c4e7b6c5e3d5c7ebef901c36bfaf5b1' THEN RAISE EXCEPTION 'pack_dispatch_line drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
E'    v_ok := FOUND\n        AND v_wh_row.status = \'Active\'\n        AND NOT COALESCE(v_wh_row.quarantined, false)\n        AND (v_wh_row.expiration_date IS NULL OR v_wh_row.expiration_date >= v_today)\n        AND (v_wh_row.reserved_for_machine_id IS NULL OR v_wh_row.reserved_for_machine_id = v_dispatch.machine_id)\n        AND COALESCE(v_wh_row.warehouse_stock, 0) >= v_pick_qty;',
E'    v_ok := FOUND\n        AND v_wh_row.status = \'Active\'\n        AND NOT COALESCE(v_wh_row.quarantined, false)\n        AND NOT COALESCE(v_wh_row.manually_quarantined, false)\n        AND (v_wh_row.expiration_date IS NULL OR v_wh_row.expiration_date >= v_today)\n        AND (v_wh_row.reserved_for_machine_id IS NULL OR v_wh_row.reserved_for_machine_id = v_dispatch.machine_id)\n        AND COALESCE(v_wh_row.warehouse_stock, 0) >= v_pick_qty;');
  IF v_new = v_def THEN RAISE EXCEPTION 'pack_dispatch_line: v_ok pattern not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
E'          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w\n                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh\n                         AND COALESCE(w.quarantined,false)\n                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)\n                         AND COALESCE(w.warehouse_stock,0) > 0)\n            THEN \'quarantined\'\n          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w\n                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh\n                         AND w.status <> \'Active\' AND NOT COALESCE(w.quarantined,false)\n                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)\n                         AND COALESCE(w.warehouse_stock,0) > 0)\n            THEN \'inactive_batch\'',
E'          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w\n                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh\n                         AND COALESCE(w.quarantined,false)\n                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)\n                         AND COALESCE(w.warehouse_stock,0) > 0)\n            THEN \'quarantined\'\n          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w\n                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh\n                         AND NOT COALESCE(w.quarantined,false) AND COALESCE(w.manually_quarantined,false)\n                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)\n                         AND COALESCE(w.warehouse_stock,0) > 0)\n            THEN \'manually_quarantined\'\n          WHEN EXISTS (SELECT 1 FROM warehouse_inventory w\n                       WHERE w.boonz_product_id = v_pick_bpid AND w.warehouse_id = v_wh\n                         AND w.status <> \'Active\' AND NOT COALESCE(w.quarantined,false)\n                         AND (w.expiration_date IS NULL OR w.expiration_date >= v_today)\n                         AND COALESCE(w.warehouse_stock,0) > 0)\n            THEN \'inactive_batch\'');
  IF v_new = v_def THEN RAISE EXCEPTION 'pack_dispatch_line: fail-reason CASE pattern not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
