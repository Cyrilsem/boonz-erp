# Travel-Scope Guardrails

**Type:** Travel scope rules (where products can and cannot travel)  
**Read by:** Engine 2 (Relocation Planner), Engine C (Swap)  
**Last updated:** 2026-04-09  
**Owner:** CS (cyrilsem@gmail.com)

## Purpose

This file lists every rule about which products can be placed in which machines based on their source of supply or contractual sourcing. Unlike coexistence rules (which are about brand conflicts), travel-scope rules are about "this product is sourced through X and can only appear at X machines."

When Engine 2 considers relocating a product from one machine to another, it MUST check this file and skip any candidate destinations that violate travel scope. Engine C's swap scorer applies the same check when proposing replacement products for a slot.

## Rule 1 — VOX-locked products

**Applies to:** all products listed below, which are sourced through VOX and locked to VOX-group machines.

**Locked products (confirmed 2026-04-09):**

| Product name (as it appears in `goods_name_raw`) | Why it's locked                                                                                  |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| Aquafina                                         | Sourced by VOX even though it's a PepsiCo brand (which would otherwise be travelable to ADDMIND) |
| Maltesers Chocolate Bag                          | VOX-sourced (Mars)                                                                               |
| Skittles Bag                                     | VOX-sourced (Mars/Wrigley)                                                                       |
| VOX Cotton Candy                                 | VOX-branded, cinema concession product                                                           |
| VOX Lollies                                      | VOX-branded, cinema concession product                                                           |
| VOX Popcorn Caramel                              | VOX-branded, cinema concession product                                                           |
| VOX Popcorn Cheese                               | VOX-branded, cinema concession product                                                           |
| VOX Popcorn Salt                                 | VOX-branded, cinema concession product                                                           |

**Destination eligibility:** these products may ONLY be placed in machines where `venue_group = 'VOX'`. This includes VOXMCC, VOXMM, ACTIVATEMCC, MPMCC, IFLYMCC (future), SKYMCC (future), and any other machine tagged as VOX group.

**Naming convention:** any product whose `goods_name_raw` starts with `VOX ` (e.g., future `VOX Nachos`, `VOX Drink`, `VOX Slushie`) is automatically VOX-locked by default. This is a pattern-based rule so new VOX-branded SKUs don't require a guardrail update.

## Rule 2 — Explicit exclusions (not VOX-locked, despite appearance)

The following products are present in VOX-group machines today but are NOT travel-locked. They may be moved to any venue group where they fit (subject to coexistence rules).

| Product           | Rationale                                                                                                                                      |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| M&M Chocolate Bag | Not VOX-sourced. Mars brand, but flexible supply.                                                                                              |
| Pepsi Regular     | Widely available product, not VOX-locked. Note: Pepsi Regular may also travel to ADDMIND group, where Pepsi is the contractual beverage brand. |
| Sun Blast Juice   | Not VOX-sourced. Flexible supply.                                                                                                              |

These are called out explicitly because they appear in `v_live_shelf_stock` only in VOX machines today. Without this exclusion list, the refill engine might infer "only in VOX → must be VOX-locked" from the data and wrongly block them.

## Rule 3 — No other groups have travel-scope restrictions

- **ADDMIND group:** no locked products. Any product from the general catalog may travel to Addmind/Ush/Iris, subject to coexistence rule 1 (no Coca-Cola).
- **VML group:** no locked products.
- **WPP, OHMYDESK, INDEPENDENT:** no locked products.

Only VOX has a travel-scope constraint today. This may change as new supplier contracts get signed.

## How the engine applies this

Engine 2 pseudocode when evaluating whether product P can move to machine M:

Look up P in travel-scope.md Rule 1 (including the VOX- prefix pattern match).
If P is VOX-locked and M.venue_group != 'VOX': REJECT.
Look up P in travel-scope.md Rule 2.
If P is in the explicit exclusion list: PROCEED (no travel restriction from this file).
Otherwise: PROCEED to coexistence rules.

## Change log

- **2026-04-09** — File created during Phase 0 guardrail interview. VOX-locked product list confirmed from live data query: 8 products locked (3 third-party + 5 VOX-branded). Explicit exclusion list added for M&M, Pepsi Regular, Sun Blast Juice which appear in VOX-only positions today but are flexible.
