-- ============================================================================
-- 20260718090001_rc08a_canonical_wh_availability.sql
-- RC-08 MIGRATION A — canonical warehouse-availability layer (ONE interface).
--
-- Closes / supports Cody conditions:
--   B1(a) ONE availability interface -> public.wh_fefo_for_line (single canonical name).
--   B1(b) coverage nets outstanding WH-origin commitments by REUSING
--         v_dispatch_availability.reserved_by_earlier (NOT re-derived). See §C.
--   B1(c) explicit warehouse parameter (p_warehouse_ids) so cold lines route to
--         WH_CENTRAL and are NOT forced onto the machine's default warehouse.
--   B2   Article-16 registry rows added in METRICS_REGISTRY_edit.md (companion file).
--   B5   Availability objects land in the SAME apply window as RC-01, and BEFORE it
--         (RC-01's push binds wh_fefo_for_line — see APPLY_ORDER.md). ATOMIC with RC-01.
--
-- Built ON the canonical base view v_wh_pickable (Art-16). Does NOT fork the pickable
-- predicate and does NOT duplicate v_dispatch_availability's netting.
--
-- All new functions are SECURITY INVOKER + STABLE (read-only). No new definer surface.
-- Protected entity touched: warehouse_inventory (READ ONLY here) -> Cody review req.
-- Live bodies pulled 2026-07-18 via pg_get_viewdef / pg_get_functiondef.
-- ============================================================================
BEGIN;

-- ── A-0: canonical WH_CENTRAL resolver (de-magics the hardcoded UUID) ─────────
-- Replaces the literal 4bebef68-9e36-4a5c-9c2c-142f8dbdae85 wherever a cold-route /
-- central default is INTENDED (RC-08 B uses it for the 6 pure-stamp sites; RC-01's
-- push uses it for cold-line routing). Name lookup verified unique 2026-07-18.
CREATE OR REPLACE FUNCTION public.wh_central_id()
RETURNS uuid
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  SELECT warehouse_id FROM public.warehouses WHERE name = 'WH_CENTRAL';
$$;

-- ── A-1: additive FEFO-tiebreak columns on the base view (non-breaking) ───────
-- Byte-faithful to the LIVE body (2026-07-18) + two trailing columns
-- (wi.created_at, wi.reservation_priority). security_invoker=true PRESERVED
-- (verified live reloption). Existing named-column consumers unaffected.
CREATE OR REPLACE VIEW public.v_wh_pickable
WITH (security_invoker = true) AS
 WITH dubai AS (
         SELECT (now() AT TIME ZONE 'Asia/Dubai'::text)::date AS today
        )
 SELECT wi.wh_inventory_id,
    wi.boonz_product_id,
    wi.warehouse_id,
    wi.wh_location,
    wi.batch_id,
    wi.warehouse_stock,
    wi.expiration_date,
    wi.reserved_for_machine_id,
    wi.snapshot_date,
    wi.created_at,
    wi.reservation_priority
   FROM warehouse_inventory wi
     CROSS JOIN dubai d
  WHERE wi.status = 'Active'::text
    AND NOT COALESCE(wi.quarantined, false)
    AND (wi.expiration_date >= d.today OR wi.expiration_date IS NULL)
    AND wi.warehouse_stock > 0::numeric;

-- ── A-2: canonical row set for a machine's route (batch grain, dedupe-safe) ───
-- Composes v_wh_pickable + machine WHscope (primary+secondary) + reservation
-- awareness + plan-date expiry (tightens the view's Dubai-today to p_plan_date).
-- This is the reference shape rank_slot_suitability already proved. Consumers
-- (stitch/engine/subs) migrate to this in the PHASE-2 cutover, not here.
CREATE OR REPLACE FUNCTION public.wh_available(p_machine_id uuid, p_plan_date date)
RETURNS TABLE (
  wh_inventory_id         uuid,
  boonz_product_id        uuid,
  warehouse_id            uuid,
  batch_id                text,
  warehouse_stock         numeric,
  expiration_date         date,
  reserved_for_machine_id uuid,
  is_reserved_here        boolean,
  created_at              timestamptz,
  reservation_priority    integer
)
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  WITH wh AS (
    SELECT m.primary_warehouse_id AS pri, m.secondary_warehouse_id AS sec
    FROM public.machines m WHERE m.machine_id = p_machine_id
  )
  SELECT vp.wh_inventory_id, vp.boonz_product_id, vp.warehouse_id, vp.batch_id,
         vp.warehouse_stock, vp.expiration_date, vp.reserved_for_machine_id,
         (vp.reserved_for_machine_id = p_machine_id) AS is_reserved_here,
         vp.created_at, vp.reservation_priority
  FROM public.v_wh_pickable vp
  CROSS JOIN wh
  WHERE vp.warehouse_id IN (wh.pri, wh.sec)                                   -- WHscope (sec may be NULL)
    AND (vp.reserved_for_machine_id IS NULL
         OR vp.reserved_for_machine_id = p_machine_id)                        -- RES
    AND (vp.expiration_date IS NULL OR vp.expiration_date >= p_plan_date);    -- EXP vs plan-date
$$;

-- ── A-3: scalar convenience aggregate (drop-in for the 4 forked pool sums) ────
CREATE OR REPLACE FUNCTION public.wh_available_qty(
  p_machine_id uuid, p_boonz_product_id uuid, p_plan_date date)
RETURNS numeric
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE(SUM(warehouse_stock), 0)
  FROM public.wh_available(p_machine_id, p_plan_date)
  WHERE boonz_product_id = p_boonz_product_id;
$$;

-- ── A-4: THE reconciled FEFO coverage function RC-01's push binds ─────────────
-- B1(a): return columns give RC-01 exactly (wh_inventory_id, expiration_date) to
--        pin + a running/coverage figure. ONE canonical name. No second signature.
-- B1(c): p_warehouse_ids is EXPLICIT. push passes ARRAY[WH_CENTRAL] for cold lines
--        and ARRAY[primary] for ambient (preserving current push routing). When
--        NULL, defaults to the machine's primary+secondary (matches wh_available).
-- B1(b): committed_elsewhere REUSES v_dispatch_availability.reserved_by_earlier —
--        the SAME CASE predicate (WH-origin, unpacked, unpicked, not
--        cancelled/skipped, pack_outcome<>'not_filled', Refill/Add New). For a
--        not-yet-inserted pin every existing live claim is "earlier", so the
--        (all-machines − same-machine) net collapses to: SUM of OTHER machines'
--        live claims for this boonz_product on this plan_date. Faithful to the
--        shipped view (no warehouse filter on the commitment sum — conservative:
--        it can only DECREASE availability, never oversubscribe). Two machines'
--        per-machine push runs therefore cannot both pin the same batch beyond stock.
CREATE OR REPLACE FUNCTION public.wh_fefo_for_line(
  p_machine_id       uuid,
  p_boonz_product_id uuid,
  p_plan_date        date,
  p_qty_needed       numeric,
  p_warehouse_ids    uuid[] DEFAULT NULL)
RETURNS TABLE (
  pick_rank               int,       -- 1 = FEFO first
  wh_inventory_id         uuid,      -- RC-01 binds from_wh_inventory_id
  warehouse_id            uuid,      -- route WH of the chosen batch (never hardcoded)
  batch_id                text,
  expiration_date         date,      -- RC-01 binds expiry_date
  warehouse_stock         numeric,   -- pickable units on this batch
  reserved_for_machine_id uuid,
  running_pickable        numeric,   -- FEFO cumulative pickable through this rank
  total_pickable          numeric,   -- route pool total for the SKU
  committed_elsewhere     numeric,   -- reserved_by_earlier net (other-machine live claims)
  net_running             numeric,   -- GREATEST(running_pickable - committed_elsewhere, 0)
  covers_line             boolean,   -- (running_pickable - committed_elsewhere) >= qty
  is_satisfiable          boolean    -- (total_pickable - committed_elsewhere) >= qty  (bind only if true)
)
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  WITH whset AS (
    SELECT COALESCE(
             p_warehouse_ids,
             (SELECT ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id]
                FROM public.machines m WHERE m.machine_id = p_machine_id)
           ) AS ids
  ),
  avail AS (
    SELECT vp.wh_inventory_id, vp.warehouse_id, vp.batch_id, vp.expiration_date,
           vp.warehouse_stock, vp.reserved_for_machine_id,
           ROW_NUMBER() OVER (ORDER BY vp.expiration_date ASC NULLS LAST,
                                       vp.created_at ASC, vp.wh_inventory_id) AS rk
    FROM public.v_wh_pickable vp
    CROSS JOIN whset
    WHERE vp.boonz_product_id = p_boonz_product_id
      AND vp.warehouse_id = ANY (whset.ids)                                    -- WHscope (explicit)
      AND (vp.reserved_for_machine_id IS NULL
           OR vp.reserved_for_machine_id = p_machine_id)                       -- RES
      AND (vp.expiration_date IS NULL OR vp.expiration_date >= p_plan_date)     -- EXP vs plan-date
  ),
  -- reserved_by_earlier REUSE (v_dispatch_availability, live 2026-07-18): SAME CASE
  -- predicate; other-machine live WH-origin unpacked/unpicked Refill/Add New claims
  -- for this product+plan_date. Do NOT fork/re-derive this netting.
  committed AS (
    SELECT COALESCE(SUM(rd.quantity), 0)::numeric AS qty
    FROM public.refill_dispatching rd
    WHERE rd.boonz_product_id = p_boonz_product_id
      AND rd.dispatch_date    = p_plan_date
      AND rd.machine_id      <> p_machine_id
      AND rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text])
      AND rd.packed    = false
      AND rd.picked_up = false
      AND rd.source_origin = 'warehouse'::public.source_origin_enum
      AND COALESCE(rd.cancelled, false) = false
      AND COALESCE(rd.skipped, false)   = false
      AND COALESCE(rd.pack_outcome::text, ''::text) <> 'not_filled'::text
  ),
  cume AS (
    SELECT a.*,
      SUM(a.warehouse_stock) OVER (ORDER BY a.rk ROWS UNBOUNDED PRECEDING) AS running_pickable,
      SUM(a.warehouse_stock) OVER () AS total_pickable
    FROM avail a
  )
  SELECT c.rk::int, c.wh_inventory_id, c.warehouse_id, c.batch_id, c.expiration_date,
         c.warehouse_stock, c.reserved_for_machine_id,
         c.running_pickable, c.total_pickable,
         cm.qty AS committed_elsewhere,
         GREATEST(c.running_pickable - cm.qty, 0)          AS net_running,
         ((c.running_pickable - cm.qty) >= p_qty_needed)   AS covers_line,
         ((c.total_pickable   - cm.qty) >= p_qty_needed)   AS is_satisfiable
  FROM cume c CROSS JOIN committed cm
  ORDER BY c.rk;
$$;

-- Read-only functions: keep grants aligned with v_wh_pickable's consumer roles.
GRANT EXECUTE ON FUNCTION public.wh_central_id()                                   TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.wh_available(uuid, date)                          TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.wh_available_qty(uuid, uuid, date)                TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.wh_fefo_for_line(uuid, uuid, date, numeric, uuid[]) TO anon, authenticated, service_role;

COMMIT;

-- RC-01 BINDING RECIPE (implemented in 20260718090002): for a warehouse-origin
-- Refill/Add New line, pin the EFFECTIVE FEFO-front batch after netting:
--   SELECT wh_inventory_id, expiration_date, warehouse_id
--     FROM public.wh_fefo_for_line(machine, boonz, plan_date, qty, ARRAY[route_wh])
--    WHERE is_satisfiable AND running_pickable > committed_elsewhere
--    ORDER BY pick_rank LIMIT 1;
-- No row  => not satisfiable => log procurement_gap (never pin beyond stock).
