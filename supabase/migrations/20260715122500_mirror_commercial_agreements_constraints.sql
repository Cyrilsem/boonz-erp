-- MIRROR of prod state as of 2026-07-15 (do NOT re-apply; idempotent).
-- Model columns to NOT NULL + the four coherence CHECKs (after the data backfill).
ALTER TABLE public.commercial_agreements
  ALTER COLUMN source_of_supply          SET NOT NULL,
  ALTER COLUMN boonz_bears_cogs          SET NOT NULL,
  ALTER COLUMN cogs_recovered_from_venue SET NOT NULL,
  ALTER COLUMN boonz_refills             SET NOT NULL,
  ALTER COLUMN adyen_pct                 SET NOT NULL,
  ALTER COLUMN adyen_fixed_aed           SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='commercial_agreements_source_of_supply_check') THEN
    ALTER TABLE public.commercial_agreements ADD CONSTRAINT commercial_agreements_source_of_supply_check
      CHECK ((source_of_supply = ANY (ARRAY['boonz'::text, 'venue_team'::text])));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='commercial_agreements_shares_sum_check') THEN
    ALTER TABLE public.commercial_agreements ADD CONSTRAINT commercial_agreements_shares_sum_check
      CHECK (((boonz_share_pct + partner_share_pct) = (1)::numeric));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='commercial_agreements_cogs_recovery_check') THEN
    ALTER TABLE public.commercial_agreements ADD CONSTRAINT commercial_agreements_cogs_recovery_check
      CHECK (((NOT cogs_recovered_from_venue) OR boonz_bears_cogs));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='commercial_agreements_venue_sourced_check') THEN
    ALTER TABLE public.commercial_agreements ADD CONSTRAINT commercial_agreements_venue_sourced_check
      CHECK (((source_of_supply <> 'venue_team'::text) OR ((NOT boonz_bears_cogs) AND (NOT boonz_refills))));
  END IF;
END $$;
