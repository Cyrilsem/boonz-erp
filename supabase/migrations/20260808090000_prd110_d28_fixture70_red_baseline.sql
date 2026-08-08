-- PRD-110 · D-28 · leg 149
-- FIXTURE 70 — RED BASELINE, applied and fired BEFORE the convergence migration (LAW 1).
--
-- D-28 ruling (CS 2026-08-01): "CONVERGE `committed_elsewhere` onto `v_dispatch_availability`.
-- Own reviewed unit; before/after diff of FEFO-visible availability for the live binder logged."
--
-- ⛔ WHAT LEG 148's ADDENDUM GOT WRONG, MEASURED THIS LEG (S-280):
--    It named THREE inline sites. There is exactly ONE. `resolve_fefo_sku_legs_v3` and
--    `push_plan_to_dispatch` merely CONSUME the column `f.committed_elsewhere` off
--    `wh_fefo_for_line`; neither has a `committed AS (` CTE nor a `SUM(rd.quantity)`.
--    Proven by catalogue predicate, not by reading:
--      SELECT proname, prosrc ~* 'SUM\s*\(\s*rd\.quantity', prosrc ~* 'committed\s+AS\s*\('
--    -> only wh_fefo_for_line is true/true. The convergence is therefore ONE object,
--    and both consumers inherit it.
--
-- ⛔⛔ WHAT THE ARITHMETIC CONVERGENCE CANNOT BE (the half this unit PARKS):
--    `v_dispatch_availability.reserved_by_earlier` is a window sum ordered by `dispatch_id`
--    over rows that ALREADY EXIST. `wh_fefo_for_line` is called at PUSH instant, BEFORE the
--    row exists — there is no dispatch_id for it to be "earlier" than. The arithmetic is
--    ill-defined at the call site; only the PREDICATE (which rows count as an open warehouse
--    commitment) can converge, and that is the Article-16 substance of Cody's original raise.
--    ⛔ AND `refill_dispatching.dispatch_id` is `uuid DEFAULT gen_random_uuid()`, so the
--    canonical object's "queue" is a RANDOM tiebreak, not first-come-first-served. Leg 148's
--    addendum called it FCFS; it is not. seq 28/29 pin that fact into the harness.
--
-- ⛔ WHY THIS FIXTURE CONSTRUCTS ITS OWN CONTEST (S-274, mandatory since leg 146):
--    Leg 148 measured the acceptance evidence off live data and it is VACUOUS — `open_wh_lines`
--    is 0 on EVERY dispatch_date in the last 60 days, because packing closes inside the session
--    that pushes. A diff read off history reports "0 rows changed" and proves nothing. So the
--    contest is MADE here: one product with ZERO pickable stock anywhere, 21 units planted at
--    WH_CENTRAL, three open lines demanding 40 + 30 + 25 = 95.
--
-- ⭐ EVERY WRITE IS ROLLED BACK (fixture 18/26 idiom): the plant lives inside a subtransaction
--    that RAISEs at the end, so ZERO rows land in warehouse_inventory or refill_dispatching and
--    no DELETE is ever issued against either. Only the s_* variables survive into golden.scratch.
--
-- ⛔ S-266: golden.scratch is written AFTER the rollback block, never inside it.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  70,
  'D-28: one canonical definition of an open warehouse commitment. The predicate that decides WHICH dispatch rows discount a FEFO walk lived in two places (wh_fefo_for_line inline, v_dispatch_availability twice over); it now lives in one object both read. The ARITHMETIC does not converge and cannot: the view charges a row for competitors with a lower dispatch_id - a RANDOM uuid, not an arrival order - while the binder, running before its own row exists, discounts every line by the whole rest of the field. This fixture CONSTRUCTS the contested batch that live history can never show, and measures both formulas side by side.',
  'D-28 (CS 2026-08-01) · raised by Cody at the P3.1d review · Article 16',
  'P3',
  DATE '2030-06-16',
  true,
  'failing_expected',
  'Leg 149. RED baseline applied and fired before 20260808090500. Structural seqs 7-17 red until the convergence lands; behavioural seqs 18-30 are INVARIANT and green on both sides - a refactor that changes behaviour is not a refactor (fixture 61 seq 7 idiom).',
