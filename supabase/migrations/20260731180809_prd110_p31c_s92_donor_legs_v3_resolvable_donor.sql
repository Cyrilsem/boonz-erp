-- PRD-110 P3.1c / S-92 · resolve_m2m_donor_legs_v3 v2 -- resolvable-donor walk
-- Forward-only replacement of the v1 applied minutes earlier (Article 12: new migration,
-- never an edit of the applied one). v1 took the biggest donor and blocked when its SKU mix
-- was unknowable -- which is the common case at 2.4% shelf_composition coverage.
--
-- PRD-110 P3.1c / S-89 · resolve_m2m_donor_legs_v3 -- the rung-4 SEAM
--
-- WHY A SEAM AND NOT MORE INLINE CODE IN stitch_v3
-- S-89 asked for proof that stitch_v3's rung-4 branch works. It could not be obtained: across
-- all 544 live shelves the ladder terminates at rung 1 (383) or rung 2 (161) -- rungs 3-6 are
-- UNREACHABLE on real data, and all 3 partner_managed machines (the only op-model that
-- disables both warehouse rungs) have zero shelves in v_shelf_state. A branch that no input
-- can reach is a branch no fixture can prove. Lifting the body behind a callable seam makes
-- it reachable FOREVER, on real donors, without forcing the ladder or touching stock.
--
-- IT ALSO FIXES THREE DEFECTS THE UNREACHABILITY HID (all four are S-91):
--   D1 the ladder's payload names `donor_machines` as count(DISTINCT machine_id) -- an INT.
--      stitch_v3 tested jsonb_typeof(...)='array' and read UUIDs out of it, so the donor was
--      ALWAYS NULL and every m2m unit blocked as 'm2m_sku_unknown'. The branch could not
--      place a single unit. Donors now come from list_m2m_donors_v3, which names them.
--   D2 stitch_v3 blocked when the donor had no Remove rows -- bypassing the shelf_composition
--      fallback resolve_m2m_sku_legs_v3 ALREADY implements for p_lines IS NULL. We now pass
--      NULL deliberately in that case and let the callee use its own estimator path.
--   D3 the ladder's qty_resolved is LEAST(needed, SUM(excess) over ALL donors) but only ONE
--      donor is drawn from, so stitch could place more than the chosen donor holds. Clamped
--      to that donor's own excess here.
--   D4 resolve_m2m_sku_legs_v3 returns transfer AND return_to_wh legs. stitch_v3 looped over
--      every leg with qty>0 and inserted them all as Refill -- re-placing into the
--      destination exactly the units the helper had just ruled non-assortable or
--      over-headroom. Verified live on donor 46c0c29e/dest 558ad2f1: 13 transfer + 5
--      'dest_capacity_clamp' units, and all 18 would have been written as Refill rows.
--      ⛔ ONLY leg='transfer' crosses. Everything else is reported, never placed.
--
-- Read-only: STABLE + SECURITY INVOKER. Emits no rows; the caller writes the legs.

