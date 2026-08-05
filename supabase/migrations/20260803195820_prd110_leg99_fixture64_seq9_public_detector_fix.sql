-- PRD-110 leg 99 · FIX fixture 64 seq 9 — the PUBLIC-grant detector was broken.
--
-- The scenario computed n_public as
--     count(*) FILTER (WHERE proacl::text LIKE '%=X/%')
-- which also matches `postgres=X/postgres`, `authenticated=X/postgres` and
-- `service_role=X/postgres`. It therefore returned 5 under EVERY possible state
-- and could never reach 0. It was RED after a revoke that was in fact entirely correct
-- (all five verified live at {postgres=X/postgres,authenticated=X/postgres,
-- service_role=X/postgres} with zero PUBLIC grants).
--
-- ⛔ This is the S-140 / S-132 lesson pointed at my own assertion: an assertion
-- that cannot fail under the wrong state is decoration, and one that cannot pass
-- under the RIGHT state is a false alarm. Both are the same defect — a check
-- whose value does not depend on the thing it claims to measure.
--
-- A PUBLIC grant is not a substring. In a PostgreSQL ACL it is an entry with an
-- EMPTY grantee, rendered `=X/postgres`, and the only correct way to detect it is
-- aclexplode(...).grantee = 0.
--
-- ⭐ AND THE DETECTOR NOW SELF-TESTS. golden._acl_canary_public_64() is created
-- here carrying a deliberate, explicit PUBLIC EXECUTE grant. Seq 24 asserts the
-- detector FINDS it. Without that canary, seq 9's `0` would be indistinguishable
-- from a detector that returns 0 for everything — which is exactly the failure
-- this migration is fixing. The canary is SECURITY INVOKER, touches no data, and
-- lives in the golden test schema, never in `public`.

-- ── the canary: a deliberate PUBLIC grant for the detector to find ───────────
CREATE OR REPLACE FUNCTION golden._acl_canary_public_64()
RETURNS integer LANGUAGE sql IMMUTABLE SECURITY INVOKER AS $fn$ SELECT 1 $fn$;

COMMENT ON FUNCTION golden._acl_canary_public_64() IS
  'PRD-110 leg 99 · fixture 64 seq 24. Deliberately carries an explicit PUBLIC EXECUTE grant so the D-41 PUBLIC-grant detector can prove it is capable of detecting one. Touches no data. Never move this to the public schema.';

-- materialise a non-null proacl carrying an explicit empty-grantee entry
REVOKE ALL ON FUNCTION golden._acl_canary_public_64() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION golden._acl_canary_public_64() TO PUBLIC;

-- ── corrected scenario ───────────────────────────────────────────────────────
UPDATE golden.fixtures
SET scenario_sql = $scenario$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'targets', jsonb_build_object(
  'n_found',      count(*),
  'n_overloaded', count(*) FILTER (WHERE n_ovl > 1),
  'n_definer',    count(*) FILTER (WHERE prosecdef),
  'n_anon',       count(*) FILTER (WHERE has_function_privilege('anon', oid, 'EXECUTE')),
  'n_public',     COALESCE(sum(n_pub), 0))
FROM (
  SELECT p.oid, p.prosecdef,
         count(*) OVER (PARTITION BY p.proname) AS n_ovl,
         (SELECT count(*) FROM aclexplode(p.proacl) a WHERE a.grantee = 0) AS n_pub
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN (
    '_build_draft_core_v3','build_draft_for_confirmed_v3','build_confirmed_now_v3',
    'pick_machines_for_refill','confirm_machines_to_visit')
) t;

-- detector self-test: the SAME expression, aimed at a function that really does
-- carry a PUBLIC grant. If this ever reads 0 the detector is broken, not the ACL.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'canary', jsonb_build_object(
  'public_grants_found',
  (SELECT count(*) FROM aclexplode(p.proacl) a WHERE a.grantee = 0))
FROM pg_proc p
WHERE p.oid = 'golden._acl_canary_public_64()'::regprocedure;
$scenario$,
    notes = notes || ' — leg 99: seq 9 detector rewritten to aclexplode(grantee=0); the original proacl::text LIKE ''%=X/%'' also matched postgres=X/postgres and could never reach 0. Seq 24 is its self-test against a deliberate PUBLIC-granted canary.'
WHERE fixture_id = 64;

-- ── seq 9 restated against the corrected measurement ─────────────────────────
UPDATE golden.assertions
SET description = '⛔ NO PUBLIC GRANT on any of the five. anon is a MEMBER of PUBLIC, so a revoke naming only anon leaves has_function_privilege(anon) TRUE. Four of the five carried an explicit =X/postgres when D-41 was executed, and the parking-lot premise named only anon. Detected via aclexplode(grantee=0) — a PUBLIC grant is an EMPTY-grantee ACL entry, never a substring of proacl::text (seq 24 proves this detector can actually see one)'
WHERE fixture_id = 64 AND seq = 9;

-- ── the self-test ────────────────────────────────────────────────────────────
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(64, 24, '⭐ DETECTOR SELF-TEST (S-140 applied to this fixture''s own check): the seq 9 expression, aimed at golden._acl_canary_public_64() which deliberately holds an explicit PUBLIC EXECUTE grant, must FIND that grant. Without this, seq 9 reading 0 could equally mean "no PUBLIC grants" or "the detector returns 0 for everything" — which is precisely the bug leg 99 shipped and then caught',
 $c$SELECT value->>'public_grants_found' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'canary'$c$,
 'eq', '1', true, 'P0');
