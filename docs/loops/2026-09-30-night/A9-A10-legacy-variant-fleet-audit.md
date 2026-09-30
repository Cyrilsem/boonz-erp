# PRD-137 Block A+ items A9/A10: legacy-variant and foreign-product fleet audit

Read-only report, generated 2026-09-30 daytime (pre-window). No writes made. Query: for every
lane where WEIMI currently recognizes a pod product (`weimi_shelf_now`), take every Active row in
`v_pod_inventory_latest` on that lane and flag any whose boonz_product is not in the Active
machine-scoped-or-global `product_mapping` set for that lane's WEIMI pod product. Restricted to
online machines (`adyen_status = 'Online today'`), excludes warehouse pseudo-machines (`WH%`).

## Scale (bigger than the 3-lane example given)

380 mismatched rows, 132 distinct lanes, 29 machines, 1692 units total. This is materially larger
than the "USH A6 / NOOK A6 / VML-1003 A8, Plaay Tablets Dark Chocolate 50g" example that prompted
this check -- that example is real and confirmed below, but it is a small slice of a much wider,
fleet-wide drift between what WEIMI/product_mapping say a lane should hold and what pod_inventory
actually shows Active on it.

**This is why A9's "gets an automatic Remove line in the next plan" is being held, not built,
pending a CS decision on scope** -- generating ~380 Remove lines (1692 units) fleet-wide tonight,
sight-unseen, is not a "surgical, do it now" change. It needs a scope call: all of it, a named
subset (e.g. just the confirmed same-family legacy-size case), or a smaller pilot on the 3 named
machines first. See "Recommendation" at the end.

## A9's own example, confirmed exactly as stated

Legacy same-family size variant sitting on a lane whose WEIMI identity has moved to a "35g"
labelled variant of the same product:

| Machine           | Shelf | Legacy variant (no size suffix)                        | Qty                 | Current WEIMI lane identity |
| ----------------- | ----- | ------------------------------------------------------ | ------------------- | --------------------------- |
| USH-1008-0000-W1  | A06   | Plaay Tablets - Dark Chocolate                         | 7                   | Plaay Tablet Chocolate 35g  |
| NOOK-1019-0200-B1 | A06   | Plaay Tablets - Dark Chocolate                         | 4 + 5 (two batches) | Plaay Tablet Chocolate 35g  |
| VML-1003-0400-O1  | A08   | Plaay Tablets - Dark Chocolate                         | 5                   | Plaay Tablet Chocolate      |
| VML-1003-0400-O1  | A08   | Plaay Tablets - Milk Chocolate Toffee                  | 1                   | Plaay Tablet Chocolate      |
| USH-1008-0000-W1  | A06   | Plaay Tablets - Milk Chocolate Toffee                  | 1                   | Plaay Tablet Chocolate 35g  |
| NOVO-1023-0000-W0 | A07   | Plaay Tablets - Dark Chocolate / Milk Chocolate Toffee | 4 + 1               | Loacker                     |

The same "same product family, legacy size label" pattern also shows up for Hunter / Hunter
Canister (differently-named same product, e.g. AMZ-1029 A10, AMZ-1068 A10, NOOK A16, USH A13,
VML-1003 A13, IRIS A14) and for Vitamin Well / Vitamin well (case-only duplicate name, dozens of
rows fleet-wide) -- these look like data-hygiene duplicates (two `boonz_products` rows for what is
really the same SKU) rather than genuine legacy-size drift, and are worth a separate look, not
folded into A9's fix.

## A10's own example, confirmed exactly as stated

Foreign product with no family relationship to the lane's current identity:

| Machine          | Shelf | Foreign product  | Qty                 | Current WEIMI lane identity |
| ---------------- | ----- | ---------------- | ------------------- | --------------------------- |
| WPP-1002-4300-O1 | A06   | Coca Cola - Zero | 9 + 6 (two batches) | Plaay Tablet Chocolate 35g  |

Many more foreign-product cases exist fleet-wide (full detail below) -- e.g. Vitamin Well sitting
on Aquafina/Pepsi/Ice Tea lanes, Barebells on Tamreem Date Ball lanes, Krambals on Ritz
Cracker/Maltesers lanes, Evian on Popit Mix lanes. Per A10's own instruction: report only, archive
after CS review, no automatic writes.

## Full per-machine detail (all 380 rows)

Format per entry: `shelf product xqty (lane=<current WEIMI-recognized pod product for that shelf>)`

