-- PRD-110 DR-3 / S-260 — fixture 67 seq 14 was authored against an INTUITED rendering of
-- pg_get_triggerdef ('BEFORE UPDATE OR DELETE'). Postgres CANONICALISES the verb list and
-- renders 'BEFORE DELETE OR UPDATE'. The guard is correct; the literal was wrong.
--
-- ⛔ THIS IS NOT A RE-BASELINE. Seq 14 was never green: it was authored in this same leg and
--    failed on its first post-apply fire. The CLAIM is unchanged and is INDEPENDENTLY PROVEN BY
--    EXECUTION at seq 22 (UPDATE refused 42501) and seq 24 (DELETE refused 42501) - the static
--    trigger-def read is only the mirror of those.
-- ⭐ Per S-257, the replacement is a PROPERTY, not a literal, so it cannot rot on verb ordering:
--    it pins BEFORE **and** UPDATE **and** DELETE, which is strictly MORE than the original
--    single substring asserted.
UPDATE golden.assertions
SET check_sql = 'SELECT ((((value->>''guard_trg_def'') LIKE ''%BEFORE%'') AND ((value->>''guard_trg_def'') LIKE ''%UPDATE%'') AND ((value->>''guard_trg_def'') LIKE ''%DELETE%''))::text) FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''',
    expect_op = 'eq',
    expect = 'true',
    description = 'The new guard covers the two verbs nothing guarded before: it is a BEFORE trigger on BOTH UPDATE and DELETE. ⭐ Stated as a PROPERTY (BEFORE ∧ UPDATE ∧ DELETE all present), never as a literal substring: Postgres CANONICALISES the verb list and renders "BEFORE DELETE OR UPDATE", not the authored "BEFORE UPDATE OR DELETE" (S-260). ⛔ Do not re-narrow this to one substring - the ordering is the server''s to choose. The executed proof of the same claim is seq 22 (UPDATE refused 42501) + seq 24 (DELETE refused 42501).'
WHERE fixture_id = 67 AND seq = 14;
