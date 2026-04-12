# Portfolio Strategy

**Type:** Catalog-level product intelligence and operator intent
**Read by:** Engine 1 (Portfolio Manager), Engine 2 (Relocation Planner), Engine C (Swap), Engine D (Decider)
**Last updated:** 2026-04-10
**Owner:** CS (cyrilsem@gmail.com)

---

## 1. Purpose & how Engine 1 reads this file

### 1.1 Why this file exists

The Boonz refill engine has two independent sources of intelligence about every product:

1. **The data layer** — `product_lifecycle_global`, `slot_lifecycle`, `sales_history`. This layer knows velocity, trend, consistency, geographic distribution, score, and signal (KEEP / KEEP GROWING / WATCH / WIND DOWN / ROTATE OUT). It is objective, continuously updated, and correct on the facts it can see.
2. **The operator intent layer** — this file. It knows everything the data layer cannot see: contractual obligations, partnership relationships, brand strategy, lifecycle archetype, client-specific requests, phase-out preferences, commercial deals, and the reasons behind the numbers.

Engine 1 reads **both layers** and reconciles them. When they agree, Engine 1 acts with high confidence. When they disagree, Engine 1 either escalates to the operator (for hard rules in this file) or explains the override in plain language (for soft biases).

This file does NOT duplicate the data layer. If the fact can be computed from sales data, it lives in the data layer, not here. This file is exclusively for facts the data cannot see.

### 1.2 Who reads this file

- **Engine 1 (Portfolio Manager)** — primary reader. Parses the structured fields at startup, applies biases and overrides to its catalog-level classifications.
- **Engine 2 (Relocation Planner)** — reads lifecycle archetype and partnership data to decide travel eligibility and push intensity.
- **Engine C (Swap)** — reads protection rules and phase-out preferences to filter swap candidates.
- **Engine D (Decider)** — reads transition rate limits and operator intent to bond plan lines and resolve conflicts.
- **Humans (operator, future operator, anyone new to the system)** — reads narrative sections and rationale fields to understand the strategic picture.

### 1.3 File structure philosophy

This file is **short and focused on exceptions.** Most products in the Boonz catalog are handled fine by the data layer alone — they don't need a `portfolio_strategy.md` entry. The file lives and dies by how selective it is. If it grows to list every product, it stops being useful and starts being maintenance.

Concrete rule: **if you can't explain why a product is in this file in one sentence, it shouldn't be in this file.**

### 1.4 How Engine 1 parses this file

Engine 1 reads this file once at startup (and re-reads on file change). For each structured section (archetypes, protected products, phase-out candidates, partnerships), Engine 1 parses the tables into in-memory lookups keyed by `pod_product_id` or `archetype_name`. Rationale fields are loaded as plain-text strings that Engine 1 can include in its decision explanations to the operator.

For every product in the catalog, Engine 1 then constructs a composite intent vector:

```
intent_vector = {
  archetype: ALWAYS-ON | HYPE | SEASONAL | TRIAL,
  protection_level: NONE | CLIENT_REQUEST | PARTNERSHIP | CONTRACTUAL,
  push_intensity: LOW | NORMAL | HIGH,
  phase_out_bias: NONE | SOFT | HARD,
  operator_rationale: "<plain text from this file, passed through to explanations>"
}
```

This vector is combined with the data-layer signal to produce Engine 1's final classification. The combination rule is: **data facts dominate unless an operator intent field explicitly overrides.** For example:

- Data says WIND DOWN, file says `protection_level = CONTRACTUAL` → Engine 1 keeps the product, explains override
- Data says KEEP, file says `phase_out_bias = HARD` → Engine 1 proposes phase-out, explains operator intent
- Data says KEEP, file has no entry for this product → Engine 1 follows data with no modification

### 1.5 Default mode

**Phase 1 runs in BALANCED mode only.** Conservative and aggressive modes are Phase 2 enhancements — see Section 11 cross-references and the bible's Phase 2 chapter. In balanced mode, Engine 1 uses this file as priors and overrides on top of data signals, with the combination rule described in 1.4.

## 2. The three product universalities

Every product has a **reach profile** that describes where it works. Some products sell broadly across all location types. Some sell only in specific venue categories. Some sell only in one or two specific machines. Engine 1 must know the reach profile to evaluate whether a product is "failing" (it should be doing better than this) or "succeeding within its natural scope" (it's not a failure, it's just a niche product with a niche audience).

### 2.1 The three categories

| Category             | Definition                                                                                                                                        | Example (from live data)                                                                                                                                             |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Global**           | Sells across ≥ 3 different `location_type` categories with consistent velocity in each. Broad-spectrum appeal.                                    | Vitamin Well — 11 machines across office (4), coworking (4), entertainment (2). Chocolate Bar — 13 machines, widest spread in top 25.                                |
| **Industry-focused** | Concentrated in 1-2 `location_type` categories. Works in a specific professional or venue context.                                                | Snack Bar — 9 machines, only office (5) and coworking (4), zero entertainment. Organic Larder Rice Cake — only office and coworking.                                 |
| **Machine-focused**  | Concentrated in ≤ 3 specific machines, typically of the same venue group or with a specific operator relationship. Narrow but often high-revenue. | Aquafina — 3 entertainment machines only, but #1 revenue in the fleet (AED 3,535/30d). VOX Popcorn × 3, VOX Lollies, Maltesers, Skittles — all 3-machine VOX-locked. |

### 2.2 How the category is determined

Engine 1 **derives** the category automatically from sales data and venue distribution:

```
For each product with ≥ 30 days of data:
  count_location_types = COUNT(DISTINCT location_type) WHERE sales > 0
  count_machines = COUNT(DISTINCT machine_id) WHERE sales > 0

  IF count_location_types >= 3 AND min_velocity_per_type > threshold:
    category = GLOBAL
  ELIF count_machines <= 3 AND max_venue_group_concentration >= 0.8:
    category = MACHINE_FOCUSED
  ELSE:
    category = INDUSTRY_FOCUSED
```

This is a derivation, not a declaration. The operator does NOT tell Engine 1 which products are which — the data does. The operator only intervenes when the derivation is wrong.

### 2.3 When operators override the derivation

Three scenarios where the operator must override Engine 1's derived category:

1. **Trial products** — a new product in only 1 machine isn't "machine-focused," it's "untested." Override category = `TRIAL` until trial window expires.
2. **Contractually-locked products** — a product restricted by `travel-scope.md` to a specific venue group (like the 8 VOX-locked products) appears as `machine-focused` in data, but its scope is a contractual rule, not a market fact. Override category = `machine-focused-locked` with pointer to travel-scope.md.
3. **Roll-out in progress** — a product being actively expanded from 2 machines to 10 is currently `machine-focused` in data, but the intended category is `global`. Override category = `global-in-rollout` until the expansion completes.

