-- MIRROR of prod state as of 2026-07-15 (do NOT re-apply; idempotent).
-- commercial_agreements never had a repo migration; this reproduces the full table + the
-- 2026-07-15 model columns + RLS + get_venue_terms. venue_commercial_terms was created and
-- DROPPED the same day (duplicate) - intentionally NOT recreated here.
CREATE TABLE IF NOT EXISTS public.commercial_agreements (
  agreement_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_group    text NOT NULL UNIQUE,
  agreement_type text NOT NULL,
  partner_name   text,
  boonz_share_pct   numeric NOT NULL DEFAULT 1.0000,
  partner_share_pct numeric NOT NULL DEFAULT 0.0000,
  notes          text,
  effective_date date NOT NULL DEFAULT CURRENT_DATE,
  created_at     timestamptz DEFAULT now()
);

-- 2026-07-15 model columns (added nullable here; backfilled in the data migration; NOT NULL set after)
ALTER TABLE public.commercial_agreements
  ADD COLUMN IF NOT EXISTS source_of_supply          text,
  ADD COLUMN IF NOT EXISTS boonz_bears_cogs          boolean,
  ADD COLUMN IF NOT EXISTS cogs_recovered_from_venue boolean,
  ADD COLUMN IF NOT EXISTS boonz_refills             boolean,
  ADD COLUMN IF NOT EXISTS adyen_pct                 numeric,
  ADD COLUMN IF NOT EXISTS adyen_fixed_aed           numeric,
  ADD COLUMN IF NOT EXISTS updated_at                timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.commercial_agreements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS commercial_agreements_select ON public.commercial_agreements;
CREATE POLICY commercial_agreements_select ON public.commercial_agreements FOR SELECT
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = (SELECT auth.uid())
                 AND user_profiles.role = ANY (ARRAY['operator_admin','superadmin','manager'])));
DROP POLICY IF EXISTS commercial_agreements_write ON public.commercial_agreements;
CREATE POLICY commercial_agreements_write ON public.commercial_agreements FOR ALL
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = (SELECT auth.uid())
                 AND user_profiles.role = ANY (ARRAY['operator_admin','superadmin'])))
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.id = (SELECT auth.uid())
                 AND user_profiles.role = ANY (ARRAY['operator_admin','superadmin'])));

CREATE OR REPLACE FUNCTION public.get_venue_terms(p_venue_group text)
RETURNS commercial_agreements
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT * FROM public.commercial_agreements WHERE venue_group = p_venue_group;
$function$;
