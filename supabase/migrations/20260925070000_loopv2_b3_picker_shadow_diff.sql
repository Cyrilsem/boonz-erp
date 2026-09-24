-- Loop 2026-09-25 B3 (PRD-133): v_picker_shadow_diff(plan_date), a side-by-side v11 vs v12
-- comparison for a given plan_date.
--
-- Implemented as a set-returning function, not a plain view, since it takes a plan_date argument
-- (matching the task's own "v_picker_shadow_diff(plan_date)" naming).
--
-- Neither picker's full data always lives in the same table for a given historical plan_date:
-- _build_draft_core_v3 (B2) writes whichever picker is authoritative into machines_to_visit and
-- archives the OTHER one's run into machines_to_visit_shadow, tagged by picker_version. This
-- function reconstructs both sides for a plan_date by reading machines_to_visit_shadow first for
-- each version, and falling back to machines_to_visit only for whichever version has no shadow
-- row for that date (meaning that version was the authoritative one that day). Read-only, no
-- writes; SQL language, STABLE, no smoke-call rule applies (it creates no writer function).
--
-- Verified in a rolled-back transaction (synthetic plan_date 2026-10-15, same one B2 used):
-- ran _build_draft_core_v3 in 'shadow' mode to populate real v11 (machines_to_visit) and v12
-- (machines_to_visit_shadow) rows inside the transaction, then called this function and confirmed
-- it returned the correct side-by-side rows with agreement correctly flagged, before rolling back.

CREATE OR REPLACE FUNCTION public.v_picker_shadow_diff(p_plan_date date)
 RETURNS TABLE(
   machine_id uuid, official_name text,
   v11_tier text, v11_reasons text[], v11_visit_value_aed numeric,
   v12_tier text, v12_reasons text[], v12_visit_value_aed numeric,
   v12_cluster_role text, v12_donor_for jsonb,
   agreement text
 )
 LANGUAGE sql
 SECURITY DEFINER
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH v11_shadow AS (
    SELECT machine_id, official_name, tier, reasons, visit_value_aed
      FROM public.machines_to_visit_shadow
     WHERE plan_date = p_plan_date AND picker_version = 'v11'
  ),
  v12_shadow AS (
    SELECT machine_id, official_name, tier, reasons, visit_value_aed, cluster_role, donor_for
      FROM public.machines_to_visit_shadow
     WHERE plan_date = p_plan_date AND picker_version = 'v12'
  ),
  v11_live AS (
    SELECT mv.machine_id, mv.official_name, mv.priority_tier AS tier,
           mv.picked_reasons AS reasons, mv.priority_score AS visit_value_aed
      FROM public.machines_to_visit mv
     WHERE mv.plan_date = p_plan_date AND mv.status = 'picked'
       AND NOT EXISTS (SELECT 1 FROM v11_shadow)
  ),
  v11_all AS (
    SELECT * FROM v11_shadow
    UNION ALL
    SELECT * FROM v11_live
  ),
  v12_live AS (
    SELECT mv.machine_id, mv.official_name, mv.priority_tier AS tier,
           mv.picked_reasons AS reasons, mv.priority_score AS visit_value_aed,
           NULL::text AS cluster_role, NULL::jsonb AS donor_for
      FROM public.machines_to_visit mv
     WHERE mv.plan_date = p_plan_date AND mv.status = 'picked'
       AND NOT EXISTS (SELECT 1 FROM v12_shadow)
       AND EXISTS (SELECT 1 FROM v11_shadow)
  ),
  v12_all AS (
    SELECT * FROM v12_shadow
    UNION ALL
    SELECT * FROM v12_live
  )
  SELECT
    COALESCE(a.machine_id, b.machine_id) AS machine_id,
    COALESCE(a.official_name, b.official_name) AS official_name,
    a.tier AS v11_tier, a.reasons AS v11_reasons, a.visit_value_aed AS v11_visit_value_aed,
    b.tier AS v12_tier, b.reasons AS v12_reasons, b.visit_value_aed AS v12_visit_value_aed,
    b.cluster_role AS v12_cluster_role, b.donor_for AS v12_donor_for,
    CASE
      WHEN a.machine_id IS NULL THEN 'v12_only'
      WHEN b.machine_id IS NULL THEN 'v11_only'
      -- v11 and v12 use different tier vocabularies (P1_RESTOCK/P2_MAINTAIN vs P1/P2/P3); this
      -- normalizes just for the agreement check, the raw native strings still show in
      -- v11_tier/v12_tier above.
      WHEN (CASE a.tier WHEN 'P1_RESTOCK' THEN 'P1' WHEN 'P2_MAINTAIN' THEN 'P2' ELSE a.tier END)
           = b.tier THEN 'same_tier'
      ELSE 'different_tier'
    END AS agreement
  FROM v11_all a
  FULL OUTER JOIN v12_all b ON a.machine_id = b.machine_id
  ORDER BY COALESCE(a.tier, b.tier), COALESCE(a.official_name, b.official_name);
$function$;
