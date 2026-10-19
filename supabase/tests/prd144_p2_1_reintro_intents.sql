-- PRD-144 P2-1 test (run after the migration). Ends with RAISE: nothing persists.
-- 28 PRD-143 seeds present, none for Red Bull 355ML at AMZ-1029. For every seeded machine, an intent is proposed
-- exactly when the machine's own warehouses hold at least min_wh_stock pickable units (checked independently
-- here), each proposal is an Add New [reintro] with up to 3 lane choices. Warehouse role refused; a reintro row
-- without min_wh_stock refused.
DO $t$
DECLARE
  v_ids uuid[]; v_out jsonb; v_seeds int; v_355 int; v_expect int; v_mismatch int; v_lanes int;
  e_role text := 'not refused'; e_shape text := 'not refused';
BEGIN
  SELECT count(*), array_agg(DISTINCT machine_id) INTO v_seeds, v_ids FROM sku_intents WHERE intent = 'reintro_when_stocked';
  SELECT count(*) INTO v_355 FROM sku_intents i JOIN machines m ON m.machine_id = i.machine_id JOIN boonz_products bp ON bp.product_id = i.boonz_product_id
   WHERE i.intent = 'reintro_when_stocked' AND m.official_name LIKE 'AMZ-1029%' AND bp.boonz_product_name = 'Red Bull - 355ML';
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  v_out := public.get_reintro_proposals((now() AT TIME ZONE 'Asia/Dubai')::date + 1, v_ids);

  WITH exp AS (
    SELECT i.id, COALESCE((SELECT SUM(vp.warehouse_stock) FROM v_wh_pickable vp JOIN machines mw ON mw.machine_id = i.machine_id
                            WHERE vp.boonz_product_id = i.boonz_product_id
                              AND vp.warehouse_id IN (mw.primary_warehouse_id, mw.secondary_warehouse_id)
                              AND (vp.reserved_for_machine_id IS NULL OR vp.reserved_for_machine_id = i.machine_id)), 0) >= i.min_wh_stock AS ready
      FROM sku_intents i WHERE i.intent = 'reintro_when_stocked'),
  got AS (SELECT (x->>'intent_id')::uuid AS id FROM jsonb_array_elements(v_out) x)
  SELECT count(*) FILTER (WHERE e.ready),
         count(*) FILTER (WHERE e.ready <> (g.id IS NOT NULL))
    INTO v_expect, v_mismatch
    FROM exp e LEFT JOIN got g ON g.id = e.id;
  SELECT count(*) INTO v_lanes FROM jsonb_array_elements(v_out) x
   WHERE x->>'action' = 'Add New' AND x->>'comment' LIKE '[reintro]%'
     AND jsonb_array_length(x->'lane_choices') BETWEEN 1 AND 3;

  BEGIN INSERT INTO sku_intents (machine_id, boonz_product_id, intent) VALUES (v_ids[1], 'd8096c9b-1dd7-42bf-96b8-a9aaae7132dc', 'reintro_when_stocked');
  EXCEPTION WHEN OTHERS THEN e_shape := SQLERRM; END;
  PERFORM set_config('request.jwt.claims', '{"sub":"bf32624e-3334-425d-b694-c5944b0c66f0","role":"authenticated"}', true);
  BEGIN PERFORM public.get_reintro_proposals('2026-10-20', v_ids); EXCEPTION WHEN OTHERS THEN e_role := SQLERRM; END;

  RAISE EXCEPTION 'PRD144_P2_1 % | seeds=% red_bull_355_at_1029=% | proposed=% expected=% mismatches=% with_lanes=% | %',
    CASE WHEN v_seeds = 28 AND v_355 = 0 AND v_mismatch = 0 AND jsonb_array_length(v_out) = v_expect AND v_expect > 0
              AND v_lanes >= 1 AND e_role LIKE '%forbidden%' AND e_shape LIKE '%reintro_shape%' THEN 'PASS' ELSE 'FAIL' END,
    v_seeds, v_355, jsonb_array_length(v_out), v_expect, v_mismatch, v_lanes,
    (SELECT string_agg(format('%s %s wh=%s lanes=%s', x->>'machine_name', x->>'boonz_product_name', x->>'wh_stock',
                              jsonb_array_length(x->'lane_choices')), '; ') FROM jsonb_array_elements(v_out) x);
END $t$;