**ACTIVATEMCC-1037-0000-L0** (5 lanes, 19 rows, 71 units)
A01 Vitamin Well - Zero Lemon x7 (lane=Aquafina) | A01 Vitamin Well - Care x1 (lane=Aquafina) | A01 Vitamin Well - Upgrade x1 (lane=Aquafina) | A01 Vitamin Well - Upgrade x2 (lane=Aquafina) | A01 Barebells - Salty Peanut x8 (lane=Aquafina) | A01 Barebells - Creamy Crisp x2 (lane=Aquafina) | A01 Barebells - Caramel Cashew x6 (lane=Aquafina) | A04 Vitamin well - Zero peach x1 (lane=Ice Tea) | A04 Vitamin Well - Zero Lemon x5 (lane=Ice Tea) | A04 Vitamin well - Zero peach x7 (lane=Ice Tea) | A05 Vitamin well - Zero peach x1 (lane=Pepsi Regular) | A05 Vitamin Well - Hydrate x1 (lane=Pepsi Regular) | A05 Vitamin Well - Care x1 (lane=Pepsi Regular) | A05 Vitamin Well - Zero Lemon x5 (lane=Pepsi Regular) | A05 Vitamin well - Zero peach x1 (lane=Pepsi Regular) | A12 Tamreem Date Ball - Sesame Dates x10 (lane=Maltesers Chocolate Bag) | A12 Krambals - Creamy Cheese x7 (lane=Maltesers Chocolate Bag) | A12 Krambals - Tomato & Mozzarella x4 (lane=Maltesers Chocolate Bag) | A14 Tamreem Dried Freeze Fruits - Mango x1 (lane=M&M Chocolate Bag)

**ACTIVATEMCC-2005-0000-W0** (11 lanes, 16 rows, 91 units)
A04 Nestle Kit-kat - Regular x15 (lane=Aquafina) | A04 Galaxy - Milk Chocolate x2 (lane=Aquafina) | A06 Gatorade Cool - Blue Raspberry x3 (lane=Gatorade Zero) | A06 Gatorade - Fruit Punch x4 (lane=Gatorade Zero) | A09 Popit - Original Cola x5 (lane=Aquafina) | A09 Popit - Orange Squeeze x1 (lane=Aquafina) | A10 G&H Popped Chips - Sweet BBQ x7 (lane=Aquafina) | B01 Galaxy - Milk Chocolate x5 (lane=Skittles Bag) | B04 Fade Fit - Salted Caramel x6 (lane=Red Bull) | B07 Fade Fit - Salted Caramel x4 (lane=Ice Tea) | B10 Aquafina - Regular x4 (lane=McVities Digestive Nibbles) | B12 Al Ain Water - Regular x8 (lane=Fade Fit) | B13 Al Ain Water - Regular x4 (lane=Loacker) | B13 McVities Digestive Nibbles - Choco Caramel x8 (lane=Loacker) | B14 Al Ain Water - Regular x1 (lane=Aquafina) | B14 Loacker - Creamkakao x14 (lane=Aquafina)

**ADDMIND-1007-0000-W0** (3 lanes, 9 rows, 42 units)
A06 Krambals - Tomato & Mozzarella x3 (lane=Ritz Cracker) | A06 Krambals - Tomato & Mozzarella x4 (lane=Ritz Cracker) | A06 Krambals - Creamy Cheese x1 (lane=Ritz Cracker) | A06 Krambals - Forest Mushroom & Butter x1 (lane=Ritz Cracker) | A06 Krambals - Green Olives & Sea Salt x1 (lane=Ritz Cracker) | A07 Smart Gourmet - Truffle Hummus and Pretzels x5 (lane=Plaay Tablet Chocolate 35g) | A16 Vitamin Well - Zero Lemon x15 (lane=Al Ain Zero) | A16 Coca Cola - Zero x7 (lane=Al Ain Zero) | A16 Coca Cola - Regular x5 (lane=Al Ain Zero)

**ALJLT-1015-0100-B1** (3 lanes, 4 rows, 10 units)
A02 Perrier - Flavored Peach x1 (lane=Ritz Cracker) | A02 Perrier - Flavored Grapefruit x1 (lane=Ritz Cracker) | A03 Perrier - Flavored Peach x1 (lane=Pepsi Black) | A09 Freakin Healthy Bites - Hazelnut 2P x7 (lane=Red Bull)

**ALJLT-1015-0200-O1** (3 lanes, 3 rows, 13 units)
A03 Vitamin well - Zero peach x1 (lane=Ice Tea) | A10 Nestle Kit-kat - Regular x3 (lane=Chocolate Bar) | A14 Al Ain Water - Regular x9 (lane=awa sparkling water Flavored)

**AMZ-1029-3003-O1** (6 lanes, 34 rows, 113 units)
A01 Zigi - Sweet Chilli x3 (lane=Sunbites) | A01 Hunter Canister - Sea Salt & Cider Vinegar x3 (lane=Sunbites) | A01 Zigi - Teryaki x2 (lane=Sunbites) | A01 Hunter Canister - Black Truffle x3 (lane=Sunbites) | A01 Zigi - Honey Mustard x2 (lane=Sunbites) | A01 Zigi - Hot Chili x11 (lane=Sunbites) | A01 Hunter Canister - Hot Chili x3 (lane=Sunbites) | A01 Zigi - Sea Salted x3 (lane=Sunbites) | A04 Freakin Protein Balls - Choco Hazelnut 3P x2 (lane=Smart Gourmet Hummus) | A04 Freakin Protein Balls - Peanut Butter 3P x3 (lane=Smart Gourmet Hummus) | A04 Freakin Protein Balls - Carmel Crunch 3P x9 (lane=Smart Gourmet Hummus) | A05 Barebells - Hazelnut Naugat x2 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Barebells - White Almond Chocolate x2 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Barebells - Caramel Cashew x2 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Barebells - Caramel Cashew x3 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Freakin Protein Balls - Peanut Butter 3P x3 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Freakin Protein Balls - Carmel Crunch 3P x3 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Freakin Protein Balls - Choco Hazelnut 3P x2 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Barebells - Salty Peanut x5 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Barebells - Hazelnut Naugat x1 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A05 Barebells - Cookies And Cream x2 (lane=Freakin Healthy Roasted Dipped in Chocolate) | A10 Hunter - Sea Salted x1 (lane=Hunter Ridge) | A10 Hunter - Hot Chili x9 (lane=Hunter Ridge) | A10 Hunter - Sea Salt & Cider Vinegar x2 (lane=Hunter Ridge) | A10 Hunter - Black Truffle x3 (lane=Hunter Ridge) | A10 Hunter - White Truffle x2 (lane=Hunter Ridge) | A11 Dubai Popcorn - Butter x1 (lane=Barebells) | A11 Dubai Popcorn - Butter x6 (lane=Barebells) | A11 Dubai Popcorn - Butter x3 (lane=Barebells) | A11 Freakin Healthy Roasted Dipped in Chocolate - Almond x5 (lane=Barebells) | A11 Dubai Popcorn - Salted x1 (lane=Barebells) | A11 Dubai Popcorn - Salted x2 (lane=Barebells) | A11 Freakin Healthy Roasted Dipped in Chocolate - Cashew x5 (lane=Barebells) | A13 7Up - Regular x4 (lane=Coca Cola Mix)

