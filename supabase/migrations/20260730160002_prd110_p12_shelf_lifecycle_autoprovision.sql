-- PRD-110 P1.2 (second half) - the coverage GUARANTEE.
-- BUILD SPEC: "shelf_configurations INSERT (non-phantom) => lifecycle row + shelf_state coverage
-- same transaction". v_shelf_state coverage is structural (it reads shelf_configurations directly),
-- so the only thing needing a guarantee is the slot_lifecycle row.
-- Article 1: this is the canonical SINGLE-SHELF lifecycle provisioner. The fleet-wide sweeper
-- (seed_missing_slot_lifecycle) stays the canonical BATCH writer; both use identical scope rules.

CREATE OR REPLACE FUNCTION public.provision_shelf_lifecycle_v3(p_shelf_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid      uuid;
  v_shelf    record;
  v_pod      uuid;
  v_slot     text;
  v_action   text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','provision_shelf_lifecycle_v3',true);

  -- Article 4: role validation. Skipped when invoked BY the shelf-insert trigger, because the
  -- parent INSERT on shelf_configurations already carried its own authorization.
  v_uid := auth.uid();
  IF v_uid IS NOT NULL
     AND COALESCE(current_setting('app.via_trigger', true), '') <> 'true'
     AND NOT EXISTS (SELECT 1 FROM public.user_profiles up
                      WHERE up.id = v_uid
                        AND up.role = ANY (ARRAY['operator_admin','superadmin','manager','warehouse']))
  THEN
    RAISE EXCEPTION 'provision_shelf_lifecycle_v3: caller % lacks a provisioning role', v_uid;
  END IF;

  IF p_shelf_id IS NULL THEN
    RETURN jsonb_build_object('action','skipped','reason','null_shelf_id');
  END IF;

  SELECT sc.shelf_id, sc.machine_id, sc.shelf_code, sc.is_phantom,
         m.status AS machine_status, m.include_in_refill
    INTO v_shelf
  FROM public.shelf_configurations sc
  JOIN public.machines m ON m.machine_id = sc.machine_id
  WHERE sc.shelf_id = p_shelf_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('action','skipped','reason','shelf_not_found','shelf_id',p_shelf_id);
  END IF;
  IF v_shelf.is_phantom THEN
    RETURN jsonb_build_object('action','skipped','reason','phantom_shelf','shelf_id',p_shelf_id);
  END IF;
  IF NOT (v_shelf.machine_status = 'Active' AND v_shelf.include_in_refill = true) THEN
    -- identical scope guard to seed_missing_slot_lifecycle (P0.2); D-02 owns the wider cohort
    RETURN jsonb_build_object('action','skipped','reason','machine_out_of_scope','shelf_id',p_shelf_id);
  END IF;
  IF EXISTS (SELECT 1 FROM public.slot_lifecycle sl
              WHERE sl.shelf_id = p_shelf_id AND sl.archived = false AND sl.is_current = true) THEN
    RETURN jsonb_build_object('action','skipped','reason','already_covered','shelf_id',p_shelf_id);
  END IF;
  IF v_shelf.shelf_code !~ '^[A-Za-z][0-9]+$' THEN
    RETURN jsonb_build_object('action','skipped','reason','unparseable_shelf_code',
                              'shelf_code', v_shelf.shelf_code);
  END IF;

  -- DATA-SOURCE LAW: WEIMI is the ONLY slot-product identity source. A01 -> A1 for the slot join.
  v_slot := LEFT(v_shelf.shelf_code,1) || (SUBSTR(v_shelf.shelf_code,2)::int)::text;

  SELECT vls.pod_product_id INTO v_pod
  FROM public.v_live_shelf_stock vls
  WHERE vls.machine_id = v_shelf.machine_id
    AND vls.slot_name = v_slot
    AND vls.pod_product_id IS NOT NULL
    AND vls.is_enabled = true AND vls.is_broken = false
  ORDER BY vls.current_stock DESC NULLS LAST, vls.snapshot_at DESC NULLS LAST
  LIMIT 1;

  IF v_pod IS NULL THEN
    -- brand-new hardware: WEIMI has not reported this slot yet. Honest no-op; the nightly
    -- coverage cron (P0.2) provisions it on the first snapshot that carries it.
    RETURN jsonb_build_object('action','deferred','reason','no_live_weimi_slot',
                              'shelf_id',p_shelf_id,'slot_name',v_slot);
  END IF;

  UPDATE public.slot_lifecycle
     SET archived = false, is_current = true, rotated_in_at = now(),
         rotated_out_at = NULL, last_evaluated_at = now()
   WHERE shelf_id = p_shelf_id
     AND machine_id = v_shelf.machine_id
     AND pod_product_id = v_pod;

  IF FOUND THEN
    v_action := 'revived';
  ELSE
    INSERT INTO public.slot_lifecycle
      (machine_id, shelf_id, shelf_code, pod_product_id, signal, recommendation_reason)
    VALUES (v_shelf.machine_id, p_shelf_id, v_shelf.shelf_code, v_pod, 'KEEP',
            'prd110_p12_autoprovision');
    v_action := 'inserted';
  END IF;

  RETURN jsonb_build_object('action', v_action, 'shelf_id', p_shelf_id,
                            'machine_id', v_shelf.machine_id, 'shelf_code', v_shelf.shelf_code,
                            'pod_product_id', v_pod);
END;
$fn$;

COMMENT ON FUNCTION public.provision_shelf_lifecycle_v3(uuid) IS
'PRD-110 P1.2: canonical single-shelf slot_lifecycle provisioner. Idempotent; scope-guarded to Active+include_in_refill machines and non-phantom shelves; identity from WEIMI only; revives an archived (shelf,pod) row instead of duplicating. Returns {action: inserted|revived|deferred|skipped, reason}.';

REVOKE ALL ON FUNCTION public.provision_shelf_lifecycle_v3(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provision_shelf_lifecycle_v3(uuid) TO authenticated, service_role;

-- Thin trigger wrapper. Sets app.via_trigger for the duration of the call ONLY, then clears it,
-- so the provenance GUC cannot leak to later statements in the same transaction (PRD-016B lesson).
CREATE OR REPLACE FUNCTION public.tg_provision_shelf_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $tg$
BEGIN
  PERFORM set_config('app.via_trigger','true',true);
  PERFORM public.provision_shelf_lifecycle_v3(NEW.shelf_id);
  PERFORM set_config('app.via_trigger','',true);
  RETURN NULL;
END;
$tg$;

DROP TRIGGER IF EXISTS tg_provision_shelf_lifecycle_ins ON public.shelf_configurations;
CREATE TRIGGER tg_provision_shelf_lifecycle_ins
AFTER INSERT ON public.shelf_configurations
FOR EACH ROW
WHEN (NEW.is_phantom = false)
EXECUTE FUNCTION public.tg_provision_shelf_lifecycle();
