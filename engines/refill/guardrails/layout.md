# Layout

**Type:** Machine layout — shelf structure, capacity per (physical_type × shelf_size), 70/30 core/flex split
**Read by:** Engine A, C, D, 2
**Last updated:** 2026-04-10

## 1. Purpose
Products are NOT bound to a single shelf size. A product migrates through shelf sizes based on demand: teaser → Small, stabilizing → Small/Medium, high-volume → Medium with multi-facing or Large. Engine A decides per slot: which shelf size + how many facings + what capacity. **Capacity is read from Section 4 (hand-tuned max capacity), then Engine B applies a fill_factor (default 0.85) for target_qty.**

## 2. Machine profiles
| Profile | Slots | Small | Medium | Large | Rows | Machines |
|---|---|---|---|---|---|---|
| STANDARD_16 | 16 | 8 | 6 | 2 | 5 | 18 of 22 |
| BIG_32 | 32 | 16 | 12 | 4 | 5 | HUAWEI-2003, MC-2004 |
| VOX_PREMIUM_13 | 13 | 4 | 3 | 6 | 5 | VOXMCC-1012, VOXMCC-1017, VOXMM-1009 |

All machines have 5 rows (R1 top → R5 bottom). Baskets are 3 sizes (Small/Medium/Large) from supplier catalog; XL not ordered. Operator to fill mm dimensions later — not blocking.

## 3. Physical types (15)
`thin_can_330` · `fat_can_330` · `water_bottle_500` · `water_bottle_1000` · `health_drink` · `chip_bag_large` · `chip_bag_medium` · `chocolate_bar_standard` · `chocolate_bag` · `protein_bar` · `biscuit_pack` · `rice_cake` · `candy_bag_large` · `dried_fruit_pack` · `small_snack`

Physical type does NOT restrict which shelf size a product occupies. It determines **capacity** per shelf size via Section 4.

## 4. Max capacity lookup (hand-tuned by operator)

**Monotonic rule:** Large ≥ Medium ≥ Small for every physical_type. Engine A refuses any assignment violating this.
**Values below are MAX CAPACITY** (physical basket limit), NOT target quantity. Engine B applies fill_factor 0.85 for target.

| physical_type | Small | Medium | Large | Notes |
|---|---|---|---|---|
| chocolate_bar_standard | 15 | 25 | 40 | Operator-set |
| protein_bar | 15 | 25 | 40 | Same as chocolate (Snack Bar class) |
| health_drink | 6 | 12 | 16 | Vitamin Well reference |
| water_bottle_500 | 6 | 10 | 15 | Aquafina S=6, Evian M=10/L=15 |
| water_bottle_1000 | — | — | 12 | Evian-1L, Large only |
| thin_can_330 | 14 | 18 | 22 | Pepsi Black class; L ≥ M ≥ S enforced |
| fat_can_330 | — | — | 12 | VOX Pepsi Regular + Pop It; Large only |
| chip_bag_large | — | 8 | 10 | Popcorn, big bags |
| chip_bag_medium | 6 | 8 | 10 | Hunter Ridge, G&H |
| chocolate_bag | 8 | 10 | 14 | Maltesers, M&M, Skittles |
| biscuit_pack | 8 | 12 | 16 | Nutella Biscuits, McVities |
| rice_cake | 10 | 14 | 18 | Organic Larder |
| candy_bag_large | 10 | 12 | 14 | VOX Cotton Candy, VOX Lollies |
| dried_fruit_pack | 10 | 12 | 14 | Tamreem, NRJ Nut |
| small_snack | 8 | 10 | 12 | Krambals, Popit Mix |

**Engine A reads max_capacity from this table. Engine B computes target_qty = floor(max_capacity × fill_factor). Operator per-slot overrides in `planogram.target_qty` always win.**

### 4.1 Schema task (CS-20)
Materialize as `slot_capacity_max` table: `(physical_type, shelf_size, max_capacity)`. Add `boonz_products.physical_type` enum column with 15-value CHECK constraint. Backfill all 269 products. **Owner: CC in follow-up prompt.**

## 5. 70/30 rule
**70% core** = ALWAYS-ON + SURGICAL + in-season SEASONAL, weighted by volume/turnover at this specific machine.
**30% flex** = TRIAL + HYPE + experimental.

| Profile | Core | Flex |
|---|---|---|
| STANDARD_16 | 11 | 5 |
| BIG_32 | 22 | 10 |
| VOX_PREMIUM_13 | 9 | 4 |

**Scoring (per machine):** +3 ALWAYS-ON, +2 in-season SEASONAL, +2 TRIAL-graduated, +1 HYPE, +3 top-50% revenue at this machine, +2 KEEP/KEEP GROWING, −2 WIND DOWN, −3 ROTATE OUT. Top-N by score = core. Ties broken by 30d revenue.

**Core stability:** no swap proposals against core unless ROTATE OUT signal. No Engine 2 relocation without operator approval. Demotion requires 14 days consistent downgrade signal.

## 6. Lifecycle migration through shelf sizes
- **Up-migration** (S→M→L): fills ≥80% of current max for 14 consecutive days
- **Down-migration** (L→M→S): fills <30% of current max for 21 consecutive days
- **Multi-facing** (add adjacent slot): hits 100% max for 14 days + archetype is ALWAYS-ON/HYPE + compatible slot available
- All migrations count toward the max-2-per-machine-per-cycle rate limit (portfolio_strategy.md §9)

## 7. Row preferences (soft, tie-breaker only)
R1-R2: chocolate_bar, biscuit_pack, protein_bar, thin_can, health_drink
R3-R4: chip_bag_medium, chocolate_bag, water_bottle_500, candy_bag, yogurt_drink
R5: chip_bag_large, water_bottle_1000, fat_can_330

## 8. Venue variations
- **ADDMIND** (2 STANDARD_16): NO Coca-Cola, source BOONZ
- **VOX** (3 STANDARD_16 + 3 VOX_PREMIUM_13): NO Coca-Cola, 8 locked SKUs per travel-scope, mixed source (VOX-proprietary via VOX, broad SKUs via BOONZ — see CS-18)
- **VML/WPP/OHMYDESK** (7 STANDARD_16): no exclusivity, all in MEDIA_CITY cluster except OHMYDESK
- **INDEPENDENT** (5 STANDARD_16 + 2 BIG_32): BIG_32 machines are the fleet's primary trial venues

## 9. Open flags for first Engine A dry-run review
1. fat_can_330 currently in Small slots at VOX (Pepsi Regular S=14, Pop It S=11). Operator stated fat cans need Large. Flag for review.
2. Evian 500ml in 4 Large slots — should be Medium primary. Flag.
3. Capacity table in Section 4 is first-cut; refine from real fill data over time.

## 10. Cross-refs
portfolio_strategy.md (archetypes, rate limits), coexistence.md, travel-scope.md, refill_rules.md (§refill volume), decision_log.
