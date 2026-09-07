-- PRD-119 D4 (held from PRD-119's own close-out, "NOT SHIPPED"): pull-horizon
-- table by product category. Dara design note: `category` as a text PRIMARY
-- KEY (not a UUID surrogate -- this table is a small, hand-edited config
-- lookup like `product_name_conventions`/`refill_qa.feature_flag`, not a
-- growing entity; the category string IS the natural key and is what every
-- join site needs). `pull_days_before_expiry` is a plain integer (days),
-- not an interval -- every consumer computes `plan_date + N`, an interval
-- adds a cast for no benefit. No FK to a separate category-lookup table --
-- `category` is matched directly against `boonz_products.category_group`,
-- the existing canonical grouping (Snacks/Bakery/Confectionery/Beverages/
-- Dairy & Chilled), so a new taxonomy table would just duplicate that
-- column's domain.
--
-- Category mapping (the goal's own seed names -> the real category_group
-- values that exist in boonz_products, confirmed via a live GROUP BY):
--   dairy/chilled  -> 'Dairy & Chilled'  = 5
--   fresh bakery   -> 'Bakery'           = 3  (NOTE: category_group='Bakery'
--     also includes "Biscuits & Cookies" (35 SKUs, shelf-stable, NOT fresh)
--     alongside genuinely fresh "Cakes"/"Pastries & Baked Goods" (11 SKUs) --
--     category_group is the finest existing grouping; a 3-day floor is
--     conservative-safe for the biscuit SKUs (never dangerous, just an
--     earlier ask than strictly needed) and correct for the fresh ones.
--     Flagged for CS if a finer split is ever wanted.
--   drinks         -> 'Beverages'        = 14
--   chips/snacks   -> 'Snacks'           = 21
--   chocolate/bars -> 'Confectionery'    = 21 (folds "Chocolates" in;
--     "chips/snacks" and "chocolate/bars" share the same 21-day value, so
--     the Snacks/Confectionery split carries no functional risk even where
--     a SKU's category_group assignment is debatable)
--   default        -> 'default'         = 14 (any category_group NULL, or
--     not one of the four above -- e.g. 'Test' rows, ungrouped SKUs)
--
-- RLS: SELECT open to all authenticated (every refill/approval path reads
-- this); INSERT/UPDATE/DELETE restricted to operator_admin/superadmin/
-- manager via the standard user_profiles role join, matching every other
-- admin-tunable config table in this schema (not routed through a
-- dedicated RPC -- a 6-row seed table edited rarely by CS/ops, same
-- posture as `product_name_conventions`). Explicit REVOKE from
-- anon/PUBLIC per S-308 (every new table is born writable by
-- `authenticated` via Supabase's default privileges).
--
-- Cody: approve, Articles 2 (RLS enabled), 12 (forward-only, additive).
CREATE TABLE public.expiry_pull_horizon (
  category text PRIMARY KEY,
  pull_days_before_expiry int NOT NULL CHECK (pull_days_before_expiry > 0),
  updated_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  reason text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.expiry_pull_horizon ENABLE ROW LEVEL SECURITY;

CREATE POLICY expiry_pull_horizon_select ON public.expiry_pull_horizon
  FOR SELECT TO authenticated USING (true);

CREATE POLICY expiry_pull_horizon_admin_write ON public.expiry_pull_horizon
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id = (SELECT auth.uid()) AND role = ANY(ARRAY['operator_admin','superadmin','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles WHERE id = (SELECT auth.uid()) AND role = ANY(ARRAY['operator_admin','superadmin','manager'])));

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.expiry_pull_horizon FROM anon, PUBLIC;

INSERT INTO public.expiry_pull_horizon (category, pull_days_before_expiry, reason) VALUES
  ('Dairy & Chilled', 5,  'D4 seed: dairy/chilled turns fastest, shortest safety margin'),
  ('Bakery',          3,  'D4 seed: fresh bakery -- shortest margin of all named categories'),
  ('Beverages',       14, 'D4 seed: drinks'),
  ('Snacks',          21, 'D4 seed: chips/snacks'),
  ('Confectionery',   21, 'D4 seed: chocolate/bars'),
  ('default',         14, 'D4 seed: fallback for any category_group not explicitly listed (NULL, Test, etc.)');
