-- PRD-016-inventory phantom pod row detector.
-- Cody-approved 2026-05-30 with revisions: cron-context role guard,
-- simplified UPDATE policy (full update for managers, no column-subset
-- trigger), phantom_pod_alerts NOT in Appendix A (monitoring telemetry).
-- Articles satisfied: 1, 2, 4, 7, 8, 11, 12.
-- Applied to prod 2026-05-30 via MCP. This file is the repo mirror.

-- 1. View: SECURITY INVOKER (default), joins pod_inventory + last sale +
--    last pack per (machine, boonz_product), flags rows with stock>0 and
--    no activity in 14 days.
CREATE OR REPLACE VIEW public.v_phantom_pod_rows AS
WITH last_activity AS (
  SELECT sh.machine_id, sh.boonz_product_id,
         MAX(sh.transaction_date) AS last_sale
  FROM public.sales_history sh
  WHERE sh.delivery_status IN ('Success','Successful')
    AND sh.machine_id IS NOT NULL
    AND sh.boonz_product_id IS NOT NULL
  GROUP BY sh.machine_id, sh.boonz_product_id
),
last_pack AS (
  SELECT rd.machine_id, rd.boonz_product_id,
         MAX(rd.dispatch_date) AS last_pack
  FROM public.refill_dispatching rd
  WHERE rd.dispatched = true
    AND rd.action IN ('Refill','Add New','Add')
    AND rd.machine_id IS NOT NULL
    AND rd.boonz_product_id IS NOT NULL
  GROUP BY rd.machine_id, rd.boonz_product_id
)
SELECT
  pi.pod_inventory_id,
  pi.machine_id,
  pi.shelf_id,
  pi.boonz_product_id,
  pi.current_stock,
  pi.snapshot_at,
  pi.expiration_date,
  m.official_name,
  bp.boonz_product_name,
  COALESCE(ls.last_sale, lp.last_pack) AS last_activity,
  (CURRENT_DATE - COALESCE(ls.last_sale, lp.last_pack)::date) AS days_silent
FROM public.pod_inventory pi
JOIN public.machines m ON m.machine_id = pi.machine_id
JOIN public.boonz_products bp ON bp.product_id = pi.boonz_product_id
LEFT JOIN last_activity ls
  ON ls.machine_id = pi.machine_id
 AND ls.boonz_product_id = pi.boonz_product_id
LEFT JOIN last_pack lp
  ON lp.machine_id = pi.machine_id
 AND lp.boonz_product_id = pi.boonz_product_id
WHERE pi.status = 'Active'
  AND COALESCE(pi.current_stock, 0) > 0
  AND COALESCE(ls.last_sale, lp.last_pack) < CURRENT_DATE - INTERVAL '14 days';

GRANT SELECT ON public.v_phantom_pod_rows TO authenticated;

-- 2. Append-only log table.
CREATE TABLE IF NOT EXISTS public.phantom_pod_alerts (
  alert_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  detected_at       timestamptz NOT NULL DEFAULT now(),
  pod_inventory_id  uuid NOT NULL,
  machine_id        uuid NOT NULL,
  boonz_product_id  uuid NOT NULL,
  current_stock     numeric NOT NULL,
  days_silent       int NOT NULL,
  status            text NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open','dismissed','corrected')),
  resolved_at       timestamptz NULL,
  resolved_by       uuid NULL REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  resolution_note   text NULL
);

CREATE INDEX IF NOT EXISTS idx_phantom_pod_alerts_status_detected
  ON public.phantom_pod_alerts (status, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_phantom_pod_alerts_pod_inv
  ON public.phantom_pod_alerts (pod_inventory_id);

ALTER TABLE public.phantom_pod_alerts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ppa_select ON public.phantom_pod_alerts;
CREATE POLICY ppa_select ON public.phantom_pod_alerts FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles up
      WHERE up.id = (SELECT auth.uid())
        AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])
    )
  );

DROP POLICY IF EXISTS ppa_update ON public.phantom_pod_alerts;
CREATE POLICY ppa_update ON public.phantom_pod_alerts FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles up
      WHERE up.id = (SELECT auth.uid())
        AND up.role = ANY (ARRAY['operator_admin','superadmin','manager'])
    )
  );

DROP POLICY IF EXISTS ppa_no_delete ON public.phantom_pod_alerts;
CREATE POLICY ppa_no_delete ON public.phantom_pod_alerts FOR DELETE USING (false);

-- 3. Canonical writer (cron-callable) with auth.uid()-aware role gate.
CREATE OR REPLACE FUNCTION public.cron_phantom_pod_alert()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id   uuid := (SELECT auth.uid());
  v_caller    text;
  v_inserted  integer := 0;
  v_skipped   integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'cron_phantom_pod_alert', true);

  -- Cron-context guard: if called with no auth.uid (service_role / pg_cron),
  -- proceed. If called by an authenticated user, require manager-class role.
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
    IF v_caller IS NULL OR v_caller NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'cron_phantom_pod_alert: forbidden for role %', COALESCE(v_caller,'unknown');
    END IF;
  END IF;

  WITH ins AS (
    INSERT INTO public.phantom_pod_alerts (
      pod_inventory_id, machine_id, boonz_product_id,
      current_stock, days_silent
    )
    SELECT v.pod_inventory_id, v.machine_id, v.boonz_product_id,
           v.current_stock, v.days_silent
    FROM public.v_phantom_pod_rows v
    WHERE NOT EXISTS (
      SELECT 1 FROM public.phantom_pod_alerts a
      WHERE a.pod_inventory_id = v.pod_inventory_id
        AND a.status = 'open'
    )
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_inserted FROM ins;

  SELECT COUNT(*) INTO v_skipped FROM public.v_phantom_pod_rows v
  WHERE EXISTS (
    SELECT 1 FROM public.phantom_pod_alerts a
    WHERE a.pod_inventory_id = v.pod_inventory_id
      AND a.status = 'open'
  );

  RETURN jsonb_build_object(
    'status', 'ok',
    'inserted', v_inserted,
    'skipped_already_open', v_skipped,
    'ran_at', now()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.cron_phantom_pod_alert() TO authenticated;

-- 4. Schedule 02:15 UTC (06:15 Dubai), 15 minutes after the daily
--    reconciliation cron at 02:00 UTC.
SELECT cron.schedule(
  'phantom_pod_alert',
  '15 2 * * *',
  $$SELECT public.cron_phantom_pod_alert();$$
);
