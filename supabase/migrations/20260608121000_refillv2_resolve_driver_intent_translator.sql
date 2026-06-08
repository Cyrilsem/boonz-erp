-- ============================================================================
-- PRD-REFILL-V2 · Item 3 · resolve_driver_intent  (NEW, read-only translator)
-- ============================================================================
-- One resolver that turns ANY driver signal (driver_feedback row or
-- driver_recommendations row) into normalized {pod_product_id, boonz_product_id,
-- qty, shelf_code} rows. Anything it cannot resolve is RETURNED with
-- resolution = 'unresolved_driver_intent' (never silently dropped). Feeds:
--   - Item 1 engine_add_pod  (qty floor)
--   - Item 2 engine_swap_pod (product choice for needs_product / wrong_product)
--   - Item 6 stitch_pod_to_boonz (boonz SKU overlay)
--
-- DARA NOTE: no new table. Reads driver_feedback + driver_recommendations +
--   product_mapping (boonz->pod reverse, machine-specific then global default) +
--   pod_products + shelf_configurations. shelf_code is returned in the system
--   canonical 'A01'..'A16' form (what every downstream table joins on); the
--   operator/driver-facing label is the numeric suffix 01..16 (the WEIMI 0-based
--   index never appears here). p_machine_id NULL = all machines for the plan_date.
--
-- CODY: read-only -> SECURITY INVOKER (Article 4: DEFINER not justified, no writes).
--   No protected-entity mutation. Article 1/5/6/8 N/A (read path).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.resolve_driver_intent(
  p_plan_date date,
  p_machine_id uuid DEFAULT NULL
)
RETURNS TABLE (
  signal_source     text,    -- 'driver_feedback' | 'driver_recommendation'
  source_id         uuid,    -- feedback_id | rec_id
  machine_id        uuid,
  shelf_code        text,    -- canonical A01..A16 (NULL if unresolved)
  pod_product_id    uuid,    -- NULL if unresolved
  boonz_product_id  uuid,
  qty               integer, -- requested qty (NULL when the driver gave none)
  intent_kind       text,    -- 'refill_request' | 'needs_product' | 'wrong_product'
  resolved          boolean,
  resolution        text     -- 'resolved' | 'unresolved_driver_intent'
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
  WITH
  -- boonz -> pod reverse map, machine-specific mapping wins over global default
  pm_resolved AS (
    SELECT DISTINCT ON (pm.boonz_product_id, COALESCE(pm.machine_id, '00000000-0000-0000-0000-000000000000'::uuid))
      pm.boonz_product_id, pm.machine_id, pm.pod_product_id
    FROM public.product_mapping pm
    WHERE pm.status = 'Active'
    ORDER BY pm.boonz_product_id,
             COALESCE(pm.machine_id, '00000000-0000-0000-0000-000000000000'::uuid),
             (pm.machine_id IS NOT NULL) DESC, pm.updated_at DESC
  ),
  -- ---- driver_feedback ----
  -- feedback_type 'add_missing' is a NEW-product ask: shelf_code is legitimately
  -- NULL (the product is not on a shelf yet) -> resolution must NOT require a
  -- shelf. 'note' is free-text. Resolution = "boonz_product_id maps to a pod".
  fb AS (
    SELECT
      'driver_feedback'::text AS signal_source,
      df.feedback_id          AS source_id,
      df.machine_id,
      df.shelf_code,
      df.boonz_product_id,
      df.requested_qty,
      CASE df.feedback_type
        WHEN 'add_missing'            THEN 'needs_product'
        WHEN 'note'                   THEN 'note'
        WHEN 'refill'                 THEN 'refill_request'
        WHEN 'shortfall'              THEN 'refill_request'
        WHEN 'wrong_product'          THEN 'wrong_product'
        ELSE COALESCE(df.feedback_type, 'refill_request')
      END AS intent_kind
    FROM public.driver_feedback df
    WHERE df.plan_date = p_plan_date
      AND COALESCE(df.resolved, false) = false
      AND (p_machine_id IS NULL OR df.machine_id = p_machine_id)
  ),
  fb_out AS (
    SELECT
      fb.signal_source, fb.source_id, fb.machine_id,
      sc.shelf_code AS shelf_code,        -- NULL is valid for add_missing / new-product
      COALESCE(pmm.pod_product_id, pmg.pod_product_id) AS pod_product_id,
      fb.boonz_product_id,
      fb.requested_qty AS qty,
      fb.intent_kind,
      -- resolved iff the driver named a boonz SKU that maps to a pod product.
      -- shelf placement is the consuming engine's job (add/swap), not a blocker.
      (fb.boonz_product_id IS NOT NULL
       AND COALESCE(pmm.pod_product_id, pmg.pod_product_id) IS NOT NULL) AS resolved
    FROM fb
    LEFT JOIN public.shelf_configurations sc
      ON sc.machine_id = fb.machine_id
     AND fb.shelf_code IS NOT NULL
     AND UPPER(sc.shelf_code) = UPPER(fb.shelf_code)
    LEFT JOIN pm_resolved pmm
      ON pmm.boonz_product_id = fb.boonz_product_id AND pmm.machine_id = fb.machine_id
    LEFT JOIN pm_resolved pmg
      ON pmg.boonz_product_id = fb.boonz_product_id AND pmg.machine_id IS NULL
  ),
  -- ---- driver_recommendations (needs_product / wrong_product => swap intents) ----
  rc AS (
    SELECT
      'driver_recommendation'::text AS signal_source,
      dr.rec_id  AS source_id,
      dr.machine_id,
      dr.shelf_id,
      dr.boonz_product_id,
      dr.kind    AS intent_kind
    FROM public.driver_recommendations dr
    WHERE dr.kind IN ('needs_product','wrong_product')
      AND COALESCE(dr.status,'open') IN ('open','pending','new')
      AND (p_machine_id IS NULL OR dr.machine_id = p_machine_id)
  ),
  rc_out AS (
    SELECT
      rc.signal_source, rc.source_id, rc.machine_id,
      sc.shelf_code AS shelf_code,
      COALESCE(pmm.pod_product_id, pmg.pod_product_id) AS pod_product_id,
      rc.boonz_product_id,
      NULL::integer AS qty,          -- recommendations carry no explicit qty
      rc.intent_kind,
      (COALESCE(pmm.pod_product_id, pmg.pod_product_id) IS NOT NULL) AS resolved
    FROM rc
    LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = rc.shelf_id
    LEFT JOIN pm_resolved pmm
      ON pmm.boonz_product_id = rc.boonz_product_id AND pmm.machine_id = rc.machine_id
    LEFT JOIN pm_resolved pmg
      ON pmg.boonz_product_id = rc.boonz_product_id AND pmg.machine_id IS NULL
  ),
  unioned AS (
    SELECT * FROM fb_out
    UNION ALL
    SELECT * FROM rc_out
  )
  SELECT
    u.signal_source, u.source_id, u.machine_id, u.shelf_code,
    u.pod_product_id, u.boonz_product_id, u.qty, u.intent_kind,
    u.resolved,
    CASE WHEN u.resolved THEN 'resolved' ELSE 'unresolved_driver_intent' END AS resolution
  FROM unioned u
  ORDER BY u.machine_id, u.resolved DESC, u.shelf_code NULLS LAST;
$function$;

REVOKE ALL ON FUNCTION public.resolve_driver_intent(date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_driver_intent(date, uuid) TO authenticated, service_role;
