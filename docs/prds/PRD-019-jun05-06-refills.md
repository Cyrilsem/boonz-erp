# PRD-019 — 05-06 Jun refills (+ Nissan supersede, WH note)

**Owner:** Claude Code · **Created:** 2026-06-07 · Supabase `eizcexopcuoycuosittm`
**Format:** engineering build-spec (PRD-016/017/018 discipline). Data-logging round + 2 side-notes. Carry all §constraints.
Already logged — DO NOT redo: 01-02 Jun (PRD-017 §0), 03-04 Jun (PRD-018). This PRD = **05/06 + 06/06 only**.

## Reconciliation guards (read first)

- **NISSAN-0804** — CS decision: the 04/06 log (14 rows / 45u, `[RETRO-LOG ...04` dated 2026-06-04) and the 05/06 doc list are the **SAME visit, completed**. SUPERSEDE: void the 14 existing 04/06 Nissan retro rows (`set_dispatch_include(dispatch_id,false)` + comment `[SUPERSEDED by 05/06 full log]`; add the service-role bypass to `set_dispatch_include` if it lacks one, same pattern as update_dispatch_comment), THEN log the full 05/06 Nissan list at date 2026-06-05. Net: one complete record, no double-count.
- **AMZ-1038 / AMZ-1029** — prior logs are on other dates (22/05, 01/06, 03/06); the 05/06 full refills are DISTINCT → log at 2026-06-05. (AMZ-1038 A8 Snack Bar KitKat/McVities may overlap the 03/06 Organic-Rice→KitKat note; log-first, dedup keys on date so no auto-collision — fine.)
- **NOOK-1019-0200-B1** — new, no prior logs.

## Resolution + logging rules (deterministic)

- Resolve each shorthand → `boonz_products.product_id` + `product_mapping` per machine (docs/refill-aliases.md). Pod is WEIMI-fed → LOG-FIRST (`log_retroactive_refill_visit`, Refill/Add New; WH not debited). Removes (swaps) via `insert_driver_remove_line`. Combine same product+date+machine (sum qty, earliest expiry, batches in comment). Multi-variant mix pods keep their split.
- Genuine catalog gaps → park + procurement (do not guess). Past-dated expiries (e.g. any 2026-02 already past) → skip.
- Aliases this round: "Gatorade Cool Raspberry"→Gatorade Cool - Blue Raspberry; "Gatorade Zero"→Gatorade Zero - Cool Blue; "poppit"→Popit; "Evain"→Evian; "Al Ain Zero"→Al Ain Water Zero (confirm variant, else Al Ain Water - Regular + park); "Environ Wellness"→Eviron - Wellness Drink; "Hummus"→Smart Gourmet - Classic Humus.

---

## PART 1 — 05/06 placements (date 2026-06-05)

**NISSAN-0804-0000-L0** (after supersede): YoPRO Choc 4 (01/09/26), Vanilla 3 (27/08/26)+1 (19/08/26), Strawberry 2 (21/08/26)+1 (31/08/26); Barebells Caramel Cashew 7 (17/11/26), Hazelnut Nougat 8 (22/12/26), Salty Peanut 3 (26/11/26); Krambals Green Olives 2 (13/11/26), Tomato 2 (14/09/26), Forest Mushroom 2 (16/01/27); Be-kind Cluster PB 3 (13/10/26)+1 (18/08/26), Dark 1 (12/10/26)+1 (17/08/26), Hazelnut 1 (19/08/26); Smart Gourmet Classic 1 (25/01/27); Chocolate Bar — Snickers 2 (06/11/26), Mars 2 (01/12/26), Bounty 2 (04/12/26), Twix 2 (22/03/27), Kinder Bueno 2 (19/11/26); Snack Bar — KitKat 2 (28/02/27 — doc says 28/02/26, treat as 2027 typo/confirm), McVities Mini Milk 3 (29/10/26), McVities Dark 3 (11/12/26), Kinder Delice 2 (17/07/26); Nibbles Milk 2 (06/09/26), Dark 1 (09/08/26), Double 3 (13/08/26), Choco Caramel 1 (12/08/26); Evian 10 (13/10/27); VW Upgrade (02/08/26), VW Reload (23/08/26) [qty as stated/confirm].

