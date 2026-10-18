-- PRD-142a Phase 3 (additive part): machine strategy tables and posture defaults,
-- plus product_clusters (shared with Phase 4 and the category-balance clause of
-- the diagnosis). Nothing here is read by the refill engine; 142b wires it.

CREATE TABLE public.strategy_posture_defaults (
  posture    text NOT NULL CHECK (posture IN ('PROTECT_GROW', 'FIX_MIX', 'WATCH_ADAPT', 'NOT_FLIPPABLE')),
  population text NOT NULL CHECK (population IN ('boonz', 'partner')),
  label      text NOT NULL,
  params     jsonb NOT NULL,
  PRIMARY KEY (posture, population)
);
INSERT INTO public.strategy_posture_defaults (posture, population, label, params) VALUES
  ('PROTECT_GROW', 'boonz', 'Protect and grow', '{"fill_depth": "full", "swap_mode": "dead_lanes_only", "allow_new_products": true, "seed_source": true}'),
  ('PROTECT_GROW', 'partner', 'Protect and grow', '{"fill_depth": "full", "swap_mode": "dead_lanes_only", "allow_new_products": false, "seed_source": true}'),
  ('FIX_MIX', 'boonz', 'Fix the mix', '{"fill_depth": "standard", "swap_mode": "aggressive", "allow_new_products": true, "cabinet_reset_flag": false}'),
  ('FIX_MIX', 'partner', 'Fix the mix', '{"fill_depth": "standard", "swap_mode": "aggressive", "allow_new_products": false, "cabinet_reset_flag": false}'),
  ('WATCH_ADAPT', 'boonz', 'Watch and adapt', '{"fill_depth": "conservative", "swap_mode": "dead_lanes_only", "allow_new_products": false, "venue_check_flag": true, "review_days": 45, "picker_multiplier": 0.8}'),
  ('WATCH_ADAPT', 'partner', 'Watch and adapt', '{"fill_depth": "conservative", "swap_mode": "dead_lanes_only", "allow_new_products": false, "venue_check_flag": true, "review_days": 45, "picker_multiplier": 0.8}'),
  ('NOT_FLIPPABLE', 'boonz', 'Not flippable', '{"fill_depth": "minimum", "swap_mode": "none", "allow_new_products": false, "drain_source": true, "relocate_flag": true, "picker_multiplier": 0.5}'),
  ('NOT_FLIPPABLE', 'partner', 'Not flippable', '{"fill_depth": "minimum", "swap_mode": "none", "allow_new_products": false, "drain_source": true, "relocate_flag": true, "picker_multiplier": 0.5}');

