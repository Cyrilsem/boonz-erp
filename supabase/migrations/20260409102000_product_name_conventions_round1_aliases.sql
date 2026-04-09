-- Phase 0 R1 follow-up: alias unmatched Weimi goods names to existing pod_products.
-- No unique constraint on original_name (PK only) — plain ON CONFLICT DO NOTHING is safe.
--
-- 'Chewing Gum ' (trailing space) → Extra Gum (PD014, 5b7075fe-...)
-- 'Chewing Gum'  (trimmed)        → Extra Gum  — belt-and-suspenders for when Weimi fixes the space
-- 'Eviron Wellness'               → Eviron Health Drink (PD126, b013fc2d-...)
--
-- After this insert, v_live_shelf_stock tier-3 match resolves these automatically on next query.
-- Remaining unmatched ("Product for testing only") is intentionally unmapped — test-only machine.
INSERT INTO public.product_name_conventions (original_name, official_name, mapped_at)
VALUES
  ('Chewing Gum ', 'Extra Gum',             CURRENT_DATE),
  ('Chewing Gum',  'Extra Gum',             CURRENT_DATE),
  ('Eviron Wellness', 'Eviron Health Drink', CURRENT_DATE)
ON CONFLICT DO NOTHING;
