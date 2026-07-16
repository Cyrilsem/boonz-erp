-- PRD-CLEAN-12 (revised): consolidate onto the INCUMBENT commercial_agreements.
-- venue_commercial_terms (created earlier today) duplicated this table and is being dropped.
-- commercial_agreements is already read by the partner-performance-report skill and holds
-- partner_name, so it wins. Extend it with the operating-model columns the LevelUp
-- partner-sourced model needs, which VOX/GRIT/OhmyDesk previously encoded only in prose notes.

ALTER TABLE public.commercial_agreements
  ADD COLUMN IF NOT EXISTS source_of_supply          text,
  ADD COLUMN IF NOT EXISTS boonz_bears_cogs          boolean,
  ADD COLUMN IF NOT EXISTS cogs_recovered_from_venue boolean,
  ADD COLUMN IF NOT EXISTS boonz_refills             boolean,
  ADD COLUMN IF NOT EXISTS adyen_pct                 numeric,
  ADD COLUMN IF NOT EXISTS adyen_fixed_aed           numeric,
  ADD COLUMN IF NOT EXISTS updated_at                timestamptz NOT NULL DEFAULT now();

COMMENT ON TABLE public.commercial_agreements IS
'Canonical commercial + operating model per venue group. One row per venue_group (UNIQUE). '
'Read by the partner-performance-report skill and get_venue_terms(). Supersedes the hardcoded '
'percentages in the VOX report functions (v_boonz_pct := 0.20 etc) - those are pending refactor.';

COMMENT ON COLUMN public.commercial_agreements.source_of_supply IS
'Who buys the goods: boonz = Boonz procures and holds inventory; venue_team = partner sources 100%, Boonz holds none.';
COMMENT ON COLUMN public.commercial_agreements.cogs_recovered_from_venue IS
'True when Boonz COGS is deducted from the venue''s dues (VOX model), false when Boonz absorbs it (GRIT/OhmyDesk).';
COMMENT ON COLUMN public.commercial_agreements.boonz_refills IS
'False for partner-sourced groups: excluded from the refill engine, dispatch, packing and driver routes.';

DROP FUNCTION IF EXISTS public.get_venue_terms(text, date);
DROP TABLE IF EXISTS public.venue_commercial_terms;

CREATE OR REPLACE FUNCTION public.get_venue_terms(p_venue_group text)
RETURNS public.commercial_agreements
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT * FROM public.commercial_agreements WHERE venue_group = p_venue_group;
$$;
