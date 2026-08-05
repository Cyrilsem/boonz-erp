-- PRD-110 P3.1a · FIXTURE 12 FIX — the standing CS assortment guardrail becomes DATA,
-- and the v3 substitute path learns what rank_slot_suitability already knew.
--
-- WHY THIS EXISTS. Probed live at leg 76 on three real (machine, shelf, anchor) triples:
--   find_substitutes_for_shelf_v3 -> Evian - 1L at RANK 1 on all three (in_category_performer)
--   rank_slot_suitability         -> Evian - 1L returned ZERO times, same inputs, same date
-- The PRD-106b2 guardrail was a literal uuid buried in one engine. Fixture 12 (migration
-- 20260731231836) recorded that RED at 19 pass / 7 fail before this file was written (LAW 1).
--
-- WHY A TABLE AND NOT A SECOND HARDCODE. "One brain" cannot mean two engines each carrying
-- their own copy of a business rule. A registry lets CS add or retire a guardrail without a
-- migration, and fixture 12 seq 23 actively FAILS a fix that copies the constant instead.
--
-- SCOPE. This blocks INTRODUCING a guardrail product to a machine that does not carry it.
-- It does NOT touch the shelves that legitimately hold it today: the substitute candidate
-- set excludes already-present products by construction, so refills are unaffected
-- (fixture 12 seq 8). rank_slot_suitability is left byte-identical - it already complies,
-- and PRD-106/108 consume it (LAW 3, LAW 10). v1 find_substitutes_for_shelf is left
-- byte-identical too and recorded as a witness (fixture 39 precedent, fixture 12 seq 31).
--
-- PROTECTED ENTITIES: none touched. No DELETE, no DROP, no data migration, no cron change.

-- ═══ 1. THE REGISTRY ════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.assortment_guardrails (
  pod_product_id uuid        PRIMARY KEY REFERENCES public.pod_products(pod_product_id),
  reason         text        NOT NULL CHECK (length(btrim(reason)) >= 20),
  active         boolean     NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text        NOT NULL DEFAULT current_user
);

COMMENT ON TABLE public.assortment_guardrails IS
  'Standing CS guardrails: products that must never be proposed as a swap-in / size-up / '
  'substitution candidate for a machine that does not already carry them. Read by '
  'find_substitutes_for_shelf_v3 (PRD-110 fixture 12). Does NOT block refilling a shelf '
  'that already holds the product - the guardrail is about INTRODUCTION only. Deactivate '
  'by setting active=false rather than deleting, so the history of the rule survives.';

ALTER TABLE public.assortment_guardrails ENABLE ROW LEVEL SECURITY;

DO $rls$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='assortment_guardrails'
                    AND policyname='assortment_guardrails_select') THEN
    -- Read-open: every engine, cron and FE surface must be able to see the rule.
    CREATE POLICY assortment_guardrails_select ON public.assortment_guardrails
      FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='assortment_guardrails'
                    AND policyname='assortment_guardrails_write') THEN
    -- Writes are a CS act. Mirrors refill_policy_params.rpp_write exactly,
    -- including the (SELECT auth.uid()) form required by the project rules.
    CREATE POLICY assortment_guardrails_write ON public.assortment_guardrails
      FOR ALL TO authenticated
      USING (EXISTS (SELECT 1 FROM public.user_profiles up
                      WHERE up.id = (SELECT auth.uid())
                        AND up.role = ANY (ARRAY['operator_admin','superadmin'])));
  END IF;
END $rls$;

GRANT SELECT ON public.assortment_guardrails TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.assortment_guardrails TO authenticated, service_role;