$fx70$
DO $do$
DECLARE
  c_date      date := DATE '2030-06-16';
  c_wh        uuid;
  c_bpid      uuid;
  c_mA        uuid; c_mB uuid; c_mC uuid;
  c_sA        uuid; c_sB uuid; c_sC uuid;
  c_pod       uuid;
  c_qA        numeric := 40;
  c_qB        numeric := 30;
  c_qC        numeric := 25;
  c_plant     numeric := 21;

  v_dA        uuid; v_dB uuid; v_dC uuid;
  v_pre_pick  numeric;
  v_n_mach    int := 0;
  v_virgin    boolean;

  s_premise   jsonb := '{}'::jsonb;
  s_sym       jsonb := '{}'::jsonb;
  s_asym      jsonb := '{}'::jsonb;
  s_struct    jsonb := '{}'::jsonb;
  s_diverge   jsonb := '{}'::jsonb;
  s_residue   jsonb := '{}'::jsonb;
  s_gucs      jsonb := '{}'::jsonb;

  v_cA numeric; v_cB numeric; v_cC numeric;
  v_tot numeric;
  v_satA boolean; v_satB boolean; v_satC boolean;
  v_legacyA numeric; v_legacyB numeric; v_legacyC numeric;
  v_mismatch int := 0;
  v_src text;
  v_vdef text;
