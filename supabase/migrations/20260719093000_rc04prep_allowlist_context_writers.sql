-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- RC-04 prep (docs/architecture/BATCH3_FE_CHANGES.md: RC-04 = rewire direct table writes onto
-- canonical RPCs): before that rewire, allowlist which roles may write demand_context_factors
-- (the "context" table backing demand multipliers). Verified live via pg_policies: dcf_write
-- restricts ALL to operator_admin/superadmin/manager; dcf_select is open SELECT. boonz_context
-- (the other public.*context* table) carries only a SELECT policy, no write policy -- left as-is.

DROP POLICY IF EXISTS dcf_select ON public.demand_context_factors;
CREATE POLICY dcf_select ON public.demand_context_factors
  FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS dcf_write ON public.demand_context_factors;
CREATE POLICY dcf_write ON public.demand_context_factors
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE user_profiles.id = (SELECT auth.uid())
        AND user_profiles.role = ANY (ARRAY['operator_admin'::text, 'superadmin'::text, 'manager'::text])
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE user_profiles.id = (SELECT auth.uid())
        AND user_profiles.role = ANY (ARRAY['operator_admin'::text, 'superadmin'::text, 'manager'::text])
    )
  );
