-- PRD-138 WS-B (= PRD-141 item 13): era-aware repurpose eligibility + velocity clip.
-- Night window only. Fleet diff in a rolled-back txn is in docs/prds/PRD-141-log.md.
-- Rollback (no migration): UPDATE pick_urgency_params SET repurpose_min_sales = 999999;
-- Full rollback: supabase/rollbacks/prd138_wsb_rollback.sql.

-- 1. Params (spec defaults, CS confirmed 17 Oct).
ALTER TABLE public.pick_urgency_params
  ADD COLUMN IF NOT EXISTS repurpose_min_days  integer NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS repurpose_min_sales integer NOT NULL DEFAULT 10;

-- 2. One eligibility source per machine. era_start = the later of repurposed_at and
--    relaunched_at (Dubai date), so ACTIVATEMOE's window starts at its relaunch.
CREATE OR REPLACE VIEW public.v_machine_eligibility AS
WITH p AS (
  SELECT repurpose_grace_days::integer AS grace_days, repurpose_min_days, repurpose_min_sales
  FROM public.pick_urgency_params
  LIMIT 1
), base AS (
  SELECT m.machine_id, m.adyen_status, m.adyen_inventory_in_store, m.repurposed_at, m.relaunched_at,
    GREATEST(m.repurposed_at, (m.relaunched_at AT TIME ZONE 'Asia/Dubai')::date) AS era_start,
    (m.repurposed_at IS NOT NULL AND m.repurposed_at >= now() - make_interval(days => p.grace_days)) AS in_repurpose_grace_window,
    p.grace_days, p.repurpose_min_days, p.repurpose_min_sales
  FROM public.machines m CROSS JOIN p
)
SELECT b.machine_id,
  (b.adyen_status = 'Online today' AND b.adyen_inventory_in_store = 'Live') AS flags_live,
  b.repurposed_at,
  b.era_start,
  b.in_repurpose_grace_window,
  rs.n AS sales_since_repurpose,
  b.adyen_status = 'Online today' AND b.adyen_inventory_in_store = 'Live'
    AND (b.repurposed_at IS NULL
         OR b.repurposed_at < now() - make_interval(days => b.grace_days)
         OR (b.repurposed_at <= now() - make_interval(days => b.repurpose_min_days)
             AND rs.n >= b.repurpose_min_sales)) AS is_eligible_machine,
  CASE WHEN b.era_start IS NULL OR b.era_start <= (now() AT TIME ZONE 'Asia/Dubai')::date - 30 THEN 30
       ELSE LEAST(30, GREATEST(1, (now() AT TIME ZONE 'Asia/Dubai')::date - b.era_start)) END AS era_days
FROM base b
LEFT JOIN LATERAL (
  SELECT count(*) AS n
  FROM public.sales_history s
  WHERE b.in_repurpose_grace_window
    AND s.machine_id = b.machine_id
    AND s.delivery_status = ANY (ARRAY['Success','Successful'])
    AND s.transaction_date >= (b.repurposed_at::timestamp AT TIME ZONE 'Asia/Dubai')
) rs ON true;

REVOKE ALL ON public.v_machine_eligibility FROM anon, public;
GRANT SELECT ON public.v_machine_eligibility TO authenticated, service_role;

-- 3. v_live_shelf_stock reads it. Anchor patch on the live body (one expression + one join).
DO $patch$
DECLARE
  v_def text := pg_get_viewdef('public.v_live_shelf_stock'::regclass, true);
  v_expr_start text := '    m.adyen_status = ''Online today''::text AND m.adyen_inventory_in_store = ''Live''::text AND (m.repurposed_at IS NULL';
  v_expr_end   text := ' AS is_eligible_machine';
  v_join_old   text := 'JOIN machines m ON m.machine_id = d.machine_id;';
  v_join_new   text := 'JOIN machines m ON m.machine_id = d.machine_id JOIN v_machine_eligibility me ON me.machine_id = d.machine_id;';
  i int; j int; v_new text;
BEGIN
  i := strpos(v_def, v_expr_start);
  j := strpos(v_def, v_expr_end);
  IF i = 0 OR j = 0 OR j < i THEN RAISE EXCEPTION 'prd138 wsb: eligibility anchor missing'; END IF;
  IF strpos(substr(v_def, i + 1), v_expr_start) > 0 THEN RAISE EXCEPTION 'prd138 wsb: eligibility anchor not unique'; END IF;
  v_new := substr(v_def, 1, i - 1) || '    me.is_eligible_machine' || substr(v_def, j);
  IF strpos(v_new, v_join_old) = 0 THEN RAISE EXCEPTION 'prd138 wsb: join anchor missing'; END IF;
  v_new := replace(v_new, v_join_old, v_join_new);
  IF v_new = v_def THEN RAISE EXCEPTION 'prd138 wsb: no-op'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_live_shelf_stock AS ' || v_new;
END
$patch$;

-- 4. v_shelf_sales_identity: velocity clipped to the era, era_days denominator, thin_history badge.
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
             JOIN v_machine_eligibility me ON me.machine_id = s.machine_id
             LEFT JOIN pod_products d ON d.pod_product_name = s.pod_product_name
             LEFT JOIN pod_products ci ON lower(btrim(ci.pod_product_name)) = lower(btrim(s.pod_product_name))
             LEFT JOIN product_name_conventions pnc ON pnc.original_name = s.pod_product_name
             LEFT JOIN pod_products cv ON cv.pod_product_name = pnc.official_name
             LEFT JOIN alias al ON al.pod_product_id = COALESCE(d.pod_product_id, ci.pod_product_id, cv.pod_product_id)
          WHERE (s.delivery_status = ANY (ARRAY['Success'::text, 'Successful'::text])) AND s.transaction_date >= (now() - '30 days'::interval)
            AND s.transaction_date >= COALESCE((me.era_start::timestamp AT TIME ZONE 'Asia/Dubai'), '-infinity'::timestamptz)
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
    COALESCE(sa.units_30d, 0::numeric) / me.era_days::numeric(10,1) AS dvel,
        CASE
            WHEN COALESCE(sa.units_30d, 0::numeric) > 0::numeric THEN sh.stock::numeric / (sa.units_30d / me.era_days::numeric(10,1))
            ELSE NULL::numeric
        END AS dos,
    true AS resolved,
    sa.machine_id IS NOT NULL AS has_sales,
    me.era_days,
    me.era_days < 14 AS thin_history
   FROM shelf sh
     JOIN v_machine_eligibility me ON me.machine_id = sh.machine_id
     LEFT JOIN sales sa ON sa.machine_id = sh.machine_id AND sa.pod_product_id = sh.pod_product_id;
