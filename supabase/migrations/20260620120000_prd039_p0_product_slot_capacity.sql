-- PRD-039 Phase 0 (A): product_slot_capacity matrix + matrix-miss resolver.
-- Forward-only. No edit-in-place, no _v2, no deletes. Author-only until CS green-lights apply.
--
-- WHY: PRD-037 Pass-3 caps every candidate at the INCUMBENT slot's observed max
-- (v_shelf_max_stock). A candidate of a different physical size is therefore mis-capped
-- (Be-kind Bar capped at popcorn's 6; a bulky SKU over-credited in a 21-slot). WS-B needs a
-- candidate-specific cap keyed on (candidate.physical_type, shelf.shelf_size). No such matrix
-- exists today: slot_capacity_max is a per-aisle manual override, not the matrix.
--
-- SEED DECISION IS CS's (two options below). Live taxonomy = 14 boonz_products.physical_type
-- values; live shelf sizes = Small / Medium / Large (planogram.shelf_size; shelf_configurations
-- .shelf_size is ~99% NULL). x0.85 fill factor is applied IN-ENGINE (WS-B), so this matrix stores
-- MAX UNITS (physical limit), not target_qty.

CREATE TABLE IF NOT EXISTS public.product_slot_capacity (
  physical_type text NOT NULL,
  shelf_size    text NOT NULL CHECK (shelf_size IN ('Small','Medium','Large')),
  max_units     integer NOT NULL CHECK (max_units > 0),
  seed_source   text NOT NULL DEFAULT 'observed_v_shelf_max_stock_2026_06_20',
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (physical_type, shelf_size)
);

COMMENT ON TABLE public.product_slot_capacity IS
  'PRD-039 WS-B. Max UNITS (pre-0.85 fill) a product of physical_type holds in a shelf_size slot. '
  'Read-only reference. Engine applies x0.85 then override/shelf fallback. Resolver handles cell misses.';

ALTER TABLE public.product_slot_capacity ENABLE ROW LEVEL SECURITY;

-- Read-only to authenticated; no insert/update/delete policy (writes only via migration / owner).
DROP POLICY IF EXISTS psc_select ON public.product_slot_capacity;
CREATE POLICY psc_select ON public.product_slot_capacity
  FOR SELECT TO authenticated USING (true);

-- ============================================================================
-- SEED OPTION B (RECOMMENDED, ACTIVE): observed physical max per (physical_type,
-- shelf_size) from v_shelf_max_stock joined to the current incumbent + planogram
-- shelf_size, 2026-06-20. 33 observed cells; 9 cells unobserved -> resolver fallback.
-- Rationale: lives natively on the 14-value taxonomy; reflects real Weimi physical
-- limits the engine already trusts (v12 multiplies max_stock_weimi x 0.85). NOT forced
-- monotonic because live slot-size assignment is demand-driven, not size-driven
-- (e.g. bag_snack Small=25 > Large=20). The matrix is more accurate left un-smoothed.
-- ============================================================================
INSERT INTO public.product_slot_capacity (physical_type, shelf_size, max_units) VALUES
  ('bag_large','Small',12),  ('bag_large','Medium',8),   ('bag_large','Large',15),
  ('bag_snack','Small',25),  ('bag_snack','Medium',14),  ('bag_snack','Large',20),
  ('bar_standard','Small',30),('bar_standard','Medium',30),
  ('bottle_330','Small',18), ('bottle_330','Medium',20), ('bottle_330','Large',20),
  ('bottle_500','Small',17), ('bottle_500','Medium',21), ('bottle_500','Large',30),
  ('bottle_large','Small',14),('bottle_large','Medium',15),('bottle_large','Large',16),
  ('box_biscuit','Small',25),('box_biscuit','Medium',30),('box_biscuit','Large',20),
  ('cake_wrapped','Small',20),('cake_wrapped','Medium',30),
  ('can_250','Small',15),
  ('can_330','Small',15),    ('can_330','Medium',21),    ('can_330','Large',20),
  ('cup_yogurt','Small',8),  ('cup_yogurt','Medium',6),
  ('date_ball','Small',14),  ('date_ball','Medium',8),   ('date_ball','Large',12),
  ('other','Small',16),
  ('pack_gum','Small',8)
ON CONFLICT (physical_type, shelf_size) DO NOTHING;

-- ============================================================================
-- SEED OPTION A (ALTERNATIVE, COMMENTED): layout.md s4 hand-tuned MAX capacity,
-- crosswalked from its stale 15-name taxonomy to the live 14. Monotonic by rule
-- (L>=M>=S). LOSSY: layout has no analog for bottle_330, cake_wrapped, cup_yogurt,
-- other; can_250 proxied by health_drink, date_ball by dried_fruit_pack, bag_large
-- by candy_bag_large, bag_snack by small_snack, bottle_large by water_bottle_1000
-- (Large-only). Unmapped cells -> resolver fallback. If CS picks A, swap the two
-- INSERT blocks and set seed_source='layout_md_s4_crosswalk_2026_06_20'.
-- ----------------------------------------------------------------------------
-- INSERT INTO public.product_slot_capacity (physical_type, shelf_size, max_units, seed_source) VALUES
--   ('bar_standard','Small',15),('bar_standard','Medium',25),('bar_standard','Large',40),
--   ('bottle_500','Small',6),  ('bottle_500','Medium',10), ('bottle_500','Large',15),
--   ('bottle_large','Large',12),
--   ('can_330','Small',14),    ('can_330','Medium',18),    ('can_330','Large',22),
--   ('can_250','Small',6),     ('can_250','Medium',12),    ('can_250','Large',16),
--   ('bag_large','Small',10),  ('bag_large','Medium',12),  ('bag_large','Large',14),
--   ('bag_snack','Small',8),   ('bag_snack','Medium',10),  ('bag_snack','Large',12),
--   ('box_biscuit','Small',8), ('box_biscuit','Medium',12),('box_biscuit','Large',16),
--   ('date_ball','Small',10),  ('date_ball','Medium',12),  ('date_ball','Large',14),
--   ('pack_gum','Small',8),    ('pack_gum','Medium',10),   ('pack_gum','Large',12)
-- ON CONFLICT (physical_type, shelf_size) DO NOTHING;

-- ============================================================================
-- Matrix-miss resolver. Guarantees a non-NULL cap for EVERY (physical_type, shelf_size)
-- even when a cell is unseeded. Ladder:
--   1. exact (physical_type, shelf_size) cell;
--   2. nearest present size for same physical_type (Large->Medium->Small; Small->Medium->Large);
--   3. bar_standard cell for that shelf_size (a sane mid catalogue capacity);
--   4. hard default 8.
-- The PER-SLOT fallback chain (override_max_stock -> shelf_configurations.max_capacity)
-- stays in the engine (WS-B); this resolver only covers TYPE/SIZE matrix misses.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.product_slot_capacity_units(
  p_physical_type text,
  p_shelf_size    text
) RETURNS integer
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    -- 1. exact
    (SELECT max_units FROM public.product_slot_capacity
      WHERE physical_type = p_physical_type AND shelf_size = p_shelf_size),
    -- 2. nearest present size, same type
    (SELECT max_units FROM public.product_slot_capacity
      WHERE physical_type = p_physical_type
      ORDER BY CASE p_shelf_size
                 WHEN 'Large'  THEN CASE shelf_size WHEN 'Medium' THEN 1 WHEN 'Small' THEN 2 ELSE 9 END
                 WHEN 'Medium' THEN CASE shelf_size WHEN 'Small'  THEN 1 WHEN 'Large' THEN 2 ELSE 9 END
                 ELSE              CASE shelf_size WHEN 'Medium' THEN 1 WHEN 'Large' THEN 2 ELSE 9 END
               END
      LIMIT 1),
    -- 3. bar_standard of that size
    (SELECT max_units FROM public.product_slot_capacity
      WHERE physical_type = 'bar_standard' AND shelf_size = p_shelf_size),
    -- 4. hard default
    8
  )::int;
$$;

COMMENT ON FUNCTION public.product_slot_capacity_units(text,text) IS
  'PRD-039 WS-B matrix-miss resolver. Never returns NULL for the 14 live physical_types x {Small,Medium,Large}.';

-- ============================================================================
-- COVERAGE SELF-CHECK (run read-only after apply; must return 42 rows, all cap_units > 0,
-- zero NULLs). 14 live physical_types x 3 shelf sizes.
-- ============================================================================
-- SELECT pt.physical_type, sz.shelf_size,
--        public.product_slot_capacity_units(pt.physical_type, sz.shelf_size) AS cap_units,
--        (SELECT max_units FROM public.product_slot_capacity c
--          WHERE c.physical_type=pt.physical_type AND c.shelf_size=sz.shelf_size) IS NULL AS via_fallback
--   FROM (SELECT DISTINCT physical_type FROM public.boonz_products WHERE physical_type IS NOT NULL) pt
--   CROSS JOIN (VALUES ('Small'),('Medium'),('Large')) sz(shelf_size)
--  ORDER BY pt.physical_type, sz.shelf_size;
