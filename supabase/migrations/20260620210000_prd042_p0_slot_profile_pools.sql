-- PRD-042 P0: slot-profile assortment pools data layer (swap engine v5, gated OFF).
-- Forward-only. New reference/cache tables + a rebuild RPC. No protected entity touched.
-- swaps_enabled untouched; engine_add_pod untouched. (Absorbs the abandoned PRD-041
-- physical_type_lane_family idea; same CS-approved 7-family starter grouping, coverage 14/14.)
--
-- Three objects + one writer:
--   physical_type_lane_family  : 14 physical_types -> 7 lane families (read-only ref).
--   slot_pool_curation         : CS include/exclude overrides (read-only ref; empty, derived-only).
--   slot_profile_pool          : PRECOMPUTED (lane_family, shelf_size) -> product + fill_qty cache,
--                                rebuilt nightly by rebuild_slot_profile_pool() before job 13.

-- 1) lane family map (read-only; explicit no-write policies; written by migration only)
CREATE TABLE IF NOT EXISTS public.physical_type_lane_family (
  physical_type text PRIMARY KEY,
  lane_family   text NOT NULL
);
ALTER TABLE public.physical_type_lane_family ENABLE ROW LEVEL SECURITY;
CREATE POLICY ptlf_select    ON public.physical_type_lane_family FOR SELECT USING (true);
CREATE POLICY ptlf_no_insert ON public.physical_type_lane_family FOR INSERT WITH CHECK (false);
CREATE POLICY ptlf_no_update ON public.physical_type_lane_family FOR UPDATE USING (false);
CREATE POLICY ptlf_no_delete ON public.physical_type_lane_family FOR DELETE USING (false);
INSERT INTO public.physical_type_lane_family (physical_type, lane_family) VALUES
  ('bottle_330','bottle'),('bottle_500','bottle'),('bottle_large','bottle'),
  ('can_250','can'),('can_330','can'),
  ('bar_standard','snack_small'),('pack_gum','snack_small'),('date_ball','snack_small'),
  ('bag_snack','bag'),('bag_large','bag'),
  ('box_biscuit','boxed'),('cake_wrapped','boxed'),
  ('cup_yogurt','cup'),('other','other')
ON CONFLICT (physical_type) DO NOTHING;

-- 2) curation overrides (read-only ref; empty/derived-only for now; written by migration only
--    until a curation RPC is added). include/exclude per (lane_family, shelf_size, product).
CREATE TABLE IF NOT EXISTS public.slot_pool_curation (
  lane_family      text NOT NULL,
  shelf_size       text NOT NULL,
  boonz_product_id uuid NOT NULL,
  mode             text NOT NULL CHECK (mode IN ('include','exclude')),
  note             text,
  PRIMARY KEY (lane_family, shelf_size, boonz_product_id, mode)
);
ALTER TABLE public.slot_pool_curation ENABLE ROW LEVEL SECURITY;
CREATE POLICY spc_select    ON public.slot_pool_curation FOR SELECT USING (true);
CREATE POLICY spc_no_insert ON public.slot_pool_curation FOR INSERT WITH CHECK (false);
CREATE POLICY spc_no_update ON public.slot_pool_curation FOR UPDATE USING (false);
CREATE POLICY spc_no_delete ON public.slot_pool_curation FOR DELETE USING (false);

-- 3) precomputed pool cache (read-only ref; written ONLY by rebuild_slot_profile_pool()).
CREATE TABLE IF NOT EXISTS public.slot_profile_pool (
  lane_family      text NOT NULL,
  shelf_size       text NOT NULL,
  boonz_product_id uuid NOT NULL,
  fill_qty         integer NOT NULL,
  computed_at      timestamptz NOT NULL,
  PRIMARY KEY (lane_family, shelf_size, boonz_product_id)
);
ALTER TABLE public.slot_profile_pool ENABLE ROW LEVEL SECURITY;
CREATE POLICY spp_select    ON public.slot_profile_pool FOR SELECT USING (true);
CREATE POLICY spp_no_insert ON public.slot_profile_pool FOR INSERT WITH CHECK (false);
CREATE POLICY spp_no_update ON public.slot_profile_pool FOR UPDATE USING (false);
CREATE POLICY spp_no_delete ON public.slot_profile_pool FOR DELETE USING (false);

-- 4) rebuild RPC: full nightly refresh of the precomputed pool.
--    effective pool = derived(lane x size x product, fill_qty from product_slot_capacity_units*0.85)
--    MINUS slot_pool_curation excludes PLUS includes; computed_at = now().
CREATE OR REPLACE FUNCTION public.rebuild_slot_profile_pool()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows integer;
  v_t0   timestamptz := clock_timestamp();
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','rebuild_slot_profile_pool',true);

  -- Full refresh of the derived cache (this table is a precomputed projection, not a
  -- protected entity; it is rebuilt in full each night inside this single transaction).
  DELETE FROM public.slot_profile_pool;

  INSERT INTO public.slot_profile_pool (lane_family, shelf_size, boonz_product_id, fill_qty, computed_at)
  WITH sizes AS (SELECT unnest(ARRAY['Small','Medium','Large']) AS shelf_size),
  derived AS (
    SELECT lf.lane_family, s.shelf_size, bp.product_id AS boonz_product_id,
           GREATEST(FLOOR(public.product_slot_capacity_units(bp.physical_type, s.shelf_size) * 0.85)::int, 1) AS fill_qty
      FROM public.boonz_products bp
      JOIN public.physical_type_lane_family lf ON lf.physical_type = bp.physical_type
      CROSS JOIN sizes s
  ),
  kept AS (
    SELECT d.lane_family, d.shelf_size, d.boonz_product_id, d.fill_qty
      FROM derived d
     WHERE NOT EXISTS (
       SELECT 1 FROM public.slot_pool_curation c
        WHERE c.mode = 'exclude' AND c.lane_family = d.lane_family
          AND c.shelf_size = d.shelf_size AND c.boonz_product_id = d.boonz_product_id)
  ),
  added AS (
    SELECT c.lane_family, c.shelf_size, c.boonz_product_id,
           GREATEST(FLOOR(public.product_slot_capacity_units(bp.physical_type, c.shelf_size) * 0.85)::int, 1) AS fill_qty
      FROM public.slot_pool_curation c
      JOIN public.boonz_products bp ON bp.product_id = c.boonz_product_id
     WHERE c.mode = 'include'
  )
  SELECT lane_family, shelf_size, boonz_product_id, fill_qty, now() FROM kept
  UNION
  SELECT lane_family, shelf_size, boonz_product_id, fill_qty, now() FROM added;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','rows',v_rows,'computed_at',now(),
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int);
END
$function$;

REVOKE ALL ON FUNCTION public.rebuild_slot_profile_pool() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_slot_profile_pool() TO service_role;

-- 5) first rebuild so the table is populated immediately.
SELECT public.rebuild_slot_profile_pool();

-- 6) nightly cron BEFORE job 13 (phaseF_stage1_prep_8pm_dubai @ 16:00 UTC). 15:30 UTC = 7:30pm Dubai.
SELECT cron.schedule('rebuild_slot_profile_pool_nightly', '30 15 * * *',
  $cron$SELECT public.rebuild_slot_profile_pool();$cron$);
