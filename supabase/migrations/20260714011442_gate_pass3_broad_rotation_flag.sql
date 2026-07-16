-- STEP 1: idempotent OFF-by-default flag (setting_value is jsonb; boolean false to match swaps_enabled/sweep_enabled)
INSERT INTO public.refill_settings(setting_key, setting_value)
SELECT 'broad_rotation_enabled','false'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM public.refill_settings WHERE setting_key='broad_rotation_enabled');

-- STEP 3-4: gate Pass 3 (value-model broad rotation) behind v_broad_enabled.
-- Transform is anchored to the LIVE source so everything else stays byte-identical.
DO $mig$
DECLARE
  v_src text := pg_get_functiondef('public.engine_swap_pod(date,integer,numeric,integer)'::regprocedure);
  v_new text;
  a1o text := $a1o$BEGIN
  PERFORM set_config('app.via_rpc','true',true);$a1o$;
  a1n text := $a1n$  v_broad_enabled      boolean;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);$a1n$;
  a2o text := $a2o$= 'false'::jsonb;
  CREATE TEMP TABLE _committed_machines ON COMMIT DROP AS$a2o$;
  a2n text := $a2n$= 'false'::jsonb;
  v_broad_enabled := COALESCE((SELECT (setting_value)::text::boolean FROM public.refill_settings WHERE setting_key='broad_rotation_enabled'), false);
  CREATE TEMP TABLE _committed_machines ON COMMIT DROP AS$a2n$;
  a3o text := $a3o$  SELECT COUNT(*) INTO v_fleet_swaps FROM public.pod_swaps$a3o$;
  a3n text := $a3n$  IF v_broad_enabled THEN
  SELECT COUNT(*) INTO v_fleet_swaps FROM public.pod_swaps$a3n$;
  a4o text := $a4o$  END LOOP;

  RETURN jsonb_build_object($a4o$;
  a4n text := $a4n$  END LOOP;
  END IF;

  RETURN jsonb_build_object($a4n$;
BEGIN
  IF (length(v_src)-length(replace(v_src,a1o,'')))/length(a1o) <> 1 THEN RAISE EXCEPTION 'anchor a1 not exactly-once'; END IF;
  IF (length(v_src)-length(replace(v_src,a2o,'')))/length(a2o) <> 1 THEN RAISE EXCEPTION 'anchor a2 not exactly-once'; END IF;
  IF (length(v_src)-length(replace(v_src,a3o,'')))/length(a3o) <> 1 THEN RAISE EXCEPTION 'anchor a3 not exactly-once'; END IF;
  IF (length(v_src)-length(replace(v_src,a4o,'')))/length(a4o) <> 1 THEN RAISE EXCEPTION 'anchor a4 not exactly-once'; END IF;
  v_new := replace(replace(replace(replace(v_src,a1o,a1n),a2o,a2n),a3o,a3n),a4o,a4n);
  IF v_new NOT LIKE '%rank_slot_suitability%' THEN RAISE EXCEPTION 'Pass 2a rank_slot_suitability lost'; END IF;
  IF v_new NOT LIKE '%value_model_swap_broad%' THEN RAISE EXCEPTION 'Pass 3 value_model_swap_broad lost'; END IF;
  -- force full plpgsql body validation (IF/END IF balance) at CREATE time
  PERFORM set_config('check_function_bodies','on',true);
  EXECUTE v_new;
END $mig$;
