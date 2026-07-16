-- MIRROR of 2026-07-15 chat-applied prod change (do NOT re-apply; idempotent for db reset).
-- machines.location_type gains 'gym'; boonz_products.physical_type gains 'bottle_shot'.
-- Definitions verified against live pg_constraint 2026-07-16.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='machines_location_type_check'
             AND pg_get_constraintdef(oid) NOT LIKE '%''gym''%') THEN
    ALTER TABLE public.machines DROP CONSTRAINT machines_location_type_check;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='machines_location_type_check') THEN
    ALTER TABLE public.machines ADD CONSTRAINT machines_location_type_check
      CHECK (((location_type IS NULL) OR (location_type = ANY (ARRAY['office'::text, 'coworking'::text, 'entertainment'::text, 'warehouse'::text, 'gym'::text]))));
  END IF;

  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='boonz_products_physical_type_check'
             AND pg_get_constraintdef(oid) NOT LIKE '%''bottle_shot''%') THEN
    ALTER TABLE public.boonz_products DROP CONSTRAINT boonz_products_physical_type_check;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='boonz_products_physical_type_check') THEN
    ALTER TABLE public.boonz_products ADD CONSTRAINT boonz_products_physical_type_check
      CHECK ((physical_type = ANY (ARRAY['can_330'::text, 'can_250'::text, 'bottle_500'::text, 'bottle_330'::text, 'bottle_large'::text, 'bottle_shot'::text, 'tetra_pack'::text, 'cup_yogurt'::text, 'bar_standard'::text, 'bag_snack'::text, 'box_biscuit'::text, 'cake_wrapped'::text, 'bag_large'::text, 'pack_gum'::text, 'date_ball'::text, 'other'::text])));
  END IF;
END $$;
