-- PRD-074 P2: Article-13 deprecation of the legacy pre-brain generator + divergence guard.
--
-- auto_generate_refill_plan: zero callers (FE/n8n/edge/cron grepped; only reference is
-- the enforce_canonical_dispatch_write allowlist string, inert). Deprecated per Article 13:
-- SECURITY INVOKER + REVOKE EXECUTE; NOT dropped (90-day window; rollback = re-grant).
-- The refill brain (auto_generate via write_refill_plan pipeline + /refill-engine) is the
-- replacement.
ALTER FUNCTION public.auto_generate_refill_plan(text, date, boolean, text[]) SECURITY INVOKER;
REVOKE ALL ON FUNCTION public.auto_generate_refill_plan(text, date, boolean, text[]) FROM PUBLIC, authenticated, anon, service_role;
COMMENT ON FUNCTION public.auto_generate_refill_plan(text, date, boolean, text[]) IS
  'DEPRECATED 2026-07-04 (PRD-074, Article 13): legacy pre-brain generator; zero callers. Use the refill brain (write_refill_plan pipeline / refill-engine skill). Execute revoked; DROP eligible after 2026-10-04.';

-- Divergence guard: per-machine diffs between get_machine_health output and the canonical
-- views on shared fields. Must return ZERO rows for Active machines; leave callable for
-- future audits (T1 of every priority-surface change).
CREATE OR REPLACE FUNCTION public.check_priority_surface_consistency()
RETURNS TABLE(machine_name text, field text, health_value text, canonical_value text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT g.machine_name, d.field, d.hv, d.cv
  FROM get_machine_health() g
  JOIN machines m ON m.machine_id = g.machine_id AND m.status = 'Active'
  LEFT JOIN v_machine_priority mp ON mp.machine_id = g.machine_id
  LEFT JOIN v_machine_health_signals hs ON hs.machine_id = g.machine_id
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
       COALESCE(mp.urgency, 0)::text)
  ) d(field, hv, cv)
  WHERE d.hv IS DISTINCT FROM d.cv;
$$;

REVOKE ALL ON FUNCTION public.check_priority_surface_consistency() FROM public;
GRANT EXECUTE ON FUNCTION public.check_priority_surface_consistency() TO authenticated, service_role;

COMMENT ON FUNCTION public.check_priority_surface_consistency() IS
  'PRD-074: audits get_machine_health against v_machine_priority / v_machine_health_signals on shared fields (visit clock, score, tier, track, breakdown sum). Zero rows = surfaces consistent.';
