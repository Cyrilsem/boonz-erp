# PRD-143: Hero reintroduction (pulled for shortage, bring back when stocked)

Written 19 Oct 2026 for PRD-144 P2-1. P2-1 seeds sku_intents from section C.

## A. Rule (CS, 19 Oct)
A product pulled from a lane because the warehouse was empty is a hero on that machine, not a failure. It goes back the moment warehouse stock is back above the threshold. There is no "reintro" action in the plan: it is an Add New with "[reintro]" in the comment. The lane offered must fit the product size (slot_profile_pool) and be shown at Gate 1 with the lane choice; nothing is written automatically.

Frame agreed with CS: hero means machine-level SKU performance vs its peers on that machine and vs the same SKU fleet-wide, over lifetime where history is thin. Top-down (fleet heroes) meets bottom-up (local heroes).

## B. Threshold
min_wh_stock = one tray of that product in WH_CENTRAL (24 for cans and bottles, 12 for bars and snacks, 8 for premium snacks like Smart Gourmet and Krambals). preferred_lane_size from slot_profile_pool for the product.

## C. Seed list (status 19 Oct, WH stock at scan)
Rows for sku_intents kind='reintro_when_stocked' (machine, boonz_product, min_wh_stock, note):

1. AMZ-1057-2403-O1, Red Bull - Regular and Red Bull - Diet, min 24. Pulled 8 Oct A14 (Regular 9 + Diet 4 to WH, Huel in). WH 151 cans on 19 Oct: proposes now. Lane: A14 or any Medium lane with a weak performer.
2. ADDMIND, Krambals (all flavours with sales history there), min 8. Off shelf, WH 146.
3. VML-1004-0500-O1 and VML-1003, Popit (all flavours with sales history there), min 12. Off shelf, WH 108.
4. ACTIVATEMCC-2005-0000-W0, Pocari Sweat, min 24. Off shelf, WH 34.
5. AMZ-1029-3003-O1, NISSAN-0804-0000-L0, NOVO: Smart Gourmet - Classic Hummus and Pretzels, min 8. Off shelf, WH 40 (Classic only, no Truffle or Beetroot).
6. AMZ-1038-3001-O1, Dubai Popcorn - Butter and Salted, min 12. WH after 19 Oct: Butter 0 free, Salted 0 free (both consumed by 2403 and OMDCW), so this one waits for the next popcorn PO.
7. Waiting on supplier stock, seed now so they fire on receipt: Activia (machines where it was pulled, per section E scan), Vitamin Well (Gatorade lanes get Vitamin Well per CS rule), YoPRO, Evian 330. One tray each per section B.

Already reintroduced on 19 Oct (do not seed): Nescafe WAVEMAKER A04 and MC A12, Dubai Popcorn AMZ-1057 A16 and OMDCW A12.

Do NOT seed: Red Bull 355ML at AMZ-1029 (standing rule: no Red Bull 355ML at AMZ-1029; the 5 cans pulled 8 Oct stay in WH or go elsewhere).

## D. How the proposals surface
get_reintro_proposals (P2-1) returns, per intent with WH stock >= min: machine, product, candidate lanes (WEIMI lanes that exist, Medium first, then slowest current occupant), proposed qty = lane capacity. The DICTATED path lists them at Gate 1 under "Reintroductions available"; engine_add_pod attaches them to the draft as proposals. CS approves per line. Comment on the written line: "[reintro] hero off shelf, back in stock: <product>".

## E. Hero scan method (for the scan that feeds future seeds)
fact_product_machine_daily (pod_product_id, machine_id, d, units, net_rev_exvat) joined to machine_features and v_shelf_capacity; product_name_conventions for pod to boonz naming; product_mapping must be deduplicated (select distinct pod_product_id, boonz_product_id) or stock inflates 5 to 40x. A hero is a SKU whose units per week on that machine is above the machine median and above the fleet median for that SKU, over the last 90 days or lifetime if fewer than 30 selling days. Candidate = hero with no current lane on that machine and WH stock > 0, mapped on that machine, not blocked by a standing rule (no Coca Cola at USH/IRIS/ADDMIND, VOX machines never introduce new products, no Red Bull 355ML at AMZ-1029, MOE no Al Ain/Sun Blast/Evian 330).
