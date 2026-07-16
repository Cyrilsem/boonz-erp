-- PRD-CLEAN-11 M4 (DDL): add 'bottle_shot' physical type.
-- Mini health shots (~60-100ml) fit no existing type; 'other' is a dumping ground
-- and physical_type drives slot capacity/fit.
ALTER TABLE public.boonz_products DROP CONSTRAINT boonz_products_physical_type_check;
ALTER TABLE public.boonz_products ADD CONSTRAINT boonz_products_physical_type_check
  CHECK ((physical_type = ANY (ARRAY[
    'can_330'::text, 'can_250'::text, 'bottle_500'::text, 'bottle_330'::text,
    'bottle_large'::text, 'bottle_shot'::text, 'tetra_pack'::text, 'cup_yogurt'::text,
    'bar_standard'::text, 'bag_snack'::text, 'box_biscuit'::text, 'cake_wrapped'::text,
    'bag_large'::text, 'pack_gum'::text, 'date_ball'::text, 'other'::text
  ])));