**AMZ-1038-3001-O1** (5 lanes, 40 rows, 268 units)
A05 Barebells - White Almond Chocolate x6 (lane=Tamreem Date Ball) | A05 Barebells - White Almond Chocolate x2 (lane=Tamreem Date Ball) | A05 Barebells - White Almond Chocolate x1 (lane=Tamreem Date Ball) | A05 Barebells - Creamy Crisp x1 (lane=Tamreem Date Ball) | A05 Barebells - Salty Peanut x9 (lane=Tamreem Date Ball) | A05 Barebells - Salty Peanut x3 (lane=Tamreem Date Ball) | A05 Barebells - Salty Peanut x4 (lane=Tamreem Date Ball) | A05 Barebells - Hazelnut Naugat x5 (lane=Tamreem Date Ball) | A05 Barebells - Hazelnut Naugat x4 (lane=Tamreem Date Ball) | A05 Barebells - Cookies And Cream x5 (lane=Tamreem Date Ball) | A07 Kinder Bueno - Hazelnut x14 (lane=Krambals) | A07 M&M - Chocolate Nuts x7 (lane=Krambals) | A07 M&M - Chocolate Nuts x3 (lane=Krambals) | A07 Bounty - Regular x8 (lane=Krambals) | A07 Bounty - Regular x5 (lane=Krambals) | A07 Kinder Bueno - Hazelnut x16 (lane=Krambals) | A07 Kinder Bueno - Hazelnut x16 (lane=Krambals) | A07 Twix - Regular x7 (lane=Krambals) | A07 Snickers - Regular x38 (lane=Krambals) | A07 Mars - Regular x41 (lane=Krambals) | A09 Tamreem Date Ball - Coconut Dates x5 (lane=Barebells) | A09 Tamreem Date Ball - Coconut Dates x2 (lane=Barebells) | A09 G&H Popped Chips - Sweet BBQ x2 (lane=Barebells) | A09 Tamreem Date Ball - Sesame Dates x6 (lane=Barebells) | A09 Tamreem Date Ball - Coconut Dates x5 (lane=Barebells) | A11 Krambals - Tomato & Mozzarella x2 (lane=Chocolate Bar) | A11 Krambals - Green Olives & Sea Salt x7 (lane=Chocolate Bar) | A11 Krambals - Green Olives & Sea Salt x5 (lane=Chocolate Bar) | A11 Dubai Popcorn - Salted x1 (lane=Chocolate Bar) | A11 Dubai Popcorn - Salted x3 (lane=Chocolate Bar) | A11 Nutella - Biscuit T3 x6 (lane=Chocolate Bar) | A11 Krambals - Forest Mushroom & Butter x3 (lane=Chocolate Bar) | A11 Krambals - Forest Mushroom & Butter x1 (lane=Chocolate Bar) | A11 Zigi - Sweet Chilli x3 (lane=Chocolate Bar) | A11 Krambals - Creamy Cheese x2 (lane=Chocolate Bar) | A11 Krambals - Creamy Cheese x2 (lane=Chocolate Bar) | A11 Zigi - Hot Chili x6 (lane=Chocolate Bar) | A11 Krambals - Tomato & Mozzarella x6 (lane=Chocolate Bar) | A11 Krambals - Tomato & Mozzarella x2 (lane=Chocolate Bar) | A13 7Up - Diet x4 (lane=Coca Cola Mix)

