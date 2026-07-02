# Refill shorthand → canonical product alias table

Single source of truth for resolving Simran's refill-log shorthand to real
`boonz_products.boonz_product_name`. Built 2026-05-31, validated against the live
catalog (300 boonz products). **No fuzzy matching at write time** — every doc line
resolves through this table; anything not here HALTS for CS/Simran.

Legend: ✓ exact catalog match · ⚠ context-dependent (two real variants exist) ·
❓ GAP — no clean match, ask Simran.

## Confectionery / bars

| Shorthand                             | Canonical boonz name                                                  |
| ------------------------------------- | --------------------------------------------------------------------- |
| Snickers                              | Snickers - Regular ✓                                                  |
| Mars                                  | Mars - Regular ✓                                                      |
| Twix                                  | Twix - Regular ✓                                                      |
| Bounty                                | Bounty - Regular ✓                                                    |
| KitKat                                | Nestle Kit-kat - Regular ✓                                            |
| Galaxy chocolate                      | Galaxy - Milk Chocolate ✓                                             |
| Delice Cake / Delice                  | Kinder Delice - Cake ✓                                                |
| Kinder Bueno                          | Kinder Bueno - Hazelnut ✓                                             |
| Oreo / Oreo Regular                   | Oreo Cookie - Regular ✓                                               |
| Sabahoo                               | Sabahoo - Chocolate ✓ (default; Butter/Fruit Slice also exist)        |
| Caramel Cashew                        | Barebells - Caramel Cashew ✓                                          |
| Cookies and Cream                     | Barebells - Cookies And Cream ✓                                       |
| Salty Peanut (Barebells)              | Barebells - Salty Peanut ✓                                            |
| Be Kind Cluster PB / Hazelnut / Dark  | Be-kind Cluster - Peanut Butter / Hazelnut / Dark Chocolate ✓         |
| Be Kind Bar PB / Dark                 | Be-kind Bar - Peanut Butter / Dark Chocolate ✓                        |
| Be Kind Caramel Sea Salt              | ❓ closest = Be-kind Bar - Almond & Sea Salt — CONFIRM                |
| McVities Mini Dark / Milk             | McVities Digestive - Mini Dark / Mini Milk Chocolate ✓                |
| Nibbles Caramel / Dark / Milk         | McVities Digestive Nibbles - Choco Caramel / Dark / Milk Chocolate ✓  |
| Loacker Cream Kakao                   | Loacker - Creamkakao ✓                                                |
| Loacker Napolitaner                   | Loacker - Napolitaner ✓ (NOT Quadratini — decommissioned)             |
| Loacker Vanilla                       | Loacker - Vanille ✓                                                   |
| Leibniz Cocoa / Milk Honey / Original | Leibniz Zoo - Cocoa / Mik and Honey / Regular ✓                       |
| M&M Chocolate / Chocolate Nuts        | M&M - Chocolate Nuts ✓                                                |
| M&M Peanut                            | ❓ no peanut variant — ask Simran                                     |
| Tamreem Dates Coconut                 | Tamreem Date Ball - Coconut Dates ✓                                   |
| Tamreem Dried Mango / Peach           | Tamreem Dried Freeze Fruits - Mango / Peach ✓                         |
| Organic rice milk / dark chocolate    | Organic Larder - Rice Cake Milk / Dark Chocolate ✓                    |
| Santiveri Coco Quinoa                 | Santiveri - Coco Quinoa ✓                                             |
| Nutella / Nutella Biscuit T12         | ❓ Nutella - Biscuit T12 (also B Ready, Biscuit T3) — CONFIRM variant |
| Yan Yan Strawberry / Chocolate        | Yan Yan - Flavored Strawberries / Milk Chocolate ✓                    |

## Chips / savoury

| Shorthand                                      | Canonical boonz name                                                       |
| ---------------------------------------------- | -------------------------------------------------------------------------- |
| Hot Chili (Hunter)                             | Hunter - Hot Chili ✓ (NOT Hunter Ridge)                                    |
| Black Truffle                                  | Hunter - Black Truffle ✓                                                   |
| Hunter Sea Salt / Sea Salted                   | Hunter - Sea Salted ⚠ (Hunter Ridge - Sea Salted also exists)              |
| Hot & Sweet                                    | Hunter Ridge - Hot N Sweet ⚠ (Hunter - Hot N Sweet also exists)            |
| Himalayan Pink                                 | Hunter Ridge - Himalayan Pink Salt ✓                                       |
| Hunter Ridge Sour Cream                        | Hunter Ridge - Sour Cream ✓                                                |
| Krambals Tomato / Green Olives / Creamy Cheese | Krambals - Tomato & Mozzarella / Green Olives & Sea Salt / Creamy Cheese ✓ |
| Zigi Sweet Chili                               | Zigi - Sweet Chilli ✓                                                      |
| Zigi Salt                                      | Zigi - Sea Salted ✓                                                        |
| Salt Popcorn / Popcorn Salt                    | Dubai Popcorn - Salted ⚠ (VOX Popcorn - Salt also exists; AMZ=Dubai)       |
| Butter Popcorn / Popcorn Butter                | Dubai Popcorn - Butter ✓                                                   |
| Smart Gourmet (Classic)                        | Smart Gourmet - Classic Humus ✓                                            |
| Soul Pantry Peri Peri                          | Soul Pantry - Fiery Peri Peri Protein Chips ✓                              |
| G&H Pop Chips Sweet BBQ                        | ❓ no G&H brand in catalog — ask Simran                                    |

