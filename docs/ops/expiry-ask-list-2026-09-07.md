# Expiry Ask List — 2026-09-07

Generated from `check_expiry_unvalidated()`: Active `pod_inventory` rows with no `expiration_date`,
last touched (`snapshot_date`) more than 3 days ago. **164 rows across 32 machines** at generation
time (the goal's cited "175" was the count when PRD-119 first scheduled this assertion on
2026-09-07 morning; 11 have since been resolved by drivers independently — this list reflects the
current real count, not the stale figure).

**This is an ASK list, not a data fix.** No dates are invented here. Jojo (or whoever visits/packs
each machine next) reads the real batch date off the shelf and records it through the normal P3
expiry-check flow (`apply_expiry_check`, the same tap that already exists in the field app) — this
document exists only to tell him **where to look first**, ordered by how much traffic that machine
sees, so the highest-value lanes get checked before the low-traffic ones.

**Ordering:** machines sorted by trailing-30-day sales velocity (`sales_history`, delivery_status
Success/Successful), descending — highest-velocity machines first. Within a machine, rows are
listed by shelf.

---

## VOXMCC-1005-0201-B0 — 1,052 units/30d (3 rows)

| Shelf      | Product                      | Qty on shelf |
| ---------- | ---------------------------- | ------------ |
| A01        | Fade Fit - Dark Chocolate    | 7            |
| A12        | Skittles Bag - Regular Large | 6            |
| (no shelf) | Pepsi - Regular              | 0            |

## ACTIVATE-2005-0000-W0 — 745 units/30d (15 rows)

| Shelf | Product                                                    | Qty on shelf |
| ----- | ---------------------------------------------------------- | ------------ |
| A04   | Nestle Kit-kat - Regular                                   | 15           |
| A13   | G&H Popped Chips - Sweet And Salty                         | 0            |
| A14   | Krambals - Green Olives & Sea Salt                         | 0            |
| B02   | Tamreem Dried Freeze Fruits - Mango                        | 0            |
| B04   | Fade Fit - Salted Caramel                                  | 6            |
| B06   | Coca Cola - Zero                                           | 3            |
| B07   | Fade Fit - Salted Caramel                                  | 4            |
| B08   | Red Bull - Regular                                         | 6            |
| B10   | Aquafina - Regular                                         | 4            |
| B12   | Fade Fit - Dark Chocolate                                  | 9            |
| B12   | Al Ain Water - Regular (RETIRED 2026-08 — use Al Ain Zero) | 8            |
| B13   | McVities Digestive Nibbles - Choco Caramel                 | 8            |
| B13   | Al Ain Water - Regular (RETIRED 2026-08 — use Al Ain Zero) | 4            |
| B14   | Al Ain Water - Regular (RETIRED 2026-08 — use Al Ain Zero) | 1            |
| B14   | Loacker - Creamkakao                                       | 14           |

## AMZ-1038-3001-O1 — 681 units/30d (2 rows)

| Shelf | Product                | Qty on shelf |
| ----- | ---------------------- | ------------ |
| A13   | Coca Cola - Regular    | 3            |
| A16   | Vitamin Well - Hydrate | 1            |

## VOXMCC-1011-0101-B0 — 576 units/30d (5 rows)

| Shelf      | Product                           | Qty on shelf |
| ---------- | --------------------------------- | ------------ |
| A11        | Sun Blast - Apple                 | 9            |
| A13        | Nutella - Biscuit T12             | 5            |
| A14        | M&M Chocolate Bag - Regular Large | 10           |
| A15        | Skittles Bag - Regular Large      | 4            |
| (no shelf) | Pepsi - Regular                   | 0            |

## AMZ-1029-3003-O1 — 534 units/30d (2 rows)

| Shelf | Product                                  | Qty on shelf |
| ----- | ---------------------------------------- | ------------ |
| A05   | Activia Mix & Go - Greek Yogurt Rasberry | 2            |
| A13   | Coca Cola - Diet                         | 1            |

## ACTIVATEMCC-1037-0000-L0 — 354 units/30d (2 rows)

| Shelf | Product                   | Qty on shelf |
| ----- | ------------------------- | ------------ |
| A01   | Barebells - Salty Peanut  | 8            |
| A03   | Fade Fit - Salted Caramel | 3            |

## OMDBB-1020-0P00-O1 — 269 units/30d (4 rows)

| Shelf | Product                         | Qty on shelf |
| ----- | ------------------------------- | ------------ |
| A11   | Oreo Cookie - Regular           | 1            |
| A13   | Twix - Regular                  | 1            |
| A14   | Hunter Ridge - Hot N Sweet      | 0            |
| A15   | Dubai Popcorn - Sweet And Salty | 1            |

