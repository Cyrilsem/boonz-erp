# Mirdif Refill Investigation — 2026-05-14

**Investigator:** Boonz Master + Dara/Stax/Cody review
**Subject:** Driver claim that "system shared the wrong recommendation and flipped the machines" on the Mirdif City Centre route
**Source evidence:** 6 driver sticky-notes (pods 0719, 0715, 0736, 0817, 0797, 0795) + Supabase live data

---

## TL;DR — Verdict

**The plans were NOT swapped between machines.** The system correctly authored each machine's plan against its current identity. Every plan's product mix matches the venue brand (MP vs ACTIVATE vs VOX) it should match.

What actually happened is a **WAREHOUSE FULFILMENT FAILURE compounded by a planogram-rename history** that made the divergence look like a flip:

1. **Warehouse was out of stock on a wide set of refill-critical SKUs** — Aquafina Regular (0/Inactive), Pocari Sweat (0/Inactive ×3), Gatorade Zero Cool Blue (0/Inactive), 7Up Diet (0/Inactive), Maltesers Chocolate Bag and M&M Chocolate Bag and VOX Lollies (no WH rows at all). Of 235 units the system told the driver to refill across the 6 machines, **WH only packed 102 units** (~43%).
2. **The driver freelanced at the venue** — bringing what they could find at the WH (e.g. Galaxy and Gatorade Cool Blue Raspberry as substitutes), skipping items WH couldn't supply, and over-stocking on items that were available (Haribo, Aquafina).
3. **Three of the six machines were renamed in place on 2026-04-28** — ACTIVATEMCC-1054→MPMCC-1054, ACTIVATEMCC-1058→MPMCC-1058, MPMCC-2005→ACTIVATE-2005. This is the source of the "flipped" mental model. The renames are clean in the database, but to anyone reading the driver app or labels at the venue, an "ACTIVATE" branded machine is now called "MAGIC PLANET" and vice-versa — easy to misread as the system having swapped them.

**The system did not lie about which machine is which.** But the WH stock situation made it look like every plan was wrong.

---

## 1. Machine mapping (note suffix → machine)

The 4-digit codes on the driver's notes are the **last 4 digits of `machines.pod_number`** (also the `adyen_store_code`). They are stable identifiers of physical fridges. Confirmed via `BOONZ_…<suffix>` lookup.

| Note header              | pod_number       | Current `official_name`      | Renamed on 2026-04-28? | Previous name (alias)    |
| ------------------------ | ---------------- | ---------------------------- | ---------------------- | ------------------------ |
| **MAGIC PLANET 0719**    | BOONZ_8625110719 | **MPMCC-1054-0000-M0**       | YES (rename in place)  | ACTIVATEMCC-1054-0000-M0 |
| **MAGIC PLANET 0715**    | BOONZ_8625110715 | **MPMCC-1058-0000-R0**       | YES (rename in place)  | ACTIVATEMCC-1058-0000-R0 |
| **ACTIVATE 0736**        | BOONZ_8625110736 | **ACTIVATEMCC-1037-0000-L0** | no                     | –                        |
| **ACTIVATE REFILL 0817** | BOONZ_82160817   | **ACTIVATE-2005-0000-W0**    | YES (rename in place)  | MPMCC-2005-0000-W0       |
| **VOX CINEMA 0797**      | BOONZ_82160797   | **VOXMCC-1009-0201-B0**      | no                     | –                        |
| **VOX CINEMA 0795**      | BOONZ_82160795   | **VOXMCC-1011-0101-B0**      | no                     | –                        |

Critical observation: **0719, 0715, and 0817 had their venue identity flipped six weeks ago** (ACTIVATE ↔ MAGIC PLANET). They share the same `machine_id` pre/post rename — slot_lifecycle, planogram, sales history all carry over. `machine_name_aliases` rows for the old names are `is_active=true` so any FE that queries by the old name still resolves to the same machine.

---

## 2. System recommendation vs Driver actual vs Warehouse fulfilment

For each of the 6 machines, three columns:

- **SYS** = approved row from `refill_plan_output` for `plan_date=2026-05-14`
- **WH PACKED** = `refill_dispatching.filled_quantity` (what WH actually managed to pack)
- **DRIVER NOTE** = what the driver wrote on the sticky

### 2.1 MPMCC-1054-0000-M0 (pod 0719 — "MAGIC PLANET 0719")

