-- PRD-110 · D-33 EXECUTED · stitch_v3's default source is the COMPOSED plan
--
-- CS ruling (2026-08-01): "D-33 -> YES: stitch consumes composed runs BY DEFAULT,
-- coupling pinned by a dedicated fixture." Answered, never executed. Fixture 76
-- (migration 20260809020000) is that fixture and it was fired RED against the body
-- this migration replaces.
--
-- ⛔ THE DEFECT IS A COIN FLIP, NOT A PREFERENCE. The old default ordered by
--    (produced_at DESC, run_id DESC) across every engine_tag. A composition and its
--    base are written in the SAME transaction, so produced_at is identical and the
--    tiebreak is a random v4 uuid. Fixture 51 section (2) wrote the diagnosis down
--    already -- "that is the coin flip, forced to its wrong face" -- and worked around
--    it with a crafted run_id rather than fixing it. When the coin lands on the base,
--    every human edit is dropped and the receipt still reports 'ok'.
--
-- ⭐ compose_plan_with_edits_v3 has ALWAYS carried the mirror-image guard (it refuses
--    to compose over a compose_v3 run, with a comment saying why). This is the other
--    half of the same seam, built at last to the same standard.
--
-- WHAT CHANGES: the NULL-source branch only, plus a `source_selection` field on the
--    receipt. Four outcomes, all named:
--      composed_latest      the composition is the plan of record  -> consume it
--      stale_composition    a base is NEWER than the composition   -> REFUSE, name both
--      uncomposed_edits     active edits, nothing composed them    -> REFUSE, count them
--      uncomposed_fallback  no edits, no composition               -> proceed, say so
--
-- WHAT DOES NOT CHANGE: the signature, the explicit-source branch, the ladder, the
--    FEFO seam, the m2m branch, the LAW 5 blocked path and the conservation assertion.
--    Asserted below, not asserted by hope.
--
-- BLAST RADIUS (surveyed before authoring): fixtures 44, 46, 47 all pass an explicit
--    source; run_pipeline_v3 (the only in-DB caller) passes explicitly and RAISEs if
--    stitch reports a different source; no cron calls stitch_v3 at all. The default
--    path had no automated caller and no fixture -- it is reachable only by hand.

BEGIN;

-- ---------------------------------------------------------------------------
-- PRE-IMAGE GUARD. Refuse to replace a body that is not the one reviewed.
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE v_md5 text; v_n int; v_acl text;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc WHERE proname = 'stitch_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-33: expected exactly 1 stitch_v3 signature, found %', v_n;
  END IF;

  SELECT md5(prosrc) INTO v_md5 FROM pg_proc WHERE proname = 'stitch_v3';
  IF v_md5 <> 'a8753091f33dcac4255892a71b481146' THEN
    RAISE EXCEPTION 'D-33: stitch_v3 pre-image md5 is %, expected a8753091f33dcac4255892a71b481146 - the body drifted since review', v_md5;
  END IF;

  SELECT COALESCE(array_to_string(proacl, ','), 'DEFAULT') INTO v_acl
    FROM pg_proc WHERE proname = 'stitch_v3';
  IF v_acl <> 'postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres' THEN
    RAISE EXCEPTION 'D-33: stitch_v3 pre-image ACL is %, not the reviewed grant set', v_acl;
  END IF;

  -- The uncomposed_edits refusal reads this view. If it were missing, the new body
  -- would fail at RUN time inside a nightly job rather than here, in a migration.
  IF to_regclass('public.v_plan_edits_active_v3') IS NULL THEN
    RAISE EXCEPTION 'D-33: v_plan_edits_active_v3 does not exist - the uncomposed_edits refusal has nothing to read';
  END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- THE REPLACEMENT
