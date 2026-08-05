-- PRD-110 P2.4 · wire the canonical demand multiplier into engine_add_pod_v3.
-- LAW 1 discharged FIRST: golden fixture 7 was applied and run RED (15 pass / 9 fail, zero
-- scenario errors, zero residue) before this migration existed.
--
-- Cody review (leg 49): Articles 1, 4, 6, 8, 12, 13, 14, 16 checked. Article 16 is DISCHARGED by
-- this change, not incurred - METRICS_REGISTRY already names resolve_demand_multiplier_v3 as the
-- canonical object and says "the engine reads the resolver". The dmf CTE CALLS it; it must never
-- re-implement the most-specific-within-source / multiply-across-sources / clamp rule.
--
-- ⛔ RECORDED, deliberately NOT acted on (LAW 13): sigma_daily_shelf is derived in `polled` from
-- velocity_instock_shelf/_pod, NOT from vel_eff. So the factor scales the MEAN term but leaves the
-- SAFETY term unscaled - an uplifted machine carries a proportionally smaller buffer. BUILD SPEC
-- P2.4 specifies only `effective_velocity = velocity_instock x PIfactors`; scaling sigma too would
-- be creative interpretation. Parked for CS.
--
-- Edit method: leg-26 substitution over pg_get_functiondef, six anchors each asserted to match
-- EXACTLY once, and the reverse substitution proven to reproduce the original byte-for-byte
-- BEFORE any DDL runs. oid preservation asserted after.

DO $mig$
DECLARE
  v_src  text;
  v_new  text;
  v_back text;
  v_oid  oid;
  a1 text; a2 text; a3 text; a4 text; a5 text; a6 text;
  b1 text; b2 text; b3 text; b4 text; b5 text; b6 text;

  FUNCTION_NOT_FOUND CONSTANT text := 'engine_add_pod_v3 not found';
BEGIN
  SELECT oid, pg_get_functiondef(oid) INTO v_oid, v_src
    FROM pg_proc WHERE proname = 'engine_add_pod_v3';
  IF v_src IS NULL THEN RAISE EXCEPTION '%', FUNCTION_NOT_FOUND; END IF;

  ---------------------------------------------------------------------------------------------
  -- ANCHORS (exact text from the live definition)
  ---------------------------------------------------------------------------------------------
  a1 := $q$  -- S-26: ONE fleet-wide evaluation of the velocity object per run.$q$;

  a2 := $q$      CASE WHEN vv.velocity_instock_shelf IS NOT NULL THEN vv.velocity_instock_shelf
           WHEN s.velocity_raw            IS NOT NULL THEN s.velocity_raw::numeric
           ELSE 0::numeric END                                  AS vel_eff,$q$;

  a3 := $q$    FROM picked p
    JOIN public.v_shelf_state s$q$;

  a4 := $q$        'velocity_source',           r.velocity_source,
        'velocity_effective_daily',  r.vel_eff,$q$;

  a5 := $q$        'engine_calibration',   'v3_p23_expiry_ceiling',$q$;

  a6 := $q$ + v_pod_demand_dispersion_v3 + v_product_shelf_life',$q$;

  ---------------------------------------------------------------------------------------------
  -- REPLACEMENTS
  ---------------------------------------------------------------------------------------------
  b1 := $q$  -- P2.4 (fixture 7). ONE resolver evaluation per PICKED MACHINE, never per shelf: the
  -- answer is machine-grain, and shelf-grain evaluation would re-run it ~16x per machine for an
  -- identical result. Article 16: this READS the canonical demand-multiplier object. It must
  -- never re-implement the most-specific-within-source / multiply-across-sources / clamp rule -
  -- that rule lives in resolve_demand_multiplier_v3 and is pinned by fixture 31 seq 3.
  -- LEFT JOIN LATERAL + COALESCE is deliberate: a resolver returning zero rows would otherwise
  -- DROP that machine's shelves from the plan entirely, which is exactly the silent-qty-0 class
  -- LAW 5 forbids. Fixture 31 seq 2/4 pin that the resolver is total and never returns NULL.
  dmf AS (
    SELECT p.machine_id,
           COALESCE(r.factor, 1)                AS demand_factor,
           COALESCE(r.factor_raw, 1)            AS demand_factor_raw,
           COALESCE(r.clamped, false)           AS demand_factor_clamped,
           COALESCE(r.provenance, '[]'::jsonb)  AS demand_factor_sources
      FROM picked p
      LEFT JOIN LATERAL public.resolve_demand_multiplier_v3(p.machine_id, p_plan_date) r ON true
  ),