BEGIN
  DELETE FROM golden.scratch WHERE fixture_id = 70;

  ---------------------------------------------------------------- 0. RESOLVE --
  c_wh := public.wh_central_id();

  -- The product is chosen for having NO pickable stock ANYWHERE, so the 21 units
  -- planted below are the entire supply and the contest is fully self-supplied.
  SELECT bp.product_id INTO c_bpid
    FROM public.boonz_products bp
   WHERE NOT EXISTS (SELECT 1 FROM public.v_wh_pickable wp WHERE wp.boonz_product_id = bp.product_id)
   ORDER BY bp.product_id
   LIMIT 1;

  SELECT COALESCE(SUM(wp.warehouse_stock), 0) INTO v_pre_pick
    FROM public.v_wh_pickable wp WHERE wp.boonz_product_id = c_bpid;

  SELECT m.machine_id INTO c_mA FROM public.machines m
    JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id
   WHERE m.primary_warehouse_id = c_wh AND m.repurposed_at IS NULL AND m.status = 'Active'
   GROUP BY m.machine_id ORDER BY m.machine_id OFFSET 0 LIMIT 1;
  SELECT m.machine_id INTO c_mB FROM public.machines m
    JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id
   WHERE m.primary_warehouse_id = c_wh AND m.repurposed_at IS NULL AND m.status = 'Active'
   GROUP BY m.machine_id ORDER BY m.machine_id OFFSET 1 LIMIT 1;
  SELECT m.machine_id INTO c_mC FROM public.machines m
    JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id
   WHERE m.primary_warehouse_id = c_wh AND m.repurposed_at IS NULL AND m.status = 'Active'
   GROUP BY m.machine_id ORDER BY m.machine_id OFFSET 2 LIMIT 1;

  SELECT count(*) INTO v_n_mach
    FROM (SELECT c_mA AS m UNION SELECT c_mB UNION SELECT c_mC) q WHERE q.m IS NOT NULL;

  SELECT sc.shelf_id INTO c_sA FROM public.shelf_configurations sc
   WHERE sc.machine_id = c_mA ORDER BY sc.shelf_id LIMIT 1;
  SELECT sc.shelf_id INTO c_sB FROM public.shelf_configurations sc
   WHERE sc.machine_id = c_mB ORDER BY sc.shelf_id LIMIT 1;
  SELECT sc.shelf_id INTO c_sC FROM public.shelf_configurations sc
   WHERE sc.machine_id = c_mC ORDER BY sc.shelf_id LIMIT 1;

  SELECT pp.pod_product_id INTO c_pod FROM public.pod_products pp ORDER BY pp.pod_product_id LIMIT 1;

  -- LAW 12: the window must be virgin before anything is planted into it.
  v_virgin := NOT (
       EXISTS (SELECT 1 FROM public.machines_to_visit  WHERE plan_date     = c_date)
    OR EXISTS (SELECT 1 FROM public.pod_refill_plan    WHERE plan_date     = c_date)
    OR EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_date = c_date)
    OR EXISTS (SELECT 1 FROM public.refill_plan_output WHERE plan_date     = c_date));

  ------------------------------------------------- 1. STRUCTURE (no writes) --
  SELECT p.prosrc INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'wh_fefo_for_line';

  SELECT pg_get_viewdef(c.oid, true) INTO v_vdef
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'v_dispatch_availability';

  s_struct := jsonb_build_object(
    'canon_objects',
      (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'v_dispatch_open_wh_commitment'),
    'canon_relkind',
      COALESCE((SELECT c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_dispatch_open_wh_commitment'), 'absent'),
    'canon_clauses',
      COALESCE((SELECT (CASE WHEN d ~* 'Refill'            THEN 1 ELSE 0 END)
                     + (CASE WHEN d ~* 'Add New'           THEN 1 ELSE 0 END)
                     + (CASE WHEN d ~* 'packed'            THEN 1 ELSE 0 END)
                     + (CASE WHEN d ~* 'picked_up'         THEN 1 ELSE 0 END)
                     + (CASE WHEN d ~* 'source_origin'     THEN 1 ELSE 0 END)
                     + (CASE WHEN d ~* 'cancelled'         THEN 1 ELSE 0 END)
                     + (CASE WHEN d ~* 'skipped'           THEN 1 ELSE 0 END)
                     + (CASE WHEN d ~* 'not_filled'        THEN 1 ELSE 0 END)
                 FROM (SELECT pg_get_viewdef(c.oid, true) AS d FROM pg_class c
                        JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'public' AND c.relname = 'v_dispatch_open_wh_commitment') z), -1),
    'fefo_refs_canon',
      (SELECT count(*) FROM regexp_matches(v_src, 'v_dispatch_open_wh_commitment', 'g')),
    'fefo_inline_rd',
      (SELECT count(*) FROM regexp_matches(v_src, 'refill_dispatching', 'g')),
    'fefo_has_col',
      (SELECT CASE WHEN v_src ~* 'committed_elsewhere' THEN 'yes' ELSE 'no' END),
    'va_refs_canon',
      (SELECT count(*) FROM regexp_matches(v_vdef, 'v_dispatch_open_wh_commitment', 'g')),
    'va_inline_predicate',
      (SELECT count(*) FROM regexp_matches(v_vdef, 'not_filled', 'g')),
    'va_window_orders_by',
      (SELECT CASE WHEN v_vdef ~* 'ORDER BY rd\.dispatch_id|ORDER BY oc\.dispatch_id|ORDER BY d\.dispatch_id'
                   THEN 'dispatch_id' ELSE 'other' END),
    'canon_anon_grant',
      (SELECT CASE WHEN has_table_privilege('anon', 'public.v_dispatch_open_wh_commitment', 'SELECT')
                   THEN 'yes' ELSE 'no' END
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'v_dispatch_open_wh_commitment'),
    'canon_auth_grant',
      (SELECT CASE WHEN has_table_privilege('authenticated', 'public.v_dispatch_open_wh_commitment', 'SELECT')
                   THEN 'yes' ELSE 'no' END
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'v_dispatch_open_wh_commitment'),
    'canon_secinvoker',
      COALESCE((SELECT CASE WHEN array_to_string(c.reloptions, ',') ~* 'security_invoker=(true|on)'
                            THEN 'yes' ELSE 'no' END
                  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_dispatch_open_wh_commitment'), 'absent'),
    'dispatch_id_default',
      COALESCE((SELECT column_default FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'refill_dispatching'
                   AND column_name = 'dispatch_id'), 'absent'));

  ---------------------------------------------------------- 2. THE CONTEST --
  -- Everything below is undone by the RAISE at the end of this block.
  IF v_virgin AND c_bpid IS NOT NULL AND v_n_mach = 3 AND c_wh IS NOT NULL THEN
  BEGIN
    PERFORM set_config('app.via_trigger', 'true', true);

    INSERT INTO public.warehouse_inventory
      (boonz_product_id, warehouse_stock, expiration_date, status, batch_id,
       snapshot_date, warehouse_id, wh_location, provenance_reason)
    VALUES (c_bpid, c_plant, DATE '2031-12-31', 'Active', 'FX70-PLANT', CURRENT_DATE,
            c_wh, 'FX70', 'snapshot');

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date,
       action, quantity, include, comment, from_warehouse_id, source_origin,
       packed, picked_up, dispatched, returned, item_added)
    VALUES (c_mA, c_sA, c_pod, c_bpid, c_date, 'Refill', c_qA, true,
            'FX70 contested line A', c_wh, 'warehouse', false, false, false, false, false)
    RETURNING dispatch_id INTO v_dA;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date,
       action, quantity, include, comment, from_warehouse_id, source_origin,
       packed, picked_up, dispatched, returned, item_added)
    VALUES (c_mB, c_sB, c_pod, c_bpid, c_date, 'Refill', c_qB, true,
            'FX70 contested line B', c_wh, 'warehouse', false, false, false, false, false)
    RETURNING dispatch_id INTO v_dB;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date,
       action, quantity, include, comment, from_warehouse_id, source_origin,
       packed, picked_up, dispatched, returned, item_added)
    VALUES (c_mC, c_sC, c_pod, c_bpid, c_date, 'Refill', c_qC, true,
            'FX70 contested line C', c_wh, 'warehouse', false, false, false, false, false)
    RETURNING dispatch_id INTO v_dC;

    PERFORM set_config('app.via_trigger', '', true);

    ------------------------------------------------- 3. THE BINDER'S ANSWER --
    SELECT f.committed_elsewhere, f.total_pickable, f.is_satisfiable
      INTO v_cA, v_tot, v_satA
      FROM public.wh_fefo_for_line(c_mA, c_bpid, c_date, c_qA, ARRAY[c_wh]) f
     ORDER BY f.pick_rank LIMIT 1;
    SELECT f.committed_elsewhere, f.is_satisfiable INTO v_cB, v_satB
      FROM public.wh_fefo_for_line(c_mB, c_bpid, c_date, c_qB, ARRAY[c_wh]) f
     ORDER BY f.pick_rank LIMIT 1;
    SELECT f.committed_elsewhere, f.is_satisfiable INTO v_cC, v_satC
      FROM public.wh_fefo_for_line(c_mC, c_bpid, c_date, c_qC, ARRAY[c_wh]) f
     ORDER BY f.pick_rank LIMIT 1;

    -- INVARIANCE (PRD-074 pattern): the PRE-convergence formula, transcribed literally
    -- from the b3cfeb77 body, recomputed here. The converged function must return exactly
    -- this. If it ever does not, the "refactor" changed behaviour and seq 21 says so.
    SELECT COALESCE(SUM(rd.quantity), 0)::numeric INTO v_legacyA
      FROM public.refill_dispatching rd
     WHERE rd.boonz_product_id = c_bpid AND rd.dispatch_date = c_date
       AND rd.machine_id <> c_mA
       AND rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text])
       AND rd.packed = false AND rd.picked_up = false
       AND rd.source_origin = 'warehouse'::public.source_origin_enum
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.skipped, false) = false
       AND COALESCE(rd.pack_outcome::text, ''::text) <> 'not_filled'::text;
    SELECT COALESCE(SUM(rd.quantity), 0)::numeric INTO v_legacyB
      FROM public.refill_dispatching rd
     WHERE rd.boonz_product_id = c_bpid AND rd.dispatch_date = c_date
       AND rd.machine_id <> c_mB
       AND rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text])
       AND rd.packed = false AND rd.picked_up = false
       AND rd.source_origin = 'warehouse'::public.source_origin_enum
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.skipped, false) = false
       AND COALESCE(rd.pack_outcome::text, ''::text) <> 'not_filled'::text;
    SELECT COALESCE(SUM(rd.quantity), 0)::numeric INTO v_legacyC
      FROM public.refill_dispatching rd
     WHERE rd.boonz_product_id = c_bpid AND rd.dispatch_date = c_date
       AND rd.machine_id <> c_mC
       AND rd.action = ANY (ARRAY['Refill'::text, 'Add New'::text])
       AND rd.packed = false AND rd.picked_up = false
       AND rd.source_origin = 'warehouse'::public.source_origin_enum
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.skipped, false) = false
       AND COALESCE(rd.pack_outcome::text, ''::text) <> 'not_filled'::text;

    v_mismatch := (CASE WHEN v_cA IS DISTINCT FROM v_legacyA THEN 1 ELSE 0 END)
                + (CASE WHEN v_cB IS DISTINCT FROM v_legacyB THEN 1 ELSE 0 END)
                + (CASE WHEN v_cC IS DISTINCT FROM v_legacyC THEN 1 ELSE 0 END);

    s_sym := jsonb_build_object(
      'cA', v_cA, 'cB', v_cB, 'cC', v_cC,
      'sum', COALESCE(v_cA,0) + COALESCE(v_cB,0) + COALESCE(v_cC,0),
      'total_pickable', v_tot,
      'zero_discount_lines',
        (CASE WHEN v_cA = 0 THEN 1 ELSE 0 END) + (CASE WHEN v_cB = 0 THEN 1 ELSE 0 END)
      + (CASE WHEN v_cC = 0 THEN 1 ELSE 0 END),
      'satisfiable_lines',
        (CASE WHEN v_satA THEN 1 ELSE 0 END) + (CASE WHEN v_satB THEN 1 ELSE 0 END)
      + (CASE WHEN v_satC THEN 1 ELSE 0 END),
      'invariance_mismatches', v_mismatch,
      'legacy', jsonb_build_object('A', v_legacyA, 'B', v_legacyB, 'C', v_legacyC));

    -------------------------------------------- 4. THE CANONICAL VIEW'S ANSWER --
    -- ⛔ Every figure here is chosen to be INVARIANT under the random dispatch_id order.
    --    min() is always 0 and exactly one row holds it; the individual values are not
    --    assertable and are recorded (sorted) for the record only.
    SELECT jsonb_build_object(
             'rows',            count(*),
             'min_reserved',    min(va.reserved_by_earlier),
             'zero_reserved_lines', count(*) FILTER (WHERE va.reserved_by_earlier = 0),
             'unblocked_lines', count(*) FILTER (WHERE va.pack_status <> 'blocked_no_wh'),
             'blocked_lines',   count(*) FILTER (WHERE va.pack_status = 'blocked_no_wh'),
             'oversubscribed',  count(*) FILTER (WHERE va.oversubscribed),
             'reserved_sorted', (SELECT jsonb_agg(x ORDER BY x)
                                   FROM (SELECT v2.reserved_by_earlier AS x
                                           FROM public.v_dispatch_availability v2
                                          WHERE v2.dispatch_id IN (v_dA, v_dB, v_dC)) q))
      INTO s_asym
      FROM public.v_dispatch_availability va
     WHERE va.dispatch_id IN (v_dA, v_dB, v_dC);

    s_premise := jsonb_build_object(
      'pre_pickable',   v_pre_pick,
      'planted_stock',  v_tot,
      'n_machines',     v_n_mach,
      'window_virgin',  CASE WHEN v_virgin THEN 'yes' ELSE 'no' END,
      'open_lines',     (SELECT count(*) FROM public.refill_dispatching
                          WHERE dispatch_date = c_date AND comment LIKE 'FX70%'),
      'demand_total',   c_qA + c_qB + c_qC,
      'contested',      CASE WHEN (c_qA + c_qB + c_qC) > v_tot AND v_tot > 0
                             AND c_qA > v_tot AND c_qB > v_tot AND c_qC > v_tot
                        THEN 'yes' ELSE 'no' END);

    RAISE EXCEPTION 'FX70_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FX70_ROLLBACK' THEN RAISE; END IF;
  END;
  ELSE
    s_premise := jsonb_build_object(
      'pre_pickable',  v_pre_pick, 'planted_stock', -1, 'n_machines', v_n_mach,
      'window_virgin', CASE WHEN v_virgin THEN 'yes' ELSE 'no' END,
      'open_lines', -1, 'demand_total', c_qA + c_qB + c_qC, 'contested', 'setup_refused');
  END IF;

  PERFORM set_config('app.via_trigger', '', true);
  PERFORM set_config('request.jwt.claims', '', true);

  ------------------------------------------------------------ 5. DIVERGENCE --
  s_diverge := jsonb_build_object(
    'sym_zero_discount',  COALESCE(s_sym->>'zero_discount_lines', 'absent'),
    'asym_zero_reserved', COALESCE(s_asym->>'zero_reserved_lines', 'absent'),
    'sym_satisfiable',    COALESCE(s_sym->>'satisfiable_lines', 'absent'),
    'asym_unblocked',     COALESCE(s_asym->>'unblocked_lines', 'absent'),
    'formulas_agree',
      CASE WHEN s_sym->>'zero_discount_lines' IS NULL OR s_asym->>'zero_reserved_lines' IS NULL
             THEN 'absent'
           WHEN (s_sym->>'zero_discount_lines') = (s_asym->>'zero_reserved_lines')
            AND (s_sym->>'satisfiable_lines')   = (s_asym->>'unblocked_lines')
             THEN 'yes' ELSE 'no' END);

  ------------------------------------------------------------- 6. RESIDUE --
  s_residue := jsonb_build_object(
    'rd',  (SELECT count(*) FROM public.refill_dispatching
             WHERE dispatch_date = c_date OR comment LIKE 'FX70%'),
    'wh',  (SELECT count(*) FROM public.warehouse_inventory WHERE wh_location = 'FX70'),
    'law12', (SELECT (SELECT count(*) FROM public.machines_to_visit  WHERE plan_date     = c_date)
                   + (SELECT count(*) FROM public.pod_refill_plan    WHERE plan_date     = c_date)
                   + (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date = c_date)
                   + (SELECT count(*) FROM public.refill_plan_output WHERE plan_date     = c_date)));

  s_gucs := jsonb_build_object(
    'via_trigger', COALESCE(NULLIF(current_setting('app.via_trigger', true), ''), '<unset>'),
    'via_rpc',     COALESCE(NULLIF(current_setting('app.via_rpc', true), ''), '<unset>'));

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (70, 'premise',  s_premise),
    (70, 'struct',   s_struct),
    (70, 'sym',      s_sym),
    (70, 'asym',     s_asym),
    (70, 'diverge',  s_diverge),
    (70, 'residue',  s_residue),
    (70, 'gucs',     s_gucs);
