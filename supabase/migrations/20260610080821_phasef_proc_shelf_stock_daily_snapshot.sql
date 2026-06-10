-- PRD-4b (Procurement Brain v3) — daily shelf-stock snapshot, to unlock availability-adjusted
-- velocity (sales / days-in-stock) for forecast v-next.
-- Migration name: phasef_proc_shelf_stock_daily_snapshot
-- Articles: 2 (RLS on new table), 4 (DEFINER writer validates + sets GUCs), 11 (cron calls an RPC).
--
-- There is NO shelf-stock history today (v_live_shelf_stock is point-in-time; refill_commit_log is
-- empty). This stands one up: a nightly snapshot of per-(machine, pod_product) stock so that, over
-- the coming weeks, "days in stock" becomes measurable and stockout bias can be removed from the
-- forecast. Forward-fills nothing retroactively — it starts accruing from first run.

-- ── 1. Snapshot table (NOT an Appendix-A protected entity; new analytics table). ─────────────────
CREATE TABLE IF NOT EXISTS public.shelf_stock_daily (
  snapshot_date   date    NOT NULL,
  machine_id      uuid    NOT NULL,
  pod_product_id  uuid    NOT NULL,
  total_stock     integer NOT NULL,
  max_stock       integer,
  slots_count     integer NOT NULL,
  in_stock        boolean NOT NULL,
  captured_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (snapshot_date, machine_id, pod_product_id)
);

CREATE INDEX IF NOT EXISTS idx_shelf_stock_daily_machine_prod
  ON public.shelf_stock_daily (machine_id, pod_product_id, snapshot_date);
CREATE INDEX IF NOT EXISTS idx_shelf_stock_daily_prod_date
  ON public.shelf_stock_daily (pod_product_id, snapshot_date);

COMMENT ON TABLE public.shelf_stock_daily IS
  'PRD-4b. Nightly per-(machine, pod_product) shelf-stock snapshot from v_live_shelf_stock. Written ONLY by snapshot_shelf_stock() (DEFINER), scheduled by pg_cron. Powers days-in-stock / availability-adjusted velocity for the procurement forecast. in_stock = total_stock > 0.';

-- Article 2: RLS. Read for authenticated; writes only through the DEFINER RPC (no authenticated write).
ALTER TABLE public.shelf_stock_daily ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shelf_stock_daily_read ON public.shelf_stock_daily;
CREATE POLICY shelf_stock_daily_read ON public.shelf_stock_daily
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS shelf_stock_daily_service ON public.shelf_stock_daily;
CREATE POLICY shelf_stock_daily_service ON public.shelf_stock_daily
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ── 2. Canonical writer: snapshot today's eligible shelf stock. Idempotent (re-run safe). ────────
CREATE OR REPLACE FUNCTION public.snapshot_shelf_stock()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_role text;
  v_date date;
  v_rows integer;
BEGIN
  -- Article 4: caller gate. auth.uid() IS NULL = system/cron/service context (allowed).
  IF auth.uid() IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin') THEN
      RAISE EXCEPTION 'snapshot_shelf_stock: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'snapshot_shelf_stock', true);

  v_date := (now() AT TIME ZONE 'Asia/Dubai')::date;

  INSERT INTO public.shelf_stock_daily
    (snapshot_date, machine_id, pod_product_id, total_stock, max_stock, slots_count, in_stock)
  SELECT
    v_date,
    s.machine_id,
    s.pod_product_id,
    SUM(s.current_stock)::int                AS total_stock,
    NULLIF(SUM(s.max_stock), 0)::int         AS max_stock,
    COUNT(*)::int                            AS slots_count,
    SUM(s.current_stock) > 0                  AS in_stock
  FROM public.v_live_shelf_stock s
  WHERE s.is_eligible_machine
    AND s.is_enabled
    AND s.pod_product_id IS NOT NULL
  GROUP BY s.machine_id, s.pod_product_id
  ON CONFLICT (snapshot_date, machine_id, pod_product_id) DO UPDATE
    SET total_stock = EXCLUDED.total_stock,
        max_stock   = EXCLUDED.max_stock,
        slots_count = EXCLUDED.slots_count,
        in_stock    = EXCLUDED.in_stock,
        captured_at = now();

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('snapshot_date', v_date, 'rows', v_rows);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.snapshot_shelf_stock() TO authenticated, service_role;

COMMENT ON FUNCTION public.snapshot_shelf_stock() IS
  'PRD-4b. Sole writer of shelf_stock_daily. Aggregates v_live_shelf_stock to (machine, pod_product) and upserts today (Asia/Dubai) snapshot. Idempotent. Called nightly by pg_cron job shelf_stock_daily_snapshot. Gate: system/cron (auth.uid() NULL) or operator_admin/superadmin.';

-- ── 3. Schedule: nightly at 20:30 UTC (00:30 Asia/Dubai), after nightly-fleet-refresh (19:59 UTC). ─
SELECT cron.schedule(
  'shelf_stock_daily_snapshot',
  '30 20 * * *',
  $$SELECT public.snapshot_shelf_stock();$$
);