**AMZ-1057-2403-O1** (3 lanes, 13 rows, 122 units)
A07 Kinder Bueno - Hazelnut x4 (lane=Tamreem Date Ball) | A07 M&M - Chocolate Nuts x2 (lane=Tamreem Date Ball) | A07 M&M - Chocolate Nuts x32 (lane=Tamreem Date Ball) | A07 Mars - Regular x21 (lane=Tamreem Date Ball) | A07 Snickers - Regular x4 (lane=Tamreem Date Ball) | A07 Snickers - Regular x26 (lane=Tamreem Date Ball) | A07 Kinder Bueno - Hazelnut x8 (lane=Tamreem Date Ball) | A09 Freakin Awesome Thins - Peanut Date & Sea Salt x3 (lane=Freakin Protein Balls 3P) | A11 Tamreem Date Ball - Coconut Dates x9 (lane=Chocolate Bar) | A11 Dubai Popcorn - Butter x1 (lane=Chocolate Bar) | A11 Tamreem Date Ball - Sesame Dates x3 (lane=Chocolate Bar) | A11 Dubai Popcorn - Salted x5 (lane=Chocolate Bar) | A11 Dubai Popcorn - Butter x4 (lane=Chocolate Bar)

**AMZ-1068-2401-O1** (5 lanes, 32 rows, 212 units)
A07 Kinder Bueno - Hazelnut x11 (lane=Freakin Awesome Filled Dates) | A07 Mars - Regular x19 (lane=Freakin Awesome Filled Dates) | A07 Snickers - Regular x18 (lane=Freakin Awesome Filled Dates) | A07 Twix - Regular x13 (lane=Freakin Awesome Filled Dates) | A07 Kinder Bueno - Hazelnut x9 (lane=Freakin Awesome Filled Dates) | A07 Bounty - Regular x21 (lane=Freakin Awesome Filled Dates) | A07 M&M - Chocolate Nuts x4 (lane=Freakin Awesome Filled Dates) | A08 Oreo Cookie - Regular x5 (lane=Barebells) | A08 Oreo Cookie - Regular x8 (lane=Barebells) | A08 Oreo Cookie - Regular x3 (lane=Barebells) | A08 Nutella - Biscuit T3 x3 (lane=Barebells) | A08 McVities Digestive - Mini Milk Chocolate x3 (lane=Barebells) | A08 Nestle Kit-kat - Regular x9 (lane=Barebells) | A08 Nutella - Biscuit T3 x2 (lane=Barebells) | A08 Smart Gourmet - Classic Hummus and Pretzels x2 (lane=Barebells) | A08 McVities Digestive - Mini Dark Chocolate x7 (lane=Barebells) | A08 McVities Digestive - Mini Dark Chocolate x4 (lane=Barebells) | A08 McVities Digestive - Mini Dark Chocolate x14 (lane=Barebells) | A10 Hunter - Sea Salt & Cider Vinegar x5 (lane=Chocolate Bar) | A10 Hunter Canister - Hot Chili x4 (lane=Chocolate Bar) | A10 Hunter Canister - Sea Salt & Cider Vinegar x3 (lane=Chocolate Bar) | A10 Hunter - Sea Salt & Cider Vinegar x4 (lane=Chocolate Bar) | A10 Hunter - Hot Chili x4 (lane=Chocolate Bar) | A10 Hunter - Hot Chili x1 (lane=Chocolate Bar) | A10 Hunter - Sea Salted x4 (lane=Chocolate Bar) | A10 Hunter Canister - Black Truffle x4 (lane=Chocolate Bar) | A11 Dubai Popcorn - Salted x11 (lane=Snack Bar) | A11 Smart Gourmet - Classic Hummus and Pretzels x5 (lane=Snack Bar) | A16 Vitamin well - Zero peach x1 (lane=Dubai Popcorn) | A16 Vitamin Well - Hydrate x1 (lane=Dubai Popcorn) | A16 Vitamin Well - Care x1 (lane=Dubai Popcorn) | A16 Vitamin Well - Zero Lemon x9 (lane=Dubai Popcorn)

**GRIT-1022-0100-W0** (5 lanes, 5 rows, 21 units)
A12 Evian - Regular x2 (lane=Al Ain Zero) | A13 Evian - Regular x2 (lane=Al Ain Zero) | A14 Evian - Regular x3 (lane=Al Ain Zero) | A15 Evian - 1L x8 (lane=Al Ain Zero) | A16 Evian - 1L x6 (lane=Al Ain Zero)

**IFLYMCC-1024-0000-W0** (3 lanes, 8 rows, 32 units)
A05 Vitamin well - Zero peach x1 (lane=Pepsi Regular) | A05 Vitamin Well - Zero Lemon x7 (lane=Pepsi Regular) | A05 Krambals - Forest Mushroom & Butter x3 (lane=Pepsi Regular) | A05 Vitamin Well - Hydrate x2 (lane=Pepsi Regular) | A05 Vitamin Well - Antioxidant x1 (lane=Pepsi Regular) | A05 Vitamin Well - Reload x1 (lane=Pepsi Regular) | A07 Pepsi - Black x9 (lane=M&M Chocolate Bag) | A08 7Up - Diet x8 (lane=Gatorade)

**IRIS-1070-0000-O1** (3 lanes, 4 rows, 9 units)
A05 Freakin Protein Balls - Carmel Crunch 3P x3 (lane=Freakin Protein Balls 3P) | A05 Freakin Protein Balls - Peanut Butter 3P x3 (lane=Freakin Protein Balls 3P) | A10 Barebells - Creamy Crisp x2 (lane=Barebells) | A14 Hunter - Sea Salted x1 (lane=Hunter Ridge)

