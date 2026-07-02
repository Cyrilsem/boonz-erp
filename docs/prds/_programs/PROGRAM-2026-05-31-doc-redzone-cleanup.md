---
id: PROGRAM-2026-05-31
parent: PROGRAM-2026-05-30
title: 22-28 May refill doc - red-zone cleanup (close all 42 outstanding lines in one /goal)
status: Ready-for-goal
severity: P1
opened: 2026-05-30
target_ship: in-session (today/tomorrow)
source: 30-May status review of the 22-28 May refill update doc. 67 lines GREEN, 11 YELLOW (backend fixed, verify-next-refill), 42 RED. The 42 reds split as 35 out-of-scope recount lines for 12 machines never in CC's run, 6 awaiting-Simran clarifications (parked), 1 Yo Pro expiry on MC-2004 that was missed.
---

## Goal of this run

Close every closable RED line from the 22-28 May refill update doc in one /goal pass. Defer only items that genuinely need Simran clarification or CS sign-off. End state: zero RED on the doc status review except the 6 already-parked Simran items.

## Why so many red (single-paragraph diagnosis)

The previous /goal was correctly scoped to HUAWEI-2003 + MC-2004. The doc covers 14 machines across 4 days; the other 12 machines were out of scope, so their recount lines were never attempted. This is not a failure - it is a missing follow-up run. This PRD is that follow-up.

## Scope: the 42 RED lines, bucketed by close-method

### Bucket A. Per-machine pod recount via add_stock (29 lines, 12 machines)

For each machine below, run add_stock edits in one batch through approve_pod_inventory_edit, exactly as the HUAWEI/MC recount did. Shelves resolved via product_mapping pod_product on each machine; halt and surface only the items where shelf cannot be resolved.

| Machine          | Lines from doc                                                                                                                                                                         | Notes                                                         |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Novo-0813        | Pepsi Regular 3 @ 01/02/2027; Pepsi Black 4 @ 29/10/2026                                                                                                                               | 22/05                                                         |
| OMDBB-0809       | Activia Honey 1 @ 01/02/2026; Hot Chili 1 @ 11/11/2026; Black Truffle 1 @ 31/01/2027; Hot & Sweet swap to Himalayan Pink 1; VW Well Care 1, Upgrade 2, Antioxidant 1; Caramel Cashew 1 | 22/05                                                         |
| AMZ-1038         | Snickers 4, Mars 4, Twix 5, Bounty 3, Delice Cake 3, KitKat 8; 2 Organic Larder Rice Milk Choc @ 12/12/2026 transferred from OMDBB                                                     | 22/05                                                         |
| AMZ-1057         | Smart Gourmet Classic 2 @ 25/01/2026 (PAST - flag for Simran); Bounty 2, Snickers 4, Mars 4, Twix 5                                                                                    | 22/05                                                         |
| AMZ-1068         | Smart Gourmet 2 @ 25/01/2027; Sabahoo 4 @ 15/06 (incomplete date - flag); Popcorn Butter 2, Popcorn Salt 2, Twix 5                                                                     | 22/05                                                         |
| AMZ-1029         | Twix 5, Mini Dark Choc 4, Salt Popcorn 1, Butter Popcorn 1, Hunter Sea Salt 2 @ 16/11/2026                                                                                             | 22/05                                                         |
| VOX 0797         | 6 ice tea lemon, 8 galaxy choc, 7 bounty, 6 snickers, 3 VW reload, 5 VW upgrade                                                                                                        | 24/05; VOX-supplied items may need decouple flag per VOX rule |
| VOX 0795         | 12 ice tea peach, 7 VW upgrade, 2 VW reload                                                                                                                                            | 24/05                                                         |
| iFly             | 5 galaxy choc, 8 snickers, 5 mars                                                                                                                                                      | 24/05                                                         |
| MP 0719          | 5 pepsi diet, 6 ice tea peach, 3 M&M peanut, 3 M&M choc, 4 sunblast apple                                                                                                              | 24/05                                                         |
| MP 0715          | 32 aquafina                                                                                                                                                                            | 24/05                                                         |
| Activate 0817    | 24 aquafina, 5 redbull, 6 gatorade blue, 6 gatorade zero, 6 sunblast apple, 2 evian 1L (last 4 "from office" - flag)                                                                   | 24/05                                                         |
| Activate 0736    | 4 evian 1L (from office)                                                                                                                                                               | 24/05                                                         |
| VOX Mercato 0798 | 3 krambals tomato, 1 Leibniz cocoa, 1 Leibniz milk honey, 1 Leibniz original, 3 VW reload, 3 VW upgrade, 2 VW zero peach                                                               | 24/05                                                         |

### Bucket B. 27-28 May refills (6 lines, 6 machines)

Same add_stock path. Lines:

