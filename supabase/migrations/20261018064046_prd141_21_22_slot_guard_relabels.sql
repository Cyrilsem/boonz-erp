-- PRD-141 items 21 (F1) and 22 (F2): the slot guard stops blocking aliased names and pending relabels,
-- and relabels live in the system instead of WhatsApp.
-- 22. weimi_relabel_requests(machine_id, shelf_code, from_pod, to_pod, requested_by, done_at, ...).
--     ensure_swap_remove_leg (PRD-141 item 1) opens one per swap it detects (deduplicated per open lane);
--     open_relabel_request / mark_relabel_done are operator_admin RPCs; Config > Machines shows the
--     open list (FE). Apply AFTER prd141_01.
-- 21. assert_weimi_slot_match resolves the planned pod name the same way v_live_shelf_stock resolves
--     WEIMI names (exact, product_name_conventions, weimi_product_alias, then the plan row's own
--     pod_product_id). All four named pairs (Hunter Cans / Hunter Canister 40G, Nutella T3 / Nutella
--     Biscuits T3, Freakin Healthy Balls 3P / Freakin Protein Balls 3P, Chewing Gum / Extra Gum) already
--     exist in product_name_conventions, so the spec's pod_product_aliases table would duplicate them and
--     is not created. Exemptions (logged as info, never blocked): an open relabel request on the lane,
--     and an Add New on a lane WEIMI shows empty when the plan line carries a comment.
-- Rollback: supabase/rollbacks/prd141_21_22_rollback.sql.

