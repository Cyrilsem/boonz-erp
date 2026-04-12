-- Migration: backfill physical_type for all 269 boonz_products rows
-- CC-20-CC1 step 2 of 3

-- Default everything to 'other' first
UPDATE boonz_products SET physical_type = 'other';

-- Beverages by subcategory
UPDATE boonz_products SET physical_type = 'can_330'
  WHERE product_category = 'Soft Drinks' AND attr_drink = true;

UPDATE boonz_products SET physical_type = 'can_250'
  WHERE product_category = 'Energy & Sports Drinks';

UPDATE boonz_products SET physical_type = 'bottle_500'
  WHERE product_category IN ('Water', 'Sparkling Water', 'Infused Water');

UPDATE boonz_products SET physical_type = 'bottle_330'
  WHERE product_category IN ('Juice', 'Iced Coffee & Tea', 'Protein Milk');

UPDATE boonz_products SET physical_type = 'bottle_large'
  WHERE product_category = 'Vitamin & Health Drinks';

UPDATE boonz_products SET physical_type = 'tetra_pack'
  WHERE product_category = 'Dairy & Yogurt' AND attr_drink = true;

UPDATE boonz_products SET physical_type = 'cup_yogurt'
  WHERE product_category IN ('Dairy & Yogurt', 'Pudding & Desserts')
    AND attr_drink = false;

-- Dry goods
UPDATE boonz_products SET physical_type = 'bar_standard'
  WHERE product_category IN ('Protein & Health Bars', 'Chocolates');

UPDATE boonz_products SET physical_type = 'bag_snack'
  WHERE product_category IN (
    'Chips & Crisps', 'Nuts & Dried Fruits', 'Popcorn',
    'Candy & Gummies', 'Organic Rice Cake'
  );

UPDATE boonz_products SET physical_type = 'box_biscuit'
  WHERE product_category IN (
    'Biscuits & Cookies', 'Crackers & Pretzels',
    'Dips & Crackers', 'Healthy Biscuits'
  );

UPDATE boonz_products SET physical_type = 'cake_wrapped'
  WHERE product_category IN ('Cakes', 'Pastries & Baked Goods');

UPDATE boonz_products SET physical_type = 'bag_large'
  WHERE product_category = 'Novelty Confectionery';

UPDATE boonz_products SET physical_type = 'pack_gum'
  WHERE product_category = 'Gum & Mints';

UPDATE boonz_products SET physical_type = 'date_ball'
  WHERE product_category = 'Date Snacks';
