-- PRD-110 P3.2 · resolve_m2m_sku_legs_v3 — SKU-level M2M leg resolution.
--
-- BUILD-SPEC line 90: "M2M SKU-level (fixture 4): transfers match on boonz_product_id;
-- mixed-SKU source shelves split legs per SKU."
--
-- WHAT THIS FIXES (root cause read from the live function body, leg 57):
--   convert_removes_to_m2m_transfer copies the SOURCE row's pod_product_id and
--   boonz_product_id verbatim onto the destination shelf with no assortment check. A
--   'Krambals & Zigi' source therefore contaminates a 'Zigi' destination with Krambals SKUs.
--   All 36 live is_m2m rows already carry a boonz_product_id, so the storage grain was never
--   the defect -- the PAIRING PREDICATE was.
--
-- ⛔ LAW 3: this does NOT edit convert_removes_to_m2m_transfer or pair_internal_transfer_m2m.
--   Both are live writers and both are md5-pinned by fixture 41 seq 44/45. This is a new,
--   standalone, versioned resolver in the P3.1a / P3.1b mould (S-62: stitch_v3 does not
--   exist, so P3 selectors ship standalone until it does).
--
-- ⛔ READ-ONLY BY CONSTRUCTION: STABLE + SECURITY INVOKER. Postgres itself refuses to let a
--   STABLE function write, so LAW 4 (shadow, don't switch) and LAW 12 (never touch live plan
--   tables) hold without needing to be trusted. SECURITY INVOKER follows P3.1a/P3.1b
--   precedent: RLS applies as the caller, so this cannot widen read access to anything.
--
-- DATA-SOURCE LAW (rule 6) compliance, stated explicitly because this function touches
-- product_mapping -- the table the standing DO-NOT list warns about:
--   ⭐ product_mapping is read here ONLY as the pod -> SKU ASSORTMENT MAP ("may this SKU sit
--     in this pod?"). It is NEVER used to size warehouse stock. The prohibited pattern is
--     summing stock across mapping joins, which fans out; this function sums no stock at all.
--   ⭐ Every mapping read is DISTINCT-ed before use. Live measurement on the anchor pod:
--     253 raw rows -> 21 Active rows -> 7 distinct SKUs. Without DISTINCT a SKU carrying both
--     a global and a machine-scoped row would be classified twice.
--   ⭐ Shelf state comes from v_shelf_state (P1.2 canonical) joined by shelf_id ONLY.
--
-- LAW 5 (silent qty-0 is a build failure): every input unit lands on exactly one leg, and a
-- self-assert RAISEs if input <> transfer + return. Units that cannot cross take a
-- return_to_wh leg with a NAMED reason; they are never dropped.
--
-- Destination capacity: an eligible unit that does not fit is NOT silently transferred into
-- an overfull shelf. It spills to return_to_wh with reason 'dest_capacity_clamp', reported
-- separately from 'not_assortable_at_destination' so the two are never conflated.
-- ⚠️ This clamp is one step beyond the literal words of BUILD-SPEC line 90, taken under
-- GOLDEN-FIXTURES #4's "qty-balanced pairing" clause and logged in the parking lot for CS
-- visibility rather than assumed.

CREATE OR REPLACE FUNCTION public.resolve_m2m_sku_legs_v3(
  p_source_shelf_id uuid,
  p_dest_shelf_id   uuid,
  p_lines           jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $fn$
DECLARE
  v_src            record;
  v_dst            record;
  v_src_name       text;
  v_dst_name       text;
  v_headroom       int;
  v_input          jsonb;
  v_input_source   text;
  v_legs           jsonb;
  v_input_units    int;
  v_transfer_units int;
  v_return_units   int;
  v_clamped_units  int;
  v_dest_scoped    int;
  v_dest_any       int;
  v_src_any        int;
  v_intersection   int;
  v_pm_rows_raw    int;
BEGIN
  ----------------------------------------------------------------------------
  -- 1. Resolve both shelves from the canonical view. shelf_id join ONLY.
  ----------------------------------------------------------------------------
  SELECT s.shelf_id, s.shelf_code, s.machine_id, s.pod_product_id, s.pod_name,
         s.current_stock, s.max_stock
    INTO v_src
    FROM public.v_shelf_state s
   WHERE s.shelf_id = p_source_shelf_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','source_shelf_not_found',
                              'source_shelf_id', p_source_shelf_id);
  END IF;

  SELECT s.shelf_id, s.shelf_code, s.machine_id, s.pod_product_id, s.pod_name,
         s.current_stock, s.max_stock
    INTO v_dst
    FROM public.v_shelf_state s
   WHERE s.shelf_id = p_dest_shelf_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','dest_shelf_not_found',
                              'dest_shelf_id', p_dest_shelf_id);
  END IF;

  -- M2M means machine TO machine. Same-machine is a shelf move, a different verb.
  IF v_src.machine_id = v_dst.machine_id THEN
    RETURN jsonb_build_object(
      'status','same_machine_not_m2m',
      'machine_id', v_src.machine_id,
      'note','source and destination are the same machine; this is a shelf move, not an M2M transfer');
  END IF;

  SELECT official_name INTO v_src_name FROM public.machines WHERE machine_id = v_src.machine_id;
  SELECT official_name INTO v_dst_name FROM public.machines WHERE machine_id = v_dst.machine_id;

  v_headroom := GREATEST(COALESCE(v_dst.max_stock,0) - COALESCE(v_dst.current_stock,0), 0);

  ----------------------------------------------------------------------------
  -- 2. Input lines. Caller-supplied (the real call site hands over the source
  --    Remove dispatch rows, which already carry boonz_product_id) or, failing
  --    that, the estimator. If neither can name the SKUs we say so loudly --
  --    we do NOT invent a split across the pod.
  ----------------------------------------------------------------------------
  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    v_input        := p_lines;
    v_input_source := 'caller_lines';
  ELSE
    SELECT jsonb_agg(jsonb_build_object('boonz_product_id', sc.boonz_product_id,
                                        'qty', round(sc.est_qty)::int))
      INTO v_input
      FROM public.shelf_composition sc
     WHERE sc.shelf_id = p_source_shelf_id
       AND round(sc.est_qty)::int > 0;
    v_input_source := 'shelf_composition';

    IF v_input IS NULL THEN
      RETURN jsonb_build_object(
        'status','source_composition_unknown',
        'source', jsonb_build_object('shelf_id', v_src.shelf_id, 'shelf_code', v_src.shelf_code,
                                     'pod_name', v_src.pod_name,
                                     'pod_level_stock', v_src.current_stock),
        'note','no caller lines and shelf_composition does not cover this shelf; the SKU mix is genuinely unknown, so no split is emitted rather than a guessed one',
        'remedy','pass p_lines from the source Remove dispatch rows, which carry boonz_product_id');
    END IF;
  END IF;

  ----------------------------------------------------------------------------
  -- 3. Assortment sets. product_mapping as a MAP only, DISTINCT before use.
  ----------------------------------------------------------------------------
  SELECT count(*) INTO v_dest_scoped FROM (
    SELECT DISTINCT pm.boonz_product_id FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_dst.pod_product_id AND pm.status = 'Active'
       AND (pm.machine_id = v_dst.machine_id OR pm.machine_id IS NULL)) t;

  SELECT count(*) INTO v_dest_any FROM (
    SELECT DISTINCT pm.boonz_product_id FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_dst.pod_product_id AND pm.status = 'Active') t;

  SELECT count(*) INTO v_src_any FROM (
    SELECT DISTINCT pm.boonz_product_id FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_src.pod_product_id AND pm.status = 'Active') t;

  SELECT count(*) INTO v_intersection FROM (
    SELECT DISTINCT pm.boonz_product_id FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_src.pod_product_id AND pm.status = 'Active'
    INTERSECT
    SELECT DISTINCT pm.boonz_product_id FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_dst.pod_product_id AND pm.status = 'Active') t;

  SELECT count(*) INTO v_pm_rows_raw FROM public.product_mapping pm
   WHERE pm.pod_product_id IN (v_src.pod_product_id, v_dst.pod_product_id);

  ----------------------------------------------------------------------------
  -- 4. Classify every input SKU, then greedily allocate the eligible ones into
  --    whatever headroom exists. Ordering is deterministic (qty DESC, then SKU)
  --    so the same input always produces the same split.
  ----------------------------------------------------------------------------
  WITH input AS (
    SELECT (e->>'boonz_product_id')::uuid AS sku,
           COALESCE((e->>'qty')::int, 0)  AS qty
      FROM jsonb_array_elements(v_input) e
     WHERE COALESCE((e->>'qty')::int, 0) > 0
  ),
  elig AS (
    SELECT DISTINCT pm.boonz_product_id AS sku
      FROM public.product_mapping pm
     WHERE pm.pod_product_id = v_dst.pod_product_id
       AND pm.status = 'Active'
       AND (pm.machine_id = v_dst.machine_id OR pm.machine_id IS NULL)
  ),
  classified AS (
    SELECT i.sku, i.qty, (e.sku IS NOT NULL) AS eligible
      FROM input i LEFT JOIN elig e ON e.sku = i.sku
  ),
  ranked AS (
    SELECT c.sku, c.qty,
           SUM(c.qty) OVER (ORDER BY c.qty DESC, c.sku
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum
      FROM classified c
     WHERE c.eligible
  ),
  alloc AS (
    -- headroom left before this row = v_headroom - (cum - qty)
    SELECT r.sku, r.qty,
           GREATEST(0, LEAST(r.qty, v_headroom - (r.cum - r.qty)))::int AS xfer
      FROM ranked r
  ),
  legs AS (
    -- (a) the units that actually cross
    SELECT a.sku, a.xfer AS qty, 'transfer'::text AS leg,
           'assortable_at_destination'::text AS reason
      FROM alloc a WHERE a.xfer > 0
    UNION ALL
    -- (b) eligible units that did not fit -- named as a clamp, never as non-assortable
    SELECT a.sku, (a.qty - a.xfer) AS qty, 'return_to_wh'::text,
           'dest_capacity_clamp'::text
      FROM alloc a WHERE (a.qty - a.xfer) > 0
    UNION ALL
    -- (c) units that may not sit in the destination pod at all -- the incident class
    SELECT c.sku, c.qty, 'return_to_wh'::text,
           'not_assortable_at_destination'::text
      FROM classified c WHERE NOT c.eligible
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'boonz_product_id',   l.sku,
             'boonz_product_name', bp.boonz_product_name,
             'qty',                l.qty,
             'leg',                l.leg,
             'reason',             l.reason)
           ORDER BY l.leg, bp.boonz_product_name), '[]'::jsonb),
         COALESCE(SUM(l.qty) FILTER (WHERE l.leg = 'transfer'), 0),
         COALESCE(SUM(l.qty) FILTER (WHERE l.leg = 'return_to_wh'), 0),
         COALESCE(SUM(l.qty) FILTER (WHERE l.reason = 'dest_capacity_clamp'), 0)
    INTO v_legs, v_transfer_units, v_return_units, v_clamped_units
    FROM legs l
    LEFT JOIN public.boonz_products bp ON bp.product_id = l.sku;

  SELECT COALESCE(SUM(COALESCE((e->>'qty')::int,0)), 0) INTO v_input_units
    FROM jsonb_array_elements(v_input) e
   WHERE COALESCE((e->>'qty')::int,0) > 0;

  ----------------------------------------------------------------------------
  -- 5. LAW 5 self-assert. If a unit ever went missing between input and legs,
  --    fail loudly here rather than shipping a quietly short transfer.
  ----------------------------------------------------------------------------
  IF v_input_units <> v_transfer_units + v_return_units THEN
    RAISE EXCEPTION
      'resolve_m2m_sku_legs_v3 conservation violated: input % <> transfer % + return % (src % dst %)',
      v_input_units, v_transfer_units, v_return_units, p_source_shelf_id, p_dest_shelf_id;
  END IF;

  RETURN jsonb_build_object(
    'status','ok',
    'source', jsonb_build_object(
        'shelf_id', v_src.shelf_id, 'shelf_code', v_src.shelf_code,
        'machine_id', v_src.machine_id, 'machine_name', v_src_name,
        'pod_product_id', v_src.pod_product_id, 'pod_name', v_src.pod_name),
    'dest', jsonb_build_object(
        'shelf_id', v_dst.shelf_id, 'shelf_code', v_dst.shelf_code,
        'machine_id', v_dst.machine_id, 'machine_name', v_dst_name,
        'pod_product_id', v_dst.pod_product_id, 'pod_name', v_dst.pod_name,
        'current_stock', v_dst.current_stock, 'max_stock', v_dst.max_stock,
        'headroom', v_headroom),
    'eligibility', jsonb_build_object(
        'dest_skus_scoped',      v_dest_scoped,
        'dest_skus_any_scope',   v_dest_any,
        'source_skus_any_scope', v_src_any,
        'intersection',          v_intersection,
        'scope_divergence',      (v_dest_scoped <> v_dest_any),
        'mapping_rows_scanned',  v_pm_rows_raw,
        'match_key',             'boonz_product_id',
        'scope_rule',            'destination pod, status=Active, machine-scoped OR global'),
    'input_source', v_input_source,
    'legs', v_legs,
    'totals', jsonb_build_object(
        'input_units',    v_input_units,
        'transfer_units', v_transfer_units,
        'return_units',   v_return_units,
        'clamped_units',  v_clamped_units,
        'conserved',      (v_input_units = v_transfer_units + v_return_units)),
    'notes', jsonb_build_array(
        'product_mapping is read as a pod-to-SKU assortment map only, never to size stock (LAW 6)',
        'every mapping read is DISTINCT-ed before use; this pod pair spans ' || v_pm_rows_raw || ' raw mapping rows',
        'units that cannot cross take a return_to_wh leg with a named reason; nothing is dropped (LAW 5)',
        'read-only: STABLE + SECURITY INVOKER, so this emits no dispatch rows -- the caller writes the legs'));
END;
$fn$;

COMMENT ON FUNCTION public.resolve_m2m_sku_legs_v3(uuid,uuid,jsonb) IS
'PRD-110 P3.2. Resolves a machine-to-machine transfer into SKU-level legs: eligible SKUs (present in the DESTINATION pod''s Active assortment) transfer, everything else takes a return_to_wh leg with a named reason, and destination headroom clamps rather than overflows. Read-only advisory (STABLE, SECURITY INVOKER); the caller emits the dispatch rows. Proven by golden fixture 41. Fixes the K&Z -> Zigi class of contamination where convert_removes_to_m2m_transfer copies the source SKU verbatim onto the destination shelf.';

-- Tight grants, matching P3.1a / P3.1b (no anon, no public).
REVOKE ALL ON FUNCTION public.resolve_m2m_sku_legs_v3(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_m2m_sku_legs_v3(uuid,uuid,jsonb) TO authenticated, service_role;
