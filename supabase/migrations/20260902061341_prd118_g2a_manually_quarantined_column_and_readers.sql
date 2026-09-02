-- PRD-118 item G2 (revised, split per CS 2026-09-02 live-packing gate): a new
-- manually_quarantined boolean column, independent of the GENERATED quarantined
-- column (which cannot be widened without dropping 10+ dependent views/matviews —
-- confirmed live earlier this session). v_wh_pickable is widened to exclude it.
--
-- CS caught a deeper gap: many functions read warehouse_inventory.quarantined
-- DIRECTLY, not through v_wh_pickable, and would not inherit the new flag from the
-- view change alone. A full audit of every public function whose body mentions
-- 'quarantined' found 15 candidates; 13 are genuine direct readers (2 are false
-- positives — find_substitutes_for_shelf_v3's mention is inside a comment, and
-- release_wh_quarantine's is a no-op short-circuit read, not an availability check).
--
-- This migration (G2a) patches 12 of the 13: every direct reader EXCEPT
-- pack_dispatch_line and bind_dispatch_fefo, which are the live packing writers for
-- the 2026-09-02 run currently in progress (3 rows still open per the gate query at
-- apply time) and are deliberately held for a separate migration (G2b) applied only
-- after CS confirms the run is closed. release_wh_quarantine is extended so a row
-- quarantined via the new door can actually be released through it (its noop-check
-- previously only inspected the generated column).
--
-- Every function patch is an md5-guarded CREATE OR REPLACE inserting exactly one
-- `AND NOT COALESCE(<alias>.manually_quarantined, false)` beside the function's
-- existing quarantined check — zero behavior change on current data, verified:
-- v_wh_pickable row count identical before/after (227/227) since the column
-- defaults false for all 788 currently-quarantined rows and every other row.
--
-- Cody: approve, Articles 1/4/8/12/16 — no new write path, no role-check touched,
-- audit wiring unchanged; closes a live Article-16 gap (inline re-derivation of the
-- pickability predicate outside the canonical view) without a full centralizing
-- refactor. Verified via rolled-back test transaction before this real apply.

ALTER TABLE public.warehouse_inventory ADD COLUMN manually_quarantined boolean NOT NULL DEFAULT false;
CREATE INDEX idx_wh_inv_manually_quarantined ON public.warehouse_inventory (warehouse_id, boonz_product_id) WHERE (manually_quarantined = true);

CREATE OR REPLACE VIEW public.v_wh_pickable AS
WITH dubai AS (
  SELECT (now() AT TIME ZONE 'Asia/Dubai'::text)::date AS today
)
SELECT wi.wh_inventory_id, wi.boonz_product_id, wi.warehouse_id, wi.wh_location,
  wi.batch_id, wi.warehouse_stock, wi.expiration_date, wi.reserved_for_machine_id,
  wi.snapshot_date, wi.created_at, wi.reservation_priority
FROM warehouse_inventory wi CROSS JOIN dubai d
WHERE wi.status = 'Active'::text AND NOT COALESCE(wi.quarantined, false)
  AND NOT COALESCE(wi.manually_quarantined, false)
  AND (wi.expiration_date >= d.today OR wi.expiration_date IS NULL)
  AND wi.warehouse_stock > 0::numeric;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='engine_add_pod' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'a86fc7c51761ea97e9be128e5c9f3cf7' THEN RAISE EXCEPTION 'engine_add_pod drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'AND wi.status = \'Active\' AND wi.quarantined = false\n         AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)',
    E'AND wi.status = \'Active\' AND wi.quarantined = false AND NOT COALESCE(wi.manually_quarantined, false)\n         AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)');
  IF v_new = v_def THEN RAISE EXCEPTION 'engine_add_pod: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='pick_wh_batch_for_machine' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '490c341685fe2a423bdb3b1dd5610490' THEN RAISE EXCEPTION 'pick_wh_batch_for_machine drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'AND NOT COALESCE(quarantined, false)\n    AND (expiration_date IS NULL',
    E'AND NOT COALESCE(quarantined, false)\n    AND NOT COALESCE(manually_quarantined, false)\n    AND (expiration_date IS NULL');
  IF v_new = v_def THEN RAISE EXCEPTION 'pick_wh_batch_for_machine: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='repin_dispatch_batch' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'c433506ddeb8725a9d598a63ab52766f' THEN RAISE EXCEPTION 'repin_dispatch_batch drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'IF v_target.status <> \'Active\' OR COALESCE(v_target.quarantined,false) THEN',
    E'IF v_target.status <> \'Active\' OR COALESCE(v_target.quarantined,false) OR COALESCE(v_target.manually_quarantined,false) THEN');
  IF v_new = v_def THEN RAISE EXCEPTION 'repin_dispatch_batch: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='wh_is_pickable' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '875b4189b6b1cded8f0541bbde320402' THEN RAISE EXCEPTION 'wh_is_pickable drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'SELECT wi.status = \'Active\'\n     AND NOT COALESCE(wi.quarantined, false)\n     AND (wi.expiration_date >=',
    E'SELECT wi.status = \'Active\'\n     AND NOT COALESCE(wi.quarantined, false)\n     AND NOT COALESCE(wi.manually_quarantined, false)\n     AND (wi.expiration_date >=');
  IF v_new = v_def THEN RAISE EXCEPTION 'wh_is_pickable: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='find_substitutes_for_shelf' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '2a311479b30635b0c0b91a892d39778c' THEN RAISE EXCEPTION 'find_substitutes_for_shelf drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = \'Active\' AND wi.quarantined = false\n     AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)',
    E'ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = \'Active\' AND wi.quarantined = false AND NOT COALESCE(wi.manually_quarantined, false)\n     AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)');
  IF v_new = v_def THEN RAISE EXCEPTION 'find_substitutes_for_shelf: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='get_pod_refill_draft' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '291d3a75c5b03c803ead8dba667be6e3' THEN RAISE EXCEPTION 'get_pod_refill_draft drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'AND wi.status = \'Active\'\n         AND wi.quarantined = false\n         AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)',
    E'AND wi.status = \'Active\'\n         AND wi.quarantined = false\n         AND NOT COALESCE(wi.manually_quarantined, false)\n         AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_pod_refill_draft: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='get_shelf_fefo_options' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '979f073f6b0f1d9a9f7d6e5940db54e2' THEN RAISE EXCEPTION 'get_shelf_fefo_options drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'AND wi.status = \'Active\'\n      AND wi.quarantined = false\n      AND COALESCE(wi.warehouse_stock,0) > 0',
    E'AND wi.status = \'Active\'\n      AND wi.quarantined = false\n      AND NOT COALESCE(wi.manually_quarantined, false)\n      AND COALESCE(wi.warehouse_stock,0) > 0');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_shelf_fefo_options: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='get_dashboard_ops' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'b6a55d4bb2fa17e3a5fd333c4455a7a2' THEN RAISE EXCEPTION 'get_dashboard_ops drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'WHERE wi.status = \'Active\' AND COALESCE(wi.quarantined,false) = false\n    AND wi.warehouse_stock > 0\n    AND COALESCE(wi.wh_location,\'\') <> \'VOX_SOURCED\'',
    E'WHERE wi.status = \'Active\' AND COALESCE(wi.quarantined,false) = false AND NOT COALESCE(wi.manually_quarantined, false)\n    AND wi.warehouse_stock > 0\n    AND COALESCE(wi.wh_location,\'\') <> \'VOX_SOURCED\'');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_dashboard_ops: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='get_stock_overview' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '1742663da1377769d6ba42df52b49564' THEN RAISE EXCEPTION 'get_stock_overview drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'WHERE wi.status = \'Active\'\n    AND COALESCE(wi.quarantined, false) = false\n    AND wi.warehouse_stock > 0',
    E'WHERE wi.status = \'Active\'\n    AND COALESCE(wi.quarantined, false) = false\n    AND NOT COALESCE(wi.manually_quarantined, false)\n    AND wi.warehouse_stock > 0');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_stock_overview: site A (wh_side) not found'; END IF;
  v_def := v_new;
  v_new := replace(v_def, E'WHERE wi.status = \'Active\'\n      AND COALESCE(wi.quarantined, false) = false\n      AND wi.warehouse_stock > 0',
    E'WHERE wi.status = \'Active\'\n      AND COALESCE(wi.quarantined, false) = false\n      AND NOT COALESCE(wi.manually_quarantined, false)\n      AND wi.warehouse_stock > 0');
  IF v_new = v_def THEN RAISE EXCEPTION 'get_stock_overview: site B (wh_split) not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='log_manual_refill' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'a6dee377a1845f94f635e215c1394447' THEN RAISE EXCEPTION 'log_manual_refill drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'AND NOT COALESCE(quarantined, false) AND (expiration_date >= p_refill_date OR expiration_date IS NULL)',
    E'AND NOT COALESCE(quarantined, false) AND NOT COALESCE(manually_quarantined, false) AND (expiration_date >= p_refill_date OR expiration_date IS NULL)');
  IF v_new = v_def THEN RAISE EXCEPTION 'log_manual_refill: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='driver_substitute_dispatch_line' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '82eb4327bb447730fcce14c111a25959' THEN RAISE EXCEPTION 'driver_substitute_dispatch_line drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'AND COALESCE(wi.quarantined, false) = false\n      AND (v_wh_id IS NULL OR wi.warehouse_id = v_wh_id)',
    E'AND COALESCE(wi.quarantined, false) = false\n      AND NOT COALESCE(wi.manually_quarantined, false)\n      AND (v_wh_id IS NULL OR wi.warehouse_id = v_wh_id)');
  IF v_new = v_def THEN RAISE EXCEPTION 'driver_substitute_dispatch_line: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='release_wh_quarantine' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '3304d2786ff21ab64a55c73fadacfe5a' THEN RAISE EXCEPTION 'release_wh_quarantine drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def, E'IF NOT v_row.quarantined THEN', E'IF NOT v_row.quarantined AND NOT COALESCE(v_row.manually_quarantined, false) THEN');
  IF v_new = v_def THEN RAISE EXCEPTION 'release_wh_quarantine: noop-check pattern not found'; END IF;
  v_def := v_new;
  v_new := replace(v_def, E'UPDATE public.warehouse_inventory\n     SET provenance_reason = \'manual_adjust\'\n   WHERE wh_inventory_id = p_wh_inventory_id;',
    E'UPDATE public.warehouse_inventory\n     SET provenance_reason = \'manual_adjust\', manually_quarantined = false\n   WHERE wh_inventory_id = p_wh_inventory_id;');
  IF v_new = v_def THEN RAISE EXCEPTION 'release_wh_quarantine: update pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;
