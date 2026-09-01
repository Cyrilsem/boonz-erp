-- PRD-118 item C, Gate-2: refuse to complete approve_refill_plan while any non-M2M,
-- non-venue fill row for this date/machine set reached dispatch unbound
-- (from_wh_inventory_id NULL, quantity>0). Report the offending rows; never fail
-- silently.
--
-- The check runs AFTER the UPDATE ... operator_status='approved' (which fires
-- trg_refill_plan_output_approve_to_dispatch -> push_plan_to_dispatch, the sole
-- dispatch writer). Raising here rolls back this function's subtransaction --
-- including that UPDATE and everything push_plan_to_dispatch's trigger cascade just
-- wrote -- so a failed gate means NOTHING was approved, not a partial/silent approval.
-- The function's existing EXCEPTION WHEN OTHERS handler (unchanged) catches it and
-- returns a clean structured error naming exactly which rows failed
-- (machine/shelf/product/qty/dispatch_id).
--
-- Verified against md5 969118b6cc8206b9f9a499cab684bb97. Live test (2026-06-26,
-- MPMCC-1058-0000-R0, never touching any current/future plan date): a clean pass with
-- 0 dispatch rows present correctly found 0 Gate-2 violations, confirming no
-- false-positive when there is nothing to flag.
-- Cody: approve, Articles 1/4/12 -- no new write path, tightens an existing canonical
-- writer's own completion condition using columns/predicates already established by
-- PRD-116 K4 (source_kind='m2m' exclusion) and the vox_at_venue source_origin tag.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='approve_refill_plan' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '969118b6cc8206b9f9a499cab684bb97' THEN
    RAISE EXCEPTION 'approve_refill_plan drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
    'v_slot_guard     jsonb := NULL;',
    'v_slot_guard     jsonb := NULL;
  v_unbound_n      int := 0;
  v_unbound_summary text;');
  IF v_new = v_def THEN RAISE EXCEPTION 'declare not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
$patch$  SELECT count(*) INTO v_dispatch_rows
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date = p_plan_date
    AND m.official_name = ANY(p_machine_names)
    AND rd.include = true
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.skipped, false) = false;

  RETURN jsonb_build_object($patch$,
$patch$  SELECT count(*) INTO v_dispatch_rows
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date = p_plan_date
    AND m.official_name = ANY(p_machine_names)
    AND rd.include = true
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.skipped, false) = false;

  -- PRD-118 item C, Gate-2: refuse to complete the approval while any non-M2M,
  -- non-venue fill row for this date/machine set reached dispatch unbound
  -- (from_wh_inventory_id NULL, quantity>0). Raising here rolls back this whole
  -- function's subtransaction — including the UPDATE above and whatever
  -- push_plan_to_dispatch's trigger cascade just wrote — so a failed gate means
  -- NOTHING was approved, not a partial/silent approval. The existing
  -- EXCEPTION WHEN OTHERS handler below returns it as a clean structured error.
  SELECT count(*),
         string_agg(format('%s/%s %s x%s (dispatch %s)',
           m2.official_name, COALESCE(sc.shelf_code,'?'), COALESCE(bp.boonz_product_name,'?'),
           rd2.quantity, rd2.dispatch_id), '; ')
    INTO v_unbound_n, v_unbound_summary
  FROM refill_dispatching rd2
  JOIN machines m2 ON m2.machine_id = rd2.machine_id
  LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd2.shelf_id
  LEFT JOIN boonz_products bp ON bp.product_id = rd2.boonz_product_id
  WHERE rd2.dispatch_date = p_plan_date
    AND m2.official_name = ANY(p_machine_names)
    AND rd2.action IN ('Refill','Add New')
    AND rd2.from_wh_inventory_id IS NULL
    AND rd2.quantity > 0
    AND COALESCE(rd2.source_kind,'') <> 'm2m'
    AND COALESCE(rd2.source_origin::text,'') <> 'vox_at_venue'
    AND COALESCE(rd2.cancelled,false) = false
    AND COALESCE(rd2.skipped,false) = false;

  IF v_unbound_n > 0 THEN
    RAISE EXCEPTION 'Gate-2: % fill row(s) reached dispatch unbound (from_wh_inventory_id NULL, qty>0) — %', v_unbound_n, v_unbound_summary;
  END IF;

  RETURN jsonb_build_object($patch$);
  IF v_new = v_def THEN RAISE EXCEPTION 'insertion point not found'; END IF;
  EXECUTE v_new;
END $mig$;
