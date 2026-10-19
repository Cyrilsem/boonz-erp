-- PRD-144 P2-1 (PRD-143): reintroduction intents.
-- sku_intents gets intent 'reintro_when_stocked' (machine + boonz product + min_wh_stock + optional
-- preferred_lane_size). get_reintro_proposals(plan_date, machine_ids) returns, for each such intent on a
-- machine in the plan, an Add New proposal with a [reintro] comment once pickable stock in the machine's own
-- warehouses (primary, secondary) reaches min_wh_stock, with up to three lanes that fit the product
-- (slot_profile_pool has a fill for that shelf size; preferred_lane_size first, WEIMI-empty lanes first, then
-- the slowest lanes; lanes already holding the product are skipped, and units of it elsewhere on the machine
-- are reported). It writes nothing: the lane choice is made at Gate 1. engine_add_pod returns the same
-- list under 'reintro_proposals' so the engine run shows them too.
-- Seeds: docs/prds/PRD-143-hero-reintroduction.md section C (28 rows). min_wh_stock per section B (one tray: 24 cans
-- and bottles, 12 bars and snacks, 8 premium snacks). preferred_lane_size is the slot_profile_pool size with the highest
-- fill for the product (ties go to Medium). Krambals and Popit: every flavour delivered to that machine. Item 7 machines
-- come from the section E hero scan (hero on the machine, no stock there now). Not seeded: Red Bull 355ML at AMZ-1029
-- (standing rule) and Vitamin Well (item 7 places it on Gatorade lanes, a lane rule this table cannot hold; held for CS).
ALTER TABLE public.sku_intents DROP CONSTRAINT sku_intents_intent_check;
ALTER TABLE public.sku_intents ADD CONSTRAINT sku_intents_intent_check
  CHECK (intent = ANY (ARRAY['deplete'::text, 'temp_out'::text, 'keep'::text, 'push'::text, 'reintro_when_stocked'::text]));
ALTER TABLE public.sku_intents ADD COLUMN IF NOT EXISTS min_wh_stock integer;
ALTER TABLE public.sku_intents ADD COLUMN IF NOT EXISTS preferred_lane_size text;
ALTER TABLE public.sku_intents ADD CONSTRAINT sku_intents_reintro_shape_check
  CHECK (intent <> 'reintro_when_stocked'
         OR (machine_id IS NOT NULL AND boonz_product_id IS NOT NULL AND min_wh_stock IS NOT NULL AND min_wh_stock > 0));
ALTER TABLE public.sku_intents ADD CONSTRAINT sku_intents_preferred_lane_size_check
  CHECK (preferred_lane_size IS NULL OR preferred_lane_size = ANY (ARRAY['Small'::text, 'Medium'::text, 'Large'::text]));

