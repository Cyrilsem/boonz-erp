-- PRD-110 P1.3 · golden fixture 24 assertions (34). Additive: golden.assertions only.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
-- ---- preconditions (seq 1 doubles as a D-04 tripwire against re-topping the sentinels) ----
(24, 1, 'PRECONDITION: sentinel population is exactly 40 rows (a change means someone re-topped or minted - re-baseline)',
 $q$SELECT (value->>'sent_rows') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'$q$, 'eq', '40', true, 'P1'),
(24, 2, 'PRECONDITION: all 40 sentinels start Active',
 $q$SELECT (value->>'sent_active') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'$q$, 'eq', '40', true, 'P1'),
(24, 3, 'PRECONDITION: sentinels hold phantom stock, so the drain is a real mutation',
 $q$SELECT (value->>'sent_units') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'$q$, 'gt', '0', true, 'P1'),
(24, 4, 'PRECONDITION: all 40 sentinels are pickable before retirement (they DO prop availability up today)',
 $q$SELECT (value->>'pickable_sent') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'$q$, 'eq', '40', true, 'P1'),
(24, 5, 'PRECONDITION: 61 shelves are sentinel-backed before retirement',
 $q$SELECT (value->>'sentinel_backed') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'$q$, 'eq', '61', true, 'P1'),

-- ---- the headline: SOA reproduces to the cent with all 40 sentinels retired ----
(24, 6, 'SOA baseline before retirement equals registry row BNZ/MAFE/2026-06/001 to the cent',
 $q$SELECT (value->>'soa_before') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '101181.71', true, 'P1'),
(24, 7, 'SOA WITH ALL 40 SENTINELS RETIRED still equals BNZ/MAFE/2026-06/001 to the cent',
 $q$SELECT (value->>'soa_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '101181.71', true, 'P1'),
(24, 8, 'SOA delta across the retirement is exactly zero',
 $q$SELECT ((value->>'soa_after')::numeric - (value->>'soa_before')::numeric)::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', true, 'P1'),
(24, 9, 'SOA registry row is still the frozen comparator (guards against the fixture drifting with the registry)',
 $q$SELECT total_sales::text FROM public.statement_of_account_registry WHERE soa_number='BNZ/MAFE/2026-06/001'$q$, 'eq', '101181.71', true, 'P1'),

-- ---- structural proof: stronger than the behavioural one, holds for EVERY month ----
(24, 10, 'STRUCTURAL: get_vox_consumer_report does not reference warehouse_inventory at all',
 $q$SELECT position('warehouse_inventory' in pg_get_functiondef('public.get_vox_consumer_report(text[],boolean,date,date,uuid)'::regprocedure))::text$q$, 'eq', '0', true, 'P1'),
(24, 11, 'STRUCTURAL: the revenue-object scan is broad enough to be evidence (>= 25 objects examined)',
 $q$SELECT count(*)::text FROM (SELECT p.proname n FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.prokind='f' AND p.proname ~ 'soa|consumer_report|settlement|statement|revenue|sales|invoice|billing|payout|adyen|cash_recovery|vox' UNION ALL SELECT c.relname FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('v','m') AND c.relname ~ 'soa|consumer_report|settlement|statement|revenue|sales|invoice|billing|payout|adyen|cash_recovery|vox') q$q$, 'gte', '25', true, 'P1'),
(24, 12, 'STRUCTURAL: zero revenue-shaped objects read warehouse_inventory, so no month can regress',
 $q$SELECT count(*)::text FROM (SELECT pg_get_functiondef(p.oid) d FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.prokind='f' AND p.proname ~ 'soa|consumer_report|settlement|statement|revenue|sales|invoice|billing|payout|adyen|cash_recovery|vox' UNION ALL SELECT pg_get_viewdef(c.oid, true) FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('v','m') AND c.relname ~ 'soa|consumer_report|settlement|statement|revenue|sales|invoice|billing|payout|adyen|cash_recovery|vox') q WHERE q.d LIKE '%warehouse_inventory%'$q$, 'eq', '0', true, 'P1'),

-- ---- the retirement actually happened ----
(24, 13, 'All 40 sentinels were drained through the canonical writer',
 $q$SELECT (value->>'drained') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '40', true, 'P1'),
(24, 14, 'Zero sentinel units remain after retirement',
 $q$SELECT (value->>'sent_units_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', true, 'P1'),
(24, 15, 'The zero-stock trigger flipped all 40 rows to Inactive without a raw UPDATE from this fixture (Article 6)',
 $q$SELECT (value->>'sent_inactive_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '40', true, 'P1'),
(24, 16, 'No sentinel remains Active after retirement',
 $q$SELECT (value->>'sent_active_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', true, 'P1'),
(24, 17, 'No sentinel is pickable after retirement (they left v_wh_pickable, which is what availability reads)',
 $q$SELECT (value->>'pickable_sent_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', true, 'P1'),
(24, 18, 'The drain wrote one auto-confirmed status proposal per row (40), so the flip is provenanced',
 $q$SELECT ((SELECT (value->>'proposals_after')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs') - (SELECT (value->>'proposals')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$, 'eq', '40', true, 'P1'),

-- ---- nothing the engine plans on changed: the load-bearing invariant ----
(24, 19, 'INVARIANT: the per-shelf available_units fingerprint is byte-identical after retiring all 40 sentinels',
 $q$SELECT ((SELECT value->>'avail_fp_after' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs') = (SELECT value->>'avail_fp' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$, 'eq', 'true', true, 'P1'),
(24, 20, 'No shelf disappeared from the availability contract',
 $q$SELECT ((SELECT (value->>'avail_rows_after')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs') = (SELECT (value->>'avail_rows')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$, 'eq', 'true', true, 'P1'),
(24, 21, 'would_block_on_retirement is 0 AFTER the retirement, not merely predicted 0 before it',
 $q$SELECT (value->>'would_block_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', true, 'P1'),
(24, 22, 'Venue/partner shelves keep available_units IS NULL (unconstrained), never coalesced to 0',
 $q$SELECT (value->>'venue_notnull_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', true, 'P1'),
(24, 23, 'Sentinel-backing drops 61 -> 0, proving the 61 shelves were measured, not assumed',
 $q$SELECT (value->>'sentinel_backed_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', true, 'P1'),

-- ---- the two spec corrections, proven live rather than asserted from a count ----
(24, 24, 'SPEC CORRECTION 1: the BUILD SPEC DELETE aborts on the inventory_audit_log FK',
 $q$SELECT (value->>'err_delete') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'contains', 'inventory_audit_log', true, 'P1'),
(24, 25, 'SPEC CORRECTION 1: 255 audit rows are why it aborts (drops to 0 only if history is destroyed)',
 $q$SELECT (value->>'audit_sent') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'$q$, 'eq', '255', true, 'P1'),
(24, 26, 'SPEC CORRECTION 2a: inactivate_warehouse_row refuses a stocked sentinel, so it cannot be the retirement writer',
 $q$SELECT (value->>'err_stocked') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'contains', 'stock > 0', true, 'P1'),
(24, 27, 'SPEC CORRECTION 2b: after the drain the trigger already inactivated the row, so the writer refuses again',
 $q$SELECT (value->>'err_inact') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'contains', 'already in status Inactive', true, 'P1'),
(24, 28, 'FAIL LOUD (Cody, leg 11): the protected-entity DELETE must NEVER succeed, whatever the error text says',
 $q$SELECT (value->>'err_delete') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'ne', 'SUCCEEDED', true, 'P1'),

-- ---- S-08 tripwire + residue (Cody standing requirement: the rollback is asserted, never assumed) ----
(24, 90, 'S-08 tripwire: open driver_feedback count unchanged by the fixture',
 $q$SELECT ((SELECT count(*) FROM public.driver_feedback WHERE resolved=false) = (SELECT (value->>'df_open')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$, 'eq', 'true', true, 'P1'),
(24, 95, 'RESIDUE: all 40 sentinels are Active again after rollback',
 $q$SELECT count(*)::text FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND wi.status='Active'$q$, 'eq', '40', true, 'P1'),
(24, 96, 'RESIDUE: sentinel unit total restored exactly (no phantom stock lost or gained)',
 $q$SELECT ((SELECT COALESCE(sum(wi.warehouse_stock),0) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)) = (SELECT (value->>'sent_units')::numeric FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$, 'eq', 'true', true, 'P1'),
(24, 97, 'RESIDUE: inventory_audit_log row count unchanged (the 40 drains left no trace)',
 $q$SELECT ((SELECT count(*) FROM public.inventory_audit_log) = (SELECT (value->>'audit_total')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$, 'eq', 'true', true, 'P1'),
(24, 98, 'RESIDUE: warehouse_inventory_status_proposal row count unchanged (the 40 auto-proposals rolled back)',
 $q$SELECT ((SELECT count(*) FROM public.warehouse_inventory_status_proposal) = (SELECT (value->>'proposals')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$, 'eq', 'true', true, 'P1'),
(24, 99, 'RESIDUE: v_shelf_availability_v3 fingerprint matches the pre-fixture baseline (live state untouched)',
 $q$SELECT ((SELECT md5(string_agg(a.shelf_id::text||':'||COALESCE(a.available_units::text,'NULL'), ',' ORDER BY a.shelf_id)) FROM public.v_shelf_availability_v3 a) = (SELECT value->>'avail_fp' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$q$, 'eq', 'true', true, 'P1');
