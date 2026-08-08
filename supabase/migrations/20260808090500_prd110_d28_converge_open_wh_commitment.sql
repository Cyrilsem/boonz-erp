-- PRD-110 · D-28 · leg 149 · THE CONVERGENCE
--
-- CS ruling (2026-08-01): "D-28 -> CONVERGE `committed_elsewhere` onto `v_dispatch_availability`.
-- Own reviewed unit; before/after diff of FEFO-visible availability for the live binder logged."
--
-- WHAT CONVERGES: the PREDICATE. Which refill_dispatching rows count as an open warehouse
-- commitment was written THREE times - once in wh_fefo_for_line's `committed` CTE and twice
-- inside v_dispatch_availability's two window sums - as seven identical clauses each time.
-- After this migration it is written ONCE, in public.v_dispatch_open_wh_commitment, and both
-- objects read it. That is the Article-16 substance of Cody's P3.1d raise.
--
-- ⛔⛔ WHAT DOES NOT CONVERGE, AND WHY IT CANNOT (D-28 half 2, PARKED with a sharpened ask):
--    v_dispatch_availability.reserved_by_earlier is a window sum over rows that ALREADY EXIST,
--    ordered by dispatch_id. wh_fefo_for_line is called at PUSH instant, BEFORE its own row is
--    inserted - there is no dispatch_id for it to be "earlier" than, so the arithmetic is
--    ill-defined at the call site. And refill_dispatching.dispatch_id is
--    `uuid DEFAULT gen_random_uuid()`: the view's "queue" is a RANDOM tiebreak, not
--    first-come-first-served (leg 148's addendum called it FCFS - it is not; S-280).
--    Fixture 70 seq 27/28/29 pin all three facts so the arithmetic cannot be quietly converged
--    later without the Article-16 review that choice needs.
--
-- ⭐ THE BEFORE/AFTER DIFF THE RULING ASKED FOR IS IN FIXTURE 70, CONSTRUCTED NOT READ.
--    Leg 148 measured it off live data and it is vacuous: `open_wh_lines` is 0 on EVERY
--    dispatch_date in the last 60 days, because packing closes inside the session that pushes.
--    Fixture 70 makes the contest - 21 units, three open lines for 40/30/25 - and measures:
--    symmetric side 0 lines undiscounted / 0 satisfiable; canonical side exactly 1 line
--    undiscounted / exactly 1 not blocked_no_wh. Same data, different winner.
--
-- INVARIANCE: fixture 70 seq 18-22 recompute the PRE-convergence formula literally (from the
-- b3cfeb77 body) inside the fixture and compare it to what the converged function returns, on
-- all three lines. A refactor that changes behaviour is not a refactor.
--
-- LAW 3: Cody-reviewed. No protected-entity write; no engine body touched; no flag flipped.

-- ============================================================================
-- 1. THE CANONICAL OBJECT
-- ============================================================================
-- ⛔ NOT security_invoker, deliberately. v_dispatch_availability is postgres-owned and reads
--    refill_dispatching with OWNER privileges today; an inner security_invoker view would apply
--    the READER's RLS instead and hand anon a reserved_by_earlier of 0 where it reads a real
--    number now. Fixture 70 seq 17 asserts the absence of the option, not merely its value.
CREATE OR REPLACE VIEW public.v_dispatch_open_wh_commitment AS
SELECT
  rd.dispatch_id,
  rd.machine_id,
  rd.boonz_product_id,
  rd.dispatch_date,
  rd.quantity
FROM public.refill_dispatching rd
WHERE rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text])
  AND rd.packed    = false
  AND rd.picked_up = false
  AND rd.source_origin = 'warehouse'::public.source_origin_enum
  AND COALESCE(rd.cancelled, false) = false
  AND COALESCE(rd.skipped,   false) = false
  AND COALESCE(rd.pack_outcome::text, ''::text) <> 'not_filled'::text;

