-- PRD-110 P3.2 · fixture 41 corrective — pg_proc.provolatile is type "char", not text.
--
-- The RED baseline caught this exactly as a RED baseline is supposed to: seq 46 returned
-- err = 'operator is not unique: "char" || unknown'. Postgres cannot resolve || against a
-- bare "char" without an explicit cast, so the assertion errored instead of evaluating.
-- Same class as leg 56's golden.scratch jsonb finding: the RED proved the fixture, not just
-- the absent function.
--
-- No change to what is asserted -- only the cast that lets it evaluate.

UPDATE golden.assertions
SET check_sql = $q$SELECT provolatile::text || '|' || prosecdef::text FROM pg_proc
                   WHERE proname='resolve_m2m_sku_legs_v3'$q$
WHERE fixture_id = 41 AND seq = 46;