DO $seed$
DECLARE n int;
BEGIN
  INSERT INTO public.sku_intents (machine_id, boonz_product_id, intent, min_wh_stock, preferred_lane_size, note)
  SELECT m.machine_id, bp.product_id, 'reintro_when_stocked', s.min_wh,
         (SELECT p.shelf_size FROM public.slot_profile_pool p WHERE p.boonz_product_id = bp.product_id
           ORDER BY p.fill_qty DESC, (p.shelf_size = 'Medium') DESC, (p.shelf_size = 'Large') DESC LIMIT 1),
         'PRD-143 ' || s.note
    FROM (VALUES
      ('AMZ-1057-2403-O1', 'Red Bull - Regular', 24, 'C1: pulled 8 Oct A14 (WH empty, Huel in)'),
      ('AMZ-1057-2403-O1', 'Red Bull - Diet', 24, 'C1: pulled 8 Oct A14 (WH empty, Huel in)'),
      ('ADDMIND-1007-0000-W0', 'Krambals - Creamy Cheese', 8, 'C2: off shelf'),
      ('ADDMIND-1007-0000-W0', 'Krambals - Forest Mushroom & Butter', 8, 'C2: off shelf'),
      ('ADDMIND-1007-0000-W0', 'Krambals - Green Olives & Sea Salt', 8, 'C2: off shelf'),
      ('ADDMIND-1007-0000-W0', 'Krambals - Tomato & Mozzarella', 8, 'C2: off shelf'),
      ('VML-1004-0500-O1', 'Popit - Lemon & Lime', 12, 'C3: off shelf'),
      ('VML-1004-0500-O1', 'Popit - Orange Squeeze', 12, 'C3: off shelf'),
      ('VML-1004-0500-O1', 'Popit - Original Cola', 12, 'C3: off shelf'),
      ('VML-1003-0400-O1', 'Popit - Lemon & Lime', 12, 'C3: off shelf'),
      ('VML-1003-0400-O1', 'Popit - Orange Squeeze', 12, 'C3: off shelf'),
      ('VML-1003-0400-O1', 'Popit - Original Cola', 12, 'C3: off shelf'),
      ('ACTIVATEMCC-2005-0000-W0', 'Pocari Sweat - Regular', 24, 'C4: off shelf'),
      ('AMZ-1029-3003-O1', 'Smart Gourmet - Classic Hummus and Pretzels', 8, 'C5: off shelf, Classic only'),
      ('NISSAN-0804-0000-L0', 'Smart Gourmet - Classic Hummus and Pretzels', 8, 'C5: off shelf, Classic only'),
      ('NOVO-1023-0000-W0', 'Smart Gourmet - Classic Hummus and Pretzels', 8, 'C5: off shelf, Classic only'),
      ('AMZ-1038-3001-O1', 'Dubai Popcorn - Butter', 12, 'C6: waits for the next popcorn PO'),
      ('AMZ-1038-3001-O1', 'Dubai Popcorn - Salted', 12, 'C6: waits for the next popcorn PO'),
      ('ADDMIND-1007-0000-W0', 'Activia Mix & Go - Greek Yogurt Strawberries', 12, 'C7: hero scan, waits for supplier stock'),
      ('AMZ-1057-2403-O1', 'Activia Mix & Go - Greek Yogurt Strawberries', 12, 'C7: hero scan, waits for supplier stock'),
      ('AMZ-1068-2401-O1', 'Activia Mix & Go - Greek Yogurt Strawberries', 12, 'C7: hero scan, waits for supplier stock'),
      ('NOVO-1023-0000-W0', 'Activia Mix & Go - Greek Yogurt Strawberries', 12, 'C7: hero scan, waits for supplier stock'),
      ('WPP-1002-4300-O1', 'Activia Mix & Go - Greek Yogurt Strawberries', 12, 'C7: hero scan, waits for supplier stock'),
      ('ALJLT-1015-0200-O1', 'YoPRO - Protein Milk Chocolate', 24, 'C7: hero scan, waits for supplier stock'),
      ('AMZ-1068-2401-O1', 'YoPRO - Protein Milk Chocolate', 24, 'C7: hero scan, waits for supplier stock'),
      ('MC-2004-0100-O1', 'YoPRO - Protein Milk Chocolate', 24, 'C7: hero scan, waits for supplier stock'),
      ('NOVO-1023-0000-W0', 'YoPRO - Protein Milk Chocolate', 24, 'C7: hero scan, waits for supplier stock'),
      ('ACTIVATEMCC-1037-0000-L0', 'Evian - 330ML', 24, 'C7: hero scan, waits for supplier stock')
    ) AS s(machine_name, product_name, min_wh, note)
    JOIN public.machines m ON m.official_name = s.machine_name
    JOIN public.boonz_products bp ON bp.boonz_product_name = s.product_name
   WHERE NOT EXISTS (SELECT 1 FROM public.sku_intents i WHERE i.machine_id = m.machine_id
                       AND i.boonz_product_id = bp.product_id AND i.intent = 'reintro_when_stocked');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 28 THEN RAISE EXCEPTION 'prd144_p2_1: expected 28 PRD-143 seeds, inserted %', n; END IF;
END
$seed$;

