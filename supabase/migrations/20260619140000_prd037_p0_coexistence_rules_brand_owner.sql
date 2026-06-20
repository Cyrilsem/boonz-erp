-- PRD-037 Phase 0: coexistence_rules table + TCCC brand_owner tag.
-- NOT APPLIED. Author-only; apply after CS sign-off + Cody verdict. Forward-only.
--
-- Reconciliation (live data 2026-06-19): boonz_products.product_family_id is NULL for
-- all 307 products, so the coexistence matrix is keyed on product_brand (CS-approved
-- brand-keyed encoding), not family_id. The catalog stores brand+variant
-- ("Coca Cola - Zero", "Perrier - Regular"), so Groups 2/3/4/7 are max-1-per-brand,
-- Groups 5/6 are explicit cross-brand pairs, Group 1 (no Soft Drinks Mix SKU exists
-- today) is encoded by name so it activates if that SKU is added. Rule 1 (TCCC venue
-- exclusion) keys on the new brand_owner tag. Rule 2 (generic max-1-per-family soft)
-- is enforced in-engine using product_brand as the family proxy until
-- product_family_id is backfilled (tracked as a follow-up), so it is not a table row.

-- ── TCCC brand_owner tag ───────────────────────────────────────────────────
ALTER TABLE public.boonz_products ADD COLUMN IF NOT EXISTS brand_owner text;
COMMENT ON COLUMN public.boonz_products.brand_owner IS
'PRD-037: brand parent company. Populated for The Coca-Cola Company portfolio (coexistence.md Rule 1) to drive the ADDMIND/VOX exclusion. NULL = not yet classified.';

-- Backfill every Coca-Cola Company brand present in the catalog. Seed list is the
-- full coexistence.md Rule 1 portfolio; only brands that exist get a row updated.
-- Matches on product_brand (clean brand field), not product names.
UPDATE public.boonz_products
SET brand_owner = 'The Coca-Cola Company'
WHERE brand_owner IS DISTINCT FROM 'The Coca-Cola Company'
  AND product_brand ~* '(coca[ -]?cola|^coke|diet coke|sprite|fanta|schwepp|seagram|appletiser|lilt|dasani|smartwater|topo[ -]?chico|powerade|monster|reign|^burn$|minute maid|del valle|fuze|honest tea|innocent|vitaminwater|costa coffee|georgia coffee)';

-- ── coexistence_rules ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.coexistence_rules (
  rule_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_group    text NOT NULL,
  a_match_type  text NOT NULL CHECK (a_match_type IN ('product_id','product_brand','brand_owner','family_id','name')),
  a_match_value text NOT NULL,
  b_match_type  text CHECK (b_match_type IN ('product_id','product_brand','brand_owner','family_id','name')),
  b_match_value text,
  scope         text NOT NULL CHECK (scope IN ('machine','venue_group','all')),
  venue_groups  text[],
  rule_type     text NOT NULL CHECK (rule_type IN ('hard','soft')),
  note          text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.coexistence_rules IS
'PRD-037 materialization of coexistence.md Rule 1 (TCCC venue exclusion) + Groups 1-7. Brand-keyed (product_family_id is unpopulated). Engine semantics: a candidate C is blocked vs an on-machine product O when a rule exists with (C matches a_match AND O matches b_match) OR the reverse; venue_group-scope rows block C on machines whose venue_group is in venue_groups. Read-only reference data; written by migration only.';

ALTER TABLE public.coexistence_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY coex_select    ON public.coexistence_rules FOR SELECT TO authenticated USING (true);
CREATE POLICY coex_no_insert ON public.coexistence_rules FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY coex_no_update ON public.coexistence_rules FOR UPDATE USING (false);
CREATE POLICY coex_no_delete ON public.coexistence_rules FOR DELETE USING (false);
CREATE INDEX idx_coex_a ON public.coexistence_rules (a_match_type, a_match_value);
CREATE INDEX idx_coex_b ON public.coexistence_rules (b_match_type, b_match_value);

-- ── Seed: Rule 1 (TCCC venue exclusion) ─────────────────────────────────────
INSERT INTO public.coexistence_rules (rule_group, a_match_type, a_match_value, b_match_type, b_match_value, scope, venue_groups, rule_type, note) VALUES
('rule1_tccc_venue_exclusion', 'brand_owner', 'The Coca-Cola Company', NULL, NULL, 'venue_group', ARRAY['ADDMIND','VOX'], 'hard',
 'No TCCC-portfolio product at ADDMIND/VOX (Pepsi contractual exclusivity). coexistence.md Rule 1.');

-- ── Seed: Groups 2/3/4/7 max-1-per-brand (self-pair) ────────────────────────
INSERT INTO public.coexistence_rules (rule_group, a_match_type, a_match_value, b_match_type, b_match_value, scope, rule_type, note) VALUES
('group2_coca_cola',     'product_brand', 'Coca Cola',           'product_brand', 'Coca Cola',           'machine', 'hard', 'Max 1 Coca Cola variant per machine.'),
('group3_pepsi',         'product_brand', 'Pepsi',               'product_brand', 'Pepsi',               'machine', 'hard', 'Max 1 Pepsi variant per machine.'),
('group4_almarai_juice', 'product_brand', 'Almarai Juice',       'product_brand', 'Almarai Juice',       'machine', 'hard', 'Max 1 Almarai Juice flavour per machine.'),
('group7_loacker',       'product_brand', 'Loacker',             'product_brand', 'Loackers Quadratini', 'machine', 'hard', 'Max 1 Loacker-family variant per machine (Loacker vs Loackers Quadratini).');

-- ── Seed: Groups 5/6 cross-brand pairs ──────────────────────────────────────
INSERT INTO public.coexistence_rules (rule_group, a_match_type, a_match_value, b_match_type, b_match_value, scope, rule_type, note) VALUES
('group5_sparkling_water', 'product_brand', 'Evian Sparkling', 'product_brand', 'Perrier', 'machine', 'hard', 'Max 1 sparkling-water brand per machine.'),
('group6_krambals_zigi',   'product_brand', 'Krambals',        'product_brand', 'Zigi',    'machine', 'hard', 'Krambals/Zigi family: max 1 variant per machine.');

-- ── Seed: Group 1 Soft Drinks Mix (name-keyed; inert until that SKU exists) ──
INSERT INTO public.coexistence_rules (rule_group, a_match_type, a_match_value, b_match_type, b_match_value, scope, rule_type, note) VALUES
('group1_soft_drinks_mix', 'name', 'Soft Drinks Mix', 'product_brand', 'Coca Cola',    'machine', 'hard', 'Soft Drinks Mix is a catch-all CSD; cannot coexist with a specific CSD. No SKU in catalog today.'),
('group1_soft_drinks_mix', 'name', 'Soft Drinks Mix', 'product_brand', 'Pepsi',        'machine', 'hard', 'See group1 note.'),
('group1_soft_drinks_mix', 'name', 'Soft Drinks Mix', 'product_brand', 'Mountain Dew', 'machine', 'hard', 'See group1 note.'),
('group1_soft_drinks_mix', 'name', 'Soft Drinks Mix', 'product_brand', '7Up',          'machine', 'hard', 'See group1 note.'),
('group1_soft_drinks_mix', 'name', 'Soft Drinks Mix', 'product_brand', 'Sprite',       'machine', 'hard', 'See group1 note.');
