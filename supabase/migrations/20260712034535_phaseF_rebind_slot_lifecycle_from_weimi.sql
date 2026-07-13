
-- Canonical writer: rebind misbound slot_lifecycle rows to WEIMI physical truth.
-- Incident 2026-07-12: engine_add_pod takes pod_product_id from slot_lifecycle but
-- stock levels from v_live_shelf_stock (WEIMI), and never asserts they agree. Stale
-- slot_lifecycle => engine plans the OLD product at the NEW product's stock level.
-- Articles 1, 4, 5, 8, 12.
CREATE OR REPLACE FUNCTION public.rebind_slot_lifecycle_from_weimi(
  p_machine_ids uuid[] DEFAULT NULL,
  p_dry_run     boolean DEFAULT true,
  p_reason      text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid       uuid;
  v_rows      jsonb;
  v_locked    jsonb;
  v_n_out     integer := 0;
  v_n_revive  integer := 0;
  v_n_insert  integer := 0;
BEGIN
  -- Article 4: mark the write path
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','rebind_slot_lifecycle_from_weimi',true);

  -- Article 4: role gate
  v_uid := auth.uid();
  IF v_uid IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_uid AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'rebind_slot_lifecycle_from_weimi: caller % lacks operator_admin', v_uid;
  END IF;

  -- Article 4: input validation
  IF NOT p_dry_run AND (p_reason IS NULL OR length(trim(p_reason)) < 10) THEN
    RAISE EXCEPTION 'rebind_slot_lifecycle_from_weimi: p_reason required (>= 10 chars) for a live run';
  END IF;

  -- WEIMI physical truth, deduped (v_live_shelf_stock can fan out per shelf)
  CREATE TEMP TABLE _weimi ON COMMIT DROP AS
  SELECT DISTINCT ON (sc.machine_id, sc.shelf_id)
         sc.machine_id, sc.shelf_id, sc.shelf_code,
         vls.pod_product_id AS weimi_pod,
         MAX(vls.current_stock)::int AS current_stock
    FROM public.v_live_shelf_stock vls
    JOIN public.shelf_configurations sc
      ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
     AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
   WHERE vls.pod_product_id IS NOT NULL
     AND vls.is_enabled = true AND vls.is_broken = false
     AND (p_machine_ids IS NULL OR sc.machine_id = ANY(p_machine_ids))
   GROUP BY sc.machine_id, sc.shelf_id, sc.shelf_code, vls.pod_product_id
   ORDER BY sc.machine_id, sc.shelf_id, MAX(vls.current_stock) DESC, vls.pod_product_id;

  -- LIVE-PLAN GUARD (Cody, required): refuse machines with an open unpacked dispatch.
  -- Rebinding a shelf under an in-flight plan would recreate the incident in reverse.
  CREATE TEMP TABLE _locked_machines ON COMMIT DROP AS
  SELECT DISTINCT rd.machine_id
    FROM public.refill_dispatching rd
   WHERE COALESCE(rd.cancelled,false) = false
     AND COALESCE(rd.include,true)    = true
     AND COALESCE(rd.picked_up,false) = false
     AND rd.dispatch_date >= CURRENT_DATE;

  -- The drift set: current lifecycle row disagrees with WEIMI
  CREATE TEMP TABLE _drift ON COMMIT DROP AS
  SELECT w.machine_id, m.official_name, w.shelf_id, w.shelf_code,
         sl.slot_lifecycle_id AS stale_id,
         sl.pod_product_id    AS stale_pod,
         w.weimi_pod,
         w.current_stock,
         EXISTS (SELECT 1 FROM public.slot_lifecycle old
                  WHERE old.machine_id = w.machine_id
                    AND old.shelf_id   = w.shelf_id
                    AND old.pod_product_id = w.weimi_pod) AS has_old_row
    FROM _weimi w
    JOIN public.machines m ON m.machine_id = w.machine_id
    JOIN public.slot_lifecycle sl
      ON sl.machine_id = w.machine_id AND sl.shelf_id = w.shelf_id
     AND sl.archived = false AND sl.is_current = true
   WHERE sl.pod_product_id IS DISTINCT FROM w.weimi_pod
     AND w.machine_id NOT IN (SELECT machine_id FROM _locked_machines);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'machine', official_name, 'shelf', shelf_code,
           'was',  (SELECT pod_product_name FROM public.pod_products WHERE pod_product_id = stale_pod),
           'now',  (SELECT pod_product_name FROM public.pod_products WHERE pod_product_id = weimi_pod),
           'on_shelf', current_stock,
           'mode', CASE WHEN has_old_row THEN 'revive' ELSE 'insert' END)
           ORDER BY official_name, shelf_code), '[]'::jsonb)
    INTO v_rows FROM _drift;

  SELECT COALESCE(jsonb_agg(DISTINCT m.official_name), '[]'::jsonb)
    INTO v_locked
    FROM _locked_machines lm
    JOIN public.machines m ON m.machine_id = lm.machine_id
   WHERE EXISTS (SELECT 1 FROM _weimi w
                  JOIN public.slot_lifecycle sl
                    ON sl.machine_id = w.machine_id AND sl.shelf_id = w.shelf_id
                   AND sl.archived = false AND sl.is_current = true
                 WHERE w.machine_id = lm.machine_id
                   AND sl.pod_product_id IS DISTINCT FROM w.weimi_pod);

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true,
      'would_rebind', (SELECT COUNT(*) FROM _drift),
      'rows', v_rows,
      'skipped_live_plan_machines', v_locked);
  END IF;

  -- Article 5: rotate the stale row OUT via the state machine
  UPDATE public.slot_lifecycle sl
     SET archived = true, is_current = false, rotated_out_at = now(),
         last_evaluated_at = now()
    FROM _drift d
   WHERE sl.slot_lifecycle_id = d.stale_id;
  GET DIAGNOSTICS v_n_out = ROW_COUNT;

  -- Revive a prior row for the correct product if one exists
  UPDATE public.slot_lifecycle sl
     SET archived = false, is_current = true, rotated_in_at = now(),
         rotated_out_at = NULL, last_evaluated_at = now(), signal = 'KEEP'
    FROM _drift d
   WHERE d.has_old_row
     AND sl.machine_id = d.machine_id AND sl.shelf_id = d.shelf_id
     AND sl.pod_product_id = d.weimi_pod;
  GET DIAGNOSTICS v_n_revive = ROW_COUNT;

  -- Otherwise insert the correct binding from WEIMI truth
  INSERT INTO public.slot_lifecycle(machine_id, shelf_id, shelf_code, pod_product_id, signal)
  SELECT d.machine_id, d.shelf_id, d.shelf_code, d.weimi_pod, 'KEEP'
    FROM _drift d WHERE NOT d.has_old_row;
  GET DIAGNOSTICS v_n_insert = ROW_COUNT;

  RETURN jsonb_build_object(
    'dry_run', false,
    'rotated_out', v_n_out,
    'revived', v_n_revive,
    'inserted', v_n_insert,
    'rows', v_rows,
    'skipped_live_plan_machines', v_locked,
    'reason', p_reason);
END;
$function$;

REVOKE ALL ON FUNCTION public.rebind_slot_lifecycle_from_weimi(uuid[], boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebind_slot_lifecycle_from_weimi(uuid[], boolean, text) TO authenticated, service_role;
