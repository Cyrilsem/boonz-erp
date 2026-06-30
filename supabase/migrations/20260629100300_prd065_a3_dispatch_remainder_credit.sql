-- PRD-065 A3 — lossless partial-fill / not-loaded capture at dispatch close.
-- HELD (writes warehouse_inventory + refill_dispatching). Apply on CS green light.
-- Dara note (important): return_dispatch_line CANNOT be reused verbatim for a partial fill -- it
-- returns the WHOLE line (sets filled_quantity=0 + returned=true), which would undo the units that
-- WERE loaded (the NOVO case: filled 2 of 6 -> we must credit only the 4 remainder, keep the 2).
-- So A3 = additive idempotency flag + a scoped remainder-credit RPC modelled on return_dispatch_line's
-- Refill branch (consumer_stock -> warehouse_stock on the pinned source row), fired at receive close.
-- Article 3: WH credit goes through this SECURITY DEFINER writer; explicit caller; GUC-audited +
-- explicit inventory_audit_log row. Idempotent via remainder_credited.

ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS remainder_credited boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.refill_dispatching.remainder_credited IS
  'PRD-065 A3: true once the (quantity - filled_quantity) not-loaded remainder has been credited back to WH. Idempotency marker.';

CREATE OR REPLACE FUNCTION public.credit_dispatch_remainder(
  p_dispatch_id uuid,
  p_caller_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_user_id   uuid := COALESCE(p_caller_id, auth.uid());
  v_d         public.refill_dispatching%ROWTYPE;
  v_remainder numeric;
  v_wh        public.warehouse_inventory%ROWTYPE;
  v_unreserve numeric;
  v_old       numeric;
BEGIN
  SELECT * INTO v_d FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'credit_dispatch_remainder: dispatch % not found', p_dispatch_id;
  END IF;

  -- idempotency / not-applicable guards (no-op)
  IF COALESCE(v_d.remainder_credited,false) THEN
    RETURN jsonb_build_object('status','already_done','dispatch_id',p_dispatch_id,'note','remainder already credited');
  END IF;
  IF COALESCE(v_d.returned,false) THEN
    RETURN jsonb_build_object('status','already_done','dispatch_id',p_dispatch_id,'note','line already returned (whole-line)');
  END IF;
  IF COALESCE(v_d.is_m2m,false) THEN
    RETURN jsonb_build_object('status','skipped','dispatch_id',p_dispatch_id,'note','M2M transfer out of scope (PRD-065)');
  END IF;
  IF v_d.action = 'Remove' THEN
    RETURN jsonb_build_object('status','skipped','dispatch_id',p_dispatch_id,'note','Remove line has no fill remainder');
  END IF;
  IF NOT COALESCE(v_d.item_added,false) THEN
    RETURN jsonb_build_object('status','skipped','dispatch_id',p_dispatch_id,'note','not yet received/closed; nothing to reconcile');
  END IF;

  v_remainder := COALESCE(v_d.quantity,0) - COALESCE(v_d.filled_quantity,0);
  IF v_remainder <= 0 THEN
    UPDATE public.refill_dispatching SET remainder_credited = true WHERE dispatch_id = p_dispatch_id; -- mark resolved
    RETURN jsonb_build_object('status','already_done','dispatch_id',p_dispatch_id,'remainder',0,'note','fully filled; no remainder');
  END IF;

  IF v_d.from_wh_inventory_id IS NULL THEN
    -- no pinned source row to credit: do not guess FEFO; surface for manual handling, do not mark resolved
    RETURN jsonb_build_object('status','unpinned_skip','dispatch_id',p_dispatch_id,'remainder',v_remainder,
                              'note','no from_wh_inventory_id pin; credit manually via adjust/return');
  END IF;

  SELECT * INTO v_wh FROM public.warehouse_inventory WHERE wh_inventory_id = v_d.from_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','unpinned_skip','dispatch_id',p_dispatch_id,'remainder',v_remainder,
                              'note','pinned wh row missing');
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'credit_dispatch_remainder', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_partial_remainder', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  PERFORM set_config('app.mutation_reason',
    format('A3 remainder credit dispatch=%s remainder=%s by=%s', p_dispatch_id, v_remainder, v_user_id), true);

  -- un-reserve the remainder: move from consumer_stock back to warehouse_stock (cap at reserved),
  -- crediting any shortfall straight to warehouse_stock so the not-loaded units are not lost.
  v_old := COALESCE(v_wh.warehouse_stock,0);
  v_unreserve := LEAST(COALESCE(v_wh.consumer_stock,0), v_remainder);
  UPDATE public.warehouse_inventory
  SET warehouse_stock = COALESCE(warehouse_stock,0) + v_remainder,
      consumer_stock  = GREATEST(0, COALESCE(consumer_stock,0) - v_unreserve)
  WHERE wh_inventory_id = v_wh.wh_inventory_id;

  INSERT INTO public.inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
  VALUES (v_wh.wh_inventory_id, v_wh.boonz_product_id, v_user_id, v_old, v_old + v_remainder,
          format('A3 partial remainder credit: dispatch %s filled %s of %s [warehouse_stock]',
                 p_dispatch_id, v_d.filled_quantity, v_d.quantity));

  UPDATE public.refill_dispatching SET remainder_credited = true WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object('status','credited','dispatch_id',p_dispatch_id,'remainder',v_remainder,
                            'wh_inventory_id',v_wh.wh_inventory_id,'unreserved',v_unreserve);
END;
$$;

REVOKE ALL ON FUNCTION public.credit_dispatch_remainder(uuid,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.credit_dispatch_remainder(uuid,uuid) TO authenticated, service_role;

-- Auto-fire at receive close: when item_added flips false->true and the line was under-filled.
-- Uses app.via_trigger so enforce_canonical_dispatch_write treats the inner row update as trusted.
CREATE OR REPLACE FUNCTION public.tg_credit_dispatch_remainder_on_receive()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF COALESCE(NEW.item_added,false) AND NOT COALESCE(OLD.item_added,false)
     AND COALESCE(NEW.filled_quantity,0) < COALESCE(NEW.quantity,0)
     AND NOT COALESCE(NEW.returned,false)
     AND NOT COALESCE(NEW.remainder_credited,false)
     AND NOT COALESCE(NEW.is_m2m,false)
     AND NEW.action <> 'Remove' THEN
    PERFORM set_config('app.via_trigger','true', true);
    PERFORM public.credit_dispatch_remainder(NEW.dispatch_id, NULL);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_credit_dispatch_remainder ON public.refill_dispatching;
CREATE TRIGGER trg_credit_dispatch_remainder
  AFTER UPDATE OF item_added ON public.refill_dispatching
  FOR EACH ROW
  WHEN (NEW.item_added = true AND COALESCE(OLD.item_added,false) = false)
  EXECUTE FUNCTION public.tg_credit_dispatch_remainder_on_receive();

-- DOWN:
-- DROP TRIGGER IF EXISTS trg_credit_dispatch_remainder ON public.refill_dispatching;
-- DROP FUNCTION IF EXISTS public.tg_credit_dispatch_remainder_on_receive();
-- DROP FUNCTION IF EXISTS public.credit_dispatch_remainder(uuid,uuid);
-- ALTER TABLE public.refill_dispatching DROP COLUMN IF EXISTS remainder_credited;
