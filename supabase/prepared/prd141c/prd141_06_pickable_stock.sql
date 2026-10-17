-- PRD-141 item 6 (B1, B2): one pickable-stock definition.
-- pickable_stock(boonz_product_id, warehouse_id, needed_by) = Active, not quarantined, not manually
-- quarantined, in the warehouse (WH_CENTRAL when NULL), expiring on or after
-- needed_by + refill_policy_params.min_shelf_life_days (new, default 14). Returns the number, the on-hand
-- total, what was excluded and why, and a ready message: "12 pickable, 30 on hand: 18 quarantined/expiring
-- before 31 Oct".
-- Callers: the pack screen max (FE, via RPC), G8 in validate_refill_plan (same predicate on its avail CTE,
-- message in the detail) and the picker wh_fefo_for_line (shelf-life floor). Before this the three
-- disagreed: G8 ignored expiry and manual quarantine; the pack screen showed the pinned batch only.
-- Impact measured 2026-10-18: the 14-day floor holds back 3 lots / 12 units of 115 lots / 1,890 units
-- pickable in WH_CENTRAL.
-- Rollback: supabase/rollbacks/prd141_06_rollback.sql (fast path: min_shelf_life_days = 0).

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS min_shelf_life_days integer NOT NULL DEFAULT 14;

CREATE OR REPLACE FUNCTION public.pickable_stock(p_boonz_product_id uuid, p_warehouse_id uuid DEFAULT NULL, p_needed_by date DEFAULT NULL)
 RETURNS TABLE(pickable numeric, on_hand numeric, excluded_quarantined numeric, excluded_expiring numeric, cutoff_date date, message text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH p AS (
    SELECT COALESCE(p_warehouse_id, '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'::uuid) AS wh,
           COALESCE(p_needed_by, (now() AT TIME ZONE 'Asia/Dubai')::date)
             + COALESCE((SELECT min_shelf_life_days FROM public.refill_policy_params ORDER BY id LIMIT 1), 14) AS cutoff
  ), rows_ AS (
    SELECT wi.warehouse_stock AS qty,
           (COALESCE(wi.quarantined, false) OR COALESCE(wi.manually_quarantined, false)) AS is_q,
           (wi.expiration_date IS NOT NULL AND wi.expiration_date < p.cutoff) AS is_exp
      FROM public.warehouse_inventory wi CROSS JOIN p
     WHERE wi.boonz_product_id = p_boonz_product_id AND wi.warehouse_id = p.wh
       AND wi.status = 'Active' AND COALESCE(wi.warehouse_stock, 0) > 0
  ), agg AS (
    SELECT COALESCE(SUM(qty) FILTER (WHERE NOT is_q AND NOT is_exp), 0) AS pickable,
           COALESCE(SUM(qty), 0) AS on_hand,
           COALESCE(SUM(qty) FILTER (WHERE is_q), 0) AS q,
           COALESCE(SUM(qty) FILTER (WHERE is_exp AND NOT is_q), 0) AS e
      FROM rows_
  )
  SELECT a.pickable, a.on_hand, a.q, a.e, p.cutoff,
         format('%s pickable, %s on hand: %s quarantined, %s expiring before %s',
                a.pickable::int, a.on_hand::int, a.q::int, a.e::int, to_char(p.cutoff, 'DD Mon'))
    FROM agg a CROSS JOIN p;
$function$;
REVOKE EXECUTE ON FUNCTION public.pickable_stock(uuid, uuid, date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pickable_stock(uuid, uuid, date) TO authenticated, service_role;

DO $patch$
DECLARE
  v_def text; n int;
  g_old text := '               AND COALESCE(wi.quarantined,false) = false' || chr(10) || '               AND wi.warehouse_stock > 0';
  g_new text := '               AND COALESCE(wi.quarantined,false) = false' || chr(10)
             || '               AND NOT COALESCE(wi.manually_quarantined,false)' || chr(10)
             || '               AND (wi.expiration_date IS NULL OR wi.expiration_date >= p_plan_date + COALESCE((SELECT rpp.min_shelf_life_days FROM public.refill_policy_params rpp ORDER BY rpp.id LIMIT 1), 14))  -- PRD-141 item 6' || chr(10)
             || '               AND wi.warehouse_stock > 0';
  d_old text := 'bp.boonz_product_name||'': need ''||x.need||'', free ''||x.free';
  d_new text := 'bp.boonz_product_name||'': need ''||x.need||'', free ''||x.free||'' (WH_CENTRAL ''||(SELECT ps.message FROM public.pickable_stock(x.boonz_product_id, NULL, p_plan_date) ps)||'')''';
  f_old text := '      AND (vp.expiration_date IS NULL OR vp.expiration_date >= p_plan_date)';
  f_new text := '      AND (vp.expiration_date IS NULL OR vp.expiration_date >= p_plan_date + COALESCE((SELECT rpp.min_shelf_life_days FROM public.refill_policy_params rpp ORDER BY rpp.id LIMIT 1), 14))  -- PRD-141 item 6';
BEGIN
  v_def := pg_get_functiondef('public.validate_refill_plan(date,text[],text)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, g_old, ''))) / length(g_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_06: G8 avail anchor count %', n; END IF;
  n := (length(v_def) - length(replace(v_def, d_old, ''))) / length(d_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_06: G8 detail anchor count %', n; END IF;
  EXECUTE replace(replace(v_def, g_old, g_new), d_old, d_new);

  v_def := pg_get_functiondef('public.wh_fefo_for_line(uuid,uuid,date,numeric,uuid[])'::regprocedure);
  n := (length(v_def) - length(replace(v_def, f_old, ''))) / length(f_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_06: wh_fefo_for_line anchor count %', n; END IF;
  EXECUTE replace(v_def, f_old, f_new);
END
$patch$;
