-- PRD-110 · D-45 EXECUTE — plan-edit `add` becomes ADDITIVE in the COMPOSER.
--
-- CS RULING (2026-08-04): "D-45 CLOSED: `add` IS ADDITIVE (`base + qty`). 'Add 3' means 3 on top —
-- matches CS dictation semantics and the writer/pin-contradiction guard as built. Fix
-- compose_plan_with_edits_v3 (composer), leave record_plan_edit_v3 alone. S3 assertion 20
-- add_composes_as_absolute_D45_sensor is EXPECTED to go red; updating it is the proof the fix
-- landed."
--
-- ⭐ THE DEFECT D-45 NAMED: the two halves of the edit path disagreed with each other.
--   · record_plan_edit_v3        evaluated `add` as ADDITIVE (base_qty_at_edit + qty) for its
--                                pin-contradiction guard — and still does; it is NOT touched here.
--   · compose_plan_with_edits_v3 applied `add` as ABSOLUTE (qty), so an "add 3" on a base of 12
--                                composed to 3, i.e. a 9-unit SILENT REDUCTION of a line a human
--                                believed they were increasing.
--   Measured exposure at S3 leg 122: 5 of 5 applied `add` edits carried base_qty_at_edit > 0, so
--   every one of them diverged. This is a money defect in the direction that starves a shelf.
--
-- ⛔ THE CHANGE IS ONE `CASE`, IN LOOP (a) ONLY, APPLIED BY NAMED SUBSTITUTION ON THE LIVE
-- DEFINITION — the body below is `pg_get_functiondef` output with exactly one line replaced and
-- diff-verified to one hunk. LOOP (b) IS DELIBERATELY UNCHANGED: it handles edits with no base
-- line, where base is 0, so `0 + edit_qty = edit_qty` was already the additive answer. Changing
-- it too would have been a second, unruled semantic move dressed as consistency.
--
-- ⛔ THE S3 SENSORS ARE NOT TOUCHED IN THIS MIGRATION, ON PURPOSE. Assertions 18
-- (hard_edits_present_in_composed_output) and 20 (add_composes_as_absolute_D45_sensor) both
-- assert `composed qty = e.qty` and both MUST go red on the next S3 run. That red is the proof
-- the fix landed, exactly as D-46 proved itself last leg, and it is banked before the sensors are
-- re-based in the follow-up migration. ⭐ These sensors live in golden.stress_s3_verify_v1, NOT in
-- golden.assertions — golden.run_all() is unaffected between the two migrations, so the harness
-- is never left red.
--
-- Article 3 (RPC, no raw write) · Article 12 (forward-only, CREATE OR REPLACE, no signature
-- change) · Article 16 (versioned _v3 surface). No protected entity is written by this migration;
-- the function writes only pod_refills_shadow, a SHADOW table (LAW 4).

