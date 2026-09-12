-- PRD-121 Phase 2, cleanup item 1: delete two bad product_name_conventions rows.
--
-- 'Plaay Truffle 2pcs' -> 'Plaay Truffles - Mix' and 'Plaay Tablet Chocolate' ->
-- 'Plaay Tablets - Mix' -- both canonical targets have zero sales while the raw names
-- sell (per task). Verified live: exactly these two rows exist by (original_name,
-- official_name); a third, unrelated row ('Plaay Cylinder' -> 'Plaay Truffles - Mix') is
-- left untouched -- it is not one of the two named for removal.
--
-- product_name_conventions is a plain reference/lookup table -- no canonical writer RPC
-- exists for it (grepped pg_proc: every hit is a reader -- get_product_velocity_ledger,
-- get_dashboard_sales, etc.), so a direct DELETE is the correct write path, not a new RPC
-- for a one-time data correction.
--
-- Cody: fast-path approve (data cleanup on a non-protected reference table, no DDL, no new
-- write path).

DELETE FROM public.product_name_conventions
WHERE (original_name, official_name) IN (
  ('Plaay Tablet Chocolate', 'Plaay Tablets - Mix'),
  ('Plaay Truffle 2pcs', 'Plaay Truffles - Mix')
);
