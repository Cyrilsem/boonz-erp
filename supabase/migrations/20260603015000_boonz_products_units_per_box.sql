-- boonz_products.units_per_box — supplier case/box size for procurement rounding.
-- Mirrors the weekly-procurement skill's box-minimum table. Nullable: products
-- without a known box size are left NULL and get no rounding downstream.

ALTER TABLE public.boonz_products ADD COLUMN IF NOT EXISTS units_per_box smallint;
COMMENT ON COLUMN public.boonz_products.units_per_box IS 'Supplier case/box size; procurement suggested qty rounds up to a multiple of this. NULL = no rounding.';

UPDATE public.boonz_products SET units_per_box = CASE
  WHEN boonz_product_name ILIKE 'Kinder Delice%'                                   THEN 10
  WHEN boonz_product_name ILIKE 'Kinder Bueno%'                                    THEN 10
  WHEN boonz_product_name ILIKE 'Oreo%'                                            THEN 12
  WHEN boonz_product_name ILIKE 'Snickers%' OR boonz_product_name ILIKE 'Mars%'
       OR boonz_product_name ILIKE 'M&M - Chocolate Nuts%' OR boonz_product_name ILIKE 'Bounty%'
       OR boonz_product_name ILIKE 'Twix%'                                         THEN 24
  WHEN boonz_product_name ILIKE 'McVities%Mini%'                                   THEN 12
  WHEN boonz_product_name ILIKE 'Nestle Kit%' OR boonz_product_name ILIKE '%Kit-kat%'
       OR boonz_product_name ILIKE '%KitKat%'                                      THEN 24
  WHEN boonz_product_name ILIKE 'Barebells%'                                       THEN 12
  WHEN boonz_product_name ILIKE 'Vitamin Well%' OR boonz_product_name ILIKE 'Vitamin well%' THEN 12
  WHEN boonz_product_name ILIKE 'Popit%'                                           THEN 24
  WHEN boonz_product_name ILIKE 'Krambals%'                                        THEN 12
  WHEN boonz_product_name ILIKE 'Perrier%'                                         THEN 10
  WHEN boonz_product_name ILIKE 'Be-kind Bar%' OR boonz_product_name ILIKE 'Be-Kind Bar%' THEN 12
  WHEN boonz_product_name ILIKE 'Be-kind Cluster%'                                 THEN 8
  WHEN boonz_product_name ILIKE 'Evian - 1L%'                                      THEN 12
  WHEN boonz_product_name ILIKE 'Evian%'                                           THEN 24
  WHEN boonz_product_name ILIKE 'Al Ain%'                                          THEN 24
  WHEN boonz_product_name ILIKE 'Red Bull%'                                        THEN 24
  WHEN boonz_product_name ILIKE 'Sun Blast%' OR boonz_product_name ILIKE 'Sunblast%' THEN 10
  WHEN boonz_product_name ILIKE 'Zigi%'                                            THEN 14
  WHEN boonz_product_name ILIKE 'Tamreem%Ball%'                                    THEN 25
  WHEN boonz_product_name ILIKE 'SF Pancake%'                                      THEN 10
  WHEN boonz_product_name ILIKE 'G&H Popped Chips%'                                THEN 8
  WHEN boonz_product_name ILIKE 'Ice Tea%'                                         THEN 6
  WHEN boonz_product_name ILIKE 'Coca Cola%' OR boonz_product_name ILIKE 'Pepsi%'
       OR boonz_product_name ILIKE '7Up%' OR boonz_product_name ILIKE '7up%'
       OR boonz_product_name ILIKE 'Mountain Dew%' OR boonz_product_name ILIKE 'Healthy Cola%' THEN 6
  ELSE units_per_box
END
WHERE units_per_box IS NULL;