**AMZ-1029-3003-O1** (56u + swaps): A1 **Zigi→Sunbites swap** (Remove Zigi; Add Sunbites Cheese 4 @14/09/26 + Sunbites Olives&Oregano 4 @11/09/26); A2 Barebells +2 → Caramel Cashew 1 (17/11/26), Hazelnut Nougat 1 (22/12/26), White Almond Choc 3 (03/12/26), Salty Peanut 3 (04/01/27); A3 Loacker +4 → Vanille 1 (15/05/27), Creamkakao 2 (03/03/27), Napolitaner 1 (04/03/27); A5 Activia → Honey&Oats 2 (14/06/26), Strawberry 1 (07/07/26); A6 Hummus +2 = **N/A (park, procurement)**; A9 Krambals +6 → Green Olives 1 (13/11/26)+1 (10/07/26), Tomato 3 (20/01/27); A10 Hunter +3 → Black Truffle 1 (09/12/26), Sea Salted 1 (01/02/27)+1 (24/02/27), Hot Chili 2 (19/02/27), Sea Salt Vinegar 1 (01/02/26 PAST→skip); A11 Dubai Popcorn +4 → Butter 2 (01/02/27)+1 (29/12/26), Salted 3 (17/02/26 PAST→confirm); A12 Soft Drinks +2 → Coca Cola Zero 1 (26/10/26), Pepsi Black 1 (15/11/26); A13 Coca Cola +15 → Zero 6 (04/10/26)+6 (18/10/26)+3 (03/11/26); A14 Red Bull +4 → Diet 2 (04/12/26), Regular 2 (04/11/27); A15 Al Ain Zero +6 (24/04/27); A16 VW +8 → Peach 2 (27/09/26), Antioxidant 2 (30/08/26), Reload 2 (30/02/26 INVALID date→confirm), Well Care 2 (06/09/26).

**AMZ-1038-3001-O1** (36u + swaps): A1 **Zigi (remove 3)→McVities Nibbles** (Remove 3 Zigi; Add Choco Caramel 3 @24/11/26, White Choc 2 @08/10/26, Milk 1 @18/11/26 +1 @06/09/26, Dark 1 @03/11/26); A2 Krambals +2 → Forest Mushroom 1 (16/01/27), Tomato 1 (20/01/27), Green Olives 1 (13/11/26); A3 Loacker +1 → Creamkakao 1 (03/03/27); A8 Snack Bar +12 → Oreo 7 (05/11/26), McVities Milk 7 (29/10/26), McVities Dark 7 (11/12/26); A9 Sunbites +1 → Cheese 1 (14/09/26); A11 Dubai Popcorn +3 → Butter 2 (01/02/27), Salted 1 (01/02/27)+2 (01/03/27); A12 Soft Drinks +6 → Coca Cola Regular 2 (27/01/27), Pepsi Black 2 (15/11/26), Pepsi Regular 2 (01/02/27); A13 Coca Cola +2 → Zero (03/11/26); A14 Red Bull +1 → Diet (04/12/26); A15 Al Ain Zero +8 (24/04/27); A16 VW → Well Care 2 (06/09/26), Peach 2 (27/09/26), Antioxidant 2 (30/08/26).

**NOOK-1019-0200-B1** (42u): A9 Choc Bar +10 → Snickers 3 (06/11/26), Mars 3 (01/12/26), Bounty 2 (04/12/26), Kinder Bueno 2 (19/11/26); A10 Barebells +9 → Caramel Cashew 7 (17/11/26), Hazelnut Nougat 2 (22/12/26); A11 Snack Bar +7 → Twix 3 (22/02/27), KitKat 3 (28/02/27), McVities Mini Milk 2 (29/10/26), McVities Dark 2 (11/12/26); A15 Al Ain Zero +15 (22/05/27) + Jojo adds: G&H Popped Protein Chips (26/08/26), Krambals Tomato 2 (20/01/26→confirm 2027), Green Olives 1 (13/11/26), Eviron Wellness (29/04/27); A16 VW → Peach 2 (27/09/26), Well Care 1 (06/09/26), Antioxidant 1 (30/08/26).

## PART 1 — 06/06 placements (date 2026-06-06)

