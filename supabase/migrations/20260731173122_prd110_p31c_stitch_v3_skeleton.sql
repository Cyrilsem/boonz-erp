-- PRD-110 P3.1c — stitch_v3 SKELETON (first leg of a multi-leg port; S-62)
--
-- Consumes the pod-grain output of engine_add_pod_v3 (pod_refills_shadow), drives every
-- positive line through resolve_supply_ladder_v3, and writes SKU-grain lines to
-- refill_plan_output_shadow. LAW 4: shadow only - it writes ONE table and that table has
-- no operational consumer.
--
-- ⛔ THE TWO WRITTEN CONTRACTS THIS FUNCTION EXISTS TO HONOUR
--
-- S-86  The ladder does NOT cascade after a partial fill. A 1-of-2 rung-1 fill leaves rung 2
--       `attempted: false`, so a caller may NEVER assume qty_resolved = qty_needed, nor that a
--       shortfall implies resolved_rung = 'blocked_demand'. The stranded remainder is THIS
--       function's LAW 5 obligation.
-- S-87  resolve_m2m_sku_legs_v3 called with p_lines = NULL is INERT on real data
--       (shelf_composition covers 16 of 656 shelves), so a rung-4 termination that defaults
--       p_lines strands units silently. This function passes p_lines built from the donor
--       shelf's Remove rows, and when no SKU mix is knowable it BLOCKS the units explicitly
--       rather than calling into a function that cannot answer.
--
-- ⭐ CONSERVATION BY CONSTRUCTION (the S-85 lesson: remove the failure mode, do not guard it).
--    Placeable rows are emitted first and accumulated into v_placed. The blocked quantity is
--    then computed as `qty_needed - v_placed` - never from the ladder's shortfall field. Any
--    rung, present or future, that places fewer units than asked therefore lands the remainder
--    in a Blocked row automatically. LAW 5 cannot be violated by an omission here.