-- ---------------------------------------------------------------------------
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
  v_src_pick   text;
  v_cmp_run    uuid;
  v_cmp_at     timestamptz;
  v_base_run   uuid;
  v_base_at    timestamptz;
  v_n_edits    int;
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

  -- Source run: explicit, else -- per CS decision D-33 -- the COMPOSED plan.
  --
  -- ⛔ WHAT THIS REPLACED, and why it was not merely a preference bug. The old default
  --    was `ORDER BY produced_at DESC, run_id DESC LIMIT 1` over EVERY tag. Its own
  --    comment claimed the ordering was "total"; it is total but it is not MEANINGFUL.
  --    A composition and the base it was composed from are written in the same
  --    transaction, so they share produced_at exactly and the tiebreak falls to a
  --    RANDOM v4 uuid. Fixture 51 section (2) diagnosed this in writing -- "that is the
  --    coin flip, forced to its wrong face" -- and steered around it with a crafted
  --    run_id instead of fixing it. When the coin lands on the base, every human edit
  --    is dropped and the receipt still says 'ok'.
  --
  -- ⭐ The mirror-image guard has always existed in compose_plan_with_edits_v3, which
  --    refuses to compose over a compose_v3 run. The two halves of one seam were built
  --    with opposite levels of care; this is the other half.
  IF p_source_run_id IS NOT NULL THEN
    SELECT s.run_id INTO v_src_run FROM public.pod_refills_shadow s
     WHERE s.run_id = p_source_run_id AND s.plan_date = p_plan_date LIMIT 1;
    IF v_src_run IS NULL THEN
      RAISE EXCEPTION 'stitch_v3: source run % has no rows on plan_date %', p_source_run_id, p_plan_date;
    END IF;
    -- The caller is allowed to mean what they said, including "stitch the raw base".
    v_src_pick := 'explicit';
  ELSE
    SELECT s.run_id, s.produced_at INTO v_cmp_run, v_cmp_at
      FROM public.pod_refills_shadow s
     WHERE s.plan_date = p_plan_date AND s.engine_tag = 'compose_v3'
     ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;

    SELECT s.run_id, s.produced_at INTO v_base_run, v_base_at
      FROM public.pod_refills_shadow s
     WHERE s.plan_date = p_plan_date AND s.engine_tag <> 'compose_v3'
     ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;

    IF v_cmp_run IS NOT NULL AND (v_base_at IS NULL OR v_cmp_at >= v_base_at) THEN
      -- The composition is the plan of record. ⛔ Compare produced_at ONLY -- never
      -- (produced_at, run_id). The uuid tiebreak IS the disease; reintroducing it here
      -- as a "total ordering" would put the coin flip straight back, because a
      -- composition and its base share produced_at exactly. On a tie the tag decides,
      -- and the tag says compose_v3.
      v_src_run  := v_cmp_run;
      v_src_pick := 'composed_latest';

    ELSIF v_cmp_run IS NOT NULL THEN
      -- ⛔ A base was produced AFTER the last composition. NEITHER answer is right: the
      --    base has lost the edits, the composition has planned against stale demand.
      --    Refuse and name both runs -- the same stance run_pipeline_v3 already takes on
      --    a composed-empty plan ("Stop, and say so") rather than falling back.
      RAISE EXCEPTION 'stitch_v3: stale_composition on % - base run % (produced %) is newer than composed run % (produced %); run compose_plan_with_edits_v3 first, or pass p_source_run_id explicitly',
        p_plan_date, v_base_run, v_base_at, v_cmp_run, v_cmp_at;

    ELSIF v_base_run IS NOT NULL THEN
      SELECT count(*) INTO v_n_edits
        FROM public.v_plan_edits_active_v3 e WHERE e.plan_date = p_plan_date;

      IF v_n_edits > 0 THEN
        -- ⛔ LAW 5 in the EDIT dimension. Active edits exist and nothing has composed
        --    them; consuming the base would drop human intent with no trace at all.
        RAISE EXCEPTION 'stitch_v3: uncomposed_edits on % - % active plan edit(s) exist and no compose_v3 run does; run compose_plan_with_edits_v3 first, or pass p_source_run_id explicitly',
          p_plan_date, v_n_edits;
      END IF;

      -- A date with no edits and no composition has nothing to lose. Refusing here
      -- would break every by-hand stitch on an unedited date, so it runs -- but it
      -- says so out loud instead of implying it consumed a plan.
      v_src_run  := v_base_run;
      v_src_pick := 'uncomposed_fallback';

    ELSE
      -- No runs of any tag. Falls through to the no_source_run return below.
      v_src_pick := 'none';
    END IF;
  END IF;

  IF v_src_run IS NULL THEN
    RETURN jsonb_build_object(
      'status','no_source_run', 'plan_date', p_plan_date, 'run_id', NULL,
      'source_selection', COALESCE(v_src_pick,'none'),
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
                            -- P3.1e SHIPPED. The promotion is real, and it is a SEPARATE call:
                            -- record_blocked_demand_v3(plan_date,'stitch'). ⛔ stitch_v3 does NOT
                            -- invoke it. blocked_demand HAS an operational consumer (procurement
                            -- reads v_blocked_demand_open), and LAW 4 forbids a shadow engine
                            -- writing into a live consumer's path. Auto-promotion is parked as a
                            -- CS flag (D-29), never a default.
                            'blocked_demand_promotion','record_blocked_demand_v3(plan_date, ''stitch'') promotes this row; not called automatically (LAW 4, D-29)'));
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
    'source_selection', v_src_pick,
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
$function$;