## Drinks

| Shorthand                    | Canonical boonz name                          |
| ---------------------------- | --------------------------------------------- |
| Pepsi Regular / Black        | Pepsi - Regular / Black ✓                     |
| Pepsi Diet                   | ❓ no Diet/Zero Pepsi — ask Simran            |
| Coca Cola Regular / Zero     | Coca Cola - Regular / Zero ✓                  |
| Mountain Dew                 | Mountain Dew - Regular ✓                      |
| Aquafina                     | Aquafina - Regular ✓                          |
| Evian 1L                     | Evian - 1L ✓                                  |
| Perrier Regular / Grapefruit | Perrier - Regular / Flavored Grapefruit ✓     |
| Red Bull / RedBull Diet      | Red Bull - Regular / Diet ✓                   |
| Pocari                       | Pocari Sweat - Regular ✓                      |
| Gatorade Blue                | Gatorade Cool - Blue Raspberry ✓              |
| Gatorade Zero                | Gatorade Zero - Cool Blue ✓                   |
| Ice Tea Peach                | Ice Tea - Peach ✓                             |
| Ice Tea Lemon                | ❓ no Lemon variant (only Peach) — ask Simran |
| Sun Blast Apple / Cherry     | Sun Blast - Apple / Cherry & BlackCurrant ✓   |
| Popit Orange Squeeze         | Popit - Orange Squeeze ✓                      |
| Poppit mix                   | ❓ which Popit variant(s)? — ask Simran       |
| Nescafe Mocha / Cappuccino   | Nescafe - Mocha / Cappucino Iced Coffee ✓     |
| Starbucks Diet               | Starbucks - Double Shot Espresso Diet ✓       |
| Eviron Wellness              | Eviron - Wellness Drink ✓                     |
| Skittles                     | Skittles Bag - Regular Large ✓ (VOX-sourced)  |

## Vitamin Well / yogurt

| Shorthand                | Canonical boonz name                                                                   |
| ------------------------ | -------------------------------------------------------------------------------------- |
| VW Care / Well Care      | Vitamin Well - Care ✓                                                                  |
| VW Upgrade               | Vitamin Well - Upgrade ✓                                                               |
| VW Antioxidant           | Vitamin Well - Antioxidant ✓                                                           |
| VW Reload                | Vitamin Well - Reload ✓                                                                |
| VW Zero Peach / VW Peach | Vitamin well - Zero peach ✓                                                            |
| Yo Pro Strawberry        | YoPRO - Protein Milk Strawberry ✓                                                      |
| Activia Honey            | ❓ closest = Activia Mix & Go - Greek Yogurt Honey & Oats — CONFIRM (also past-expiry) |

---

## GAPS — RESOLVED 2026-05-31 by CS

1. **Pepsi Diet** (MP 0719) → Pepsi - Black
2. **M&M Peanut** (MP 0719) → M&M - Chocolate Nuts
3. **Ice Tea Lemon** (VOX 0797) → Ice Tea - Peach
4. **G&H Pop Chips Sweet BBQ** (MC-2004) → G&H Popped Chips - Sweet BBQ (verify exact catalog name)
5. **Nutella** (27/05) → Nutella - Biscuit T12
6. **Poppit mix** (Activate 0817) → even split: Popit Orange Squeeze / Lemon & Lime / Original Cola
7. **Be Kind Caramel Sea Salt** (MC-2004) → Be-kind Bar - Almond & Sea Salt
8. **Activia Honey** (OMDBB) → SKIP, past-expiry (01/02/2026); note in log, no pod credit

## Context ambiguities (two real variants exist — pick by machine)

- **Hunter Sea Salt**: default Hunter - Sea Salted, but Hunter Ridge - Sea Salted exists.
- **Hot & Sweet**: Hunter Ridge - Hot N Sweet vs Hunter - Hot N Sweet.
- **Popcorn Salt/Butter**: Dubai Popcorn for AMZ/office; VOX Popcorn for VOX venues — resolve per machine planogram.

_Built 2026-05-31. Resolution by name; boonz_product_id pinned at write time per line._