COMMENT ON VIEW public.v_dispatch_open_wh_commitment IS
  'PRD-110 D-28 (leg 149). CANONICAL: the rows that count as an OPEN WAREHOUSE COMMITMENT - a '
  'dispatch line that has not been packed or picked up, is sourced from a warehouse, and has not '
  'been cancelled, skipped or marked not_filled. Consumed by wh_fefo_for_line (committed_elsewhere) '
  'and v_dispatch_availability (reserved_by_earlier). ⛔ The two consumers AGGREGATE it differently '
  'on purpose and that divergence is NOT converged: the binder runs before its own row exists and '
  'discounts a line by the whole rest of the field (symmetric); the view charges a row only for '
  'competitors with a lower dispatch_id - a RANDOM uuid, not an arrival order. See PRD-110 D-28 '
  'half 2 and golden fixture 70.';

-- S-268: REVOKE ... FROM PUBLIC does NOT remove Supabase's schema default privileges. anon must
-- be named explicitly or it keeps SELECT and the convergence widens what an unauthenticated
-- caller of wh_fefo_for_line can see.
REVOKE ALL ON public.v_dispatch_open_wh_commitment FROM PUBLIC;
REVOKE ALL ON public.v_dispatch_open_wh_commitment FROM anon;
GRANT SELECT ON public.v_dispatch_open_wh_commitment TO authenticated, service_role;

-- ============================================================================
-- 2. CONSUMER 1 — wh_fefo_for_line
-- ============================================================================
-- ⭐ CODY R1 (DR-8 precedent, CLAUDE.md repurpose_machine foot-gun): CREATE OR REPLACE does NOT
--    replace across a differing signature - it silently OVERLOADS. This guard runs BEFORE the
--    CREATE and refuses the whole transaction if the shape on disk is not the shape assumed here,
--    including pronargdefaults (a lost DEFAULT on p_warehouse_ids breaks every 4-arg caller -
--    the exact Wave-2 confirm outage).
DO $guard$
DECLARE
  v_n int; v_args text; v_defs int;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'wh_fefo_for_line';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-28 guard: expected exactly 1 wh_fefo_for_line, found % - resolve the overload before replacing', v_n;
  END IF;

  SELECT pg_get_function_identity_arguments(p.oid), p.pronargdefaults
    INTO v_args, v_defs
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'wh_fefo_for_line';

  IF v_args <> 'p_machine_id uuid, p_boonz_product_id uuid, p_plan_date date, p_qty_needed numeric, p_warehouse_ids uuid[]' THEN
    RAISE EXCEPTION 'D-28 guard: wh_fefo_for_line signature drifted: %', v_args;
  END IF;
  IF v_defs <> 1 THEN
    RAISE EXCEPTION 'D-28 guard: wh_fefo_for_line lost its p_warehouse_ids DEFAULT (pronargdefaults=%)', v_defs;
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION public.wh_fefo_for_line(
  p_machine_id       uuid,
  p_boonz_product_id uuid,
  p_plan_date        date,
  p_qty_needed       numeric,
  p_warehouse_ids    uuid[] DEFAULT NULL::uuid[])