### 2.4 Overrides table

Products whose derived category does not match reality. Most of the catalog has no entry here — the data derivation is correct for ~90% of products.

| `pod_product_name`              | Derived category | Override category | Rationale |
| ------------------------------- | ---------------- | ----------------- | --------- |
| _(none at time of first draft)_ | —                | —                 | —         |

**Maintenance rule:** add a row here only when the operator finds Engine 1's derivation actively misleading its decisions. Do not populate preemptively. Each override is a bug report against the derivation rule — consider whether the rule itself should be tightened instead.

### 2.5 Why this matters for Engine 1

- **Global products** declining in one location_type is not a failure — it may mean one venue shifted. Evaluate against the global trend.
- **Industry-focused products** declining outside their focus type is noise — don't react.
- **Machine-focused products** are evaluated only against their own machines, not fleet-wide averages. A machine-focused product with 3 KEEP slots and 0 other deployments is a success, not a failure to scale.

## 3. The four lifecycle archetypes

Every product in the Boonz catalog is classified into exactly one of four **lifecycle archetypes**. The archetype determines how Engine 1 interprets every data signal about that product. The same velocity decline means different things for a HYPE vs an ALWAYS-ON, so we must know the archetype before we can score.

Archetypes are assigned at the catalog level (one archetype per `pod_product_id`, not per slot) and stored in `boonz_products.lifecycle_archetype` (schema change pending in Phase 1). Products without an archetype default to `TRIAL` and must be promoted to a permanent archetype after the trial window expires.

### 3.1 HYPE 🌊

> Short, intense lifecycle. Launch fast, ride the wave, exit before the crash.

Hype products live on social media attention, novelty, and impulse. Examples: TikTok-viral snacks (Korean cheese, Dubai chocolate), seasonal limited editions, celebrity-endorsed drinks, Gen-Z candy trends. These products are EXPECTED to decline. Decline is not a failure — it's the end of the cycle. The only failure is dragging a hype product past its natural death.

**Structured fields:**

