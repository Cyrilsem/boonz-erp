-- PRD-039 Phase 0 (B): get_candidate_affinity -- scoring-only Pearson/co-purchase helper.
-- Forward-only. New function (NOT a refactor of find_substitutes_for_shelf) so PRD-037
-- regression R1 (T1-T7,T10-T13) and find_substitutes stay byte-identical. Author-only
-- until CS green-lights apply.
--
-- WHY: today the basket-correlation (Pearson) score lives ONLY inside
-- find_substitutes_for_shelf, where it doubles as the candidate-shortlist GATE and as a
-- ranking term. PRD-039 WS-A removes find_substitutes as the gate and broadens the universe
-- to v_wh_pickable; the w3 affinity term must then be computable for ANY candidate vs a
-- machine's basket, independent of the shortlist. This helper returns exactly the score
-- find_substitutes computes (per-machine correlation, loc-type fallback, averaged over the
-- machine's velocity>0 basket), so V's w3 term is unchanged in meaning -- no double-count.

CREATE OR REPLACE FUNCTION public.get_candidate_affinity(
  p_machine_id          uuid,
  p_cand_pod_product_id uuid
) RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_loc_type text;
  v_score    numeric;
BEGIN
  IF p_machine_id IS NULL OR p_cand_pod_product_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT m.location_type INTO v_loc_type
    FROM public.machines m WHERE m.machine_id = p_machine_id;

  WITH basket AS (
    SELECT sl.pod_product_id
      FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id
       AND sl.archived = false AND sl.is_current = true
       AND (COALESCE(sl.velocity_7d,0) > 0 OR COALESCE(sl.velocity_30d,0) > 0)
  )
  SELECT COALESCE(
    -- per-machine correlation first
    (SELECT AVG(cm.pearson) FROM public.correlation_pod_per_machine cm
      WHERE cm.machine_id = p_machine_id
        AND cm.pod_product_b = p_cand_pod_product_id
        AND cm.pod_product_a IN (SELECT pod_product_id FROM basket)),
    -- loc-type correlation fallback
    (SELECT AVG(cl.pearson) FROM public.correlation_pod_per_loc_type cl
      WHERE cl.location_type = v_loc_type
        AND cl.pod_product_b = p_cand_pod_product_id
        AND cl.pod_product_a IN (SELECT pod_product_id FROM basket)),
    0
  )::numeric INTO v_score;

  RETURN COALESCE(v_score, 0);
END
$function$;

COMMENT ON FUNCTION public.get_candidate_affinity(uuid,uuid) IS
  'PRD-039 WS-A. Scoring-only Pearson/co-purchase score for an arbitrary candidate pod vs a '
  'machine basket (velocity>0 on-machine pods). Mirrors find_substitutes_for_shelf basket_corr '
  'exactly: per-machine correlation, loc-type fallback, COALESCE 0. Read-only, no gate.';

REVOKE ALL ON FUNCTION public.get_candidate_affinity(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_candidate_affinity(uuid,uuid) TO authenticated, service_role;
