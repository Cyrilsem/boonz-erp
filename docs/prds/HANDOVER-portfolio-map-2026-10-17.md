# Handover - Boonz Portfolio Map (product engineering × revenue)

**Date:** 2026-10-17 · **Owner:** CS (Cyril) · **Prepared by:** Claude (Cowork session)
**Status:** Live artifact, v2 (lifecycle + playbook). Data vintage: 48 weekly buckets **2025-11-03 → 2026-10-05**, snapshot taken 2026-10-10. Needs a refresh before the next decision cycle.

---

## 1. What this is

A single interactive page that answers, for every live product: _how fast does it sell where it's placed, how widely is it placed, how mature is it, and what should we do about it?_ It replaces gut-feel reads of the Performance tab with a 2×2 (velocity × coverage) plus a lifecycle layer that distinguishes **demand that faded** from **supply we stopped**.

**Artifact:** https://claude.ai/artifact/FbMjNvPoNoFx3HTdJavNvc (private; share from the page's Share menu)

Views on the page:

- **Scope** - All machines / Boonz sourcing / Partner sourcing (VOX + LVLUP). Default Boonz.
- **Position** - Current (last 8 wk) / At prime / **Trails** (prime → now). Default Trails.
- **Playbook chips** - Double down · Protect · Missed the wave · Cooled off · Reduce & replace · Incubate · Exit. Click to isolate.
- **Cluster** filter, **Min units** slider, **Label all**, hover/pin tooltips, per-cluster table, sortable full table.

Related deliverables from the same work:

- **PRD-104** - Performance-tab fleet split fixed and relabelled _Boonz Sourcing / Partner Sourcing (VOX · LVLUP)_. RPC `get_product_velocity_ledger` live on prod (project `eizcexopcuoycuosittm`), migration `20260720120000_prd087_perf_partner_sourcing_classification.sql`, PRD at `boonz-erp/docs/prds/PRD-104-perf-fleet-sourcing-split-goal-command.md`.
- **October Freakin' Healthy PO** - `BOONZ BRAIN/Boonz_FreakinHealthy_PO_October_2026.xlsx` (120 pcs / 12 boxes, box-compliant; Protein Balls skipped due to overstock).
- **IRIS-1070 machine review** - section 6 below.

---

## 2. Where the pieces live

| Piece                    | Location                                             | Notes                                                                                                   |
| ------------------------ | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Published page           | artifact URL above                                   | Republish to the **same file path / URL** to keep the link.                                             |
| Page template            | session scratchpad `boonz_portfolio_map_v2.html`     | Has a `/*DATA*/` placeholder. Ephemeral - copy into `BOONZ BRAIN/` if you want it kept.                 |
| Data payload             | scratchpad `data/map_data.js` (`const DATA = {...}`) | 96 products × 48 wk × (units, machines) × (Boonz, partner) + stock + revenue. ~51 KB.                   |
| Classification prototype | scratchpad `lifecycle.py`                            | Python mirror of the page's JS logic; use it to tune thresholds and print the lists.                    |
| Fleet-split logic        | `get_product_velocity_ledger` (prod)                 | Same partner predicate as the page (section 3).                                                         |
| Planograms               | `BOONZ BRAIN/planograms/`                            | SAP (2026-09-28), ACTIVATEMOE (2026-09-30 slide is authoritative; its CSV is stale), IRIS (2026-08-21). |

The scratchpad is session-scoped. **Action:** copy `boonz_portfolio_map_v2.html`, `data/map_data.js` and `lifecycle.py` into `BOONZ BRAIN/portfolio-map/` so the next person can rebuild without this session.

---

## 3. Definitions (as implemented)

**Fleet scope.** A machine is _partner-sourced_ when `upper(venue_group) IN ('VOX','LVLUP','LEVELUP')` **or** `official_name` contains ACTIVATE / IFLY / VOX / MPMCC / LVLUP / LEVELUP. Everything else (excluding WH machines) is _Boonz-sourced_. `venue_group` is canonical; the name clause is a guard for machines not yet tagged.

**Sales basis.** `sales_history` rows with `delivery_status IN ('Success','Successful')`, excluding rows where the refund ≥ paid amount. Pod names normalised through `product_name_conventions.official_name`. Weeks are Monday-based, Asia/Dubai. Mixed shelves (Chocolate Bar, Coca Cola Mix, Soft Drinks Mix…) count as sold, not split by flavour - POS does not record the flavour picked.

**Velocity** = units ÷ machine-weeks with a sale (units per machine per _selling_ week). This is "how fast it moves where it's stocked", so a product that is stocked out half the time still shows its true rate. _(The Performance tab's older snapshot used units ÷ distinct machines ÷ 8 - lower; don't compare the two directly.)_

