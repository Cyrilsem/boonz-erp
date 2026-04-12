# Coexistence Guardrails

**Type:** Coexistence rules  
**Read by:** Engine 2 (Relocation Planner), Engine A (Layout), Engine C (Swap), Engine D (Decider)  
**Last updated:** 2026-04-09  
**Owner:** CS (cyrilsem@gmail.com)

## Purpose

This file lists every rule about which products cannot coexist with which other products, or cannot be placed in which venues. The refill engine consults these rules BEFORE proposing any move. Violations are hard-blocked — not scored down, not warned about, blocked at the planner level.

Exceptions are possible ONLY via the `/refill` review UI with operator override + reason code `one_off_business_reason` + operator notes. There are no rule-level exceptions, temporary carve-outs, or transition periods. If a rule needs to change, this file is the source of truth.

## How venue groups work

Every machine belongs to exactly one venue group, stored in `machines.venue_group`. The group determines which coexistence and travel-scope rules apply.

Possible values:

| Group         | Description                                                                                                                         | Coca-Cola allowed? |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| `ADDMIND`     | Addmind, Ush, Iris — all operated under Addmind Group. Contractually Pepsi-exclusive.                                               | **NO**             |
| `VOX`         | VOX-branded machines (VOXMCC, VOXMM) plus Activate, MP, iFly, Sky (VOX family, currently launching). Contractually Pepsi-exclusive. | **NO**             |
| `VML`         | Both VML machines. No exclusivity, operated as a family for clubbing.                                                               | Yes                |
| `WPP`         | WPP, Mindshare, Wavemaker — all under WPP Group (global advertising holding). Family for clubbing. No exclusivity.                  | Yes                |
| `OHMYDESK`    | Oh My Desk coworking machines (OMDBB, OMDCW). Family for clubbing. No exclusivity.                                                  | Yes                |
| `INDEPENDENT` | Standalone machines with no sibling at other locations. Default for single-location venues.                                         | Yes                |

**Tagging rule:** A machine gets a family group name if it belongs to a multi-machine family. Otherwise it's `INDEPENDENT`. The `INDEPENDENT` tag is never NULL — all machines always have a group value.

## Rule 1 — Coca-Cola portfolio exclusion at Pepsi-exclusive venues

**Applies to:** all machines where `venue_group IN ('ADDMIND', 'VOX')`.

**Rule:** No product from The Coca-Cola Company portfolio may be placed in any machine belonging to the ADDMIND or VOX groups. This is a contractual exclusivity held by Pepsi at these venues and is enforced by the operator.

**Coca-Cola Company portfolio (non-exhaustive, the refill engine should treat any TCCC-owned brand as covered):**

- **Colas:** Coca-Cola, Coke Zero, Coke Light, Diet Coke, Coca-Cola Life
- **Other sparkling:** Sprite, Fanta (all flavors), Schweppes, Seagram's, Appletiser, Lilt
- **Water:** Dasani, Glacéau Smartwater, Topo Chico
- **Sports/energy:** Powerade, Monster Energy, Reign (Monster-affiliated), Burn
- **Juices & tea:** Minute Maid, Del Valle, Fuze Tea, Honest Tea, Innocent
- **Enhanced water:** Glacéau Vitaminwater
- **Coffee RTD:** Costa Coffee RTD cans, Georgia Coffee

If in doubt about whether a brand is Coca-Cola Company owned, the refill engine should treat it as covered by this rule and ask the operator via override reason `one_off_business_reason` or `disagree_with_logic`.

**Scope of the exclusion:** the full portfolio, not beverage-only. Even if TCCC launches a new snack or non-beverage SKU, it is covered by this rule by default.

**Rationale:** signed contracts with Pepsi at Addmind and VOX venues. This is not a preference, not a relationship, not a soft rule. It is a legal exclusivity that overrides all sales/lifecycle/optimization signals.

**Pepsi products (the other side):** no restriction on Pepsi products anywhere. Pepsi may go to ADDMIND, VOX, and every other group including INDEPENDENT machines.

## Rule 2 — Same product family within a machine

**Applies to:** all machines, all venue groups.

**Rule:** Two slots in the same machine should not hold products from the same `product_family`. When the refill engine proposes a swap that would create duplicate families, it must either pick a different candidate or escalate to the operator with an override request.

