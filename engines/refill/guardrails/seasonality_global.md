# Seasonality — Global UAE Calendar

**Type:** Time-of-year adjustments for SEASONAL archetype products and cross-fleet demand modulation
**Read by:** Engine 1 (archetype evaluation), Engine A (layout scoring), Engine B (refill volume)
**Last updated:** 2026-04-10

## 1. Purpose
Defines recurring annual events and windows that affect product demand across the Boonz fleet. Engine 1 reads this file to avoid mis-judging SEASONAL products during their expected trough/peak. Engine A uses it to modulate core/flex scoring. Engine B uses it to adjust refill volume during expected peaks.

## 2. UAE annual calendar (first-cut, operator to refine)

### 2.1 Religious / cultural calendar
| Event | Approx window (varies yearly) | Demand effect |
|---|---|---|
| **Ramadan** | 10-11 days earlier each year (Feb-Apr in mid-2020s) | Daytime demand drops sharply at office/coworking machines. Iftar-adjacent demand spikes at cinema/entertainment. Halal-only products see bump. Dates, snacks, water bottles spike post-sunset. |
| **Eid al-Fitr** | End of Ramadan, 3 days | Office machines dead (holidays). Entertainment machines spike (family outings). |
| **Eid al-Adha** | ~70 days after Eid al-Fitr, 3-4 days | Same pattern as Eid al-Fitr. |
| **Islamic New Year** | Varies | Minor effect. |

### 2.2 National / civic calendar
| Event | Window | Demand effect |
|---|---|---|
| **UAE National Day** | Dec 2-3 | Entertainment venues spike. Offices closed. |
| **Commemoration Day** | Dec 1 | Minor. |
| **New Year's Day** | Jan 1 | Offices closed. Entertainment spike. |

### 2.3 Climate windows
| Window | Effect |
|---|---|
| **Peak summer** (Jun-Sep) | Extreme heat. Cold drinks (water, sparkling, juice) spike. Chocolate avoided due to melt risk at outdoor-adjacent machines. Foot traffic at outdoor venues drops; indoor venue demand increases. |
| **Mild / peak tourism** (Nov-Feb) | Highest foot traffic across entertainment and coworking. All categories perform. |
| **Shoulder** (Mar-May, Oct) | Normal baseline. |

### 2.4 School / academic calendar
| Window | Effect |
|---|---|
| **School year** (Sep-Jun) | Office/coworking machines at peak weekday demand. |
| **Summer break** (Jul-Aug) | Office/coworking demand dips ~20-30%. Entertainment venues spike (school holidays → family outings). |
| **Winter break** (late Dec - early Jan) | Offices near-dead for 2 weeks. Entertainment peaks. |
| **Spring break** (varies) | Minor dip at office, spike at entertainment. |

### 2.5 Lifestyle / behavioral
| Window | Effect |
|---|---|
| **January fitness resolutions** | Protein bars, health drinks, Vitamin Well spike for 4-6 weeks |
| **DSF / Dubai Shopping Festival** (Jan-Feb) | Tourism and mall traffic up; entertainment venues spike |
| **Back-to-school** (late Aug - early Sep) | Snack bars, biscuit packs spike at office/coworking (new school-year routine) |

## 3. How engines use this file
- **Engine 1**: a SEASONAL product cannot be WIND DOWN'd during its expected trough. Never phase out a seasonal product without observing a full cycle.
- **Engine A**: in-season SEASONAL products get +2 in core scoring (layout.md §5). Out-of-season get 0.
- **Engine B**: during known demand spikes (Ramadan iftar, National Day, summer heat), allowed to exceed standard refill volume by up to 25% for stockout prevention, logged as `seasonal_surge_refill`.

## 4. Open flags (operator to refine when ready)
1. **Ramadan exact dates per year** — needs yearly update. Not a Phase 1 blocker since Engine 1's protection for SEASONAL products during expected trough is generic.
2. **School calendar precise dates** — varies by emirate and school. Not a blocker.
3. **Partnership-driven seasons** (e.g., "we push Vitamin Well hard during January") — not yet captured. Would be in portfolio_strategy.md §4 Partnerships if a commercial deal exists.

## 5. Cross-refs
portfolio_strategy.md §3 (SEASONAL archetype), layout.md §5 (core scoring), refill_rules.md §4 (frequency by archetype)

## Change log
- 2026-04-10: drafted from public UAE calendar knowledge. First-cut, operator to verify.