**Coverage** = average weekly machines selling it ÷ machines with any sale in the scope that week.

**Current** = last 8 complete weeks. **Prime** = the product's best 4-week window by velocity, requiring ≥16 units and ≥8 machine-weeks (≈2 machines; falls back to ≥4), velocity ≤ 40. **Retention** = current velocity ÷ prime velocity. **Momentum** = last 4 weeks vs the 4 before (▲ >+15 %, ▼ <−15 %).

**Maturity** (colour, single-hue ordinal ramp): New <3 mo · Growing 3–6 · Established 6–12 · Mature 12+, from first-ever sale to window end.

**Supply signal.** Physical warehouse stock mapped through `product_mapping` → `warehouse_inventory.warehouse_stock`. _Warehouse ≤ 5 = not fuelling._ Open POs are shown but **not** counted as fuel (stale POs are common). Deployed stock (`pod_inventory.current_stock`) is shelf stock, not fuel.

**Playbook rules** (evaluated in this order; medians from live products with ≥8 units in the window):

1. `superseded` - renamed/split pods (Krambals & Zigi, Pepsi Mix, Healthy Cola - Mix). Excluded.
2. `anomaly` - prime velocity > 40 or one week ≥ 60 % of all units, with no current sales (one-machine dumps). Excluded.
3. **Incubate** - under 3 months.
4. **Missed the wave** - prime velocity ≥ today's median **and** prime ≥20 units **and** warehouse ≤ 5 **and** now below prime (retention <0.7, or coverage <60 % of prime, or units down) **and** prime ≥4 weeks ago.
5. **Cooled off** - same strong prime, retention <0.5, but still stocked.
6. Current <8 units → **Exit** if ≥6 months, else Incubate.
7. **Double down** - velocity ≥ median, coverage <50 %, and (top-quartile velocity or coverage < median).
8. **Protect** - velocity ≥ median otherwise.
9. **Reduce & replace** - velocity < median, coverage ≥ median.
10. **Exit** - the rest at ≥6 months; Incubate if 3–6 months.

**Clusters** map `pod_products.product_category` to 8 groups: Water & sparkling · Soft & energy drinks · Health & protein drinks · Bars, protein & dates · Chocolate & candy · Biscuits, cakes & crackers · Chips & popcorn · Fresh & dips (mapping in `lifecycle.py` / `build` script).

---

## 4. How to refresh

1. **Pull the weekly series** (prod, `eizcexopcuoycuosittm`). The query returns one row per product with four 48-element arrays (`ub, mb, up, mp` = units/machines for Boonz/partner), `first_sale`, `category`, `wh`, `dep`, `oo`, plus fleet arrays. Core shape:

```sql
WITH params AS (SELECT date_trunc('week',(now() AT TIME ZONE 'Asia/Dubai'))::date cur_wk, 48 n),
wks   AS (SELECT gs i, (p.cur_wk-(p.n-gs)*7)::date ws FROM params p, generate_series(0,47) gs),
mach  AS (SELECT machine_id, <partner predicate> is_partner FROM machines
          WHERE COALESCE(venue_group,'')<>'WH' AND upper(official_name) NOT LIKE 'WH%'),
base  AS (SELECT normalised pod_name, machine_id, is_partner, qty, week_start ws, date d
          FROM sales_history JOIN mach USING (machine_id) LEFT JOIN product_name_conventions ...
          WHERE <success & not fully refunded>),
wk    AS (SELECT pod_name, ws, is_partner, sum(qty) u, count(DISTINCT machine_id) m FROM base ... GROUP BY 1,2,3),
prods AS (SELECT pod_name FROM wk GROUP BY 1 HAVING sum(u)>=30),
series AS (array_agg over wks × prods, split by is_partner),
fleetwk AS (per-week distinct machines by is_partner),
stock AS (sum warehouse_stock / pod_inventory.current_stock(Active) / open PO qty via product_mapping)
SELECT ... ;
```

The full text is in this session's history (query of 2026-10-10); the result exceeds the MCP output limit, so save it to a file and parse with Python. 2. **Pull 8-week revenue per product** (the earlier snapshot query; `r_b`, `r_p`) and merge by name - a few names differ between pulls (alias map in the build script). 3. **Build** `data/map_data.js` with the Python build step (clusters, superseded flags, name aliases), inject into `boonz_portfolio_map_v2.html` at `/*DATA*/`, write `boonz_portfolio_map.html`. 4. **Check** with `lifecycle.py` (prints every playbook list) - sanity-check Activia/YoPRO land in Missed, Coke Mix in Double down. 5. **Republish** the same file path → same URL. Update `DATA.start/end` automatically from the query.

