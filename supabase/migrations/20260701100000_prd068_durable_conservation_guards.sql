-- PRD-068 durable: keep the refill log conserved going forward (the one-time data pass is already live).
-- Three additive guards. Forward-only, idempotent. Cody-reviewed.
--   1. not_filled invariant: pack_outcome='not_filled' => filled_quantity=0 (BEFORE trigger, always-on).
--   2. post-confirm conservation re-assert: when a driver confirm / field edit changes driver_confirmed_qty
--      on a REMOVE/M2W line, align that child's quantity to the confirmed physical qty and set the
--      pod_refill_plan parent to the resulting children sum, so check_pod_conservation cannot drift
--      post-publish. Mirrors the manual reconciliation pass.
--   3. daily conservation monitor cron: writes a monitoring_alerts row with the non-conserving rows +
--      the stitch_leakage day-total (the existing alert pipeline emails it).

-- 1. not_filled invariant --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_enforce_not_filled_zero()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.pack_outcome = 'not_filled' AND COALESCE(NEW.filled_quantity,0) <> 0 THEN
    NEW.filled_quantity := 0;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_not_filled_zero ON public.refill_dispatching;
CREATE TRIGGER trg_enforce_not_filled_zero
  BEFORE INSERT OR UPDATE OF pack_outcome, filled_quantity ON public.refill_dispatching
  FOR EACH ROW EXECUTE FUNCTION public.tg_enforce_not_filled_zero();

-- 2. post-confirm conservation re-assert -----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_reassert_conservation_on_confirm()
RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_sum numeric;
BEGIN
  PERFORM set_config('app.via_trigger','true', true);

  -- align this child's dispatched quantity to the driver-confirmed physical truth
  IF NEW.quantity IS DISTINCT FROM NEW.driver_confirmed_qty THEN
    UPDATE public.refill_dispatching
       SET quantity = NEW.driver_confirmed_qty
     WHERE dispatch_id = NEW.dispatch_id;
  END IF;

  -- recompute the children sum for this (machine, shelf, product, date) and set the plan parent
  SELECT COALESCE(SUM(quantity),0) INTO v_sum
  FROM public.refill_dispatching
  WHERE machine_id = NEW.machine_id AND shelf_id = NEW.shelf_id
    AND pod_product_id = NEW.pod_product_id AND dispatch_date = NEW.dispatch_date
    AND action IN ('Remove','Machine To Warehouse') AND COALESCE(cancelled,false) = false;

  UPDATE public.pod_refill_plan
     SET qty = v_sum, updated_at = now()
   WHERE machine_id = NEW.machine_id AND shelf_id = NEW.shelf_id
     AND pod_product_id = NEW.pod_product_id AND plan_date = NEW.dispatch_date
     AND action IN ('REMOVE','M2W');

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_reassert_conservation ON public.refill_dispatching;
CREATE TRIGGER trg_reassert_conservation
  AFTER UPDATE OF driver_confirmed_qty ON public.refill_dispatching
  FOR EACH ROW
  WHEN (NEW.action IN ('Remove','Machine To Warehouse')
        AND NEW.driver_confirmed_qty IS NOT NULL
        AND NEW.driver_confirmed_qty IS DISTINCT FROM OLD.driver_confirmed_qty
        AND COALESCE(NEW.cancelled,false) = false)
  EXECUTE FUNCTION public.tg_reassert_conservation_on_confirm();

-- 3. daily conservation monitor --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cron_conservation_monitor()
RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_rows jsonb;
  v_n int;
  v_leak_units numeric;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb), count(*)
    INTO v_rows, v_n
  FROM public.check_pod_conservation(v_today) c;

  SELECT COALESCE(SUM(abs(delta)),0) INTO v_leak_units
  FROM public.stitch_leakage WHERE plan_date = v_today;

  IF v_n > 0 THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('conservation_monitor', 'critical',
            jsonb_build_object('plan_date', v_today, 'violations', v_n,
                               'stitch_leakage_units', v_leak_units, 'rows', v_rows,
                               'note', 'check_pod_conservation non-zero; investigate before next publish'));
  END IF;

  RETURN jsonb_build_object('plan_date', v_today, 'violations', v_n, 'stitch_leakage_units', v_leak_units);
END;
$$;

DO $$
BEGIN
  PERFORM cron.unschedule('conservation_monitor_daily') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='conservation_monitor_daily');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
SELECT cron.schedule('conservation_monitor_daily', '30 3 * * *', $$SELECT public.cron_conservation_monitor();$$);

-- DOWN:
-- SELECT cron.unschedule('conservation_monitor_daily');
-- DROP FUNCTION IF EXISTS public.cron_conservation_monitor();
-- DROP TRIGGER IF EXISTS trg_reassert_conservation ON public.refill_dispatching;
-- DROP FUNCTION IF EXISTS public.tg_reassert_conservation_on_confirm();
-- DROP TRIGGER IF EXISTS trg_enforce_not_filled_zero ON public.refill_dispatching;
-- DROP FUNCTION IF EXISTS public.tg_enforce_not_filled_zero();