RETURNS TABLE(
  pick_rank               integer,
  wh_inventory_id         uuid,
  warehouse_id            uuid,
  batch_id                text,
  expiration_date         date,
  warehouse_stock         numeric,
  reserved_for_machine_id uuid,
  running_pickable        numeric,
  total_pickable          numeric,
  committed_elsewhere     numeric,
  net_running             numeric,
  covers_line             boolean,
  is_satisfiable          boolean)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
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
      AND vp.warehouse_id = ANY (whset.ids)
      AND (vp.reserved_for_machine_id IS NULL
           OR vp.reserved_for_machine_id = p_machine_id)
      AND (vp.expiration_date IS NULL OR vp.expiration_date >= p_plan_date)
  ),
  -- ⭐ D-28: the seven-clause predicate that used to live here is now ONE canonical object.
  --    What this CTE still owns - and must own, because it is the binder's own policy - is the
  --    SHAPE of the discount: every OTHER machine's open line for the same product and date,
  --    summed whole. Symmetric and order-independent. See the view comment for why the
  --    canonical object's own asymmetric window is NOT what a pre-insert caller can use.
  committed AS (
    SELECT COALESCE(SUM(oc.quantity), 0)::numeric AS qty
    FROM public.v_dispatch_open_wh_commitment oc
    WHERE oc.boonz_product_id = p_boonz_product_id
      AND oc.dispatch_date    = p_plan_date
      AND oc.machine_id      <> p_machine_id
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
$function$;

-- ============================================================================
-- 3. CONSUMER 2 — v_dispatch_availability
-- ============================================================================
-- ⛔ CREATE OR REPLACE VIEW cannot reorder, rename or drop output columns. The SELECT list below
--    is byte-for-byte the existing one; only dispatch_with_meta's two window sums change, from a
--    CASE repeating the seven clauses to COALESCE(oc.quantity, 0) off a LEFT JOIN on the primary
--    key. dispatch_id is the PK of refill_dispatching, so the join can never multiply a row, and
--    SUM ignoring a NULL is the same total as SUM adding a 0.
CREATE OR REPLACE VIEW public.v_dispatch_availability AS
 WITH wh_avail AS (
         SELECT rd.machine_id,
            rd.boonz_product_id,
            COALESCE(sum(wp.warehouse_stock), 0::numeric)::integer AS stock_now
           FROM ( SELECT DISTINCT refill_dispatching.machine_id,
                    refill_dispatching.boonz_product_id
                   FROM refill_dispatching
                  WHERE refill_dispatching.boonz_product_id IS NOT NULL) rd
             JOIN machines m ON m.machine_id = rd.machine_id
             LEFT JOIN v_wh_pickable wp ON wp.boonz_product_id = rd.boonz_product_id AND (wp.warehouse_id = ANY (ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id])) AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = rd.machine_id)
          GROUP BY rd.machine_id, rd.boonz_product_id
        ), dispatch_with_meta AS (
         SELECT rd.dispatch_id,
            rd.machine_id,
            rd.shelf_id,
            rd.pod_product_id,
            rd.boonz_product_id,
            rd.dispatch_date,
            rd.action,
            rd.quantity,
            rd.filled_quantity,
            rd.expiry_date,
            rd.item_added,
            rd.dispatched,
            rd.comment,
            rd.include,
            rd.created_at,
            rd.packed,
            rd.picked_up,
            rd.returned,
            rd.return_reason,
            rd.expiry_warning,
            rd.from_warehouse_id,
            rd.to_warehouse_id,
            rd.from_wh_inventory_id,
            rd.driver_confirmed_qty,
            rd.driver_confirmed_at,
            rd.driver_confirmed_by,
            rd.driver_confirmed_breakdown,
            rd.wh_approved_at,
            rd.wh_approved_by,
            rd.is_m2m,
            rd.m2m_partner_id,
            rd.m2m_transfer_id,
            rd.source_origin,
            rd.from_machine_id,
            (COALESCE(sum(COALESCE(oc.quantity, 0::numeric))
                 OVER (PARTITION BY rd.boonz_product_id, rd.dispatch_date
                       ORDER BY rd.dispatch_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::numeric)
           - COALESCE(sum(COALESCE(oc.quantity, 0::numeric))
                 OVER (PARTITION BY rd.boonz_product_id, rd.dispatch_date, rd.machine_id
                       ORDER BY rd.dispatch_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::numeric))::integer AS reserved_by_earlier
           FROM refill_dispatching rd
             LEFT JOIN v_dispatch_open_wh_commitment oc ON oc.dispatch_id = rd.dispatch_id
        )
 SELECT d.dispatch_id,
    d.machine_id,
    d.shelf_id,
    d.pod_product_id,
    d.boonz_product_id,
    d.dispatch_date,
    d.action,
    d.quantity AS target_qty,
    d.source_origin,
    d.from_machine_id,
    d.packed,
    d.picked_up,
    d.dispatched,
    d.returned,
    d.comment,
    COALESCE(wh.stock_now, 0) AS wh_stock_now,
    d.reserved_by_earlier,
        CASE
            WHEN d.source_origin = ANY (ARRAY['internal_transfer'::source_origin_enum, 'vox_at_venue'::source_origin_enum]) THEN d.quantity::integer
            WHEN d.action = ANY (ARRAY['Remove'::text, 'Machine To Warehouse'::text]) THEN d.quantity::integer
            ELSE LEAST(d.quantity, GREATEST(COALESCE(wh.stock_now, 0) - d.reserved_by_earlier, 0)::numeric)::integer
        END AS available_qty,
        CASE
            WHEN d.packed THEN 'packed'::text
            WHEN d.source_origin = ANY (ARRAY['internal_transfer'::source_origin_enum, 'vox_at_venue'::source_origin_enum]) THEN 'ready'::text
            WHEN d.action = ANY (ARRAY['Remove'::text, 'Machine To Warehouse'::text]) THEN 'ready'::text
            WHEN (COALESCE(wh.stock_now, 0) - d.reserved_by_earlier)::numeric >= d.quantity THEN 'ready'::text
            WHEN (COALESCE(wh.stock_now, 0) - d.reserved_by_earlier) > 0 THEN 'partial'::text
            ELSE 'blocked_no_wh'::text
        END AS pack_status,
        CASE
            WHEN d.source_origin = ANY (ARRAY['internal_transfer'::source_origin_enum, 'vox_at_venue'::source_origin_enum]) THEN false
            WHEN d.action = ANY (ARRAY['Remove'::text, 'Machine To Warehouse'::text]) THEN false
            WHEN d.packed THEN false
            ELSE d.quantity > GREATEST(COALESCE(wh.stock_now, 0) - d.reserved_by_earlier, 0)::numeric
        END AS oversubscribed
   FROM dispatch_with_meta d
     LEFT JOIN wh_avail wh ON wh.machine_id = d.machine_id AND wh.boonz_product_id = d.boonz_product_id;

-- ============================================================================
-- 4. POST-CONDITIONS — re-asserted in the SAME transaction that made the change
-- ============================================================================
DO $post$
DECLARE
  v_n int; v_defs int; v_src text; v_vdef text;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'wh_fefo_for_line';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-28 post: wh_fefo_for_line was OVERLOADED, not replaced (% copies)', v_n;
  END IF;

  SELECT p.pronargdefaults, p.prosrc INTO v_defs, v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'wh_fefo_for_line';
  IF v_defs <> 1 THEN
    RAISE EXCEPTION 'D-28 post: p_warehouse_ids DEFAULT lost (pronargdefaults=%)', v_defs;
  END IF;
  IF v_src ~* 'refill_dispatching' THEN
    RAISE EXCEPTION 'D-28 post: wh_fefo_for_line still names refill_dispatching - the inline copy survived';
  END IF;
  IF v_src !~* 'committed_elsewhere' THEN
    RAISE EXCEPTION 'D-28 post: wh_fefo_for_line no longer returns committed_elsewhere';
  END IF;

  SELECT pg_get_viewdef(c.oid, true) INTO v_vdef
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'v_dispatch_availability';
  IF v_vdef ~* 'not_filled' THEN
    RAISE EXCEPTION 'D-28 post: v_dispatch_availability still carries the inline predicate';
  END IF;
  IF v_vdef !~* 'v_dispatch_open_wh_commitment' THEN
    RAISE EXCEPTION 'D-28 post: v_dispatch_availability does not read the canonical object';
  END IF;

  IF has_table_privilege('anon', 'public.v_dispatch_open_wh_commitment', 'SELECT') THEN
    RAISE EXCEPTION 'D-28 post: anon retained SELECT on the canonical view (S-268)';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.v_dispatch_open_wh_commitment', 'SELECT') THEN
    RAISE EXCEPTION 'D-28 post: authenticated cannot read the canonical view - invoker-rights callers of wh_fefo_for_line would break';
  END IF;
END $post$;
