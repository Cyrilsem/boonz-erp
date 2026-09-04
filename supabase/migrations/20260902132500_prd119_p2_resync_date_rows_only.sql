-- PRD-119 P2 / D0: resync_pod_inventory_from_weimi may REGISTER a physically-present
-- product with no lot as a DATE? (NULL-expiry) row, and may top up / trim / write off
-- ONLY that DATE? row. Dated lots are the human-touch-only ledger (D0) — this drift
-- engine must never change current_stock on one. Any drift that would previously have
-- been corrected by touching a dated batch is now left untouched and surfaced via a
-- new monitoring_alerts row (prd119_resync_dated_lot_blocked) instead of silently
-- either dropping the signal or wrongly mutating a dated lot.
--
-- Changes from the PRD-CLEAN-01 original:
--   1) product-mismatch write-off: DATE?-rows only; a dated mismatch is counted and
--      alerted instead of zeroed.
--   2) ledger-over-physical trim: DATE?-rows only; any excess the DATE? pool can't
--      absorb is left on the dated lot and alerted instead of trimmed from it.
--   3) ledger-under-physical top-up/insert: always a DATE? row — top up an existing
--      one, else INSERT a fresh one. The old "reuse a zero-stock dated row" / "merge
--      into the newest dated batch" fallback branches are removed entirely — no
--      longer needed, since the widened grain (PRD-119 P2 pod_inventory_expiry_grain,
--      idx_pod_inv_active_shelf_nulldate) lets a DATE? row coexist with a dated row
--      for the same product without any uniqueness conflict.
--   4) orphan (NULL shelf_id) write-off: DATE?-rows only; a dated orphan is alerted
--      instead of zeroed.
--
-- Verified live: captured every dated Active pod_inventory row's current_stock
-- before a REAL (non-dry-run) fleet-wide run, re-checked after — zero changed. One
-- prd119_resync_dated_lot_blocked alert correctly fired for the drift that would
-- have required a dated-lot write.
--
-- Cody: approve, Articles 1/4/8/12/16 — role gate and provenance unchanged, same
-- RETURNS TABLE signature, alert uses the established monitoring_alerts pattern
-- (prd113_fifo_expired_overflow / prd113_internal_move_flagged), remains the
-- canonical drift-truing engine.
DO $guard$ BEGIN
  IF (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p WHERE p.proname='resync_pod_inventory_from_weimi' AND p.pronamespace='public'::regnamespace) <> 'fdd8e631cab01fcdd78c3339a54b4717' THEN
    RAISE EXCEPTION 'resync_pod_inventory_from_weimi drifted, refusing blind replace';
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION public.resync_pod_inventory_from_weimi(p_machine_id uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT false)
 RETURNS TABLE(machine_id uuid, machine_name text, shelves_touched integer, units_written_off numeric, units_added_unattributed numeric, orphan_rows_zeroed integer, shelves_skipped_no_weimi integer, skipped_reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_role text;
  v_run_ref text := 'drift-resync-' || to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai', 'YYYYMMDD"T"HH24MISS');
  v_today date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  m RECORD; s RECORD; r RECORD;
  v_snap timestamptz; v_tot numeric; v_excess numeric; v_diff numeric; v_dec numeric;
  v_touched boolean; v_shelves integer; v_off numeric; v_added numeric; v_orphans integer; v_skipped integer;
  v_target uuid; v_target_boonz uuid; v_target_old numeric;
  v_dated_blocked_n integer := 0; v_dated_blocked_units numeric := 0; v_dated_blocked_detail jsonb := '[]'::jsonb;
BEGIN
  IF v_user IS NOT NULL THEN
    SELECT up.role INTO v_role FROM user_profiles up WHERE up.id = v_user;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'resync_pod_inventory_from_weimi: forbidden for role %', COALESCE(v_role, 'unknown');
    END IF;
  END IF;
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'resync_pod_inventory_from_weimi', true);
  PERFORM set_config('app.mutation_reason', format('PRD-119 P2 weimi-authoritative resync (DATE?-rows-only) run=%s dry_run=%s by=%s', v_run_ref, p_dry_run, v_user), true);
  FOR m IN
    SELECT mm.machine_id AS mid, mm.official_name AS mname FROM machines mm
    WHERE (p_machine_id IS NULL OR mm.machine_id = p_machine_id)
      AND (EXISTS (SELECT 1 FROM pod_inventory pi WHERE pi.machine_id = mm.machine_id AND pi.status = 'Active' AND pi.current_stock > 0)
        OR EXISTS (SELECT 1 FROM v_shelf_slot_identity vsi WHERE vsi.machine_id = mm.machine_id))
    ORDER BY mm.official_name
  LOOP
    v_shelves := 0; v_off := 0; v_added := 0; v_orphans := 0; v_skipped := 0;
    SELECT MAX(vls.snapshot_at) INTO v_snap FROM v_live_shelf_stock vls WHERE vls.machine_id = m.mid;
    IF v_snap IS NULL OR v_snap < CURRENT_TIMESTAMP - interval '48 hours' THEN
      machine_id := m.mid; machine_name := m.mname; shelves_touched := 0; units_written_off := 0;
      units_added_unattributed := 0; orphan_rows_zeroed := 0; shelves_skipped_no_weimi := 0;
      skipped_reason := COALESCE('stale_weimi_snapshot:' || v_snap::text, 'no_weimi_snapshot');
      RETURN NEXT; CONTINUE;
    END IF;
    SELECT COUNT(*) INTO v_skipped FROM shelf_configurations sc
    WHERE sc.machine_id = m.mid AND NOT EXISTS (SELECT 1 FROM v_shelf_slot_identity vsi WHERE vsi.shelf_id = sc.shelf_id)
      AND EXISTS (SELECT 1 FROM pod_inventory pi WHERE pi.machine_id = m.mid AND pi.shelf_id = sc.shelf_id AND pi.status = 'Active' AND pi.current_stock > 0);
    FOR s IN
      SELECT vsi.shelf_id AS sid, vsi.pod_product_id AS pid, COALESCE(vsi.current_stock, 0) AS physical
      FROM v_shelf_slot_identity vsi WHERE vsi.machine_id = m.mid
    LOOP
      v_touched := false;
      IF s.pid IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;
      FOR r IN
        SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date FROM pod_inventory pi
        WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid AND pi.status = 'Active' AND pi.current_stock > 0
          AND pi.expiration_date IS NULL
          AND NOT EXISTS (SELECT 1 FROM product_mapping pm WHERE pm.pod_product_id = s.pid AND pm.boonz_product_id = pi.boonz_product_id AND pm.status = 'Active')
      LOOP
        IF NOT p_dry_run THEN
          UPDATE pod_inventory pi SET current_stock = 0 WHERE pi.pod_inventory_id = r.pod_inventory_id;
          INSERT INTO pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date, source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
          VALUES (r.pod_inventory_id, m.mid, s.sid, r.boonz_product_id, r.expiration_date, 'drift_resync', 'update', r.current_stock, 0, -r.current_stock, v_user, v_run_ref, 'drift_resync_product_mismatch');
        END IF;
        v_off := v_off + r.current_stock; v_touched := true;
      END LOOP;
      FOR r IN
        SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date FROM pod_inventory pi
        WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid AND pi.status = 'Active' AND pi.current_stock > 0
          AND pi.expiration_date IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM product_mapping pm WHERE pm.pod_product_id = s.pid AND pm.boonz_product_id = pi.boonz_product_id AND pm.status = 'Active')
      LOOP
        v_dated_blocked_n := v_dated_blocked_n + 1; v_dated_blocked_units := v_dated_blocked_units + r.current_stock;
        IF v_dated_blocked_n <= 200 THEN
          v_dated_blocked_detail := v_dated_blocked_detail || jsonb_build_object('kind', 'product_mismatch', 'machine', m.mname, 'shelf_id', s.sid, 'pod_inventory_id', r.pod_inventory_id, 'boonz_product_id', r.boonz_product_id, 'expiration_date', r.expiration_date, 'current_stock', r.current_stock);
        END IF;
      END LOOP;
      SELECT COALESCE(SUM(pi.current_stock), 0) INTO v_tot FROM pod_inventory pi
      WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid AND pi.status = 'Active' AND pi.current_stock > 0
        AND EXISTS (SELECT 1 FROM product_mapping pm WHERE pm.pod_product_id = s.pid AND pm.boonz_product_id = pi.boonz_product_id AND pm.status = 'Active');
      IF v_tot > s.physical THEN
        v_excess := v_tot - s.physical;
        FOR r IN
          SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date FROM pod_inventory pi
          WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid AND pi.status = 'Active' AND pi.current_stock > 0
            AND pi.expiration_date IS NULL
            AND EXISTS (SELECT 1 FROM product_mapping pm WHERE pm.pod_product_id = s.pid AND pm.boonz_product_id = pi.boonz_product_id AND pm.status = 'Active')
          ORDER BY pi.created_at ASC
        LOOP
          EXIT WHEN v_excess <= 0;
          v_dec := LEAST(r.current_stock, v_excess);
          IF NOT p_dry_run THEN
            UPDATE pod_inventory pi SET current_stock = pi.current_stock - v_dec WHERE pi.pod_inventory_id = r.pod_inventory_id;
            INSERT INTO pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date, source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
            VALUES (r.pod_inventory_id, m.mid, s.sid, r.boonz_product_id, r.expiration_date, 'drift_resync', 'update', r.current_stock, r.current_stock - v_dec, -v_dec, v_user, v_run_ref, 'drift_resync');
          END IF;
          v_excess := v_excess - v_dec; v_off := v_off + v_dec; v_touched := true;
        END LOOP;
        IF v_excess > 0 THEN
          v_dated_blocked_n := v_dated_blocked_n + 1; v_dated_blocked_units := v_dated_blocked_units + v_excess;
          IF v_dated_blocked_n <= 200 THEN
            v_dated_blocked_detail := v_dated_blocked_detail || jsonb_build_object('kind', 'ledger_over_physical_dated_remainder', 'machine', m.mname, 'shelf_id', s.sid, 'pod_product_id', s.pid, 'excess_units', v_excess);
          END IF;
        END IF;
      ELSIF v_tot < s.physical THEN
        v_diff := s.physical - v_tot; v_target := NULL; v_target_boonz := NULL; v_target_old := NULL;
        SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock INTO v_target, v_target_boonz, v_target_old
        FROM pod_inventory pi
        WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid AND pi.status = 'Active' AND pi.expiration_date IS NULL
          AND EXISTS (SELECT 1 FROM product_mapping pm WHERE pm.pod_product_id = s.pid AND pm.boonz_product_id = pi.boonz_product_id AND pm.status = 'Active')
        ORDER BY pi.created_at DESC LIMIT 1;
        IF v_target IS NOT NULL THEN
          IF NOT p_dry_run THEN
            UPDATE pod_inventory pi SET current_stock = pi.current_stock + v_diff WHERE pi.pod_inventory_id = v_target;
            INSERT INTO pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date, source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
            VALUES (v_target, m.mid, s.sid, v_target_boonz, NULL, 'drift_resync', 'update', v_target_old, v_target_old + v_diff, v_diff, v_user, v_run_ref, 'drift_resync_unattributed');
          END IF;
          v_added := v_added + v_diff; v_touched := true;
        ELSE
          SELECT pm.boonz_product_id INTO v_target_boonz FROM product_mapping pm
          WHERE pm.pod_product_id = s.pid AND pm.status = 'Active'
          ORDER BY (pm.machine_id = m.mid) DESC NULLS LAST, COALESCE(pm.is_global_default, false) DESC, pm.mix_weight DESC NULLS LAST, pm.split_pct DESC NULLS LAST, pm.created_at DESC
          LIMIT 1;
          IF v_target_boonz IS NOT NULL THEN
            IF NOT p_dry_run THEN
              INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, batch_id, status)
              VALUES (m.mid, s.sid, v_target_boonz, v_today, v_diff, NULL, NULL, 'Active') RETURNING pod_inventory_id INTO v_target;
              INSERT INTO pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date, source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
              VALUES (v_target, m.mid, s.sid, v_target_boonz, NULL, 'drift_resync', 'insert', 0, v_diff, v_diff, v_user, v_run_ref, 'drift_resync_unattributed');
            END IF;
            v_added := v_added + v_diff; v_touched := true;
          ELSE
            v_skipped := v_skipped + 1;
          END IF;
        END IF;
      END IF;
      IF v_touched THEN v_shelves := v_shelves + 1; END IF;
    END LOOP;
    FOR r IN
      SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date FROM pod_inventory pi
      WHERE pi.machine_id = m.mid AND pi.shelf_id IS NULL AND pi.status = 'Active' AND pi.current_stock > 0 AND pi.expiration_date IS NULL
    LOOP
      IF NOT p_dry_run THEN
        UPDATE pod_inventory pi SET current_stock = 0 WHERE pi.pod_inventory_id = r.pod_inventory_id;
        INSERT INTO pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date, source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
        VALUES (r.pod_inventory_id, m.mid, NULL, r.boonz_product_id, r.expiration_date, 'drift_resync', 'update', r.current_stock, 0, -r.current_stock, v_user, v_run_ref, 'drift_resync_orphan_null_shelf');
      END IF;
      v_orphans := v_orphans + 1; v_off := v_off + r.current_stock;
    END LOOP;
    FOR r IN
      SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date FROM pod_inventory pi
      WHERE pi.machine_id = m.mid AND pi.shelf_id IS NULL AND pi.status = 'Active' AND pi.current_stock > 0 AND pi.expiration_date IS NOT NULL
    LOOP
      v_dated_blocked_n := v_dated_blocked_n + 1; v_dated_blocked_units := v_dated_blocked_units + r.current_stock;
      IF v_dated_blocked_n <= 200 THEN
        v_dated_blocked_detail := v_dated_blocked_detail || jsonb_build_object('kind', 'dated_orphan_null_shelf', 'machine', m.mname, 'pod_inventory_id', r.pod_inventory_id, 'boonz_product_id', r.boonz_product_id, 'expiration_date', r.expiration_date, 'current_stock', r.current_stock);
      END IF;
    END LOOP;
    machine_id := m.mid; machine_name := m.mname; shelves_touched := v_shelves; units_written_off := v_off;
    units_added_unattributed := v_added; orphan_rows_zeroed := v_orphans; shelves_skipped_no_weimi := v_skipped; skipped_reason := NULL;
    RETURN NEXT;
  END LOOP;
  IF v_dated_blocked_n > 0 AND NOT p_dry_run THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('prd119_resync_dated_lot_blocked', CASE WHEN v_dated_blocked_units >= 20 THEN 'warning' ELSE 'info' END,
      jsonb_build_object('ran_at', now(), 'run_ref', v_run_ref, 'blocked_count', v_dated_blocked_n, 'blocked_units', v_dated_blocked_units,
        'detail_capped_at', 200, 'detail', v_dated_blocked_detail,
        'message', 'resync_pod_inventory_from_weimi found drift that would have required changing current_stock on a DATED lot. Per PRD-119 D0, dated lots are the human-touch-only ledger - resync never writes to them. Reconcile these manually via correct_expiry_v1 / adjust_pod_inventory / a driver expiry-check tap.'));
  END IF;
END;
$function$;
