-- ============================================================================
-- PRD-002 + PRD-006 — product_family grouping for multi-variant SKUs
--
-- Source PRDs:
--   docs/prds/refill-pipeline/PRD-002-returns-split-by-variant-ui.md
--   docs/prds/refill-pipeline/PRD-006-dispatch-enforces-single-variant.md
--
-- Both PRDs lock the same Decision: "variants are DISTINCT boonz_product_id
-- rows, grouped by a product_family_id." This migration delivers that schema
-- piece as a shared prerequisite. FE work in both PRDs (variant split,
-- substitution flow) can then read family membership without bespoke joins.
--
-- Design intent: KEEP boonz_products as the canonical SKU (one row per
-- pickable variant). ADD a non-protected `product_families` lookup table and
-- a nullable `product_family_id` FK on boonz_products. Backfill is left to
-- CS — no automatic guess at family grouping because the wrong guess corrupts
-- the brain's signal in exactly the way these PRDs are trying to prevent.
--
-- boonz_products is NOT in Constitution Appendix A (verified against the
-- protected entity list in cody/SKILL.md). Adding a nullable FK column is
-- additive and reversible. No RLS changes on boonz_products.
--
-- Cody Articles checked: 4 (validation via CHECK on family name), 7
-- (product_families gets append-only-ish RLS — superadmin can update for
-- corrections), 12 (forward-only), 14 (no _v2 table — boonz_products evolves
-- in place).
-- ============================================================================

BEGIN;

-- ── 1. product_families lookup ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.product_families (
  product_family_id   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  family_name         text        NOT NULL UNIQUE
                                  CHECK (length(btrim(family_name)) > 0),
  display_name        text        NOT NULL,
  notes               text,
  is_active           boolean     NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.product_families IS
  'PRD-002/006: grouping for multi-variant SKUs (Hunter family → Hunter Truffle, '
  'Sea Salt, Hot & Sweet; YoPro family → Vanilla, Chocolate, Strawberry; etc). '
  'Used by the returns split UI and dispatch substitution flow to constrain '
  'cross-variant swaps to within the same family.';

ALTER TABLE public.product_families ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pf_select_authenticated ON public.product_families;
CREATE POLICY pf_select_authenticated
  ON public.product_families
  FOR SELECT TO authenticated USING (true);

-- Write gated to operator_admin / superadmin / manager — family corrections
-- are a CS decision, not a driver/WH action.
DROP POLICY IF EXISTS pf_write_admins ON public.product_families;
CREATE POLICY pf_write_admins
  ON public.product_families
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE id = (SELECT auth.uid())
        AND role = ANY (ARRAY['operator_admin', 'superadmin', 'manager'])
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE id = (SELECT auth.uid())
        AND role = ANY (ARRAY['operator_admin', 'superadmin', 'manager'])
    )
  );

-- ── 2. boonz_products: nullable FK to product_families ──────────────────────

ALTER TABLE public.boonz_products
  ADD COLUMN IF NOT EXISTS product_family_id uuid
    REFERENCES public.product_families(product_family_id) ON DELETE SET NULL;

COMMENT ON COLUMN public.boonz_products.product_family_id IS
  'PRD-002/006: optional family grouping. NULL means standalone SKU (no '
  'siblings). Same-family variants are eligible for the returns split UI and '
  'dispatch substitution flow. Backfill is manual — CS-owned because wrong '
  'grouping would corrupt the brain signal these PRDs are trying to fix.';

-- Index for the "give me all variants in this family" query that the FE
-- substitution picker hits.
CREATE INDEX IF NOT EXISTS idx_boonz_products_family
  ON public.boonz_products (product_family_id)
  WHERE product_family_id IS NOT NULL;

-- ── 3. Convenience view: same-family variant lookup ─────────────────────────

CREATE OR REPLACE VIEW public.v_product_family_members
WITH (security_invoker = true) AS
SELECT
  bp.product_id,
  bp.name AS product_name,
  bp.product_family_id,
  pf.family_name,
  pf.display_name AS family_display_name,
  pf.is_active AS family_is_active
FROM public.boonz_products bp
LEFT JOIN public.product_families pf ON pf.product_family_id = bp.product_family_id;

COMMENT ON VIEW public.v_product_family_members IS
  'PRD-002/006: products with their family resolved. FE substitution picker '
  'reads this filtered by product_family_id to show "other variants in this family".';

-- ── 4. Touch-updated-at trigger on product_families ─────────────────────────

CREATE OR REPLACE FUNCTION public.touch_product_families_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_pf_touch_updated_at ON public.product_families;
CREATE TRIGGER trg_pf_touch_updated_at
  BEFORE UPDATE ON public.product_families
  FOR EACH ROW EXECUTE FUNCTION public.touch_product_families_updated_at();

COMMIT;

-- ============================================================================
-- BACKFILL (CS-owned — NOT included in this migration)
--
-- The product_families table starts empty. CS curates the family list and
-- backfills boonz_products.product_family_id by hand because automated grouping
-- would corrupt brand signal. Suggested first families to seed (per PRD source
-- doc):
--   - Hunter Ridges     → Hunter Truffle, Hunter Sea Salt, Hunter Hot & Sweet
--   - YoPro            → Vanilla, Chocolate, Strawberry (etc.)
--   - Be Kind Cluster   → Dark, Peanut Butter, Maple Pecan (etc.)
--   - Perrier          → Regular, Strawberry, Lime (etc.)
--   - McVities Mini     → Milk Chocolate, Dark Chocolate, Caramel (etc.)
--
-- Example seed (one family) — DO NOT include in this migration; run by hand
-- once names are confirmed with CS:
--
--   INSERT INTO product_families (family_name, display_name)
--     VALUES ('hunter_ridges', 'Hunter Ridges') RETURNING product_family_id;
--   UPDATE boonz_products SET product_family_id = '<returned>' WHERE name ILIKE 'Hunter%';
--
-- DEFERRED FOLLOW-UPS for PRD-002:
--   - Returns split UI reads v_product_family_members to constrain variant
--     picker to same-family options.
--   - return_audit_log table (separate Dara design, coupled with PRD-006's
--     substitution log — keep them in one append-only table).
--   - Returns save RPC (in live DB).
--
-- DEFERRED FOLLOW-UPS for PRD-006:
--   - Picking UI variant-level rendering of refill_plan_output.
--   - Substitution log table (shared with return_audit_log).
--   - Picking RPC variant validation (in live DB).
-- ============================================================================