Suggested cadence: weekly, Monday after the week closes. Could be a scheduled task; not set up yet.

---

## 5. Findings snapshot - Boonz sourcing, window to 2026-10-05

65 products shown (70 in scope), 9,169 units, AED 67.5k in 8 weeks. Medians: velocity 2.4/wk, coverage 19 %.

**Double down (9 · AED 19k):** Coca Cola Mix 15.6/wk @22 % · Coca Cola Zero 7.7 @28 % (prime 12.3) · Loacker 5.9 @40 % (prime 9.9) · Red Bull · Vitamin Well · Pepsi Black · Soft Drinks Mix · Ritz Cracker · Mountain Dew (1 machine, test wider). Six of nine are drinks → the cluster is under-distributed; the fix is can lanes, not SKUs.

**Protect (10 · AED 28k, 41 % of revenue):** Chocolate Bar, Al Ain Zero, Snack Bar, Barebells, Dubai Popcorn, Hunter, Popit Mix, Hunter Ridge, Krambals, Freakin Protein Balls 3P. **Fuel risk inside this group:** Hunter (WH 11 vs ~23/wk), Dubai Popcorn (13 vs ~29/wk, momentum ▼), Barebells (74 vs ~60/wk). Popit Mix diluted: 4.8/wk @16 % at prime → 2.4 @39 % now.

**Missed the wave (15):** at prime ≈1,486 units/8 wk, now 310 (~150 units/wk of proven demand unserved).

- Chilled exited: Activia Mix & Go (4.5 @32 % → 2.7 @11 %, WH 2), YoPRO (3.2 @15 % → 2.1 @6 %), Mezzmix.
- Bakery vanished ~9 mo ago: Sabahoo Cake (5.1 @29 %), 7 Days Croissant (8.2), Caprice.
- Iced coffee both gone: Nescafe (3.6 @28 %), Starbucks (2.9 @19 %).
- Supply lapses on live lines: Sunbites (WH 0, PO open), G&H Popped Chips (WH 0, no PO), Benlian, Freakin Healthy Bites (WH 0 - Oct PO covers), McVities, Be-kind Cluster, Organic Larder Rice Cake, Santiveri.

**Cooled off (4):** Plaay Truffle (launch spike normalising, ▲), Zigi (7.7 → 3.8 **with 546 on order - question it**), Smart Gourmet Hummus, Ice Tea.

**Reduce & replace (4 · ~20 facings):** Keen Health Dipped Crackers (30 % @2.2), Perrier (24 %), Nutella Biscuits T12 (19 %, 44 wk since prime), Be-kind Bar (20 %).

**Exit (13):** ten already at zero (Caprice, Evian Sparkling, Extra Gum, Leibniz Zoo, Freakin PB 4P, Coca Cola Regular pod, Almarai juice, Mezzmix Hummus, Organic Larder Chestnuts, Tamreem Freeze-Dried); live but weak: Evian (**120 on order - question it**), Tamreem Date Ball.

**Incubate (10):** Nutella Biscuits T3 (23/wk on 3 machines, 3 weeks old - fastest in the fleet), Hunter Canister, Freakin Granola / Roasted Dipped / Filled Dates / Thins, Plaay Tablet ×2, Rice & Corn Chips, awa.

**By cluster:** Bars/protein/dates = biggest revenue (AED 19.9k) with 0 double-downs - saturated, rationalise. Soft & energy = 6/8 double-downs - most under-exploited. Chips & popcorn = 4 missed + 3 protect - supply discipline. Biscuits/bakery = bakery hole, Loacker/Ritz winners. Health drinks + Fresh & dips = effectively abandoned (5 missed between them). Water = Al Ain Zero carries it; three Evian variants are exits.

_(Partner view: Aquafina ~50 units/machine/wk is a different business - keep the scope toggle.)_

---

## 6. IRIS-1070 case study (machine-level application)

Live 25 Aug 2026, 16 lanes. ~128 units / ~AED 960 in 6½ weeks (≈20 u, AED 150 per week) - weakest of the three ADDMIND machines (USH-1008 ≈3×). 8/16 lanes dead (0–4 units).

Diagnosis: (1) **drinks don't sell at this venue** - Pepsi Black 0.3/wk here vs 9.5 at ADDMIND-1007; Al Ain Zero and Red Bull at 0 while they sell at siblings; only Perrier moves (and is accelerating). (2) **≥AED 15 is dead** - Barebells, Freakin, Plaay, Red Bull, Keen Health: 9 units across 5 lanes. (3) **We removed the winner** - Zigi (4.2/wk, best revenue/unit) was swapped for Freakin Bites on 27–29 Sep. Krambals sells but sits in a 7-slot lane and stocks out while the 22-slot lane holds 21 bottles of unsold water.

