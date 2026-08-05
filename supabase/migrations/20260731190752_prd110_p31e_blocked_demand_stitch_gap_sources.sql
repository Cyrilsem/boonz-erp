-- PRD-110 · P3.1e · migration A — the stitch gap source for the blocked_demand ledger
--
-- BUILD SPEC P0.5 names THREE writers of the ledger: engine_add_pod (shipped, cron 43),
-- stitch (procurement_alerts) and the FEFO-bind step (unbound rows). engine_add has been
-- live since P0.5; this migration builds the SECOND and THIRD. They are one source, not two,
-- because after P3.1d the FEFO bind happens INSIDE stitch_v3 and its unbound rows land in
-- the same shadow output.
--
-- ⛔ NOTHING here writes. All three objects are read-only (SQL/plpgsql STABLE or IMMUTABLE).
--    The only writer of blocked_demand remains the canonical record_blocked_demand_v3.
-- ⛔ LAW 6 is respected by construction: warehouse stock is never read here at all. This
--    reads stitch's OWN output, which already resolved supply through the canonical ladder.

------------------------------------------------------------------------------------
-- (1) THE MAPPING. This is the design decision P3.1e exists to make, so it gets its
--     own named, independently testable object rather than being buried in a CASE
--     inside a bigger query.
--
--     stitch_v3 computes RICH named reasons ('m2m_donor_capped', 'spot_buy_candidate',
--     'no_pickable_batch_in_scope', ...). blocked_demand.reason is a FOUR-value CHECK
--     constraint that procurement's worklist is built on. The mapping is therefore lossy
--     BY DESIGN, and the loss is compensated: _blocked_demand_gaps_stitch_v3 always
--     carries the original named reason through into reasoning->'components', so no
--     diagnosis ever depends on the enum alone.
--
--     The organising question is NOT "what went wrong" but "what must a human DO":
--       blocked_no_wh          -> BUY it: nothing on hand, here or anywhere in the fleet
--       partial_wh_limited     -> BUY the balance: some stock served, not enough
--       routing_gap            -> MOVE it: the units exist but cannot legally reach here
--       substitution_exhausted -> DECIDE: no product can serve this shelf as configured
------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._blocked_demand_reason_map_v3(p_named text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    -- Already the ledger's own vocabulary (stitch emits 'partial_wh_limited' directly, and
    -- rung 6 defaults to 'substitution_exhausted'). Identity, never re-derived.
    WHEN p_named IN ('blocked_no_wh','partial_wh_limited','substitution_exhausted','routing_gap')
      THEN p_named

    -- Rung 5. The ladder found the item PURCHASABLE, which means it found none on hand.
    -- The action is to buy it, so it is a no-stock row and not a routing one.
    WHEN p_named = 'spot_buy_candidate' THEN 'blocked_no_wh'

    -- Rung 4, no donor at all: the warehouses are empty AND no sibling machine holds a
    -- spare unit. Nothing to move, so this is a buy, not a transfer.
    WHEN p_named IN ('m2m_no_donor','m2m_no_donor_excess') THEN 'blocked_no_wh'

    -- Rung 4, a donor DOES exist but the units could not legally cross (destination
    -- assortment, headroom clamp, or an unresolved donor). Stock exists; the route does
    -- not. ⛔ Escaped underscore: bare 'm2m_%' would make LIKE treat _ as a wildcard.
    WHEN p_named LIKE 'm2m\_%' THEN 'routing_gap'

    -- The FEFO seam (P3.1d). The ladder counted supply that no batch could NAME.
    -- ⛔ S-63: sentinels are not supply, so all_batches_sentinel is a genuine empty.
    WHEN p_named IN ('no_pickable_batch_in_scope','all_batches_sentinel') THEN 'blocked_no_wh'

    -- The FEFO seam, warehouse side: the machine has no primary warehouse, or none of the
    -- warehouses in scope hold the pod. Stock may well exist; it has nowhere to come from.
    WHEN p_named IN ('no_primary_warehouse','no_warehouse_in_scope') THEN 'routing_gap'

    -- The FEFO seam, partial: batches bound, but fewer units than the ladder promised.
    WHEN p_named IN ('fefo_ceiling_exhausted','fefo_short') THEN 'partial_wh_limited'

    -- The FEFO seam, identity: the pod has no Active variant it could even BE. That is an
    -- assortment decision, not a supply one.
    WHEN p_named = 'no_active_variants' THEN 'substitution_exhausted'

    -- ⛔ Deliberate default, matching stitch_v3's own fallback. An unmapped reason is never
    --    dropped: the caller carries the original string into reasoning->'components', so a
    --    new named reason shows up as a diagnosable row rather than a silent miscategory.
    ELSE 'substitution_exhausted'
  END
$function$;

COMMENT ON FUNCTION public._blocked_demand_reason_map_v3(text) IS
  'PRD-110 P3.1e. Maps a stitch_v3 named reason onto the four-value blocked_demand.reason '
  'enum, organised by the action a human must take. Lossy by design; the original named '
  'reason is always preserved in blocked_demand.reasoning->''components''.';