**JET-1016-0000-O1** (3 lanes, 4 rows, 13 units)
A07 Santiveri - Coco Quinoa x4 (lane=Popit Mix) | A07 Santiveri - Cran Berry x2 (lane=Popit Mix) | A14 Benlian Chips - Sour Cream x3 (lane=Sunbites) | A16 Dubai Popcorn - Salted x4 (lane=Loacker)

**MC-2004-0100-O1** (6 lanes, 19 rows, 63 units)
A08 Pepsi - Regular x3 (lane=Pepsi Black) | A08 7Up - Regular x5 (lane=Pepsi Black) | A08 7Up - Diet x6 (lane=Pepsi Black) | A08 7Up - Diet x5 (lane=Pepsi Black) | A08 Mountain Dew - Regular x2 (lane=Pepsi Black) | A11 Freakin Protein Balls - Peanut Butter 3P x3 (lane=Soft Drinks Mix) | A11 Freakin Protein Balls - Carmel Crunch 3P x8 (lane=Soft Drinks Mix) | A15 McVities Digestive Nibbles - Choco Caramel x2 (lane=Tamreem Date Ball) | A15 McVities Digestive Nibbles - Double Chocolate x2 (lane=Tamreem Date Ball) | A15 McVities Digestive Nibbles - Dark Chocolate x1 (lane=Tamreem Date Ball) | A15 McVities Digestive Nibbles - Milk Chocolate x1 (lane=Tamreem Date Ball) | B13 Rice & Corn Chips - Sour Cream & Onion x1 (lane=Krambals) | B13 Rice & Corn Chips - Sweet Paprika x2 (lane=Krambals) | B14 Vitamin Well - Care x3 (lane=Evian) | B14 Vitamin Well - Care x4 (lane=Evian) | B14 Vitamin Well - Hydrate x5 (lane=Evian) | B14 Vitamin well - Zero peach x3 (lane=Evian) | B14 Vitamin Well - Zero Lemon x2 (lane=Evian) | B16 Evian - Regular x5 (lane=Vitamin Well)

**MINDSHARE-1009-4500-O1** (1 lane, 2 rows, 7 units)
A02 Popit - Orange Squeeze x6 (lane=Pepsi Black) | A02 Popit - Lemon & Lime x1 (lane=Pepsi Black)

**MPMCC-1058-0000-R0** (5 lanes, 10 rows, 44 units)
A02 Vitamin Well - Upgrade x1 (lane=Mountain Dew) | A02 Be-kind Bar - Almond & Sea Salt x15 (lane=Mountain Dew) | A02 Vitamin Well - Hydrate x2 (lane=Mountain Dew) | A02 Vitamin well - Zero peach x3 (lane=Mountain Dew) | A02 Vitamin Well - Antioxidant x1 (lane=Mountain Dew) | A07 McVities Digestive Nibbles - Dark Chocolate x2 (lane=Sunbites) | A08 Vitamin Well - Zero Lemon x10 (lane=Ice Tea) | A11 Be-kind Bar - Dark Chocolate x8 (lane=Aquafina) | A13 Krambals - Green Olives & Sea Salt x1 (lane=Maltesers Chocolate Bag) | A13 Krambals - Tomato & Mozzarella x1 (lane=Maltesers Chocolate Bag)

**NISSAN-0804-0000-L0** (4 lanes, 7 rows, 13 units)
A06 Smart Gourmet - Truffle Hummus and Pretzels x1 (lane=Plaay Truffle 2pcs) | A07 Be-kind Cluster - Peanut Butter x4 (lane=Loacker) | A07 Be-kind Cluster - Peanut Butter x1 (lane=Loacker) | A07 Be-kind Cluster - Hazelnut x1 (lane=Loacker) | A13 McVities Digestive Nibbles - Choco Caramel x1 (lane=Zigi) | A13 McVities Digestive Nibbles - Double Chocolate x1 (lane=Zigi) | A14 Dubai Popcorn - Butter x4 (lane=Benlian Chips)

**NOOK-1019-0200-B1** (4 lanes, 7 rows, 23 units)
A02 Krambals - Tomato & Mozzarella x4 (lane=Tamreem Date Ball) | A02 Krambals - Creamy Cheese x6 (lane=Tamreem Date Ball) | A06 Plaay Tablets - Dark Chocolate x4 (lane=Plaay Tablet Chocolate 35g) | A06 Plaay Tablets - Dark Chocolate x5 (lane=Plaay Tablet Chocolate 35g) | A12 Dubai Popcorn - Salted x1 (lane=Popit Mix) | A16 Hunter - Sea Salt & Cider Vinegar x2 (lane=Hunter Ridge) | A16 Hunter - Hot Chili x1 (lane=Hunter Ridge)

**NOVO-1023-0000-W0** (3 lanes, 8 rows, 25 units)
A04 Hunter Canister - Sea Salt & Cider Vinegar x3 (lane=Keen Health Dipped Crackers) | A04 Hunter Canister - Black Truffle x3 (lane=Keen Health Dipped Crackers) | A04 Hunter Canister - Hot Chili x3 (lane=Keen Health Dipped Crackers) | A04 Plaay Protein Balls - Peanut Butter Truffles 2P x4 (lane=Keen Health Dipped Crackers) | A04 Plaay Protein Balls - Triple Chocolate Truffles 2P x4 (lane=Keen Health Dipped Crackers) | A07 Plaay Tablets - Dark Chocolate x4 (lane=Loacker) | A07 Plaay Tablets - Milk Chocolate Toffee x1 (lane=Loacker) | A15 Freakin Healthy Roasted Dipped in Chocolate - Almond x3 (lane=Benlian Chips)

