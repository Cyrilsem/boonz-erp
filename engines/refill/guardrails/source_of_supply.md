# Source of Supply — Decision

**Decided:** 2026-04-10 (CS-07 fast-path)

## Decision

`machines.source_of_supply` column is **abandoned**. It was designed as one-value-per-machine but source of supply is actually **per-SKU-at-venue**. A VOX machine sources VOX-proprietary SKUs (VOX Popcorn ×3, VOX Lollies, VOX Cotton Candy, fat_can_330 Pepsi, chocolate bars at VOX) via the VOX supply chain, and broad SKUs (Barebells, Vitamin Well, Nutella, Krambals, Ziggi, Leibniz, Sun Blast) via Boonz warehouse WH3. Same pattern will apply to iFly, MP/Mercato, Activate as they come online.

## What we do instead

1. Column stays in schema (don't drop yet, avoid hidden breakage) but unused. No backfill.
2. Per-SKU sourcing will live in either `planogram.source_of_supply` or an extended `supplier_product_mapping` — decided in CS-18.
3. Travel-scope guardrails join on `machines.venue_group`, NOT `source_of_supply`.
4. LLFP was a one-time water activation, removed from vocabulary.
5. ADDMIND machines are managed by Boonz with Boonz products (not VOX proprietary) — no special rule needed; they follow the default BOONZ path.

## Follow-up

**CS-18 — Per-SKU supply source model.** Phase 1, non-blocking for first refill plan.
