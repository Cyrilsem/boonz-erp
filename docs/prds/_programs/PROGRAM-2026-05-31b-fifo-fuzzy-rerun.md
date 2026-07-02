---
id: PROGRAM-2026-05-31b
parent: PROGRAM-2026-05-31
title: 22-28 May refill doc - FIFO+fuzzy rerun (post CS-comment unblock)
status: Ready-for-goal
severity: P1
opened: 2026-05-30
source: CS annotated the status Google Doc with shelf-class hints and a "take FIFO from WH" directive that unblocks ~25 of the 38 RED lines. The original /goal halted because doc lines were undated and products weren't on the target machine; the missing piece was using the canonical chain fuzzy-match-product to product_mapping pod_product to shelf, then sourcing the expiry from warehouse_inventory FIFO. Sample-tested 2026-05-30 on 5 chocolate-bar entries across IFLY/OMDBB - chain works.
---

## What changed since PROGRAM-2026-05-31

CS confirmed three operating rules that the prior run did not apply:

1. Undated doc lines should pull expiry from warehouse_inventory FIFO (earliest expiry where status=Active and warehouse_stock>0).
2. Simran's free-text product names are shorthand. Fuzzy-match to boonz_products by stem (Snickers, Mars, Twix, etc.), then resolve shelf via product_mapping pod_product on the target machine.
3. Shelf classes are deterministic: Snickers/Mars/Twix/Bounty/Galaxy go to the Chocolate Bar shelf; Delice/KitKat/McVities Mini go to Snack Bar; Hunter / Hunter Ridge / Hunter Sea Salted go to Hunter Chips; Vitamin Well variants go to the Vitamin Well shelf; Barebells variants go to Barebells; Dubai Popcorn variants go to Dubai Popcorn.

Plus CS confirmed: Sabahoo 15/06 = 2026 (not 2027).

## Goal

Close every RED line that the FIFO+fuzzy chain can resolve. Defer only items where (a) WH has no stock of the product (FIFO unsatisfiable), (b) the product is VOX-supplied and the procurement_decouple mechanism is not yet built, or (c) Simran's clarification is genuinely required (past-expiry confirms, the original 6 PDF questions).

## Scope: re-bucketed with the new rules

### Bucket A1 - FIFO+fuzzy applyable (estimated ~22 lines)

Apply via add_stock for each line: fuzzy-match the product, resolve shelf via product_mapping pod_product on the machine, source expiry from WH FIFO. Skip if WH stock=0 (defer to Bucket A2).

| Machine                                                       | Lines (all undated; FIFO from WH)                                                                                                                                                                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| OMDBB-1020                                                    | Hot Chili 1 (Hunter Ridge - Hot N Sweet or similar), Black Truffle 1 (Hunter - Black Truffle), Hot & Sweet swap to Himalayan Pink 1, VW Well Care 1 + Upgrade 2 + Antioxidant 1, Caramel Cashew 1 (Barebells - Caramel Cashew) |
| AMZ-1038                                                      | Snickers 4, Mars 4, Twix 5, Bounty 3, Delice Cake 3, KitKat 8                                                                                                                                                                  |
| AMZ-1057                                                      | Bounty 2, Snickers 4, Mars 4, Twix 5                                                                                                                                                                                           |
| AMZ-1068                                                      | Twix 5                                                                                                                                                                                                                         |
| AMZ-1029                                                      | Twix 5, Mini Dark Choc 4, Salt Popcorn 1, Butter Popcorn 1                                                                                                                                                                     |
| Novo-1023                                                     | (already done in prior run)                                                                                                                                                                                                    |
| VOX 0797 / 0795 / iFly / MP 0719 / MP 0715 / VOX Mercato 0798 | Per-product fuzzy-match; chocolate bars / Vitamin Well / Krambals will resolve; pure VOX-supplied items defer to A3                                                                                                            |
| Activate 0817 / 0736                                          | Office-supplied items defer to A3; the rest fuzzy-match                                                                                                                                                                        |