**OMDBB-1020-0P00-O1** (2 lanes, 8 rows, 19 units)
A06 Krambals - Forest Mushroom & Butter x1 (lane=Sunbites) | A06 Krambals - Creamy Cheese x1 (lane=Sunbites) | A06 Krambals - Forest Mushroom & Butter x1 (lane=Sunbites) | A10 Freakin Awesome Filled Dates - Peanut Butter x5 (lane=Loacker) | A10 Freakin Protein Balls - Choco Hazelnut 3P x4 (lane=Loacker) | A10 Freakin Protein Balls - Peanut Butter 3P x2 (lane=Loacker) | A10 Freakin Protein Balls - Carmel Crunch 3P x3 (lane=Loacker) | A10 Freakin Awesome Filled Dates - Carmel Almond Butter x2 (lane=Loacker)

**OMDCW-1021-0100-W0** (2 lanes, 6 rows, 33 units)
A01 Freakin Healthy Garnola Bar - Chocolate x5 (lane=Freakin Awesome Filled Dates) | A01 Freakin Healthy Garnola Bar - Peanut Butter x1 (lane=Freakin Awesome Filled Dates) | A01 Freakin Healthy Garnola Bar - Peanut Butter x10 (lane=Freakin Awesome Filled Dates) | A01 Freakin Healthy Garnola Bar - Chocolate x9 (lane=Freakin Awesome Filled Dates) | A06 Freakin Awesome Filled Dates - Peanut Butter x2 (lane=Freakin Healthy Garnola Bar) | A06 Freakin Awesome Filled Dates - Carmel Almond Butter x6 (lane=Freakin Healthy Garnola Bar)

**USH-1008-0000-W1** (6 lanes, 16 rows, 52 units)
A02 7Up - Diet x4 (lane=Mountain Dew) | A03 Popit - Lemon & Lime x4 (lane=Evian) | A03 Popit - Lemon & Lime x9 (lane=Evian) | A03 Popit - Original Cola x2 (lane=Evian) | A03 Popit - Orange Squeeze x2 (lane=Evian) | A03 Popit - Lemon & Lime x2 (lane=Evian) | A06 Plaay Tablets - Dark Chocolate x7 (lane=Plaay Tablet Chocolate 35g) | A06 Plaay Tablets - Milk Chocolate Toffee x1 (lane=Plaay Tablet Chocolate 35g) | A12 Evian - Regular x2 (lane=Popit Mix) | A12 Evian - Regular x3 (lane=Popit Mix) | A12 Evian - Regular x5 (lane=Popit Mix) | A12 Evian - Regular x2 (lane=Popit Mix) | A13 Hunter Canister - Hot Chili x3 (lane=Plaay Truffle 2pcs) | A13 Hunter - Hot Chili x2 (lane=Plaay Truffle 2pcs) | A13 Hunter Canister - Sea Salt & Cider Vinegar x3 (lane=Plaay Truffle 2pcs) | A16 Dubai Popcorn - Salted x1 (lane=Benlian Chips)

**VML-1003-0400-O1** (5 lanes, 29 rows, 75 units)
A05 Vitamin Well - Care x2 (lane=Freakin Protein Balls 3P) | A05 Vitamin well - Zero peach x1 (lane=Freakin Protein Balls 3P) | A05 Vitamin Well - Antioxidant x2 (lane=Freakin Protein Balls 3P) | A05 Vitamin Well - Upgrade x1 (lane=Freakin Protein Balls 3P) | A05 Vitamin well - Zero peach x2 (lane=Freakin Protein Balls 3P) | A05 Barebells - Caramel Cashew x2 (lane=Freakin Protein Balls 3P) | A05 Vitamin Well - Zero Lemon x7 (lane=Freakin Protein Balls 3P) | A05 Vitamin Well - Zero Lemon x2 (lane=Freakin Protein Balls 3P) | A05 Barebells - Creamy Crisp x1 (lane=Freakin Protein Balls 3P) | A06 Freakin Protein Balls - Peanut Butter 3P x9 (lane=Keen Health Dipped Crackers) | A06 Freakin Protein Balls - Carmel Crunch 3P x5 (lane=Keen Health Dipped Crackers) | A06 Freakin Protein Balls - Carmel Crunch 3P x2 (lane=Keen Health Dipped Crackers) | A08 Zigi - Sweet Chilli x1 (lane=Plaay Tablet Chocolate) | A08 Hunter Canister - Sea Salt & Cider Vinegar x2 (lane=Plaay Tablet Chocolate) | A08 Hunter Canister - Hot Chili x2 (lane=Plaay Tablet Chocolate) | A08 Zigi - Sea Salted x1 (lane=Plaay Tablet Chocolate) | A08 Hunter Canister - Black Truffle x2 (lane=Plaay Tablet Chocolate) | A08 Zigi - Honey Mustard x6 (lane=Plaay Tablet Chocolate) | A08 Zigi - Hot Chili x1 (lane=Plaay Tablet Chocolate) | A13 Plaay Tablets - Milk Chocolate Toffee x3 (lane=Hunter Ridge) | A13 Plaay Tablets - Dark Chocolate x4 (lane=Hunter Ridge) | A13 Plaay Tablets - Dark Chocolate x2 (lane=Hunter Ridge) | A13 Hunter - Sea Salted x3 (lane=Hunter Ridge) | A13 McVities Digestive Nibbles - Milk Chocolate x1 (lane=Hunter Ridge) | A16 Krambals - Green Olives & Sea Salt x1 (lane=Dubai Popcorn) | A16 Krambals - Forest Mushroom & Butter x1 (lane=Dubai Popcorn) | A16 Sunbites - Olive And Oregano x4 (lane=Dubai Popcorn) | A16 Sunbites - Cheese x2 (lane=Dubai Popcorn) | A16 Krambals - Tomato & Mozzarella x3 (lane=Dubai Popcorn)

