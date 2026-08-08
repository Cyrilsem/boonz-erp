-- PRD-110 DR-1 (leg 160) — S-308: revoke the write verbs the new tables were BORN holding.
--
-- ⛔⛔ S-308 (NEW). Fixture 74 seq 8/9 went red against a migration that had already stripped `anon`
--    and granted `authenticated` nothing but SELECT. The reason: a Supabase DEFAULT PRIVILEGE grants
--    `authenticated` DELETE/INSERT/REFERENCES/SELECT/TRIGGER/TRUNCATE/UPDATE on EVERY new table in
--    `public`. A migration that only ADDS `GRANT SELECT` is a no-op — the write verbs were already
--    there, and `REVOKE ... FROM anon, PUBLIC` does not touch a grant held by `authenticated`.
--
-- ⭐ WHY THIS WAS NOT A LIVE HOLE, AND WHY IT STILL MATTERS. The registry's RLS policies are
--    FOR UPDATE/DELETE USING (false), so the writes were refused anyway. But that means the ONLY
--    thing standing between `authenticated` and a direct cutover flip was a policy I happened to
--    write. Article 3 wants the grant absent as well — defence in depth, and the DR-3 / fixture-67
--    idiom for pod_inventory is exactly this REVOKE.
--
-- ⛔ EVERY FUTURE TABLE IN THIS PROJECT IS BORN THE SAME WAY. Assert the grant, never assume it.

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.engine_cutover_authority_v3 FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.engine_cutover_audit_v3     FROM authenticated;

-- The read path survives; the board still renders which cluster is on which engine.
GRANT SELECT ON public.engine_cutover_authority_v3 TO authenticated;
GRANT SELECT ON public.engine_cutover_audit_v3     TO authenticated;

-- ⭐ service_role KEEPS its write privileges, deliberately — same reasoning as fixture 67 seq 8:
--    it is the n8n / break-glass path, this build cannot read the n8n flows to prove none of them
--    writes, and revoking a privilege whose consumers are unverifiable is how a job dies at 02:00.
--    RLS + the absence of any INSERT policy is what covers it.

DO $post$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(t||':'||p, ', ') INTO v_bad FROM (
    SELECT t, p FROM unnest(ARRAY['engine_cutover_authority_v3','engine_cutover_audit_v3']) t
    CROSS JOIN unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE']) p
    WHERE has_table_privilege('authenticated', 'public.'||t, p)) x;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'S-308 post-image: authenticated still holds %', v_bad;
  END IF;

  IF NOT has_table_privilege('authenticated','public.engine_cutover_authority_v3','SELECT') THEN
    RAISE EXCEPTION 'S-308 post-image: the revoke went too far and took SELECT with it';
  END IF;
  IF has_table_privilege('anon','public.engine_cutover_authority_v3','SELECT') THEN
    RAISE EXCEPTION 'S-308 post-image: anon holds SELECT';
  END IF;
  RAISE NOTICE 'S-308 OK: authenticated read-only on both cutover tables, anon holds nothing';
END
$post$;