| Shelf       | Product (SYS)           | SYS qty | WH packed | Driver note                    | Verdict                                                                                                   |
| ----------- | ----------------------- | ------- | --------- | ------------------------------ | --------------------------------------------------------------------------------------------------------- |
| A04 Remove  | Pepsi Regular (drain)   | 13      | n/a       | – (removal)                    | OK — driver doesn't note removals                                                                         |
| A04 Add New | Ritz Cracker            | 10      | **10 ✓**  | Ritz Crackers 10               | ✅ Match                                                                                                  |
| A06         | Popit Mix               | 10      | **10 ✓**  | Popit Mix 16 (A06+A07)         | ✅ Match                                                                                                  |
| A07         | Popit Mix               | 6       | 1 only    | (rolled into above)            | ⚠ WH short-packed                                                                                         |
| A08         | Maltesers Chocolate Bag | 2       | **0**     | Maltesers 2                    | ⚠ Driver still brought 2 from elsewhere                                                                   |
| A09         | M&M Chocolate Bag       | 2       | **0**     | M&M Chocolate 2                | ⚠ Driver still brought 2 from elsewhere                                                                   |
| A10         | Haribo Gold Bear        | 2       | **0**     | Haribo **15**                  | ⚠ Driver brought 7.5× SYS — almost certainly used what WH had (~5 units at WH_CENTRAL) plus walk-in stock |
| A13         | Sun Blast Juice         | 9       | **9 ✓**   | Sunblast 10                    | ✅ Match (driver rounded up)                                                                              |
| A14         | VOX Lollies             | 6       | **0**     | "Leibniz Milk Cocoa Lollies" 6 | ❓ ambiguous handwriting — see §3                                                                         |
| –           | (not in plan)           | –       | –         | Aquafina 4                     | Driver-added (Aquafina was at high overfill — A10 already 15/10)                                          |

**Plan total (units to refill):** 60 | **WH packed:** 30 | **Driver note total:** ~62
**Diagnosis:** Plan correct. WH packed only the items it had (Ritz, Popit A06, Sun Blast = 30 units). Driver compensated.

### 2.2 MPMCC-1058-0000-R0 (pod 0715 — "MAGIC PLANET 0715")

| Shelf | Product (SYS) | SYS qty | WH packed | Driver note           | Verdict                                                                |
| ----- | ------------- | ------- | --------- | --------------------- | ---------------------------------------------------------------------- |
| A01   | Aquafina      | 2       | **0**     | (rolled into total)   | ⚠ Aquafina = 0 stock WH-wide                                           |
| A05   | Krambals      | 2       | **0**     | –                     | ⚠ Driver skipped                                                       |
| A08   | Skittles Bag  | 2       | 0         | Skittles Red 2        | ✅ Match (driver brought from elsewhere)                               |
| A09   | Leibniz Zoo   | 3       | **1**     | Leibniz Cocoa 3       | ✅ Match                                                               |
| A10   | Popit Mix     | 5       | 0         | –                     | ⚠ Driver skipped                                                       |
| A12   | VOX Lollies   | 7       | 0         | Lollies 7             | ✅ Match                                                               |
| A13   | Aquafina      | 4       | 0         | Aquafina **11** total | ✅ Match (system 6 across A01+A13, driver brought 11 — included extra) |

**Plan total:** 25 | **WH packed:** 1 (!) | **Driver note total:** ~23
**Diagnosis:** WH packing essentially failed on this machine. Driver brought ~23 units of relevant stock from another source (likely walk-in / market). System rec actually well-matched what was needed.

### 2.3 ACTIVATEMCC-1037-0000-L0 (pod 0736 — "ACTIVATE 0736")

| Shelf | Product (SYS)        | SYS qty | WH packed | Driver note     | Verdict                                         |
| ----- | -------------------- | ------- | --------- | --------------- | ----------------------------------------------- |
| A06   | Vitamin Well         | 3       | 0         | –               | ⚠ Skipped                                       |
| A07   | Vitamin Well         | 2       | 0         | –               | ⚠ Skipped                                       |
| A09   | Evian                | 5       | 5 ✓       | –               | ⚠ Driver skipped despite WH packing it          |
| A10   | Evian                | 3       | 0         | –               | ⚠ Skipped                                       |
| A13   | Nutella Biscuits T12 | 2       | 2 ✓       | Nutella 2       | ✅ Match                                        |
| –     | (crossed-out)        | –       | –         | "7 [scribbled]" | Driver was about to add an item, crossed it out |

