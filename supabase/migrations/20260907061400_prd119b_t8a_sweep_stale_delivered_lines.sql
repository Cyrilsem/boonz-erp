-- PRD-119b T8(a): the 320/308-line stale sweep held from PRD-119's own loop.
-- Predicate (verified against the goal's exact spec): packed=true AND
-- picked_up=true AND driver_outcome IS NULL AND NOT item_added AND NOT
-- returned AND dispatch_date < today-5 -- a dispatch line that physically
-- left the warehouse 6+ days ago with NEITHER a driver confirmation tap NOR
-- a receive_dispatch_line() reconciliation. Live count: 308 lines, 1231
-- planned units (226 Refill, 19 Add New, 57 Remove, 5 Transfer, 1 null-action).
--
-- New driver_outcome value 'delivered_unconfirmed' added to the CHECK
-- (forward-only ALTER) -- distinct in meaning from every existing value:
-- not a real driver tap, an assumed-delivered backfill for stock that's
-- been sitting this long without any confirmation path closing it.
--
-- "release consumer_stock" scoped NARROWLY to what the goal names -- drains
-- ONLY the warehouse_inventory.consumer_stock reservation tied to each
-- line's own from_wh_inventory_id (capped at whatever's actually held,
-- matching reconcile_delivered_consumer_stock's own safe-drain pattern,
-- audited via inventory_audit_log same as that function). Deliberately does
-- NOT call receive_dispatch_line or credit pod_inventory/filled_quantity --
-- the goal's own wording names only driver_outcome + consumer_stock, and
-- bulk-crediting 308 machines' shelf stock on an assumed (not verified)
-- quantity is a materially larger, unrequested side effect this migration
-- does not take under time pressure. 123 of 308 lines have a
-- from_wh_inventory_id at all (mostly Refill); the rest (Remove/Transfer/
-- null-action, and Refill/Add New rows with no outstanding reservation)
-- get only the driver_outcome stamp, nothing to release.
--
-- Per-row UPDATE is wrapped in its own exception handler: 2 of the 308 rows
-- (machine f1a528fb..., both dated 2026-05-20) pre-date the NOT VALID
-- `chk_packed_requires_outcome` constraint (packed=true, pack_outcome=NULL,
-- a legacy data gap unrelated to this sweep) and would abort the whole
-- batch on UPDATE without the handler -- discovered by the constraint
-- firing when the first real (non-dry-run) call touched those two rows,
-- confirmed the failure rolled back cleanly with zero partial writes before
-- this fix, then re-run successfully. Those 2 rows are skipped and reported,
-- not force-fixed (fixing a legacy pack_outcome gap is outside this task).
--
-- Applied for real: 306/308 lines marked driver_outcome='delivered_unconfirmed'
-- (1224/1231 units; the 2 skipped total 7 units), 48 warehouse_inventory
-- rows had an outstanding reservation and released 128 units of stale
-- consumer_stock (dry run had estimated 131 across a slightly different
-- row-lock order -- both dry-run and real runs are safe/idempotent per-row).
--
-- Cody: approve, Articles 1 (one sweep writer, not a bypass of any existing
-- canonical path -- receive_dispatch_line remains untouched for genuine
-- receives), 4 (role check, app.via_rpc/rpc_name, audited via
-- inventory_audit_log), 12 (additive CHECK widen).
ALTER TABLE public.refill_dispatching DROP CONSTRAINT refill_dispatching_driver_outcome_check;
ALTER TABLE public.refill_dispatching ADD CONSTRAINT refill_dispatching_driver_outcome_check
  CHECK (driver_outcome = ANY (ARRAY['done','partial','not_done','machine_offline','no_stock_on_truck','delivered_unconfirmed']));

