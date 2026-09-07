-- PRD-119 D3 (receipt capture, backend only) -- built on PRD-119 P5's own
-- design note (docs/prds/PRD-119-REPORT.md sec P5): "±25% shelf-life band
-- as a soft warning, not a hard block... boonz_products has no shelf-life
-- column today... check runs inside create_po_addition_v2 itself (or a thin
-- wrapper)... matching PRD-118 A's own per-line guard, which this would
-- extend rather than duplicate."
--
-- Investigation before writing anything: the actual warehouse-side goods
-- receipt writer is `receive_purchase_order(p_po_id, p_lines, p_additions)`
-- -- NOT create_po_addition_v2 (which only inserts a `po_additions` row, a
-- proposed line, not warehouse stock) and not the machine-side
-- `receive_dispatch_line`. `receive_purchase_order` is the one function
-- that INSERTs into `warehouse_inventory` for both originally-ordered PO
-- lines (`p_lines`, with nested `batches`) and mid-cycle additions
-- (`p_additions`).
--
-- PRD-118 A's hard "no NULL expiry" refusal is ALREADY live in this exact
-- function for both paths (RAISE EXCEPTION '...BUG-007/009' for batches,
-- '...Capture expiry before receiving' for additions) -- confirmed by
-- reading the live body, not assumed. `log_expiry_entry_suspect` (date-
-- plausibility / day-month-swap detection) is also already composed in
-- both paths. What was genuinely missing, per this task's exact ask:
--
-- 1. `boonz_products.typical_shelf_life_days integer` (nullable) -- Dara
--    note: nullable because most SKUs have no computed value yet (only the
--    top-40-by-volume backfill below populates it); plain integer (whole
--    days) rather than an interval or a separate lookup table because every
--    consumer of it (this migration's own deviation check) does simple date
--    arithmetic against it and a second lookup table would be a needless
--    join for a single per-product scalar with no independent lifecycle of
--    its own.
-- 2. New `check_receipt_shelf_life_deviation(p_writer, p_receipt_date,
--    p_entered_expiry, p_boonz_product_id, p_context)` -- composed
--    (following log_expiry_entry_suspect's own shape/pattern exactly:
--    same SECURITY DEFINER, same safe_monitoring_alert call, same "return
--    silently if inputs are NULL" guard) alongside the existing
--    log_expiry_entry_suspect call, in BOTH the batch loop and the addition
--    loop. WARNS via safe_monitoring_alert (source='expiry_shelf_life_
--    deviation') when |actual_days - typical| > 25% of typical; silently
--    no-ops when typical_shelf_life_days is NULL (most products, until
--    backfilled further) -- never blocks, per the goal's own instruction.
-- 3. New `check_receipt_duplicate_expiry_dates(p_po_id, p_lines,
--    p_additions)` -- scans the WHOLE receive call (its natural "one
--    receipt" unit) for an expiry_date shared by 2+ DIFFERENT boonz
--    products, WARNS once per call via safe_monitoring_alert
--    (source='receipt_duplicate_expiry_date') listing every offending
--    date+product-set. Called once, before either loop, so a genuinely
--    single-product multi-batch receipt (same product, same date) never
--    false-positives -- the check is scoped to DIFFERENT products sharing
--    one date, the actual fat-finger pattern this guards against.
--
-- All three new call sites are additive PERFORM statements wired next to
-- existing, unrelated log_expiry_entry_suspect calls; byte-identical
-- everywhere else in this ~150-line function (md5-guarded, byte-exact
-- replace(), 3 anchors, all matched on first try against the live body).
--
-- `check_wh_expiry_anomaly` (the existing INSERT trigger on
-- warehouse_inventory, fixed absolute day-thresholds: null/in_past/
-- too_soon<30d/too_far>730d) is untouched -- it is a different, generic,
-- product-agnostic sanity check that already fires on every insert
-- regardless of writer; this migration's new checks are product-specific
-- (shelf-life band) and batch-specific (duplicate dates), a different
-- concern, not a duplicate of it.
--
-- Cody: approve, Articles 1 (receive_purchase_order remains the sole
-- warehouse-receipt writer -- no second writer created), 4 (both new
-- functions are SECURITY DEFINER, warn-only, no privilege escalation --
-- role/via_rpc context is already set by the calling receive_purchase_order),
-- 12 (forward-only, byte-exact patch, nothing else in the function touched),
-- 16 (composes the existing alert mechanism, doesn't invent a parallel one).
ALTER TABLE public.boonz_products ADD COLUMN IF NOT EXISTS typical_shelf_life_days integer;

CREATE OR REPLACE FUNCTION public.check_receipt_shelf_life_deviation(
  p_writer text, p_receipt_date date, p_entered_expiry date,
  p_boonz_product_id uuid, p_context jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_typical int;
  v_actual_days numeric;
  v_deviation_pct numeric;
BEGIN
  IF p_entered_expiry IS NULL OR p_receipt_date IS NULL OR p_boonz_product_id IS NULL THEN RETURN; END IF;

  SELECT typical_shelf_life_days INTO v_typical FROM public.boonz_products WHERE product_id = p_boonz_product_id;
  IF v_typical IS NULL OR v_typical <= 0 THEN RETURN; END IF;

  v_actual_days := p_entered_expiry - p_receipt_date;
  v_deviation_pct := ABS(v_actual_days - v_typical) / v_typical::numeric;

  IF v_deviation_pct > 0.25 THEN
    PERFORM public.safe_monitoring_alert('expiry_shelf_life_deviation', 'warning',
      jsonb_build_object(
        'writer', p_writer, 'receipt_date', p_receipt_date, 'entered_expiry', p_entered_expiry,
        'boonz_product_id', p_boonz_product_id, 'typical_shelf_life_days', v_typical,
        'actual_days', v_actual_days, 'deviation_pct', ROUND(v_deviation_pct*100,1),
        'context', p_context));
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_receipt_duplicate_expiry_dates(
  p_po_id text, p_lines jsonb, p_additions jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dupes jsonb;
BEGIN
  WITH all_expiries AS (
    SELECT (b->>'expiry_date')::date AS expiry,
           (SELECT boonz_product_id FROM public.purchase_orders WHERE po_line_id = (l->>'po_line_id')::uuid) AS product_id
    FROM jsonb_array_elements(COALESCE(p_lines,'[]'::jsonb)) l,
         jsonb_array_elements(COALESCE(l->'batches','[]'::jsonb)) b
    WHERE COALESCE((b->>'received_qty')::numeric,0) > 0
      AND NULLIF(b->>'expiry_date','') IS NOT NULL
    UNION ALL
    SELECT COALESCE(NULLIF(a->>'expiry_date','')::date,
             (SELECT expiry_date FROM public.po_additions WHERE addition_id = (a->>'addition_id')::uuid)),
           (a->>'boonz_product_id')::uuid
    FROM jsonb_array_elements(COALESCE(p_additions,'[]'::jsonb)) a
  ),
  dupes AS (
    SELECT expiry, array_agg(DISTINCT product_id) AS product_ids, count(DISTINCT product_id) AS n_products
    FROM all_expiries
    WHERE expiry IS NOT NULL AND product_id IS NOT NULL
    GROUP BY expiry
    HAVING count(DISTINCT product_id) >= 2
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('expiry', expiry, 'boonz_product_ids', product_ids, 'n_products', n_products)), '[]'::jsonb)
    INTO v_dupes
  FROM dupes;

  IF jsonb_array_length(v_dupes) > 0 THEN
    PERFORM public.safe_monitoring_alert('receipt_duplicate_expiry_date', 'warning',
      jsonb_build_object('po_id', p_po_id, 'duplicates', v_dupes));
  END IF;
END;
$function$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='receive_purchase_order' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '8d393ae60215eb4ceafba9b96eb7f3c8' THEN RAISE EXCEPTION 'receive_purchase_order drifted (md5 %)', md5(v_def); END IF;

  v_new := replace(v_def,
E'  IF p_po_id IS NULL OR trim(p_po_id) = \'\' THEN\n    RAISE EXCEPTION \'receive_purchase_order: p_po_id is required\';\n  END IF;\n\n  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = \'array\' AND jsonb_array_length(p_lines) > 0 THEN',
E'  IF p_po_id IS NULL OR trim(p_po_id) = \'\' THEN\n    RAISE EXCEPTION \'receive_purchase_order: p_po_id is required\';\n  END IF;\n\n  PERFORM public.check_receipt_duplicate_expiry_dates(p_po_id, p_lines, p_additions);\n\n  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = \'array\' AND jsonb_array_length(p_lines) > 0 THEN');
  IF v_new = v_def THEN RAISE EXCEPTION 'anchor 1 (duplicate-check insertion point) not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
E'        IF COALESCE((v_batch->>\'received_qty\')::numeric, 0) > 0 THEN\n          PERFORM public.log_expiry_entry_suspect(\'receive_purchase_order\', v_purchase_date,\n            NULLIF(v_batch->>\'expiry_date\',\'\')::date,\n            jsonb_build_object(\'po_id\', p_po_id, \'po_line_id\', v_po_line_id, \'boonz_product_id\', v_product_id));\n        END IF;',
E'        IF COALESCE((v_batch->>\'received_qty\')::numeric, 0) > 0 THEN\n          PERFORM public.log_expiry_entry_suspect(\'receive_purchase_order\', v_purchase_date,\n            NULLIF(v_batch->>\'expiry_date\',\'\')::date,\n            jsonb_build_object(\'po_id\', p_po_id, \'po_line_id\', v_po_line_id, \'boonz_product_id\', v_product_id));\n          PERFORM public.check_receipt_shelf_life_deviation(\'receive_purchase_order\', v_today,\n            NULLIF(v_batch->>\'expiry_date\',\'\')::date, v_product_id,\n            jsonb_build_object(\'po_id\', p_po_id, \'po_line_id\', v_po_line_id));\n        END IF;');
  IF v_new = v_def THEN RAISE EXCEPTION 'anchor 2 (batch deviation check) not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
E'      PERFORM public.log_expiry_entry_suspect(\'receive_purchase_order_addition_inline\', v_addition_created_at,\n        v_addition_expiry, jsonb_build_object(\'po_id\', p_po_id, \'addition_id\', v_addition_id, \'boonz_product_id\', v_product_id));',
E'      PERFORM public.log_expiry_entry_suspect(\'receive_purchase_order_addition_inline\', v_addition_created_at,\n        v_addition_expiry, jsonb_build_object(\'po_id\', p_po_id, \'addition_id\', v_addition_id, \'boonz_product_id\', v_product_id));\n      PERFORM public.check_receipt_shelf_life_deviation(\'receive_purchase_order_addition_inline\', v_today,\n        v_addition_expiry, v_product_id, jsonb_build_object(\'po_id\', p_po_id, \'addition_id\', v_addition_id));');
  IF v_new = v_def THEN RAISE EXCEPTION 'anchor 3 (addition deviation check) not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
