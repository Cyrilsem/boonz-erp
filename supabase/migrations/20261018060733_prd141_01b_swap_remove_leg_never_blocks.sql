-- PRD-141 item 1 hotfix: ensure_swap_remove_leg must never block the Add New it was called for.
-- Found in the FE reproduction (2026-10-18 10:10): an Add New on WH2-2001 A09 failed with
-- "no Active product_mapping for boonz_product <M&M Bag - Brown Bag> on machine ...": the lane's current
-- product has no Active mapping on that machine, add_dispatch_row refused its Remove leg, and the
-- exception rolled back the Add New. Now each Remove leg is written in its own exception block; on
-- failure it retries with the lane pod's top mapped variant, and if that also fails it raises a
-- monitoring alert and returns status remove_failed. The Add New always goes through.
DO $patch$
DECLARE
  v_def text; n int;
  a_old text := '    v_res := public.add_dispatch_row(' || chr(10)
             || '      p_machine_id, v_code, r.bpid, r.qty, ''Remove'', p_dispatch_date, ''unknown'', NULL, NULL,' || chr(10)
             || '      COALESCE(v_role, ''system''),' || chr(10)
             || '      format(''PRD-141 item 1: auto Remove of %s on %s, lane swapped to %s'', v_pod_name, v_code, v_new_name), NULL);';
  a_new text := '    BEGIN' || chr(10)
             || '      v_res := public.add_dispatch_row(' || chr(10)
             || '        p_machine_id, v_code, r.bpid, r.qty, ''Remove'', p_dispatch_date, ''unknown'', NULL, NULL,' || chr(10)
             || '        COALESCE(v_role, ''system''),' || chr(10)
             || '        format(''PRD-141 item 1: auto Remove of %s on %s, lane swapped to %s'', v_pod_name, v_code, v_new_name), NULL);' || chr(10)
             || '    EXCEPTION WHEN OTHERS THEN' || chr(10)
             || '      v_res := NULL;' || chr(10)
             || '      SELECT pm.boonz_product_id INTO v_fallback FROM public.product_mapping pm' || chr(10)
             || '       WHERE pm.pod_product_id = v_old_pod AND pm.status = ''Active'' AND pm.boonz_product_id <> r.bpid' || chr(10)
             || '         AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)' || chr(10)
             || '       ORDER BY (pm.machine_id = p_machine_id) DESC NULLS LAST, COALESCE(pm.split_pct, 0) DESC, pm.boonz_product_id LIMIT 1;' || chr(10)
             || '      IF v_fallback IS NOT NULL THEN' || chr(10)
             || '        BEGIN' || chr(10)
             || '          v_res := public.add_dispatch_row(' || chr(10)
             || '            p_machine_id, v_code, v_fallback, r.qty, ''Remove'', p_dispatch_date, ''unknown'', NULL, NULL,' || chr(10)
             || '            COALESCE(v_role, ''system''),' || chr(10)
             || '            format(''PRD-141 item 1: auto Remove of %s on %s (variant to confirm at warehouse), lane swapped to %s'', v_pod_name, v_code, v_new_name), NULL);' || chr(10)
             || '        EXCEPTION WHEN OTHERS THEN v_res := NULL;' || chr(10)
             || '        END;' || chr(10)
             || '      END IF;' || chr(10)
             || '      IF v_res IS NULL THEN' || chr(10)
             || '        INSERT INTO public.monitoring_alerts (source, severity, payload)' || chr(10)
             || '        VALUES (''ensure_swap_remove_leg'', ''warning'', jsonb_build_object(' || chr(10)
             || '          ''title'', format(''Swap on %s: Remove leg for %s x%s could not be written (%s); add it by hand'', v_code, v_pod_name, r.qty, SQLERRM),' || chr(10)
             || '          ''machine_id'', p_machine_id, ''shelf_code'', v_code, ''dispatch_date'', p_dispatch_date, ''boonz_product_id'', r.bpid, ''detected_at'', now()));' || chr(10)
             || '        v_legs := v_legs || jsonb_build_object(''status'', ''remove_failed'', ''boonz_product_id'', r.bpid, ''qty'', r.qty, ''error'', SQLERRM);' || chr(10)
             || '        CONTINUE;' || chr(10)
             || '      END IF;' || chr(10)
             || '    END;';
BEGIN
  v_def := pg_get_functiondef('public.ensure_swap_remove_leg(uuid,text,uuid,date)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_01b: anchor count %', n; END IF;
  EXECUTE replace(v_def, a_old, a_new);
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) TO authenticated, service_role;