This is a soft-block, not a hard-block — there are times when the operator intentionally double-stocks a family (e.g., Barebells Protein Bar in 2 slots because it's a top seller at the venue). The engine should ask, not decide unilaterally.

**Note:** `product_family` is defined in `product_families` (102 families today). Refill engine should use this table as the source of truth for family membership, not brand name inference.

## Coexistence rules (machine-level exclusions)

Rules derived from operator-approved matrix (2026-04-12).
All rules are bidirectional. Engine C enforces these at candidate
scoring time — any candidate that violates a rule for a product
already on the machine is filtered out before scoring.

### Group 1 — Soft Drinks Mix exclusions

Soft Drinks Mix is a catch-all CSD slot. It cannot coexist with any
specific CSD because it duplicates them. If a machine already has any
of the following, Soft Drinks Mix must not be proposed (and vice versa):

| Product A           | Product B       |
| ------------------- | --------------- |
| 7up And Sprite Lime | Soft Drinks Mix |
| Coca Cola Mix       | Soft Drinks Mix |
| Coca Cola Regular   | Soft Drinks Mix |
| Coca Cola Zero      | Soft Drinks Mix |
| Mountain Dew        | Soft Drinks Mix |
| Pepsi Black         | Soft Drinks Mix |
| Pepsi Mix           | Soft Drinks Mix |

### Group 2 — Coca Cola variants (max 1 per machine)

Only one Coca Cola variant per machine. Having both Mix and Zero,
or Regular and Zero, etc., is duplication.

| Product A         | Product B         |
| ----------------- | ----------------- |
| Coca Cola Mix     | Coca Cola Regular |
| Coca Cola Mix     | Coca Cola Zero    |
| Coca Cola Regular | Coca Cola Zero    |

Note: Coca Cola and Pepsi CAN coexist on the same machine.

### Group 3 — Pepsi variants (max 1 per machine)

Only one Pepsi variant per machine.

| Product A   | Product B |
| ----------- | --------- |
| Pepsi Black | Pepsi Mix |

### Group 4 — Almarai Juice flavours (max 1 per machine)

Only one Almarai Farm Select Juice flavour per machine.

| Product A                        | Product B                             |
| -------------------------------- | ------------------------------------- |
| Almarai Farm Select Juice Mix    | Almarai Farm Select Juice Orange      |
| Almarai Farm Select Juice Mix    | Almarai Farm Select Juice Pomegranate |
| Almarai Farm Select Juice Orange | Almarai Farm Select Juice Pomegranate |

### Group 5 — Sparkling water (max 1 brand per machine)

Only one sparkling water brand per machine.

| Product A       | Product B                                   |
| --------------- | ------------------------------------------- |
| Evian Sparkling | Perrier Regular                             |
| Evian Sparkling | Perrier Sparking Water Regular and Flavored |

### Group 6 — Krambals family (max 1 variant per machine)

| Product A       | Product B       |
| --------------- | --------------- |
| Krambals        | Krambals & Zigi |
| Krambals & Zigi | Zigi            |

### Group 7 — Loacker family (max 1 variant per machine)

| Product A | Product B          |
| --------- | ------------------ |
| Loacker   | Loacker Quadratini |

## Override protocol

When an operator overrides a rule on `/refill`:

1. The plan line is saved with the override value
2. A row is inserted into `decision_log` with:
   - `operator_action = 'overridden'`
   - `operator_reason = 'one_off_business_reason'` (the canonical reason for guardrail overrides)
   - `operator_notes` = free-text explanation
3. The override does NOT modify this file. This file stays canonical.
4. The learning loop (Engine D) does NOT use guardrail overrides as learning signal. `one_off_business_reason` is explicitly excluded from rank adjustments.

## Change log

- **2026-04-13** — Rule 3 (reserved) replaced with 19-pair product-level coexistence matrix (Groups 1–7). Engine C v1 enforces these as Rule 7 at candidate scoring time. Source: operator-approved matrix 2026-04-12.
- **2026-04-09** — File created during Phase 0 guardrail interview. Coca-Cola exclusion rule formalized. Venue group taxonomy (ADDMIND, VOX, VML, WPP, OHMYDESK, INDEPENDENT) defined. Same-family soft-block added as Rule 2.
