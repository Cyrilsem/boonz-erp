-- PRD-144 P0-2 test: add_dispatch_row M2M legs are stamped like push_plan_to_dispatch's.
-- Runs as operator_admin (CS) inside one block and always ends with RAISE, so nothing persists.
-- PASS = the final error reads 'PRD144_P0_2 PASS ...'.
DO $t$
DECLARE
  f record; r_rem jsonb; r_add jsonb; a record; b record; v_bypass_before int; v_bypass_after int;
BEGIN
  SELECT s.machine_id src, scs.shelf_code src_shelf, d.machine_id dst, scd.shelf_code dst_shelf, s.boonz_product_id bp
    INTO f
    FROM pod_inventory s JOIN shelf_configurations scs ON scs.shelf_id = s.shelf_id
    JOIN pod_inventory d ON d.boonz_product_id = s.boonz_product_id AND d.machine_id <> s.machine_id AND d.status = 'Active'
    JOIN shelf_configurations scd ON scd.shelf_id = d.shelf_id
    JOIN slot_lifecycle sl ON sl.shelf_id = d.shelf_id AND sl.is_current AND NOT sl.archived
    JOIN product_mapping pm ON pm.pod_product_id = sl.pod_product_id AND pm.boonz_product_id = s.boonz_product_id AND pm.status = 'Active'
    JOIN slot_lifecycle sls ON sls.shelf_id = s.shelf_id AND sls.is_current AND NOT sls.archived AND sls.pod_product_id = sl.pod_product_id
   WHERE s.status = 'Active' AND s.current_stock > 3
   LIMIT 1;
  IF f.src IS NULL THEN RAISE EXCEPTION 'PRD144_P0_2 SKIP no fixture'; END IF;

  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  SELECT count(*) INTO v_bypass_before FROM refill_pack_bypass_log;

  r_rem := public.add_dispatch_row(f.src, f.src_shelf, f.bp, 2, 'Remove', '2099-02-01'::date, 'unknown', NULL, NULL, 'operator_admin', 'PRD-144 P0-2 test');
  r_add := public.add_dispatch_row(f.dst, f.dst_shelf, f.bp, 2, 'Refill', '2099-02-01'::date, 'm2m', NULL, f.src, 'operator_admin', 'PRD-144 P0-2 test', NULL, (r_rem->>'dispatch_id')::uuid);

  SELECT packed, pack_outcome::text po, dispatched, is_m2m, m2m_partner_id INTO a FROM refill_dispatching WHERE dispatch_id = (r_add->>'dispatch_id')::uuid;
  SELECT packed, pack_outcome::text po, dispatched, is_m2m, m2m_partner_id INTO b FROM refill_dispatching WHERE dispatch_id = (r_rem->>'dispatch_id')::uuid;
  SELECT count(*) INTO v_bypass_after FROM refill_pack_bypass_log;

  IF a.packed AND a.po = 'no_pack_needed' AND a.dispatched AND a.is_m2m
     AND b.packed AND b.po = 'no_pack_needed' AND b.dispatched AND b.is_m2m
     AND b.m2m_partner_id = (r_add->>'dispatch_id')::uuid
     AND v_bypass_after = v_bypass_before THEN
    RAISE EXCEPTION 'PRD144_P0_2 PASS add=% remove=% bypass_rows_added=%', row_to_json(a), row_to_json(b), v_bypass_after - v_bypass_before;
  END IF;
  RAISE EXCEPTION 'PRD144_P0_2 FAIL add=% remove=% bypass_rows_added=%', row_to_json(a), row_to_json(b), v_bypass_after - v_bypass_before;
END
$t$;
