-- PRD-090 (Wave 1 ADD, Cody PASS): niche merchandising fill floor, SHIP DARK. Composes on 089.
-- Flag add_niche_fill_v1 seeded OFF. Niche floor raises need_raw only; downstream fill_to_cap +
-- pickable wh_avail clamp UNCHANGED. PROVEN inert (flag off => diff_vs_golden IDENTICAL).
-- NOTE: this migration's footprint subquery had a wrong column (pod_inventory.pod_product_id);
-- corrected by the immediately-following prd090_fix_footprint_source_slot_lifecycle. Both applied.
ALTER TABLE public.refill_policy_params ADD COLUMN IF NOT EXISTS niche_footprint_max integer NOT NULL DEFAULT 2;
ALTER TABLE public.refill_policy_params ADD COLUMN IF NOT EXISTS niche_facing_target numeric NOT NULL DEFAULT 0.8;
INSERT INTO refill_qa.feature_flag(flag,value) VALUES ('add_niche_fill_v1','off') ON CONFLICT (flag) DO NOTHING;
DO $outer$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.engine_add_pod(date,integer)'::regprocedure);
  IF position('CASE WHEN v_add_abs_floor AND NOT(cv.v7=0 AND cv.v30=0) THEN v_min_facing_floor ELSE 0 END)' IN v_def) = 0 THEN
    RAISE EXCEPTION 'PRD-090: 089 anchor not found - aborting (fail closed)'; END IF;
  IF position('v_add_niche_fill' IN v_def) > 0 THEN RETURN; END IF;
  v_def := replace(v_def, '  v_min_facing_floor integer := COALESCE((SELECT min_facing_floor FROM public.refill_policy_params LIMIT 1),2);'||E'\n',
    '  v_min_facing_floor integer := COALESCE((SELECT min_facing_floor FROM public.refill_policy_params LIMIT 1),2);'||E'\n'||
    '  v_add_niche_fill boolean := (refill_qa.flag(''add_niche_fill_v1'')=''on'');'||E'\n'||
    '  v_niche_footprint_max integer := COALESCE((SELECT niche_footprint_max FROM public.refill_policy_params LIMIT 1),2);'||E'\n'||
    '  v_niche_facing_target numeric := COALESCE((SELECT niche_facing_target FROM public.refill_policy_params LIMIT 1),0.8);'||E'\n');
  v_def := replace(v_def, 'CASE WHEN v_add_abs_floor AND NOT(cv.v7=0 AND cv.v30=0) THEN v_min_facing_floor ELSE 0 END)',
    'CASE WHEN v_add_abs_floor AND NOT(cv.v7=0 AND cv.v30=0) THEN v_min_facing_floor ELSE 0 END, '||
    'CASE WHEN v_add_niche_fill AND (SELECT count(DISTINCT sl.machine_id) FROM slot_lifecycle sl JOIN machines mm ON mm.machine_id=sl.machine_id AND mm.status=''Active'' WHERE sl.pod_product_id = cv.pod_product_id AND sl.is_current AND NOT sl.archived) <= v_niche_footprint_max AND cv.v30 >= (SELECT MAX(cv2.v30) FROM covered cv2 WHERE cv2.pod_product_id = cv.pod_product_id) THEN (CASE WHEN v_niche_facing_target <= 1 THEN CEIL(v_niche_facing_target * cv.max_stock)::int ELSE v_niche_facing_target::int END) ELSE 0 END)');
  EXECUTE v_def;
END $outer$;
