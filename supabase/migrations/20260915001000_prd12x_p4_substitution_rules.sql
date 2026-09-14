-- PRD-125 D4 / ONE-LOOP Phase 4 -- substitution rules as data.
--
-- Dara-shaped table: uuid PK, RLS enabled, SELECT for authenticated,
-- INSERT/UPDATE/DELETE explicitly revoked from authenticated (S-308 --
-- every new table in public is born writable by authenticated; the default
-- grant must be revoked explicitly, RLS covering it is not enough on its
-- own). Only find_substitutes_for_shelf reads it; no writer RPC exists yet
-- (CS edits via SQL or a future FE settings table -- see the deferred item
-- in DECISIONS-2026-09-15.md).
--
-- Seeded with CS's rules from PRD-125 D4, resolved against live pod_products:
-- Evian -> Al Ain Zero (no Al Ain Zero on machine) / Aquafina (VOX site);
-- Hunter + Hunter Ridge -> Hunter Canister 40G, 9/lane, 3/flavour, cap 12;
-- the dead-snack chain (Dubai Popcorn, Rice & Corn Chips, G&H Popped Chips,
-- G&H Popped Protein, Ritz Cracker, Zigi) -> Benlian, then Sunbites, then
-- Krambals, in that priority order; the scarce-stock and expired-on-shelf
-- rules as engine-enforced (no fixed then_pod_product_id -- they modify
-- HOW a match is chosen, not WHAT it resolves to).
--
-- NOTE: "Freakin Roasted" (named in D4) does not exist as its own pod_product
-- -- the closest live match is "Freakin Healthy Roasted Dipped in Chocolate",
-- which is not the same item PRD-123's Cashew/Almond flavours reference.
-- Left out of the seed rather than guessed; flag for CS to confirm the
-- correct pod_product_id.
CREATE TABLE IF NOT EXISTS public.substitution_rules (
  rule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  priority integer NOT NULL,
  when_pod_product_id uuid REFERENCES public.pod_products(pod_product_id),
  when_condition text,
  then_pod_product_id uuid REFERENCES public.pod_products(pod_product_id),
  then_qty_rule text,
  never_if_on_machine boolean NOT NULL DEFAULT true,
  active boolean NOT NULL DEFAULT true,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_substitution_rules_active_priority
  ON public.substitution_rules (priority) WHERE active = true;
ALTER TABLE public.substitution_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY substitution_rules_select ON public.substitution_rules FOR SELECT TO authenticated USING (true);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.substitution_rules FROM authenticated;
GRANT SELECT ON public.substitution_rules TO authenticated;

INSERT INTO public.substitution_rules (priority, when_pod_product_id, when_condition, then_pod_product_id, then_qty_rule, never_if_on_machine, active, note) VALUES
(10, '07eb303d-eb6e-45d8-a9b8-afb059c207df', 'machine has no Al Ain Zero', 'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77', 'match current lane qty', true, true, 'PRD-125 D4: Evian -> Al Ain Zero'),
(20, '07eb303d-eb6e-45d8-a9b8-afb059c207df', 'VOX site', '11b11bda-d277-4ab0-8105-595a209750ce', 'match current lane qty', true, true, 'PRD-125 D4: Evian -> Aquafina at VOX sites'),
(10, '168aeb7e-fc0c-441b-94df-6d8cc185945d', null, '355aa701-37eb-4e74-a13c-e893d0f66e3b', '9 canisters to a lane, 3 per flavour, capacity override 12', true, true, 'PRD-125 D4: Hunter bags -> Hunter Canister'),
(10, '51e4600f-2c15-428b-92ef-85fdc783c3af', null, '355aa701-37eb-4e74-a13c-e893d0f66e3b', '9 canisters to a lane, 3 per flavour, capacity override 12', true, true, 'PRD-125 D4: Hunter Ridge -> Hunter Canister'),
(10, '31c78eac-d859-41d7-8ba1-6d5cee5381ff', null, '34b6ee46-5a1b-4d2b-a1c8-b92b89fe9945', 'match current lane qty', true, true, 'PRD-125 D4 chain 1/3: Dubai Popcorn -> Benlian'),
(20, '31c78eac-d859-41d7-8ba1-6d5cee5381ff', null, '45a302cb-8e10-464a-9c46-5b2f873cfadd', 'match current lane qty', true, true, 'PRD-125 D4 chain 2/3: Dubai Popcorn -> Sunbites'),
(30, '31c78eac-d859-41d7-8ba1-6d5cee5381ff', null, '27444f0d-7d3c-4480-bbdc-4faf60acbdbc', 'match current lane qty', true, true, 'PRD-125 D4 chain 3/3: Dubai Popcorn -> Krambals'),
(10, '195a5050-dd96-425f-8781-385c74661126', null, '34b6ee46-5a1b-4d2b-a1c8-b92b89fe9945', 'match current lane qty', true, true, 'PRD-125 D4 chain 1/3: Rice & Corn -> Benlian'),
(20, '195a5050-dd96-425f-8781-385c74661126', null, '45a302cb-8e10-464a-9c46-5b2f873cfadd', 'match current lane qty', true, true, 'PRD-125 D4 chain 2/3: Rice & Corn -> Sunbites'),
(30, '195a5050-dd96-425f-8781-385c74661126', null, '27444f0d-7d3c-4480-bbdc-4faf60acbdbc', 'match current lane qty', true, true, 'PRD-125 D4 chain 3/3: Rice & Corn -> Krambals'),
(10, 'e49838aa-8d9d-4dc0-8d0d-96c84720d775', null, '34b6ee46-5a1b-4d2b-a1c8-b92b89fe9945', 'match current lane qty', true, true, 'PRD-125 D4 chain 1/3: G&H Popped Chips -> Benlian'),
(20, 'e49838aa-8d9d-4dc0-8d0d-96c84720d775', null, '45a302cb-8e10-464a-9c46-5b2f873cfadd', 'match current lane qty', true, true, 'PRD-125 D4 chain 2/3: G&H Popped Chips -> Sunbites'),
(30, 'e49838aa-8d9d-4dc0-8d0d-96c84720d775', null, '27444f0d-7d3c-4480-bbdc-4faf60acbdbc', 'match current lane qty', true, true, 'PRD-125 D4 chain 3/3: G&H Popped Chips -> Krambals'),
(10, '9bb1abae-8eb4-4ae2-a8a1-6c6e1606b3ed', null, '34b6ee46-5a1b-4d2b-a1c8-b92b89fe9945', 'match current lane qty', true, true, 'PRD-125 D4 chain 1/3: G&H Popped Protein -> Benlian'),
(20, '9bb1abae-8eb4-4ae2-a8a1-6c6e1606b3ed', null, '45a302cb-8e10-464a-9c46-5b2f873cfadd', 'match current lane qty', true, true, 'PRD-125 D4 chain 2/3: G&H Popped Protein -> Sunbites'),
(30, '9bb1abae-8eb4-4ae2-a8a1-6c6e1606b3ed', null, '27444f0d-7d3c-4480-bbdc-4faf60acbdbc', 'match current lane qty', true, true, 'PRD-125 D4 chain 3/3: G&H Popped Protein -> Krambals'),
(10, 'f2f2733f-22d5-4d28-9477-eccc90768955', null, '34b6ee46-5a1b-4d2b-a1c8-b92b89fe9945', 'match current lane qty', true, true, 'PRD-125 D4 chain 1/3: Ritz Cracker -> Benlian'),
(20, 'f2f2733f-22d5-4d28-9477-eccc90768955', null, '45a302cb-8e10-464a-9c46-5b2f873cfadd', 'match current lane qty', true, true, 'PRD-125 D4 chain 2/3: Ritz Cracker -> Sunbites'),
(30, 'f2f2733f-22d5-4d28-9477-eccc90768955', null, '27444f0d-7d3c-4480-bbdc-4faf60acbdbc', 'match current lane qty', true, true, 'PRD-125 D4 chain 3/3: Ritz Cracker -> Krambals'),
(10, 'da115e6f-8d9b-48ab-b998-531cb81d3faa', null, '34b6ee46-5a1b-4d2b-a1c8-b92b89fe9945', 'match current lane qty', true, true, 'PRD-125 D4 chain 1/3: Zigi -> Benlian'),
(20, 'da115e6f-8d9b-48ab-b998-531cb81d3faa', null, '45a302cb-8e10-464a-9c46-5b2f873cfadd', 'match current lane qty', true, true, 'PRD-125 D4 chain 2/3: Zigi -> Sunbites'),
(30, 'da115e6f-8d9b-48ab-b998-531cb81d3faa', null, '27444f0d-7d3c-4480-bbdc-4faf60acbdbc', 'match current lane qty', true, true, 'PRD-125 D4 chain 3/3: Zigi -> Krambals'),
(90, null, 'fleet-wide free stock of the WEIMI product under 12', null, 'single highest-velocity lane that wants it, nowhere else', false, true, 'PRD-125 D4: scarce-stock consolidation rule (engine-enforced, no fixed then_pod_product_id)'),
(5, null, 'expired on shelf', null, 'Remove plus the substitute, same line', true, true, 'PRD-125 D4: expired-on-shelf rule (engine-enforced alongside whichever chain rule matches the product)')
ON CONFLICT DO NOTHING;