- **Activate 0736 (ACTIVATEMCC-1037):** Evian 24 (13/11/27).
- **Activate 0817 (ACTIVATE-2005):** Gatorade Cool Raspberry 2 (05/01/27)+2 (19/01/27)+1 (01/03/27), Gatorade Zero 1 (07/02/27), Popit Lemon 4 (10/11/27), Popit Cola 1 (17/10/26), Pocari 9 (22/01/27). [vox_at_venue]
- **IFLY (IFLYMCC-1024):** Leibniz Cocoa 4 (03/09/26), Leibniz Milk&Honey 3 (20/01/27), Sun Blast Apple 5 (16/02/27). [vox_at_venue]
- **Vox 0795 (VOXMCC-1011):** VW Well Care 2 (06/06/26 PAST→confirm), Antioxidant 2 (30/08/26), Reload 4 (30/08/26), Peach 2 (27/09/26). [vox_at_venue]
- **MP 0719 (MPMCC-1054):** Haribo 8 (26/01/27), Popit Cola 5 (17/10/26), Popit Lemon 2 (10/11/27). [vox_at_venue]
- **Vox 0797 (VOXMCC-1005):** VW Antioxidant 2 (30/08/26), Peach 2 (27/09/26), Well Care 2 (06/06/26 PAST→confirm), Reload 3 (30/08/26), Leibniz Cocoa 2 (03/09/26), Leibniz Milk&Honey 2 (20/01/27). [vox_at_venue]

---

## PART 2 — Side notes

- **VW Zero Lemon — WH add (CS-approved):** `Vitamin Well - Zero Lemon` exists in catalog. Add **5 pcs @ 06/09/26** to warehouse inventory via `adjust_warehouse_stock` (run as WH manager, provenance `manual_adjust`). Confirm target WH (likely Mirdif/WH_MM or WH_CENTRAL) before applying.
- **Mirdif Stockroom list — Simran only, DO NOT log to system** (doc says "not update in system, this is for simran"): Gatorade Zero 5, Gatorade Cool Raspberry 5, Sunblast Orange 10, Sunblast Apple 10, Evian 24, Leibniz Milk&Honey 5, Leibniz Cocoa 6, Pocari 12. Surface as a WH/Simran note (action_tracker, type task, no refill/WH writes).

## Constraints (carry from PRD-016/017/018)

Cody before any canonical-writer/view/trigger change; verbatim bodies; service-role bypass pattern; pod_inventory_audit_log operation lowercase + valid source; pod_inventory.status enum; warehouse_inventory.status manager-only; RPC-only writes to refill_dispatching/pod_refill_plan/refill_plan_output (+ allow-list); log_retroactive_refill_visit = Refill/Add New only, Removes via insert_driver_remove_line. Verify in rolled-back tx; update RPC_REGISTRY/CHANGELOG/PRD status. Apply BUG-D fix (PRD-018 Dara design) is NOT part of this round.

## DONE CRITERIA — ✅ COMPLETE (applied to prod 2026-06-07)

- [x] Nissan 04/06 superseded (14 rows `include=false` + SUPERSEDED comment) + full 05/06 logged once (29 rows). No double-count.
- [x] AMZ-1029 (25)+Zigi→Sunbites Remove, AMZ-1038 (23)+Zigi(3)→Nibbles Remove, NOOK (16) 05/06 logged; 06/06 six VOX machines logged (1+5+3+3+3+5=20, vox_at_venue).
- [x] Past/invalid SKIPPED (Hunter Sea Salt&Vinegar 01/02/26, AMZ-1029 Dubai Salted 17/02/26, VW Reload 30/02/26 invalid, VOX Well Care 06/06/26); PARKED to action_tracker: A6 Hummus N/A (procurement), AMZ-1029 Reload invalid-date, NOOK G&H+Eviron no-qty.
- [x] VW Zero Lemon +5 @2026-09-06 → WH_CENTRAL (adjust_warehouse_stock, WH-mgr, manual_adjust); Mirdif list → 1 action_tracker task (Simran-only, not logged).
- [x] Registries updated (CHANGELOG + RPC_REGISTRY set_dispatch_include bypass). CS calls: Al Ain Zero→Regular; Nissan VW Upgrade/Reload 2 each; KitKat + NOOK Krambals date typos → 2027.
