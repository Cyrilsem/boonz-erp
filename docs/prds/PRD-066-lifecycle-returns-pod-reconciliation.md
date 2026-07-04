# PRD-066: Lifecycle reconciliation - stale returns queue + pod state

Status: Closed 2026-07-04 (CS per-row answers, executed via Cowork MCP). Final sweep: VW Hydrate USH d31b6cd5 received (qty 4, remove_fefo_fallback, NO WH credit - pod already empty, see note); M&M AMZ-1038 8a139416 received (venue_team guard skipped WH credit, correct per PRD-054); MC-2004 Starbucks 04d925bc + G&H b119b392 DECLINED as internal transfer MC->AMZ-1038 (stock verified already Active at AMZ-1038 pod: Starbucks 6u, G&H 11u; no WH credit, conservation holds); HUAWEI qty-0 x3 (3fb53eb6, 1492f5de, a34bfb9e) declined as junk. Queue now holds only 3 recent (<72h) legitimate rows for normal FE approval. OPEN NOTE: the 4 VW Hydrate units confirmed off USH were NOT credited anywhere - if physically in the office, WH is understated by 4 (needs adjust_warehouse_stock). Earlier partial execution in PRD-066-068-DATA-RECONCILIATION-LOG.md. Reopen by deleting this line.

Owner: CS. Date: 2026-06-30. Surface: data reconciliation on prod via canonical RPCs only. Touches refill_dispatching, pod_inventory, warehouse_inventory (Articles 1,3,12). Cody review mandatory. Idempotent, skip+log gaps, no em dashes.

## Problem (from the 28/06 + 30/06 "Pod Inventory Need to Adjust" list)

The returns approval window (`v_pending_wh_remove_confirmations`) is clogged with stale and wrong rows that never resolved, and some pod state is wrong because a REMOVE was logged for stock that was never physically pulled. Verified live 2026-06-30:

| Item                                                                                                                                     | Machine                | State now                                                                              | Correct action                                                                          |
| ---------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Vitamin Well (Antioxidant, Hydrate, Zero Peach)                                                                                          | USH-1008-0000-W1       | 3 REMOVE rows pending 346h; stock was NEVER physically removed                         | Decline the returns AND re-add the units to the USH pod (stock is still in the machine) |
| Eviron - Wellness Drink                                                                                                                  | MPMCC-1054-0000-M0     | pending 442h; already in stockroom (approval-window bug)                               | Decline (no WH credit, already counted)                                                 |
| Santiveri (Cran Berry, Double Chocolate)                                                                                                 | ALJLT-1015-0200-O1     | pending 199h; never received in WH, no pod stock, status updated wrongly by field edit | Decline (correct the false status)                                                      |
| NRJ Nut - Trail Mix                                                                                                                      | MINDSHARE-1009-4500-O1 | pending 174h, qty 0                                                                    | Decline (qty 0, junk)                                                                   |
| Sun Blast - Cherry & BlackCurrant                                                                                                        | WAVEMAKER-1006-4100-O1 | pending 173h, qty 0                                                                    | Decline (qty 0, junk)                                                                   |
| AMZ M2M transfer                                                                                                                         | (Amazon site)          | M2M removed from source but never received back to warehouse                           | Complete the receive into WH (or decline if duplicate)                                  |
| MC to Amazon transfer                                                                                                                    | MC-2004 -> AMZ         | removed from Mastercard, transfer to Amazon never landed                               | Complete the transfer / receive                                                         |
| Stale qty-0 / >120h returns (Hunter Hot Chili AMZ-1029 271h, Hunter Sea Salted AMZ-1038 270h, McVities qty-0, Red Bull qty-0, M&M, etc.) | various                | pending >120h, mostly driver_confirmed_qty 0                                           | Decline as a class, one log line each                                                   |

The recent (<48h) legitimate pending returns (GRIT/WAVEMAKER Be-kind, AMZ-1068 Popit/Zigi/Krambals, WPP McVities fresh) are OUT of scope - CS approves those normally.

## Rules

- Use the existing validated return path. Junk/wrong rows: `decline_dispatch_return(dispatch_id, reason)` (sets returned=true, include=false, NO WH credit, NO pod write). Re-add (Vitamin Well only): retroactive ADD via the canonical pod writer to restore the units that were never pulled. AMZ/MC transfers: complete via the canonical receive (`receive_dispatch_line`) only if the source REMOVE is real and unreceived; else decline.
- SCOPE GUARD: only touch rows matching the table above (named product+machine) OR pending_hours > 120 with driver_confirmed_qty = 0. Never touch a row younger than 48h. Print the full candidate set and the per-row decision before any write.
- Idempotent: a row already returned/declined or a Vitamin Well unit already restored is a no-op on re-run.
- CONSERVATION: declines move no stock; the Vitamin Well re-add restores exactly the pulled qty (assert pod delta = sum of the 3 declined REMOVE qtys). Eviron/AMZ/MC must not double-credit WH.
- Skip+log: any row whose source REMOVE cannot be resolved is SKIPPED and written to the final incomplete-tasks log, not forced.

## Acceptance

- The 8 flagged classes above are resolved (declined / re-added / received) with a per-row log.
- `v_pending_wh_remove_confirmations` no longer shows the named stale rows.
- Vitamin Well units are back in the USH-1008 pod (conservation asserted).
- No warehouse_inventory double-credit from Eviron / Santiveri / AMZ / MC.
- Recent legitimate returns untouched.
- Final log lists every SKIPPED row with the reason.
