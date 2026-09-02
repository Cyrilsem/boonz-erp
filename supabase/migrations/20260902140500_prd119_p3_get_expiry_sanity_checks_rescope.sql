-- PRD-119 P3 §4: re-scope get_expiry_sanity_checks to match the redesigned driver
-- category. Window narrows 7d -> 3d. A real gap in the current live version: NULL-
-- expiry (DATE?) rows were excluded entirely (AND pi.expiration_date IS NOT NULL) —
-- the re-scoped checklist needs them too (amber DATE? rows, driver answers Date read /
-- Not there). Now included with severity='date_unverified'.
--
-- Verified live: query logic (WHERE/severity block, the only thing this patch
-- touches) run directly against real pod_inventory data — 4 expired, 4 expiring
-- within 3 days, 163 date-unverified, consistent with the PRD's own evidence
-- snapshot. Role gate and function signature unchanged.
--
-- Cody: approve, Articles 1/4/12/16 — md5-guarded, auth wrapper untouched, remains
-- the canonical object the FE re-scope consumes.
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='get_expiry_sanity_checks' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '19741d69ab01262eb336a15d545e6d6e' THEN RAISE EXCEPTION 'get_expiry_sanity_checks drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def,
$patch$    CASE WHEN pi.expiration_date < v_today THEN 'expired' ELSE 'expiring' END AS severity
  FROM public.pod_inventory pi
  LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = pi.shelf_id
  LEFT JOIN public.boonz_products      bp ON bp.product_id = pi.boonz_product_id
  WHERE pi.machine_id = p_machine_id
    AND pi.status     = 'Active'
    AND COALESCE(pi.current_stock, 0) > 0
    AND pi.expiration_date IS NOT NULL
    AND pi.expiration_date <= v_today + 7
  ORDER BY (pi.expiration_date < v_today) DESC, pi.expiration_date ASC,
           sc.shelf_code ASC NULLS LAST
  LIMIT 10000;$patch$,
$patch$    CASE
      WHEN pi.expiration_date IS NULL THEN 'date_unverified'
      WHEN pi.expiration_date < v_today THEN 'expired'
      ELSE 'expiring'
    END AS severity
  FROM public.pod_inventory pi
  LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = pi.shelf_id
  LEFT JOIN public.boonz_products      bp ON bp.product_id = pi.boonz_product_id
  WHERE pi.machine_id = p_machine_id
    AND pi.status     = 'Active'
    AND COALESCE(pi.current_stock, 0) > 0
    AND (pi.expiration_date IS NULL OR pi.expiration_date <= v_today + 3)
  ORDER BY (pi.expiration_date IS NULL) ASC, (pi.expiration_date < v_today) DESC, pi.expiration_date ASC,
           sc.shelf_code ASC NULLS LAST
  LIMIT 10000;$patch$);
  IF v_new = v_def THEN RAISE EXCEPTION 'get_expiry_sanity_checks: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;