CREATE OR REPLACE FUNCTION public.stitch_v3(
  p_plan_date      date,
  p_source_run_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id    uuid;
  v_run_id     uuid := gen_random_uuid();
  v_src_run    uuid;
  v_t0         timestamptz := clock_timestamp();
  r            record;
  leg          record;
  v_ladder     jsonb;
  v_payload    jsonb;
  v_rung       text;
  v_rung_no    int;
  v_placed     int;
  v_blocked    int;
  v_sub_pod    uuid;
  v_donor_m    uuid;
  v_donor_shelf uuid;
  v_m2m_lines  jsonb;
  v_m2m        jsonb;
  v_block_rsn  text;
  v_lines_in   int := 0;
  v_rows_out   int := 0;
  v_units_in   int := 0;
  v_units_pl   int := 0;
  v_units_bl   int := 0;
  v_blocked_rows int := 0;
  v_rung_hist  jsonb := '{}'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',      true);
  PERFORM set_config('app.rpc_name', 'stitch_v3', true);

  -- Role gate, identical in shape to record_blocked_demand_v3.
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'stitch_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'stitch_v3: p_plan_date is required';
  END IF;

  -- Source run: explicit, else the latest shadow run for the date. The (produced_at, run_id)
  -- ordering is total - several runs share a produced_at, so run_id breaks the tie
  -- deterministically instead of leaving the pick to physical row order.
  IF p_source_run_id IS NOT NULL THEN
    SELECT s.run_id INTO v_src_run FROM public.pod_refills_shadow s
     WHERE s.run_id = p_source_run_id AND s.plan_date = p_plan_date LIMIT 1;
    IF v_src_run IS NULL THEN
      RAISE EXCEPTION 'stitch_v3: source run % has no rows on plan_date %', p_source_run_id, p_plan_date;
    END IF;
  ELSE
    SELECT s.run_id INTO v_src_run FROM public.pod_refills_shadow s
     WHERE s.plan_date = p_plan_date
     ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;
  END IF;

  IF v_src_run IS NULL THEN
    RETURN jsonb_build_object(
      'status','no_source_run', 'plan_date', p_plan_date, 'run_id', NULL,
      'note','no pod_refills_shadow run exists for this plan_date; nothing to stitch',
      'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
  END IF;

  FOR r IN
    SELECT s.machine_id, s.shelf_id, s.pod_product_id, s.qty
      FROM public.pod_refills_shadow s
     WHERE s.run_id = v_src_run AND s.qty > 0
     ORDER BY s.machine_id, s.shelf_id, s.pod_product_id
  LOOP
    v_lines_in := v_lines_in + 1;
    v_units_in := v_units_in + r.qty;
    v_placed   := 0;
    v_block_rsn := NULL;

    v_ladder := public.resolve_supply_ladder_v3(
                  p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id, r.qty, 5);

    v_rung    := v_ladder->>'resolved_rung';
    v_rung_no := (v_ladder->>'rung_no')::int;
    v_payload := COALESCE(v_ladder->'payload', '{}'::jsonb);

    -- COALESCE is not cosmetic: jsonb_set with a NULL path element returns NULL and would
    -- silently wipe the whole histogram rather than fail loudly.
    v_rung_hist := jsonb_set(v_rung_hist, ARRAY[COALESCE(v_rung,'unknown')],
                     to_jsonb(COALESCE((v_rung_hist->>COALESCE(v_rung,'unknown'))::int, 0) + 1));

    ------------------------------------------------------------------------
    -- RUNG 1 'variant' -> Refill from the primary warehouse.
    -- RUNG 2 'substitute' -> Add New on the substitute pod (anchor is preserved).
    -- RUNG 3 'alt_wh' -> Transfer leg; the ladder's own note says stitch emits it.
    ------------------------------------------------------------------------
    IF v_rung IN ('variant','substitute','alt_wh')
       AND COALESCE((v_ladder->>'qty_resolved')::int, 0) > 0 THEN

      v_sub_pod := CASE WHEN v_rung = 'substitute'
                        THEN (v_payload->>'substitute_pod_product_id')::uuid
                        ELSE r.pod_product_id END;

      -- A rung-2 payload without a substitute id would silently rewrite the line back to the
      -- anchor pod. Refuse instead: that is a ladder defect, not a stitch fallback.
      IF v_sub_pod IS NULL THEN
        RAISE EXCEPTION 'stitch_v3: rung 2 payload carried no substitute_pod_product_id for shelf %', r.shelf_id;
      END IF;

      INSERT INTO public.refill_plan_output_shadow
        (run_id, engine_tag, plan_date, source_run_id, machine_id, shelf_id,
         anchor_pod_product_id, pod_product_id, boonz_product_id, action, qty,
         qty_needed, qty_shortfall, resolved_rung, rung_no, source_origin, reasoning)
      VALUES
        (v_run_id, 'stitch_v3', p_plan_date, v_src_run, r.machine_id, r.shelf_id,
         r.pod_product_id, v_sub_pod, NULL,
         CASE v_rung WHEN 'variant' THEN 'Refill'
                     WHEN 'substitute' THEN 'Add New'
                     ELSE 'Transfer' END,
         (v_ladder->>'qty_resolved')::int,
         r.qty, COALESCE((v_ladder->>'qty_shortfall')::int, 0), v_rung, v_rung_no, 'warehouse',
         jsonb_build_object('source','stitch_v3','ladder', v_ladder->'ladder',
                            'payload', v_payload, 'supply', v_ladder->'supply',
                            'sku_binding','deferred_to_p31d'));

      v_placed  := v_placed + (v_ladder->>'qty_resolved')::int;
      v_rows_out := v_rows_out + 1;
      IF COALESCE((v_ladder->>'qty_shortfall')::int, 0) > 0 THEN
        v_block_rsn := 'partial_wh_limited';   -- S-86: terminal rung served less than asked
      END IF;

    ------------------------------------------------------------------------
    -- RUNG 4 'm2m' -> one leg PER SKU. ⛔ S-87 in force.
    ------------------------------------------------------------------------
    ELSIF v_rung = 'm2m' AND COALESCE((v_ladder->>'qty_resolved')::int, 0) > 0 THEN

      v_donor_m := NULL;
      IF jsonb_typeof(v_payload->'donor_machines') = 'array' THEN
        SELECT d::uuid INTO v_donor_m
          FROM jsonb_array_elements_text(v_payload->'donor_machines') d LIMIT 1;
      END IF;

      -- The donor SHELF carrying the same pod. The ladder names donor MACHINES only.
      v_donor_shelf := NULL;
      IF v_donor_m IS NOT NULL THEN
        -- ⛔ via v_shelf_state, the P1.2 canonical shelf<->pod object. shelf_configurations
        --    carries NO pod_product_id (cols: shelf_id, machine_id, shelf_code, shelf_size,
        --    max_capacity, created_at, is_phantom) and v_shelf_state is already restricted to
        --    enabled, non-phantom shelves.
        SELECT ss.shelf_id INTO v_donor_shelf
          FROM public.v_shelf_state ss
         WHERE ss.machine_id     = v_donor_m
           AND ss.pod_product_id = r.pod_product_id
         LIMIT 1;
      END IF;

      -- p_lines from the donor shelf's Remove rows, which carry boonz_product_id. This is the
      -- function's own stated remedy. ⛔ NEVER call it with NULL (S-87): on this fleet that
      -- returns source_composition_unknown and the units would vanish.
      v_m2m_lines := NULL;
      IF v_donor_shelf IS NOT NULL THEN
        SELECT jsonb_agg(jsonb_build_object('boonz_product_id', x.boonz_product_id, 'qty', x.qty))
          INTO v_m2m_lines
          FROM (SELECT rpo.boonz_product_id, sum(rpo.quantity)::int AS qty
                  FROM public.refill_plan_output rpo
                 WHERE rpo.plan_date = p_plan_date
                   AND rpo.shelf_id  = v_donor_shelf
                   AND lower(rpo.action) = 'remove'
                   AND rpo.boonz_product_id IS NOT NULL
                 GROUP BY rpo.boonz_product_id
                HAVING sum(rpo.quantity) > 0) x;
      END IF;

      IF v_m2m_lines IS NULL THEN
        -- No knowable SKU mix. Do not guess, and do not make an inert call: block the units.
        v_block_rsn := 'm2m_sku_unknown';
      ELSE
        v_m2m := public.resolve_m2m_sku_legs_v3(v_donor_shelf, r.shelf_id, v_m2m_lines);

        FOR leg IN
          SELECT (e->>'boonz_product_id')::uuid AS bpid, (e->>'qty')::int AS qty
            FROM jsonb_array_elements(COALESCE(v_m2m->'legs', '[]'::jsonb)) e
           WHERE COALESCE((e->>'qty')::int, 0) > 0
        LOOP
          -- Never place more than the ladder said was available.
          EXIT WHEN v_placed >= (v_ladder->>'qty_resolved')::int;

          INSERT INTO public.refill_plan_output_shadow
            (run_id, engine_tag, plan_date, source_run_id, machine_id, shelf_id,
             anchor_pod_product_id, pod_product_id, boonz_product_id, action, qty,
             qty_needed, qty_shortfall, resolved_rung, rung_no, source_origin,
             from_machine_id, reasoning)
          VALUES
            (v_run_id, 'stitch_v3', p_plan_date, v_src_run, r.machine_id, r.shelf_id,
             r.pod_product_id, r.pod_product_id, leg.bpid, 'Refill',
             LEAST(leg.qty, (v_ladder->>'qty_resolved')::int - v_placed),
             r.qty, 0, v_rung, v_rung_no, 'internal_transfer', v_donor_m,
             jsonb_build_object('source','stitch_v3','ladder', v_ladder->'ladder',
                                'payload', v_payload, 'm2m', v_m2m,
                                'donor_shelf_id', v_donor_shelf,
                                'lines_source','donor_remove_rows'));

          v_placed   := v_placed + LEAST(leg.qty, (v_ladder->>'qty_resolved')::int - v_placed);
          v_rows_out := v_rows_out + 1;
        END LOOP;

        IF v_placed = 0 THEN
          v_block_rsn := 'm2m_no_legs';
        END IF;
      END IF;

    ------------------------------------------------------------------------
    -- RUNG 5 'spot_buy' / RUNG 6 'blocked_demand' -> nothing is physically placeable.
    ------------------------------------------------------------------------
    ELSIF v_rung = 'spot_buy' THEN
      v_block_rsn := 'spot_buy_candidate';
    ELSE
      v_block_rsn := COALESCE(v_payload->>'reason', 'substitution_exhausted');
    END IF;

    ------------------------------------------------------------------------
    -- ⭐ LAW 5 / S-86. Computed from what was ACTUALLY placed, never from the ladder's
    --    shortfall field, so no rung can strand a unit by omission.
    ------------------------------------------------------------------------
    v_blocked := r.qty - v_placed;
    IF v_blocked > 0 THEN
      INSERT INTO public.refill_plan_output_shadow
        (run_id, engine_tag, plan_date, source_run_id, machine_id, shelf_id,
         anchor_pod_product_id, pod_product_id, boonz_product_id, action, qty,
         qty_needed, qty_shortfall, resolved_rung, rung_no, source_origin, reasoning)
      VALUES
        (v_run_id, 'stitch_v3', p_plan_date, v_src_run, r.machine_id, r.shelf_id,
         r.pod_product_id, r.pod_product_id, NULL, 'Blocked', v_blocked,
         r.qty, v_blocked, v_rung, v_rung_no, 'warehouse',
         jsonb_build_object('source','stitch_v3',
                            'reason', COALESCE(v_block_rsn,'substitution_exhausted'),
                            'terminal_rung', v_rung, 'rung_no', v_rung_no,
                            'qty_placed', v_placed,
                            'ladder', v_ladder->'ladder', 'payload', v_payload,
                            'law5','stranded units are carried explicitly; never a silent qty-0',
                            'blocked_demand_promotion','source=stitch writer lands with the live cutover (P3.1e)'));
      v_rows_out     := v_rows_out + 1;
      v_blocked_rows := v_blocked_rows + 1;
      v_units_bl     := v_units_bl + v_blocked;
    END IF;

    v_units_pl := v_units_pl + v_placed;
  END LOOP;

  -- Conservation is asserted, not assumed. If this ever raises, the emitter lost a unit.
  IF v_units_pl + v_units_bl <> v_units_in THEN
    RAISE EXCEPTION 'stitch_v3: conservation violated - in=% placed=% blocked=%',
      v_units_in, v_units_pl, v_units_bl;
  END IF;

  RETURN jsonb_build_object(
    'status',         'ok',
    'plan_date',      p_plan_date,
    'run_id',         v_run_id,
    'source_run_id',  v_src_run,
    'engine_tag',     'stitch_v3',
    'lines_in',       v_lines_in,
    'rows_out',       v_rows_out,
    'units_in',       v_units_in,
    'units_placed',   v_units_pl,
    'units_blocked',  v_units_bl,
    'blocked_rows',   v_blocked_rows,
    'rungs',          v_rung_hist,
    'sku_binding',    'deferred_to_p31d',
    'duration_ms',    (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
END
$fn$;

COMMENT ON FUNCTION public.stitch_v3(date, uuid) IS
  'PRD-110 P3.1c SKELETON. pod_refills_shadow -> resolve_supply_ladder_v3 -> refill_plan_output_shadow. '
  'Honours S-86 (no cascade after a partial fill; the stranded remainder is the consumer''s LAW 5 '
  'obligation) and S-87 (never calls resolve_m2m_sku_legs_v3 with p_lines = NULL). Conservation is '
  'by construction: blocked = qty_needed - qty_actually_placed, asserted before return. '
  'NOT YET PORTED from v1 stitch_pod_to_boonz (md5 806340b2..): FEFO SKU binding (P3.1d), the '
  'PRD-109 preflight gate, variant redistribution, Remove/M2W legs, and the live blocked_demand '
  'source=stitch writer. Writes exactly one table, which has no operational consumer (LAW 4).';

REVOKE ALL ON FUNCTION public.stitch_v3(date, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.stitch_v3(date, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.stitch_v3(date, uuid) TO authenticated, service_role;
