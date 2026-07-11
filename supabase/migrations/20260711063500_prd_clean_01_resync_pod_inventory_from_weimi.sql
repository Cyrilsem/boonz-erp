-- PRD-CLEAN-01 M1 (DDL): resync_pod_inventory_from_weimi + audit source CHECK extension
-- Weimi physical count is authoritative for pod_inventory quantities (approved by CS 2026-07-11).
-- Every write is logged to pod_inventory_audit_log with source='drift_resync',
-- reference_id='drift-resync-<run>' and the sub-reason in notes.

-- 1) allow 'drift_resync' as an audit source
ALTER TABLE public.pod_inventory_audit_log DROP CONSTRAINT pod_inventory_audit_log_source_check;
ALTER TABLE public.pod_inventory_audit_log ADD CONSTRAINT pod_inventory_audit_log_source_check
  CHECK ((source = ANY (ARRAY['seed'::text, 'sale'::text, 'refill'::text, 'manual_edit'::text,
                              'weimi_sync'::text, 'correction'::text, 'cleanup'::text, 'drift_resync'::text])));

-- 2) the resync RPC
CREATE OR REPLACE FUNCTION public.resync_pod_inventory_from_weimi(
  p_machine_id uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT false
)
RETURNS TABLE(
  machine_id uuid,
  machine_name text,
  shelves_touched integer,
  units_written_off numeric,
  units_added_unattributed numeric,
  orphan_rows_zeroed integer,
  shelves_skipped_no_weimi integer,
  skipped_reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_role text;
  v_run_ref text := 'drift-resync-' || to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai', 'YYYYMMDD"T"HH24MISS');
  v_today date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  m RECORD;
  s RECORD;
  r RECORD;
  v_snap timestamptz;
  v_tot numeric;
  v_excess numeric;
  v_diff numeric;
  v_dec numeric;
  v_touched boolean;
  v_shelves integer;
  v_off numeric;
  v_added numeric;
  v_orphans integer;
  v_skipped integer;
  v_target uuid;
  v_target_boonz uuid;
  v_target_old numeric;
  v_target_exp date;
BEGIN
  IF v_user IS NOT NULL THEN
    SELECT up.role INTO v_role FROM user_profiles up WHERE up.id = v_user;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'resync_pod_inventory_from_weimi: forbidden for role %', COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'resync_pod_inventory_from_weimi', true);
  PERFORM set_config('app.mutation_reason',
    format('PRD-CLEAN-01 weimi-authoritative resync run=%s dry_run=%s by=%s', v_run_ref, p_dry_run, v_user), true);

  FOR m IN
    SELECT mm.machine_id AS mid, mm.official_name AS mname
    FROM machines mm
    WHERE (p_machine_id IS NULL OR mm.machine_id = p_machine_id)
      AND (EXISTS (SELECT 1 FROM pod_inventory pi
                   WHERE pi.machine_id = mm.machine_id AND pi.status = 'Active' AND pi.current_stock > 0)
        OR EXISTS (SELECT 1 FROM v_shelf_slot_identity vsi WHERE vsi.machine_id = mm.machine_id))
    ORDER BY mm.official_name
  LOOP
    v_shelves := 0; v_off := 0; v_added := 0; v_orphans := 0; v_skipped := 0;

    SELECT MAX(vls.snapshot_at) INTO v_snap
    FROM v_live_shelf_stock vls WHERE vls.machine_id = m.mid;

    -- never zero a machine on missing/stale data (Weimi staleness is a known silent failure)
    IF v_snap IS NULL OR v_snap < CURRENT_TIMESTAMP - interval '48 hours' THEN
      machine_id := m.mid; machine_name := m.mname;
      shelves_touched := 0; units_written_off := 0; units_added_unattributed := 0;
      orphan_rows_zeroed := 0; shelves_skipped_no_weimi := 0;
      skipped_reason := COALESCE('stale_weimi_snapshot:' || v_snap::text, 'no_weimi_snapshot');
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- shelves holding ledger stock that are absent from the fresh snapshot: skip, report
    SELECT COUNT(*) INTO v_skipped
    FROM shelf_configurations sc
    WHERE sc.machine_id = m.mid
      AND NOT EXISTS (SELECT 1 FROM v_shelf_slot_identity vsi WHERE vsi.shelf_id = sc.shelf_id)
      AND EXISTS (SELECT 1 FROM pod_inventory pi
                  WHERE pi.machine_id = m.mid AND pi.shelf_id = sc.shelf_id
                    AND pi.status = 'Active' AND pi.current_stock > 0);

    FOR s IN
      SELECT vsi.shelf_id AS sid, vsi.pod_product_id AS pid, COALESCE(vsi.current_stock, 0) AS physical
      FROM v_shelf_slot_identity vsi
      WHERE vsi.machine_id = m.mid
    LOOP
      v_touched := false;

      IF s.pid IS NULL THEN
        -- Weimi product unresolved: quantity truth exists but product identity does not.
        -- Skip rather than guess (0 such shelves at build time).
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- 1) product mismatch: ledger rows whose boonz product has no Active mapping
      --    to the Weimi product on this shelf -> write off to zero
      FOR r IN
        SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date
        FROM pod_inventory pi
        WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid
          AND pi.status = 'Active' AND pi.current_stock > 0
          AND NOT EXISTS (
            SELECT 1 FROM product_mapping pm
            WHERE pm.pod_product_id = s.pid
              AND pm.boonz_product_id = pi.boonz_product_id
              AND pm.status = 'Active')
      LOOP
        IF NOT p_dry_run THEN
          UPDATE pod_inventory pi SET current_stock = 0 WHERE pi.pod_inventory_id = r.pod_inventory_id;
          INSERT INTO pod_inventory_audit_log
            (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
             source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
          VALUES
            (r.pod_inventory_id, m.mid, s.sid, r.boonz_product_id, r.expiration_date,
             'drift_resync', 'update', r.current_stock, 0, -r.current_stock, v_user, v_run_ref,
             'drift_resync_product_mismatch');
        END IF;
        v_off := v_off + r.current_stock;
        v_touched := true;
      END LOOP;

      -- matching ledger total (mismatch rows excluded by the mapping filter, so dry-run safe)
      SELECT COALESCE(SUM(pi.current_stock), 0) INTO v_tot
      FROM pod_inventory pi
      WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid
        AND pi.status = 'Active' AND pi.current_stock > 0
        AND EXISTS (
          SELECT 1 FROM product_mapping pm
          WHERE pm.pod_product_id = s.pid
            AND pm.boonz_product_id = pi.boonz_product_id
            AND pm.status = 'Active');

      -- 2) ledger over physical: trim OLDEST batches first (FIFO survivors are newest)
      IF v_tot > s.physical THEN
        v_excess := v_tot - s.physical;
        FOR r IN
          SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date
          FROM pod_inventory pi
          WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid
            AND pi.status = 'Active' AND pi.current_stock > 0
            AND EXISTS (
              SELECT 1 FROM product_mapping pm
              WHERE pm.pod_product_id = s.pid
                AND pm.boonz_product_id = pi.boonz_product_id
                AND pm.status = 'Active')
          ORDER BY pi.expiration_date ASC NULLS LAST, pi.created_at ASC
        LOOP
          EXIT WHEN v_excess <= 0;
          v_dec := LEAST(r.current_stock, v_excess);
          IF NOT p_dry_run THEN
            UPDATE pod_inventory pi SET current_stock = pi.current_stock - v_dec
            WHERE pi.pod_inventory_id = r.pod_inventory_id;
            INSERT INTO pod_inventory_audit_log
              (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
               source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
            VALUES
              (r.pod_inventory_id, m.mid, s.sid, r.boonz_product_id, r.expiration_date,
               'drift_resync', 'update', r.current_stock, r.current_stock - v_dec, -v_dec, v_user, v_run_ref,
               'drift_resync');
          END IF;
          v_excess := v_excess - v_dec;
          v_off := v_off + v_dec;
          v_touched := true;
        END LOOP;

      -- 3) ledger under physical: add the remainder as unattributed (NULL expiry) stock
      ELSIF v_tot < s.physical THEN
        v_diff := s.physical - v_tot;
        v_target := NULL; v_target_boonz := NULL; v_target_old := NULL; v_target_exp := NULL;

        -- a) existing NULL-expiry matching Active row: top it up (unique index forbids a 2nd row)
        SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock
          INTO v_target, v_target_boonz, v_target_old
        FROM pod_inventory pi
        WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid
          AND pi.status = 'Active' AND pi.expiration_date IS NULL
          AND EXISTS (
            SELECT 1 FROM product_mapping pm
            WHERE pm.pod_product_id = s.pid
              AND pm.boonz_product_id = pi.boonz_product_id
              AND pm.status = 'Active')
        ORDER BY pi.created_at DESC
        LIMIT 1;

        IF v_target IS NOT NULL THEN
          IF NOT p_dry_run THEN
            UPDATE pod_inventory pi SET current_stock = pi.current_stock + v_diff
            WHERE pi.pod_inventory_id = v_target;
            INSERT INTO pod_inventory_audit_log
              (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
               source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
            VALUES
              (v_target, m.mid, s.sid, v_target_boonz, NULL,
               'drift_resync', 'update', v_target_old, v_target_old + v_diff, v_diff, v_user, v_run_ref,
               'drift_resync_unattributed');
          END IF;
          v_added := v_added + v_diff;
          v_touched := true;
        ELSE
          -- b) mapped boonz product with NO Active row on this shelf: insert the NULL-expiry marker row
          SELECT pm.boonz_product_id INTO v_target_boonz
          FROM product_mapping pm
          WHERE pm.pod_product_id = s.pid AND pm.status = 'Active'
            AND NOT EXISTS (
              SELECT 1 FROM pod_inventory pi2
              WHERE pi2.machine_id = m.mid AND pi2.shelf_id = s.sid
                AND pi2.boonz_product_id = pm.boonz_product_id AND pi2.status = 'Active')
          ORDER BY (pm.machine_id = m.mid) DESC NULLS LAST,
                   COALESCE(pm.is_global_default, false) DESC,
                   pm.mix_weight DESC NULLS LAST,
                   pm.split_pct DESC NULLS LAST,
                   pm.created_at DESC
          LIMIT 1;

          IF v_target_boonz IS NOT NULL THEN
            IF NOT p_dry_run THEN
              INSERT INTO pod_inventory
                (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock,
                 expiration_date, batch_id, status)
              VALUES
                (m.mid, s.sid, v_target_boonz, v_today, v_diff, NULL, NULL, 'Active')
              RETURNING pod_inventory_id INTO v_target;
              INSERT INTO pod_inventory_audit_log
                (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
                 source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
              VALUES
                (v_target, m.mid, s.sid, v_target_boonz, NULL,
                 'drift_resync', 'insert', 0, v_diff, v_diff, v_user, v_run_ref,
                 'drift_resync_unattributed');
            END IF;
            v_added := v_added + v_diff;
            v_touched := true;
          ELSE
            -- c) every mapped boonz already has an Active row here:
            --    prefer converting a zero-stock row into the unattributed bucket,
            --    else merge into the newest dated batch (logged as such)
            SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date
              INTO v_target, v_target_boonz, v_target_old, v_target_exp
            FROM pod_inventory pi
            WHERE pi.machine_id = m.mid AND pi.shelf_id = s.sid
              AND pi.status = 'Active'
              AND EXISTS (
                SELECT 1 FROM product_mapping pm
                WHERE pm.pod_product_id = s.pid
                  AND pm.boonz_product_id = pi.boonz_product_id
                  AND pm.status = 'Active')
            ORDER BY (pi.current_stock > 0) ASC, pi.expiration_date DESC NULLS FIRST, pi.created_at DESC
            LIMIT 1;

            IF v_target IS NOT NULL THEN
              IF NOT p_dry_run THEN
                IF COALESCE(v_target_old, 0) = 0 THEN
                  UPDATE pod_inventory pi
                  SET current_stock = v_diff, expiration_date = NULL, batch_id = NULL
                  WHERE pi.pod_inventory_id = v_target;
                ELSE
                  UPDATE pod_inventory pi SET current_stock = pi.current_stock + v_diff
                  WHERE pi.pod_inventory_id = v_target;
                END IF;
                INSERT INTO pod_inventory_audit_log
                  (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
                   source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
                VALUES
                  (v_target, m.mid, s.sid, v_target_boonz, v_target_exp,
                   'drift_resync', 'update', COALESCE(v_target_old, 0), COALESCE(v_target_old, 0) + v_diff,
                   v_diff, v_user, v_run_ref,
                   CASE WHEN COALESCE(v_target_old, 0) = 0
                        THEN 'drift_resync_unattributed'
                        ELSE 'drift_resync_unattributed_merged_into_dated_batch' END);
              END IF;
              v_added := v_added + v_diff;
              v_touched := true;
            ELSE
              v_skipped := v_skipped + 1;  -- no mapping at all: cannot attribute, report
            END IF;
          END IF;
        END IF;
      END IF;

      IF v_touched THEN
        v_shelves := v_shelves + 1;
      END IF;
    END LOOP;

    -- 4) orphan rows: Active stock with NULL shelf_id can never reconcile to a shelf -> write off
    FOR r IN
      SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.current_stock, pi.expiration_date
      FROM pod_inventory pi
      WHERE pi.machine_id = m.mid AND pi.shelf_id IS NULL
        AND pi.status = 'Active' AND pi.current_stock > 0
    LOOP
      IF NOT p_dry_run THEN
        UPDATE pod_inventory pi SET current_stock = 0 WHERE pi.pod_inventory_id = r.pod_inventory_id;
        INSERT INTO pod_inventory_audit_log
          (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
           source, operation, old_stock, new_stock, delta, actor, reference_id, notes)
        VALUES
          (r.pod_inventory_id, m.mid, NULL, r.boonz_product_id, r.expiration_date,
           'drift_resync', 'update', r.current_stock, 0, -r.current_stock, v_user, v_run_ref,
           'drift_resync_orphan_null_shelf');
      END IF;
      v_orphans := v_orphans + 1;
      v_off := v_off + r.current_stock;
    END LOOP;

    machine_id := m.mid;
    machine_name := m.mname;
    shelves_touched := v_shelves;
    units_written_off := v_off;
    units_added_unattributed := v_added;
    orphan_rows_zeroed := v_orphans;
    shelves_skipped_no_weimi := v_skipped;
    skipped_reason := NULL;
    RETURN NEXT;
  END LOOP;
END;
$function$;

COMMENT ON FUNCTION public.resync_pod_inventory_from_weimi(uuid, boolean) IS
'PRD-CLEAN-01: Weimi-authoritative pod_inventory resync. Per shelf (v_shelf_slot_identity, slot_name join): zeroes product-mismatch rows, trims oldest batches (FIFO) when ledger > physical, adds NULL-expiry unattributed stock when ledger < physical. Skips machines without a <48h Weimi snapshot. Idempotent. All writes audited with source=drift_resync, reference_id=drift-resync-<run>.';