END $do$;
$fx70$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ============================== PREMISES (self-supplied, S-274) ==============================
(70, 1, 'D-28 premise: the product the contest is built on had ZERO pickable stock anywhere BEFORE the plant, so the 21 units below are the entire supply and the contest is fully self-supplied. A red here means live stock reached the chosen product - re-pick the product, never loosen the contest.',
 'SELECT COALESCE((SELECT value->>''pre_pickable'' FROM golden.scratch WHERE fixture_id=70 AND key=''premise''),''absent'')', 'eq', '0', true, 'P3'),
(70, 2, 'D-28 premise: the plant landed and the binder can see it - total_pickable is exactly the 21 units planted, nothing more.',
 'SELECT COALESCE((SELECT value->>''planted_stock'' FROM golden.scratch WHERE fixture_id=70 AND key=''premise''),''absent'')', 'eq', '21', true, 'P3'),
(70, 3, 'D-28 premise: three DISTINCT machines were resolved. Two machines cannot express a queue discipline (every ordering of two puts one first), so three is the minimum that separates fair-share from first-in-line.',
 'SELECT COALESCE((SELECT value->>''n_machines'' FROM golden.scratch WHERE fixture_id=70 AND key=''premise''),''absent'')', 'eq', '3', true, 'P3'),
(70, 4, 'D-28 safety (LAW 12): 2030-06-16 was virgin across machines_to_visit / pod_refill_plan / refill_dispatching / refill_plan_output before anything was planted.',
 'SELECT COALESCE((SELECT value->>''window_virgin'' FROM golden.scratch WHERE fixture_id=70 AND key=''premise''),''absent'')', 'eq', 'yes', true, 'P3'),