- Activate 0736: 7 VW Peach @ 27/09/2026 + 9 Nutella @ 24/11/26 + 3 Evian 1L @ 12/10/27 + 1 Evian 1L @ 14/10/2026 + 10 VW Upgrade
- Activate 0817: 86 aquafina (VOX-supplied)
- MP 0715: 10 Poppit mix transfer + 5 Pocari transfer + 4 Loacker Cream Kakao @ 03/03/27 + 4 Loacker Napolitaner @ 11/05/27 + 4 Loacker Vanilla @ 15/05/27 + 4 Zigi sweet chili @ 12/01/27 + 5 Zigi salt @ 06/01/27 + 4 Nibbles caramel @ 24/11/26 + 2 Nibbles dark @ 03/11/26 + 3 Nibbles milk @ 06/09/26 + 2 Krambals tomato @ 20/01/27 + 2 Krambals green olive @ 10/07/26
- VOX 0797: 9 Nutella @ 24/11/26 + 10 Sunblast Apple @ 24/03/27
- VOX 0795: 10 Sunblast Apple @ 24/03/27
- AMZ-1068 (28/05): 1 Popcorn Salt @ 01/02/27 + 1 Popcorn Butter @ 17/02/27 + 1 Be Kind Cluster PB @ 13/10/26 + 1 Be Kind Cluster PB @ 19/08/26 + 2 Be Kind Cluster Hazelnut @ 20/08/26 + 1 Be Kind Cluster Dark Choc @ 18/08/26

### Bucket C. Yo Pro MC-2004 expiry fix (1 line)

Doc line: "Yo Pro Strawberry - 13/07/2026 (Need to update the expiry in pod)". Find the current MC-2004 Yo Pro Strawberry pod row, if expiry differs, archive + add with 13/07/2026.

### Bucket D. Driver-rec planned_swaps (3 batches)

Insert planned_swaps rows for next visit:

- Novo: Be Kind Bar -> Barebells (full swap).
- OMDBB: McVities Milk 5, McVities Dark 5, Oreo 3, Mars 3, Snickers 3, Delice 3.
- MC-2004: Mars 3, Bounty 5, M&M Choc Nuts 5.

### Bucket E. System Bugs Summary (3 issues)

- IFLY-1024 M2M Barebells 12 pcs to WH (19/05): apply PRD-014 Phase 3 repair via canonical `repair_orphan_internal_transfer` for that specific orphan. CS sign-off required (destructive class).
- OMDCW-1021 Returned items variant-split UI error (21/05): re-test on /field/dispatching the Hunter Truffle variant flow. If still broken, ticket to Stax for the FE fix and write a clear repro.
- MCC WH phantoms (21/05): list every Hunter / Organic Rice Cake / Perrier WH row in WH_MCC that has no procurement_events history; surface for CS to authorize bulk drain via canonical drain RPC.

## Hard rules (carried from prior runs)

1. No raw writes on protected tables.
2. Reuse pod_inventory_edits + approve_pod_inventory_edit (add_stock edit_type, live since 30-May).
3. Pod-only scope: never touch warehouse_inventory.expiration_date.
4. Multi-batch per (machine, shelf, product) collapses via add_stock merge: sum stock, earliest expiry.
5. Per the VOX-sourced products memory: any VOX-supplied product on VOX/iFly/MP/Activate gets a separate procurement_decouple tag (do not bill against Boonz POs).
6. No em-dashes anywhere.
7. Cody review only required for the System Bugs Bucket E items (touch protected entities). Bucket A-D use existing canonical writers, no review needed per line.

## Out of scope (defer to next runs)

- The 6 Simran clarifications (PDF sent; reopens when she replies).
- 11 YELLOW lines (verify next refill, not actionable today).
- Structural fix (PROGRAM-2026-06-02 recount RPC + force_close + shelf_id NOT NULL).
- Past-expiry items: flag for Simran, do not auto-add.

## Acceptance

- Bucket A: 12 machines have add_stock edits submitted, applied, and verified; per-machine row table in final report.
- Bucket B: 6 27-28 May refill batches applied.
- Bucket C: Yo Pro MC-2004 expiry updated.
- Bucket D: 3 planned_swaps rows inserted for next visit.
- Bucket E: IFLY orphan repaired (or surfaced for CS sign-off); OMDCW re-test result reported; MCC phantom list surfaced for CS sign-off.
- Final report shows: per-bucket close count, defer reasons, before/after RED count on the doc status review.

## Sequence

1. Bucket A first (mechanical, fastest, biggest count).
2. Bucket B (same path).
3. Bucket C (1 line).
4. Bucket D (planned_swaps inserts, no canonical RPC needed - planned_swaps is non-protected).
5. Bucket E (last, needs Cody for the IFLY repair + MCC drain; OMDCW just a re-test).

Target close: this session. If anything halts, halt cleanly with per-line "deferred: <reason>" entries, do not block the rest.

## /goal command

See companion file: PROGRAM-2026-05-31-doc-redzone-cleanup.goal.txt (4000-char trimmed).