CREATE OR REPLACE FUNCTION public.get_reintro_proposals(p_plan_date date, p_machine_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_out  jsonb;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
    IF v_role IS NULL OR v_role NOT IN ('operator_admin', 'superadmin', 'manager') THEN
      RAISE EXCEPTION 'get_reintro_proposals: forbidden for role %', COALESCE(v_role, 'none');
    END IF;
  END IF;

  WITH intents AS (
    SELECT i.id, i.machine_id, i.boonz_product_id, i.min_wh_stock, i.preferred_lane_size, i.note
      FROM public.sku_intents i
     WHERE i.intent = 'reintro_when_stocked'
       AND (p_machine_ids IS NULL AND EXISTS (SELECT 1 FROM public.machines_to_visit mtv
                                               WHERE mtv.machine_id = i.machine_id AND mtv.plan_date = p_plan_date
                                                 AND mtv.status IN ('picked', 'cs_added'))
            OR i.machine_id = ANY (p_machine_ids))
  ),
  stocked AS (
    SELECT it.*, COALESCE((SELECT SUM(vp.warehouse_stock) FROM public.v_wh_pickable vp
                            JOIN public.machines mw ON mw.machine_id = it.machine_id
                            WHERE vp.boonz_product_id = it.boonz_product_id
                              AND vp.warehouse_id IN (mw.primary_warehouse_id, mw.secondary_warehouse_id)
                              AND (vp.reserved_for_machine_id IS NULL OR vp.reserved_for_machine_id = it.machine_id)), 0) AS wh_stock,
           COALESCE((SELECT SUM(pi.current_stock) FROM public.pod_inventory pi
                      WHERE pi.machine_id = it.machine_id AND pi.boonz_product_id = it.boonz_product_id
                        AND pi.status = 'Active'), 0) AS on_machine
      FROM intents it
  ),
  ready AS (
    SELECT s.* FROM stocked s
     WHERE s.wh_stock >= s.min_wh_stock
  ),
  lanes AS (
    SELECT r.id AS intent_id, sc.shelf_code, sc.shelf_size, spp.fill_qty,
           w.product_name AS weimi_product, COALESCE(w.current_stock, 0) AS weimi_stock,
           sl.velocity_30d,
           row_number() OVER (PARTITION BY r.id
             ORDER BY (sc.shelf_size = r.preferred_lane_size) DESC NULLS LAST,
                      (COALESCE(w.current_stock, 0) = 0) DESC,
                      COALESCE(sl.velocity_30d, 0) ASC, sc.shelf_code) AS rk
      FROM ready r
      JOIN public.shelf_configurations sc ON sc.machine_id = r.machine_id AND NOT sc.is_phantom
       AND NOT EXISTS (SELECT 1 FROM public.pod_inventory pi WHERE pi.shelf_id = sc.shelf_id
                        AND pi.boonz_product_id = r.boonz_product_id AND pi.status = 'Active' AND COALESCE(pi.current_stock, 0) > 0)
      JOIN LATERAL (SELECT MAX(p.fill_qty) AS fill_qty FROM public.slot_profile_pool p
                     WHERE p.boonz_product_id = r.boonz_product_id AND p.shelf_size = sc.shelf_size) spp ON spp.fill_qty IS NOT NULL
      JOIN LATERAL public.weimi_lane_now(sc.machine_id, sc.shelf_code) w ON true  -- only lanes WEIMI knows
      LEFT JOIN public.slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.is_current AND NOT sl.archived
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'intent_id', r.id, 'machine_id', r.machine_id, 'machine_name', m.official_name,
           'boonz_product_id', r.boonz_product_id, 'boonz_product_name', bp.boonz_product_name,
           'action', 'Add New', 'comment', format('[reintro] %s', COALESCE(r.note, '')),
           'wh_stock', r.wh_stock, 'min_wh_stock', r.min_wh_stock, 'already_on_machine_units', r.on_machine,
           'lane_choices', (SELECT COALESCE(jsonb_agg(jsonb_build_object('shelf_code', l.shelf_code, 'shelf_size', l.shelf_size,
                                      'fill_qty', l.fill_qty, 'weimi_product', l.weimi_product, 'weimi_stock', l.weimi_stock,
                                      'velocity_30d', l.velocity_30d) ORDER BY l.rk), '[]'::jsonb)
                              FROM lanes l WHERE l.intent_id = r.id AND l.rk <= 3))
         ORDER BY m.official_name), '[]'::jsonb)
    INTO v_out
    FROM ready r
    JOIN public.machines m ON m.machine_id = r.machine_id
    JOIN public.boonz_products bp ON bp.product_id = r.boonz_product_id;
  RETURN v_out;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_reintro_proposals(date, uuid[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_reintro_proposals(date, uuid[]) TO authenticated, service_role;

DO $patch$
DECLARE v_def text; n int; a_old text := '    ''sizing_mode'', v_mode,' || chr(10);
BEGIN
  v_def := pg_get_functiondef('public.engine_add_pod(date,integer)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd144_p2_1: engine_add_pod anchor count %', n; END IF;
  EXECUTE replace(v_def, a_old, a_old || '    ''reintro_proposals'', public.get_reintro_proposals(p_plan_date, NULL::uuid[]),  -- PRD-144 P2-1' || chr(10));
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.engine_add_pod(date, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.engine_add_pod(date, integer) TO authenticated, service_role;
