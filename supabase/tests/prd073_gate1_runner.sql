-- PRD-073 Gate-1 runner: seed reweights from the 02-03/07 weekly driver doc.
-- STAGE 1 (after the reweight_pod_splits migration is applied): run this file as-is.
--   Every call is p_dry_run => true; output rows ARE the Gate-1 current-vs-proposed table.
-- STAGE 2 (after CS approves the Gate-1 table): re-run with p_dry_run => false.
--   The Activia rebuild rows additionally need p_rebuild => true.
--
-- Weight payloads use rec quantities from the doc verbatim; the RPC scales them to 90%
-- and spreads 10% across unrecommended mapped flavors. Name lookups raise if a product
-- name does not resolve; fix names before Stage 2.
--
-- AMBIGUOUS DOC ROWS - excluded pending CS clarification at Gate-1:
--   NOOK "Chocolate Bar Bounty-lean" (no quantities given)
--   NOOK / ALJLT-B1 "VW mix N even" (flavor list = all mapped: use p_weights of all flavors at qty 1? confirm)
--   ALJLT-O1 "Plaay -> milk-choc-heavy", "Zigi mix 6 even" (pod names to confirm)
--   NISSAN "Evian 500ml note" (not a split change)
--   OMDCW/VML-1004/NISSAN McVities pods (pod product name to confirm: 'McVities' variant naming)
--   AMZ-1057 Coke Regular ~5 (single-flavor demotion; needs the pod's full rec set to reweight)
--   AMZ-1038 Loacker Vanilla ->0 (10% floor principle conflicts with 'no vanilla'; CS to rule: keep floor or drop flavor)

\set ON_ERROR_STOP on

-- helper: resolve product ids by name (raises on miss via strict INTO in DO blocks below)
-- VML-1003-0400-O1 (VML4) Chocolate Bar: Bueno 45, M&M 25, Twix 20
SELECT reweight_pod_splits(
  'VML-1003-0400-O1', 'Chocolate Bar',
  jsonb_build_object(
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%kinder bueno%' LIMIT 1), 45,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE 'M&M%' LIMIT 1), 25,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%twix%' LIMIT 1), 20),
  'PRD-073 Gate-1 seed: weekly doc 02-03/07 driver rec (Bueno 5, M&M 3, Twix 2)',
  p_rebuild => false, p_dry_run => true);

-- VML-1004-0500-O1 (VML5) Chocolate Bar: Oreo 30, Bueno 25, Delice 15
SELECT reweight_pod_splits(
  'VML-1004-0500-O1', 'Chocolate Bar',
  jsonb_build_object(
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%oreo%' LIMIT 1), 30,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%kinder bueno%' LIMIT 1), 25,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%delice%' LIMIT 1), 15),
  'PRD-073 Gate-1 seed: weekly doc 02-03/07 driver rec (Oreo-led mix VML5)',
  p_rebuild => false, p_dry_run => true);

-- OMDCW-1021-0100-W0 Chocolate Bar: KitKat 30, Bueno 25, Bounty 25
SELECT reweight_pod_splits(
  'OMDCW-1021-0100-W0', 'Chocolate Bar',
  jsonb_build_object(
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%kitkat%' OR boonz_product_name ILIKE '%kit kat%' LIMIT 1), 30,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%kinder bueno%' LIMIT 1), 25,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%bounty%' LIMIT 1), 25),
  'PRD-073 Gate-1 seed: weekly doc 02-03/07 driver rec (OMDCW KitKat/Bueno/Bounty)',
  p_rebuild => false, p_dry_run => true);

-- ALJLT-1015-0200-O1 Chocolate Bar: KitKat 40, Bounty 20, Bueno 20, Delice 10
SELECT reweight_pod_splits(
  'ALJLT-1015-0200-O1', 'Chocolate Bar',
  jsonb_build_object(
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%kitkat%' OR boonz_product_name ILIKE '%kit kat%' LIMIT 1), 40,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%bounty%' LIMIT 1), 20,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%kinder bueno%' LIMIT 1), 20,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%delice%' LIMIT 1), 10),
  'PRD-073 Gate-1 seed: weekly doc 02-03/07 driver rec (ALJLT office KitKat-led)',
  p_rebuild => false, p_dry_run => true);

-- NISSAN-0804-0000-L0 Chocolate Bar: Delice 4, Oreo 3
SELECT reweight_pod_splits(
  'NISSAN-0804-0000-L0', 'Chocolate Bar',
  jsonb_build_object(
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%delice%' LIMIT 1), 4,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%oreo%' AND boonz_product_name NOT ILIKE '%activia%' LIMIT 1), 3),
  'PRD-073 Gate-1 seed: weekly doc 02-03/07 driver rec (NISSAN Delice/Oreo lean)',
  p_rebuild => false, p_dry_run => true);

-- NISSAN Barebells: Cookies & Cream 45 (dominant rec; others share 10 via formula
-- only if C&C is sole rec -> scale would give C&C 90. Doc says 45: interpret as rec
-- qty; formula puts C&C at 90 with 10 spread. CS to confirm intent at Gate-1.)
SELECT reweight_pod_splits(
  'NISSAN-0804-0000-L0', 'Barebells',
  jsonb_build_object(
    (SELECT product_id FROM boonz_products WHERE boonz_product_name ILIKE '%barebells%cookie%' LIMIT 1), 45),
  'PRD-073 Gate-1 seed: weekly doc 02-03/07 driver rec (Barebells C&C heavy)',
  p_rebuild => false, p_dry_run => true);

-- ACTIVIA CLEAN REBUILD (PRD-073 item 4).
-- NISSAN: Honey 2, Raspberry 2 -> 45/45/10 others. 'Rasberry' (sic) has NO mapping row
-- anywhere today (engine-invisible): p_rebuild=true creates the per-machine mapping.
SELECT reweight_pod_splits(
  'NISSAN-0804-0000-L0', 'Activia Mix & Go',
  jsonb_build_object(
    (SELECT product_id FROM boonz_products WHERE boonz_product_name = 'Activia Mix & Go - Greek Yogurt Honey & Oats'), 2,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name = 'Activia Mix & Go - Greek Yogurt Rasberry'), 2),
  'PRD-073 Activia rebuild: NISSAN rec Honey 2 / Raspberry 2; creates missing Rasberry mapping',
  p_rebuild => true, p_dry_run => true);

-- WH2-1018-0000-W0: the known-broken sum-170 scope (Blueberry 70 + Honey&Oats 50 +
-- Strawberries 50). Rebuild with the same NISSAN-doc seed unless CS overrides.
SELECT reweight_pod_splits(
  'WH2-1018-0000-W0', 'Activia Mix & Go',
  jsonb_build_object(
    (SELECT product_id FROM boonz_products WHERE boonz_product_name = 'Activia Mix & Go - Greek Yogurt Honey & Oats'), 2,
    (SELECT product_id FROM boonz_products WHERE boonz_product_name = 'Activia Mix & Go - Greek Yogurt Rasberry'), 2),
  'PRD-073 Activia rebuild: WH2-1018 splits sum 170 (known-broken since June); rebuild from NISSAN-doc seed',
  p_rebuild => true, p_dry_run => true);