CREATE TABLE public.machine_strategy (
  machine_id        uuid PRIMARY KEY REFERENCES public.machines(machine_id),
  archetype_code    text,
  posture           text CHECK (posture IN ('PROTECT_GROW', 'FIX_MIX', 'WATCH_ADAPT', 'NOT_FLIPPABLE')),
  posture_proposed  text CHECK (posture_proposed IN ('PROTECT_GROW', 'FIX_MIX', 'WATCH_ADAPT', 'NOT_FLIPPABLE')),
  proposed_at       timestamptz,
  proposed_reason   text,
  proposal_detail   jsonb,
  confirmed_at      timestamptz,
  confirmed_by      uuid,
  review_by         date,
  params            jsonb,
  shelf_overrides   jsonb NOT NULL DEFAULT '[]'::jsonb,
  notes             text,
  rejected_posture  text,
  rejected_until    date,
  rejected_reason   text,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.product_clusters (
  product_category text PRIMARY KEY,
  cluster_code     text NOT NULL,
  cluster_label    text NOT NULL,
  sort_order       int NOT NULL
);
INSERT INTO public.product_clusters (product_category, cluster_code, cluster_label, sort_order) VALUES
  ('Water', 'WATER', 'Water and sparkling', 1),
  ('Sparkling Water', 'WATER', 'Water and sparkling', 1),
  ('Infused Water', 'WATER', 'Water and sparkling', 1),
  ('Soft Drinks', 'SOFT_ENERGY', 'Soft and energy drinks', 2),
  ('Energy & Sports Drinks', 'SOFT_ENERGY', 'Soft and energy drinks', 2),
  ('Juice', 'SOFT_ENERGY', 'Soft and energy drinks', 2),
  ('Iced Coffee & Tea', 'SOFT_ENERGY', 'Soft and energy drinks', 2),
  ('Vitamin & Health Drinks', 'HEALTH_DRINKS', 'Health and protein drinks', 3),
  ('Protein Milk', 'HEALTH_DRINKS', 'Health and protein drinks', 3),
  ('Dairy & Yogurt', 'HEALTH_DRINKS', 'Health and protein drinks', 3),
  ('Protein Pudding', 'HEALTH_DRINKS', 'Health and protein drinks', 3),
  ('Protein & Health Bars', 'BARS_DATES', 'Bars, protein and dates', 4),
  ('Snack Bar', 'BARS_DATES', 'Bars, protein and dates', 4),
  ('Date Snacks', 'BARS_DATES', 'Bars, protein and dates', 4),
  ('Nuts & Dried Fruits', 'BARS_DATES', 'Bars, protein and dates', 4),
  ('Chocolate Bar', 'CHOC_CANDY', 'Chocolate and candy', 5),
  ('Chocolates', 'CHOC_CANDY', 'Chocolate and candy', 5),
  ('Candy & Gummies', 'CHOC_CANDY', 'Chocolate and candy', 5),
  ('Chewing Gum', 'CHOC_CANDY', 'Chocolate and candy', 5),
  ('Novelty Confectionery', 'CHOC_CANDY', 'Chocolate and candy', 5),
  ('Biscuits & Cookies', 'BISCUITS', 'Biscuits, cakes and crackers', 6),
  ('Cakes', 'BISCUITS', 'Biscuits, cakes and crackers', 6),
  ('Crackers & Pretzels', 'BISCUITS', 'Biscuits, cakes and crackers', 6),
  ('Pastries & Baked Goods', 'BISCUITS', 'Biscuits, cakes and crackers', 6),
  ('Organic Rice Cake', 'BISCUITS', 'Biscuits, cakes and crackers', 6),
  ('Chips', 'CHIPS_POPCORN', 'Chips and popcorn', 7),
  ('Chips & Crisps', 'CHIPS_POPCORN', 'Chips and popcorn', 7),
  ('Popcorn', 'CHIPS_POPCORN', 'Chips and popcorn', 7),
  ('Fresh Food', 'FRESH_DIPS', 'Fresh and dips', 8),
  ('Fresh Fruit', 'FRESH_DIPS', 'Fresh and dips', 8),
  ('Dips & Crackers', 'FRESH_DIPS', 'Fresh and dips', 8),
  ('Test', 'UNCLASSIFIED', 'Unclassified', 9);

CREATE OR REPLACE FUNCTION public.strategy_cluster(p_category text)
RETURNS text
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE((SELECT cluster_code FROM product_clusters WHERE product_category = p_category), 'UNCLASSIFIED')
$$;

COMMENT ON TABLE public.strategy_posture_defaults IS 'PRD-142a 5.1. Default params per posture and population (5.5 view reads these in 142b).';
COMMENT ON TABLE public.machine_strategy IS 'PRD-142a 5.3. One row per machine. The nightly job writes archetype_code, posture_proposed, proposed_at, proposed_reason (diagnosis sentence) and proposal_detail only; posture, params, shelf_overrides, notes, confirmed_* are written only by set_machine_strategy (CS). A rejected proposal is suppressed until rejected_until.';
COMMENT ON TABLE public.product_clusters IS 'PRD-142a 6.1. pod_products.product_category to the 8 Portfolio Map clusters (+ UNCLASSIFIED). CS extends it when categories are added.';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['strategy_posture_defaults','machine_strategy','product_clusters'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.is_admin((SELECT auth.uid())))', t || '_admin_select', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
  END LOOP;
END $$;