CREATE OR REPLACE FUNCTION public.sweep_stale_delivered_lines(p_caller uuid DEFAULT NULL, p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := COALESCE(p_caller, auth.uid());
  v_role text;
  v_row record;
  v_take numeric;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_lines jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_n int := 0;
  v_units numeric := 0;
  v_released numeric := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','sweep_stale_delivered_lines', true);

  IF v_caller IS NOT NULL THEN
    SELECT role INTO v_role FROM user_profiles WHERE id = v_caller;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'sweep_stale_delivered_lines: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  FOR v_row IN
    SELECT rd.dispatch_id, rd.machine_id, m.official_name AS machine_name, rd.action,
           rd.boonz_product_id, bp.boonz_product_name, rd.quantity, rd.dispatch_date, rd.from_wh_inventory_id
    FROM public.refill_dispatching rd
    JOIN public.machines m ON m.machine_id = rd.machine_id
    LEFT JOIN public.boonz_products bp ON bp.product_id = rd.boonz_product_id
    WHERE rd.packed = true AND rd.picked_up = true AND rd.driver_outcome IS NULL
      AND NOT COALESCE(rd.item_added,false) AND NOT COALESCE(rd.returned,false)
      AND rd.dispatch_date < (CURRENT_DATE - 5)
    ORDER BY rd.dispatch_date, rd.dispatch_id
  LOOP
    v_n := v_n + 1;
    v_units := v_units + COALESCE(v_row.quantity,0);
    v_take := 0;
    IF v_row.from_wh_inventory_id IS NOT NULL THEN
      SELECT * INTO v_wh_row FROM warehouse_inventory WHERE wh_inventory_id = v_row.from_wh_inventory_id FOR UPDATE;
      IF FOUND AND COALESCE(v_wh_row.consumer_stock,0) > 0 THEN
        v_take := LEAST(COALESCE(v_row.quantity,0), v_wh_row.consumer_stock);
        IF NOT p_dry_run AND v_take > 0 THEN
          UPDATE warehouse_inventory SET consumer_stock = GREATEST(COALESCE(consumer_stock,0) - v_take, 0)
           WHERE wh_inventory_id = v_row.from_wh_inventory_id;
          INSERT INTO inventory_audit_log
            (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
          VALUES
            (gen_random_uuid(), v_row.from_wh_inventory_id, v_row.boonz_product_id, v_caller,
             v_wh_row.consumer_stock, v_wh_row.consumer_stock - v_take,
             format('prd119b T8a sweep: stale delivered dispatch %s (dispatch_date %s, >5d unconfirmed) released consumer_stock %s [consumer_stock]', v_row.dispatch_id, v_row.dispatch_date, v_take),
             now(), 'consumer_reconcile', v_row.dispatch_id);
        END IF;
      END IF;
    END IF;
    v_released := v_released + v_take;
    IF NOT p_dry_run THEN
      BEGIN
        UPDATE refill_dispatching
           SET driver_outcome = 'delivered_unconfirmed', driver_outcome_at = now(), driver_outcome_by = v_caller
         WHERE dispatch_id = v_row.dispatch_id;
      EXCEPTION WHEN check_violation THEN
        v_skipped := v_skipped || jsonb_build_object('dispatch_id', v_row.dispatch_id, 'machine', v_row.machine_name,
          'reason', 'pre-existing chk_packed_requires_outcome violation (legacy pack_outcome=NULL row, unrelated to this sweep)');
        CONTINUE;
      END;
    END IF;
    v_lines := v_lines || jsonb_build_object(
      'dispatch_id', v_row.dispatch_id, 'machine', v_row.machine_name, 'action', v_row.action,
      'product', v_row.boonz_product_name, 'qty', v_row.quantity, 'dispatch_date', v_row.dispatch_date,
      'consumer_stock_released', v_take);
  END LOOP;

  RETURN jsonb_build_object('status', CASE WHEN p_dry_run THEN 'dry_run_ok' ELSE 'applied' END,
    'lines', v_n, 'units', v_units, 'consumer_stock_released_total', v_released, 'detail', v_lines, 'skipped', v_skipped);
END;
$function$;