-- ---------------------------------------------------------------------------
-- POST-IMAGE GUARD. Every claim in the header, asserted.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE v_src text; v_n int; v_acl text; v_cfg text; v_sd boolean;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc WHERE proname = 'stitch_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-33: post-image has % stitch_v3 signatures, expected exactly 1 (an overload is a foot-gun, not a ship)', v_n;
  END IF;

  SELECT pronargdefaults INTO v_n FROM pg_proc WHERE proname = 'stitch_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-33: pronargdefaults is %, expected 1 - stitch_v3(date) must still resolve to this function', v_n;
  END IF;

  SELECT prosrc, prosecdef, COALESCE(array_to_string(proconfig, ','), 'NONE'),
         COALESCE(array_to_string(proacl, ','), 'DEFAULT')
    INTO v_src, v_sd, v_cfg, v_acl
    FROM pg_proc WHERE proname = 'stitch_v3';

  IF NOT v_sd THEN
    RAISE EXCEPTION 'D-33: stitch_v3 lost SECURITY DEFINER';
  END IF;
  IF v_cfg <> 'search_path=public, pg_temp' THEN
    RAISE EXCEPTION 'D-33: stitch_v3 search_path is now %, expected search_path=public, pg_temp', v_cfg;
  END IF;
  IF v_acl <> 'postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres' THEN
    RAISE EXCEPTION 'D-33: stitch_v3 ACL changed to % - CREATE OR REPLACE must preserve the grant set', v_acl;
  END IF;

  -- the four named outcomes are present
  IF position('composed_latest'     in v_src) = 0 THEN RAISE EXCEPTION 'D-33: composed_latest branch missing'; END IF;
  IF position('stale_composition'   in v_src) = 0 THEN RAISE EXCEPTION 'D-33: stale_composition refusal missing'; END IF;
  IF position('uncomposed_edits'    in v_src) = 0 THEN RAISE EXCEPTION 'D-33: uncomposed_edits refusal missing'; END IF;
  IF position('uncomposed_fallback' in v_src) = 0 THEN RAISE EXCEPTION 'D-33: uncomposed_fallback branch missing'; END IF;
  IF position('source_selection'    in v_src) = 0 THEN RAISE EXCEPTION 'D-33: the receipt does not name its source selection'; END IF;

  -- ⛔ the OLD tag-blind pick must be GONE, not merely shadowed by new code above it
  IF v_src ~ 'WHERE s\.plan_date = p_plan_date\s*\n\s*ORDER BY s\.produced_at DESC' THEN
    RAISE EXCEPTION 'D-33: the tag-blind default pick is still present in the body';
  END IF;

  -- ⭐ the parts that must NOT have moved. A body replacement is the easiest place in
  --    this build to lose a branch by transcription, so each survivor is named.
  IF position('resolve_fefo_sku_legs_v3'   in v_src) = 0 THEN RAISE EXCEPTION 'D-33: FEFO seam lost'; END IF;
  IF position('resolve_m2m_donor_legs_v3'  in v_src) = 0 THEN RAISE EXCEPTION 'D-33: m2m seam lost'; END IF;
  IF position('resolve_supply_ladder_v3'   in v_src) = 0 THEN RAISE EXCEPTION 'D-33: ladder call lost'; END IF;
  IF position('conservation violated'      in v_src) = 0 THEN RAISE EXCEPTION 'D-33: conservation assertion lost'; END IF;
  IF position('stranded units are carried explicitly' in v_src) = 0 THEN RAISE EXCEPTION 'D-33: LAW 5 blocked path lost'; END IF;
  IF position('lacks operator_admin role'  in v_src) = 0 THEN RAISE EXCEPTION 'D-33: role gate lost'; END IF;
END
$post$;

COMMIT;
