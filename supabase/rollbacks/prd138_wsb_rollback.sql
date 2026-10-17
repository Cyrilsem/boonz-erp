-- PRD-138 WS-B rollback.
-- Fast path (no DDL, restores the pure 30-day grace):
--   UPDATE public.pick_urgency_params SET repurpose_min_sales = 999999;
-- Full path: restore the pre-WS-B bodies (held below) and drop the helper view.

-- v_live_shelf_stock: put the inline eligibility expression back (anchor patch, reverse of the migration).
DO $rb$
DECLARE
  v_def text := pg_get_viewdef('public.v_live_shelf_stock'::regclass, true);
  v_new text;
BEGIN
  IF strpos(v_def, '    me.is_eligible_machine') = 0 THEN RAISE EXCEPTION 'rollback anchor missing'; END IF;
  v_new := replace(v_def, '    me.is_eligible_machine',
    '    m.adyen_status = ''Online today''::text AND m.adyen_inventory_in_store = ''Live''::text AND (m.repurposed_at IS NULL OR m.repurposed_at < (now() - make_interval(days => ( SELECT p.repurpose_grace_days::integer AS repurpose_grace_days FROM pick_urgency_params p))))');
  v_new := replace(v_new, ' JOIN v_machine_eligibility me ON me.machine_id = d.machine_id;', ';');
  EXECUTE 'CREATE OR REPLACE VIEW public.v_live_shelf_stock AS ' || v_new;
END
$rb$;

-- v_shelf_sales_identity: CREATE OR REPLACE cannot drop the appended era_days / thin_history
-- columns, so the held body keeps them as constants (30, false) and restores the flat 30-day window.
CREATE OR REPLACE VIEW public.v_shelf_sales_identity AS
 WITH alias(pod_product_id, canonical_pod) AS (
         VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,'51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
        ), shelf AS (
         SELECT v.machine_id,
            COALESCE(al.canonical_pod, v.pod_product_id) AS pod_product_id,
            min(v.goods_name_raw) AS goods_name_sample,
            count(*) AS facings,
            sum(v.current_stock) AS stock,
            sum(v.max_stock) AS cap
           FROM v_live_shelf_stock v
             LEFT JOIN alias al ON al.pod_product_id = v.pod_product_id
          WHERE v.is_enabled AND COALESCE(v.is_broken, false) = false AND v.is_eligible_machine AND v.pod_product_id IS NOT NULL
          GROUP BY v.machine_id, (COALESCE(al.canonical_pod, v.pod_product_id))
        ), sale_resolved AS (
         SELECT s.machine_id,
            COALESCE(al.canonical_pod, COALESCE(d.pod_product_id, ci.pod_product_id, cv.pod_product_id)) AS pod_product_id,
            s.qty,
            s.transaction_date
           FROM sales_history s
             LEFT JOIN pod_products d ON d.pod_product_name = s.pod_product_name
             LEFT JOIN pod_products ci ON lower(btrim(ci.pod_product_name)) = lower(btrim(s.pod_product_name))
             LEFT JOIN product_name_conventions pnc ON pnc.original_name = s.pod_product_name
             LEFT JOIN pod_products cv ON cv.pod_product_name = pnc.official_name
             LEFT JOIN alias al ON al.pod_product_id = COALESCE(d.pod_product_id, ci.pod_product_id, cv.pod_product_id)
          WHERE (s.delivery_status = ANY (ARRAY['Success'::text, 'Successful'::text])) AND s.transaction_date >= (now() - '30 days'::interval)
        ), sales AS (
         SELECT sale_resolved.machine_id,
            sale_resolved.pod_product_id,
            sum(sale_resolved.qty) AS units_30d,
            sum(sale_resolved.qty) FILTER (WHERE sale_resolved.transaction_date >= (now() - '7 days'::interval)) AS units_7d
           FROM sale_resolved
          WHERE sale_resolved.pod_product_id IS NOT NULL
          GROUP BY sale_resolved.machine_id, sale_resolved.pod_product_id
        )
 SELECT sh.machine_id,
    sh.pod_product_id,
    sh.goods_name_sample,
    sh.facings,
    sh.stock,
    sh.cap,
    COALESCE(sa.units_30d, 0::numeric) AS units_30d,
    COALESCE(sa.units_7d, 0::numeric) AS units_7d,
    COALESCE(sa.units_30d, 0::numeric) / 30.0 AS dvel,
        CASE
            WHEN COALESCE(sa.units_30d, 0::numeric) > 0::numeric THEN sh.stock::numeric / (sa.units_30d / 30.0)
            ELSE NULL::numeric
        END AS dos,
    true AS resolved,
    sa.machine_id IS NOT NULL AS has_sales,
    30 AS era_days,
    false AS thin_history
   FROM shelf sh
     LEFT JOIN sales sa ON sa.machine_id = sh.machine_id AND sa.pod_product_id = sh.pod_product_id;

-- v_machine_eligibility is then unreferenced by these two views; drop only after confirming
-- no later migration (PRD-141 item 14, WS-C drift view) reads it.
