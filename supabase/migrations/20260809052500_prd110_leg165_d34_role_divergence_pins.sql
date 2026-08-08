-- PRD-110 leg 165 · D-34 · S-333 drift pins on the role-gate divergence
--
-- Cody's Article 4 finding, verified live as warehouse bf32624e:
--   run_nightly_shadow_v3 admits operator_admin, superadmin, manager, warehouse
--   run_pipeline_v3       admits operator_admin, superadmin
-- SECURITY DEFINER does not reset auth.uid(), so once the runner calls the pipeline the
-- STRICTER gate wins and a manager/warehouse caller is refused. Cron is unaffected (NULL
-- uid skips both gates). D-34 classifies that refusal as 'role_refused' rather than
-- burying it in 'error', and the question "should manager/warehouse keep the ability to
-- run the nightly shadow runner by hand?" is a CS ask, not the loop's to answer.
--
-- ⛔ THESE PINS EXIST SO THE ASK CANNOT ANSWER ITSELF. The tempting "fix" for a
--    role_refused night is to widen run_pipeline_v3's gate -- an authorization
--    EXPANSION on a SECURITY DEFINER that plans refills. If either gate moves, these go
--    red and the divergence comes back to CS instead of being quietly settled by whoever
--    is debugging that night. S-322: never loosen an assertion to accommodate the code
--    it caught.
--
-- ⭐ Green on arrival: unlike seq 24..34 these are drift guards on the CURRENT state,
--    not red-first proofs of a defect.

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(53, 35, 'S-333 / Article 4: run_pipeline_v3''s role gate is still the NARROW one -- it does not admit warehouse. Widening it to silence a role_refused night is an authorization expansion on a SECURITY DEFINER and belongs to CS, not to the leg debugging the night.',
 'SELECT golden.probe_scalar(''SELECT position(''''warehouse'''' in p.prosrc)::text FROM pg_proc p WHERE p.proname=''''run_pipeline_v3'''' AND p.pronamespace=''''public''''::regnamespace'')',
 'eq', '0', true, 'P2'),

(53, 36, 'S-333 / Article 4: and run_nightly_shadow_v3''s gate is still the WIDE one -- it does admit warehouse. The two gates diverging is the whole reason role_refused exists; if this ever reads 0 the divergence was closed from the other side and the CS ask changed meaning.',
 'SELECT golden.probe_scalar(''SELECT (position(''''warehouse'''' in p.prosrc) > 0)::text FROM pg_proc p WHERE p.proname=''''run_nightly_shadow_v3'''' AND p.pronamespace=''''public''''::regnamespace'')',
 'eq', 'true', true, 'P2');