**VML-1004-0500-O1** (5 lanes, 11 rows, 29 units)
A01 Extra Gum - Peppermint x1 (lane=Soft Drinks Mix) | A02 7Up - Regular x3 (lane=Soft Drinks Mix) | A02 7Up - Regular x1 (lane=Soft Drinks Mix) | A08 Plaay Protein Balls - Triple Chocolate Truffles 2P x4 (lane=Popit Mix) | A08 Plaay Protein Balls - Cashew Caramel Truffles 2P x1 (lane=Popit Mix) | A08 Plaay Protein Balls - Peanut Butter Truffles 2P x2 (lane=Popit Mix) | A15 Evian - Regular x6 (lane=Al Ain Zero) | A16 Krambals - Creamy Cheese x6 (lane=Dubai Popcorn) | A16 Krambals - Forest Mushroom & Butter x1 (lane=Dubai Popcorn) | A16 Krambals - Creamy Cheese x1 (lane=Dubai Popcorn) | A16 Krambals - Tomato & Mozzarella x3 (lane=Dubai Popcorn)

**VOXMCC-1005-0201-B0** (2 lanes, 2 rows, 11 units)
A03 Tamreem Date Ball - Sesame Dates x5 (lane=Nutella Biscuits T12) | A12 Skittles Bag - Regular Large x6 (lane=M&M Chocolate Bag)

**VOXMCC-1011-0101-B0** (7 lanes, 11 rows, 46 units)
A02 Hunter - White Truffle x3 (lane=Chocolate Bar) | A03 Tamreem Date Ball - Sesame Dates x3 (lane=Barebells) | A04 Krambals - Creamy Cheese x3 (lane=VOX Lollies) | A04 Barebells - Caramel Cashew x6 (lane=VOX Lollies) | A04 Barebells - Creamy Crisp x4 (lane=VOX Lollies) | A04 Krambals - Creamy Cheese x5 (lane=VOX Lollies) | A11 Sun Blast - Apple x9 (lane=Nutella Biscuits T12) | A13 Nutella - Biscuit T12 x5 (lane=M&M Chocolate Bag) | A14 Sun Blast - Orange x1 (lane=Maltesers Chocolate Bag) | A15 Tamreem Date Ball - Sesame Dates x3 (lane=Sun Blast Juice) | A15 Skittles Bag - Regular Large x4 (lane=Sun Blast Juice)

**VOXMM-1013-0101-B0** (3 lanes, 4 rows, 20 units)
A02 Barebells - White Almond Chocolate x11 (lane=VOX Lollies) | A02 Barebells - Caramel Cashew x2 (lane=VOX Lollies) | A11 Skittles Bag - Regular Large x5 (lane=M&M Chocolate Bag) | A15 Leibniz Zoo - Mik and Honey x2 (lane=Aquafina)

**WAVEMAKER-1006-4100-O1** (8 lanes, 20 rows, 89 units)
A01 Hunter Canister - Hot Chili x3 (lane=Coca Cola Zero) | A01 Sunbites - Olive And Oregano x2 (lane=Coca Cola Zero) | A01 Sunbites - Cheese x3 (lane=Coca Cola Zero) | A01 Hunter Canister - Black Truffle x3 (lane=Coca Cola Zero) | A01 Hunter Canister - Sea Salt & Cider Vinegar x2 (lane=Coca Cola Zero) | A03 Sunbites - Olive And Oregano x8 (lane=Coca Cola Mix) | A04 Red Bull - Regular x3 (lane=Pepsi Black) | A04 Red Bull - Regular x6 (lane=Pepsi Black) | A06 Pepsi - Black x10 (lane=Be-kind Bar) | A07 Tamreem Date Ball - Coconut Dates x5 (lane=Plaay Truffle 2pcs) | A07 Tamreem Date Ball - Sesame Dates x1 (lane=Plaay Truffle 2pcs) | A08 Barebells - Hazelnut Naugat x1 (lane=Freakin Healthy Garnola Bar) | A08 Barebells - Salty Peanut x4 (lane=Freakin Healthy Garnola Bar) | A08 Barebells - White Almond Chocolate x8 (lane=Freakin Healthy Garnola Bar) | A08 Barebells - Salty Peanut x2 (lane=Freakin Healthy Garnola Bar) | A08 Barebells - Caramel Cashew x2 (lane=Freakin Healthy Garnola Bar) | A08 Barebells - Cookies And Cream x1 (lane=Freakin Healthy Garnola Bar) | A10 Freakin Healthy Garnola Bar - Chocolate x9 (lane=Barebells) | A10 Freakin Healthy Garnola Bar - Chocolate x4 (lane=Barebells) | A13 Pepsi - Black x12 (lane=Sunbites)

