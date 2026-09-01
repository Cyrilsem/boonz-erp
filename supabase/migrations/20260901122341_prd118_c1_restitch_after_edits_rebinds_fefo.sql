-- PRD-118 item C: restitch_after_edits calls stitch_pod_to_boonz but never
-- bind_dispatch_fefo — the exact incident CS hit (MC-2004 A06 Pepsi Black x2: cut then
-- restored via edit_pod_refill_row after stitch had already allocated a different
-- batch; no re-bind ran; the row reached refill_dispatching with
-- from_wh_inventory_id NULL, unpackable, a manufactured stockout for stock that was
-- physically on the rack).
--
-- Fix: after the stitch commits, compute the set of machines whose pod_refill_plan
-- rows were actually edited this pass (same predicate already used for
-- v_edited_count/v_will_change) and call bind_dispatch_fefo scoped to exactly those
-- machines. bind_dispatch_fefo is the PRD-118 item H rebuild (quantity-aware, running
-- tally, split-into-breakdown) applied earlier this session — this composition
-- inherits that correctness directly.
--
-- Verified against md5 26e56639ba2cbaf5e820ff6341109811. Dry-run path (default,
-- p_dry_run=true) is unaffected — it returns before either the stitch or the new bind
-- call, fully read-only. Cody: approve, Articles 1/4/12 — no new write path, wires an
-- existing canonical RPC (bind_dispatch_fefo) into an existing canonical RPC
-- (restitch_after_edits) exactly as the PRD specifies.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='restitch_after_edits' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '26e56639ba2cbaf5e820ff6341109811' THEN
    RAISE EXCEPTION 'restitch_after_edits drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
    'v_stitch_result  jsonb;',
    'v_stitch_result  jsonb;
  v_bind_result    jsonb;
  v_affected_machines text[];');
  IF v_new = v_def THEN RAISE EXCEPTION 'declare not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
$patch$  SELECT public.stitch_pod_to_boonz(p_plan_date, false) INTO v_stitch_result;

  RETURN jsonb_build_object(
    'status',                    'committed',
    'edited_pod_rows',           v_edited_count,
    'locked_boonz_rows_skipped', v_locked_count,
    'stitch_result',             v_stitch_result
  );
END $function$$patch$,
$patch$  SELECT public.stitch_pod_to_boonz(p_plan_date, false) INTO v_stitch_result;

  -- PRD-118 item C: the stitch alone can raise a quantity or add a row without
  -- re-binding FEFO — the row then reaches refill_dispatching with
  -- from_wh_inventory_id NULL and the packer sees "no stock" for stock on the rack.
  -- bind_dispatch_fefo exists and does exactly the right thing; it was simply never
  -- invoked here. Scope to the machines whose pod rows actually changed this pass.
  SELECT ARRAY_AGG(DISTINCT m.official_name) INTO v_affected_machines
  FROM public.pod_refill_plan prp
  JOIN public.machines m ON m.machine_id = prp.machine_id
  WHERE prp.plan_date = p_plan_date
    AND prp.status = 'approved'
    AND prp.edited_at IS NOT NULL
    AND prp.edited_at > COALESCE(v_last_stitch, '1970-01-01'::timestamptz);

  IF v_affected_machines IS NOT NULL THEN
    SELECT public.bind_dispatch_fefo(p_plan_date, v_affected_machines, auth.uid()) INTO v_bind_result;
  END IF;

  RETURN jsonb_build_object(
    'status',                    'committed',
    'edited_pod_rows',           v_edited_count,
    'locked_boonz_rows_skipped', v_locked_count,
    'stitch_result',             v_stitch_result,
    'bind_result',                v_bind_result,
    'rebind_machines',            v_affected_machines
  );
END $function$$patch$);
  IF v_new = v_def THEN RAISE EXCEPTION 'return block not found'; END IF;
  EXECUTE v_new;
END $mig$;
