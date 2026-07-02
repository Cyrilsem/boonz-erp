# /goal — PRD-020 (paste into Claude Code, repo root)

```
/goal Execute docs/prds/PRD-020-jun08-09-refills-and-0506-closeout.md on Supabase eizcexopcuoycuosittm. Two parts: (A) close 05-06 Jun leftovers with Simran's corrected dates; (B) 08/06+09/06 round. Cody before any canonical-writer/view/trigger change; verbatim bodies. DO NOT redo 01-06 Jun green rows (PRD-017/018/019).

DRIVER-REC POLICY (CS): driver "recommendation" = REQUEST for next refill → driver_recommendations (signal for next engine run), NEVER a completed refill. Only "log the flow" + Part-A lines are real placements.

PART A — log these 6 corrected lines on their ORIGINAL visit date (dedup makes re-log safe). AMZ-1029+NOOK=2026-06-05; Vox=2026-06-06 vox_at_venue. Via log_retroactive_refill_visit:
- AMZ-1029-3003-O1 A10 Hunter - Sea Salt & Cider Vinegar 1 @2027-02-01
- AMZ-1029 A11 Dubai Popcorn Salted 3 @2027-02-17
- AMZ-1029 A16 Vitamin Well - Reload 2 @2026-08-30
- NOOK-1019-0200-B1 A15 Eviron - Wellness Drink 4 @2027-04-29 + G&H Popped Protein - Salt & Black Pepper 3 @2026-08-26
- VOXMCC-1011-0101-B0 (Vox 0795) Vitamin Well - Care 2 @2026-09-06
- VOXMCC-1005-0201-B0 (Vox 0797) Vitamin Well - Care 2 @2026-09-06
KEEP PARKED: AMZ-1029 A6 Smart Gourmet Classic Humus +2 (product N/A). CLOSE/resolve action_tracker: Mirdif list note + the 3 date-fix rows + NOOK qty row (mark resolved once logged).

PART B1 — log the flow:
- AMZ-1068-2401-O1 (dev 0705) date 2026-06-08: REMOVE 1 Sabahoo @2026-06-15 via insert_driver_remove_line; resolve Sabahoo variant on-shelf via v_live_shelf_stock (match exp 2026-06-15).
- OMDBB-1020-0P00-O1 (0809) 2026-06-08: Refill Vitamin Well - Antioxidant 1 @2026-08-30.
- ALJLT-1015-0200-O1 (dev 0799 ACTIVE; 1014 Inactive) 2026-06-09 via log_retroactive_refill_visit: Hunter Ridge - Himalayan Pink Salt 2 @2027-02-03; Hunter - Sea Salt & Cider Vinegar 2 @2027-02-01; Hunter Hot Chili 2 @2027-02-19; Dubai Popcorn Butter 1 @2027-02-01 AND Butter 1 @2027-02-07 (KEEP as two separate-expiry batches, do not merge); Dubai Popcorn Salted 2 @2027-03-01.

PART B2 — OMDBB-1020: VW Antioxidant shows in packing but pick-up qty not displayed → log ONE action_tracker row type=bug (packing-FE pickup-qty gap). No data change.

PART B3 — driver_recommendations (signals, NOT refills). resolve via docs/refill-aliases.md; mixes=multi-variant even split flag:
- AMZ-1029 (0745): Kinder Bueno 5, Snickers 5, KitKat 5, Smart Gourmet Classic Humus 3
- ADDMIND-1007-0000-W0 (0791): KitKat 6, Kinder Delice 5
- OMDBB-1020 (0809): McVities Mini (Milk+Dark even split), qty_unspecified flag
- ALJLT-1015 (0799): Barebells mix 15 (even split), KitKat 10, Kinder Delice 3, Ice Tea - Peach 6, Bounty 4
- WPP-1002-4300-O1 (0793): Be-Kind Cluster mix 5 (even split), Oreo 3
- WAVEMAKER-1006-4100-O1 (0792): KitKat 5, Mars 4, Snickers 3, McVities Dark 3, McVities Milk 3
- MINDSHARE-1009-4500-O1 (0807): Kinder Delice 3, McVities Dark 4, McVities Milk 4, Kinder Bueno 3
- HUAWEI-2003-0000-B1 (0819): KitKat 6, Kinder Delice 4, McVities Dark 4, McVities Milk 4, Oreo 3, Tamreem Date Ball mix 6 (Coconut+Sesame even split), Vitamin Well mix 8 (even split), Mars 4
- MC-2004-0100-O1 (0815): YoPRO mix 6 (even split)
ALIASES (rest in PRD §Resolution): Himalayan pink salt→Hunter Ridge - Himalayan Pink Salt (NOT Soul Pantry); iced tea peach→Ice Tea - Peach; Eviron Wellness→Eviron - Wellness Drink; G&H Popped→G&H Popped Protein - Salt & Black Pepper; delice→Kinder Delice; Bueno→Kinder Bueno; hummus→Smart Gourmet - Classic Humus; mcvities→McVities Digestive Mini (Snack Bar shelf).

CONSTRAINTS (full set in PRD §Constraints, all in force): service-role bypass pattern; RPC-only writes + allow-list + block_orphan_internal_transfer + tg_audit_refill_dispatching; log_retroactive_refill_visit=Refill/Add New only, Removes via insert_driver_remove_line; warehouse_inventory.status manager-only; never guess catalog gaps. Verify writes in rolled-back tx; update RPC_REGISTRY.md + CHANGELOG.md + PRD-020 status. BUG-D (PRD-018) NOT in scope.
```
