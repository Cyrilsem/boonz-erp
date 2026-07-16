-- MIRROR (do NOT re-apply; idempotent). v_slot_binding_drift has been live in prod since the
-- drift-kill work but its CREATE VIEW was never captured in a repo migration (PRD-CLEAN-09's
-- migration consumes it and notes it pre-existed). Definition verified against live pg_views 2026-07-16.
-- Join axis: slot_name zero-pad -> shelf_code; NEVER aisle_code.
CREATE OR REPLACE VIEW public.v_slot_binding_drift AS
 WITH wm AS (
         SELECT v.machine_id,
            sc.shelf_id,
            sc.shelf_code,
            v.pod_product_id AS weimi_product,
            v.goods_name_raw,
            v.snapshot_at
           FROM v_live_shelf_stock v
             JOIN shelf_configurations sc ON sc.machine_id = v.machine_id AND sc.shelf_code = regexp_replace(v.slot_name, '^([A-Z])(\d)$'::text, '\10\2'::text)
          WHERE v.pod_product_id IS NOT NULL
        )
 SELECT sl.machine_id,
    wm.shelf_id,
    wm.shelf_code,
    sl.pod_product_id AS lifecycle_product,
    wm.weimi_product,
    wm.goods_name_raw,
    wm.snapshot_at
   FROM slot_lifecycle sl
     JOIN wm ON wm.machine_id = sl.machine_id AND wm.shelf_id = sl.shelf_id
  WHERE sl.archived = false AND sl.is_current = true AND sl.pod_product_id <> wm.weimi_product;