CREATE OR REPLACE FUNCTION public.compose_plan_with_edits_v3(p_plan_date date, p_source_run_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id   uuid;
  v_run_id    uuid := gen_random_uuid();
  v_base_run  uuid;
  v_t0        timestamptz := clock_timestamp();
  e           record;
  v_considered int := 0;
  v_applied    int := 0;
  v_yielded    int := 0;
  v_applied_j  jsonb := '[]'::jsonb;
  v_yielded_j  jsonb := '[]'::jsonb;
  v_base_qty   int;
  v_has_base   boolean;
  v_eff        int;
  v_lines_base int := 0;
  v_lines_out  int := 0;
  v_units_base int := 0;
  v_units_out  int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                       true);
  PERFORM set_config('app.rpc_name', 'compose_plan_with_edits_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'compose_plan_with_edits_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'compose_plan_with_edits_v3: p_plan_date is required';
  END IF;

  IF p_source_run_id IS NOT NULL THEN
    SELECT s.run_id INTO v_base_run FROM public.pod_refills_shadow s
     WHERE s.run_id = p_source_run_id AND s.plan_date = p_plan_date LIMIT 1;
    IF v_base_run IS NULL THEN
      RAISE EXCEPTION 'compose_plan_with_edits_v3: source run % has no rows on plan_date %',
        p_source_run_id, p_plan_date;
    END IF;
  ELSE
    -- ⛔ never compose over a previous COMPOSED run: the overlay would be
    --    applied to its own output and every soft edit would read as fresh.
    SELECT s.run_id INTO v_base_run FROM public.pod_refills_shadow s
     WHERE s.plan_date = p_plan_date AND s.engine_tag <> 'compose_v3'
     ORDER BY s.produced_at DESC, s.run_id DESC LIMIT 1;
  END IF;

  IF v_base_run IS NULL THEN
    RETURN jsonb_build_object(
      'status','no_source_run', 'plan_date', p_plan_date, 'run_id', NULL,
      'note','no non-composed pod_refills_shadow run exists for this plan_date',
      'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
  END IF;

  SELECT count(*), COALESCE(SUM(qty),0) INTO v_lines_base, v_units_base
    FROM public.pod_refills_shadow WHERE run_id = v_base_run;

  -- ⭐ considered is counted INDEPENDENTLY of the loops that consume it. If a
  --    base run ever carried two rows for one (shelf, pod), the loop below
  --    would process one edit twice and the accounting assertion at the end
  --    would RAISE -- which is the point. A counter incremented inside the
  --    loop would have absorbed the duplicate and stayed silently green.
  SELECT count(*) INTO v_considered
    FROM public.v_plan_edits_active_v3 WHERE plan_date = p_plan_date;

  ----------------------------------------------------------------------
  -- (a) BASE LINES, each asked whether an active edit speaks for it.
  ----------------------------------------------------------------------
  FOR e IN
    SELECT b.shelf_id, b.pod_product_id, b.machine_id, b.qty AS base_qty,
           b.current_stock, b.max_stock, b.days_cover, b.signal,
           b.wh_available_pod, b.velocity_instock, b.availability_basis, b.reasoning,
           x.edit_id, x.kind, x.qty AS edit_qty, x."lock" AS lck,
           x.base_qty_at_edit, x.reason
      FROM public.pod_refills_shadow b
      LEFT JOIN public.v_plan_edits_active_v3 x
             ON x.plan_date = p_plan_date
            AND x.shelf_id = b.shelf_id
            AND x.pod_product_id = b.pod_product_id
     WHERE b.run_id = v_base_run
     ORDER BY b.shelf_id, b.pod_product_id
  LOOP
    v_eff := e.base_qty;

    IF e.edit_id IS NOT NULL THEN
      -- hard: the human wins outright. soft: only while the base has not moved.
      IF e.lck = 'hard' OR COALESCE(e.base_qty_at_edit, 0) = e.base_qty THEN
        -- ⭐ D-45 EXECUTED (CS ruling 2026-08-04): `add` is ADDITIVE. "Add 3" means
        --    3 ON TOP of what the engine planned, matching CS dictation semantics and
        --    the reading record_plan_edit_v3 has always used for its pin test.
        --    `set_qty` stays ABSOLUTE; `drop` stays 0. chk_plan_edits_v3_qty pins
        --    qty >= 0 on an add, so base + qty can never go negative.
        v_eff := CASE WHEN e.kind = 'drop' THEN 0
                      WHEN e.kind = 'add'  THEN e.base_qty + e.edit_qty
                      ELSE e.edit_qty END;
        v_applied := v_applied + 1;
        v_applied_j := v_applied_j || jsonb_build_object(
          'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
          'kind', e.kind, 'lock', e.lck, 'base_qty', e.base_qty, 'effective_qty', v_eff,
          'reason', e.reason);
      ELSE
        -- ⭐ LAW 5 in the EDIT dimension: a yielded edit is counted and named.
        v_yielded := v_yielded + 1;
        v_yielded_j := v_yielded_j || jsonb_build_object(
          'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
          'kind', e.kind, 'lock', e.lck,
          'base_qty_at_edit', e.base_qty_at_edit, 'base_qty_now', e.base_qty,
          'edit_qty', e.edit_qty, 'effective_qty', v_eff,
          'why','soft edit yielded: the base moved since the edit was recorded');
      END IF;
    END IF;

    IF v_eff > 0 THEN
      INSERT INTO public.pod_refills_shadow
        (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
         current_stock, max_stock, days_cover, signal, wh_available_pod,
         velocity_instock, availability_basis, reasoning)
      VALUES
        (v_run_id, 'compose_v3', p_plan_date, e.machine_id, e.shelf_id, e.pod_product_id, v_eff,
         e.current_stock, e.max_stock, e.days_cover, e.signal, e.wh_available_pod,
         e.velocity_instock, e.availability_basis,
         COALESCE(e.reasoning,'{}'::jsonb) || jsonb_build_object(
           'compose_v3', jsonb_build_object(
             'base_run_id', v_base_run, 'base_qty', e.base_qty,
             'edit_id', e.edit_id, 'edit_kind', e.kind, 'edit_lock', e.lck,
             'overlay', CASE WHEN e.edit_id IS NULL THEN 'none'
                             WHEN v_eff = e.base_qty AND e.lck='soft'
                                  AND COALESCE(e.base_qty_at_edit,0) <> e.base_qty THEN 'yielded'
                             ELSE 'applied' END)));
      v_lines_out := v_lines_out + 1;
      v_units_out := v_units_out + v_eff;
    END IF;
  END LOOP;

  ----------------------------------------------------------------------
  -- (b) EDITS WITH NO BASE LINE. The engine did not plan this shelf at all;
  --     the human says it should be planned. base_qty_now is 0.
  ----------------------------------------------------------------------
  FOR e IN
    SELECT x.edit_id, x.machine_id, x.shelf_id, x.pod_product_id, x.kind,
           x.qty AS edit_qty, x."lock" AS lck, x.base_qty_at_edit, x.reason
      FROM public.v_plan_edits_active_v3 x
     WHERE x.plan_date = p_plan_date
       AND NOT EXISTS (
         SELECT 1 FROM public.pod_refills_shadow b
          WHERE b.run_id = v_base_run AND b.shelf_id = x.shelf_id
            AND b.pod_product_id = x.pod_product_id)
     ORDER BY x.shelf_id, x.pod_product_id
  LOOP
    IF e.kind = 'drop' THEN
      -- dropping a line the base never produced is a satisfied intent, not a gap
      v_applied := v_applied + 1;
      v_applied_j := v_applied_j || jsonb_build_object(
        'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
        'kind', e.kind, 'lock', e.lck, 'base_qty', 0, 'effective_qty', 0,
        'note','drop on a shelf the base did not plan: already satisfied');
      CONTINUE;
    END IF;

    IF e.lck = 'hard' OR COALESCE(e.base_qty_at_edit, 0) = 0 THEN
      v_applied := v_applied + 1;
      v_applied_j := v_applied_j || jsonb_build_object(
        'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
        'kind', e.kind, 'lock', e.lck, 'base_qty', 0, 'effective_qty', e.edit_qty,
        'reason', e.reason);

      IF e.edit_qty > 0 THEN
        -- ⛔ scalar lookups, not a join: if v_shelf_state ever carried two rows
        --    for one shelf, a LEFT JOIN here would insert the line twice.
        INSERT INTO public.pod_refills_shadow
          (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
           current_stock, max_stock, wh_available_pod, availability_basis, reasoning)
        VALUES
          (v_run_id, 'compose_v3', p_plan_date, e.machine_id, e.shelf_id,
           e.pod_product_id, e.edit_qty,
           COALESCE((SELECT vs.current_stock FROM public.v_shelf_state vs
                      WHERE vs.shelf_id = e.shelf_id LIMIT 1), 0),
           COALESCE((SELECT vs.max_stock FROM public.v_shelf_state vs
                      WHERE vs.shelf_id = e.shelf_id LIMIT 1), 0),
           0,
           COALESCE((SELECT CASE WHEN vs.sourcing IN ('boonz_wh','venue','partner','mixed')
                                 THEN vs.sourcing ELSE 'boonz_wh' END
                       FROM public.v_shelf_state vs WHERE vs.shelf_id = e.shelf_id LIMIT 1),
                    'boonz_wh'),
           jsonb_build_object('compose_v3', jsonb_build_object(
             'base_run_id', v_base_run, 'base_qty', 0,
             'edit_id', e.edit_id, 'edit_kind', e.kind, 'edit_lock', e.lck,
             'overlay','applied',
             'note','line introduced by a human edit; the base plan had none')));
        v_lines_out := v_lines_out + 1;
        v_units_out := v_units_out + e.edit_qty;
      END IF;
    ELSE
      v_yielded := v_yielded + 1;
      v_yielded_j := v_yielded_j || jsonb_build_object(
        'edit_id', e.edit_id, 'shelf_id', e.shelf_id, 'pod_product_id', e.pod_product_id,
        'kind', e.kind, 'lock', e.lck,
        'base_qty_at_edit', e.base_qty_at_edit, 'base_qty_now', 0,
        'edit_qty', e.edit_qty, 'effective_qty', 0,
        'why','soft edit yielded: the base dropped this line after the edit was recorded');
    END IF;
  END LOOP;

  -- ⛔ No edit may vanish. If this raises, the overlay lost a human decision,
  --    which is the exact failure P3.6 exists to make impossible.
  IF v_applied + v_yielded <> v_considered THEN
    RAISE EXCEPTION 'compose_plan_with_edits_v3: edit accounting violated - considered=% applied=% yielded=%',
      v_considered, v_applied, v_yielded;
  END IF;

  RETURN jsonb_build_object(
    'status','ok', 'plan_date', p_plan_date, 'run_id', v_run_id,
    'source_run_id', v_base_run, 'engine_tag','compose_v3',
    'lines_base', v_lines_base, 'lines_out', v_lines_out,
    'units_base', v_units_base, 'units_out', v_units_out,
    'edits_considered', v_considered, 'edits_applied', v_applied,
    'edits_yielded', v_yielded,
    'applied', v_applied_j, 'yielded', v_yielded_j,
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int);
END
$function$
