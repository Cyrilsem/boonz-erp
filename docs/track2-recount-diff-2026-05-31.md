# Track 2 — Inventory-control recount diff (HUAWEI-2003 + MC-2004)

Review-before-write. Policy: correct pod ONLY where the 25-May recount diverges from current
live-WEIMI pod. Apply via `adjust_pod_inventory` with reason `INVENTORY-CONTROL 2026-05-25 <machine>`.
No writes made yet. Both machines are live-WEIMI (last snapshot 31-May 07:09), so any correction
may be re-asserted by WEIMI — a divergence is itself a WEIMI-accuracy signal.

**Semantics flag:** the doc mixes "set to N" and "add N more". Lines marked ⚠ need your read on which.

## MC-2004 — clear discrepancies

| Shelf      | Product                         | Current pod                              | Doc recount                                                    | Proposed action                                      |
| ---------- | ------------------------------- | ---------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------- |
| A03        | Pepsi - Black                   | 14 @ 2026-08-13 (1 batch)                | 5 @ 2026-08-13 + 9 @ 2026-10-29                                | Split into 2 batches (qty same total 14, fix expiry) |
| A02        | Coca Cola - Zero                | 14 @ 2026-10-04                          | "add 8, 6 there" → 14                                          | MATCHES — no action                                  |
| A04        | Red Bull - Regular              | 2 @ 2027-07-27                           | add 4@2027-01-28 + 2@2027-05-31 + 4@2027-07-21                 | ⚠ doc = "add new" 10u; confirm add vs set            |
| A10        | Kinder Bueno                    | 4 @ 2026-07-10                           | remove existing, add 3@2026-09-26 + 1@2026-07-10               | Replace batch: 3@09-26 + 1@07-10                     |
| B06        | YoPRO - Strawberry              | 1 @ 2026-07-13                           | expiry 2026-07-13                                              | MATCHES (already fixed) — no action                  |
| B13 / nosh | Perrier - Regular               | 13 @ 2026-08-10 + 1 @ 2026-11-22 = 14    | 7@2026-09-18 + 2@2026-11-22 + 1@2026-11-21 + 1@2026-08-10 = 11 | ⚠ qty 14→11 and 4-batch expiry rebuild; confirm      |
| B10        | Be-kind Bar - Almond & Sea Salt | 2 @ 2026-08-08                           | 2 @ 2026-08-08                                                 | MATCHES — no action                                  |
| A15        | Dubai Popcorn Salt/Butter       | Salt 1 @2026-12-16, Butter 2 @2026-08-04 | doc salt 16/01/27-1, butter 04/08+01/11                        | ⚠ expiry differs; confirm                            |

## HUAWEI-2003 — clear discrepancies

| Shelf | Product                     | Current pod                                   | Doc recount                                                   | Proposed action                                                              |
| ----- | --------------------------- | --------------------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| A09   | Snickers - Regular          | 8 @ 2026-06-28 (1 batch)                      | 2@2026-11-07 + 2@2026-11-06 + 1@2026-06-28 + 3@2026-06-29 = 8 | Rebuild 4 batches (total 8, fix expiry). Doc flagged "Snickers expiry wrong" |
| A03   | Nescafe - Mocha Iced Coffee | 1 @ 2026-09-05                                | 1 @ 2026-05-28                                                | ⚠ expiry 09-05 → 05-28 (past date — confirm w/ Simran)                       |
| nosh  | Be-kind Cluster - Hazelnut  | 2 @ 2026-08-19                                | 3 @ 2026-08-19                                                | ⚠ qty 2→3 (add 1) — confirm add vs WEIMI truth                               |
| B01   | Red Bull - Diet             | 5 @ 2026-07-31                                | 4 @ 2026-07-31                                                | ⚠ qty 5→4 — confirm                                                          |
| B01   | Red Bull - Regular          | 4 @ 2027-07-27                                | "add 1, total 4" → 4                                          | MATCHES — no action                                                          |
| B06   | Nutella - Biscuit T12       | 10 @ 2026-09-24                               | "24/09/26 - 3 pcs"                                            | ⚠ 10 vs 3 — likely "add 3" not "set 3"; confirm                              |
| A02   | Healthy Cola (5 variants)   | Cola 2, Apple 1, Lemon 1, Berries 2, Orange 3 | not in doc recount                                            | leave (WEIMI)                                                                |

## ⛔ STRUCTURAL FINDING (2026-05-31) — supersedes the "rebuild" actions above

`pod_inventory` enforces UNIQUE `(machine_id, shelf_id, boonz_product_id)` on Active rows
(`idx_pod_inv_active_shelf`): **one Active row per shelf+product, single FEFO expiry.** The doc's
multi-batch expiry breakdown is NOT representable in pod_inventory and does not need to be.

At the representable granularity (total qty + earliest/FEFO expiry), the three proposed "rebuilds"
are **already correct = NO-OP**:

- Snickers A09: 8 @ 2026-06-28 = recount total 8, earliest 06-28 ✓
- Pepsi Black A03: 14 @ 2026-08-13 = recount total 14, earliest 08-13 ✓
- Kinder Bueno A10: 4 @ 2026-07-10 = recount total 4, earliest 07-10 ✓

So **no pod writes were applied** (attempt rolled back atomically; pod unchanged). The only genuine
pod-correctable divergences are total-qty or FEFO-expiry differences, and those are exactly the
items already held for Simran. Inventory-control exercise logged to action_tracker (2 rows,
source=inventory_control_2026-05-25).

## The ask (Simran)

Most lines are expiry-batch rebuilds (FEFO splits) where current pod collapsed multi-batch reality
into one batch — these are safe, high-value corrections. The ⚠ lines hinge on "add vs set" and a
couple of past-dated expiries that need Simran. Once you confirm the ⚠ lines, I apply all via
`adjust_pod_inventory` with the inventory-control reason in one reviewed batch per machine.

_Built 2026-05-31 from live pod vs Simran 25-May recount. First-pass; the doc's full line lists
(~40 HUAWEI / ~45 MC) include many singles that already match WEIMI and need no action._