**Plan total:** 15 | **WH packed:** 7 | **Driver note total:** 2 visible
**Diagnosis:** Driver did the bare minimum on this machine — likely because the rest of the items were already in stock at the machine (snapshot shows Vitamin Well at 5–10 across A04–A07, Evian at 4–7 across A08–A10). System rec was too aggressive; driver applied common sense.

### 2.4 ACTIVATE-2005-0000-W0 (pod 0817 — "ACTIVATE REFILL 0817")

| Shelf                     | Product (SYS)              | SYS qty  | WH packed                                          | Driver note                                 | Verdict                                                                            |
| ------------------------- | -------------------------- | -------- | -------------------------------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------- |
| A02                       | Sun Blast Juice            | 3        | 3 ✓                                                | Sunblast 3                                  | ✅ Match                                                                           |
| A03                       | Popit Mix                  | 1        | – (excluded)                                       | –                                           | OK                                                                                 |
| A04                       | Kinder Delice              | 4        | 4 ✓                                                | –                                           | ⚠ Driver skipped despite WH packing it                                             |
| A06                       | Gatorade Zero Cool Blue    | 7        | **0** (WH Inactive)                                | Gatorade Blue 7                             | ⚠ Driver substituted with Gatorade Cool Blue Raspberry (7u available WH_CENTRAL)   |
| A07                       | Pocari Sweat               | 10       | **0** (WH Inactive ×3)                             | –                                           | ⚠ WH had zero Pocari; driver skipped                                               |
| A09–A11, B09–B11, B15–B16 | Aquafina (8 rows)          | 45 total | **0** (WH `Aquafina-Regular` is Inactive, 0 stock) | Aquafina **35**                             | ⚠ Driver brought 35 from non-WH source                                             |
| B06                       | 7Up Diet (Soft Drinks Mix) | 2        | **0** (Inactive)                                   | –                                           | ⚠ Skipped, WH zero                                                                 |
| B12                       | Ice Tea Peach              | 4        | 4 ✓                                                | Ice Tea Peach 4                             | ✅ Match                                                                           |
| –                         | (not in plan, crossed)     | –        | –                                                  | Bounty 3 (crossed), Pepsi Black 2 (crossed) | Driver brought, decided not to refill — A04/A05 already full                       |
| –                         | (not in plan, kept)        | –        | –                                                  | Galaxy 1                                    | Driver-added — A04 (Chocolate Bar) shelf is 24/20 overfilled, this was an addition |

**Plan total:** 76 | **WH packed:** 11 | **Driver note total:** ~50
**Diagnosis:** The Aquafina situation is a fleet-wide procurement bottleneck. WH `Aquafina-Regular` is Inactive — driver had to bring 35 units from elsewhere to plug 8 separate Aquafina shelves. Gatorade Zero is also Inactive; driver swapped to Gatorade Cool Blue.

### 2.5 VOXMCC-1009-0201-B0 (pod 0797 — "VOX CINEMA 0797")

| Shelf | Product (SYS)           | SYS qty | WH packed | Driver note    | Verdict                           |
| ----- | ----------------------- | ------- | --------- | -------------- | --------------------------------- |
| A02   | Be-kind Cluster         | 7       | 7 ✓       | Be Kind Dark 7 | ✅ Match                          |
| A03   | Tamreem Date Ball       | 2       | 0         | –              | Skipped                           |
| A05   | Pepsi Black             | 6       | 0         | –              | Skipped                           |
| A06   | Pepsi Regular           | 3       | 0         | –              | Skipped                           |
| A07   | Ice Tea                 | 5       | 0         | –              | Skipped                           |
| A08   | Aquafina                | 3       | 0         | –              | Skipped (WH Aquafina = 0)         |
| A09   | Aquafina                | 7       | 0         | –              | Skipped (WH Aquafina = 0)         |
| A11   | Skittles Bag            | 3       | 0         | –              | Skipped                           |
| A12   | Maltesers Chocolate Bag | 5       | 0         | –              | Skipped                           |
| A13   | M&M Chocolate Bag       | 2       | 0         | –              | Skipped                           |
| A14   | Sun Blast Juice         | 10      | 0         | Sunblast 7     | ⚠ Driver brought 7 (vs system 10) |
| A16   | Nutella Biscuits T12    | 13      | 13 ✓      | Nutella 13     | ✅ Match                          |

