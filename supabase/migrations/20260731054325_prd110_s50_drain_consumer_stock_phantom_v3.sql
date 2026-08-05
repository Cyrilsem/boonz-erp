-- PRD-110 S-50 · leg 43 · L43-U1 migration A
-- Sentinel retirement (P1.3) strands every sentinel carrying phantom consumer_stock,
-- because tg_propose_inactivate_on_zero_stock fires only when BOTH warehouse_stock=0
-- AND consumer_stock=0. Measured live: 5 of 40 sentinels carry consumer_stock > 0,
-- all with provenance_reason='dispatch_pack' (phantom stock packed from phantom stock).
--
-- The pre-existing writer public.drain_consumer_stock_phantom CANNOT run at all: it
-- INSERTs into inventory_audit_log.delta, which is GENERATED ALWAYS AS (new_qty-old_qty),
-- so every call raises 428C9. It is referenced by no function and no cron.
-- Article 13: it is NOT dropped here (no deprecation window, out of PRD-110 scope).
--
-- Cody (WARN) approve-with-revisions; all four revisions applied:
--   (1) sentinel-scoped - the general phantom-leak case stays with v_consumer_stock_leaks
--   (2) never writes status (Article 6) - the flip stays with the pre-existing trigger
--   (3) registered in RPC_REGISTRY.md; the broken sibling is parked, not dropped
--   (4) anon/PUBLIC EXECUTE revoked
--
-- AUDIT FOOTPRINT (measured at apply time, first attempt caught it): a consumer-only
-- drain leaves EXACTLY TWO inventory_audit_log rows -
--   1. the generic trg_audit_wh_inventory row, whose old_qty/new_qty come from
--      WAREHOUSE stock and are therefore equal (delta 0). It carries app.mutation_reason.
--   2. the explicit row written here, prefixed 'consumer_phantom_drain: ', which is the
--      only row that records the consumer delta.
-- app.mutation_reason therefore must NOT carry the prefix, or the two become
-- indistinguishable - that is precisely what the first apply attempt failed on.