(70, 5, 'D-28 premise: all three lines were genuinely OPEN warehouse commitments at measurement time - unpacked, unpicked, warehouse-sourced, not cancelled/skipped/not_filled. This is the population the whole ruling is about.',
 'SELECT COALESCE((SELECT value->>''open_lines'' FROM golden.scratch WHERE fixture_id=70 AND key=''premise''),''absent'')', 'eq', '3', true, 'P3'),
(70, 6, 'D-28 premise: the batch is scarce against EVERY line individually (21 < 25 < 30 < 40), not merely against their sum. Without this, the head of the queue could be satisfied outright and the pack_status comparison at seq 26 would depend on which random uuid won.',
 'SELECT COALESCE((SELECT value->>''contested'' FROM golden.scratch WHERE fixture_id=70 AND key=''premise''),''absent'')', 'eq', 'yes', true, 'P3'),

-- ============================== STRUCTURE — the convergence (RED before) ==============================
(70, 7, 'D-28 CONVERGENCE: exactly one canonical object defines an open warehouse commitment (RED until the convergence lands).',
 'SELECT COALESCE((SELECT value->>''canon_objects'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', '1', true, 'P3'),
(70, 8, 'D-28 CONVERGENCE: the canonical object is a VIEW, not a materialized view or a table - it must never go stale against refill_dispatching, which changes inside the same session that reads it.',
 'SELECT COALESCE((SELECT value->>''canon_relkind'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', 'v', true, 'P3'),
(70, 9, 'D-28 anti-vacuity (S-162 family): the canonical object still CARRIES all eight predicate markers. An empty view would satisfy seqs 10 and 12 - the copies would be gone because the rule would be gone.',
 'SELECT COALESCE((SELECT value->>''canon_clauses'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', '8', true, 'P3'),
(70, 10, 'D-28 CONVERGENCE: wh_fefo_for_line reads the canonical object (RED until the convergence lands).',
 'SELECT COALESCE((SELECT value->>''fefo_refs_canon'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'gte', '1', true, 'P3'),
(70, 11, 'D-28 CONVERGENCE: wh_fefo_for_line no longer names refill_dispatching at all - the inline copy is RETIRED, not merely shadowed by a call it makes alongside (fixture 61 seq 5 idiom).',
 'SELECT COALESCE((SELECT value->>''fefo_inline_rd'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', '0', true, 'P3'),
(70, 12, 'D-28 anti-vacuity: wh_fefo_for_line still RETURNS committed_elsewhere. Deleting the column would satisfy seq 11 and silently un-discount every FEFO walk in the fleet.',
 'SELECT COALESCE((SELECT value->>''fefo_has_col'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', 'yes', true, 'P3'),
(70, 13, 'D-28 CONVERGENCE: v_dispatch_availability reads the canonical object too. Converging only the function would leave Article 16 registering a canonical object that still carries its own private copy of the rule.',
 'SELECT COALESCE((SELECT value->>''va_refs_canon'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'gte', '1', true, 'P3'),
(70, 14, 'D-28 CONVERGENCE: the seven-clause predicate no longer appears in v_dispatch_availability - it was written there TWICE (product-partition window and machine-partition window), so this counts the marker, not the clause.',
 'SELECT COALESCE((SELECT value->>''va_inline_predicate'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', '0', true, 'P3'),
(70, 15, 'D-28 S-268: the canonical view is NOT readable by anon. REVOKE ... FROM PUBLIC does not remove Supabase schema default privileges; anon must be named.',
 'SELECT COALESCE((SELECT value->>''canon_anon_grant'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', 'no', true, 'P3'),
(70, 16, 'D-28 grant necessity: authenticated CAN read it. wh_fefo_for_line is SECURITY INVOKER and is called by two invoker-rights functions granted to authenticated (resolve_fefo_sku_legs_v3, find_substitutes_for_shelf_v3) - without this grant the convergence breaks both.',
 'SELECT COALESCE((SELECT value->>''canon_auth_grant'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', 'yes', true, 'P3'),
(70, 17, 'D-28: the canonical view is NOT security_invoker. v_dispatch_availability is postgres-owned and reads refill_dispatching with owner privileges today; a security_invoker inner view would silently apply the READER''s RLS and hand anon a reserved_by_earlier of 0 where it reads a real number now.',
 'SELECT COALESCE((SELECT value->>''canon_secinvoker'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', 'no', true, 'P3'),

-- ============================== INVARIANCE — green BEFORE and AFTER ==============================
(70, 18, 'D-28 INVARIANCE: machine A is discounted by the whole rest of the field - 30 + 25 = 55. This is the live binder''s answer and the convergence must not move it by one unit.',
 'SELECT COALESCE((SELECT value->>''cA'' FROM golden.scratch WHERE fixture_id=70 AND key=''sym''),''absent'')', 'eq', '55', true, 'P3'),
(70, 19, 'D-28 INVARIANCE: machine B is discounted by 40 + 25 = 65.',
 'SELECT COALESCE((SELECT value->>''cB'' FROM golden.scratch WHERE fixture_id=70 AND key=''sym''),''absent'')', 'eq', '65', true, 'P3'),
(70, 20, 'D-28 INVARIANCE: machine C is discounted by 40 + 30 = 70.',
 'SELECT COALESCE((SELECT value->>''cC'' FROM golden.scratch WHERE fixture_id=70 AND key=''sym''),''absent'')', 'eq', '70', true, 'P3'),
(70, 21, 'D-28 INVARIANCE (PRD-074 pattern): the converged function returns exactly what the PRE-convergence formula, transcribed literally from the b3cfeb77 body and recomputed inside this fixture, returns - on all three lines. A refactor that changes behaviour is not a refactor.',
 'SELECT COALESCE((SELECT value->>''invariance_mismatches'' FROM golden.scratch WHERE fixture_id=70 AND key=''sym''),''absent'')', 'eq', '0', true, 'P3'),
(70, 22, 'D-28 SYMMETRY SIGNATURE: the three discounts sum to 190 = 2 x 95. Every line discounting itself by the whole rest of the field means the total demand is counted exactly (n-1) times. This single number is what makes the formula symmetric and order-independent, and it is what changes if anyone converges the ARITHMETIC rather than the predicate.',
 'SELECT COALESCE((SELECT value->>''sum'' FROM golden.scratch WHERE fixture_id=70 AND key=''sym''),''absent'')', 'eq', '190', true, 'P3'),

-- ============================== THE BEFORE/AFTER DIFF CS ASKED FOR ==============================
(70, 23, 'D-28 DIFF (binder side): under the binder''s symmetric rule NO line is left undiscounted - a contested batch makes everyone look short, so all three back off.',
 'SELECT COALESCE((SELECT value->>''sym_zero_discount'' FROM golden.scratch WHERE fixture_id=70 AND key=''diverge''),''absent'')', 'eq', '0', true, 'P3'),
(70, 24, 'D-28 DIFF (canonical side): under v_dispatch_availability EXACTLY ONE line is charged nothing. That is the whole policy difference, stated in a way the random dispatch_id order cannot flip.',
 'SELECT COALESCE((SELECT value->>''asym_zero_reserved'' FROM golden.scratch WHERE fixture_id=70 AND key=''diverge''),''absent'')', 'eq', '1', true, 'P3'),
(70, 25, 'D-28 DIFF (FEFO-visible availability, binder side): ZERO lines are satisfiable. This is the number the ruling asked to see before and after, and off live data it is vacuous - leg 148 measured open_wh_lines = 0 on every dispatch_date in 60 days.',
 'SELECT COALESCE((SELECT value->>''sym_satisfiable'' FROM golden.scratch WHERE fixture_id=70 AND key=''diverge''),''absent'')', 'eq', '0', true, 'P3'),
(70, 26, 'D-28 DIFF (FEFO-visible availability, canonical side): exactly ONE line is not blocked_no_wh. One machine would be packed and two would be refused, where the binder refuses all three.',
 'SELECT COALESCE((SELECT value->>''asym_unblocked'' FROM golden.scratch WHERE fixture_id=70 AND key=''diverge''),''absent'')', 'eq', '1', true, 'P3'),
(70, 27, 'D-28 THE PARKED HALF, PINNED: the two formulas DISAGREE on constructed data. This assertion is deliberately green-as-no - converging the predicate does not converge the arithmetic, and it cannot: wh_fefo_for_line runs BEFORE its own dispatch row exists, so there is no dispatch_id for it to be earlier than. The day someone makes them agree, this goes red and the change gets the Article-16 review it needs.',
 'SELECT COALESCE((SELECT value->>''formulas_agree'' FROM golden.scratch WHERE fixture_id=70 AND key=''diverge''),''absent'')', 'eq', 'no', true, 'P3'),
(70, 28, 'D-28 S-280: refill_dispatching.dispatch_id defaults to gen_random_uuid(). The canonical object''s queue discipline is therefore a RANDOM tiebreak, NOT first-come-first-served - leg 148''s addendum called it FCFS and that is wrong. If this column ever becomes time-ordered the divergence changes character and this fixture must be restated.',
 'SELECT COALESCE((SELECT value->>''dispatch_id_default'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'contains', 'gen_random_uuid', true, 'P3'),
(70, 29, 'D-28 S-280 corollary: v_dispatch_availability still orders its window by dispatch_id rather than created_at. Read with seq 28 this is the whole finding: who wins a contested batch is decided by a random number.',
 'SELECT COALESCE((SELECT value->>''va_window_orders_by'' FROM golden.scratch WHERE fixture_id=70 AND key=''struct''),''absent'')', 'eq', 'dispatch_id', true, 'P3'),
(70, 30, 'D-28 anti-flake: the canonical side''s minimum reserved_by_earlier is 0. Together with seq 24 this is the only pair of statements about the view that survives every permutation of three random uuids - the individual values are recorded in scratch but never asserted.',
 'SELECT COALESCE((SELECT value->>''min_reserved'' FROM golden.scratch WHERE fixture_id=70 AND key=''asym''),''absent'')', 'eq', '0', true, 'P3'),

-- ============================== RESIDUE ==============================
(70, 31, 'D-28 residue: ZERO refill_dispatching rows survive. The three contested lines existed only inside a subtransaction that RAISEd - no DELETE was ever issued against a protected table.',
 'SELECT COALESCE((SELECT value->>''rd'' FROM golden.scratch WHERE fixture_id=70 AND key=''residue''),''absent'')', 'eq', '0', true, 'P3'),
(70, 32, 'D-28 residue: ZERO warehouse_inventory rows carry wh_location FX70. Article 7 matters here - warehouse_inventory is referenced by the append-only inventory_audit_log, so a delete-based reclaim would have had to erase audit rows. Rolling back never writes them.',
 'SELECT COALESCE((SELECT value->>''wh'' FROM golden.scratch WHERE fixture_id=70 AND key=''residue''),''absent'')', 'eq', '0', true, 'P3'),
(70, 33, 'D-28 LAW 12: the fixture date holds zero rows across all four plan tables AFTER the run.',
 'SELECT COALESCE((SELECT value->>''law12'' FROM golden.scratch WHERE fixture_id=70 AND key=''residue''),''absent'')', 'eq', '0', true, 'P3'),
(70, 34, 'D-28 residue: app.via_trigger does not leak out of the fixture. It was set to true for the plant only, and the enforce_canonical_dispatch_write bypass logger stayed quiet because of it.',
 'SELECT COALESCE((SELECT value->>''via_trigger'' FROM golden.scratch WHERE fixture_id=70 AND key=''gucs''),''absent'')', 'eq', '<unset>', true, 'P3');