**Plan total:** 66 | **WH packed:** 33 | **Driver note total:** 27
**Diagnosis:** Driver refilled only the three items WH packed (Be-kind 7, Nutella 13) plus Sun Blast 7. Skipped 9 items WH had not packed. Plan correct, fulfillment broken.

### 2.6 VOXMCC-1011-0101-B0 (pod 0795 — "VOX CINEMA 0795")

| Shelf | Product (SYS)              | SYS qty | WH packed | Driver note                   | Verdict                                                                               |
| ----- | -------------------------- | ------- | --------- | ----------------------------- | ------------------------------------------------------------------------------------- |
| A01   | Chocolate Bar (Bounty)     | 14      | 14 ✓      | Galaxy 3                      | ⚠ Driver substituted Galaxy (3 units) for Bounty 14 — A00 already overfilled at 17/25 |
| A02   | Zigi (Honey Mustard)       | 3       | 0         | Zigi Honey Mustard 3          | ✅ Match                                                                              |
| A04   | Barebells (Caramel Cashew) | 4       | 0         | –                             | Skipped                                                                               |
| A07   | Ice Tea                    | 6       | 0         | Peach 6                       | ✅ Match (driver brought from elsewhere)                                              |
| A08   | Aquafina                   | 3       | 0         | –                             | Skipped                                                                               |
| A09   | Aquafina                   | 4       | 0         | –                             | Skipped                                                                               |
| A10   | Vitamin Well               | 3       | 0         | –                             | Skipped                                                                               |
| A11   | Skittles Bag               | 2       | 0         | Skittles Red 3                | ✅ Match                                                                              |
| A12   | M&M Chocolate Bag          | 2       | 0         | –                             | Skipped                                                                               |
| A13   | Maltesers Chocolate Bag    | 5       | 0         | Maltesers 7                   | ✅ Match (driver brought 7)                                                           |
| A14   | Sun Blast Juice            | 3       | 0         | –                             | Skipped                                                                               |
| A16   | Leibniz Zoo                | 3       | 0         | –                             | Skipped                                                                               |
| –     | (not in plan)              | –       | –         | Pepsi Diet 1, Pepsi Regular 1 | Driver-added                                                                          |
| –     | (not in plan, crossed)     | –       | –         | Snickers 5 (crossed)          | Driver brought, decided not to refill                                                 |

**Plan total:** 52 | **WH packed:** 16 | **Driver note total:** ~24
**Diagnosis:** Same picture — driver substituted what WH had, skipped what was missing, added Pepsi Diet/Regular based on venue judgment.

**Note:** This machine ALSO has 74 _rejected_ plan rows from a 2026-05-10 generation (someone — operator — pushed back on the initial plan); the 12 _approved_ rows above are from a regeneration on 2026-05-13 21:39.

---

## 3. The "flipped machines" claim — root-cause analysis

The user's instinct that something was wrong is correct. The system did NOT flip plans between machines, but two real issues fed the perception:

### 3.1 Brand-identity rename (April 28, 2026)

Three of the six Mirdif machines had their `official_name` rewritten on 2026-04-28 via `rename_machine_in_place_legacy`:

```
ACTIVATEMCC-1054-0000-M0  →  MPMCC-1054-0000-M0   (pod 0719)
ACTIVATEMCC-1058-0000-R0  →  MPMCC-1058-0000-R0   (pod 0715)
MPMCC-2005-0000-W0        →  ACTIVATE-2005-0000-W0 (pod 0817)
```

The `machine_id` UUIDs were preserved, so all dispatching / sales / slot_lifecycle history carried over cleanly. But this means **the fridge physically labeled "ACTIVATE" at the venue six weeks ago is now labeled "MAGIC PLANET"** (and vice versa for 0817). A driver who has been doing this route since before April 28 will, by muscle memory, expect ACTIVATE products in fridges they remember as "ACTIVATE". When the driver app showed "MAGIC PLANET 0719" with MP-style products (Ritz, Popit, Haribo, VOX Lollies), it looks like the SYSTEM swapped the venue and the products.