| Field                                  | Value                                                                                                                                                                                                         |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `archetype_name`                       | HYPE                                                                                                                                                                                                          |
| `typical_lifespan_days`                | 60–120                                                                                                                                                                                                        |
| `ramp_up_window_days`                  | 14                                                                                                                                                                                                            |
| `success_threshold_score`              | ≥ 8 within ramp-up window (if it doesn't hit 8 in 2 weeks, this hype isn't for this machine)                                                                                                                  |
| `exit_trigger`                         | Velocity drops ≥ 40% from peak for 14 consecutive days, OR lifecycle score falls below 5                                                                                                                      |
| `min_data_window_before_judgment_days` | 7 (don't kill a hype in the first week)                                                                                                                                                                       |
| `decline_alarm_level`                  | QUIET (decline is expected, no operator alert)                                                                                                                                                                |
| `protected_during_decline`             | NO                                                                                                                                                                                                            |
| `engine_1_default_signal_bias`         | AGGRESSIVE — lean toward action, don't over-protect                                                                                                                                                           |
| `decline_tolerance_pct`                | 40% from peak                                                                                                                                                                                                 |
| `narrative_description`                | Hype products are bets on cultural timing. Know when to enter and, more importantly, when to exit. A hype that doesn't hit score 8+ in 14 days is not a hype for that machine — pull it and try the next one. |

### 3.2 ALWAYS-ON ⚓

> Staple products with stable demand year-round. Never let them stock-out. Treat decline as a problem to investigate.

Always-on products are the backbone of the catalog. Examples: water, gum, Pringles, Coke, Aquafina, Vitamin Well, Chocolate Bar, Pepsi Black. These products are expected to sell at a steady pace indefinitely. **Decline is alarming, not expected** — it signals a problem (refrigeration issue? competitor nearby? SKU swap confusion?) and deserves investigation before any phase-out decision.

**Structured fields:**

| Field                                  | Value                                                                                                                                                                                                                                               |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `archetype_name`                       | ALWAYS-ON                                                                                                                                                                                                                                           |
| `typical_lifespan_days`                | Indefinite (∞)                                                                                                                                                                                                                                      |
| `ramp_up_window_days`                  | 30                                                                                                                                                                                                                                                  |
| `success_threshold_score`              | ≥ 5 sustained for 30 days (doesn't need to be a star, needs to be reliable)                                                                                                                                                                         |
| `exit_trigger`                         | Velocity drops ≥ 25% from rolling 90-day average for ≥ 30 consecutive days, AND investigation concluded (no equipment issue, no competitor shift, no SKU confusion)                                                                                 |
| `min_data_window_before_judgment_days` | 21 (don't react to a bad week)                                                                                                                                                                                                                      |
| `decline_alarm_level`                  | LOUD (decline is anomalous, flag to operator immediately)                                                                                                                                                                                           |
| `protected_during_decline`             | YES — always ask operator before phase-out                                                                                                                                                                                                          |
| `engine_1_default_signal_bias`         | PROTECTIVE — lean toward keep, require strong signal to remove                                                                                                                                                                                      |
| `decline_tolerance_pct`                | 25% from rolling 90-day average                                                                                                                                                                                                                     |
| `narrative_description`                | Always-on products are the foundation of every machine. They don't need to be spectacular — they need to be present and reliable. If an always-on is declining, something is wrong in the world, not in the product. Investigate before you remove. |

### 3.3 SEASONAL 📅

> Predictable cyclical demand. Scale up and down on calendar, not on velocity alone.

Seasonal products are driven by external cyclical forces: weather, religious/cultural calendar (Ramadan, winter holidays), school year, sporting events. Examples: hot drinks in winter, electrolyte drinks in summer heat waves, dates during Ramadan, back-to-school snack bars in September, protein products during January fitness resolutions. **Decline inside the expected trough is not a signal** — it's the cycle. Engine 1 must know the product's seasonal calendar to avoid mis-interpreting normal cycles as failures.

**Structured fields:**

| Field                                  | Value                                                                                                                                                                                                                          |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `archetype_name`                       | SEASONAL                                                                                                                                                                                                                       |
| `typical_lifespan_days`                | Indefinite, with recurring active/dormant windows each year                                                                                                                                                                    |
| `ramp_up_window_days`                  | 14 (within the active season window only)                                                                                                                                                                                      |
| `success_threshold_score`              | ≥ 6 during peak season window                                                                                                                                                                                                  |
| `exit_trigger`                         | Peak season score < 6 for 2 consecutive peak seasons (i.e., 2 years of failing its own cycle)                                                                                                                                  |
| `min_data_window_before_judgment_days` | One full season cycle minimum before any phase-out decision                                                                                                                                                                    |
| `decline_alarm_level`                  | SILENT during expected trough, LOUD during expected peak                                                                                                                                                                       |
| `protected_during_decline`             | YES during trough, NO during peak failure                                                                                                                                                                                      |
| `engine_1_default_signal_bias`         | CALENDAR-AWARE — never judge a seasonal product outside its active window                                                                                                                                                      |
| `decline_tolerance_pct`                | N/A during trough, 30% from prior peak during active season                                                                                                                                                                    |
| `narrative_description`                | Seasonal products must be evaluated on their own cycle, not on the last 30 days. A hot chocolate selling zero in August is not a failure — it's August. The test is whether it sells during its active window, year over year. |

### 3.4 TRIAL 🧪

> New products in active testing. Protected from phase-out during the trial window. Evaluated against trial-specific success criteria, then graduate to one of the other three archetypes or wash out.

Trial is the entry state for every new product added to the catalog. Trial products have no history, so data-driven scoring is unreliable for the first few weeks. During the trial window, Engine 1 does not propose phase-out no matter what the score says. At the end of the trial window, Engine 1 forces a decision: promote to HYPE, ALWAYS-ON, or SEASONAL — or wash out.

**Structured fields:**

| Field                                  | Value                                                                                                                                                                                                                                                                                                 |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `archetype_name`                       | TRIAL                                                                                                                                                                                                                                                                                                 |
| `typical_lifespan_days`                | 60 (fixed window, then forced decision)                                                                                                                                                                                                                                                               |
| `ramp_up_window_days`                  | 30                                                                                                                                                                                                                                                                                                    |
| `success_threshold_score`              | ≥ 5 by day 30 AND ≥ 0.5 transactions/day for ≥ 14 consecutive days                                                                                                                                                                                                                                    |
| `exit_trigger`                         | Day 60 forced decision: promote or wash out. No extensions unless operator override.                                                                                                                                                                                                                  |
| `min_data_window_before_judgment_days` | 30 (the entire ramp-up window is protected)                                                                                                                                                                                                                                                           |
| `decline_alarm_level`                  | QUIET (trial products are expected to fail)                                                                                                                                                                                                                                                           |
| `protected_during_decline`             | YES during trial window (60 days), NO after                                                                                                                                                                                                                                                           |
| `engine_1_default_signal_bias`         | PATIENT — give the trial its full window, don't prematurely conclude                                                                                                                                                                                                                                  |
| `decline_tolerance_pct`                | N/A during trial window                                                                                                                                                                                                                                                                               |
| `narrative_description`                | Trial is the entry state for every new product. The trial window protects new products from premature phase-out, but forces a decision at day 60 so the catalog doesn't drift into perpetual-trial limbo. After day 60, the product either promotes to HYPE / ALWAYS-ON / SEASONAL, or it washes out. |

### 3.5 How Engine 1 uses archetypes

When Engine 1 reads `boonz_products.lifecycle_archetype` for a product, it:

1. Loads the archetype's structured fields from this file (via a parser at startup or embedded lookup table)
2. Combines those fields with the product's actual lifecycle score from `product_lifecycle_global` and `slot_lifecycle`
3. Applies the archetype's `engine_1_default_signal_bias` as a multiplier on its recommendation confidence
4. Checks `exit_trigger` and `min_data_window_before_judgment_days` before proposing any phase-out
5. Emits `decline_alarm_level` as operator notifications for ALWAYS-ON products in decline (loud) vs HYPE products in decline (quiet)

### 3.6 Archetype transitions

A product can move between archetypes over its lifetime, but transitions are always operator-approved, never automatic. Common transitions:

- **TRIAL → ALWAYS-ON**: most common graduation path, for products that prove steady reliable demand
- **TRIAL → HYPE**: for trial products that show explosive early velocity and match hype characteristics
- **TRIAL → SEASONAL**: for trial products that align with an upcoming cycle (rare, usually caught on introduction)
- **HYPE → ALWAYS-ON**: rare but valuable — a hype product that defies decline and settles into sustained demand graduates into the always-on tier
- **ALWAYS-ON → HYPE**: almost never happens; if it does, it usually means the product has lost its "staple" status and is now novelty-driven

Every archetype transition must be logged with a reason code in `decision_log.archetype_transition_reason`.

## 4. Partnerships

### 4.1 Purpose

This section captures commercial relationships between Boonz and brands/suppliers that affect how Engine 1 should treat a product beyond its sales data. A product with a paid placement deal must be pushed harder than its velocity alone would justify. A product on consignment has different risk economics than one bought outright. A product tied to a marketing fund agreement may require specific machine visibility to fulfill contract terms.

### 4.2 Partnership type vocabulary

The following partnership types are recognized by Engine 1. If a new type is needed, add it here and update Engine 1's parser.

| Type             | Definition                                                                              | Effect on Engine 1 behavior                                                                                                            |
| ---------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `none`           | No special arrangement. Product sourced through normal supplier channel, no obligation. | No bias. Engine 1 follows data layer decisions.                                                                                        |
| `paid_placement` | Brand pays Boonz for shelf access (flat fee, per-machine fee, or per-month).            | HIGH push intensity. Protected from phase-out during contract window. Operator must be alerted before any removal proposal.            |
| `consignment`    | Brand provides product, Boonz pays only for units sold.                                 | Reduced phase-out urgency (no inventory risk). Engine 1 can experiment more freely with placement.                                     |
| `volume_deal`    | Preferential wholesale pricing in exchange for a minimum order commitment.              | NORMAL push intensity, but Engine 1 must track total fleet velocity against the volume commitment to avoid underperformance penalties. |
| `marketing_fund` | Brand provides co-marketing budget alongside placement.                                 | HIGH push intensity. Specific machine visibility requirements may apply — check rationale field per product.                           |
| `exclusive`      | Boonz is the only UAE vending operator for this SKU.                                    | HIGH push intensity. Strategic value beyond sales — exclusivity is the asset. Never propose phase-out without operator review.         |
| `supermarket`    | No relationship, Boonz buys from grocery retail. Highest cost, no obligations.          | Zero bias. Normal data-layer decisions. May be biased toward phase-out in favor of better-sourced alternatives.                        |

### 4.3 Active partnerships table

| `pod_product_name`                                                        | Partnership type | Contract start | Contract end | Push intensity | Rationale |
| ------------------------------------------------------------------------- | ---------------- | -------------- | ------------ | -------------- | --------- |
| _(none at time of first draft — populate as commercial deals are signed)_ | —                | —              | —            | —              | —         |

**Maintenance rule:** this table is updated whenever a partnership is signed, modified, or expires. Partnership changes are the most time-sensitive updates this file receives. The file's quarterly review pass should verify every active partnership row has an accurate contract end date.

### 4.4 How Engine 1 applies partnership intent

When Engine 1 evaluates a product with an active partnership:

1. Lookup the partnership type in section 4.3
2. Apply the `push_intensity` override from the vocabulary table
3. Check if the contract end date is within 30 days — if so, flag to operator for renewal decision
4. Include the partnership rationale in any decision explanation passed to the operator via `/refill`

### 4.5 Phase 1 starting state

No partnerships are active at the time of first drafting this file. All products are currently sourced through normal supplier channels (`none` or `supermarket`). The structure is in place for when commercial deals are signed. First real partnership entry will exercise and validate the Engine 1 parser.

## 5. Protected products

### 5.1 Purpose and posture

Protection is **soft and specific**, not blanket. The operator's stated position is: "I'm not focused on 100% protecting products as long as there's a good mix and performance is justified." Protection exists for specific situations where the data would lead Engine 1 to a decision the operator wants to delay or prevent — usually because of a client relationship, a pending test, or a reason outside the data's visibility.

Protected products are NOT immune from phase-out. They receive **grace periods** and **operator-review gates** before Engine 1 acts.

### 5.2 Protection levels

| Level            | Meaning                                                                                                               | Engine 1 behavior                                                                                                                              |
| ---------------- | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `NONE`           | Default. No protection.                                                                                               | Normal data-driven decisions.                                                                                                                  |
| `CLIENT_REQUEST` | A specific client asked for this product at a specific machine. Must stay for a defined window.                       | Engine 1 cannot propose removal of this product from the named machine(s) until `protected_until` date. After expiry, normal behavior resumes. |
| `OPERATOR_WATCH` | Operator is keeping an eye on this product for non-data reasons (testing a sourcing change, monitoring quality, etc). | Engine 1 may propose changes but must flag the protection status so the operator can veto quickly.                                             |
| `PARTNERSHIP`    | Product is protected because of a partnership (see Section 4).                                                        | Inherited from Section 4. Engine 1 must not propose removal without operator review.                                                           |
| `CONTRACTUAL`    | Product is contractually required at specific venues (see `travel-scope.md` VOX lock list).                           | Engine 1 must not propose removal at the contractually-required venues. May propose changes at other venues.                                   |

### 5.3 Active protections table

Each row locks a single product at a single venue (or venue group) until a specific date or condition.

| `pod_product_name`        | Scope           | Level         | Protected until | Rationale                                                                                                                                                                                                                        |
| ------------------------- | --------------- | ------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _(VOX-locked 8 products)_ | VOX venue group | `CONTRACTUAL` | Indefinite      | See `engines/refill/guardrails/travel-scope.md` — these are the 8 products contractually locked to VOX cinemas: Aquafina, Maltesers Chocolate Bag, Skittles Bag, VOX Cotton Candy, VOX Lollies, VOX Popcorn Caramel/Cheese/Salt. |

**Note:** the 8 VOX-locked products already have a pointer from `travel-scope.md`. They appear here only as a cross-reference so Engine 1 has a single lookup path for protection status. The source of truth for the list is `travel-scope.md`.

### 5.4 The VOX Lollies worked example (preview)

VOX Lollies has lifecycle signal `WIND DOWN` (score 4.8) in the data but is currently the #6 revenue earner in the fleet (AED 1,184/30d). Without this file, Engine 1 would propose phase-out based on the declining score. With this file, Engine 1 reads:

1. Section 2: derived category `machine-focused`, overridden to `machine-focused-locked` (travel-scope pointer)
2. Section 3: archetype is `ALWAYS-ON` for VOX-locked products (stable demand during cinema operating hours)
3. Section 5 (this section): protection level `CONTRACTUAL` via VOX venue group
4. Section 6: no phase-out bias

Engine 1's final decision: **keep. Do not propose removal.** Explanation to operator: "VOX Lollies has a declining data signal (WIND DOWN, 4.8) but is contractually locked to VOX venues per travel-scope.md. Protection: CONTRACTUAL. No action proposed. If the contract ever ends, this product's data signal should be re-evaluated."

Full worked example in Section 10.

### 5.5 Maintenance rule

Client-request protections must have an explicit `protected_until` date. No open-ended client-request protections — they drift into permanent entries and pollute the file. When a client-request expires, delete the row (or archive it to a comment) rather than letting it linger.

## 6. Phase-out candidates

### 6.1 Purpose

This section captures products the operator wants to move away from for reasons outside the data layer's visibility. The data might say a product is performing fine, but the operator has other information: the supplier is unreliable, margins have been eroding, the brand is causing ops problems, or the operator has lost commercial appetite for the relationship.

Phase-out bias does NOT force immediate removal. It biases Engine 1 toward proposing phase-out when any data-layer decline signal appears, and toward NOT proposing expansion even if data would support it.

### 6.2 Phase-out bias levels

| Level  | Meaning                                                                                                                   | Engine 1 behavior                                                                                                                                           |
| ------ | ------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NONE` | Default. No phase-out bias.                                                                                               | Normal data-driven decisions.                                                                                                                               |
| `SOFT` | Operator prefers to reduce exposure to this product over time, but current placements are fine until data says otherwise. | Engine 1 will NOT propose expansion of this product to new machines. Engine 1 WILL propose phase-out on any data decline, even small ones.                  |
| `HARD` | Operator wants this product out of the catalog. Timeline is weeks, not months.                                            | Engine 1 proactively proposes phase-out regardless of data signal. Exception: hard protections (Section 5) override hard phase-out bias at specific venues. |

### 6.3 Phase-out reason vocabulary

| Reason code                 | Meaning                                                                                 |
| --------------------------- | --------------------------------------------------------------------------------------- |
| `supplier_unreliable`       | Sourcing has been difficult, stockouts common, supplier responsiveness poor             |
| `margin_erosion`            | Product is still selling but profitability has dropped below acceptable threshold       |
| `brand_misalignment`        | Brand no longer fits Boonz strategic direction (quality perception, positioning)        |
| `operational_friction`      | Product breaks easily, doesn't display well on shelves, hard to load, driver complaints |
| `better_alternative_exists` | A newer product does the same job better                                                |
| `commercial_dispute`        | Ongoing issue with the supplier (pricing, payment terms, contract dispute)              |
| `quality_decline`           | Product quality itself has dropped (taste, shelf life, complaints from end customers)   |

Multiple reasons can apply to a single phase-out entry. The rationale field should name the reason codes and expand on them in prose.

### 6.4 Active phase-out candidates table

Based on operator dump on 2026-04-10, the following brands/products are candidates for phase-out. Each entry is **soft** unless explicitly marked hard, because the operator noted "in some locations it makes sense to keep" for most of them.

| `pod_product_name` or brand | Level  | Reason codes                            | Rationale                                                                                                                                                                                                                                                |
| --------------------------- | ------ | --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 7days (brand, all SKUs)     | `SOFT` | `margin_erosion`, `commercial_dispute`  | Operator flagged 7days as challenging on profit and sourcing. Historically worked only at ADDMIND/IRIS venues — so soft bias, not hard. If ADDMIND/IRIS placements decline, phase out without hesitation. Non-ADDMIND placements should not be expanded. |
| Sabahoo (brand, all SKUs)   | `SOFT` | `margin_erosion`, `supplier_unreliable` | Operator flagged as challenging, not moving in the right direction. Keep existing placements until data decline, then phase out. Do not expand.                                                                                                          |
| YoPro (brand, all SKUs)     | `SOFT` | `margin_erosion`, `commercial_dispute`  | Same pattern — operator wants to reduce exposure. Soft bias to allow remaining placements to run their course.                                                                                                                                           |

**Maintenance rule:** populate this table as the operator identifies specific products or brands to reduce. Phase-out entries should be reviewed quarterly to decide if `SOFT` should escalate to `HARD` or if the situation has improved and the entry should be removed.

### 6.5 Operational quality phase-outs (future product attribute)

The operator also flagged a separate category: "items that break easily, display wise not appealing, hard to put on shelves." These are phase-out drivers that have nothing to do with sales performance and everything to do with ops cost.

**This is tracked separately as a future product attribute** in `boonz_products.operational_quality_score` (schema change, Phase 1+). It is NOT captured in this file as individual entries because it's a physical attribute of the SKU, not an operator intent. When the schema change lands, Engine 1 will read the operational quality score as an additional input to phase-out decisions.

For now (pre-schema-change), operational quality concerns are captured as prose notes in individual phase-out rationale fields above.

### 6.6 How Engine 1 applies phase-out bias

When Engine 1 evaluates a product listed here:

1. Lookup the phase-out bias level
2. If `SOFT`: check the data signal. If any decline at all (signal != `KEEP`, `KEEP GROWING`, or `WATCH`), propose phase-out with explicit reference to both the data signal AND the operator bias.
3. If `HARD`: propose phase-out proactively regardless of current data signal, unless protected by Section 5 at specific venues.
4. Never expand a phase-out candidate to new machines regardless of bias level.

## 7. Trial protocol

### 7.1 Why trials need explicit protocol

New products have no history, so the data layer cannot score them reliably for the first weeks. If Engine 1 applies normal scoring to a trial product, it will either over-react to early noise (killing a good product that had a slow first week) or miss an obvious failure (keeping a dead product because it has 12 days of data). The trial protocol defines a **protected evaluation window** where new products are judged against trial-specific criteria rather than fleet-wide lifecycle scoring.

### 7.2 Trial entry

Every new product enters the catalog as an entry in `boonz_products` with `lifecycle_archetype = TRIAL`. Entry is a manual operator decision today; in Phase 2+ an AI product discovery engine may suggest new trials from external signals (web, social, ecom scan), but the operator still approves every trial entry.

**Trial configuration (per trial):**

| Field                        | Default                             | Notes                                                                                                          |
| ---------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `trial_start_date`           | Today                               | Set when the product is first placed in a machine                                                              |
| `trial_window_days`          | 60                                  | Fixed window, non-extendable without operator override                                                         |
| `trial_machines`             | 1-3                                 | Which machines will host the trial. Chosen by operator based on venue relevance.                               |
| `trial_success_score`        | ≥ 5 by day 30                       | Lifecycle score threshold                                                                                      |
| `trial_success_transactions` | ≥ 0.5/day for ≥ 14 consecutive days | Minimum steady-turnover criterion                                                                              |
| `intended_archetype`         | Any of HYPE / ALWAYS-ON / SEASONAL  | Operator's initial guess about which archetype this product is. Used for early-promotion evaluation (see 7.4). |

### 7.3 Trial protection window

During the first 30 days (the `ramp_up_window_days` for the TRIAL archetype per Section 3.4), Engine 1 does NOT apply normal lifecycle scoring to the product. The data is accumulating, not judging. Specifically:

- No WIND DOWN or ROTATE OUT signals can be emitted for a trial product during the ramp-up window
- No phase-out proposals regardless of velocity
- No cross-machine relocation proposals (the trial set is locked)
- Decline alarms are QUIET (no operator notifications on trial declines)

### 7.4 Trial graduation paths

At day 30 (mid-trial checkpoint) OR day 60 (forced decision), Engine 1 evaluates the trial against the success criteria and proposes one of five outcomes:

| Outcome                          | Trigger                                                                                                             | Next step                                                                                                                   |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **Early promotion to ALWAYS-ON** | Score ≥ 6 AND ≥ 0.5 txn/day for 21 days AND operator's `intended_archetype` was ALWAYS-ON                           | Operator confirms, archetype flips, normal scoring begins                                                                   |
| **Early promotion to HYPE**      | Score ≥ 8 within 14 days (the HYPE success threshold from Section 3.1) AND operator's `intended_archetype` was HYPE | Operator confirms, archetype flips, HYPE exit_trigger rules apply                                                           |
| **Promotion to SEASONAL**        | Score ≥ 6 during peak of its season AND operator's `intended_archetype` was SEASONAL                                | Operator confirms, archetype flips, calendar rules apply                                                                    |
| **Continue trial**               | Day 30 checkpoint only: score trending positive but not at threshold                                                | No action, re-evaluate at day 60                                                                                            |
| **Wash out**                     | Day 60: score < 5 OR transactions < 0.5/day for 14 consecutive days                                                 | Engine 1 proposes phase-out from trial machines. Operator confirms. Row marked phased-out with reason code `trial_failure`. |

### 7.5 Fast-track early promotion

The operator's preference (Q1 answered in CS-01) is the hybrid pattern: default TRIAL window, but early promotion allowed if data supports it. The early-promotion triggers are in the table above. In practice:

- A product that explodes in its first week (score hitting 8+ by day 7) is almost certainly a HYPE. Engine 1 flags it for early promotion to HYPE archetype. Operator confirms. Phase-out timer becomes the HYPE 40%-from-peak rule.
- A product that quietly reaches steady 6+ by day 21 is probably an ALWAYS-ON. Engine 1 flags it for early promotion. Operator confirms. Normal lifecycle scoring begins.
- A product that needs all 60 days to prove itself is fine — no need to rush the graduation.

### 7.6 Trial failures and the "not for this machine" pattern

Not every trial failure means the product is bad. Some trials fail because the product-machine fit is wrong, even though the product is strong elsewhere. Example: a premium protein bar that bombs at an entertainment venue might still be an ALWAYS-ON winner at a corporate office.

When a trial fails, Engine 1 should check whether the product category has succeeded in the same location_type elsewhere in the fleet before concluding phase-out. If similar products work in similar venues, the failure may be product-specific rather than category-specific, and the wash-out proceeds normally. If similar products have failed in this location_type too, the wash-out is evidence of a venue-level mismatch.

### 7.7 Current state (today's manual process)

Trial selection today is reactive and manual: the operator discovers new products via personal research, supplier calls, or grocery store visits. No system-level discovery engine exists. Trials are tracked informally.

**Phase 2 vision:** an AI product discovery subsystem that scans web/social/ecom platforms for emerging product ideas and suggests trials to the operator, along with rationale (why this product, which venues, projected archetype). Operator still approves every trial entry — discovery is automated, decision remains human.

This future work is captured in the bible's Phase 2+ chapter. No Phase 1 engine will implement discovery automation.

## 8. Establishment criteria

### 8.1 Product lifecycle stages (separate from archetype)

A product moves through stages over time, independent of its archetype. The archetype describes _how_ a product is expected to behave. The stage describes _where it is in its journey._ Both matter, and together they determine Engine 1's behavior.

Three stages:

| Stage         | Definition                                                                                                    | Engine 1 treatment                                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **Trial**     | New product, inside the 60-day trial window. See Section 7.                                                   | Protected from phase-out, evaluated on trial criteria only.                                                            |
| **Expansion** | Graduated from trial. Proven at ≥ 1 machine. Being considered for additional machine placements.              | Normal data-driven scoring. Engine 2 may propose relocations to similar venues. Growth is the main question.           |
| **Stable**    | Established at multiple machines with sustained performance. In the top 20 SKUs by revenue (see Section 8.4). | Normal data-driven scoring with ALWAYS-ON bias toward preservation. Growth is no longer the question — reliability is. |

### 8.2 Stage transitions

**Trial → Expansion** (the trial graduation described in Section 7.4):

- Day 30 or day 60 checkpoint
- Score ≥ 5 sustained
- ≥ 0.5 transactions/day for ≥ 14 consecutive days
- Operator confirms archetype classification

**Expansion → Stable:**

- Product has been in the catalog for ≥ 90 days post-trial
- Deployed in ≥ 3 machines (or the operationally maximum number for its `universality` category — machine-focused products can become stable with only their locked machines)
- Has appeared in the top 20 revenue ranking for ≥ 14 consecutive days (see Section 8.4)

**Stable → Expansion** (demotion):

- Product drops out of the top 20 revenue ranking for ≥ 30 consecutive days
- OR is removed from ≥ 1 machine due to data decline
- Returns to Expansion stage for re-evaluation of growth potential

**Stable → Phase-out:**

- Meets the archetype-specific exit trigger from Section 3
- AND operator review confirms (ALWAYS-ON products always require review before phase-out per Section 3.2)

**Expansion → Phase-out (without reaching Stable):**

- Meets the archetype-specific exit trigger
- No operator review required for TRIAL or HYPE archetypes
- Required for ALWAYS-ON (even in Expansion stage)

### 8.3 What "steady turnover at the machine level" means

Per the operator's dump: "For establishing a product it has to reach a steady turnover at the machine level, then we expand it into other relevant locations."

Computable definition:

- **Steady turnover** = ≥ 0.5 transactions/day for ≥ 14 consecutive days at a single machine, with week-over-week variance < 50%
- **Machine-level** = measured per (machine_id, pod_product_id) pair, not aggregated across the fleet
- **Relevant locations** = expansion targets are machines with similar `location_type` and similar existing product mix (Engine 2 relocation planner makes the concrete recommendations)

### 8.4 "Top 20 SKU" definition

Per the operator's preference (CS-01 Q6): **top 20 by revenue** (price × units), measured on a rolling 30-day window.

Computable rule:

```
top_20_by_revenue_30d = (
  SELECT pod_product_id, SUM(paid_amount) AS revenue_30d
  FROM sales_history
  WHERE transaction_date >= NOW() - INTERVAL '30 days'
    AND paid_amount > 0
  GROUP BY pod_product_id
  ORDER BY revenue_30d DESC
  LIMIT 20
)
```

A product is "in the top 20" on a given day if `pod_product_id` is in the above set for that day's calculation. To graduate Expansion → Stable, a product must appear in this set for ≥ 14 consecutive days.

**Future upgrade (Phase 2+):** transition the "top 20" ranking from revenue to **gross profit** (revenue − product_cost) once cost data is reliable across the catalog. Revenue is a proxy; gross profit is the actual business metric. Captured in the bible's Phase 2 chapter.

### 8.5 Current top-performer snapshot (from live data, 2026-04-10)

For reference, the current top 15 products by 30-day revenue:

| Rank | Product                 | Units 30d | Revenue (AED) | Machine spread    | Lifecycle signal |
| ---- | ----------------------- | --------- | ------------- | ----------------- | ---------------- |
| 1    | Aquafina                | 387       | 3,535         | 3 (entertainment) | KEEP GROWING     |
| 2    | Vitamin Well            | 83        | 1,627         | 11 (broad)        | KEEP             |
| 3    | Maltesers Chocolate Bag | 47        | 1,354         | 3 (entertainment) | KEEP GROWING     |
| 4    | VOX Popcorn Caramel     | 52        | 1,352         | 3 (entertainment) | KEEP             |
| 5    | VOX Popcorn Cheese      | 47        | 1,222         | 3 (entertainment) | KEEP GROWING     |
| 6    | VOX Lollies             | 32        | 1,184         | 3 (entertainment) | WIND DOWN        |
| 7    | Chocolate Bar           | 145       | 1,169         | 13 (broad)        | KEEP             |
| 8    | VOX Popcorn Salt        | 43        | 1,134         | 3 (entertainment) | KEEP             |
| 9    | Barebells               | 57        | 1,092         | 11 (broad)        | KEEP             |
| 10   | Pepsi Regular           | 56        | 945           | 3 (entertainment) | KEEP GROWING     |
| 11   | Pepsi Black             | 82        | 870           | 7 (broad)         | KEEP             |
| 12   | M&M Chocolate Bag       | 29        | 870           | 3 (entertainment) | KEEP             |
| 13   | Skittles Bag            | 28        | 824           | 3 (entertainment) | KEEP             |
| 14   | Nutella Biscuits T12    | 31        | 787           | 7 (broad)         | KEEP             |
| 15   | Ice Tea                 | 52        | 724           | 8 (broad)         | KEEP GROWING     |

**Observation:** 10 of the top 15 revenue products are machine-focused (3 machines, entertainment-locked). This is the VOX cluster dominating the top of the catalog. The 5 broad products in the top 15 (Vitamin Well, Chocolate Bar, Barebells, Pepsi Black, Nutella Biscuits, Ice Tea) are the ALWAYS-ON backbone across office and coworking venues.

This snapshot is a **point-in-time reference**, not a rule. Engine 1 computes top-20 fresh daily. The snapshot exists so future operators can see what "good" looked like when this file was first drafted.

## 9. Transition rate limits

### 9.1 The human-led operation constraint

The single most important design principle in this file, from the operator's own words:

> "Frustration is with not getting the data right, and being too aggressive in the scores. It has to be radical but also reasonable. Transitioning is very important — it's not black or white. The more correlation, and plans to adapting new changes are well managed the better it is. **Remember this is a human-led operation — you don't want to change products every day.**"

This principle is a hard constraint on Engine 1's output volume. It is NOT an optimization goal, it's a ceiling. Engine 1 may produce a smaller plan than the data would justify. It may not produce a larger one.

### 9.2 Rate limits

| Limit                                                          | Value | Rationale                                                                                                                                                                                       |
| -------------------------------------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Max slot changes per machine per refill cycle**              | 2     | Drivers can absorb a handful of swaps per visit without losing the main refill workflow. More than 2 at once means the driver spends as much time reconfiguring as refilling.                   |
| **Max machines with any slot change per day**                  | 5     | Even across the fleet, the operator and dispatching team need to review and sanity-check each machine with changes. 5 is the ceiling for a single day's review cycle.                           |
| **Max total slot changes per day (fleet-wide)**                | 10    | Hard ceiling regardless of machine distribution. Engine D enforces this when bonding plan lines from Engine A/C across machines.                                                                |
| **Min days between consecutive changes at the same slot**      | 14    | Once a slot has been swapped, it gets 14 days of stability before Engine 1 is allowed to propose another change at the same (machine_id, shelf_code). Prevents ping-pong between alternatives.  |
| **Max phase-out proposals per product per 30 days**            | 1     | If the operator rejects a phase-out proposal for product X, Engine 1 may not propose phase-out again for 30 days. Reduces noise when the operator has overruled Engine 1 for a specific reason. |
| **Max archetype transition proposals per product per 90 days** | 1     | Archetype changes are rare and deliberate. Even if data strongly suggests a re-classification, Engine 1 gets one shot per 90 days.                                                              |

### 9.3 How Engine D enforces rate limits

The engines upstream of Engine D (Engine 1 portfolio, Engine A layout, Engine C swap, Engine B quantity) may each independently propose changes. Engine D is the sole writer to `refill_plan_output` and is responsible for:

1. **Collecting all proposed changes** from upstream engines for tomorrow's plan
2. **Ranking them by confidence score** — high-confidence data + operator intent alignment wins
3. **Applying rate limits** — truncating the plan when it exceeds any of the ceilings above
4. **Logging truncated proposals** to `decision_log` with reason `rate_limit_exceeded` so the operator can see what Engine 1 wanted to do but was held back

When truncation happens, Engine D prioritizes in this order:

1. **Stockout prevention** (a slot that's empty or nearly empty) — always included, never truncated
2. **Expiry rescue** (a slot with batches about to expire) — always included
3. **Hard phase-out bias** (Section 6 `HARD` level) — included if the data also supports
4. **Slot-level ROTATE OUT signal** (data consensus for removal) — included if below the per-machine ceiling
5. **Swap opportunities** (Engine C proposals to improve layout) — truncated first when ceilings are hit
6. **Relocations** (Engine 2 proposals to move a product to a better machine) — truncated next

### 9.4 Override of rate limits

Rate limits can be overridden manually by the operator on `/refill` with reason code `operator_escalation`. Useful cases:

- Major venue launch — the operator knows about a new anchor tenant and wants to push many changes through before opening day
- Crisis response — a supplier has gone down and multiple products need rapid substitution across the fleet
- Seasonal transition — Ramadan starts, entire beverage section needs adjustment in 48 hours

Overrides are logged in `decision_log` with `operator_action = 'rate_limit_overridden'` and `operator_notes` describing the trigger.

### 9.5 Rate limits are NOT mode-dependent (Phase 1)

In the Phase 2 mode system (Conservative / Balanced / Aggressive), rate limits will vary by mode — Conservative mode tightens them, Aggressive mode loosens them. In Phase 1, rate limits are fixed at the Balanced mode values in the table above. See bible Phase 2 chapter for the full mode-mode parameter design.

## 10. Worked example — VOX Lollies

### 10.1 Why this example exists

VOX Lollies is the clearest case in the current live data of **a product where the data layer and the operator intent layer disagree**, and where the operator intent must win. It's the single best worked example of why this file exists. Any future operator reading this file can point at this example and understand the whole system.

### 10.2 The facts (from live data, 2026-04-10)

| Fact                               | Value                                                    |
| ---------------------------------- | -------------------------------------------------------- |
| `pod_product_name`                 | VOX Lollies                                              |
| `venue_group` distribution         | VOX-only (all 3 deployments in VOX entertainment venues) |
| 30-day units                       | 32                                                       |
| 30-day revenue                     | AED 1,184                                                |
| Fleet rank by revenue (30d)        | #6                                                       |
| `product_lifecycle_global.signal`  | WIND DOWN                                                |
| `product_lifecycle_global.score`   | 4.8                                                      |
| `slot_lifecycle` signal (per slot) | Varies — mostly KEEP, one WIND DOWN                      |

**The data layer's conclusion:** velocity is declining, score has dropped below 5, signal is WIND DOWN. Normal lifecycle logic would propose phase-out at the underperforming slot and flag the product for catalog-level review.

### 10.3 What the data layer cannot see

1. **VOX Lollies is part of the 8-product VOX-locked SKU list** in `engines/refill/guardrails/travel-scope.md`. These 8 products are contractually sourced through VOX and locked to VOX venues. The lock is a contractual fact, not a market outcome.
2. **The product is #6 by revenue in the entire fleet.** Even with declining velocity, it's generating AED ~1,200/month. Phase-out would remove a meaningful revenue line.
3. **Its "decline" is relative to its own prior peak, not to alternatives.** There is no better-performing candy product that could take the same slot at the same venue — the VOX travel-scope constraint limits candidate swaps to other VOX-locked SKUs, most of which are already deployed.
4. **Cinema concession products have inherently noisy velocity** — heavily weighted toward weekends and cinema release schedules. A 14-day decline window may be capturing a quiet cinema period, not a product failure.

### 10.4 How this file's layers combine to produce the correct decision

When Engine 1 evaluates VOX Lollies, it reads:

- **Section 2 (universalities):** derived category is `machine-focused` (3 machines, single venue group). Override not needed — the derivation is correct.
- **Section 3 (archetype):** `lifecycle_archetype = ALWAYS-ON` for the VOX cluster (cinema concession products behave like always-on within their venue scope, even if globally they look niche). `protected_during_decline = YES`. `engine_1_default_signal_bias = PROTECTIVE`.
- **Section 4 (partnerships):** no explicit commercial deal with VOX captured in the partnerships table yet, but the relationship exists operationally (this is a known gap — see Section 4.5).
- **Section 5 (protected products):** `protection_level = CONTRACTUAL` via the VOX venue group lock in travel-scope.md.
- **Section 6 (phase-out candidates):** NOT listed. No operator phase-out bias.
- **Section 9 (rate limits):** not relevant at this stage — Engine 1 isn't even proposing a change.

### 10.5 Engine 1's decision

**Keep. Do not propose removal.** Do not propose reduction in facings. Do not flag for operator review (the alarm level for this product is set low because its decline is within expected scope).

### 10.6 Engine 1's explanation to the operator

If the operator asks "why didn't you suggest changing VOX Lollies even though it's declining?":

> VOX Lollies has a WIND DOWN signal (score 4.8) in the data layer, but is contractually locked to VOX venues per `travel-scope.md`. Its archetype is ALWAYS-ON within the VOX venue scope, and its protection level is CONTRACTUAL. Even with the velocity decline, it remains the #6 revenue product in the fleet (AED 1,184/30d) and there is no VOX-locked alternative available to swap in. No action is proposed. If the VOX contract ends or this product drops below a critical revenue threshold, I will re-evaluate and surface it for your review.

### 10.7 What would change this decision

- The VOX contract ends — `travel-scope.md` updated to remove the lock. Engine 1 re-reads on file change, protection_level drops to NONE, normal lifecycle scoring applies, phase-out likely proposed on next cycle.
- The product drops below a critical revenue threshold (say, bottom 50% of the top 20) — Engine 1 escalates to operator review even under contractual lock, because the business impact has changed.
- A new VOX-branded candy SKU becomes available with better velocity — Engine C proposes the swap, travel-scope allows it (both products are VOX-locked), operator approves.
- The operator manually overrides on `/refill` with reason `one_off_business_reason` — Engine 1 logs the override in `decision_log` and doesn't propose the same change again for 30 days (Section 9.2 rate limit).

### 10.8 The general lesson

Any product appearing in this file has a story that the data cannot fully tell. The file's job is to carry the story alongside the data so Engine 1 can make decisions that the data alone would get wrong. VOX Lollies is one instance; the pattern applies to any product with contractual, relational, operational, or strategic context that overrides the numbers.

## 11. What lives elsewhere

### 11.1 Cross-reference map

This file is one of several guardrail and intelligence files the refill engine consumes. Each has a specific scope. When in doubt about where a rule should live, use this table:

| Question                                                                              | File                                                                            | Scope                                                    |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Which products are we willing to carry, in what stage, with what intent?              | **`portfolio_strategy.md`** (this file)                                         | Catalog-level product intelligence                       |
| Which products can't be in the same machine as which?                                 | `engines/refill/guardrails/coexistence.md`                                      | Slot-level brand exclusivity rules                       |
| Which products are locked to which venue groups?                                      | `engines/refill/guardrails/travel-scope.md`                                     | Machine-level travel restrictions                        |
| How should a slot's facings, share, and physical layout be configured?                | `engines/refill/guardrails/layout.md` (CS-04, pending)                          | Slot-level facing/share rules, anchor slots, 70/30 split |
| How much of each product should go to a slot on a given refill?                       | `engines/refill/guardrails/refill_rules.md` (CS-05, pending)                    | Vitrine minimums, min facings per signal tier            |
| Which machines are in which building for same-day refill clubbing?                    | `machines.building_id` column + `engines/refill/guardrails/routing.md` (future) | Operational routing, not strategic                       |
| Which machines supply from which source?                                              | `machines.source_of_supply` column                                              | Operational sourcing, not strategic                      |
| What is a product's velocity, trend, score, signal right now?                         | `product_lifecycle_global`, `slot_lifecycle`, `sales_history` tables            | Data layer, not strategic                                |
| What are the venue group definitions (ADDMIND, VOX, VML, WPP, OHMYDESK, INDEPENDENT)? | `engines/refill/guardrails/coexistence.md` Section "How venue groups work"      | Cross-referenced here for convenience                    |
| How are refill plan changes rate-limited?                                             | **`portfolio_strategy.md` Section 9**                                           | Change velocity ceiling                                  |

### 11.2 Things that are NOT in this file (and where they go)

- **Operational quality scores** (breakage, shelf appeal, load difficulty) → `boonz_products.operational_quality_score` column, Phase 1+ schema change
- **Physical attributes** (dimensions, weight, temperature requirements) → `boonz_products` or `pod_products` tables
- **Pricing and margin rules** → `product_pricing`, `machine_product_pricing`, `supplier_product_mapping` tables. The "move to top-20 by gross profit" Phase 2 upgrade will join these at query time.
- **Correlation matrix** (which products sell well together) → Phase 1 Stage 0 calculator output, not a manually-curated file
- **Machine similarity matrix** (which machines have similar buyer profiles) → Phase 1 Stage 0 calculator output
- **Demand forecasts** → Phase 1 Stage 0 calculator output
- **Mode parameters** (Conservative / Balanced / Aggressive) → Phase 2 chapter in the bible, not this file
- **AI product discovery suggestions** (external trend scanning) → Phase 2+ subsystem

### 11.3 Maintenance checklist

This file should be reviewed on a **quarterly cadence** plus **on partnership changes**. At each review:

1. **Partnerships (Section 4)** — verify every active row has an accurate contract end date; flag expiring deals; add new deals
2. **Protected products (Section 5)** — delete expired client-request entries; verify CONTRACTUAL entries still match travel-scope.md
3. **Phase-out candidates (Section 6)** — escalate SOFT to HARD where decline continued; remove entries where the situation improved
4. **Category overrides (Section 2.4)** — remove entries where Engine 1's derivation is now correct
5. **Archetype field values (Section 3)** — tune based on observed outcomes; HYPE success threshold and SEASONAL decline tolerance are the most likely to need adjustment after first real cycles
6. **Worked example (Section 10)** — update VOX Lollies facts, or replace with a fresher example if VOX Lollies situation changes materially
7. **Top-15 snapshot (Section 8.5)** — refresh as a point-in-time reference

### 11.4 Version control

This file is committed to the repo at `engines/refill/guardrails/portfolio_strategy.md`. All changes go through git. Each edit should have a commit message describing what changed and why. Major structural changes (adding/removing sections, changing archetype definitions) should bump the bible version (v5.4 → v5.5 etc.) to capture the strategic pivot.

---

---

## Change log

- **2026-04-10** — File drafted in full during CS-01 portfolio strategy interview. All 11 sections populated. Section 3 (lifecycle archetypes) is the structural keystone; Section 10 (VOX Lollies worked example) is the canonical illustration. Phase 1 starts with this file as the operator intent layer for Engine 1.
