-- PRD-116c: edit_pod_refill_row clamped ADD_NEW edits to v_shelf_capacity, whose max_stock
-- describes the OUTGOING product's facing. On a swap the shelf is being emptied and restocked
-- with a different-sized product, so the honest cap is the INCOMING pod product's own typical
-- facing (max WEIMI max_stock observed for it fleet-wide, last 30d), falling back to the lane
-- max when the product is new to the fleet. Live case: NOVO A16 Krambals 10 refused at 6
-- (popcorn-tub cap). REFILL clamps unchanged (same product, lane max valid). Cody OK 1,4,8,12.
-- Applied to prod via MCP 2026-08-23 21:57 UTC. md5 guard d71eb77a2b8c6a2c69a7a01babe9f9ff.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='edit_pod_refill_row' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'd71eb77a2b8c6a2c69a7a01babe9f9ff' THEN
    RAISE EXCEPTION 'edit_pod_refill_row drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;
  v_new := replace(v_def,
$$  IF p_action IN ('REFILL','ADD_NEW') THEN
    SELECT max_stock, current_stock, headroom
      INTO v_cap_max, v_cur, v_headroom
    FROM public.v_shelf_capacity WHERE shelf_id = p_shelf_id;
    IF v_cap_max IS NOT NULL AND p_new_qty > COALESCE(v_headroom, 0) THEN$$,
$$  IF p_action IN ('REFILL','ADD_NEW') THEN
    SELECT max_stock, current_stock, headroom
      INTO v_cap_max, v_cur, v_headroom
    FROM public.v_shelf_capacity WHERE shelf_id = p_shelf_id;
    -- PRD-116c: on ADD_NEW the lane max belongs to the product LEAVING the shelf.
    -- Cap at the incoming product's own fleet facing instead (fallback: lane max).
    IF p_action = 'ADD_NEW' THEN
      SELECT GREATEST(COALESCE(v_headroom, 0), COALESCE(MAX(s.max_stock), 0))
        INTO v_headroom
      FROM public.weimi_aisle_snapshots s
      JOIN public.pod_products pp
        ON lower(trim(s.product_name)) = lower(trim(pp.pod_product_name))
      WHERE pp.pod_product_id = p_pod_product_id
        AND s.snapshot_date >= CURRENT_DATE - 30;
    END IF;
    IF v_cap_max IS NOT NULL AND p_new_qty > COALESCE(v_headroom, 0) THEN$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'clamp block not found'; END IF;
  EXECUTE v_new;
END $mig$;
