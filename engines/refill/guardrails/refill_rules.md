# Refill Rules

**Type:** Per-refill quantity rules — how many units to send per slot per cycle
**Read by:** Engine B (Quantity Sizer), Engine D
**Last updated:** 2026-04-10

## 1. Purpose
Given a slot with a known `max_capacity` (from layout.md §4) and current stock level, Engine B decides how many units to send in tomorrow's refill. This file defines the rules, thresholds, and fill factors Engine B uses.

## 2. Fill factor
**Default fill_factor = 0.85.** Engine B never fills beyond 85% of max_capacity. Reasons: (a) operator slack for expiry management, (b) visual appearance (fully crammed baskets look bad), (c) physical dispense reliability.

**target_qty = floor(max_capacity × fill_factor)**

Per-slot operator overrides in `planogram.target_qty` always win over the formula.

## 3. Refill volume = target_qty − current_stock
Engine B fetches `current_stock` from `v_live_shelf_stock` (the four-oracles stock view) at refill-plan-generation time. Sends the difference. Never sends negative (current ≥ target means no refill).

## 4. Refill frequency by archetype
| Archetype | Target refill frequency | Notes |
|---|---|---|
| ALWAYS-ON | Standard cycle (2-3x/week depending on velocity) | Refill whenever current < 40% of target |
| HYPE | Aggressive — refill whenever current < 60% of target | Ride the wave, avoid stockout |
| SEASONAL (in-season) | Same as ALWAYS-ON during active window | Skip refill entirely during trough |
| SEASONAL (trough) | Do not refill | Wait for next cycle |
| TRIAL | Frequent — refill whenever current < 50% of target | Maximize data collection |

## 5. Minimum facings per signal tier
| Lifecycle signal | Min facings | Max facings |
|---|---|---|
| KEEP GROWING | 2 | 4 |
| KEEP | 1 | 3 |
| WATCH | 1 | 2 |
| WIND DOWN | 1 | 1 |
| ROTATE OUT | 0 (don't refill) | 0 |

Facings = adjacent slots with same product. Engine A proposes facings; Engine B respects the assignment.

## 6. Stockout prevention priority
Engine D always includes stockout-prevention refills first in tomorrow's plan, regardless of portfolio_strategy.md §9 rate limits. A slot below 20% of target_qty is classified **critical** and jumps the queue. Critical refills don't count against the max-10-changes-per-day ceiling — that ceiling is for slot changes (swap/relocate/migrate), not for refilling existing placements.

## 7. Expiry-aware refill reduction
Before sending, Engine B checks `pod_inventory` for any existing batches at the slot with expiry < 14 days away. If present, Engine B reduces the send quantity so total remaining (old + new) doesn't exceed what can plausibly sell before expiry. FIFO rule: expiration_date ASC NULLS LAST.

## 8. Dead stock flag
If a slot has been refilled ≥ 3 times in 21 days without the current_stock dropping below 50%, Engine B flags it as dead stock for operator review on `/refill`. This is a signal that the slot's product isn't moving and the refills are wasted warehouse cycles.

## 9. Cross-refs
layout.md §4 (max capacity table), portfolio_strategy.md §3 (archetypes), portfolio_strategy.md §9 (rate limits), v_live_shelf_stock, pod_inventory.

## Change log
- 2026-04-10: drafted fast-path from portfolio_strategy.md §9 + archetype logic + layout.md §4 capacity model. All thresholds are first-cut; tune after first 30 days of real Engine B runs.
