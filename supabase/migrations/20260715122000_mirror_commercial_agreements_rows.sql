-- MIRROR of prod commercial_agreements rows as of 2026-07-15 (do NOT re-apply; idempotent).
-- New rows insert ON CONFLICT DO NOTHING; the model-column backfill only touches NULLs so a
-- replay never clobbers later tuning. All rows use the fleet fee schedule 2.6% + 0.50 AED.

INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('VOX', 'VOX', 'VOX Cinemas', 0.2000, 0.8000, 'boonz', true, true, true, 0.026, 0.50, '2026-04-19', 'VOX revenue share — includes COGS from Boonz')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('GRIT', 'REVENUE_SHARE', 'GRIT', 0.9500, 0.0500, 'boonz', true, false, true, 0.026, 0.50, '2026-04-19', 'Site partner 5% of net revenue, no COGS accountability')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('OHMYDESK', 'REVENUE_SHARE', 'OhmyDesk', 0.9500, 0.0500, 'boonz', true, false, true, 0.026, 0.50, '2026-04-19', 'Site partner 5% of net revenue, no COGS accountability')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('ADDMIND', 'NONE', NULL, 1.0000, 0.0000, 'boonz', true, false, true, 0.026, 0.50, '2026-04-19', 'No commercial agreement')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('VML', 'NONE', NULL, 1.0000, 0.0000, 'boonz', true, false, true, 0.026, 0.50, '2026-04-19', 'No commercial agreement')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('WPP', 'NONE', NULL, 1.0000, 0.0000, 'boonz', true, false, true, 0.026, 0.50, '2026-04-19', 'No commercial agreement')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('INDEPENDENT', 'NONE', NULL, 1.0000, 0.0000, 'boonz', true, false, true, 0.026, 0.50, '2026-04-19', 'No commercial agreement — Boonz keeps 100%')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('AMAZON', 'NONE', NULL, 1.0000, 0.0000, 'boonz', true, false, true, 0.026, 0.50, '2026-04-19', 'No commercial agreement — Boonz keeps 100%. Boonz operates end to end (procurement, warehouse, refill, driver routes) exactly as any standard machine. Recorded 2026-07-15 per CS.')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('NOVO', 'NONE', NULL, 1.0000, 0.0000, 'boonz', true, false, true, 0.026, 0.50, '2026-04-19', 'No commercial agreement — Boonz keeps 100%. Boonz operates end to end (procurement, warehouse, refill, driver routes) exactly as any standard machine. Recorded 2026-07-15 per CS.')
ON CONFLICT (venue_group) DO NOTHING;
INSERT INTO public.commercial_agreements
  (venue_group, agreement_type, partner_name, boonz_share_pct, partner_share_pct,
   source_of_supply, boonz_bears_cogs, cogs_recovered_from_venue, boonz_refills,
   adyen_pct, adyen_fixed_aed, effective_date, notes)
VALUES ('LVLUP', 'PARTNER_SOURCED', 'LevelUp', 0.2500, 0.7500, 'venue_team', false, false, false, 0.026, 0.50, '2026-07-13', 'Partner-sourced scaling model. LevelUp sources 100% of product; Boonz holds zero inventory and zero COGS. Boonz supplies the machine and takes 25% of net revenue. Machines are include_in_refill=false and excluded from the refill engine, dispatch, packing and driver routes. Boonz delivers sales intelligence, rev-share reporting and replenishment intelligence only. Installed 2026-07-13.')
ON CONFLICT (venue_group) DO NOTHING;

-- Backfill only where the model columns are still NULL (pre-2026-07-15 shape)
UPDATE public.commercial_agreements SET
  source_of_supply          = COALESCE(source_of_supply, 'boonz'),
  boonz_bears_cogs          = COALESCE(boonz_bears_cogs, true),
  cogs_recovered_from_venue = COALESCE(cogs_recovered_from_venue, venue_group = 'VOX'),
  boonz_refills             = COALESCE(boonz_refills, true),
  adyen_pct                 = COALESCE(adyen_pct, 0.026),
  adyen_fixed_aed           = COALESCE(adyen_fixed_aed, 0.50)
WHERE source_of_supply IS NULL OR boonz_bears_cogs IS NULL OR cogs_recovered_from_venue IS NULL
   OR boonz_refills IS NULL OR adyen_pct IS NULL OR adyen_fixed_aed IS NULL;
