-- PRD-110 P2.4 · forward-only correction (Article 12: the applied migration is NOT edited).
--
-- ⭐ THE BUG, and it is fully general: `jsonb_build_object` is capped at **100 arguments = 50
-- key/value pairs**. The engine's `reasoning` object was already at 49 pairs (98 args) - ONE PAIR
-- from the ceiling. P2.4's five provenance keys took it to 54 pairs / 108 args, and EVERY engine
-- run then died with `54023: cannot pass more than 100 arguments to a function`.
--
-- 📌 It would have been reported as a VACUOUS GREEN. With the engine dead, both fixture-7 run maps
-- were empty, so every `count(*) FROM jsonb_each` mismatch assertion returned 0 and PASSED. Ten
-- assertions went green on a completely broken engine. What caught it was fixture 7 seq 3/4, the
-- NON-VACUITY guards. This is the third time the S-48 / S-52 vacuity discipline has paid for
-- itself - it is why the failure surfaced in 30 seconds instead of at cutover.
--
-- Fix: the P2.4 keys move OUT of the base object into a SECOND jsonb_build_object merged with `||`.
-- Identical resulting jsonb, no argument ceiling. The two halves sit at 44 and 5 pairs.
--
-- ⚠️ STANDING RULE for every future leg: before adding a key to `reasoning`, COUNT THE PAIRS.
-- At 50 the base object is FULL - append a new `|| jsonb_build_object` group instead.
--
-- ⛔ A rejected first attempt at this migration carried a "count the pair separators" guard as
-- belt-and-braces. It was itself wrong - the pattern it counted matches BOTH objects - and it
-- raised before EXECUTE, applying nothing. Recorded because the lesson is real: a structural
-- guard over generated SQL text is easy to write and easy to get silently wrong. The load-bearing
-- evidence here is the reverse-substitution proof plus fixture 7 seq 1/2, which run the engine.

DO $mig$
DECLARE
  v_src       text;
  v_new       text;
  v_stripped  text;
  v_oid       oid;
  c1 text; c2 text; d2 text;
BEGIN
  SELECT oid, pg_get_functiondef(oid) INTO v_oid, v_src
    FROM pg_proc WHERE proname = 'engine_add_pod_v3';

  -- the five keys as P2.4 wrongly placed them: INSIDE the base object
  c1 := $q$        'velocity_base_daily',       r.vel_base,
        'demand_factor',             r.demand_factor,
        'demand_factor_raw',         r.demand_factor_raw,
        'demand_factor_clamped',     r.demand_factor_clamped,
        'demand_factor_sources',     r.demand_factor_sources,$q$;

  c2 := $q$        'run_id',               v_run_id)$q$;

  d2 := $q$        'run_id',               v_run_id)
      -- P2.4 demand-multiplier provenance, fixture 7 seq 14-19. ⛔ These live in a SECOND
      -- jsonb_build_object merged with ||, NOT in the base object above: jsonb_build_object is
      -- capped at 100 arguments = 50 pairs, and the base object is AT that ceiling. Adding one
      -- key there kills every engine run with SQLSTATE 54023.
      -- LAW 5: an UNFACTORED line records 1.0 and an empty source list EXPLICITLY, so silence is
      -- never ambiguous.
      || jsonb_build_object$q$ || chr(40) || $q$
        'velocity_base_daily',       r.vel_base,
        'demand_factor',             r.demand_factor,
        'demand_factor_raw',         r.demand_factor_raw,
        'demand_factor_clamped',     r.demand_factor_clamped,
        'demand_factor_sources',     r.demand_factor_sources)$q$;

  IF (length(v_src) - length(replace(v_src, c1, ''))) / length(c1) <> 1 THEN
     RAISE EXCEPTION 'anchor c1 does not match exactly once'; END IF;
  IF (length(v_src) - length(replace(v_src, c2, ''))) / length(c2) <> 1 THEN
     RAISE EXCEPTION 'anchor c2 does not match exactly once'; END IF;

  -- The whole edit is: strip c1 from the base object, then swap c2 -> d2.
  v_stripped := replace(v_src, c1, '');
  v_new      := replace(v_stripped, c2, d2);

  -- ⭐ Reverse-substitution proof, BEFORE any DDL. c1 is a deletion and cannot be reversed by
  -- replacement, so the proof is stated against the c1-stripped original: undoing d2 -> c2 must
  -- reproduce it byte-for-byte, which pins that the c2 swap touched nothing else.
  IF replace(v_new, d2, c2) <> v_stripped THEN
    RAISE EXCEPTION 'reverse substitution did not reproduce the c1-stripped original';
  END IF;

  -- and the deletion removed exactly its own length, nothing more
  IF length(v_stripped) <> length(v_src) - length(c1) THEN
    RAISE EXCEPTION 'c1 deletion removed an unexpected number of bytes';
  END IF;

  IF strpos(v_new, $q$|| jsonb_build_object$q$) = 0 THEN
    RAISE EXCEPTION 'the merged second object is missing';
  END IF;

  EXECUTE v_new;

  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_oid AND proname = 'engine_add_pod_v3') THEN
    RAISE EXCEPTION 'oid % did not survive the replace', v_oid;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'engine_add_pod_v3') <> 1 THEN
    RAISE EXCEPTION 'engine_add_pod_v3 is no longer a single overload';
  END IF;

  RAISE NOTICE 'reasoning split into two jsonb objects; oid % preserved', v_oid;
END
$mig$;