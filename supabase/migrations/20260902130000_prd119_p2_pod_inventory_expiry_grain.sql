-- PRD-119 P2 / PRD-118 item J: pod_inventory expiry grain. Widens
-- idx_pod_inv_active_shelf from "one Active row per machine+shelf+product" to "one
-- Active row per machine+shelf+product+expiry" — the design already conditionally
-- approved 2026-09-01 in _DRAFT_prd118_j_pod_inventory_expiry_grain.sql, applied here
-- verbatim after completing the reader audit that file's own header demanded before
-- any apply.
--
-- Root cause / real incident: AMZ-1068 A05 held ~3 Activia dated 31 Aug; 4 fresh units
-- dated 25 Sep were delivered; the old index forced receive_dispatch_line to archive
-- the existing row and merge into one INSERT (6 units @ 2026-08-31) — the fresh
-- batch's true expiry was destroyed and the shelf then read as fully expired
-- everywhere.
--
-- Reader audit (this session, two independent passes) found and fixed 5 objects that
-- would break once 2+ dated Active rows can coexist for the same machine+shelf+
-- product, ALL applied in this same transaction per the draft's own requirement
-- (the old index would reject the writer's new INSERT on a different expiry
-- otherwise):
--   - v_pod_inventory_latest: DISTINCT ON collapsed every row to the latest snapshot
--     regardless of expiry — added expiration_date to the DISTINCT ON/ORDER BY key.
--   - v_machine_expiry_batches: identical collapse via ROW_NUMBER PARTITION BY,
--     independently implemented — added expiration_date to the partition key. This
--     is the exact defect PRD-114 already named ("keeps the newest snapshot, not
--     the MIN expiry").
--   - approve_pod_inventory_edit, add_stock branch: top-up target row picked with no
--     expiry match — added the same (expiration_date = target OR both NULL) guard
--     already used correctly elsewhere (adjust_pod_inventory).
--   - record_variant_correction, NEW-variant lookup site: same bug, same fix,
--     matched against v_dispatch.expiry_date (the value the fallback INSERT branch
--     already uses). The OLD-variant site has no expiry parameter to match against —
--     deliberately left unpatched, flagged for Dara/Cody rather than guessed.
--   - v_pod_inventory_shelf_mismatch: 'multi_active_rows' verdict was keyed on raw
--     row count, which would false-alarm on every legitimately multi-batch shelf —
--     narrowed to a genuine DISTINCT boonz_product_id > 1 conflict. Verified zero
--     behavior change on current live data (345/345 match: today's only multi-row
--     shelves are NULL-shelf rows that are already genuinely multi-product).
--
-- Verified via rolled-back test transaction before this real apply: all six pieces
-- compile and apply together atomically, row counts sane (7,263 / 1,175), zero
-- behavior change on current shelf-mismatch verdicts.
--
-- Cody: approve, Articles 1/4/12/16 — index/writer design unchanged from the
-- 2026-09-01 conditional approval; reader audit now complete per that condition.

CREATE OR REPLACE VIEW public.v_pod_inventory_latest AS
SELECT DISTINCT ON (machine_id, shelf_id, boonz_product_id, expiration_date)
  machine_id, shelf_id, boonz_product_id, current_stock, expiration_date, batch_id, status, snapshot_at
FROM public.pod_inventory pi
ORDER BY machine_id, shelf_id, boonz_product_id, expiration_date, snapshot_at DESC;

CREATE OR REPLACE VIEW public.v_machine_expiry_batches AS
WITH ranked AS (
  SELECT pi.pod_inventory_id, pi.machine_id, pi.shelf_id, pi.boonz_product_id, pi.batch_id,
    pi.expiration_date, pi.current_stock, pi.snapshot_date,
    row_number() OVER (PARTITION BY pi.machine_id, (COALESCE(pi.shelf_id::text, 'noshelf'::text)),
      pi.boonz_product_id, pi.expiration_date
      ORDER BY pi.snapshot_date DESC, pi.pod_inventory_id) AS rn
  FROM public.pod_inventory pi
  WHERE pi.status = 'Active'::text AND pi.current_stock > 0::numeric
)
SELECT pod_inventory_id, machine_id, shelf_id, boonz_product_id, batch_id, expiration_date, current_stock, snapshot_date
FROM ranked WHERE rn = 1;

CREATE OR REPLACE VIEW public.v_pod_inventory_shelf_mismatch AS
WITH pod_active AS (
  SELECT pi.machine_id, pi.shelf_id, count(*) AS active_row_count,
    count(DISTINCT pi.boonz_product_id) AS distinct_product_count,
    (array_agg(pi.boonz_product_id ORDER BY pi.snapshot_at DESC NULLS LAST))[1] AS pod_boonz_id
  FROM public.pod_inventory pi
  WHERE pi.status = 'Active'::text AND pi.shelf_id IS NOT NULL
  GROUP BY pi.machine_id, pi.shelf_id
), pod_resolved AS (
  SELECT pa.machine_id, pa.shelf_id, pa.active_row_count, pa.distinct_product_count, pa.pod_boonz_id,
    (SELECT pm.pod_product_id FROM public.product_mapping pm
      WHERE pm.boonz_product_id = pa.pod_boonz_id AND pm.is_global_default = true AND pm.status = 'Active'::text
      LIMIT 1) AS pod_pp_id
  FROM pod_active pa
), weimi AS (
  SELECT DISTINCT ON (sc.machine_id, sc.shelf_id) sc.machine_id, sc.shelf_id, sc.shelf_code,
    vls.pod_product_id AS weimi_pp_id, vls.match_method, vls.fill_pct, vls.goods_name_raw
  FROM public.shelf_configurations sc
    JOIN public.v_live_shelf_stock vls ON vls.machine_id = sc.machine_id
      AND vls.slot_name = ("left"(sc.shelf_code, 1) || substr(sc.shelf_code, 2)::integer::text)
  WHERE sc.is_phantom = false
  ORDER BY sc.machine_id, sc.shelf_id, vls.snapshot_at DESC NULLS LAST
), joined AS (
  SELECT COALESCE(w.machine_id, pr.machine_id) AS machine_id, COALESCE(w.shelf_id, pr.shelf_id) AS shelf_id,
    w.shelf_code, pr.active_row_count, pr.distinct_product_count, pr.pod_pp_id, w.weimi_pp_id,
    w.match_method, w.fill_pct, w.goods_name_raw
  FROM pod_resolved pr FULL JOIN weimi w USING (machine_id, shelf_id)
)
SELECT j.machine_id, m.official_name AS machine, j.shelf_id, j.shelf_code, j.pod_pp_id,
  podp.pod_product_name AS pod_inventory_product, j.weimi_pp_id, weip.pod_product_name AS weimi_product,
  j.goods_name_raw, j.match_method, j.fill_pct, COALESCE(j.active_row_count, 0::bigint) AS active_row_count,
  CASE
    WHEN COALESCE(j.distinct_product_count, 0::bigint) > 1 THEN 'multi_active_rows'::text
    WHEN j.active_row_count IS NULL THEN 'no_pod_row'::text
    WHEN j.weimi_pp_id IS NULL OR j.match_method = 'unmatched'::text THEN 'weimi_unmatched'::text
    WHEN j.pod_pp_id IS DISTINCT FROM j.weimi_pp_id THEN 'product_mismatch'::text
    ELSE 'ok'::text
  END AS verdict
FROM joined j
  JOIN public.machines m ON m.machine_id = j.machine_id
  LEFT JOIN public.pod_products podp ON podp.pod_product_id = j.pod_pp_id
  LEFT JOIN public.pod_products weip ON weip.pod_product_id = j.weimi_pp_id;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='approve_pod_inventory_edit' AND p.pronamespace='public'::regnamespace;
  v_new := replace(v_def,
    E'    SELECT * INTO v_pod FROM public.pod_inventory\n     WHERE machine_id=v_edit.machine_id\n       AND shelf_id=v_edit.destination_shelf_id\n       AND boonz_product_id=v_edit.boonz_product_id\n       AND status=\'Active\'\n     FOR UPDATE;',
    E'    SELECT * INTO v_pod FROM public.pod_inventory\n     WHERE machine_id=v_edit.machine_id\n       AND shelf_id=v_edit.destination_shelf_id\n       AND boonz_product_id=v_edit.boonz_product_id\n       AND status=\'Active\'\n       AND ((expiration_date = v_edit.requested_expiration_date) OR (expiration_date IS NULL AND v_edit.requested_expiration_date IS NULL))\n     FOR UPDATE;');
  IF v_new = v_def THEN RAISE EXCEPTION 'approve_pod_inventory_edit: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='record_variant_correction' AND p.pronamespace='public'::regnamespace;
  v_new := replace(v_def,
    E'  SELECT * INTO v_pod_new_row FROM pod_inventory\n  WHERE machine_id = v_dispatch.machine_id\n    AND boonz_product_id = p_new_variant_id\n    AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL)\n    AND status = \'Active\'\n  ORDER BY snapshot_at DESC LIMIT 1 FOR UPDATE;',
    E'  SELECT * INTO v_pod_new_row FROM pod_inventory\n  WHERE machine_id = v_dispatch.machine_id\n    AND boonz_product_id = p_new_variant_id\n    AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL)\n    AND status = \'Active\'\n    AND ((expiration_date = v_dispatch.expiry_date) OR (expiration_date IS NULL AND v_dispatch.expiry_date IS NULL))\n  ORDER BY snapshot_at DESC LIMIT 1 FOR UPDATE;');
  IF v_new = v_def THEN RAISE EXCEPTION 'record_variant_correction: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;

DROP INDEX IF EXISTS public.idx_pod_inv_active_shelf;
CREATE UNIQUE INDEX IF NOT EXISTS idx_pod_inv_active_shelf_expiry
  ON public.pod_inventory (machine_id, shelf_id, boonz_product_id, expiration_date) WHERE (status = 'Active');
CREATE UNIQUE INDEX IF NOT EXISTS idx_pod_inv_active_shelf_nulldate
  ON public.pod_inventory (machine_id, shelf_id, boonz_product_id) WHERE (status = 'Active' AND expiration_date IS NULL);

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='receive_dispatch_line' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'b2be5e5b14c57eb253eb04140642a36b' THEN
    RAISE EXCEPTION 'receive_dispatch_line drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;
  v_new := replace(v_def,
$patch$    IF p_filled_quantity > 0 THEN
      WITH archived AS (UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('merged_into_dispatch_%s_%s', v_dispatch.dispatch_date, p_dispatch_id::text), snapshot_at = now() WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' RETURNING current_stock, expiration_date), merge_stats AS (SELECT COALESCE(SUM(current_stock), 0)::numeric AS prior_qty, COUNT(*)::int AS prior_n, MIN(expiration_date) AS oldest_expiry FROM archived)
      INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at) SELECT v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE, p_filled_quantity + ms.prior_qty, p_filled_quantity + ms.prior_qty, LEAST(v_effective_expiry, COALESCE(ms.oldest_expiry, v_effective_expiry)), CASE WHEN ms.prior_n > 0 THEN format('MERGED-DISPATCH-%s', v_dispatch.dispatch_date) ELSE format('DISPATCH-%s', v_dispatch.dispatch_date) END, 'Active', now(), now() FROM merge_stats ms RETURNING pod_inventory_id INTO v_pod_id;
      SELECT prior_n INTO v_prior_active_merged FROM (SELECT COUNT(*)::int AS prior_n FROM pod_inventory WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Inactive' AND removal_reason = format('merged_into_dispatch_%s_%s', v_dispatch.dispatch_date, p_dispatch_id::text)) AS s;
    END IF;$patch$,
$patch$    IF p_filled_quantity > 0 THEN
      UPDATE pod_inventory
         SET current_stock = current_stock + p_filled_quantity,
             estimated_remaining = current_stock + p_filled_quantity,
             snapshot_at = now()
       WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id
         AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
         AND ((expiration_date = v_effective_expiry) OR (expiration_date IS NULL AND v_effective_expiry IS NULL))
       RETURNING pod_inventory_id INTO v_pod_id;
      IF NOT FOUND THEN
        INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date,
          current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at)
        VALUES (v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE,
          p_filled_quantity, p_filled_quantity, v_effective_expiry,
          format('DISPATCH-%s', v_dispatch.dispatch_date), 'Active', now(), now())
        RETURNING pod_inventory_id INTO v_pod_id;
      END IF;
      v_prior_active_merged := 0;
    END IF;$patch$);
  IF v_new = v_def THEN RAISE EXCEPTION 'merge block not found'; END IF;
  EXECUTE v_new;
END $mig$;
