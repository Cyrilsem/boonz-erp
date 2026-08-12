-- PRD-114 §3.1 - the read RPC behind the driver's "Sanity checks" category.
--
-- The refill plan says what to PUT IN. Nothing said what to CHECK. This returns
-- the machine's expiry candidates so the field PWA can render them as one more
-- category at the end of the dispatch line list.
--
-- LAW: pod_inventory is the expiry ledger and the ONLY expiry truth. This reads
-- it directly rather than through the /refill slot-drawer join - that join is a
-- known disconnect (PRD-105) and is deliberately NOT fixed here (§4.5).
--
-- READ ONLY. STABLE. No write path exists in this function.

CREATE OR REPLACE FUNCTION public.get_expiry_sanity_checks(p_machine_id uuid)
RETURNS TABLE (
  pod_inventory_id uuid,
  machine_id       uuid,
  shelf_id         uuid,
  shelf_code       text,
  boonz_product_id uuid,
  product_name     text,
  qty              numeric,
  expiration_date  date,
  days_to_expiry   integer,
  severity         text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller uuid := (SELECT auth.uid());
  v_role   text;
  v_today  date := (now() AT TIME ZONE 'Asia/Dubai')::date;
BEGIN
  IF p_machine_id IS NULL THEN
    RAISE EXCEPTION 'get_expiry_sanity_checks: p_machine_id required';
  END IF;

  -- Anonymous is refused BY NAME as its own statement. Folding it into the role
  -- test short-circuits to false for anon and skips the gate (D-41 / D-42 class).
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_expiry_sanity_checks: anonymous caller refused';
  END IF;
  SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_caller;
  IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'get_expiry_sanity_checks: role % not authorized', COALESCE(v_role,'none');
  END IF;

  RETURN QUERY
  SELECT
    pi.pod_inventory_id,
    pi.machine_id,
    pi.shelf_id,
    sc.shelf_code,
    pi.boonz_product_id,
    COALESCE(bp.boonz_product_name, '(unknown product)')            AS product_name,
    pi.current_stock                                                AS qty,
    pi.expiration_date,
    (pi.expiration_date - v_today)::int                             AS days_to_expiry,
    CASE WHEN pi.expiration_date < v_today THEN 'expired' ELSE 'expiring' END AS severity
  FROM public.pod_inventory pi
  LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = pi.shelf_id
  LEFT JOIN public.boonz_products      bp ON bp.product_id = pi.boonz_product_id
  WHERE pi.machine_id = p_machine_id
    AND pi.status     = 'Active'
    AND COALESCE(pi.current_stock, 0) > 0
    AND pi.expiration_date IS NOT NULL
    AND pi.expiration_date <= v_today + 7
  -- expired first, then soonest; ties broken on shelf so the driver walks the
  -- machine in one direction instead of hopping between aisles.
  ORDER BY (pi.expiration_date < v_today) DESC, pi.expiration_date ASC,
           sc.shelf_code ASC NULLS LAST
  LIMIT 10000;
END
$function$;

COMMENT ON FUNCTION public.get_expiry_sanity_checks(uuid) IS
  'PRD-114 §3.1. Read-only expiry candidates for one machine: Active pod_inventory batches with stock whose expiration_date is <= today(Dubai)+7. severity = expired (date < today) | expiring. Reads pod_inventory directly - it is the expiry ledger, and the slot-drawer join is a known disconnect.';

-- A new function is born EXECUTE-to-PUBLIC (PRD-113 finding). Strip it, then
-- grant only the two roles that can actually reach a machine or a screen.
REVOKE ALL ON FUNCTION public.get_expiry_sanity_checks(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_expiry_sanity_checks(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_expiry_sanity_checks(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_expiry_sanity_checks(uuid) TO service_role;
