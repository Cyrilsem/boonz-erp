-- PRD-118 item I: pack screen nets batch commitments against actual pins.
-- Reconstructed from live prod introspection (applied 2026-08-31 as two migrations,
-- schema_migrations versions 20260831041646 + 20260831041717; combined here into one
-- file since the incremental diff between the two was not preserved outside prod).
--
-- v_dispatch_open_wh_commitment (PRD-110 D-28 canonical "which lines count as an open
-- warehouse claim") gains two additive columns so a consumer can net commitment at
-- BATCH grain (from_wh_inventory_id) instead of product grain, and can see the PRD-053
-- driver_confirmed_breakdown a line may already carry. Shape/predicate unchanged —
-- same 7-clause WHERE, same base columns; this is exposure only, not a redefinition.
-- Fixed the 3-machine Sunbites packing deadlock (batches showing "no stock" on-screen
-- while a sibling batch of the same product had committed units elsewhere).
CREATE OR REPLACE VIEW public.v_dispatch_open_wh_commitment AS
 SELECT dispatch_id,
    machine_id,
    boonz_product_id,
    dispatch_date,
    quantity,
    from_wh_inventory_id,
    shelf_id,
    driver_confirmed_breakdown
   FROM refill_dispatching rd
  WHERE (action = ANY (ARRAY['Refill'::text, 'Add New'::text]))
    AND packed = false
    AND picked_up = false
    AND source_origin = 'warehouse'::source_origin_enum
    AND COALESCE(cancelled, false) = false
    AND COALESCE(skipped, false) = false
    AND COALESCE(pack_outcome::text, ''::text) <> 'not_filled'::text;
