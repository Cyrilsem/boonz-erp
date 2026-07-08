-- PRD-093 Part A (Cody fast-path: additive columns on non-protected boonz_products).
-- Foundation for the consignment model: additive, default false/null => fully inert.
-- Lets CS tag venue-sourced SKUs. ENGINE gating (skip wh_avail for consignment, behind
-- consignment_v1) is PART B, PARKED (engine-internal blocked_no_wh region; needs an engine-ADD
-- fixture to validate + a pod_product->boonz consignment mapping). diff_vs_golden IDENTICAL.
ALTER TABLE public.boonz_products ADD COLUMN IF NOT EXISTS is_consignment boolean NOT NULL DEFAULT false;
ALTER TABLE public.boonz_products ADD COLUMN IF NOT EXISTS consignment_venue_id uuid;
INSERT INTO refill_qa.feature_flag(flag,value) VALUES ('consignment_v1','off') ON CONFLICT (flag) DO NOTHING;
COMMENT ON COLUMN public.boonz_products.is_consignment IS 'PRD-093: venue-sourced SKU (no WH draw). Additive/inert until consignment_v1 engine gating ships (Part B parked).';