CREATE TABLE IF NOT EXISTS public.weimi_relabel_requests (
  request_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id   uuid NOT NULL REFERENCES public.machines(machine_id),
  shelf_code   text NOT NULL,
  from_pod     uuid REFERENCES public.pod_products(pod_product_id),
  to_pod       uuid NOT NULL REFERENCES public.pod_products(pod_product_id),
  dispatch_date date,
  source       text NOT NULL DEFAULT 'swap',
  requested_by uuid,
  requested_at timestamptz NOT NULL DEFAULT now(),
  done_at      timestamptz,
  done_by      uuid,
  note         text
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_weimi_relabel_open
  ON public.weimi_relabel_requests (machine_id, shelf_code, to_pod) WHERE done_at IS NULL;
ALTER TABLE public.weimi_relabel_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY weimi_relabel_requests_read ON public.weimi_relabel_requests
  FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.weimi_relabel_requests FROM anon, public;
GRANT SELECT ON public.weimi_relabel_requests TO authenticated;
GRANT ALL ON public.weimi_relabel_requests TO service_role;

CREATE OR REPLACE FUNCTION public.open_relabel_request(p_machine_id uuid, p_shelf_code text, p_to_pod uuid, p_from_pod uuid DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_id   uuid;
  v_code text := upper(regexp_replace(trim(p_shelf_code), '^([A-Za-z])([0-9])$', '\1' || '0' || '\2'));
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND (v_role IS NULL OR v_role NOT IN ('operator_admin', 'superadmin')) THEN
    RAISE EXCEPTION 'open_relabel_request: forbidden for role %', COALESCE(v_role, 'unknown');
  END IF;
  INSERT INTO public.weimi_relabel_requests (machine_id, shelf_code, from_pod, to_pod, source, requested_by, note)
  VALUES (p_machine_id, v_code, p_from_pod, p_to_pod, 'manual', auth.uid(), p_note)
  ON CONFLICT (machine_id, shelf_code, to_pod) WHERE done_at IS NULL DO NOTHING
  RETURNING request_id INTO v_id;
  RETURN jsonb_build_object('status', CASE WHEN v_id IS NULL THEN 'already_open' ELSE 'opened' END, 'request_id', v_id);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.open_relabel_request(uuid, text, uuid, uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.open_relabel_request(uuid, text, uuid, uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.mark_relabel_done(p_request_id uuid, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_n    int;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND (v_role IS NULL OR v_role NOT IN ('operator_admin', 'superadmin')) THEN
    RAISE EXCEPTION 'mark_relabel_done: forbidden for role %', COALESCE(v_role, 'unknown');
  END IF;
  UPDATE public.weimi_relabel_requests
     SET done_at = now(), done_by = auth.uid(), note = COALESCE(p_note, note)
   WHERE request_id = p_request_id AND done_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status', CASE WHEN v_n = 1 THEN 'done' ELSE 'not_open' END, 'request_id', p_request_id);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.mark_relabel_done(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.mark_relabel_done(uuid, text) TO authenticated, service_role;

DO $patch$
DECLARE
  v_def text; n int; i int;
  pairs text[][];
BEGIN
  -- ensure_swap_remove_leg (item 1) opens the relabel request for the swap it detected.
  v_def := pg_get_functiondef('public.ensure_swap_remove_leg(uuid,text,uuid,date)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  RETURN jsonb_build_object(''status'', ''created'', ''shelf_code'', v_code, ''lane_pod'', v_old_pod,',
          '  -- PRD-141 item 22: a swap is also a WEIMI relabel to do.' || chr(10)
          || '  INSERT INTO public.weimi_relabel_requests (machine_id, shelf_code, from_pod, to_pod, dispatch_date, source, requested_by)' || chr(10)
          || '  VALUES (p_machine_id, v_code, v_old_pod, p_new_pod_product_id, p_dispatch_date, ''swap'', auth.uid())' || chr(10)
          || '  ON CONFLICT (machine_id, shelf_code, to_pod) WHERE done_at IS NULL DO NOTHING;' || chr(10) || chr(10)
          || '  RETURN jsonb_build_object(''status'', ''created'', ''shelf_code'', v_code, ''lane_pod'', v_old_pod,']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_22: ensure_swap_remove_leg anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  -- assert_weimi_slot_match (item 21).
  v_def := pg_get_functiondef('public.assert_weimi_slot_match(date,text,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['           ssi.goods_name_raw, ssi.match_method,',
          '           ssi.goods_name_raw, ssi.match_method, ssi.current_stock AS weimi_stock, rpo.comment AS plan_comment,' || chr(10)
          || '           EXISTS (SELECT 1 FROM public.weimi_relabel_requests wr' || chr(10)
          || '                    WHERE wr.machine_id = m.machine_id AND wr.done_at IS NULL' || chr(10)
          || '                      AND wr.shelf_code = COALESCE(sc.shelf_code, regexp_replace(rpo.shelf_code, ''^([A-Z])([0-9])$'', ''\1'' || ''0'' || ''\2''))) AS relabel_pending,'],
    ARRAY['    LEFT JOIN pod_products plan_pp ON lower(trim(plan_pp.pod_product_name)) = lower(trim(rpo.pod_product_name))',
          '    LEFT JOIN LATERAL (SELECT COALESCE(' || chr(10)
          || '        (SELECT pp1.pod_product_id FROM pod_products pp1 WHERE lower(trim(pp1.pod_product_name)) = lower(trim(rpo.pod_product_name)) LIMIT 1),' || chr(10)
          || '        (SELECT pp2.pod_product_id FROM product_name_conventions pnc JOIN pod_products pp2 ON pp2.pod_product_name = pnc.official_name' || chr(10)
          || '          WHERE lower(trim(pnc.original_name)) = lower(trim(rpo.pod_product_name)) LIMIT 1),' || chr(10)
          || '        (SELECT a.pod_product_id FROM weimi_product_alias a WHERE lower(trim(a.weimi_name)) = lower(trim(rpo.pod_product_name)) LIMIT 1),' || chr(10)
          || '        rpo.pod_product_id) AS pod_product_id) plan_pp ON true  -- PRD-141 item 21'],
    ARRAY['    IF r.same_shelf_swap THEN' || chr(10) || '      v_info := v_info || (v_diag || jsonb_build_object(''reason'',''same_shelf_swap_exempt''));' || chr(10) || '      CONTINUE;' || chr(10) || '    END IF;',
          '    IF r.same_shelf_swap THEN' || chr(10) || '      v_info := v_info || (v_diag || jsonb_build_object(''reason'',''same_shelf_swap_exempt''));' || chr(10) || '      CONTINUE;' || chr(10) || '    END IF;' || chr(10)
          || '    -- PRD-141 item 21: a relabel is already queued for this lane, or an Add New lands on an empty lane with a note.' || chr(10)
          || '    IF r.relabel_pending THEN' || chr(10)
          || '      v_info := v_info || (v_diag || jsonb_build_object(''reason'',''relabel_pending_exempt''));' || chr(10)
          || '      CONTINUE;' || chr(10)
          || '    END IF;' || chr(10)
          || '    IF r.act = ''ADD NEW'' AND COALESCE(r.weimi_stock, 0) = 0 AND NULLIF(trim(COALESCE(r.plan_comment, '''')), '''') IS NOT NULL THEN' || chr(10)
          || '      v_info := v_info || (v_diag || jsonb_build_object(''reason'',''empty_lane_add_new_exempt''));' || chr(10)
          || '      CONTINUE;' || chr(10)
          || '    END IF;']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_21: assert_weimi_slot_match anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

REVOKE EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.ensure_swap_remove_leg(uuid, text, uuid, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assert_weimi_slot_match(date, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_weimi_slot_match(date, text, text) TO authenticated, service_role;
