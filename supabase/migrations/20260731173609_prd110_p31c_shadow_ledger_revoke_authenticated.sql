-- PRD-110 P3.1c — fix: strip the default-privilege grants from `authenticated`
-- on refill_plan_output_shadow. Forward-only (Article 12): a new migration to fix an
-- old one, never an edit in place.
--
-- ⛔ WHY 20260731173118 DID NOT ACHIEVE THIS. It ran `REVOKE ALL ... FROM PUBLIC` and then
--    `GRANT SELECT, REFERENCES, TRIGGER TO authenticated`. Neither removes what Supabase's
--    ALTER DEFAULT PRIVILEGES had ALREADY granted to the `authenticated` ROLE at CREATE TABLE
--    time. Revoking from PUBLIC does not touch a role-specific grant, and GRANT only adds.
--    The table therefore shipped with authenticated holding INSERT, UPDATE, DELETE and
--    TRUNCATE (Articles 1 and 3).
--
-- ⛔ AND TRUNCATE IS THE ONE THAT MATTERED. RLS `USING (false)` and the row-level append-only
--    trigger both stop UPDATE/DELETE - but TRUNCATE is not a row operation: it bypasses RLS
--    entirely and fires no FOR EACH ROW trigger. So the immutable ledger was, in fact,
--    erasable by any authenticated user. Golden fixture 44 seq 25 caught this.

REVOKE ALL ON public.refill_plan_output_shadow FROM authenticated;
GRANT SELECT, REFERENCES, TRIGGER ON public.refill_plan_output_shadow TO authenticated;
