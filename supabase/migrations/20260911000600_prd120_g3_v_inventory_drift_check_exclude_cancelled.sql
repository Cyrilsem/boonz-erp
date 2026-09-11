-- PRD-120 follow-up G3: v_inventory_drift_check (read live by
-- src/app/(app)/refill/drift/page.tsx) counts "in_flight_dispatches" via
-- `refill_dispatching rd WHERE ... packed=true AND item_added=false`, with no cancelled
-- filter. 6 rows are currently packed=true, item_added=false, cancelled=true -- counted
-- as "in flight" (stock that will supposedly still be consumed) even though a cancelled
-- packed row never actually draws down the warehouse stock it's charged against. This can
-- mask real drift, and the same unfiltered EXISTS() in HAVING can keep a product's row
-- visible on the dashboard when it should show zero flow.
--
-- Fix: add `AND NOT COALESCE(rd.cancelled, false)` to both the scalar subquery and the
-- EXISTS() in HAVING. Cody: approve, Articles 12 (forward-only, md5-guarded), 16 (single
-- canonical object, corrected in place).

DO $mig$ DECLARE v_def text; BEGIN
  SELECT md5(pg_get_viewdef('public.v_inventory_drift_check'::regclass, true)) INTO v_def;
  IF v_def <> 'fc8eeb4c156ad9c23284676cd552b23c' THEN
    RAISE EXCEPTION 'v_inventory_drift_check drifted (md5 %), refusing blind replace', v_def;
  END IF;
END $mig$;

CREATE OR REPLACE VIEW public.v_inventory_drift_check AS
SELECT bp.product_id,
    bp.boonz_product_name,
    COALESCE(sum(wi.warehouse_stock), 0::numeric) AS wh_total,
    COALESCE(sum(wi.consumer_stock), 0::numeric) AS consumer_total,
    COALESCE(( SELECT sum(pod_inventory.current_stock) AS sum
           FROM pod_inventory
          WHERE pod_inventory.boonz_product_id = bp.product_id AND pod_inventory.status = 'Active'::text), 0::numeric) AS pod_total,
    COALESCE(sum(wi.consumer_stock), 0::numeric) AS unreconciled_consumer,
    ( SELECT count(*) AS count
           FROM refill_dispatching rd
          WHERE rd.boonz_product_id = bp.product_id AND rd.packed = true AND rd.item_added = false
            AND NOT COALESCE(rd.cancelled, false)) AS in_flight_dispatches
   FROM boonz_products bp
     LEFT JOIN warehouse_inventory wi ON wi.boonz_product_id = bp.product_id AND wi.status = 'Active'::text
  GROUP BY bp.product_id, bp.boonz_product_name
 HAVING COALESCE(sum(wi.consumer_stock), 0::numeric) > 0::numeric OR (EXISTS ( SELECT 1
           FROM refill_dispatching rd
          WHERE rd.boonz_product_id = bp.product_id AND rd.packed = true AND rd.item_added = false
            AND NOT COALESCE(rd.cancelled, false)));