CREATE OR REPLACE FUNCTION public.resolve_m2m_donor_legs_v3(
  p_plan_date       date,
  p_dest_machine_id uuid,
  p_dest_shelf_id   uuid,
  p_pod_product_id  uuid,
  p_qty_needed      integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
DECLARE
  v_donor        record;
  v_lines        jsonb;
  v_lines_src    text;
  v_m2m          jsonb;
  v_cap          int;
  v_legs         jsonb;
  v_placeable    int;
  v_xfer_avail   int;
  v_nontransfer  jsonb;
  v_tried        int := 0;
  v_found        boolean := false;
  v_attempts     jsonb := '[]'::jsonb;
BEGIN
  IF p_plan_date IS NULL OR p_dest_shelf_id IS NULL OR p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'resolve_m2m_donor_legs_v3: plan_date, dest_shelf_id and pod_product_id are all required';
  END IF;
  IF COALESCE(p_qty_needed, 0) <= 0 THEN
    RAISE EXCEPTION 'resolve_m2m_donor_legs_v3: p_qty_needed must be > 0 (got %)', p_qty_needed;
  END IF;

  --------------------------------------------------------------------------
  -- 1+2. THE DONOR, AND ITS SKU MIX -- chosen together, not in sequence.
  --
  -- ⛔ S-92, found by EXECUTING this branch rather than reading it. Picking the
  --    biggest donor and then asking for its SKU mix blocks almost every time:
  --    shelf_composition covers 16 of 656 shelves (2.4%), so the largest-excess
  --    donor is overwhelmingly one whose mix is unknowable, and the units land in
  --    a Blocked row that names a donor we could never have drawn from. LAW 5 is
  --    satisfied by that row, but the answer is useless.
  --
  --    A donor is only a donor if we can say WHICH SKUs cross. So walk donors in
  --    excess order and take the first whose mix actually resolves. Every attempt
  --    is recorded, so a block says which donors were tried and why each failed
  --    rather than reporting only the last one.
  --
  --    Bounded at 10 candidates: this runs once per planned line, and an unbounded
  --    walk would turn one unresolvable pod into a fleet-wide scan.
  --------------------------------------------------------------------------
  FOR v_donor IN
    SELECT * FROM public.list_m2m_donors_v3(p_pod_product_id, p_dest_machine_id) LIMIT 10
  LOOP
    v_tried := v_tried + 1;

    -- D3: never promise more than THIS donor can give, whatever the ladder summed.
    v_cap := LEAST(p_qty_needed, v_donor.excess_units);
    IF v_cap <= 0 THEN
      v_attempts := v_attempts || jsonb_build_object(
        'donor_shelf_id', v_donor.donor_shelf_id, 'donor_shelf_code', v_donor.donor_shelf_code,
        'excess_units', v_donor.excess_units, 'outcome', 'no_donor_excess');
      CONTINUE;
    END IF;

    -- Prefer the donor's own Remove rows (they carry boonz_product_id); otherwise hand over
    -- NULL ON PURPOSE so resolve_m2m_sku_legs_v3 uses its shelf_composition path (D2).
    -- ⛔ NOT S-87's forbidden blind NULL call: S-87 forbids it where there is no fallback and
    --    the units would vanish. Here the fallback is the callee's documented behaviour and
    --    its 'source_composition_unknown' status is caught immediately below.
    SELECT jsonb_agg(jsonb_build_object('boonz_product_id', x.boonz_product_id, 'qty', x.qty))
      INTO v_lines
      FROM (SELECT rpo.boonz_product_id, SUM(rpo.quantity)::int AS qty
              FROM public.refill_plan_output rpo
             WHERE rpo.plan_date = p_plan_date
               AND rpo.shelf_id  = v_donor.donor_shelf_id
               AND lower(rpo.action) = 'remove'
               AND rpo.boonz_product_id IS NOT NULL
             GROUP BY rpo.boonz_product_id
            HAVING SUM(rpo.quantity) > 0) x;

    v_lines_src := CASE WHEN v_lines IS NULL THEN 'shelf_composition_via_callee'
                        ELSE 'donor_remove_rows' END;

    v_m2m := public.resolve_m2m_sku_legs_v3(v_donor.donor_shelf_id, p_dest_shelf_id, v_lines);

    IF COALESCE(v_m2m->>'status', '') = 'ok'
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_m2m->'legs', '[]'::jsonb)) e
                    WHERE e->>'leg' = 'transfer' AND COALESCE((e->>'qty')::int, 0) > 0) THEN
      v_found := true;
      v_attempts := v_attempts || jsonb_build_object(
        'donor_shelf_id', v_donor.donor_shelf_id, 'donor_shelf_code', v_donor.donor_shelf_code,
        'excess_units', v_donor.excess_units, 'lines_source', v_lines_src, 'outcome', 'ok');
      EXIT;
    END IF;

    v_attempts := v_attempts || jsonb_build_object(
      'donor_shelf_id', v_donor.donor_shelf_id, 'donor_shelf_code', v_donor.donor_shelf_code,
      'excess_units', v_donor.excess_units, 'lines_source', v_lines_src,
      'outcome', COALESCE(NULLIF(v_m2m->>'status', 'ok'), 'no_transferable_legs'));
  END LOOP;

  IF v_tried = 0 THEN
    RETURN jsonb_build_object(
      'status', 'no_donor',
      'pod_product_id', p_pod_product_id,
      'qty_needed', p_qty_needed,
      'note', 'no sibling machine holds this pod above its 7-day cover floor');
  END IF;

  IF NOT v_found THEN
    RETURN jsonb_build_object(
      'status', 'no_resolvable_donor',
      'pod_product_id', p_pod_product_id,
      'qty_needed', p_qty_needed,
      'donors_tried', v_tried,
      'attempts', v_attempts,
      'note', 'donors exist but none could name the SKUs that would cross; widen '
              'shelf_composition coverage or plan a Remove on the donor shelf');
  END IF;

  --------------------------------------------------------------------------
  -- 3. ⛔ D4. ONLY leg='transfer' may cross. return_to_wh legs are units the
  --    callee ruled non-assortable or over-headroom; placing them would be the
  --    exact incident resolve_m2m_sku_legs_v3 exists to prevent. They are
  --    reported for the reasoning blob and left for the caller to block.
  --    The cumulative clamp mirrors the callee's own alloc idiom so the two
  --    stay comparable, and the ordering (qty DESC, sku) is deterministic.
  --------------------------------------------------------------------------
  WITH t AS (
    SELECT (e->>'boonz_product_id')::uuid AS sku,
           (e->>'qty')::int               AS qty
      FROM jsonb_array_elements(COALESCE(v_m2m->'legs', '[]'::jsonb)) e
     WHERE e->>'leg' = 'transfer'
       AND COALESCE((e->>'qty')::int, 0) > 0
  ),
  r AS (
    SELECT t.sku, t.qty,
           SUM(t.qty) OVER (ORDER BY t.qty DESC, t.sku
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum
      FROM t
  ),
  a AS (
    SELECT r.sku, GREATEST(0, LEAST(r.qty, v_cap - (r.cum - r.qty)))::int AS q
      FROM r
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('boonz_product_id', a.sku, 'qty', a.q)
                            ORDER BY a.q DESC, a.sku), '[]'::jsonb),
         COALESCE(SUM(a.q), 0)::int
    INTO v_legs, v_placeable
    FROM a WHERE a.q > 0;

  SELECT COALESCE(SUM((e->>'qty')::int), 0)::int
    INTO v_xfer_avail
    FROM jsonb_array_elements(COALESCE(v_m2m->'legs', '[]'::jsonb)) e
   WHERE e->>'leg' = 'transfer';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'boonz_product_id', e->>'boonz_product_id',
             'qty',    (e->>'qty')::int,
             'reason', e->>'reason')), '[]'::jsonb)
    INTO v_nontransfer
    FROM jsonb_array_elements(COALESCE(v_m2m->'legs', '[]'::jsonb)) e
   WHERE e->>'leg' <> 'transfer'
     AND COALESCE((e->>'qty')::int, 0) > 0;

  RETURN jsonb_build_object(
    'status',            'ok',
    'donor',             to_jsonb(v_donor),
    'dest_shelf_id',     p_dest_shelf_id,
    'pod_product_id',    p_pod_product_id,
    'qty_needed',        p_qty_needed,
    'donor_excess',      v_donor.excess_units,
    'qty_cap',           v_cap,
    'lines_source',      v_lines_src,
    'donors_tried',      v_tried,
    'attempts',          v_attempts,
    'legs',              COALESCE(v_legs, '[]'::jsonb),
    'units_placeable',   COALESCE(v_placeable, 0),
    'transfer_available', v_xfer_avail,
    'not_transferred',   v_nontransfer,
    'm2m',               v_m2m,
    'notes', jsonb_build_array(
      'ONLY leg=transfer crosses; return_to_wh legs are reported here and blocked by the caller (D4)',
      'placement is clamped to the CHOSEN donor''s excess, not the fleet-wide sum the ladder reports (D3)',
      'read-only: the caller writes the rows'));
END;
$fn$;

COMMENT ON FUNCTION public.resolve_m2m_donor_legs_v3(date, uuid, uuid, uuid, integer) IS
'PRD-110 P3.1c rung-4 seam. Names a donor, clamps to ITS excess, and returns transfer-only SKU
legs. Exists because rung 4 is unreachable via the ladder on live data (544/544 shelves stop at
rung 1-2), so the branch was unprovable inline. Fixes S-91 D1-D4.';

REVOKE ALL ON FUNCTION public.resolve_m2m_donor_legs_v3(date, uuid, uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_m2m_donor_legs_v3(date, uuid, uuid, uuid, integer)
  TO authenticated, service_role;
