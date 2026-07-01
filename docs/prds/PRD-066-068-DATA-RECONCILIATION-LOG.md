# Data reconciliation log - applied to prod via MCP 2026-06-30 (post main 2cdcc96)

These are one-time DATA corrections (no DDL). Recorded here for audit; they do not require migration files. The CODE changes that DO need to reach main are tracked in PRD-FINAL-push-to-main-goal-command.md.

## Conservation reconciliation (PRD-068 live-violation pass) - driver-confirmed truth

check_pod_conservation was non-zero for 2026-06-24..30 (10 REMOVE violations). Reconciled to driver-confirmed physical truth (CS decision), NOT to pod-plan qty (which would have discarded real removals).

- Step 1: aligned 12 stale REMOVE child `refill_dispatching.quantity` -> their `driver_confirmed_qty` (scoped to the 10 violation shelves, non-cancelled Remove/M2W). Cleared 5 pure-artifact violations (MC-2004 G&H, MC-2004 Starbucks, OMDCW-1021 Krambals & Zigi, AMZ-1057 YoPRO, MINDSHARE-1009 Krambals).
- Step 2: set 5 `pod_refill_plan.qty` parents to the driver-confirmed sum for the genuine plan-vs-actual gaps:
  - HUAWEI-2003 Red Bull 2 -> 7 (plan was stale-low; 5 real units preserved)
  - NOVO-1023 Organic Larder Rice Cake 1 -> 2
  - AMZ-1038 McVities Digestive Nibbles 7 -> 6
  - AMZ-1068 Popit Mix 6 -> 5
  - GRIT-1022 Be-kind Bar 9 -> 8
- Result: check_pod_conservation returns ZERO for every day 2026-06-24..30.

## Sour Cream duplicate merge (PRD-067 item 1)

CS confirmed one physical product mislabeled. 285479a7 "Hunter Ridge - Sour Cream & Onion" had 37 real refs (not the empty shell the doc claimed).

- Repointed 285479a7 -> 4edc4fbb across refill_dispatching(17), pod_inventory(6), warehouse_inventory(1), purchase_orders(1), weekly_procurement_plan(5), daily_reconciliation_log(1), inventory_audit_log(2), pod_inventory_edits(1); deleted 3 derived slot_profile_pool rows.
- Verified zero remaining refs, DELETED 285479a7, RENAMED 4edc4fbb -> "Hunter Ridge - Sour Cream & Onion". One correctly-named product; no stock lost. product_mapping had 0 collisions.

## PRD-066 returns queue + not-filled

- Declined 13 stale/wrong returns via decline_dispatch_return (no WH credit, no pod change): 9 effective + 4 already-resolved noop. Named: Eviron MPMCC-1054, Santiveri ALJLT-1015 x2, plus stale dconf-0 >120h (Freakin MC-2004, Hunter Sea Salted OMDCW/AMZ-1038, Hunter Hot Chili AMZ-1029, Zigi AMZ-1068, Red Bull Diet VML, Sun Blast + NRJ qty-0). EXCLUDED 4 legitimate confirmed returns (NRJ Roasted&Salted, Sun Blast Apple, fresh NRJ/Sun Blast) - left for normal WH approval.
- USH-1008 Vitamin Well: declined 2 stale returns. Zero-peach still Active(1) in pod so no re-add needed; Antioxidant is Inactive(0) and unverified - NOT fabricated, flagged for physical confirm.
- not_filled reconcile: zeroed filled_quantity on 8 rows where pack_outcome='not_filled' AND filled_quantity>0 (the "Not Filled still shows qty" glitch, data level).

## Still open (need CODE in main, see PRD-FINAL goal)

- PRD-068 durable: not_filled=0 guard going forward; post-confirm conservation re-assert hook on confirm/edit RPCs; daily conservation monitor cron.
- PRD-034: venue_team WH-credit guard in receive_dispatch_line.
- PRD-036 backend: FEFO bind from_wh_inventory_id at pickup.
- AMZ M2M + MC->Amazon transfers: receive-vs-decline, needs a look.
- USH VW Antioxidant physical confirm.
