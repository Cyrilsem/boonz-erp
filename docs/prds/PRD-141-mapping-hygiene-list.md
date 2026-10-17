# PRD-141 item 11: mapping hygiene change list (for CS approval)

Applied on 2026-10-18 (migration 20261017214206), no approval needed because behaviour-neutral:
375 Active product_mapping rows in 90 pod groups (88 machine, 2 global) renormalised so each group
sums to exactly 100 (largest remainder). Shares moved by at most 0.0074 percentage points. Old values
are in `prd141_mapping_split_backup`. A nightly job (03:40 Dubai) now alerts if any group drifts off 100.

## Needs CS approval: promote machine-only SKUs to a global row

These boonz products exist only as machine-scoped Active rows (no global row for that pod) on two or
more machines. Promoting one adds a global row, which makes it a variant on every machine that has no
machine-scoped rows for that pod. Not applied. "Machines" = machines with a machine-scoped Active row;
"sold" = of those, machines with a successful sale of that pod in the last 30 days (pod-name match,
undercounts where the sales pod name differs).

| Pod product | Boonz product | Machines | Sold |
| --- | --- | --- | --- |
| Vitamin Well | Vitamin well - Zero peach | 43 | 17 |
| Vitamin Well | Vitamin Well - Zero Lemon | 42 | 17 |
| Extra Gum | Extra Gum - Peppermint | 42 | 0 |
| Barebells | Barebells - Pistachio Spread | 41 | 26 |
| Barebells | Barebells - Soft Choco | 41 | 26 |
| Barebells | Barebells - Cookies and Caramel | 41 | 26 |
| Barebells | Barebells - Peanut Cloud | 41 | 26 |
| Zigi | Zigi - Hot Chili | 41 | 13 |
| Evian - 330 ML | Evian - 330ML | 41 | 0 |
| Smart Gourmet Hummus | Smart Gourmet - Truffle Hummus and Pretzels | 40 | 5 |
| Smart Gourmet Hummus | Smart Gourmet - Zaatar Hummus and Pretzels | 40 | 5 |
| 7up - Regular | 7Up - Regular | 39 | 0 |
| 7up And Sprite Lime | 7Up - Diet | 39 | 0 |
| Hunter Canister 40G | Hunter Canister - Sea Salted | 39 | 0 |
| Freakin Protein Balls 3P | Freakin Protein Balls - Peanut Butter 3P | 38 | 0 |
| Freakin Protein Balls 3P | Freakin Protein Balls - Carmel Crunch 3P | 38 | 0 |
| Karuzo Croissant Bun | Karuzo Croissant Bun - Blueberry Cheesecake | 36 | 0 |
| Karuzo Croissant Bun | Karuzo Croissant Bun - Cherry Cheesecake | 36 | 0 |
| Karuzo Croissant Bun | Karuzo Croissant Bun - Chocolate | 36 | 0 |
| Karuzo Croissant Bun | Karuzo Croissant Bun - Strawberry Cheesecake | 36 | 0 |
| Karuzo Croissant Bun | Karuzo Croissant Bun - Tiramisu Cream Taste | 36 | 0 |
| Be-kind Bar | Be-kind Bar - Dark Chocolate | 34 | 8 |
| Soft Drinks Mix | 7Up - Regular | 27 | 14 |
| Coca Cola Mix | 7Up - Regular | 11 | 0 |
| Coca Cola Mix | 7Up - Diet | 11 | 0 |
| Fade Fit | Fade Fit - Coconut | 11 | 3 |
| Barebells | Barebells - Creamy Crisp | 4 | 0 |
| M&M Bags | M&M Bag - Brown Bag | 2 | 0 |
| Gatorade | Gatorade - Fruit Punch | 2 | 2 |

Excluded: TEST TRANSFER / TEST - TRANSFER (test fixture).
Recommendation: approve the first 23 rows (the pod's standard flavours, mapped on 34 or more
machines); hold the Coca Cola Mix 7Up rows (7Up inside a Coca Cola pod looks like a mapping error),
Fade Fit, Creamy Crisp, M&M Brown Bag and Gatorade Fruit Punch (2 to 11 machines, local choices).

Also for CS (data, not code): AMZ-1029 and AMZ-1038 machine rows for Soft Drinks Mix still give
7Up - Regular, 7Up - Diet and Mountain Dew - Regular a split of 5 each (now renormalised, same
share). If those are meant to be off, set them to 0 in Config > Product Mapping; since PRD-141 item 10
the engine then never proposes them and the plan writer rejects them by name.

## How to apply an approved row

```sql
-- one row per approved (pod, boonz); split taken as the median of its machine-scoped splits
INSERT INTO product_mapping (pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status)
SELECT pm.pod_product_id, pm.boonz_product_id, NULL, percentile_cont(0.5) WITHIN GROUP (ORDER BY pm.split_pct), true, 'Active'
FROM product_mapping pm JOIN pod_products pp USING (pod_product_id) JOIN boonz_products bp ON bp.product_id = pm.boonz_product_id
WHERE pm.status = 'Active' AND pm.machine_id IS NOT NULL
  AND (pp.pod_product_name, bp.boonz_product_name) IN (('Barebells', 'Barebells - Soft Choco'))  -- approved pairs here
GROUP BY pm.pod_product_id, pm.boonz_product_id;
-- then the nightly check (or SELECT check_mapping_split_sums()) lists the global groups to renormalise.
```