-- ═══ 2. THE SEED — lifted from the PRD-106b2 hardcode, not invented here ════
-- Sourced by NAME so this file carries no magic uuid (fixture 12 seq 23 checks the
-- engine for exactly that), and asserted to have found precisely one row.
DO $seed$
DECLARE v_pid uuid; v_n int;
BEGIN
  SELECT pod_product_id INTO v_pid FROM public.pod_products WHERE pod_product_name = 'Evian - 1L';
  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'seed failed: pod_products has no row named "Evian - 1L"';
  END IF;
  SELECT count(*) INTO v_n FROM public.pod_products WHERE pod_product_name = 'Evian - 1L';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'seed failed: % rows named "Evian - 1L", expected exactly 1', v_n;
  END IF;

  INSERT INTO public.assortment_guardrails (pod_product_id, reason)
  VALUES (v_pid,
          'Standing CS guardrail (PRD-106b2): the 1L format is never a swap-in. It occupies '
       || 'a full-depth lane for a low-rotation SKU and cannibalises the 500ml water that '
       || 'actually sells. Refilling the shelves that already carry it is unaffected.')
  ON CONFLICT (pod_product_id) DO NOTHING;
END $seed$;

-- ═══ 3. THE ENGINE — one named substitution, 146 other lines untouched ══════
-- pg_get_functiondef round-trip: the ONLY delta is the new NOT EXISTS. If the anchor
-- text ever moves, this RAISEs instead of silently shipping an unguarded engine.
DO $fix$
DECLARE def text; newdef text; anchor text; addition text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'find_substitutes_for_shelf_v3';
  IF def IS NULL THEN RAISE EXCEPTION 'find_substitutes_for_shelf_v3 not found'; END IF;

  anchor := 'AND si.scope_pod_product_id = gp.pod_product_id';
  -- Cody (leg 76): replace() substitutes EVERY occurrence. "At least one" is not
  -- good enough - two anchors would ship two guardrail clauses and a malformed body,
  -- and the post-condition grep below would still pass. Demand exactly one.
  IF (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 THEN
    RAISE EXCEPTION 'named substitution ABORTED: anchor found % time(s), expected exactly 1',
      (length(def) - length(replace(def, anchor, ''))) / length(anchor);
  END IF;

  addition := anchor || E'\n'
    || E'      )\n'
    || E'      -- PRD-110 fixture 12: a standing CS assortment guardrail is never proposed\n'
    || E'      -- as a substitute for a machine that does not already carry the product.\n'
    || E'      -- Data-driven ON PURPOSE: rank_slot_suitability enforces the same rule as a\n'
    || E'      -- literal uuid, and one brain must not need a migration to learn what the\n'
    || E'      -- other brain already refuses. Refills are untouched - anything already on\n'
    || E'      -- the machine was removed by `present` several predicates above.\n'
    || E'      AND NOT EXISTS (\n'
    || E'        SELECT 1 FROM public.assortment_guardrails g\n'
    || E'         WHERE g.pod_product_id = gp.pod_product_id\n'
    || E'           AND g.active';

  newdef := replace(def, anchor, addition);
  IF newdef = def THEN RAISE EXCEPTION 'named substitution ABORTED: replace was a no-op'; END IF;

  EXECUTE newdef;
END $fix$;

-- ═══ 4. SELF-VERIFY — refuse to ship a body that lost the rule or gained a uuid ══
DO $verify$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'find_substitutes_for_shelf_v3';

  IF v_src NOT ILIKE '%assortment_guardrails%' THEN
    RAISE EXCEPTION 'post-condition failed: engine does not read the registry';
  END IF;
  IF v_src ILIKE '%990461%' THEN
    RAISE EXCEPTION 'post-condition failed: engine carries a literal guardrail uuid';
  END IF;
  IF v_src NOT ILIKE '%strategic_intents%' THEN
    RAISE EXCEPTION 'post-condition failed: the decommission exclusion was lost';
  END IF;

  SELECT count(*) INTO v_n FROM public.assortment_guardrails WHERE active;
  IF v_n < 1 THEN RAISE EXCEPTION 'post-condition failed: registry seeded empty'; END IF;
END $verify$;
