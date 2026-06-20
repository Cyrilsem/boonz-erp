-- PRD-033 Phase A (R1): v_shelf_capacity headroom nets same-plan planned removals.
--
-- Before: headroom = max_stock - current_stock, where current_stock is live WEIMI
-- (v_live_shelf_stock) only. A paired REMOVE/M2W in the same visit did NOT free
-- capacity, so placing a new product on an occupied shelf clamped to the free space
-- (Nutella 12/12 -> Keen clamped to 0). add_pod_refill_row + edit_pod_refill_row read
-- this view live by shelf_id and hard-clamp REFILL/ADD_NEW to headroom, so fixing the
-- view fixes both clamps with no RPC change (A2: they read, do not snapshot).
--
-- After: headroom = max_stock - GREATEST(current_stock - planned_removed, 0), where
-- planned_removed = SUM(qty) of REMOVE/M2W rows on the shelf, status IN ('draft','approved')
-- (un-executed removes only - CS 2026-06-17 - so an already-dispatched REMOVE whose stock has
-- left the shelf is not double-counted), capped at current_stock. The view is shelf-keyed
-- (one row per shelf, no plan_date), so
-- to avoid fan-out we scope planned_removed to the shelf's MOST RECENT active plan_date
-- (the plan an operator is currently building). current_stock stays as the live WEIMI
-- value for display; a new planned_removed column is appended for transparency.
--
-- Forward-only CREATE OR REPLACE VIEW; planned_removed is appended last so existing
-- column positions are preserved (Postgres CREATE OR REPLACE VIEW rule). No protected
-- table is written; this is a read-only view that governs the two clamp RPCs.

CREATE OR REPLACE VIEW public.v_shelf_capacity AS
 WITH live AS (
         SELECT sc.shelf_id,
            sc.machine_id,
            sc.shelf_code,
            sc.shelf_size,
            sc.max_capacity,
            GREATEST(COALESCE(max(vls.current_stock), 0), 0) AS current_stock,
            max(vls.max_stock) AS live_max_stock,
            (array_agg(NULLIF(btrim(vls.goods_name_raw), ''::text) ORDER BY vls.current_stock DESC NULLS LAST) FILTER (WHERE NULLIF(btrim(vls.goods_name_raw), ''::text) IS NOT NULL))[1] AS current_product
           FROM shelf_configurations sc
             LEFT JOIN v_live_shelf_stock vls ON vls.machine_id = sc.machine_id AND vls.slot_name = ("left"(sc.shelf_code, 1) || substr(sc.shelf_code, 2)::integer::text)
          WHERE sc.is_phantom = false
          GROUP BY sc.shelf_id, sc.machine_id, sc.shelf_code, sc.shelf_size, sc.max_capacity
        ),
      -- PRD-033 R1: planned removals on the shelf's most recent active plan, so a paired
      -- REMOVE/M2W in the same visit frees capacity for the ADD_NEW/REFILL. One row per
      -- shelf (latest active plan_date only) to avoid fan-out vs the shelf-keyed consumers.
      removals AS (
         SELECT prp.machine_id,
            prp.shelf_id,
            COALESCE(sum(prp.qty), 0)::integer AS planned_removed
           FROM pod_refill_plan prp
          WHERE prp.action IN ('REMOVE'::text, 'M2W'::text)
            -- Un-executed removes only (CS 2026-06-17): a stitched/dispatched REMOVE has
            -- already dropped WEIMI current_stock, so netting it again double-counts. draft +
            -- approved are the not-yet-executed planning states an operator is building.
            AND prp.status IN ('draft'::text, 'approved'::text)
            AND prp.plan_date = (
                  SELECT max(p2.plan_date)
                    FROM pod_refill_plan p2
                   WHERE p2.machine_id = prp.machine_id
                     AND p2.shelf_id = prp.shelf_id
                     AND p2.action IN ('REMOVE'::text, 'M2W'::text)
                     AND p2.status IN ('draft'::text, 'approved'::text)
                )
          GROUP BY prp.machine_id, prp.shelf_id
        )
 SELECT l.shelf_id,
    l.machine_id,
    l.shelf_code,
    l.shelf_size AS size_class,
    COALESCE(NULLIF(l.live_max_stock, 0), NULLIF(l.max_capacity, 0), 10) AS max_stock,
    l.current_stock,
    -- planned_removed is capped at current_stock (AC-A invariant: you cannot plan-remove more
    -- than is physically on the shelf; an over-planned remove just clears the shelf). The cap is
    -- arithmetically transparent to headroom: GREATEST(current - LEAST(removed,current), 0) ==
    -- GREATEST(current - removed, 0).
    GREATEST(COALESCE(NULLIF(l.live_max_stock, 0), NULLIF(l.max_capacity, 0), 10)
             - GREATEST(l.current_stock - LEAST(COALESCE(r.planned_removed, 0), l.current_stock), 0), 0) AS headroom,
    l.current_product,
    LEAST(COALESCE(r.planned_removed, 0), l.current_stock) AS planned_removed
   FROM live l
     LEFT JOIN removals r ON r.machine_id = l.machine_id AND r.shelf_id = l.shelf_id;