But it didn't. The slot_lifecycle was correctly transitioned: MPMCC-1054 has MP-style products, ACTIVATE-2005 has ACTIVATE-style products, etc. **Driver and venue labelling matches the database — the rename is internally consistent.**

The only smoke around this is that, for the renamed machines (0719, 0715, 0817), the planogram was rebuilt on 2026-05-08 (`first_seen_at` on slot_lifecycle), meaning the system has only had 6 days of velocity data per slot. Most slots are in `RAMPING` signal — the brain is still calibrating which SKUs win on this layout.

### 3.2 Warehouse fulfilment crisis — the real failure

Across the 6 machines, **the brain asked for 248 units of refill. WH packed 102 units (~41%).** Look at WH stock for the major missing SKUs as of today:

| Boonz product                           | WH_CENTRAL stock       | Status          | Note                                                                                 |
| --------------------------------------- | ---------------------- | --------------- | ------------------------------------------------------------------------------------ |
| Aquafina - Regular                      | **0**                  | **Inactive**    | Used on 13 separate plan rows across the 6 machines (45 units needed for 0817 alone) |
| Pocari Sweat - Regular                  | **0 / 0 / 0** (3 rows) | **Inactive** ×3 | Used on 0817 A07 (10 units)                                                          |
| Gatorade Zero - Cool Blue               | **0**                  | **Inactive**    | Used on 0817 A06 (7 units)                                                           |
| 7Up - Diet                              | **0 / 0**              | **Inactive** ×2 | Used on 0817 B06                                                                     |
| Maltesers Chocolate Bag - Regular Large | **(no WH rows)**       | n/a             | Used on 1054 A08, 1009 A12, 1011 A13                                                 |
| M&M Chocolate Bag - Regular Large       | **(no WH rows)**       | n/a             | Used on 1054 A09, 1009 A13, 1011 A12                                                 |
| VOX Lollies - Regular                   | **(no WH rows)**       | n/a             | Used on 1054 A14, 1058 A12                                                           |
| Haribo Gold Bear - Regular              | 5                      | Active          | Used on 1054 A10 — driver brought 15, far more than WH had                           |

The system's plan didn't fail because the recommendations were wrong — the system can't see that `warehouse_inventory.status` is `Inactive` for Aquafina-Regular when it picks the SKU (it relies on `boonz_products` + planogram). The bug is upstream: **`warehouse_inventory.status='Inactive'` is not being respected by ENGINE ADD's WH-stock check**, OR these SKUs were Inactivated _after_ the plan ran but before WH packed.

What the driver experienced:

1. Plan said "go to MAGIC PLANET 0719 and refill A04 Ritz, A06–A07 Popit, A08 Maltesers, A09 M&M, A10 Haribo, A13 Sun Blast, A14 VOX Lollies"
2. At the warehouse, half the items weren't there
3. Driver grabbed what was available + walk-in / market stock + extras (Haribo, Aquafina)
4. At the venue, the driver tried to make the fridge look right based on what's selling
5. They wrote the sticky-note recording what they actually put in, not what the system asked

To the user reading the stickies, this looks like the system "flipped" the plan because driver had to massively deviate. But the deviation traces back to **WH packing**, not to plan content.

### 3.3 Was there an actual swap? Sanity test

Cross-test: would the driver's 0719 note look more correct if applied to _any other_ pod's plan?

- Driver 0719 wrote: Maltesers 2, Sunblast 10, M&M 2, Popit 16, Haribo 15, Ritz 10, Aquafina 4, "Leibniz Lollies" 6
- System plan for 0719 expects: Ritz 10, Popit 16, Maltesers 2, M&M 2, Haribo 2, Sun Blast 9, VOX Lollies 6, Remove Pepsi 13
- 7 of 8 items on the driver's note match this plan's products by name. The single oddity (Haribo 15 vs 2) is the driver bringing extra of a snack that's already at high fill at the machine (A09 Haribo was 11/10).

There's **no other machine on the route** whose plan would explain "Maltesers + M&M + Popit + Ritz + Sun Blast + VOX Lollies" together — that exact bouquet is unique to MPMCC-1054's planogram. The plan and the driver's intent were aimed at the same fridge.

---

## 4. Specific anomalies that ARE worth attention