**WPP-1002-4300-O1** (11 lanes, 29 rows, 126 units)
A01 Vitamin Well - Hydrate x3 (lane=Nutella Biscuits T12) | A01 Evian - Regular x5 (lane=Nutella Biscuits T12) | A01 Vitamin Well - Zero Lemon x9 (lane=Nutella Biscuits T12) | A01 Vitamin well - Zero peach x3 (lane=Nutella Biscuits T12) | A02 Keen Health Dipped Crackers - Milk Chocolate x3 (lane=Coca Cola Zero) | A02 Keen Health Dipped Crackers - Raspberry Chocolate x3 (lane=Coca Cola Zero) | A02 Keen Health Dipped Crackers - Dark Chocolate x3 (lane=Coca Cola Zero) | A02 Keen Health Dipped Crackers - Milk Chocolate x7 (lane=Coca Cola Zero) | A02 Evian - Regular x5 (lane=Coca Cola Zero) | A03 Barebells - Caramel Cashew x1 (lane=Perrier Sparking Water Regular and Flavored) | A03 Barebells - Hazelnut Naugat x2 (lane=Perrier Sparking Water Regular and Flavored) | A03 Barebells - White Almond Chocolate x9 (lane=Perrier Sparking Water Regular and Flavored) | A04 Perrier - Flavored Peach x5 (lane=Al Ain Zero) | A04 Perrier - Flavored Peach x9 (lane=Al Ain Zero) | A04 Perrier - Flavored Lime x2 (lane=Al Ain Zero) | A04 Perrier - Flavored Grapefruit x1 (lane=Al Ain Zero) | A05 Al Ain Zero x6 (lane=Keen Health Dipped Crackers) | A06 Coca Cola - Zero x9 (lane=Plaay Tablet Chocolate 35g) | A06 Coca Cola - Zero x6 (lane=Plaay Tablet Chocolate 35g) | A08 Plaay Tablets - Dark Chocolate x2 (lane=Vitamin Well) | A08 Plaay Tablets - Dark Chocolate x3 (lane=Vitamin Well) | A10 Nutella - Biscuit T12 x11 (lane=Barebells) | A14 Tamreem Date Ball - Sesame Dates x6 (lane=Be-kind Cluster) | A14 Tamreem Date Ball - Coconut Dates x1 (lane=Be-kind Cluster) | A15 Rice & Corn Chips - Sweet Paprika x3 (lane=Sunbites) | A15 Loacker - Vanille x2 (lane=Sunbites) | A15 Loacker - Napolitaner x3 (lane=Sunbites) | A15 Rice & Corn Chips - Sour Cream & Onion x2 (lane=Sunbites) | A16 Dubai Popcorn - Salted x2 (lane=Benlian Chips)

## Observations worth CS's attention before any Remove-line generation

1. **A lot of this looks like a WEIMI-recognition drift problem, not purely a physical-stock
   problem.** Many lanes show a completely different product category on both sides (e.g. Barebells
   protein bars sitting on a "Tamreem Date Ball" or "Krambals" lane) -- this pattern (chocolate/bar
   product families cycling through the same physical bin across many machines) suggests either (a)
   WEIMI's own product-name recognition for that lane has drifted/misidentified what's really there,
   or (b) these shelves are genuinely being used for whatever's in stock that day and the
   product_mapping table hasn't caught up. Either way, generating a Remove line for all 380 rows
   uncritically would remove real, sellable stock in cases where WEIMI (not the shelf) is wrong.
2. **Vitamin Well / Vitamin well** (capital vs lowercase "well") appears dozens of times fleet-wide
   as if it were two different products -- worth checking whether these are actually two separate
   `boonz_products` rows for the same real product (a data-hygiene duplicate, PRD-062's merge
   pattern may apply) rather than a genuine mapping violation.
3. **A9's 3 named lanes (USH A06, NOOK A06, VML-1003 A08) are the cleanest, most confident case** --
   same product family, only the size label differs, and the newer size variant is already present
   and mapped on the same lane. If CS wants a pilot before the fleet-wide fix, this is the safest
   starting subset.

## Recommendation

Do not auto-generate 380 Remove lines tonight. Options for CS to pick from:

- **Pilot**: build the "legacy same-family variant" Remove-generator for A9 and run it only on the
  3 confirmed lanes (USH A06, NOOK A06, VML-1003 A08) as a first cut, then re-run the report next
  loop to see how much of the fleet-wide list turns out to be the same clean pattern vs. WEIMI
  drift noise.
- **Full run**: apply the sweep fleet-wide as specified, accepting the risk noted in observation 1.
- **Hold entirely**: treat this as a data-quality investigation (WEIMI drift + boonz_products
  duplicate cleanup) before any Remove-line automation, and revisit A9 once that's understood.
