-- PRD-110 P3.4 — fixture 48 seq 44 correction.
--
-- ⛔ THE ASSERTION WAS STRICTER THAN THE RATIFIED CONVENTION, AND THE ENGINE WAS RIGHT.
-- Seq 44 as first written demanded that propose_facing_changes_v3 be non-executable by
-- `authenticated`, reading the staged migration's `GRANT EXECUTE ... TO service_role` as
-- "service_role ONLY". It is not: Supabase default privileges grant EXECUTE to
-- authenticated at CREATE time, and REVOKE ... FROM PUBLIC does not remove that explicit
-- grant. Measured live, ALL SIX v3 engine objects carry the identical ACL
-- (postgres=X | authenticated=X | service_role=X): engine_add_pod_v3, stitch_v3,
-- resolve_supply_ladder_v3, rank_machines_by_value_at_risk_v3 (whose anon/PUBLIC grants
-- were deliberately revoked at leg 58 under S-81, leaving authenticated in place), and the
-- ratified sibling proposer propose_rotations_v3 which passed Cody at leg 57 with exactly
-- this shape.
--
-- ⭐ So the S-88 line is ANON, not authenticated -- that is what seq 43 pins and it is green.
-- Revoking authenticated here would make this one object inconsistent with six peers and
-- would change a fleet-wide convention, which is a CS decision, not a mid-loop edit.
-- Seq 44 is therefore re-expressed as the stronger and self-maintaining invariant: this
-- proposer's execute-ACL must MATCH its ratified sibling's, whatever that convention is. If
-- CS later tightens the convention, this assertion follows it instead of having to be found.

UPDATE golden.assertions
   SET description = 'The proposer carries the SAME execute-ACL as its ratified sibling propose_rotations_v3 (anon denied, authenticated allowed, service_role allowed) -- a fleet-wide convention for every v3 engine object, never a per-object choice',
       check_sql = $c$SELECT COALESCE((SELECT (
            has_function_privilege('anon',          a.oid, 'EXECUTE') = has_function_privilege('anon',          b.oid, 'EXECUTE')
        AND has_function_privilege('authenticated', a.oid, 'EXECUTE') = has_function_privilege('authenticated', b.oid, 'EXECUTE')
        AND has_function_privilege('service_role',  a.oid, 'EXECUTE') = has_function_privilege('service_role',  b.oid, 'EXECUTE')
       )::text
       FROM pg_proc a, pg_proc b
      WHERE a.proname = 'propose_facing_changes_v3' AND a.pronamespace = 'public'::regnamespace
        AND b.proname = 'propose_rotations_v3'      AND b.pronamespace = 'public'::regnamespace
      LIMIT 1), 'absent')$c$
 WHERE fixture_id = 48 AND seq = 44;