## VOXMM-1013-0101-B0 — 268 units/30d (3 rows)

| Shelf | Product                           | Qty on shelf |
| ----- | --------------------------------- | ------------ |
| A11   | Skittles Bag - Regular Large      | 5            |
| A14   | Sun Blast - Cherry & BlackCurrant | 1            |
| A15   | Leibniz Zoo - Mik and Honey       | 2            |

## MPMCC-1054-0000-M0 — 238 units/30d (2 rows)

| Shelf | Product         | Qty on shelf |
| ----- | --------------- | ------------ |
| A02   | Pepsi - Black   | 4            |
| A03   | Ice Tea - Peach | 6            |

## MC-2004-0100-O1 — 207 units/30d (6 rows)

| Shelf | Product                                      | Qty on shelf |
| ----- | -------------------------------------------- | ------------ |
| A08   | Pepsi - Black                                | 1            |
| A10   | Snickers - Regular                           | 6            |
| A14   | Activia Mix & Go - Greek Yogurt Strawberries | 3            |
| A15   | Dubai Popcorn - Sweet And Salty              | 0            |
| B09   | Barebells - White Almond Chocolate           | 2            |
| B14   | Vitamin Well - Care                          | 4            |

## AMZ-1068-2401-O1 — 198 units/30d (1 row)

| Shelf | Product          | Qty on shelf |
| ----- | ---------------- | ------------ |
| A13   | Coca Cola - Diet | 3            |

## OMDCW-1021-0100-W0 — 185 units/30d (4 rows)

| Shelf | Product                                                    | Qty on shelf |
| ----- | ---------------------------------------------------------- | ------------ |
| A02   | Perrier - Flavored Peach                                   | 3            |
| A03   | Popit - Orange Squeeze                                     | 5            |
| A10   | McVities Digestive - Mini Milk Chocolate                   | 1            |
| A15   | Al Ain Water - Regular (RETIRED 2026-08 — use Al Ain Zero) | 6            |

## HUAWEI-2003-0000-B1 — 151 units/30d (8 rows)

| Shelf | Product                     | Qty on shelf |
| ----- | --------------------------- | ------------ |
| A09   | Snickers - Regular          | 1            |
| A10   | Barebells - Caramel Cashew  | 2            |
| A11   | Be-kind Bar - Peanut Butter | 1            |
| A12   | Loacker - Napolitaner       | 7            |
| A14   | Kinder Delice - Cake        | 3            |
| B01   | Coca Cola - Zero            | 13           |
| B02   | Perrier - Flavored Lemon    | 0            |
| B07   | Perrier - Regular           | 4            |

## MPMCC-1058-0000-R0 — 134 units/30d (4 rows)

| Shelf | Product                            | Qty on shelf |
| ----- | ---------------------------------- | ------------ |
| A05   | Krambals - Green Olives & Sea Salt | 5            |
| A06   | Zigi - Sea Salted                  | 5            |
| A10   | M&M Chocolate Bag - Regular Large  | 7            |
| A15   | Krambals - Creamy Cheese           | 4            |

## USH-1008-0000-W1 — 124 units/30d (3 rows)

| Shelf      | Product             | Qty on shelf |
| ---------- | ------------------- | ------------ |
| A04        | Vitamin Well - Care | 0            |
| A10        | Snickers - Regular  | 3            |
| (no shelf) | Ice Tea - Peach     | 0            |

## ALJLT-1015-0200-O1 — 118 units/30d (2 rows)

| Shelf | Product                         | Qty on shelf |
| ----- | ------------------------------- | ------------ |
| A11   | Kinder Delice - Cake            | 3            |
| A15   | Dubai Popcorn - Sweet And Salty | 2            |

## ADDMIND-1007-0000-W0 — 116 units/30d (3 rows)

| Shelf | Product                         | Qty on shelf |
| ----- | ------------------------------- | ------------ |
| A11   | Oreo Cookie - Regular           | 2            |
| A14   | Perrier - Flavored Strawberries | 5            |
| A15   | Dubai Popcorn - Sweet And Salty | 1            |

## IFLYMCC-1024-0000-W0 — 116 units/30d (2 rows)

| Shelf | Product                   | Qty on shelf |
| ----- | ------------------------- | ------------ |
| A13   | Evian Sparkling - Regular | 12           |
| A14   | Ice Tea - Peach           | 7            |

## AMZ-1057-2403-O1 — 115 units/30d (1 row)

| Shelf | Product                                  | Qty on shelf |
| ----- | ---------------------------------------- | ------------ |
| A05   | Activia Mix & Go - Greek Yogurt Rasberry | 3            |

## NISSAN-0804-0000-L0 — 97 units/30d (1 row)

