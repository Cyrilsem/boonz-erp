-- PRD-089 (Wave 1 ADD, Cody PASS): absolute velocity floor + min-facing, SHIP DARK.
-- engine_add_pod modified via 3 NAMED substitutions (auditable diff; deterministic on the
-- live def -> perfect prod=file parity for an 18KB engine). Flag add_abs_floor_v1 seeded OFF.
-- PROVEN inert: flag OFF => diff_vs_golden IDENTICAL. Other-3 Family A md5 11b0b03f unchanged.
-- NEVER enabled (CS-only). Live sizing_mode=base_stock so the legacy/velocity branch is dormant.
ALTER TABLE public.refill_policy_params ADD COLUMN IF NOT EXISTS abs_velocity_floor numeric NOT NULL DEFAULT 0.5;
ALTER TABLE public.refill_policy_params ADD COLUMN IF NOT EXISTS min_facing_floor integer NOT NULL DEFAULT 2;
INSERT INTO refill_qa.feature_flag(flag,value) VALUES ('add_abs_floor_v1','off') ON CONFLICT (flag) DO NOTHING;

DO $outer$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.engine_add_pod(date,integer)'::regprocedure);
  IF position('#variable_conflict use_column'||E'\nDECLARE\n' IN v_def) = 0
     OR position('* (CASE b.machine_band WHEN 1 THEN 1.00 WHEN 2 THEN 0.60 ELSE 0.30 END))::int, 1)' IN v_def) = 0
     OR position('GREATEST(cv.cover_units, COALESCE(cv.driver_req_qty,0))' IN v_def) = 0 THEN
    RAISE EXCEPTION 'PRD-089: engine_add_pod anchors not found - aborting (fail closed)';
  END IF;
  IF position('v_add_abs_floor' IN v_def) > 0 THEN RETURN; END IF;
  v_def := replace(v_def, E'#variable_conflict use_column\nDECLARE\n',
    E'#variable_conflict use_column\nDECLARE\n  v_add_abs_floor boolean := (refill_qa.flag(''add_abs_floor_v1'')=''on'');\n  v_abs_velocity_floor numeric := COALESCE((SELECT abs_velocity_floor FROM public.refill_policy_params LIMIT 1),0.5);\n  v_min_facing_floor integer := COALESCE((SELECT min_facing_floor FROM public.refill_policy_params LIMIT 1),2);\n');
  v_def := replace(v_def, '* (CASE b.machine_band WHEN 1 THEN 1.00 WHEN 2 THEN 0.60 ELSE 0.30 END))::int, 1)',
    '* (CASE WHEN v_add_abs_floor AND (b.v30/30.0 >= v_abs_velocity_floor OR b.v7 >= v_abs_velocity_floor) THEN 1.00 ELSE (CASE b.machine_band WHEN 1 THEN 1.00 WHEN 2 THEN 0.60 ELSE 0.30 END) END))::int, 1)');
  v_def := replace(v_def, 'GREATEST(cv.cover_units, COALESCE(cv.driver_req_qty,0))',
    'GREATEST(cv.cover_units, COALESCE(cv.driver_req_qty,0), CASE WHEN v_add_abs_floor AND NOT(cv.v7=0 AND cv.v30=0) THEN v_min_facing_floor ELSE 0 END)');
  EXECUTE v_def;
END $outer$;
