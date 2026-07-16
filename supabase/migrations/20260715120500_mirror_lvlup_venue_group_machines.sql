-- MIRROR of 2026-07-15 chat-applied prod change (do NOT re-apply; idempotent).
-- venue_groups LVLUP + the three LVLUP machines' classification.
INSERT INTO public.venue_groups (code, display_name, active, commercial_notes)
VALUES ('LVLUP', 'LevelUp', true,
  'Partner-sourced model. LevelUp sources 100% of product; Boonz holds zero inventory and zero COGS. Boonz supplies the machine and takes 25% of net revenue (VOX-style rev share, no COGS leg). Machines are include_in_refill=false: excluded from the refill engine, dispatch, packing and driver routes. Boonz delivers sales intelligence, rev-share reporting and replenishment intelligence only. All product_mapping rows for this group use source_of_supply=''venue_team'' with avg_cost NULL.')
ON CONFLICT (code) DO NOTHING;

UPDATE public.machines
   SET location_type = 'gym', venue_group = 'LVLUP', include_in_refill = false,
       adyen_status = 'Online today', adyen_inventory_in_store = 'Live'
 WHERE official_name IN ('LVLUP-1018-0000-G0','LVLUP-1048-0000-P0','LVLUP-2015-0000-R0');