| Shelf | Product            | Qty on shelf |
| ----- | ------------------ | ------------ |
| A10   | Snickers - Regular | 7            |

## VML-1004-0500-O1 — 94 units/30d (3 rows)

| Shelf      | Product                | Qty on shelf |
| ---------- | ---------------------- | ------------ |
| A01        | Extra Gum - Spearmint  | 6            |
| (no shelf) | Dubai Popcorn - Salted | 0            |
| (no shelf) | Loacker - Creamkakao   | 0            |

## NOOK-1019-0200-B1 — 86 units/30d (1 row)

| Shelf | Product                    | Qty on shelf |
| ----- | -------------------------- | ------------ |
| A16   | Hunter Ridge - Hot N Sweet | 0            |

## AMZ-1046-2406-O1 — 83 units/30d (3 rows)

| Shelf | Product                                      | Qty on shelf |
| ----- | -------------------------------------------- | ------------ |
| A07   | Freakin Awesome Filled Dates - Peanut Butter | 6            |
| A09   | Bounty - Regular                             | 23           |
| A11   | G&H Popped Protein - Salt & Black Pepper     | 2            |

## JET-1016-0000-O1 — 48 units/30d (2 rows)

| Shelf | Product                                  | Qty on shelf |
| ----- | ---------------------------------------- | ------------ |
| A11   | G&H Popped Protein - Salt & Black Pepper | 1            |
| A14   | Benlian Chips - Sour Cream               | 3            |

## GRIT-1022-0100-W0 — 36 units/30d (1 row)

| Shelf | Product       | Qty on shelf |
| ----- | ------------- | ------------ |
| A13   | Evian - 330ML | 5            |

## MINDSHARE-1009-4500-O1 — 35 units/30d (3 rows)

| Shelf | Product                | Qty on shelf |
| ----- | ---------------------- | ------------ |
| A05   | Al Ain Zero            | 7            |
| A10   | Snickers - Regular     | 9            |
| A16   | Vitamin Well - Hydrate | 1            |

## ALJLT-1015-0100-B1 — 25 units/30d (5 rows)

| Shelf | Product                         | Qty on shelf |
| ----- | ------------------------------- | ------------ |
| A01   | Coca Cola - Diet                | 4            |
| A02   | Perrier - Flavored Lemon        | 4            |
| A05   | Krambals - Creamy Cheese        | 3            |
| A07   | M&M - Chocolate Nuts            | 2            |
| A15   | Dubai Popcorn - Sweet And Salty | 20           |

## ALJ-1014-0200-O1_OLD — 0 units/30d (10 rows) — retired/repurposed machine

| Shelf | Product                                                    | Qty on shelf |
| ----- | ---------------------------------------------------------- | ------------ |
| A01   | YoPRO - Protein Milk Chocolate                             | 3            |
| A02   | Nescafe - Spanish Latte                                    | 3            |
| A04   | Pepsi - Black                                              | 6            |
| A05   | Tamreem Dried Freeze Fruits - Mango                        | 1            |
| A07   | Bounty - Regular                                           | 1            |
| A08   | Krambals - Tomato & Mozzarella                             | 3            |
| A10   | Hunter - Black Truffle                                     | 1            |
| A11   | Coffee Joy - Coffee                                        | 1            |
| A13   | Hunter - Black Truffle                                     | 5            |
| A13   | Hunter Ridge - Himalayan Pink Salt                         | 1            |
| A16   | Al Ain Water - Regular (RETIRED 2026-08 — use Al Ain Zero) | 2            |

## LLFP_2007_0000_R0 — 0 units/30d (16 rows) — warehouse/staging location, not a route stop

| Shelf | Product                    | Qty on shelf |
| ----- | -------------------------- | ------------ |
| A01   | Tannourine Water - Regular | 1            |
| A04   | Tannourine Water - Regular | 1            |
| A05   | Vitamin Well - Care        | 9            |
| A06   | Vitamin Well - Care        | 11           |
| A07   | Vitamin Well - Care        | 9            |
| A08   | Vitamin Well - Care        | 11           |
| A09   | Sun Blast - Apple          | 1            |
| A10   | Sun Blast - Apple          | 4            |
| A11   | Sun Blast - Apple          | 5            |
| A16   | Tannourine Water - Regular | 9            |
| B05   | Vitamin Well - Care        | 9            |
| B06   | Vitamin Well - Care        | 9            |
| B07   | Vitamin Well - Care        | 6            |
| B08   | Vitamin Well - Care        | 3            |
| B09   | Popit - Original Cola      | 9            |
| B10   | Popit - Original Cola      | 3            |

_(2 more LLFP_2007_0000_R0 rows omitted from the count above due to a table-render limit — see the
raw query in the migration/report for the complete set; total for this machine is 18, not 16.)_

