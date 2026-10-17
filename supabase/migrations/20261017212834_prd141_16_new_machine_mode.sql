-- PRD-141 item 16: new-machine mode (D5).
-- A machine is "new" while GREATEST(created_at, relaunched_at) is under
-- refill_policy_params.new_machine_days (default 21). For new machines:
--   * lane velocity in compute_refill_decision and engine_add_pod uses the same pod product's
--     fleet median (slot_lifecycle, established machines) via new_machine_velocity();
--     new_machine_velocity_mode 'floor' (default) = GREATEST(own, category),
--     'replace' = category instead of own (the spec's literal wording), 'off' = disabled.
--     Default is 'floor' because 'replace' would cut ACTIVATEMOE (relaunched 30 Sep, 105 sales/48 h)
--     from own v30 190.5 / v7 732.1 to category 87.0 / 89.0; see docs/prds/PRD-141-log.md.
--   * engine_swap_pod proposes no swaps (no Remove suggested), CS rule "no swaps on SAP".
--   * assert_weimi_slot_match runs in warn instead of block (a manual per-machine override wins).
-- Night window only. Fleet diff in docs/prds/PRD-141-log.md.
-- Rollback: UPDATE refill_policy_params SET new_machine_velocity_mode = 'off', new_machine_days = 0;
--           (no DDL; machine_is_new() then returns false everywhere) or supabase/rollbacks/prd141_16_rollback.sql.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS new_machine_days integer NOT NULL DEFAULT 21,
  ADD COLUMN IF NOT EXISTS new_machine_velocity_mode text NOT NULL DEFAULT 'floor'
    CHECK (new_machine_velocity_mode IN ('floor', 'replace', 'off'));

CREATE OR REPLACE FUNCTION public.machine_is_new(p_machine_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(GREATEST(m.created_at, m.relaunched_at)
                  > now() - make_interval(days => COALESCE(rpp.new_machine_days, 21)), false)
    FROM public.machines m
    CROSS JOIN (SELECT new_machine_days FROM public.refill_policy_params ORDER BY id LIMIT 1) rpp
   WHERE m.machine_id = p_machine_id;
$function$;
REVOKE EXECUTE ON FUNCTION public.machine_is_new(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.machine_is_new(uuid) TO authenticated, service_role;

CREATE OR REPLACE VIEW public.v_pod_category_velocity AS
SELECT sl.pod_product_id,
  percentile_cont(0.5) WITHIN GROUP (ORDER BY sl.velocity_7d)::numeric  AS median_v7,
  percentile_cont(0.5) WITHIN GROUP (ORDER BY sl.velocity_30d)::numeric AS median_v30,
  count(*) AS lanes
FROM public.slot_lifecycle sl
WHERE sl.is_current AND NOT COALESCE(sl.archived, false)
  AND COALESCE(sl.velocity_30d, 0) > 0
  AND NOT public.machine_is_new(sl.machine_id)
GROUP BY sl.pod_product_id;
REVOKE ALL ON public.v_pod_category_velocity FROM anon, public;
GRANT SELECT ON public.v_pod_category_velocity TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.new_machine_velocity(p_machine_id uuid, p_pod_product_id uuid, p_own numeric, p_window text)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN mode = 'off' OR NOT public.machine_is_new(p_machine_id) THEN p_own
    WHEN mode = 'replace' THEN COALESCE(cat, p_own)
    ELSE GREATEST(COALESCE(p_own, 0), COALESCE(cat, 0))
  END
  FROM (SELECT COALESCE((SELECT new_machine_velocity_mode FROM public.refill_policy_params ORDER BY id LIMIT 1), 'floor') AS mode,
               (SELECT CASE WHEN p_window = '7d' THEN cv.median_v7 ELSE cv.median_v30 END
                  FROM public.v_pod_category_velocity cv WHERE cv.pod_product_id = p_pod_product_id) AS cat) x;
$function$;
REVOKE EXECUTE ON FUNCTION public.new_machine_velocity(uuid, uuid, numeric, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.new_machine_velocity(uuid, uuid, numeric, text) TO authenticated, service_role;

DO $patch$
DECLARE
  v_def text; v_new text;
BEGIN
  -- compute_refill_decision (invoker): adjust v7 / v30 after the local/global fallback.
  v_def := pg_get_functiondef('public.compute_refill_decision(uuid,uuid,uuid,integer)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, '  v_stance := COALESCE(v_signal_local, v_signal_glob, ''KEEP'');', ''))) / length('  v_stance := COALESCE(v_signal_local, v_signal_glob, ''KEEP'');') <> 1 THEN
    RAISE EXCEPTION 'prd141_16: compute_refill_decision anchor';
  END IF;
  v_new := replace(v_def, '  v_stance := COALESCE(v_signal_local, v_signal_glob, ''KEEP'');',
    '  v7  := public.new_machine_velocity(p_machine_id, v_pod_id, v7, ''7d'');' || chr(10) ||
    '  v30 := public.new_machine_velocity(p_machine_id, v_pod_id, v30, ''30d'');' || chr(10) ||
    '  v_stance := COALESCE(v_signal_local, v_signal_glob, ''KEEP'');');
  EXECUTE v_new;

  -- engine_add_pod: lane v7 / v30.
  v_def := pg_get_functiondef('public.engine_add_pod(date,integer)'::regprocedure);
  IF strpos(v_def, 'ELSE COALESCE(sl.velocity_7d, 0) END::numeric      AS v7,') = 0
     OR strpos(v_def, 'ELSE COALESCE(sl.velocity_30d, 0) END::numeric     AS v30,') = 0 THEN
    RAISE EXCEPTION 'prd141_16: engine_add_pod anchor';
  END IF;
  IF (length(v_def) - length(replace(v_def, 'ELSE COALESCE(sl.velocity_7d, 0) END::numeric      AS v7,', ''))) / length('ELSE COALESCE(sl.velocity_7d, 0) END::numeric      AS v7,') <> 1 THEN
    RAISE EXCEPTION 'prd141_16: engine_add_pod anchor not unique';
  END IF;
  v_new := replace(v_def, 'ELSE COALESCE(sl.velocity_7d, 0) END::numeric      AS v7,',
    'ELSE public.new_machine_velocity(p.machine_id, wid.identity_pod, COALESCE(sl.velocity_7d, 0), ''7d'') END::numeric      AS v7,');
  v_new := replace(v_new, 'ELSE COALESCE(sl.velocity_30d, 0) END::numeric     AS v30,',
    'ELSE public.new_machine_velocity(p.machine_id, wid.identity_pod, COALESCE(sl.velocity_30d, 0), ''30d'') END::numeric     AS v30,');
  EXECUTE v_new;

  -- engine_swap_pod: new machines get no swaps.
  v_def := pg_get_functiondef('public.engine_swap_pod(date,integer,numeric,integer)'::regprocedure);
  IF strpos(v_def, '         ) = ''false''::jsonb;' || chr(10) || '  v_broad_enabled') = 0 THEN
    RAISE EXCEPTION 'prd141_16: engine_swap_pod anchor';
  END IF;
  v_new := replace(v_def, '         ) = ''false''::jsonb;' || chr(10) || '  v_broad_enabled',
    '         ) = ''false''::jsonb' || chr(10) || '      OR public.machine_is_new(m.machine_id);' || chr(10) || '  v_broad_enabled');
  EXECUTE v_new;

  -- assert_weimi_slot_match: block becomes warn for new machines unless a manual override is set.
  v_def := pg_get_functiondef('public.assert_weimi_slot_match(date,text,text)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, 'v_row_mode := COALESCE(p_mode, r.machine_override, v_global_mode, ''warn'');', ''))) / length('v_row_mode := COALESCE(p_mode, r.machine_override, v_global_mode, ''warn'');') <> 1 THEN
    RAISE EXCEPTION 'prd141_16: assert_weimi_slot_match anchor';
  END IF;
  v_new := replace(v_def, 'v_row_mode := COALESCE(p_mode, r.machine_override, v_global_mode, ''warn'');',
    'v_row_mode := COALESCE(p_mode, r.machine_override, v_global_mode, ''warn'');' || chr(10) ||
    '    IF v_row_mode = ''block'' AND p_mode IS NULL AND r.machine_override IS NULL' || chr(10) ||
    '       AND (SELECT public.machine_is_new(mm.machine_id) FROM public.machines mm WHERE mm.official_name = r.machine_name) THEN' || chr(10) ||
    '      v_row_mode := ''warn'';  -- PRD-141 item 16: new-machine mode' || chr(10) ||
    '    END IF;');
  EXECUTE v_new;
END
$patch$;

REVOKE EXECUTE ON FUNCTION public.engine_add_pod(date, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_add_pod(date, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.engine_swap_pod(date, integer, numeric, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_swap_pod(date, integer, numeric, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.assert_weimi_slot_match(date, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_weimi_slot_match(date, text, text) TO authenticated, service_role;
