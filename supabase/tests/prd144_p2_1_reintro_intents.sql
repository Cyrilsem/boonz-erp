-- PRD-144 P2-1 test (run after the migration). Ends with RAISE: nothing persists.
-- Seeds present; at min_wh_stock 24 nothing is proposed (5 cans in stock); at 1 both seeds propose an
-- Add New [reintro] with lane choices; warehouse role refused; a reintro row without min_wh_stock refused.
DO $t$
DECLARE v_ids uuid[] := ARRAY['84386a8b-ba1c-4be1-aa51-a529203ecfb6'::uuid, 'f1a528fb-15e8-4f20-b4e2-ebb2e6852198'::uuid];
  v_def jsonb; v_low jsonb; e_role text := 'not refused'; e_shape text := 'not refused'; v_seeds int;
BEGIN
  SELECT count(*) INTO v_seeds FROM sku_intents WHERE intent = 'reintro_when_stocked';
  PERFORM set_config('request.jwt.claims', '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
  v_def := public.get_reintro_proposals('2026-10-20', v_ids);
  UPDATE sku_intents SET min_wh_stock = 1 WHERE intent = 'reintro_when_stocked';
  v_low := public.get_reintro_proposals('2026-10-20', v_ids);
  BEGIN INSERT INTO sku_intents (machine_id, boonz_product_id, intent) VALUES (v_ids[1], 'd8096c9b-1dd7-42bf-96b8-a9aaae7132dc', 'reintro_when_stocked');
  EXCEPTION WHEN OTHERS THEN e_shape := SQLERRM; END;
  PERFORM set_config('request.jwt.claims', '{"sub":"bf32624e-3334-425d-b694-c5944b0c66f0","role":"authenticated"}', true);
  BEGIN PERFORM public.get_reintro_proposals('2026-10-20', v_ids); EXCEPTION WHEN OTHERS THEN e_role := SQLERRM; END;
  RAISE EXCEPTION 'PRD144_P2_1 % | seeds=% | at 24: % | at 1: %',
    CASE WHEN v_seeds = 2 AND jsonb_array_length(v_def) = 0 AND jsonb_array_length(v_low) = 2
              AND jsonb_array_length(v_low->0->'lane_choices') >= 1
              AND e_role LIKE '%forbidden%' AND e_shape LIKE '%reintro_shape%' THEN 'PASS' ELSE 'FAIL' END,
    v_seeds, jsonb_array_length(v_def), left(v_low::text, 600);
END $t$;
