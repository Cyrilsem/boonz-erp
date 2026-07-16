-- PRD-CLEAN-12 M1 (DDL): the partner business model as data, not code.
-- VOX terms are currently hardcoded in ~25 functions (v_boonz_pct := 0.20 etc).
-- LevelUp is the second model (25% of net, zero COGS, venue-sourced, no refill).
-- Partner #3 should be a row, not a code change.

CREATE TABLE IF NOT EXISTS public.venue_commercial_terms (
  venue_group_code   text        NOT NULL REFERENCES public.venue_groups(code),
  effective_from     date        NOT NULL DEFAULT CURRENT_DATE,
  effective_to       date,

  -- revenue split (of the settlement basis, after Adyen fees when basis = net_revenue)
  boonz_share_pct    numeric     NOT NULL CHECK (boonz_share_pct >= 0 AND boonz_share_pct <= 1),
  venue_share_pct    numeric     GENERATED ALWAYS AS (1 - boonz_share_pct) STORED,
  settlement_basis   text        NOT NULL DEFAULT 'net_revenue'
                                 CHECK (settlement_basis IN ('net_revenue','gross_revenue')),

  -- who buys the goods, and whether COGS is recovered from the venue's dues
  source_of_supply   text        NOT NULL CHECK (source_of_supply IN ('boonz','venue_team')),
  boonz_bears_cogs   boolean     NOT NULL,
  cogs_recovered_from_venue boolean NOT NULL DEFAULT false,

  -- does Boonz operate replenishment for this group?
  boonz_refills      boolean     NOT NULL DEFAULT true,

  -- payment processing
  adyen_pct          numeric     NOT NULL DEFAULT 0.026,
  adyen_fixed_aed    numeric     NOT NULL DEFAULT 0.50,

  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (venue_group_code, effective_from),
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  -- COGS can only be recovered from the venue if Boonz actually bore it
  CHECK (NOT cogs_recovered_from_venue OR boonz_bears_cogs),
  -- if the venue sources everything, Boonz cannot bear COGS
  CHECK (source_of_supply <> 'venue_team' OR NOT boonz_bears_cogs)
);

COMMENT ON TABLE public.venue_commercial_terms IS
'Canonical commercial model per venue group, temporal via effective_from/effective_to. Replaces hardcoded percentages in the VOX report functions. Read via get_venue_terms(code, as_of).';

-- No overlapping term windows per venue group
CREATE UNIQUE INDEX IF NOT EXISTS venue_commercial_terms_open_window
  ON public.venue_commercial_terms (venue_group_code) WHERE effective_to IS NULL;

CREATE OR REPLACE FUNCTION public.get_venue_terms(p_venue_group_code text, p_as_of date DEFAULT CURRENT_DATE)
RETURNS public.venue_commercial_terms
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT * FROM public.venue_commercial_terms
   WHERE venue_group_code = p_venue_group_code
     AND effective_from <= p_as_of
     AND (effective_to IS NULL OR effective_to > p_as_of)
   ORDER BY effective_from DESC
   LIMIT 1;
$$;
