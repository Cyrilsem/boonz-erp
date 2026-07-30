-- PRD-110 P0.2 — stop the slot_lifecycle coverage gap regrowing, safely.
-- Applied via Supabase MCP as `prd110_p02_seed_slot_lifecycle_scope_guard` 2026-07-30.
--
-- Cody class (b): modified SECURITY DEFINER writer on protected entity slot_lifecycle.
--   Article 1  OK — same canonical writer; no second write path introduced.
--   Article 4  OK — role check + app.via_rpc/app.rpc_name preserved verbatim.
--   Article 8  OK — tg_audit_slot_lifecycle is installed on the table.
--   Article 12 OK — forward-only CREATE OR REPLACE, identical signature.
--
-- SIGNATURE DELIBERATELY UNCHANGED (p_dry_run boolean, p_machine_id uuid). Adding a defaulted
-- parameter would create an OVERLOAD rather than a replacement — the exact foot-gun behind the
-- 13-day driver-confirm outage (Wave-2 closeout lesson). No new args.
--
-- TWO DEFECTS FIXED (both found live 2026-07-30):
--  1. NO SCOPE GUARD. Unscoped, the function wanted to revive 272 rows: 47 on the 4 legitimate
--     Active+include_in_refill machines, 102 on Active-but-include_in_refill=false machines
--     (LVLUP x3, VOXMCC/VOXMM x3) and 123 on 5 INACTIVE warehouse pseudo-machines (LLFP,
--     WH1-2002, WH2_2006, WH2-2001, ALHQ-1016). Reviving lifecycle rows there injects those
--     shelves into engine_add_pod's universe — LVLUP is partner_managed, where WS-J1 says the
--     engine must plan nothing at all. Any future unscoped call (a cron, a console "just run
--     it") would silently corrupt the plan universe. Now filtered at source.
--  2. NOT RE-ENTRANT. CREATE TEMP TABLE _sl_gaps ON COMMIT DROP made a second call in the same
--     transaction fail with 42P07. Now dropped defensively first.

CREATE OR REPLACE FUNCTION public.seed_missing_slot_lifecycle(
  p_dry_run boolean DEFAULT true, p_machine_id uuid DEFAULT NULL::uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $function$
DECLARE
  v_user_id  uuid;
  v_rows     jsonb;
  v_n_insert integer := 0;
  v_n_revive integer := 0;
  v_skipped  integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','seed_missing_slot_lifecycle',true);
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id=v_user_id AND up.role='operator_admin'
  ) THEN RAISE EXCEPTION 'seed_missing_slot_lifecycle: caller % lacks operator_admin role', v_user_id; END IF;

  DROP TABLE IF EXISTS _sl_gaps;          -- re-entrancy (defect 2)

  CREATE TEMP TABLE _sl_gaps ON COMMIT DROP AS
  SELECT sc.machine_id, m.official_name, sc.shelf_id, sc.shelf_code,
         vls.pod_product_id, pp.pod_product_name,
         MAX(vls.current_stock)::int AS current_stock,
         EXISTS (SELECT 1 FROM public.slot_lifecycle old
                  WHERE old.machine_id = sc.machine_id AND old.shelf_id = sc.shelf_id
                    AND old.pod_product_id = vls.pod_product_id) AS has_old_row
  FROM public.v_live_shelf_stock vls
  JOIN public.machines m ON m.machine_id = vls.machine_id
  JOIN public.shelf_configurations sc ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
   AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
  JOIN public.pod_products pp ON pp.pod_product_id = vls.pod_product_id
  WHERE vls.pod_product_id IS NOT NULL
    AND vls.is_enabled = true AND vls.is_broken = false
    AND m.status = 'Active'                     -- scope guard (defect 1)
    AND m.include_in_refill = true              -- scope guard (defect 1)
    AND (p_machine_id IS NULL OR vls.machine_id = p_machine_id)
    AND NOT EXISTS (SELECT 1 FROM public.slot_lifecycle sl
                     WHERE sl.shelf_id = sc.shelf_id AND sl.machine_id = sc.machine_id
                       AND sl.archived = false AND sl.is_current = true)
  GROUP BY 1,2,3,4,5,6,8;

  -- guard: one pod_product per shelf (live-view fan-out safety): keep highest-stock product
  DELETE FROM _sl_gaps g
   WHERE EXISTS (SELECT 1 FROM _sl_gaps g2
                  WHERE g2.machine_id = g.machine_id AND g2.shelf_id = g.shelf_id
                    AND (g2.current_stock > g.current_stock
                         OR (g2.current_stock = g.current_stock AND g2.pod_product_id < g.pod_product_id)));

  -- observability: how many shelves the scope guard deliberately withheld
  SELECT count(*) INTO v_skipped
  FROM public.v_live_shelf_stock vls
  JOIN public.machines m ON m.machine_id = vls.machine_id
  JOIN public.shelf_configurations sc ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
   AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
  WHERE vls.pod_product_id IS NOT NULL AND vls.is_enabled AND NOT vls.is_broken
    AND NOT (m.status = 'Active' AND m.include_in_refill = true)
    AND NOT EXISTS (SELECT 1 FROM public.slot_lifecycle sl
                     WHERE sl.shelf_id = sc.shelf_id AND sl.machine_id = sc.machine_id
                       AND sl.archived = false AND sl.is_current = true);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'machine', official_name, 'shelf_code', shelf_code,
           'product', pod_product_name, 'current_stock', current_stock,
           'action', CASE WHEN has_old_row THEN 'revive' ELSE 'insert' END)
           ORDER BY official_name, shelf_code), '[]'::jsonb)
    INTO v_rows FROM _sl_gaps;

  IF p_dry_run THEN
    RETURN jsonb_build_object('dry_run', true,
      'pending_count', (SELECT COUNT(*) FROM _sl_gaps), 'rows', v_rows,
      'out_of_scope_skipped', v_skipped,
      'scope', 'machines.status=Active AND include_in_refill=true');
  END IF;

  UPDATE public.slot_lifecycle sl
     SET archived = false, is_current = true, rotated_in_at = now(),
         rotated_out_at = NULL, last_evaluated_at = now()
    FROM _sl_gaps g
   WHERE g.has_old_row
     AND sl.machine_id = g.machine_id AND sl.shelf_id = g.shelf_id
     AND sl.pod_product_id = g.pod_product_id;
  GET DIAGNOSTICS v_n_revive = ROW_COUNT;

  INSERT INTO public.slot_lifecycle(machine_id, shelf_id, shelf_code, pod_product_id, signal)
  SELECT g.machine_id, g.shelf_id, g.shelf_code, g.pod_product_id, 'KEEP'
  FROM _sl_gaps g WHERE NOT g.has_old_row;
  GET DIAGNOSTICS v_n_insert = ROW_COUNT;

  RETURN jsonb_build_object('dry_run', false,
    'revived', v_n_revive, 'inserted', v_n_insert, 'rows', v_rows,
    'out_of_scope_skipped', v_skipped,
    'scope', 'machines.status=Active AND include_in_refill=true');
END;
$function$;

COMMENT ON FUNCTION public.seed_missing_slot_lifecycle(boolean, uuid) IS
  'PRD-110 P0.2. Canonical repairer of the slot_lifecycle coverage gap (RC-06): revives stale '
  '(archived/not-current) rows and inserts genuinely missing ones so no live WEIMI shelf is '
  'invisible to engine_add_pod, whose shelf universe is an INNER JOIN on '
  'slot_lifecycle(archived=false, is_current=true). Scoped to Active + include_in_refill '
  'machines only. out_of_scope_skipped reports what the guard withheld.';