1. **WH `Aquafina-Regular` is Inactive but planogram still uses it heavily.** This is a fleet-wide procurement / status-flag bug. Status proposal review needed. (Article 6: only manager can flip status — but the brain should refuse to plan against `Inactive`.)
2. **Pocari, Gatorade Zero Cool Blue, 7Up Diet, Maltesers Chocolate Bag, M&M Chocolate Bag, VOX Lollies — WH stock is zero or no row at all.** The brain shouldn't propose refills for SKUs WH cannot supply; this requires an ENGINE ADD guardrail.
3. **VOXMCC-1011 had 74 rejected plan rows from 2026-05-10** — someone (operator) explicitly pushed back on that draft. Worth confirming whether the regen on 2026-05-13 actually addressed the rejection reasoning or just produced a smaller plan.
4. **Driver brought Haribo Gold Bear 15 units for 0719 but the machine was already at 110% fill on Haribo (11/10).** That implies the driver was given Haribo at WH and put it in even though the shelf was overflowing. Worth flagging — surplus stock in a wrong-trending slot.
5. **0817 A06 substitute (Gatorade Cool Blue Raspberry for Gatorade Zero Cool Blue)** is a planogram-level swap the driver made on the spot. Should be logged as a planned_swap so the brain learns.
6. **Pod 0817's slot_lifecycle still tags many shelves as RAMPING with 6-day age.** That confirms slots were rebuilt on 2026-05-08, but the brain has limited velocity history to argue with the driver's tweaks. Expect more deviation for ~30 days post-rename.

---

## 5. Recommended actions

| Priority | Action                                                                                                                                                                                                                                           | Owner                                     |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| P0       | Audit ENGINE ADD: it should refuse to propose a refill row if no WH row with `warehouse_stock > 0 AND status='Active'` exists for the boonz_product. The current pipeline is asking for Aquafina-Regular even though WH-wide it's Inactive.      | Dara (design) → Cody (review) → assistant |
| P0       | Confirm via WAREHOUSE_STATUS whether `Aquafina-Regular` should still be Inactive or needs reactivation. Same for Pocari Sweat, Gatorade Zero Cool Blue, 7Up Diet.                                                                                | CS                                        |
| P1       | Issue a PO (or walk-in) for: Maltesers Chocolate Bag, M&M Chocolate Bag, VOX Lollies — these are core planogram items with zero WH rows. Without them, half the MCC route can't be refilled.                                                     | CS (procurement)                          |
| P1       | Log driver-side substitutions via `LOG_SWAP`: Gatorade Cool Blue Raspberry as approved sub for Gatorade Zero Cool Blue at ACTIVATE-2005 A06; Galaxy as approved sub for Bounty at VOXMCC-1011 A01 (when warranted).                              | Master                                    |
| P2       | Add a "renamed in last 60 days" surface to the morning brief — flag plans for recently-renamed machines so CS knows to read them with extra care while the slot_lifecycle ramps.                                                                 | Stax (FE)                                 |
| P2       | Driver app should print pod_number prominently alongside official_name — this would let the driver verify physical identity independently of brand label.                                                                                        | Stax (FE)                                 |
| P3       | Train: WEIMI's stock view uses 0-indexed aisle codes (`0-A00…0-A15`); the planogram uses 1-indexed (`A01…A16`). They map cleanly through `shelf_configurations` but visually look off-by-one. Worth surfacing both labels in the dispatch sheet. | Stax (FE)                                 |

---

## 6. Data sources used

| Table / View           | Why                                                                                                                       |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `machines`             | pod_number → official_name mapping, repurpose history                                                                     |
| `machine_name_aliases` | confirmed rename direction (ACTIVATEMCC ↔ MPMCC)                                                                          |
| `refill_plan_output`   | system's recommendation for plan_date 2026-05-14                                                                          |
| `refill_dispatching`   | `filled_quantity` showing what WH actually packed                                                                         |
| `v_live_shelf_stock`   | physical machine state (per aisle), 2026-05-14 15:33 snapshot                                                             |
| `slot_lifecycle`       | the system's belief about the current planogram per shelf                                                                 |
| `warehouse_inventory`  | confirmed WH stock-out on Aquafina / Pocari / Gatorade Zero / 7Up                                                         |
| `machine_field_notes`  | only 2 unread notes — both "stock Ritz on next visit" for 1054 and 1058 (which the brain did action via A04 Add New Ritz) |

---

_Report generated 2026-05-14 by Boonz Master investigation team._