### Bucket A2 - Defer (no WH stock)

A line lands here if the FIFO query returns NULL. Per the no-guessing rule, surface as deferred with reason "WH stock = 0 for this product; cannot source FIFO expiry". Known so far based on the sample WH query: Galaxy variants, Ice Tea Peach, M&M Chocolate Nuts, Aquafina (regular), Pocari, Vitamin Well Care, several Zigi variants, Leibniz Cocoa.

### Bucket A3 - VOX procurement_decouple (blocked on task #90)

Aquafina at VOX/iFly/MP/Activate, Gatorade Blue/Zero, Pepsi Diet, Pocari, certain VW variants when sourced from VOX stockroom. These need the `source_origin='vox_at_venue'` decouple tag on the add_stock edit so they don't count against Boonz POs. Until task #90 ships, defer.

### Bucket A4 - Still Simran

The 6 already-parked PDF items (Mountain Dew qty, Nescafe Mocha qty+expiry, VW Upgrade 31/05, Popit Orange Squeeze, Tamreem Mango, Tamreem Peach) plus 2 past-expiry confirms (Activia Honey 01/02/2026 OMDBB, Smart Gourmet Classic 25/01/2026 AMZ-1057).

### Bucket E (unchanged from prior PRD) - System Bugs

- IFLY orphan (DONE)
- OMDCW variant-split (Stax ticket filed)
- MCC WH phantom (blocked on task #89 drain RPC)

## Hard rules (carried forward)

1. No raw writes on protected tables. add_stock via approve_pod_inventory_edit only.
2. Fuzzy match must be deterministic: strip whitespace, case-fold, match by canonical stem (Snickers->Snickers - Regular). If multiple candidates, halt and surface.
3. FIFO query: `SELECT MIN(expiration_date) FROM warehouse_inventory WHERE boonz_product_id=$1 AND warehouse_stock>0 AND status='Active'`. If NULL, defer to A2.
4. Shelf resolution: prefer the machine's existing pod_inventory shelf for this pod_product if any (most recent Active). Fall back to product_mapping if no pod row exists. If both miss, defer with reason.
5. Pod-only scope: never touch warehouse_inventory.
6. No em-dashes.
7. Cody review not required for Bucket A1 (existing canonical writer); required only if Bucket E touches.

## Closability estimate (after this run)

Starting RED: 38. Expected end:

- Bucket A1 closes ~20 lines (chocolate bars + Hunter + VW + Barebells + Krambals where WH has stock)
- Bucket A2 surfaces ~6 deferrals (no WH stock)
- Bucket A3 surfaces ~6 VOX-decouple-blocked
- Bucket A4 unchanged (~8 Simran items)
- Bucket E unchanged (~1 MCC phantom)

Estimated final RED count after this run: ~14, all genuinely blocked (Simran + WH-zero + decouple + Dara WH-drain).

## /goal command

See companion file PROGRAM-2026-05-31b.goal.txt.

## Acceptance

- Bucket A1: per-machine row table showing each closed line with shelf + expiry + edit_id.
- Bucket A2: list of products with WH-zero (procurement signal for the next PO).
- Bucket A3: list of VOX-decouple-blocked items (input for task #90).
- Final RED count + reason-per-line for what remains.

## CLOSEOUT (executed 2026-05-31)

Status: DONE. Chain (fuzzy-match -> product_mapping pod_product -> family/direct shelf -> WH FIFO or doc date) ran across all 13 in-scope machines. All writes pod-only, additive, via `add_stock` proposal + `approve_pod_inventory_edit` (canonical writer, CS uid 82bba4ee as requested_by + approver). No raw protected-table writes. No `warehouse_inventory` touched. No Cody (A1 only).

### A1 - applied this run: 24 lines (all `result:success`, read-back verified)

| Machine          | Product                                              | Shelf | Qty added | Final exp (FEFO LEAST) | edit_id  |
| ---------------- | ---------------------------------------------------- | ----- | --------- | ---------------------- | -------- |
| OMDBB-1020       | Hunter Ridge - Hot N Sweet (doc "Hot Chili", CS map) | A14   | 1         | 2026-11-11             | 6dede50e |
| OMDBB-1020       | Hunter Ridge - Himalayan Pink Salt (Hot&Sweet swap)  | A14   | 1         | 2026-12-03             | 9b3fd618 |
| OMDBB-1020       | Vitamin Well - Upgrade                               | A16   | 2         | 2026-06-21             | b44248ad |
| AMZ-1038         | Snickers - Regular                                   | A07   | 4         | 2026-11-06             | b7cc0e14 |
| AMZ-1038         | Mars - Regular                                       | A07   | 4         | 2026-12-01             | 9be67951 |
| AMZ-1038         | Twix - Regular                                       | A07   | 5         | 2027-02-22             | d821e2e6 |
| AMZ-1038         | Kinder Delice - Cake                                 | A08   | 3         | 2026-07-02             | dd3b1ea5 |
| AMZ-1038         | Nestle Kit-kat - Regular                             | B04   | 8         | 2027-01-31             | 5910c3a2 |
| AMZ-1057         | Snickers - Regular                                   | B03   | 4         | 2026-11-06             | e33a5d91 |
| AMZ-1057         | Mars - Regular                                       | B03   | 4         | 2026-12-01             | ac90168a |
| AMZ-1057         | Twix - Regular                                       | B03   | 5         | 2027-02-22             | 992c2983 |
| AMZ-1068         | Twix - Regular                                       | A07   | 5         | 2027-02-22             | 521ee72a |
| AMZ-1068         | Dubai Popcorn - Salted (undated 22May batch)         | C03   | 2         | 2027-02-01             | 694911f7 |
| AMZ-1068         | Dubai Popcorn - Butter (undated 22May batch)         | C03   | 2         | 2026-12-01             | 481f1037 |
| AMZ-1029         | Twix - Regular                                       | A07   | 5         | 2027-02-22             | 9edd264b |
| AMZ-1029         | McVities Digestive - Mini Dark Chocolate             | B04   | 4         | 2026-11-01             | 619073df |
| AMZ-1029         | Dubai Popcorn - Salted                               | C03   | 1         | 2027-02-01             | 84fe0be6 |
| AMZ-1029         | Dubai Popcorn - Butter                               | C03   | 1         | 2026-12-01             | 8148408f |
| IFLY-1024        | Mars - Regular                                       | A03   | 5         | 2026-12-01             | 79454ec7 |
| IFLY-1024        | Snickers - Regular                                   | A03   | 8         | 2026-11-07             | 0d2e857b |
| VOX Mercato-0798 | Vitamin Well - Reload                                | A10   | 3         | 2026-08-23             | 055f3512 |
| VOX Mercato-0798 | Vitamin Well - Upgrade                               | A10   | 3         | 2026-06-21             | 10065dc0 |
| MP-0719          | Sun Blast - Apple                                    | A13   | 4         | 2026-12-06             | ddb20acd |
| VOX-0795         | Sun Blast - Apple                                    | A03   | 10        | 2026-12-06             | 4384b595 |

Already closed by the 30-May run (reconciled, NOT re-applied to avoid double-count): AMZ-1029 Hunter Sea Salted 2@2026-11-16; AMZ-1038 Organic Larder Rice Cake Milk Choc 2@2026-12-12; AMZ-1068 Dubai Popcorn Salted 1@2027-02-01 + Butter 1@2027-02-17 (dated 28/10 batches) + Smart Gourmet Classic Humus 2@2027-01-25; AMZ-1068 Sabahoo (partial_sold/expired/reject already applied 30-May - left alone).

### A2 - WH stock = 0 (procurement-gap signal for next PO; FIFO unsatisfiable)

Bounty - Regular (AMZ-1038, AMZ-1057, VOX-0797); Vitamin Well - Care (OMDBB); Vitamin Well - Antioxidant (OMDBB); Galaxy - Milk Chocolate (IFLY, VOX-0797); Ice Tea - Peach (MP-0719, VOX-0795); M&M - Chocolate Nuts (MP-0719); Vitamin well - Zero peach (Mercato); Leibniz Zoo - Cocoa (Mercato); Zigi - Sweet Chilli + Sea Salted (MP-0715). On a Boonz machine with a shelf these are clean A2 (OMDBB VW Care/Antiox, AMZ Bounty x2, IFLY Galaxy); the rest also lack shelf history.

### A3 - VOX/office decouple-blocked (input for task #90; needs source_origin='vox_at_venue' tag, which add_stock has no param for)

MP-0715: Aquafina 32, Zigi SweetChilli 4, Zigi SeaSalted 5, Nibbles Caramel 4/Dark 2/Milk 3, Krambals Tomato 2, Krambals GreenOlive 2.
Activate-0817: Aquafina 24 + 86(from vox), Gatorade Blue 6(office), Gatorade Zero 6(office), SunBlast Apple 6(office), Evian 1L 2(office), Pocari 5(transfer).
Activate-0736: Evian 1L 4(office)+3(union)+1, VW Zero Peach 7(from office), VW Upgrade 10(from vox stockroom), Nutella 9(union).
VOX-0797: Snickers 6, SunBlast Apple 10, VW Reload 3, VW Upgrade 5 (VOX-venue, no Boonz shelf history).
VOX-0795: VW Reload 2, VW Upgrade 7.
Mercato-0798: Krambals Tomato 3, Leibniz MilkHoney 1, Leibniz Regular 1.
NOTE: this is far larger than the PRD's "~6" estimate. The VOX/MP venues carry many non-Boonz-dispatched items; all are genuinely blocked on #90 (decouple) plus add_new_product shelf placement.

### Defer - placement needed (Boonz product, no historical family shelf on machine; needs add_new_product shelf decision, not additive)

OMDBB: Hunter - Black Truffle 1, Barebells - Caramel Cashew 1. AMZ-1068: Be-kind Cluster PB 2, Hazelnut 2, Dark 1. Activate-0817: Loacker Creamkakao 4, Napolitaner 4, Vanille 4, Red Bull - Regular 5.

### A4 - Simran / past-expiry (untouched, per rule)

6 PDF items (Mountain Dew qty, Nescafe Mocha qty+expiry, VW Upgrade 31/05, Popit Orange Squeeze, Tamreem Mango, Tamreem Peach) + 2 past-expiry confirms (Activia Honey 01/02/2026 OMDBB; Smart Gourmet Classic 25/01/2026 AMZ-1057).

### No catalog match / ambiguous (surface for Simran/CS - not in fuzzy map or >1 candidate)

VOX-0797 "iced tea lemon" (no lemon Ice Tea variant); MP-0719 "pepsi diet" (no Pepsi - Diet in catalog); MP-0719 "m&m peanut" (no M&M - Peanut in catalog); "Nutella" bare (3 variants - B Ready / Biscuit T12 / T3); Activate-0817 "poppit mix" transfer (no Popit catalog match).

### Bucket E (system bugs) - unchanged

IFLY orphan DONE; OMDCW variant-split Stax ticket filed; MCC WH phantom blocked on task #89 drain RPC. No E touches this run (no Cody needed).

### RED reconciliation

Start 38. Closed this run via A1: 24. Previously closed 30-May (reconciled): ~5. The remainder are genuinely blocked: A2 WH-zero (~10 product lines), A3 VOX/office decouple (~30 lines, blocked on #90 - exceeds estimate), placement-needed (9), A4 Simran/past-expiry (8), no-match/ambiguous (5). Net: every line the FIFO+fuzzy chain could resolve was closed; all residual lines have an explicit, actionable reason.
