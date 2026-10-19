-- PRD-142b A8: phantom shelves. shelf_configurations is templated A01-A16 plus B01-B16 on most machines (and
-- C, D, E on the four AMZ machines) whatever the physical door count. The strategy layer now only looks at
-- cabinets that exist: cabinet index (A = 0, B = 1, ...) below machines.cabinet_count, or, when cabinet_count
-- is NULL, cabinets with a sale (fact_shelf_daily) or a pod_inventory snapshot in the last 180 days.
-- shelf_configurations itself is NOT touched (planner views and the slot guard read it); the cleanup list is
-- docs/prds/PRD-142-phantom-shelves.md. Patches are single-occurrence replace() on the live bodies, each guarded.

CREATE OR REPLACE FUNCTION public.strategy_cabinet_in_scope(p_machine_id uuid, p_shelf_code text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT CASE
           WHEN m.cabinet_count IS NOT NULL THEN ascii(upper(left(p_shelf_code, 1))) - 65 < m.cabinet_count
           ELSE EXISTS (SELECT 1 FROM fact_shelf_daily s
                         WHERE s.machine_id = p_machine_id AND left(s.shelf_code, 1) = upper(left(p_shelf_code, 1))
                           AND s.units > 0 AND s.d > (now() AT TIME ZONE 'Asia/Dubai')::date - 180)
             OR EXISTS (SELECT 1 FROM pod_inventory pi JOIN shelf_configurations sc ON sc.shelf_id = pi.shelf_id
                         WHERE pi.machine_id = p_machine_id AND left(sc.shelf_code, 1) = upper(left(p_shelf_code, 1))
                           AND pi.snapshot_date > (now() AT TIME ZONE 'Asia/Dubai')::date - 180)
         END
  FROM machines m WHERE m.machine_id = p_machine_id
$$;
REVOKE EXECUTE ON FUNCTION public.strategy_cabinet_in_scope(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.strategy_cabinet_in_scope(uuid, text) TO authenticated, service_role;

DO $do$
DECLARE
  v_old text; v_new text; v_find text; v_repl text;
BEGIN
  -- 1. get_strategy_machine_detail: the shelf grid only lists lanes of existing cabinets.
  v_old  := pg_get_functiondef('public.get_strategy_machine_detail(uuid)'::regprocedure);
  v_find := E'    WHERE c.machine_id = p_machine_id\n  ),\n  lane_sales AS (';
  v_repl := E'    WHERE c.machine_id = p_machine_id\n      AND strategy_cabinet_in_scope(c.machine_id, c.shelf_code)  -- PRD-142b A8: no phantom cabinets\n  ),\n  lane_sales AS (';
  IF (length(v_old) - length(replace(v_old, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'A8 guard: get_strategy_machine_detail anchor found % times', (length(v_old) - length(replace(v_old, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_old, v_find, v_repl);
  IF v_new = v_old THEN RAISE EXCEPTION 'A8 guard: get_strategy_machine_detail unchanged'; END IF;
  EXECUTE v_new;

  -- 2. build_machine_features: shelf KPIs (dead shelf pct, top5 share, shelves) use the same cabinet filter.
  v_old  := pg_get_functiondef('public.build_machine_features(date)'::regprocedure);
  v_find := 'JOIN shelf_configurations sc ON sc.machine_id = c.machine_id AND NOT COALESCE(sc.is_phantom, false)';
  v_repl := 'JOIN shelf_configurations sc ON sc.machine_id = c.machine_id AND NOT COALESCE(sc.is_phantom, false)'
            || ' AND strategy_cabinet_in_scope(sc.machine_id, sc.shelf_code)';
  IF (length(v_old) - length(replace(v_old, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'A8 guard: build_machine_features anchor found % times', (length(v_old) - length(replace(v_old, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_old, v_find, v_repl);
  IF v_new = v_old THEN RAISE EXCEPTION 'A8 guard: build_machine_features unchanged'; END IF;
  EXECUTE v_new;
END
$do$;
