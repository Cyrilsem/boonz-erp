-- Rollback for PRD-100: live check_priority_surface_consistency as of 2026-07-14.
CREATE OR REPLACE FUNCTION public.check_priority_surface_consistency()
 RETURNS TABLE(machine_name text, field text, health_value text, canonical_value text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT g.machine_name, d.field, d.hv, d.cv
  FROM get_machine_health() g
  JOIN machines m ON m.machine_id = g.machine_id AND m.status = 'Active'
  LEFT JOIN v_machine_priority mp ON mp.machine_id = g.machine_id
  LEFT JOIN v_machine_health_signals hs ON hs.machine_id = g.machine_id
  CROSS JOIN pick_urgency_params pup
  CROSS JOIN LATERAL (
    SELECT
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='runout'), 0)   AS chip_runout,
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='capacity'), 0) AS chip_capacity,
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='expiry'), 0)   AS chip_expiry,
      COALESCE((SELECT (e->>'pts')::numeric FROM jsonb_array_elements(COALESCE(g.urgency_breakdown,'[]'::jsonb)) e WHERE e->>'label'='stale'), 0)    AS chip_stale
  ) ch
  CROSS JOIN LATERAL (VALUES
    ('days_since_visit', g.days_since_visit::text, COALESCE(hs.days_since_visit, -1)::text),
    ('priority_score',   g.priority_score::text,   COALESCE(mp.p_score, 0)::text),
    ('priority_tier',    g.priority_tier,
       CASE WHEN NOT COALESCE(m.include_in_refill, true)
                 OR COALESCE(m.status, 'Active') IN ('Warehouse','Inactive') THEN 'excluded'
            WHEN mp.p_tier = 'P3_OK' OR mp.p_tier IS NULL THEN 'skip'
            ELSE mp.p_tier END),
    ('service_track',    g.service_track,
       COALESCE(mp.svc_track, CASE WHEN m.venue_group = 'VOX' THEN 'vox' ELSE 'main' END)),
    ('urgency_breakdown_sum',
       COALESCE((SELECT round(sum((e->>'pts')::numeric), 2) FROM jsonb_array_elements(g.urgency_breakdown) e), 0)::text,
       COALESCE(mp.urgency, 0)::text),
    ('chip_capacity', round(ch.chip_capacity,2)::text, round(pup.w_capacity * COALESCE(mp.s_capacity,0), 2)::text),
    ('chip_expiry',   round(ch.chip_expiry,2)::text,   round(pup.w_expiry   * COALESCE(mp.s_expiry,0), 2)::text),
    ('chip_stale',    round(ch.chip_stale,2)::text,    round(pup.w_stale    * COALESCE(mp.s_stale,0), 2)::text),
    ('chip_runout',   round(ch.chip_runout,2)::text,
       round((round(COALESCE(mp.urgency,0),2)
        - round(pup.w_capacity * COALESCE(mp.s_capacity,0), 2)
        - round(pup.w_expiry   * COALESCE(mp.s_expiry,0), 2)
        - round(pup.w_stale    * COALESCE(mp.s_stale,0), 2)
        - round(pup.w_empty    * COALESCE(mp.s_empty,0), 2)
        - round(pup.w_lowfill  * COALESCE(mp.s_lowfill,0), 2)), 2)::text)
  ) d(field, hv, cv)
  WHERE d.hv IS DISTINCT FROM d.cv;
$function$;
