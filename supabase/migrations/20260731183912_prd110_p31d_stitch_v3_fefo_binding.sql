CREATE OR REPLACE FUNCTION public.stitch_v3(p_plan_date date, p_source_run_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  -- P3.1d FEFO SKU binding
  v_fefo         jsonb;
  v_qty_res      int;
  v_take         int;
  v_unbound      int;
  v_first        boolean;
  v_action       text;
  v_bound_units  int := 0;
  v_unbound_units int := 0;
  v_fefo_legs    int := 0;
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

      v_qty_res := (v_ladder->>'qty_resolved')::int;
      v_action  := CASE v_rung WHEN 'variant' THEN 'Refill'
                               WHEN 'substitute' THEN 'Add New'
                               ELSE 'Transfer' END;

      -- ⭐ P3.1d. The SKU is no longer deferred. resolve_fefo_sku_legs_v3 binds the pod to
      -- REAL batches, FEFO, merged across every Active variant, and returns one leg per SKU.
      -- ⭐ AUTHORITY SPLIT: the ladder above already decided HOW MANY units are placeable;
      -- the seam only decides WHICH SKU they are. It is never allowed to place more (the
      -- LEAST/EXIT guards below are belt-and-braces on that), and never allowed to place
      -- fewer in silence (the v_unbound row below is the LAW 5 path for identity).
      v_fefo  := public.resolve_fefo_sku_legs_v3(
                   p_plan_date, r.machine_id, r.shelf_id, v_sub_pod, v_qty_res, v_rung);
      v_first := true;

      FOR leg IN
        SELECT (t.e->>'boonz_product_id')::uuid          AS bpid,
               (t.e->>'qty')::int                        AS qty,
               (t.e->>'preferred_wh_inventory_id')::uuid AS wh_id,
               t.e                                       AS legobj
          FROM jsonb_array_elements(COALESCE(v_fefo->'legs', '[]'::jsonb)) AS t(e)
         WHERE COALESCE((t.e->>'qty')::int, 0) > 0
      LOOP
        EXIT WHEN v_placed >= v_qty_res;
        v_take := LEAST(leg.qty, v_qty_res - v_placed);

        INSERT INTO public.refill_plan_output_shadow
          (run_id, engine_tag, plan_date, source_run_id, machine_id, shelf_id,
           anchor_pod_product_id, pod_product_id, boonz_product_id, action, qty,
           qty_needed, qty_shortfall, resolved_rung, rung_no, source_origin,
           preferred_wh_inventory_id, reasoning)
        VALUES
          (v_run_id, 'stitch_v3', p_plan_date, v_src_run, r.machine_id, r.shelf_id,
           r.pod_product_id, v_sub_pod, leg.bpid, v_action, v_take,
           -- the ladder's shortfall is a property of the LINE, not of each split leg, so it
           -- rides the first row only and is never multiplied across the split.
           r.qty, CASE WHEN v_first THEN COALESCE((v_ladder->>'qty_shortfall')::int, 0) ELSE 0 END,
           v_rung, v_rung_no, 'warehouse', leg.wh_id,
           jsonb_build_object('source','stitch_v3','ladder', v_ladder->'ladder',
                              'payload', v_payload, 'supply', v_ladder->'supply',
                              'sku_binding','fefo_bound',
                              'fefo_leg', leg.legobj,
                              'fefo', v_fefo - 'legs',
                              'seam','resolve_fefo_sku_legs_v3'));

        v_placed      := v_placed + v_take;
        v_bound_units := v_bound_units + v_take;
        v_rows_out    := v_rows_out + 1;
        v_fefo_legs   := v_fefo_legs + 1;
        v_first       := false;
      END LOOP;

      -- ⛔ LAW 5, in the IDENTITY dimension. Units the ladder ruled placeable but which no
      -- batch could NAME still ship - they are not dropped and not silently renamed - but
      -- they carry the seam's own named reason. Before P3.1d EVERY row looked like this;
      -- now only the rows that genuinely could not be bound do.
      v_unbound := v_qty_res - v_placed;
      IF v_unbound > 0 THEN
        INSERT INTO public.refill_plan_output_shadow
          (run_id, engine_tag, plan_date, source_run_id, machine_id, shelf_id,
           anchor_pod_product_id, pod_product_id, boonz_product_id, action, qty,
           qty_needed, qty_shortfall, resolved_rung, rung_no, source_origin, reasoning)
        VALUES
          (v_run_id, 'stitch_v3', p_plan_date, v_src_run, r.machine_id, r.shelf_id,
           r.pod_product_id, v_sub_pod, NULL, v_action, v_unbound,
           r.qty, CASE WHEN v_first THEN COALESCE((v_ladder->>'qty_shortfall')::int, 0) ELSE 0 END,
           v_rung, v_rung_no, 'warehouse',
           jsonb_build_object('source','stitch_v3','ladder', v_ladder->'ladder',
                              'payload', v_payload, 'supply', v_ladder->'supply',
                              'sku_binding','unbound',
                              'unbound_reason', COALESCE(v_fefo->>'unbound_reason','unknown'),
                              'fefo', v_fefo - 'legs',
                              'seam','resolve_fefo_sku_legs_v3',
                              'law5','the unit ships; only its SKU identity is unresolved, and it is named'));

        v_placed        := v_placed + v_unbound;
        v_unbound_units := v_unbound_units + v_unbound;
        v_rows_out      := v_rows_out + 1;
      END IF;

      IF COALESCE((v_ladder->>'qty_shortfall')::int, 0) > 0 THEN
        v_block_rsn := 'partial_wh_limited';   -- S-86: terminal rung served less than asked
      END IF;

    ------------------------------------------------------------------------
    -- RUNG 4 'm2m' -> one leg PER SKU. ⛔ S-87 in force.
    ------------------------------------------------------------------------
    ELSIF v_rung = 'm2m' AND COALESCE((v_ladder->>'qty_resolved')::int, 0) > 0 THEN

      -- ⛔ S-91. This branch had NEVER executed, and could not have. The ladder names
      -- `donor_machines` as count(DISTINCT machine_id) -- an INT -- and the previous body
      -- tested jsonb_typeof(payload->'donor_machines')='array' before reading UUIDs out of
      -- it. A number is never an array, so the donor was ALWAYS NULL, v_m2m_lines was always
      -- NULL, and every single m2m unit fell through to 'm2m_sku_unknown'. The branch could
      -- not place one unit. Three further defects hid behind that one (see
      -- resolve_m2m_donor_legs_v3): the shelf_composition fallback was bypassed, the qty was
      -- clamped to the FLEET-WIDE donor sum rather than the chosen donor's, and every
      -- return_to_wh leg was written as a Refill into the destination.
      --
      -- Donor choice, the per-donor clamp and the transfer-only filter now live in
      -- resolve_m2m_donor_legs_v3. That seam exists because rung 4 is UNREACHABLE through
      -- the ladder on live data (544/544 shelves stop at rung 1 or 2), so this branch could
      -- never be reached by a fixture while its logic was inline. It is directly callable,
      -- and fixture 45 proves it on real donors.
      v_m2m := public.resolve_m2m_donor_legs_v3(
                 p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id,
                 (v_ladder->>'qty_resolved')::int);

      IF COALESCE(v_m2m->>'status', '') <> 'ok' THEN
        -- Named, never generic: 'm2m_no_donor', 'm2m_no_donor_excess', 'm2m_m2m_unresolved'.
        v_block_rsn := 'm2m_' || COALESCE(v_m2m->>'status', 'unresolved');
      ELSE
        v_donor_m     := (v_m2m #>> '{donor,donor_machine_id}')::uuid;
        v_donor_shelf := (v_m2m #>> '{donor,donor_shelf_id}')::uuid;

        -- ⛔ Every leg here is already leg='transfer' and already clamped to the donor's own
        --    excess by the seam. The EXIT guard stays as belt-and-braces so a future change
        --    to the seam can never over-place through this writer.
        FOR leg IN
          SELECT (e->>'boonz_product_id')::uuid AS bpid, (e->>'qty')::int AS qty
            FROM jsonb_array_elements(COALESCE(v_m2m->'legs', '[]'::jsonb)) e
           WHERE COALESCE((e->>'qty')::int, 0) > 0
        LOOP
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
                                'lines_source', v_m2m->>'lines_source',
                                'seam','resolve_m2m_donor_legs_v3'));

          v_placed   := v_placed + LEAST(leg.qty, (v_ladder->>'qty_resolved')::int - v_placed);
          v_rows_out := v_rows_out + 1;
        END LOOP;

        IF v_placed = 0 THEN
          -- The seam resolved a donor but nothing could legally cross: every unit was
          -- non-assortable at the destination or clamped out by its headroom.
          v_block_rsn := 'm2m_no_transferable_legs';
        ELSIF v_placed < r.qty THEN
          v_block_rsn := 'm2m_donor_capped';
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
    'sku_binding',       'fefo_v3',
    'units_sku_bound',   v_bound_units,
    'units_sku_unbound', v_unbound_units,
    'sku_legs',          v_fefo_legs,
    'duration_ms',    (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
END
$function$
;
