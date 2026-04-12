-- Migration: add physical_type column to boonz_products (nullable initially)
-- CC-20-CC1 step 1 of 3
-- Uses IF NOT EXISTS — column was pre-applied to production via MCP before this file landed.

ALTER TABLE boonz_products
ADD COLUMN IF NOT EXISTS physical_type text
CHECK (physical_type IN (
  'can_330',
  'can_250',
  'bottle_500',
  'bottle_330',
  'bottle_large',
  'tetra_pack',
  'cup_yogurt',
  'bar_standard',
  'bag_snack',
  'box_biscuit',
  'cake_wrapped',
  'bag_large',
  'pack_gum',
  'date_ball',
  'other'
));
