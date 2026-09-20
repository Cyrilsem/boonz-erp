-- PRD-125 D2 / ONE-LOOP Phase 1 -- WEIMI is the shelf truth.
--
-- weimi_shelf_now(p_machine_id): one row per lane from the machine's latest
-- weimi_aisle_snapshots, zero-padded shelf_code (A1 -> A01), pod_product_id
-- resolved weimi_product_alias first then pod_products by name, max_stock
-- with the slot_capacity_max override applied (a real table --
-- machine_id/aisle_code/override_max_stock -- verified via pg_proc source
-- text search before assuming it existed). This is the new canonical read
-- for "what is on a shelf right now": v_live_shelf_stock, the internal-move
-- detection, and add_dispatch_row's Remove path all switch to it in this
-- same phase's remaining migrations.
--
-- Verified live against ACTIVATEMCC-1037-0000-L0: 8 lanes returned, stock
-- and capacity match the raw snapshot, product resolved on every lane.
CREATE OR REPLACE FUNCTION public.weimi_shelf_now(p_machine_id uuid)
 RETURNS TABLE(shelf_code text, pod_product_id uuid, current_stock integer, max_stock integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH latest AS (
    SELECT max(snapshot_date) AS d FROM public.weimi_aisle_snapshots WHERE machine_id = p_machine_id
  ),
  w AS (
    SELECT s.*,
           upper(left(s.slot_code,1)) || lpad(regexp_replace(s.slot_code,'^[A-Za-z]',''),2,'0') AS norm_shelf_code
    FROM public.weimi_aisle_snapshots s, latest l
    WHERE s.machine_id = p_machine_id AND s.snapshot_date = l.d
  )
  SELECT w.norm_shelf_code AS shelf_code,
         COALESCE(wpa.pod_product_id, pp.pod_product_id) AS pod_product_id,
         w.current_stock,
         COALESCE(scm.override_max_stock, w.max_stock) AS max_stock
    FROM w
    LEFT JOIN public.weimi_product_alias wpa ON wpa.weimi_name = w.product_name
    LEFT JOIN public.pod_products pp ON lower(trim(pp.pod_product_name)) = lower(trim(w.product_name))
    LEFT JOIN public.slot_capacity_max scm ON scm.machine_id = p_machine_id AND scm.aisle_code = w.norm_shelf_code;
$function$;