REVOKE ALL ON FUNCTION public._blocked_demand_reason_map_v3(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._blocked_demand_reason_map_v3(text) TO authenticated, service_role;


------------------------------------------------------------------------------------
-- (2) THE STITCH GAP SOURCE. Same RETURNS TABLE shape as _blocked_demand_gaps_v3 so the
--     canonical writer can consume either without knowing which it holds.
--
-- ⭐ TWO ROW KINDS, ONE LEDGER ROW. The unique index uq_blocked_demand_open keys on
--    (plan_date, machine_id, shelf_id, pod_product_id, source), so a shelf gets exactly one
--    open row per source. That is the right grain for procurement, and it forces the merge:
--      'unplaced' = an explicit Blocked row; the ladder placed nothing for these units.
--      'unbound'  = a row that DOES ship, at qty > 0, but which no batch could name a SKU
--                   for (P3.1d). On a real plan date that means no pickable batch exists,
--                   so the unit is just as unservable as an unplaced one.
--    Both are demand that no nameable warehouse batch can serve, which is exactly what the
--    ledger is for, so qty_blocked is their SUM - and reasoning splits it back out into
--    qty_unplaced / qty_unbound so the two are never confused downstream.
--
-- ⛔ Keyed on anchor_pod_product_id, not pod_product_id. A rung-2 substitution emits its
--    rows against the SUBSTITUTE pod while the Blocked row carries the ANCHOR; keying on
--    the emitted pod would split one shelf's demand into two ledger rows that each look
--    like a separate problem. The anchor is the demand that was actually unmet.
------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._blocked_demand_gaps_stitch_v3(p_plan_date date)
RETURNS TABLE(machine_id uuid, shelf_id uuid, pod_product_id uuid,
              qty_blocked integer, reason text, reasoning jsonb)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  WITH latest AS (
    -- The run to promote is stitch's OWN latest for the date. ⛔ (produced_at, run_id)
    -- descending is the same total order stitch_v3 uses to pick its source run: several
    -- runs can share a produced_at, and run_id breaks the tie deterministically instead of
    -- leaving the choice to physical row order. Promoting a stale run would resurrect gaps
    -- the newest run has already solved.
    SELECT o.run_id
      FROM public.refill_plan_output_shadow o
     WHERE o.engine_tag = 'stitch_v3'
       AND o.plan_date  = p_plan_date
     ORDER BY o.produced_at DESC, o.run_id DESC
     LIMIT 1
  ),
  parts AS (
    -- (a) units the ladder could not place at all
    SELECT o.machine_id,
           o.shelf_id,
           COALESCE(o.anchor_pod_product_id, o.pod_product_id) AS pod_product_id,
           o.qty::int                                          AS qty,
           'unplaced'::text                                    AS row_kind,
           COALESCE(o.reasoning->>'reason','substitution_exhausted') AS named_reason,
           o.resolved_rung,
           o.rung_no,
           o.pod_product_id                                    AS emitted_pod_product_id
      FROM public.refill_plan_output_shadow o
      JOIN latest l ON l.run_id = o.run_id
     WHERE o.action = 'Blocked'
       AND o.qty > 0

    UNION ALL

    -- (b) units placed but whose SKU no batch could name - the FEFO-bind writer of P0.5
    SELECT o.machine_id,
           o.shelf_id,
           COALESCE(o.anchor_pod_product_id, o.pod_product_id),
           o.qty::int,
           'unbound'::text,
           COALESCE(o.reasoning->>'unbound_reason','unknown'),
           o.resolved_rung,
           o.rung_no,
           o.pod_product_id
      FROM public.refill_plan_output_shadow o
      JOIN latest l ON l.run_id = o.run_id
     WHERE o.reasoning->>'sku_binding' = 'unbound'
       AND o.qty > 0
  ),
  mapped AS (
    SELECT p.*, public._blocked_demand_reason_map_v3(p.named_reason) AS enum_reason
      FROM parts p
  ),
  by_enum AS (
    -- Aggregate to (shelf, enum) FIRST. Picking the reason straight off the largest single
    -- component would let three small blocked_no_wh parts lose to one larger routing_gap.
    SELECT m.machine_id, m.shelf_id, m.pod_product_id, m.enum_reason, SUM(m.qty)::int AS qty_enum
      FROM mapped m
     GROUP BY 1,2,3,4
  ),
  pick AS (
    -- The merged row's enum: most units wins; ties break on a fixed severity rank and then
    -- alphabetically, so identical input always produces an identical row.
    SELECT DISTINCT ON (b.machine_id, b.shelf_id, b.pod_product_id)
           b.machine_id, b.shelf_id, b.pod_product_id, b.enum_reason
      FROM by_enum b
     ORDER BY b.machine_id, b.shelf_id, b.pod_product_id, b.qty_enum DESC,
              CASE b.enum_reason WHEN 'blocked_no_wh'          THEN 1
                                 WHEN 'substitution_exhausted' THEN 2
                                 WHEN 'routing_gap'            THEN 3
                                 ELSE 4 END,
              b.enum_reason
  )
  SELECT m.machine_id,
         m.shelf_id,
         m.pod_product_id,
         SUM(m.qty)::int AS qty_blocked,
         pk.enum_reason  AS reason,
         jsonb_build_object(
           'run_id',        (SELECT l.run_id FROM latest l),
           'machine_name',  min(mc.official_name),
           'shelf_code',    min(sc.shelf_code),
           'qty_unplaced',  COALESCE(SUM(m.qty) FILTER (WHERE m.row_kind = 'unplaced'), 0)::int,
           'qty_unbound',   COALESCE(SUM(m.qty) FILTER (WHERE m.row_kind = 'unbound'),  0)::int,
           'components',    jsonb_agg(jsonb_build_object(
                              'row_kind',               m.row_kind,
                              'named_reason',           m.named_reason,
                              'enum_reason',            m.enum_reason,
                              'qty',                    m.qty,
                              'terminal_rung',          m.resolved_rung,
                              'rung_no',                m.rung_no,
                              'emitted_pod_product_id', m.emitted_pod_product_id)
                              ORDER BY m.row_kind, m.named_reason, m.qty DESC),
           'derived_by',    '_blocked_demand_gaps_stitch_v3 from refill_plan_output_shadow (engine_tag=stitch_v3)',
           'semantics',     'qty_blocked = unplaced (ladder placed nothing) + unbound (placed, but no batch could name the SKU). Both are demand no nameable warehouse batch can serve.'
         ) AS reasoning
    FROM mapped m
    JOIN pick pk
      ON pk.machine_id = m.machine_id AND pk.shelf_id = m.shelf_id
     AND pk.pod_product_id = m.pod_product_id
    -- PK joins only; 1:1, no fan-out, and ⛔ never through product_mapping (LAW 6 / S-67).
    JOIN public.machines             mc ON mc.machine_id = m.machine_id
    JOIN public.shelf_configurations sc ON sc.shelf_id   = m.shelf_id
   GROUP BY m.machine_id, m.shelf_id, m.pod_product_id, pk.enum_reason
$function$;

COMMENT ON FUNCTION public._blocked_demand_gaps_stitch_v3(date) IS
  'PRD-110 P3.1e. Gap source for source=stitch: the latest stitch_v3 shadow run''s Blocked '
  'rows (unplaced) plus its FEFO-unbound rows, merged one row per shelf on the ANCHOR pod. '
  'Read-only; the canonical writer record_blocked_demand_v3 owns every INSERT.';

REVOKE ALL ON FUNCTION public._blocked_demand_gaps_stitch_v3(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._blocked_demand_gaps_stitch_v3(date) TO authenticated, service_role;


------------------------------------------------------------------------------------
-- (3) THE DISPATCHER. record_blocked_demand_v3 references its gap source in THREE places
--     (the count, the upsert, and the stale-close NOT EXISTS). Routing once, here, keeps
--     those three in lockstep forever and means the writer's body changes by exactly one
--     identifier per call site.
--
-- ⛔ plpgsql with an explicit IF, not a SQL UNION ALL with WHERE p_source = '...'. The
--    UNION form reads well but relies on the planner proving a constant qual false to avoid
--    executing the other branch's set-returning function; an explicit branch is guaranteed.
------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._blocked_demand_gaps_for_source_v3(p_plan_date date, p_source text)
RETURNS TABLE(machine_id uuid, shelf_id uuid, pod_product_id uuid,
              qty_blocked integer, reason text, reasoning jsonb)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
BEGIN
  IF p_source = 'engine_add' THEN
    RETURN QUERY SELECT * FROM public._blocked_demand_gaps_v3(p_plan_date);
  ELSIF p_source = 'stitch' THEN
    RETURN QUERY SELECT * FROM public._blocked_demand_gaps_stitch_v3(p_plan_date);
  ELSE
    -- 'pack' is a valid blocked_demand.source but has no gap source yet (P4.4b).
    RAISE EXCEPTION '_blocked_demand_gaps_for_source_v3: no gap source implemented for source %', p_source;
  END IF;
END
$function$;

COMMENT ON FUNCTION public._blocked_demand_gaps_for_source_v3(date, text) IS
  'PRD-110 P3.1e. Routes record_blocked_demand_v3 to the gap source for a given '
  'blocked_demand.source. engine_add -> _blocked_demand_gaps_v3 (P0.5, unchanged), '
  'stitch -> _blocked_demand_gaps_stitch_v3 (P3.1e). pack raises until P4.4b.';

REVOKE ALL ON FUNCTION public._blocked_demand_gaps_for_source_v3(date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._blocked_demand_gaps_for_source_v3(date, text) TO authenticated, service_role;