CREATE OR REPLACE FUNCTION public.drain_consumer_stock_phantom_v3(
  p_wh_inventory_id uuid,
  p_reason          text,
  p_drained_by      uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_user_id       uuid;
  v_caller        text;
  v_row           public.warehouse_inventory%ROWTYPE;
  v_before        numeric;
  v_status_before text;
  v_status_after  text;
BEGIN
  -- Article 4: caller identity + role validation
  v_user_id := COALESCE(p_drained_by, auth.uid());
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom_v3: no caller identity';
  END IF;
  SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller IS NULL OR v_caller NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom_v3: forbidden for role %', COALESCE(v_caller,'unknown');
  END IF;

  -- Article 4: input validation
  IF p_wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom_v3: p_wh_inventory_id required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom_v3: p_reason is required (>= 10 chars) - phantom drain demands per-row CS audit text';
  END IF;

  -- Article 4/8: declare the write BEFORE touching the row, so the generic audit
  -- trigger attributes it and trg_detect_silent_warehouse_write trusts it.
  -- NOTE: mutation_reason is deliberately UNPREFIXED - see the header note.
  PERFORM set_config('app.via_rpc',           'true', true);
  PERFORM set_config('app.rpc_name',          'drain_consumer_stock_phantom_v3', true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  PERFORM set_config('app.mutation_reason',   p_reason, true);

  SELECT * INTO v_row
    FROM public.warehouse_inventory
   WHERE wh_inventory_id = p_wh_inventory_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom_v3: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  -- Cody revision 1 - SENTINEL SCOPE. A general consumer_stock-zeroing RPC on a
  -- protected entity is a far wider blast radius than this incident requires.
  IF NOT public._is_sentinel_wh_row_v3(v_row.batch_id, v_row.expiration_date) THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom_v3: % is not a sentinel row - refusing. General phantom leaks belong to v_consumer_stock_leaks / drain_phantom_consumer_stock_batch_run', p_wh_inventory_id;
  END IF;

  v_before        := COALESCE(v_row.consumer_stock, 0);
  v_status_before := v_row.status;

  IF v_before = 0 THEN
    RAISE EXCEPTION 'drain_consumer_stock_phantom_v3: wh_inventory_id % already has consumer_stock=0, nothing to drain', p_wh_inventory_id;
  END IF;

  -- Article 6 - consumer_stock ONLY. `status` is never assigned in this function.
  -- The Active -> Inactive flip remains with tg_propose_inactivate_on_zero_stock,
  -- which is the pre-existing exposure disclosed in PARKING-LOT D-09 / S-17.
  UPDATE public.warehouse_inventory
     SET consumer_stock = 0
   WHERE wh_inventory_id = p_wh_inventory_id;

  -- Article 7 - explicit, semantically-correct audit row. The generic row cannot
  -- express a consumer_stock change (it reads warehouse stock); this one can.
  -- /!\ `delta` is GENERATED ALWAYS AS (new_qty - old_qty). NEVER insert it.
  --     Inserting it is exactly the 428C9 bug that makes the v1 writer dead code.
  INSERT INTO public.inventory_audit_log
    (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, provenance_reason)
  VALUES
    (p_wh_inventory_id, v_row.boonz_product_id, v_user_id, v_before, 0,
     'consumer_phantom_drain: ' || p_reason, 'manual_adjust');

  SELECT status INTO v_status_after
    FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'wh_inventory_id',    p_wh_inventory_id,
    'boonz_product_id',   v_row.boonz_product_id,
    'old_consumer_stock', v_before,
    'new_consumer_stock', 0,
    'drained_units',      v_before,
    'warehouse_stock',    v_row.warehouse_stock,
    'status_before',      v_status_before,
    'status_after',       v_status_after,
    'reason',             p_reason,
    'drained_at',         now(),
    'drained_by',         v_user_id);
END
$fn$;

REVOKE ALL ON FUNCTION public.drain_consumer_stock_phantom_v3(uuid,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.drain_consumer_stock_phantom_v3(uuid,text,uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.drain_consumer_stock_phantom_v3(uuid,text,uuid) TO authenticated;

-- ============================================================================
-- PROOF, not assertion (leg-42 doctrine): actually RUN the function against a
-- real sentinel inside a subtransaction and roll it back. This is what catches
-- the generated-column class of defect at apply time rather than at fixture time.
-- ============================================================================
DO $proof$
DECLARE
  v_cs         uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  v_id         uuid;
  v_nonsent    uuid;
  v_res        jsonb;
  v_ok         boolean := false;
  v_scoped     boolean := false;
  v_cs_after   numeric;
  v_st_after   text;
  v_explicit   int;
  v_total      int;
BEGIN
  SELECT wh_inventory_id INTO v_id
    FROM public.warehouse_inventory
   WHERE public._is_sentinel_wh_row_v3(batch_id, expiration_date)
     AND COALESCE(consumer_stock,0) > 0
   ORDER BY wh_inventory_id LIMIT 1;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'PROOF ABORT: no sentinel with consumer_stock>0 - the S-50 premise is gone, re-baseline before shipping';
  END IF;

  BEGIN
    SELECT public.drain_consumer_stock_phantom_v3(
      v_id, 'PRD-110 S-50 apply-time proof: phantom consumer drain', v_cs) INTO v_res;

    SELECT consumer_stock, status INTO v_cs_after, v_st_after
      FROM public.warehouse_inventory WHERE wh_inventory_id = v_id;

    SELECT count(*) INTO v_explicit
      FROM public.inventory_audit_log
     WHERE wh_inventory_id = v_id
       AND reason LIKE 'consumer_phantom_drain:%'
       AND golden.written_by_this_txn(xmin);

    SELECT count(*) INTO v_total
      FROM public.inventory_audit_log
     WHERE wh_inventory_id = v_id
       AND golden.written_by_this_txn(xmin);

    -- non-sentinel rows must be refused (Cody revision 1)
    SELECT wh_inventory_id INTO v_nonsent
      FROM public.warehouse_inventory
     WHERE NOT public._is_sentinel_wh_row_v3(batch_id, expiration_date)
       AND COALESCE(consumer_stock,0) > 0
     ORDER BY wh_inventory_id LIMIT 1;
    IF v_nonsent IS NOT NULL THEN
      BEGIN
        PERFORM public.drain_consumer_stock_phantom_v3(
          v_nonsent, 'PRD-110 S-50 apply-time proof: must be refused', v_cs);
        v_scoped := false;
      EXCEPTION WHEN OTHERS THEN
        v_scoped := SQLERRM LIKE '%is not a sentinel row%';
      END;
    ELSE
      v_scoped := true;  -- nothing to test against; not a failure
    END IF;

    v_ok := (v_cs_after = 0)
        AND (v_st_after = (v_res->>'status_before'))   -- Article 6: status untouched
        AND (v_explicit = 1)                           -- exactly one SEMANTIC audit row
        AND (v_total    = 2)                           -- generic + explicit, nothing else
        AND ((v_res->>'drained_units')::numeric > 0)
        AND v_scoped;

    RAISE EXCEPTION 'PROOFDONE:%',
      jsonb_build_object('ok',v_ok,'cs_after',v_cs_after,'status_after',v_st_after,
                         'status_before',v_res->>'status_before','explicit_audit',v_explicit,
                         'total_audit',v_total,'drained',v_res->>'drained_units',
                         'scope_refused',v_scoped)::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'PROOFDONE:%' THEN
      v_res := substring(SQLERRM from 'PROOFDONE:(.*)$')::jsonb;
      v_ok  := (v_res->>'ok')::boolean;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'PRD-110 S-50: drain_consumer_stock_phantom_v3 failed its apply-time proof: %', v_res::text;
  END IF;
  RAISE NOTICE 'PRD-110 S-50 proof PASSED: %', v_res::text;
END
$proof$;

-- Post-guards
DO $g$
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE proname='drain_consumer_stock_phantom_v3') <> 1 THEN
    RAISE EXCEPTION 'guard: expected exactly one drain_consumer_stock_phantom_v3';
  END IF;
  IF (SELECT has_function_privilege('anon', oid, 'EXECUTE')
        FROM pg_proc WHERE proname='drain_consumer_stock_phantom_v3') THEN
    RAISE EXCEPTION 'guard: anon still has EXECUTE on drain_consumer_stock_phantom_v3';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE proname='drain_consumer_stock_phantom_v3') ~* 'SET\s+status\s*=' THEN
    RAISE EXCEPTION 'guard: Article 6 - the function must never assign status';
  END IF;
END
$g$;
