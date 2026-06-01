-- Refill System v2 / Phase 0 step 2 (B2) — shelf aisle-index regression guard.
--
-- CONTEXT: WEIMI reports each slot twice with DIFFERENT indexing:
--   * aisle_code  = "<cabinet>-A<NN>"  0-indexed   (e.g. 0-A01 = the 2nd aisle of cabinet 0)
--   * slot_name   = showName           1-indexed   (e.g. A2)
-- shelf_configurations.shelf_code is 1-indexed ('A02') and aligns with slot_name. The whole
-- read stack is already correct: seed_shelf_configurations derives shelf_code as
-- "letter || (aisle_code_number + 1)", and every engine/draft/pick caller joins
-- v_live_shelf_stock on slot_name = LEFT(shelf_code,1)||SUBSTR(shelf_code,2)::int. Audited
-- 2026-06-01: 727/727 live slots satisfy the invariant, 0 drift. The historical "WPP A01
-- Nescafe wrong-removal" was the pre-fix state and is gone (WPP Nescafe now correctly on A02).
--
-- THIS MIGRATION adds NO behavioral change to the read path (it is already correct, and editing
-- working joins would violate the no-refactor rule). It installs a READ-ONLY regression guard so
-- the off-by-one cannot silently return: a view that recomputes the invariant per live slot, plus
-- a daily cron that raises one monitoring_alerts finding if any slot ever drifts (WEIMI re-indexes,
-- a machine reports a nonstandard showName, or a malformed aisle_code appears). NOT YET APPLIED.

-- 1) Read-only diagnostic. expected_slot_name mirrors seed_shelf_configurations EXACTLY:
--    cabinet = prefix before '-'; letter = chr(65+cabinet); number = digits after '-A', +1.
CREATE OR REPLACE VIEW public.v_shelf_aisle_index_drift AS
SELECT
  v.machine_id,
  v.machine_name,
  v.cabinet_index,
  v.aisle_code,
  v.slot_name,
  CASE
    WHEN v.aisle_code !~ '^[0-9]+-A[0-9]+$' THEN NULL
    ELSE chr(65 + split_part(v.aisle_code, '-', 1)::int)
         || ((regexp_replace(v.aisle_code, '^[0-9]+-A', '')::int) + 1)::text
  END AS expected_slot_name,
  CASE
    WHEN v.aisle_code !~ '^[0-9]+-A[0-9]+$' THEN 'unparseable_aisle_code'
    WHEN v.slot_name IS DISTINCT FROM (
           chr(65 + split_part(v.aisle_code, '-', 1)::int)
           || ((regexp_replace(v.aisle_code, '^[0-9]+-A', '')::int) + 1)::text
         ) THEN 'index_drift'
    ELSE 'ok'
  END AS verdict
FROM public.v_live_shelf_stock v;

COMMENT ON VIEW public.v_shelf_aisle_index_drift IS
  'Refill v2 B2 guard: verifies the WEIMI 0-indexed aisle_code +1 == 1-indexed slot_name (showName) '
  'invariant that seed_shelf_configurations and every refill read-caller depend on. verdict in '
  '(ok|index_drift|unparseable_aisle_code). Expect zero non-ok rows. Read-only.';

-- 2) Daily cron monitor. Writes ONE deduped finding/day if any slot is not ok.
CREATE OR REPLACE FUNCTION public.cron_shelf_index_drift_alert()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_caller  text;
  v_drift    int;
  v_unparse  int;
  v_machines jsonb;
  v_inserted int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'cron_shelf_index_drift_alert', true);

  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
    IF v_caller IS NULL OR v_caller NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'cron_shelf_index_drift_alert: forbidden for role %', COALESCE(v_caller,'unknown');
    END IF;
  END IF;

  SELECT
    count(*) FILTER (WHERE verdict = 'index_drift'),
    count(*) FILTER (WHERE verdict = 'unparseable_aisle_code'),
    COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
      'machine', machine_name, 'aisle_code', aisle_code,
      'slot_name', slot_name, 'expected_slot_name', expected_slot_name, 'verdict', verdict))
      FILTER (WHERE verdict <> 'ok'), '[]'::jsonb)
  INTO v_drift, v_unparse, v_machines
  FROM public.v_shelf_aisle_index_drift;

  IF COALESCE(v_drift,0) + COALESCE(v_unparse,0) = 0 THEN
    RETURN jsonb_build_object('status','ok','drift_rows',0,'unparseable',0,'inserted',0);
  END IF;

  INSERT INTO public.monitoring_alerts (source, severity, payload)
  SELECT 'shelf_aisle_index_drift', 'critical',
    jsonb_build_object(
      'drift_rows',   COALESCE(v_drift,0),
      'unparseable',  COALESCE(v_unparse,0),
      'samples',      (SELECT jsonb_agg(e) FROM (SELECT jsonb_array_elements(v_machines) e LIMIT 25) s),
      'action_needed','The WEIMI aisle_code(0-indexed)+1 == slot_name(1-indexed) invariant broke. '
                      'seed_shelf_configurations and every refill read-caller assume it. Inspect '
                      'v_shelf_aisle_index_drift; do NOT re-seed shelf_configurations until resolved '
                      '(would map products to the wrong shelf, as in the original WPP A01 Nescafe bug).',
      'detected_at',  now())
  WHERE NOT EXISTS (
    SELECT 1 FROM public.monitoring_alerts a
    WHERE a.source = 'shelf_aisle_index_drift'
      AND a.created_at::date = CURRENT_DATE
  );
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN jsonb_build_object('status','drift_detected','drift_rows',COALESCE(v_drift,0),
    'unparseable',COALESCE(v_unparse,0),'inserted',v_inserted,'ran_at',now());
END $function$;
GRANT EXECUTE ON FUNCTION public.cron_shelf_index_drift_alert() TO authenticated;

-- 03:30 UTC = 07:30 Dubai daily, after the WEIMI overnight snapshots settle.
SELECT cron.schedule('shelf_aisle_index_drift_alert', '30 3 * * *',
  'SELECT public.cron_shelf_index_drift_alert();');