Recommended 7 lane moves (not yet executed): A15 Al Ain Zero → Krambals; A13 → Zigi back; A12 Pepsi Black → Nutella Biscuits T3; A03 Red Bull → 2nd Perrier; A01 Keen Health → Ritz Cracker; A08/A10 Plaay + Barebells → Sunbites + 2nd Hunter Ridge; A05 Freakin PB out (keep Bites on A06 as the one incubation lane). Loacker: match USH flavour mix, one more cycle. Pull ~70 units of dead stock to WH. Expected: ~20 → ~40 units/wk.

**Rule to encode in the engine:** never swap out a lane running above fleet velocity at that machine; seed new lines on dead lanes. IRIS had five dead lanes available when Zigi was removed.

---

## 7. Caveats and known data issues

- **Warehouse stock numbers are inflated for mixed/catch-all pods** (mapping fan-out: one SKU counted under several pods; VOX consignment uses 999/2099 sentinels). The page therefore shows warehouse **status** (stocked / low / none), not quantities. Do not read `wh` as a count for Chocolate Bar, Soft Drinks Mix, Vitamin Well, Tannourine, Sun Blast.
- **On-order is unreliable** (stale POs) - shown as "PO open", never counted as fuel.
- **Alias drift** - renamed pods appear as zero-sellers (handled by the `superseded` list; extend it when pods are renamed). "Garnola/Granola", "Freakin Healthy Thins/Awesome Thins" are known variants.
- **One-machine anomalies** (Tannourine 422/wk, Sun Blast) are quarantined, not fixed at source.
- **IRIS Zigi count** doesn't reconcile (11 placed − 4 removed vs 14 sold) - check shelf attribution.
- **ACTIVATEMOE planogram CSV** in the folder is stale; the 2026-09-30 slide (rev 4) is the truth. Regenerate the CSV.
- **48-week horizon** - primes before Nov 2025 are not seen; fine for the 2026 fleet, but a 52-week+ view is needed for true seasonality.
- Velocity per mixed shelf can be inflated where a product occupies multiple lanes in one machine.

---

## 8. Open decisions for CS

1. Re-source or formally exit: **Activia, YoPRO** (chilled), **bakery line** (Sabahoo / 7 Days), **iced coffee** (Nescafe / Starbucks). Each was above today's median velocity when fuel stopped.
2. Cancel or confirm the open POs on **Zigi (546)** and **Evian (120)**; check **Nescafe (48)**, **Coca Cola Regular (72)**.
3. Approve the **IRIS lane plan** (section 6) and run it through the dispatch pipeline as Remove + Add New.
4. Reallocate the ~20 **Reduce & replace** facings to Coca Cola Mix / Coke Zero / Loacker.
5. Restock the three thin **Protect** items (Hunter, Dubai Popcorn, Barebells) before they stock out.
6. Decide whether the Performance tab's own velocity should move to the machine-selling-week basis used here (consistency).

---

## 9. Backlog (in priority order)

1. **Weeks-of-cover column** on Protect items (WH ÷ weekly rate) - the stockout-in-progress finding should be standing, not spotted.
2. **AED per facing** as an alternate X axis (velocity × price) - re-ranks Barebells-type high-price lines.
3. **Sparklines in the tooltip** - the 48-week arrays are already in the payload.
4. **Machine drill-down tab** - per machine: lane × product, velocity here vs fleet vs sibling machines, stock and capacity, dead-lane flags. (The IRIS analysis, generalised.)
5. **Venue-type split** of velocity (office / gym / cinema / F&B) so "double down" becomes "double down _where_".
6. **PO hygiene lens** - open POs against Cooled/Exit items.
7. **Cannibalisation check** within clusters (cola variants, water SKUs).
8. **Swap-guard rule** in the refill/swap engine (section 6 rule).
9. **Scheduled weekly refresh** of the data payload + republish.
10. Move the template, data builder and `lifecycle.py` into `BOONZ BRAIN/portfolio-map/` (section 2 action).

---

## 10. Related docs

- `boonz-erp/docs/prds/PRD-104-perf-fleet-sourcing-split-goal-command.md` - fleet split fix (shipped).
- `claude/PO-suggestion-2026-09-29.md` - earlier PO suggestion.
- `BOONZ BRAIN/Boonz_FreakinHealthy_PO_October_2026.xlsx` - October FH PO (Agthia / BMB, attn Aya Hanano).
- `BOONZ BRAIN/planograms/` - SAP, ACTIVATEMOE, IRIS planograms.
- Project memory: `reference_product_performance_fleet_split.md` (partner predicate, why).
