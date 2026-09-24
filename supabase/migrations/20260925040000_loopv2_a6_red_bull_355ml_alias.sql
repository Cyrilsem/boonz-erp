-- Loop 2026-09-25 A6 (G5, data): Red bull 355ML mapping and WEIMI unmatched sweep.
--
-- Investigated before writing anything, per the loop's own discipline of confirming root cause
-- against live data rather than assuming the task brief's premise:
--
-- 1. A generic pod product "Red Bull" (a602c923-c4c0-4ecc-b5f7-3c13a1960beb) already exists.
-- 2. boonz_products already has "Red Bull - 355ML" (e21bae75-cdeb-42a9-b6ad-df8f5d4166dc), with an
--    Active, machine-scoped product_mapping row to that same generic pod product, for machine_id
--    f1a528fb-15e8-4f20-b4e2-ebb2e6852198 (AMZ-1029-3003-O1), the exact machine named in the
--    sku_intents evidence.
-- 3. pod_inventory history for AMZ-1029-3003-O1 shelf A14 (05916907-569d-44ae-a0dc-7e4f17ab9768)
--    shows THREE different boonz_product variants have occupied that lane over time (Red Bull -
--    Diet, Red Bull - Regular, Red Bull - 355ML), all correctly sharing the one generic "Red Bull"
--    pod product. That is the intended model: pod identity is the physical can, boonz_product_id
--    is the SKU/flavour variant sold from it.
-- 4. v_shelf_slot_identity already resolves this exact shelf's raw WEIMI string
--    ("Red bull 355ML") to pod_product_id a602c923 via match_method = 'conventions' (a fuzzy
--    matcher), not 'unmatched'.
--
-- Conclusion: creating a NEW, separate pod product literally named "Red bull 355ML" would
-- fragment an identity that is already correct and already shared correctly across three real
-- SKU variants on this shelf's history. That is not "the correct boonz product" mapping the task
-- asked for; it is the wrong fix for what is actually a fuzzy-match-only resolution, not a missing
-- mapping. No new pod product is created and no product_mapping changes; the existing Active
-- mapping (boonz "Red Bull - 355ML" to pod "Red Bull", machine-scoped to AMZ-1029-3003-O1) is
-- already correct and untouched.
--
-- What this migration does instead: adds an explicit weimi_product_alias row so this shelf's
-- resolution stops depending on the fuzzy 'conventions' matcher and becomes a first-class,
-- explicit mapping like any other aliased WEIMI string.
--
-- WEIMI unmatched sweep (match_method = 'unmatched' in v_shelf_slot_identity), all other findings
-- left unfixed per "fix only exact, unambiguous ones", written to STATE.md:
--   - "C4 Energy Drink" (LVLUP-1018-0000-G0 A05, LVLUP-1048-0000-P0 A09): no C4 pod product exists
--     at all; LVLUP machines are excluded from planning entirely per this loop's hard rules, so
--     even if mapped, no plan would touch them. Not fixed, not unambiguous.
--   - "Plaay Cylinder" (WH1-2002-0000-W0, three shelves): several existing Plaay pod products
--     (Truffle 2pcs, Tablet Chocolate, Tablet Chocolate 35g) but none named or shaped like a
--     "Cylinder" format. Ambiguous, not fixed.
--   - "Product for testing only" (WH1-2002-0000-W0, two shelves, stock 0): a test fixture, not a
--     real product. Correctly left unmapped.

SELECT set_config('app.mutation_reason',
  'loopv2 A6: add weimi_product_alias Red bull 355ML -> pod_product Red Bull (a602c923...), '
  || 'direct reference-table insert, no canonical writer RPC exists for this table', true);

INSERT INTO public.weimi_product_alias (weimi_name, pod_product_id, note)
VALUES (
  'Red bull 355ML',
  'a602c923-c4c0-4ecc-b5f7-3c13a1960beb',
  'Loop 2026-09-25 A6: explicit alias for AMZ-1029-3003-O1 A14, previously resolved only via the '
  || 'fuzzy conventions matcher in v_shelf_slot_identity. Confirmed correct against pod_inventory '
  || 'history (Red Bull Diet, Regular, and 355ML boonz variants have all occupied this shelf, all '
  || 'correctly sharing this one pod product). by=system, plan_date n/a (reference-table fix, no '
  || 'plan_date scope)'
)
ON CONFLICT (weimi_name, pod_product_id) DO NOTHING;
