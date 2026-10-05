-- VOX placeholder trap fix (reported 2026-10-05). Two bugs plus a new canonical RPC.
-- Rollback: supabase/migrations/20261005103600_vox_placeholder_trap_fix_rollback.sql
--
-- Classification: all three pieces touch warehouse_inventory / refill_dispatching writes --
-- warehouse-confirmation adjacent. Apply only 22:00-06:00 Dubai, per the reporting user's
-- explicit instruction. ensure_vox_placeholder is SECURITY DEFINER -- Cody review required.
--
-- Bug 1: pack_dispatch_line's v2 VOX GUARD sets refill_dispatching.bind_fail_reason =
-- 'no_venue_placeholder' when no 2099-12-31 placeholder row exists for the product, but the
-- check constraint only allowed ('no_stock','quarantined','inactive_batch','pinned_elsewhere').
-- The UPDATE threw 23514 and the pack screen showed a generic save failure instead of the
-- friendly bind_failed message already built into pack_dispatch_line's own RETURN payload.
-- Fix: add 'no_venue_placeholder' to the allowed vocabulary (drop + re-add, since Postgres has
-- no ALTER TABLE ... ALTER CONSTRAINT for CHECK value lists).
--
-- Bug 2: trg_enforce_warehouse_expiry_sanity (BEFORE INSERT OR UPDATE OF expiration_date on
-- warehouse_inventory) rejects any expiry more than 3 years after created_at, which makes it
-- impossible to create or transfer-create a VOX venue placeholder row -- pack_dispatch_line's
-- v2 VOX GUARD and transfer_warehouse_stock's destination-row INSERT both require
-- expiration_date = 2099-12-31 for these rows. Confirmed live 2026-10-05: a rolled-back
-- transfer_warehouse_stock call moving the existing WH_MCC sentinels to WH_MOE hit the exact
-- same P0001 error on the destination INSERT -- this bug blocks more than just placeholder
-- creation, it blocks anything that needs to create a NEW sentinel row at any warehouse.
-- Fix: exempt sentinel rows via the EXISTING public._is_sentinel_wh_row_v3(batch_id,
-- expiration_date) helper (already defined, batch_id LIKE 'VOXSOURCE-%' AND expiry =
-- 2099-12-31) -- early RETURN NEW before either date-sanity check, for sentinel rows only. No
-- other row's expiry window is loosened.
--
-- New RPC: ensure_vox_placeholder(p_boonz_product_id, p_warehouse_id, p_caller DEFAULT NULL)
-- creates or reactivates the VOX placeholder for one product+warehouse: finds an existing
-- sentinel row for that exact product+warehouse (matched structurally via
-- _is_sentinel_wh_row_v3, not by reconstructing an exact batch_id string, since the three
-- 2026-10-03 sentinels were hand-typed with ad hoc product abbreviations that a programmatic
-- slug won't reproduce) and tops it back up to 999 / Active / un-quarantined, or inserts a
-- fresh one with batch_id VOXSOURCE-<warehouse name>-<slugified product name>-999. Role-gated
-- to operator_admin/superadmin/warehouse. SECURITY DEFINER (writes warehouse_inventory).
--
-- No other function touched. pack_dispatch_line's existing VOX guard logic is unchanged -- it
-- already builds the correct bind_fail_reason/message, the constraint was the only thing
-- stopping it from being written.

-- Bug 1: constraint
ALTER TABLE public.refill_dispatching DROP CONSTRAINT refill_dispatching_bind_fail_reason_check;
ALTER TABLE public.refill_dispatching ADD CONSTRAINT refill_dispatching_bind_fail_reason_check
  CHECK (bind_fail_reason IS NULL OR bind_fail_reason = ANY (ARRAY[
    'no_stock'::text, 'quarantined'::text, 'inactive_batch'::text, 'pinned_elsewhere'::text,
    'no_venue_placeholder'::text
  ]));

-- Bug 2: trigger exemption for sentinel rows
CREATE OR REPLACE FUNCTION public.enforce_warehouse_expiry_sanity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_created date := COALESCE(NEW.created_at, now())::date;
BEGIN
  IF NEW.expiration_date IS NULL THEN
    RETURN NEW;
  END IF;

  -- VOX placeholder trap fix (2026-10-05): a sentinel row (VOXSOURCE-*, expiry 2099-12-31) is
  -- deliberately far-future by design -- it has no real shelf life, it exists only so
  -- pack_dispatch_line's VOX guard has something to draw from for venue-supplied lines. Every
  -- other row's expiry window is unchanged.
  IF public._is_sentinel_wh_row_v3(NEW.batch_id, NEW.expiration_date) THEN
    RETURN NEW;
  END IF;

  IF NEW.expiration_date > v_created + interval '3 years' THEN
    RAISE EXCEPTION 'warehouse_inventory.expiration_date: % is more than 3 years after created_at (%) for wh_inventory_id %', NEW.expiration_date, v_created, NEW.wh_inventory_id;
  END IF;

  IF NEW.expiration_date < v_created - interval '2 years' THEN
    RAISE EXCEPTION 'warehouse_inventory.expiration_date: % is more than 2 years before created_at (%) for wh_inventory_id %', NEW.expiration_date, v_created, NEW.wh_inventory_id;
  END IF;

  RETURN NEW;
END;
$function$;

-- New canonical RPC
CREATE OR REPLACE FUNCTION public.ensure_vox_placeholder(
  p_boonz_product_id uuid,
  p_warehouse_id uuid,
  p_caller uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := COALESCE(p_caller, auth.uid());
  v_role text;
  v_wh_name text;
  v_product_name text;
  v_existing warehouse_inventory%ROWTYPE;
  v_wh_inventory_id uuid;
  v_mode text;
  v_batch_id text;
BEGIN
  IF p_boonz_product_id IS NULL THEN RAISE EXCEPTION 'ensure_vox_placeholder: p_boonz_product_id is required'; END IF;
  IF p_warehouse_id IS NULL THEN RAISE EXCEPTION 'ensure_vox_placeholder: p_warehouse_id is required'; END IF;

  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller;
  IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','warehouse') THEN
    RAISE EXCEPTION 'forbidden: ensure_vox_placeholder requires operator_admin, superadmin, or warehouse (got %)', COALESCE(v_role,'none');
  END IF;

  SELECT name INTO v_wh_name FROM public.warehouses WHERE warehouse_id = p_warehouse_id;
  IF v_wh_name IS NULL THEN RAISE EXCEPTION 'ensure_vox_placeholder: warehouse % not found', p_warehouse_id; END IF;

  SELECT boonz_product_name INTO v_product_name FROM public.boonz_products WHERE product_id = p_boonz_product_id;
  IF v_product_name IS NULL THEN RAISE EXCEPTION 'ensure_vox_placeholder: boonz_product_id % not found', p_boonz_product_id; END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'ensure_vox_placeholder', true);
  PERFORM set_config('app.mutation_reason',
    format('ensure_vox_placeholder product=%s (%s) warehouse=%s (%s) by=%s',
      p_boonz_product_id, v_product_name, p_warehouse_id, v_wh_name, COALESCE(v_caller::text,'system')), true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);

  -- Reactivate an existing sentinel row for this exact product+warehouse if one exists (any
  -- VOXSOURCE-*, expiry 2099-12-31 row, matched structurally via _is_sentinel_wh_row_v3 --
  -- NOT by reconstructing an exact batch_id string, since earlier sentinels were hand-typed
  -- with ad hoc product abbreviations a programmatic slug can't reproduce).
  SELECT * INTO v_existing FROM public.warehouse_inventory
   WHERE boonz_product_id = p_boonz_product_id
     AND warehouse_id = p_warehouse_id
     AND public._is_sentinel_wh_row_v3(batch_id, expiration_date)
   ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    v_mode := 'reactivated';
    v_wh_inventory_id := v_existing.wh_inventory_id;
    UPDATE public.warehouse_inventory
       SET warehouse_stock = 999, status = 'Active', provenance_reason = 'manual_adjust',
           manually_quarantined = false
     WHERE wh_inventory_id = v_wh_inventory_id;
  ELSE
    v_mode := 'created';
    v_batch_id := format('VOXSOURCE-%s-%s-999', v_wh_name, upper(regexp_replace(v_product_name, '[^a-zA-Z0-9]', '', 'g')));
    INSERT INTO public.warehouse_inventory
      (boonz_product_id, warehouse_id, warehouse_stock, expiration_date, batch_id, status, snapshot_date, provenance_reason)
    VALUES (p_boonz_product_id, p_warehouse_id, 999, DATE '2099-12-31', v_batch_id, 'Active', CURRENT_DATE, 'manual_adjust')
    RETURNING wh_inventory_id INTO v_wh_inventory_id;
  END IF;

  RETURN jsonb_build_object('status', 'ok', 'mode', v_mode, 'wh_inventory_id', v_wh_inventory_id,
    'boonz_product_id', p_boonz_product_id, 'warehouse_id', p_warehouse_id, 'warehouse_stock', 999);
END;
$function$;