$q$ || a1;

  b2 := $q$      CASE WHEN vv.velocity_instock_shelf IS NOT NULL THEN vv.velocity_instock_shelf
           WHEN s.velocity_raw            IS NOT NULL THEN s.velocity_raw::numeric
           ELSE 0::numeric END                                  AS vel_base,
      -- P2.4. The multiplier is applied HERE and nowhere else. vel_eff feeds mu_term,
      -- cover_units AND expiry_ceiling_units, so this one multiplication carries the factor into
      -- every sizing term downstream. vel_base is kept UNSCALED beside it so shadow-vs-v19
      -- diffing can always separate "demand moved" from "we multiplied it" (fixture 7 seq 18/19).
      -- ⛔ sigma_daily_shelf is NOT scaled here - see the migration header.
      (CASE WHEN vv.velocity_instock_shelf IS NOT NULL THEN vv.velocity_instock_shelf
            WHEN s.velocity_raw            IS NOT NULL THEN s.velocity_raw::numeric
            ELSE 0::numeric END) * COALESCE(mf.demand_factor, 1)  AS vel_eff,
      COALESCE(mf.demand_factor, 1)                               AS demand_factor,
      COALESCE(mf.demand_factor_raw, 1)                           AS demand_factor_raw,
      COALESCE(mf.demand_factor_clamped, false)                   AS demand_factor_clamped,
      COALESCE(mf.demand_factor_sources, '[]'::jsonb)             AS demand_factor_sources,$q$;

  b3 := $q$    FROM picked p
    LEFT JOIN dmf mf
      ON mf.machine_id = p.machine_id
    JOIN public.v_shelf_state s$q$;

  b4 := $q$        'velocity_source',           r.velocity_source,
        'velocity_effective_daily',  r.vel_eff,
        -- P2.4 demand-multiplier provenance (fixture 7 seq 14-19). LAW 5: an UNFACTORED line
        -- records 1.0 and an empty source list EXPLICITLY, so silence is never ambiguous.
        'velocity_base_daily',       r.vel_base,
        'demand_factor',             r.demand_factor,
        'demand_factor_raw',         r.demand_factor_raw,
        'demand_factor_clamped',     r.demand_factor_clamped,
        'demand_factor_sources',     r.demand_factor_sources,$q$;

  b5 := $q$        'engine_calibration',   'v3_p24_demand_multiplier',$q$;

  b6 := $q$ + v_pod_demand_dispersion_v3 + v_product_shelf_life + demand_calendar',$q$;

  ---------------------------------------------------------------------------------------------
  -- Every anchor must match EXACTLY once. Zero = the engine moved under us; >1 = ambiguous edit.
  ---------------------------------------------------------------------------------------------
  IF (length(v_src) - length(replace(v_src, a1, ''))) / length(a1) <> 1 THEN
     RAISE EXCEPTION 'anchor a1 does not match exactly once'; END IF;
  IF (length(v_src) - length(replace(v_src, a2, ''))) / length(a2) <> 1 THEN
     RAISE EXCEPTION 'anchor a2 does not match exactly once'; END IF;
  IF (length(v_src) - length(replace(v_src, a3, ''))) / length(a3) <> 1 THEN
     RAISE EXCEPTION 'anchor a3 does not match exactly once'; END IF;
  IF (length(v_src) - length(replace(v_src, a4, ''))) / length(a4) <> 1 THEN
     RAISE EXCEPTION 'anchor a4 does not match exactly once'; END IF;
  IF (length(v_src) - length(replace(v_src, a5, ''))) / length(a5) <> 1 THEN
     RAISE EXCEPTION 'anchor a5 does not match exactly once'; END IF;
  IF (length(v_src) - length(replace(v_src, a6, ''))) / length(a6) <> 1 THEN
     RAISE EXCEPTION 'anchor a6 does not match exactly once'; END IF;

  v_new := replace(v_src, a1, b1);
  v_new := replace(v_new, a2, b2);
  v_new := replace(v_new, a3, b3);
  v_new := replace(v_new, a4, b4);
  v_new := replace(v_new, a5, b5);
  v_new := replace(v_new, a6, b6);

  IF v_new = v_src THEN RAISE EXCEPTION 'substitution was a no-op'; END IF;

  ---------------------------------------------------------------------------------------------
  -- ⭐ THE PROOF, and it runs BEFORE any DDL: undoing the six substitutions must reproduce the
  -- ORIGINAL definition byte-for-byte. If it does, the edit changed exactly what was intended
  -- and nothing else - no collateral match anywhere in 27kB of engine.
  ---------------------------------------------------------------------------------------------
  v_back := replace(v_new,  b6, a6);
  v_back := replace(v_back, b5, a5);
  v_back := replace(v_back, b4, a4);
  v_back := replace(v_back, b3, a3);
  v_back := replace(v_back, b2, a2);
  v_back := replace(v_back, b1, a1);

  IF v_back <> v_src THEN
    RAISE EXCEPTION 'reverse substitution did NOT reproduce the original (len src=% back=%) - refusing to touch the engine',
      length(v_src), length(v_back);
  END IF;

  EXECUTE v_new;

  -- CREATE OR REPLACE must preserve the identity (and therefore its privileges).
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_oid AND proname = 'engine_add_pod_v3') THEN
    RAISE EXCEPTION 'oid % did not survive the replace', v_oid;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'engine_add_pod_v3') <> 1 THEN
    RAISE EXCEPTION 'engine_add_pod_v3 is no longer a single overload';
  END IF;

  RAISE NOTICE 'engine_add_pod_v3 rewired for P2.4; oid % preserved', v_oid;
END
$mig$;