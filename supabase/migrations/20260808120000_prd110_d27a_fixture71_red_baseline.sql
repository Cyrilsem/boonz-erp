-- PRD-110 · D-27(a) · leg 150
-- FIXTURE 71 — RED BASELINE, applied and fired BEFORE the de-duplication migration (LAW 1).
--
-- D-27 ruling (CS 2026-08-01): "converge rung-4 velocity onto the canonical in-stock object.
-- Own reviewed unit, own before/after diff of donor-set changes. Never a drive-by."
--
-- ⛔ THE RULING IS TWO SEPARABLE MOVES AND THIS FIXTURE COVERS ONLY THE FIRST (leg 149 addendum):
--    (a) DE-DUPLICATE the donor-surplus rule into one object both sites read.  <-- THIS UNIT
--        Behaviour-invariant BY CONSTRUCTION; no policy content whatsoever.
--    (b) CONVERGE THE VELOCITY TERM off COALESCE(velocity_instock, velocity_raw, 0).
--        ⛔ That one really does move which machines qualify as donors. NOT in this unit.
--
-- ⛔⛔ WHAT LEG 150 MEASURED THAT MAKES (b) BIGGER THAN THE ADDENDUM HOPED (S-282):
--    `v_shelf_state.velocity_instock` is literally `NULL::numeric` — a hardcoded NULL column,
--    derived from nothing. So COALESCE(velocity_instock, velocity_raw, 0) resolves to
--    velocity_raw for EVERY row, unconditionally and forever, not merely "in practice"
--    (S-73's weaker phrasing). 0 of 656 v_shelf_state rows carry a non-NULL velocity_instock.
--    The first arm of that COALESCE is DEAD CODE. (b) is therefore not "delete a defensive
--    COALESCE" — it is choosing a genuinely different velocity source. seq 3 pins the fact.
--
-- ⛔⛔ THE ARITHMETIC ASYMMETRY THIS UNIT MUST PRESERVE EXACTLY, AND WHY (S-281):
--    The two sites are verbatim mirrors of the same rule, but they ROUND DIFFERENTLY:
--      · list_m2m_donors_v3 casts EACH ROW's excess to ::int, then callers sum.
--      · resolve_supply_ladder_v3 sums the NUMERIC excess and rounds ONCE at the end
--        (v_donor_units is declared numeric; v_av4 := LEAST(qty, v_donor_units)::int).
--    Measured live at leg 150: 353 donor rows over 57 pods, 46 rows fractional,
--    sum-of-rounded 2014 vs rounded-of-sum 2012, and 17 of 57 pods disagree.
--    ⛔ A de-dup that made BOTH sites read one ::int column would silently move rung-4
--    availability on 17 pods. The canonical object therefore exposes BOTH an exact numeric
--    excess and a rounded int excess, and seqs 18-21 + 24 + 27 pin which site reads which.
--
-- ⛔ AND THE ART-16 PIN CODY RELIED ON IS NARROWER THAN IT READS (S-281):
--    Fixture 45 seq 5 pins "the two objects agree on TOTAL donor excess" at ONE pod
--    (b1827ff7). That pod's 5 donor rows happen to have integral excess, so the pin is green
--    by luck of the arithmetic. Fleet-wide the two formulas ALREADY disagree on 17 of 57 pods.
--    The mirror was tolerated on a pin that never covered the divergence it was meant to catch.
--
-- ⭐ THIS FIXTURE WRITES NOTHING. The donor rule is a pure read over live state, so there is
--    no plant, no subtransaction, no RAISE and no DELETE against any protected table. Its
--    population is genuinely live, so every assertion is stated as a PROPERTY or an INVARIANCE
--    (S-257: an assertion anchored to a moment rots), and the four premise sensors at seqs 1-4
--    fail LOUDLY and by name if live data ever stops supplying the case (S-274).
--
-- ⛔ S-266: golden.scratch is written at the END, in one statement, never mid-scenario.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  71,
  'D-27(a): one canonical definition of an m2m donor surplus. The overstock rule that decides which shelves may donate stock to another machine - GREATEST(current_stock - GREATEST(velocity*7, 5), 0) - was written verbatim in two places: list_m2m_donors_v3 (the object stitch_v3 calls to NAME a donor) and resolve_supply_ladder_v3 rung 4 (the object that decides whether rung 4 is satisfiable at all). It now lives in one view both read. ⛔ The two sites round DIFFERENTLY - per-row ::int vs one numeric sum rounded at the end - and that asymmetry is DELIBERATELY PRESERVED, because converging it moves rung-4 availability on 17 of 57 live pods and that is a policy change requiring its own Article-16 review, not a refactor.',
  'D-27 (CS 2026-08-01) · raised by Cody at the rung-4 review · Article 16',
  'P3',
  DATE '2030-06-18',
  true,
  'failing_expected',
  'Leg 150. RED baseline applied and fired before 20260808120500. Structural seqs 7-21 red until the de-dup lands; premise seqs 1-6 and invariance seqs 22-28 are green on BOTH sides - a refactor that changes behaviour is not a refactor (fixture 61 seq 7 / fixture 70 seq 21 idiom).',
$fx71$
DO $do$
DECLARE
  c_date        date := DATE '2030-06-18';

  v_donors_src  text;
  v_ladder_src  text;
  v_vdef        text;

  -- premise
  v_rows        int := 0;
  v_pods        int := 0;
  v_frac_rows   int := 0;
  v_frac_pods   int := 0;
  v_instock_nn  int := 0;

  -- the ladder probe pod/machine (chosen deterministically, never pinned)
  v_pod         uuid;
  v_mach        uuid;
  v_shelf       uuid;
  v_lad_donors  int := -1;
  v_lad_excess  numeric := -1;
  v_leg_donors  int := -1;
  v_leg_exc_num numeric := -1;
  v_leg_exc_int int := -1;
  v_after_excl  int := -1;
  v_ladder_json jsonb;

  -- invariance
  v_mism_rows   int := -1;
  v_mism_mach   int := -1;
  v_mism_sumint int := -1;
  v_order_ok    text := 'absent';

  -- anon baseline
  v_anon        text := 'absent';
  v_anon_msg    text := 'absent';

  s_premise  jsonb := '{}'::jsonb;
  s_struct   jsonb := '{}'::jsonb;
  s_round    jsonb := '{}'::jsonb;
  s_inv      jsonb := '{}'::jsonb;
  s_residue  jsonb := '{}'::jsonb;
  s_gucs     jsonb := '{}'::jsonb;
BEGIN
  DELETE FROM golden.scratch WHERE fixture_id = 71;

  ---------------------------------------------------------------- 0. SOURCES --
  SELECT p.prosrc INTO v_donors_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'list_m2m_donors_v3';

  SELECT p.prosrc INTO v_ladder_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'resolve_supply_ladder_v3';

  SELECT pg_get_viewdef(c.oid, true) INTO v_vdef
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus';

  ------------------------------------------------- 1. PREMISE (live supply) --
  -- The LEGACY rule, transcribed literally from the 42198fee / 920b32d0 bodies. Everything
  -- downstream is measured against THIS, never against the object under test (S-267).
  SELECT count(*),
         count(DISTINCT s.pod_product_id),
         count(*) FILTER (
           WHERE (s.current_stock - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5))
                 <> round(s.current_stock - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)))
    INTO v_rows, v_pods, v_frac_rows
    FROM public.v_shelf_state s
   WHERE s.pod_product_id IS NOT NULL
     AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5);

  -- The pods where the two sites' rounding genuinely disagrees. If this ever reaches 0 the
  -- unit's whole reason for exposing two excess columns has evaporated and seq 4 says so.
  SELECT count(*) INTO v_frac_pods FROM (
    SELECT s.pod_product_id
      FROM public.v_shelf_state s
     WHERE s.pod_product_id IS NOT NULL
       AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)
     GROUP BY s.pod_product_id
    HAVING SUM(s.current_stock - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5))
        <> SUM(GREATEST(s.current_stock - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5), 0)::int)
  ) q;

  SELECT count(*) INTO v_instock_nn
    FROM public.v_shelf_state s WHERE s.velocity_instock IS NOT NULL;

  ------------------------------------------- 2. STRUCTURE (catalogue, no writes) --
  s_struct := jsonb_build_object(
    'canon_objects',
      (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus'),
    'canon_relkind',
      COALESCE((SELECT c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus'), 'absent'),
    'canon_markers',
      COALESCE((SELECT (CASE WHEN v_vdef ~* 'velocity_instock' THEN 1 ELSE 0 END)
                     + (CASE WHEN v_vdef ~* 'velocity_raw'     THEN 1 ELSE 0 END)
                     + (CASE WHEN v_vdef ~* '\* 7'             THEN 1 ELSE 0 END)
                     + (CASE WHEN v_vdef ~* '5::numeric'       THEN 1 ELSE 0 END)
                     + (CASE WHEN v_vdef ~* 'GREATEST'         THEN 1 ELSE 0 END)
                     + (CASE WHEN v_vdef ~* 'current_stock'    THEN 1 ELSE 0 END)), -1),
    'donors_refs_canon',
      (SELECT count(*) FROM regexp_matches(v_donors_src, 'v_m2m_donor_surplus', 'g')),
    'donors_inline_vss',
      (SELECT count(*) FROM regexp_matches(v_donors_src, 'v_shelf_state', 'g')),
    'donors_has_excess_col',
      (SELECT CASE WHEN pg_get_function_result(p.oid) ~* 'excess_units' THEN 'yes' ELSE 'no' END
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'list_m2m_donors_v3'),
    'ladder_refs_canon',
      (SELECT count(*) FROM regexp_matches(v_ladder_src, 'v_m2m_donor_surplus', 'g')),
    'ladder_inline_velocity',
      (SELECT count(*) FROM regexp_matches(v_ladder_src, 'velocity_instock', 'g')),
    'canon_anon_grant',
      COALESCE((SELECT CASE WHEN has_table_privilege('anon', c.oid, 'SELECT') THEN 'yes' ELSE 'no' END
                  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus'), 'absent'),
    'canon_auth_grant',
      COALESCE((SELECT CASE WHEN has_table_privilege('authenticated', c.oid, 'SELECT') THEN 'yes' ELSE 'no' END
                  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus'), 'absent'),
    'canon_secinvoker',
      COALESCE((SELECT CASE WHEN array_to_string(c.reloptions, ',') ~* 'security_invoker=(true|on)'
                            THEN 'yes' ELSE 'no' END
                  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus'), 'absent'));

  ------------------------------------------- 3. THE ROUNDING SEAM (structure) --
  s_round := jsonb_build_object(
    'excess_exact_type',
      COALESCE((SELECT format_type(a.atttypid, a.atttypmod)
                  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus'
                   AND a.attname = 'excess_exact'), 'absent'),
    'excess_units_type',
      COALESCE((SELECT format_type(a.atttypid, a.atttypmod)
                  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus'
                   AND a.attname = 'excess_units'), 'absent'),
    'donors_reads_int',
      CASE WHEN v_donors_src ~* 'excess_units' THEN 'yes' ELSE 'no' END,
    'ladder_reads_exact',
      CASE WHEN v_ladder_src ~* 'excess_exact' THEN 'yes' ELSE 'no' END);

  ------------------------------------------------------- 4. THE LADDER PROBE --
  -- Chosen deterministically from live state, never pinned to a uuid (S-257): the pod with
  -- the most donor rows, excluding the machine holding the single largest excess for it.
  SELECT s.pod_product_id INTO v_pod
    FROM public.v_shelf_state s
   WHERE s.pod_product_id IS NOT NULL
     AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)
   GROUP BY s.pod_product_id
   HAVING count(DISTINCT s.machine_id) >= 2
   ORDER BY count(*) DESC, s.pod_product_id
   LIMIT 1;

  IF v_pod IS NOT NULL THEN
    SELECT s.machine_id INTO v_mach
      FROM public.v_shelf_state s
     WHERE s.pod_product_id = v_pod
       AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)
     ORDER BY (s.current_stock - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)) DESC,
              s.machine_id
     LIMIT 1;

    SELECT sc.shelf_id INTO v_shelf
      FROM public.shelf_configurations sc
     WHERE sc.machine_id = v_mach ORDER BY sc.shelf_id LIMIT 1;

    -- LEGACY rung-4 arithmetic, transcribed literally, with the SAME exclusion the ladder makes.
    SELECT COALESCE(SUM(GREATEST(
             s.current_stock - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5), 0)), 0),
           count(DISTINCT s.machine_id),
           COALESCE(SUM(GREATEST(
             s.current_stock - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5), 0)::int), 0),
           count(*)
      INTO v_leg_exc_num, v_leg_donors, v_leg_exc_int, v_after_excl
      FROM public.v_shelf_state s
     WHERE s.pod_product_id = v_pod
       AND s.machine_id <> v_mach
       AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5);

    IF v_shelf IS NOT NULL AND v_after_excl > 0 THEN
      BEGIN
        SELECT public.resolve_supply_ladder_v3(c_date, v_mach, v_shelf, v_pod, 5, 3)
          INTO v_ladder_json;
        SELECT (e->'detail'->>'donor_machines')::int,
               (e->'detail'->>'donor_excess_units')::numeric
          INTO v_lad_donors, v_lad_excess
          FROM jsonb_array_elements(v_ladder_json->'ladder') e
         WHERE e->>'rung' = 'm2m'
         LIMIT 1;
      EXCEPTION WHEN OTHERS THEN
        v_lad_donors := -2; v_lad_excess := -2;
      END;
    END IF;
  END IF;

  -------------------------------------------------- 5. INVARIANCE (per pod) --
  -- list_m2m_donors_v3 vs the legacy rule, over EVERY pod that has donors. Zero mismatches
  -- is the whole claim of a de-duplication: the object may be rewritten, its answers may not.
  SELECT count(*) FILTER (WHERE d.n_rows IS DISTINCT FROM l.n_rows),
         count(*) FILTER (WHERE d.n_mach  IS DISTINCT FROM l.n_mach),
         count(*) FILTER (WHERE d.sum_int IS DISTINCT FROM l.sum_int)
    INTO v_mism_rows, v_mism_mach, v_mism_sumint
    FROM (
      SELECT s.pod_product_id AS pod,
             count(*) AS n_rows,
             count(DISTINCT s.machine_id) AS n_mach,
             COALESCE(SUM(GREATEST(s.current_stock
               - GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5), 0)::int), 0) AS sum_int
        FROM public.v_shelf_state s
       WHERE s.pod_product_id IS NOT NULL
         AND s.current_stock > GREATEST(COALESCE(s.velocity_instock, s.velocity_raw, 0) * 7, 5)
       GROUP BY s.pod_product_id) l
    LEFT JOIN LATERAL (
      SELECT count(*) AS n_rows,
             count(DISTINCT g.donor_machine_id) AS n_mach,
             COALESCE(SUM(g.excess_units), 0) AS sum_int
        FROM public.list_m2m_donors_v3(l.pod, NULL) g) d ON true;

  -- Ordering is excess-DESC and TOTAL: stitch_v3's donor choice must be reproducible.
  SELECT CASE WHEN v_pod IS NULL THEN 'absent'
              WHEN (SELECT g.excess_units FROM public.list_m2m_donors_v3(v_pod, NULL) g LIMIT 1)
                 = (SELECT max(g2.excess_units) FROM public.list_m2m_donors_v3(v_pod, NULL) g2)
              THEN 'true' ELSE 'false' END
    INTO v_order_ok;

  -------------------------------------------------------- 6. ANON BASELINE --
  -- list_m2m_donors_v3 carries anon EXECUTE and is SECURITY INVOKER, but v_shelf_state grants
  -- SELECT only to postgres/authenticated/service_role - so the anon path is ALREADY refused
  -- today. Recording it here proves the de-dup cannot introduce a NEW anon refusal the way
  -- D-28 did; only the object NAMED in the message moves.
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.list_m2m_donors_v3(v_pod, NULL);
    v_anon := 'readable';
  EXCEPTION WHEN OTHERS THEN
    v_anon := 'refused'; v_anon_msg := SQLERRM;
  END;
  RESET ROLE;

  ------------------------------------------------------------- 7. ASSEMBLE --
  s_premise := jsonb_build_object(
    'donor_rows',     v_rows,
    'donor_pods',     v_pods,
    'frac_rows',      v_frac_rows,
    'frac_pods',      v_frac_pods,
    'instock_notnull', v_instock_nn,
    'after_excl',     v_after_excl,
    'anon',           v_anon,
    'anon_msg',       v_anon_msg);

  s_inv := jsonb_build_object(
    'mismatch_rows',   v_mism_rows,
    'mismatch_mach',   v_mism_mach,
    'mismatch_sumint', v_mism_sumint,
    'order_ok',        v_order_ok,
    'ladder_donors',   v_lad_donors,
    'legacy_donors',   v_leg_donors,
    'ladder_excess',   v_lad_excess,
    'legacy_exc_num',  v_leg_exc_num,
    'legacy_exc_int',  v_leg_exc_int,
    'ladder_donors_match',
      CASE WHEN v_lad_donors < 0 THEN 'absent'
           WHEN v_lad_donors = v_leg_donors THEN 'true' ELSE 'false' END,
    'ladder_excess_match',
      CASE WHEN v_lad_excess < 0 THEN 'absent'
           WHEN v_lad_excess = v_leg_exc_num THEN 'true' ELSE 'false' END);

  -- LAW 12: the probe date must be, and remain, empty across all four plan tables. The ladder
  -- is STABLE and writes nothing; this measures that rather than asserting it from the docs.
  s_residue := jsonb_build_object(
    'law12', (SELECT (SELECT count(*) FROM public.machines_to_visit  WHERE plan_date     = c_date)
                   + (SELECT count(*) FROM public.pod_refill_plan    WHERE plan_date     = c_date)
                   + (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date = c_date)
                   + (SELECT count(*) FROM public.refill_plan_output WHERE plan_date     = c_date)),
    'canon_objects_after',
      (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'v_m2m_donor_surplus'));

  s_gucs := jsonb_build_object(
    'via_trigger', COALESCE(NULLIF(current_setting('app.via_trigger', true), ''), '<unset>'),
    'via_rpc',     COALESCE(NULLIF(current_setting('app.via_rpc', true), ''), '<unset>'));

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (71, 'premise', s_premise),
    (71, 'struct',  s_struct),
    (71, 'round',   s_round),
    (71, 'inv',     s_inv),
    (71, 'residue', s_residue),
    (71, 'gucs',    s_gucs);
END $do$;
$fx71$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ============================== PREMISES — live data must keep supplying the case (S-274) ==============================
(71, 1, 'D-27(a) premise: live state supplies a non-empty donor population. This fixture plants nothing - the donor rule is a pure read - so if the fleet ever carries zero overstocked shelves every invariance assertion below would pass vacuously. It fails HERE and by name instead.',
 'SELECT COALESCE((SELECT value->>''donor_rows'' FROM golden.scratch WHERE fixture_id=71 AND key=''premise''),''absent'')', 'gte', '1', true, 'P3'),
(71, 2, 'D-27(a) premise: the donor population spans at least two pods, so the per-pod invariance sweep at seqs 22-24 is comparing a real set rather than one row.',
 'SELECT COALESCE((SELECT value->>''donor_pods'' FROM golden.scratch WHERE fixture_id=71 AND key=''premise''),''absent'')', 'gte', '2', true, 'P3'),
(71, 3, 'D-27(a) S-282: v_shelf_state.velocity_instock is a hardcoded NULL::numeric column - ZERO rows carry a value. COALESCE(velocity_instock, velocity_raw, 0) therefore resolves to velocity_raw unconditionally and the first arm is DEAD CODE. ⛔ This is why D-27(b) is a real policy change and not the "delete a defensive COALESCE" the leg-149 addendum hoped for. The day this stops being 0, (b) has changed shape and must be re-scoped.',
 'SELECT COALESCE((SELECT value->>''instock_notnull'' FROM golden.scratch WHERE fixture_id=71 AND key=''premise''),''absent'')', 'eq', '0', true, 'P3'),
(71, 4, 'D-27(a) S-281 PREMISE SENSOR - the reason this unit exposes TWO excess columns: at least one pod''s donors sum differently under per-row ::int rounding than under one numeric sum rounded at the end. Measured at leg 150: 17 of 57 pods. ⛔ If this ever reads 0 the asymmetry has gone latent and seqs 20/21/24/27 would pass without discriminating - re-derive before touching the rounding.',
 'SELECT COALESCE((SELECT value->>''frac_pods'' FROM golden.scratch WHERE fixture_id=71 AND key=''premise''),''absent'')', 'gte', '1', true, 'P3'),
(71, 5, 'D-27(a) premise: the ladder probe pod still has at least one donor left AFTER excluding the destination machine, so the rung-4 comparison at seqs 26-27 is against a live number and not against zero.',
 'SELECT COALESCE((SELECT value->>''after_excl'' FROM golden.scratch WHERE fixture_id=71 AND key=''premise''),''absent'')', 'gte', '1', true, 'P3'),
(71, 6, 'D-27(a) anon BASELINE (the D-28 claim-3 analogue, measured BEFORE the change): list_m2m_donors_v3 carries anon EXECUTE and is SECURITY INVOKER, but v_shelf_state grants SELECT only to postgres/authenticated/service_role - so the anon path is ALREADY refused today. This unit therefore CANNOT introduce a new anon refusal; only the object named in the message moves. Green on both sides is the point.',
 'SELECT COALESCE((SELECT value->>''anon'' FROM golden.scratch WHERE fixture_id=71 AND key=''premise''),''absent'')', 'eq', 'refused', true, 'P3'),

-- ============================== STRUCTURE — the de-duplication (RED before) ==============================
(71, 7, 'D-27(a) DE-DUP: exactly one canonical object defines an m2m donor surplus (RED until the de-dup lands).',
 'SELECT COALESCE((SELECT value->>''canon_objects'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', '1', true, 'P3'),
(71, 8, 'D-27(a) DE-DUP: the canonical object is a VIEW, not a materialized view or a table - v_shelf_state is recomputed from WEIMI and slot_lifecycle continuously, and a stale donor set would strand real stock.',
 'SELECT COALESCE((SELECT value->>''canon_relkind'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', 'v', true, 'P3'),
(71, 9, 'D-27(a) anti-vacuity (S-162 family): the canonical view still carries all six markers of the overstock rule - velocity_instock, velocity_raw, the 7-day multiplier, the floor of 5, GREATEST and current_stock. An empty or trivial view would satisfy seqs 11 and 14 because the RULE would be gone, not the duplication.',
 'SELECT COALESCE((SELECT value->>''canon_markers'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', '6', true, 'P3'),
(71, 10, 'D-27(a) DE-DUP: list_m2m_donors_v3 reads the canonical object (RED until the de-dup lands).',
 'SELECT COALESCE((SELECT value->>''donors_refs_canon'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'gte', '1', true, 'P3'),
(71, 11, 'D-27(a) DE-DUP: list_m2m_donors_v3 no longer names v_shelf_state at all - the inline copy is RETIRED, not merely shadowed by a call made alongside it (fixture 61 seq 5 / fixture 70 seq 11 idiom).',
 'SELECT COALESCE((SELECT value->>''donors_inline_vss'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', '0', true, 'P3'),
(71, 12, 'D-27(a) anti-vacuity: list_m2m_donors_v3 still RETURNS excess_units. Dropping the column would satisfy seq 11 and silently blind stitch_v3 to how much any donor can actually spare.',
 'SELECT COALESCE((SELECT value->>''donors_has_excess_col'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', 'yes', true, 'P3'),
(71, 13, 'D-27(a) DE-DUP: resolve_supply_ladder_v3 reads the canonical object too. De-duplicating only the NAMING side would leave the object that decides whether rung 4 is satisfiable at all still carrying its own private copy of the rule - which is exactly the Article-16 state Cody raised.',
 'SELECT COALESCE((SELECT value->>''ladder_refs_canon'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'gte', '1', true, 'P3'),
(71, 14, 'D-27(a) DE-DUP: resolve_supply_ladder_v3 no longer names velocity_instock. Rung 4 was its ONLY use of that column, so this counts the whole inline copy out of a 16,996-character body without asserting anything about the other five rungs.',
 'SELECT COALESCE((SELECT value->>''ladder_inline_velocity'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', '0', true, 'P3'),
(71, 15, 'D-27(a) S-268: the canonical view is NOT readable by anon. REVOKE ALL ... FROM PUBLIC does not remove Supabase''s schema default privileges - anon must be named explicitly - and v_shelf_state itself does not grant anon, so the canonical object must not widen that surface.',
 'SELECT COALESCE((SELECT value->>''canon_anon_grant'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', 'no', true, 'P3'),
(71, 16, 'D-27(a) grant necessity: authenticated CAN read it. Both call sites are SECURITY INVOKER and both carry authenticated EXECUTE, so without this grant the de-dup would break every authenticated caller of the donor path and of the supply ladder.',
 'SELECT COALESCE((SELECT value->>''canon_auth_grant'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', 'yes', true, 'P3'),
(71, 17, 'D-27(a): the canonical view is NOT security_invoker - it matches v_shelf_state, which is postgres-owned and read with owner privileges today. Making the inner view security_invoker would apply the READER''s RLS to shelf state and silently shrink the donor set per caller.',
 'SELECT COALESCE((SELECT value->>''canon_secinvoker'' FROM golden.scratch WHERE fixture_id=71 AND key=''struct''),''absent'')', 'eq', 'no', true, 'P3'),

-- ============================== THE ROUNDING SEAM — the crux of this unit (RED before) ==============================
(71, 18, 'D-27(a) S-281: the canonical view exposes an EXACT numeric excess. The ladder sums this and rounds ONCE at the end (v_donor_units is numeric), so collapsing it to an integer column would move rung-4 availability on 17 of 57 live pods.',
 'SELECT COALESCE((SELECT value->>''excess_exact_type'' FROM golden.scratch WHERE fixture_id=71 AND key=''round''),''absent'')', 'eq', 'numeric', true, 'P3'),
(71, 19, 'D-27(a) S-281: the canonical view ALSO exposes a per-row rounded integer excess, because list_m2m_donors_v3 declares excess_units as integer and rounds each row before any caller sums it.',
 'SELECT COALESCE((SELECT value->>''excess_units_type'' FROM golden.scratch WHERE fixture_id=71 AND key=''round''),''absent'')', 'eq', 'integer', true, 'P3'),
(71, 20, 'D-27(a) S-281: list_m2m_donors_v3 reads the ROUNDED column. Read with seq 21 this is the whole asymmetry, pinned in the catalogue so it cannot be closed by a drive-by "cleanup" that looks like it is removing a redundant column.',
 'SELECT COALESCE((SELECT value->>''donors_reads_int'' FROM golden.scratch WHERE fixture_id=71 AND key=''round''),''absent'')', 'eq', 'yes', true, 'P3'),
(71, 21, 'D-27(a) S-281: resolve_supply_ladder_v3 reads the EXACT column. ⛔ The day someone points both sites at one column this goes red, and the change gets the Article-16 review that converging rung-4 availability deserves - exactly the role fixture 70 seq 27 plays for D-28.',
 'SELECT COALESCE((SELECT value->>''ladder_reads_exact'' FROM golden.scratch WHERE fixture_id=71 AND key=''round''),''absent'')', 'eq', 'yes', true, 'P3'),

-- ============================== INVARIANCE — green BEFORE and AFTER ==============================
(71, 22, 'D-27(a) INVARIANCE (PRD-074 pattern): across EVERY pod with donors, list_m2m_donors_v3 returns exactly as many rows as the pre-de-dup rule transcribed literally from the 42198fee body. Zero mismatches. A refactor that changes behaviour is not a refactor.',
 'SELECT COALESCE((SELECT value->>''mismatch_rows'' FROM golden.scratch WHERE fixture_id=71 AND key=''inv''),''absent'')', 'eq', '0', true, 'P3'),
(71, 23, 'D-27(a) INVARIANCE: across every pod, list_m2m_donors_v3 names exactly the same number of donor MACHINES as the legacy rule. This is fixture 45 seq 4''s pin restated fleet-wide instead of at one pod.',
 'SELECT COALESCE((SELECT value->>''mismatch_mach'' FROM golden.scratch WHERE fixture_id=71 AND key=''inv''),''absent'')', 'eq', '0', true, 'P3'),
(71, 24, 'D-27(a) INVARIANCE: across every pod, list_m2m_donors_v3''s excess_units sums to exactly what the legacy PER-ROW-ROUNDED rule sums to. ⛔ This is the assertion that goes red if anyone repoints the naming side at the exact column - it is fixture 45 seq 5''s pin, restated fleet-wide and on the correct side of the rounding seam.',
 'SELECT COALESCE((SELECT value->>''mismatch_sumint'' FROM golden.scratch WHERE fixture_id=71 AND key=''inv''),''absent'')', 'eq', '0', true, 'P3'),
(71, 25, 'D-27(a) INVARIANCE: donor ordering is still excess-DESC and TOTAL - the first row returned IS the maximum excess. A non-total order here would make stitch_v3''s donor choice non-reproducible, which is the comment the original body carries and the property it was protecting.',
 'SELECT COALESCE((SELECT value->>''order_ok'' FROM golden.scratch WHERE fixture_id=71 AND key=''inv''),''absent'')', 'eq', 'true', true, 'P3'),
(71, 26, 'D-27(a) INVARIANCE (ladder side): rung 4 counts exactly as many donor machines as the legacy rule does under the SAME exclusion. Measured through a real resolve_supply_ladder_v3 call, not by re-reading the view the change edits (S-267).',
 'SELECT COALESCE((SELECT value->>''ladder_donors_match'' FROM golden.scratch WHERE fixture_id=71 AND key=''inv''),''absent'')', 'eq', 'true', true, 'P3'),
(71, 27, 'D-27(a) INVARIANCE (ladder side, the crux): rung 4''s donor_excess_units equals the legacy EXACT numeric sum, to the cent. ⛔ If the de-dup ever routes the ladder through the per-row-rounded column this is the assertion that catches it, and it catches it as a NUMBER rather than as a catalogue string.',
 'SELECT COALESCE((SELECT value->>''ladder_excess_match'' FROM golden.scratch WHERE fixture_id=71 AND key=''inv''),''absent'')', 'eq', 'true', true, 'P3'),

-- ============================== RESIDUE ==============================
(71, 28, 'D-27(a) LAW 12: the ladder probe date holds zero rows across all four plan tables after the run. resolve_supply_ladder_v3 is declared STABLE; this MEASURES that it wrote nothing rather than trusting the declaration.',
 'SELECT COALESCE((SELECT value->>''law12'' FROM golden.scratch WHERE fixture_id=71 AND key=''residue''),''absent'')', 'eq', '0', true, 'P3'),
(71, 29, 'D-27(a) residue: the canonical object is still present at the END of the scenario - the fixture reads the catalogue and creates nothing, so a run can never leave a half-built object behind.',
 'SELECT COALESCE((SELECT value->>''canon_objects_after'' FROM golden.scratch WHERE fixture_id=71 AND key=''residue''),''absent'')', 'eq', '1', true, 'P3'),
(71, 30, 'D-27(a) residue: app.via_trigger does not leak out of the fixture. Nothing here writes to a protected table, so it must never have been set in the first place.',
 'SELECT COALESCE((SELECT value->>''via_trigger'' FROM golden.scratch WHERE fixture_id=71 AND key=''gucs''),''absent'')', 'eq', '<unset>', true, 'P3'),
(71, 31, 'D-27(a) residue: app.via_rpc does not leak out of the fixture either - the SET LOCAL ROLE anon probe at seq 6 resets cleanly and leaves no impersonation behind.',
 'SELECT COALESCE((SELECT value->>''via_rpc'' FROM golden.scratch WHERE fixture_id=71 AND key=''gucs''),''absent'')', 'eq', '<unset>', true, 'P3');