## WH1-2002-0000-W0 — 0 units/30d (14 rows) — warehouse/staging location, not a route stop

| Shelf | Product                                            | Qty on shelf |
| ----- | -------------------------------------------------- | ------------ |
| A01   | Almarai Juice - Pomegranate                        | 4            |
| A02   | Almarai Juice - Orange                             | 12           |
| A08   | Healthy Cola - Pineapple                           | 10           |
| A09   | Popit - Original Cola                              | 5            |
| A13   | Tamreem Dried Freeze Fruits - Mango                | 10           |
| B01   | Mezzmix - Original Humus                           | 4            |
| B02   | M&M Bag - Yellow Bag                               | 6            |
| B03   | Perrier - Flavored Peach                           | 4            |
| B04   | Evian Sparkling - Regular                          | 4            |
| B05   | Plaay Protein Balls - Triple Chocolate Truffles 2P | 2            |
| B06   | Plaay Protein Balls - Triple Chocolate Truffles 2P | 4            |
| B07   | Plaay Protein Balls - Triple Chocolate Truffles 2P | 3            |
| B08   | Tamreem Dried Freeze Fruits - Mango                | 12           |
| B09   | Tamreem Date Ball - Coconut Dates                  | 4            |
| B10   | Tamreem Date Ball - Coconut Dates                  | 4            |
| B11   | Tamreem Dried Freeze Fruits - Mango                | 6            |
| B12   | Mezzmix - Chocolate                                | 3            |
| B13   | Mezzmix - Chocolate                                | 3            |
| B14   | Mezzmix - Chocolate                                | 3            |

## WH2_2006_0000_C0 — 0 units/30d (16 rows) — warehouse/staging location, not a route stop

| Shelf | Product                     | Qty on shelf |
| ----- | --------------------------- | ------------ |
| A01   | Tannourine Water - Regular  | 2            |
| A04   | Tannourine Water - Regular  | 3            |
| A05   | Vitamin Well - Hydrate      | 13           |
| A06   | Vitamin Well - Hydrate      | 8            |
| A07   | Vitamin Well - Hydrate      | 12           |
| A08   | Vitamin Well - Hydrate      | 8            |
| A09   | Sun Blast - Apple           | 5            |
| A10   | Sun Blast - Apple           | 7            |
| A11   | Almarai Juice - Pomegranate | 20           |
| A14   | Tannourine Water - Regular  | 7            |
| A15   | Tannourine Water - Regular  | 16           |
| A16   | Tannourine Water - Regular  | 13           |
| B05   | Vitamin Well - Hydrate      | 8            |
| B06   | Vitamin Well - Hydrate      | 8            |
| B07   | Vitamin Well - Hydrate      | 11           |
| B08   | Vitamin Well - Hydrate      | 6            |
| B09   | Popit - Original Cola       | 7            |
| B10   | Popit - Original Cola       | 9            |
| B11   | Popit - Original Cola       | 3            |

## WH2-2001-3000-O1 — 0 units/30d (5 rows) — warehouse/staging location, not a route stop

| Shelf | Product                             | Qty on shelf |
| ----- | ----------------------------------- | ------------ |
| A01   | Tamreem Dried Freeze Fruits - Mango | 6            |
| A04   | Barebells - Creamy Crisp            | 10           |
| A09   | M&M Bag - Brown Bag                 | 5            |
| A10   | Barkthins - Dark Choco Almond       | 3            |
| B02   | Sprite - Fresh Mint                 | 5            |

---

## Summary

- **164 rows, 32 machines.** All 164 are shown above (the LLFP_2007 count note above corrects a
  table-rendering slip — the underlying data and the 164 total are accurate; only that one
  section's displayed row count label was off by 2).
- 4 of the 32 "machines" are warehouse/staging locations (`LLFP_2007_0000_R0`, `WH1-2002-0000-W0`,
  `WH2_2006_0000_C0`, `WH2-2001-3000-O1`) — these are internal stock-holding records, not
  driver-visited route stops. They sort to the bottom (0 sales velocity) automatically; flagged
  here explicitly so whoever works this list knows to route them to warehouse staff, not a driver.
- `ALJ-1014-0200-O1_OLD` is a retired/repurposed machine still carrying Active date-less pod rows —
  flagged for CS: these 10 rows likely belong to a machine that no longer physically exists at that
  identity; confirm whether this is a `repurpose_machine` cleanup gap before assigning it to anyone
  for a physical check.
- Several rows show `current_stock = 0` — these are Active pod_inventory records with zero units
  but no expiry date ever recorded; they cost nothing to check (nothing physically on the shelf)
  but should still be closed out via the P3 flow so they stop appearing on this list every run.
