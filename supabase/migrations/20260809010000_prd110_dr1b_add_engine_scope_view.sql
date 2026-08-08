-- PRD-110 DR-1b · leg 161 · Object 1 of 4
-- v_add_engine_scope_v3 — THE canonical answer to "which ADD engine owns this machine tonight".
--
-- Article 16: both ADD engines and promote_v3_shadow_to_live_v3 READ this rule. None of them
-- restates it. The day a second place spells `venue_group = cluster_key` is the day the two
-- can disagree about who planned VOX.
--
-- ⭐ LEFT JOIN + CASE, deliberately, NOT an inner join on the authority table. A machine whose
--    venue_group has no authority row (a venue group added between flips) must FALL BACK to
--    v19 — an inner join would drop it from BOTH engines and it would silently go unplanned.
--    That is the LAW 5 silent-qty-0 class at machine grain. Absence of a row is a state, and
--    that state is spelled 'v19'.

CREATE OR REPLACE VIEW public.v_add_engine_scope_v3 AS
SELECT mtv.plan_date,
       mtv.machine_id,
       mtv.official_name,
       m.venue_group AS cluster_key,
       CASE WHEN a.authoritative_engine = 'v3' THEN 'v3' ELSE 'v19' END AS assigned_engine
  FROM public.machines_to_visit mtv
  JOIN public.machines m ON m.machine_id = mtv.machine_id
  LEFT JOIN public.engine_cutover_authority_v3 a ON a.cluster_key = m.venue_group
 WHERE mtv.status IN ('picked','cs_added');

COMMENT ON VIEW public.v_add_engine_scope_v3 IS
  'PRD-110 DR-1b. Canonical per-machine ADD-engine assignment for a plan_date. '
  'assigned_engine is v3 only when the machine''s venue_group is authoritative for v3; '
  'every other case — including no authority row at all — is v19. Article 16 canonical.';

-- S-268: revoke anon/PUBLIC on every new relation.
REVOKE ALL ON public.v_add_engine_scope_v3 FROM anon, PUBLIC;

-- ⛔⛔ S-314 (NEW, leg 161) — **S-308 APPLIES TO VIEWS, NOT JUST TABLES.**
--    The first version of this migration asserted the opposite: that the Supabase DEFAULT
--    PRIVILEGE granting `authenticated` INSERT/UPDATE/DELETE/TRUNCATE on new objects targets
--    TABLES only, so a view needed no REVOKE. **That is false.** This migration's own guard
--    refused the apply with:
--      "v_add_engine_scope_v3 grants authenticated more than SELECT:
--       INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER"
--    The default privilege is `GRANT ALL ON TABLES`, and in Postgres the TABLES object class
--    covers views. A `GRANT SELECT` adds nothing that was not already there, and S-268's
--    `REVOKE … FROM anon, PUBLIC` does not touch a grant held by `authenticated`.
--    ⭐ The assertion is what caught this — it was written to be redundant and was not.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
    ON public.v_add_engine_scope_v3 FROM authenticated;
GRANT SELECT ON public.v_add_engine_scope_v3 TO authenticated;

-- Asserted rather than assumed:
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(privilege_type, ',')
    INTO v_bad
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public'
     AND table_name   = 'v_add_engine_scope_v3'
     AND grantee      = 'authenticated'
     AND privilege_type <> 'SELECT';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'DR-1b: v_add_engine_scope_v3 grants authenticated more than SELECT: %', v_bad;
  END IF;

  -- Post-image: the view must be readable and must classify every picked machine.
  PERFORM 1 FROM public.v_add_engine_scope_v3 LIMIT 1;
  IF EXISTS (SELECT 1 FROM public.v_add_engine_scope_v3
              WHERE assigned_engine IS NULL OR assigned_engine NOT IN ('v3','v19')) THEN
    RAISE EXCEPTION 'DR-1b: v_add_engine_scope_v3 produced an unassigned machine';
  END IF;
END $$;
