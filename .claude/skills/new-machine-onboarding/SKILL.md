---
name: new-machine-onboarding
description: |
  Planning brain for new Boonz machine deployments. Takes an Awarded lead from sales_leads and produces an end-to-end deployment plan: machine config (count, format, address, contacts, source-of-supply), SIM and Adyen terminal pre-assignment, demand-anchored planogram per machine, product-mapping cleanup, draft procurement PO (held), draft dispatching plan (held), and a final validation gate. Outputs a dossier folder under BOONZ BRAIN/leads/<slug>/ plus rows in lead_deployment_plan. Does NOT execute writes to protected entities — when ready, hands off to boonz-master's EXECUTE_DEPLOYMENT_PLAN intent which calls add_new_machine, create_purchase_order, and write_dispatch_plan. Trigger whenever CS says "we got the green light to add machines at X", "plan onboarding for [lead]", "build the deployment plan for [company]", "we awarded [lead]", "procurement plan for the upcoming launch", "stock plan for new machines", or anything similar involving fresh machine deployments.
license: Boonz Internal
---

# New Machine Onboarding — Deployment Planning

End-to-end **planning** workflow for new machine deployments. Picks up after a lead reaches `funnel_stage='Awarded'` in `sales_leads`. Produces a complete, locked deployment plan ready for boonz-master to execute. **Never writes to protected entities directly.**

---

## What this skill does and does NOT do

| Does | Does NOT |
|---|---|
| Read from `sales_leads`, `sim_cards`, `suppliers`, `pod_products`, `boonz_products`, `product_mapping`, `v_sales_history_attributed`, `machines` | Insert into `machines`, `slots`, `slot_lifecycle`, `planogram`, `pod_inventory`, `sim_cards.machine_id`, `purchase_orders`, `dispatch_plan`, `dispatch_lines` |
| Write to `lead_deployment_plan` (planning state) and `sales_lead_activities` (journal) | Call `add_new_machine`, `create_purchase_order`, `write_dispatch_plan` (those are boonz-master's job at execution time) |
| Produce held draft Excels (procurement, dispatch) and PNG visuals | Send the draft PO to a supplier or trigger a dispatch task |
| Recommend product mix from comparable machines (location_type + area + venue_group) | Override `product_mapping` for live machines |
| Lock the plan with `ready_to_execute=true` after gates pass | Mark a deployment "Installed" — that's set by boonz-master after RPCs succeed |

---

## Trigger phrases

- "we got the green light to add machines at [company]"
- "plan onboarding for [lead]"
- "build the deployment plan for [company/branch]"
- "we awarded [lead]"
- "stock plan for the new launch at X"
- Or CS opens the conversation by referencing a lead at `funnel_stage IN ('Negotiation','Awarded')`

Do NOT trigger for:
- Refill plans for live machines → `refill-engine` / `boonz-master`
- Tweaking a single SKU on an existing planogram → SQL on `product_mapping`
- Sales/forecasting analysis → other skills

---

## Memory rules this skill MUST apply

Read these memory files at start. Their content is the authority — do not duplicate the lists in this skill, just reference them and apply.

- `procurement_min_order_qty.md` — box-rounding for POs
- `reference_vox_sourced_products.md` — exclude these SKUs from procurement when `venue_group='VOX'`
- `feedback_evian_1l_guardrail.md` — exclude Evian-1L from candidate set when `location_type IN ('office','coworking')`
- `feedback_no_destructive_changes.md` — never DELETE or silently reduce; this skill never writes to protected entities anyway

---

## Supabase connection

- Project: `eizcexopcuoycuosittm` (ap-south-1)
- Use Supabase MCP for all reads
- All writes are confined to `lead_deployment_plan` and `sales_lead_activities` (non-protected)

---

## The 10-phase workflow

### Phase 0 — Lead lookup

Find the lead in `sales_leads`. Confirm with CS if multiple matches.

```sql
SELECT id, lead_ref, company_name, funnel_stage, engagement_status,
       priority_order, estimated_machines, relationship_type,
       contact_person, contact_email, contact_phone,
       area, location_address, location_type,
       date_initiated, rev_share, installation_date, notes
FROM sales_leads
WHERE company_name ILIKE '%<query>%'
   OR lead_ref ILIKE '%<query>%'
ORDER BY funnel_stage DESC, priority_order ASC;
```

Required to proceed: `funnel_stage IN ('Negotiation','Awarded')`. If `Lead`, `Initiated`, or `Qualification`, ask CS to advance the deal first.

Show CS what was found:

```
🎯 Lead found: [company_name] (ref [lead_ref])
   Stage: [funnel_stage] | Owner: [lead_owner] | Priority: [priority_order]
   Estimated machines: [estimated_machines]
   Area: [area] | Location type: [location_type]
   Contact: [contact_person] <[contact_email]>
   Rev share: [rev_share]% | Target install: [installation_date]
   Latest note: "[truncated notes]"

   Proceed with deployment planning?
```

Also fetch any existing rows in `lead_deployment_plan` — if planning was already started for this lead, resume from where it left off rather than re-doing prior phases.

```sql
SELECT plan_id, machine_index, planned_official_name, planogram_locked,
       procurement_drafted, dispatch_drafted, ready_to_execute, install_target_date
FROM lead_deployment_plan
WHERE lead_id = '<id>'
ORDER BY machine_index;
```

---

### Phase 1 — Venue qualification

Six structured questions. Append answers as a `sales_lead_activities` row of type `note` and into `lead_deployment_plan.notes`. **Don't skip — these catch deal-breakers cheaply.**

1. **Power point:** 24-hour outlet at the placement spot? Amperage?
2. **Cellular signal:** confirmed at the spot, or do we need a wifi backup?
3. **Footprint:** clearance for single-door (≥600mm) or double-door (≥1200mm + door swing)? Floor level + load-bearing OK?
4. **Refill access:** 24/7? After-hours code? Loading dock vs. front door? Weekend security?
5. **Operating hours:** of the venue itself (drives velocity baseline — cinema evenings ≠ office daytime).
6. **Commercial constraints:** rev-share/listing fee/hybrid? Partner-mandated price endings (e.g., AMZ wanted .45/.95)? Premium-only? Excluded categories? Any partner-supplied SKUs (per-deal sourcing rule)?

If any answer is "no" or "unknown", surface as a risk and ask CS whether to continue or pause the deal.

---

### Phase 2 — Machine count and format

Decide per-machine: single-door (16 slots, 4-4-3-3-2) or double-door (32 slots, two 4-4-3-3-2 panels). The lead's `estimated_machines` is a starting point but not binding. CS confirms count and format.

For each planned machine, allocate a `machine_index` (1, 2, 3…) and create or update a `lead_deployment_plan` row:

```sql
INSERT INTO lead_deployment_plan (
  lead_id, machine_index, pod_format, venue_group, location_type,
  pod_address, install_target_date, artifacts_path
) VALUES (
  '<lead_id>', <n>, '<single|double>', '<venue_group>', '<location_type>',
  '<address>', '<date or NULL>', 'BOONZ BRAIN/leads/<slug>/machines/<n>/'
)
ON CONFLICT (lead_id, machine_index) DO UPDATE SET
  pod_format = EXCLUDED.pod_format,
  venue_group = EXCLUDED.venue_group,
  location_type = EXCLUDED.location_type,
  pod_address = EXCLUDED.pod_address,
  install_target_date = EXCLUDED.install_target_date,
  updated_at = now();
```

---

### Phase 3 — Per-machine config spec

For each row in `lead_deployment_plan` for this lead, fill:

- `planned_official_name` — follow Boonz convention `BRAND-####-####-X#`. Pull next-available numbers:
  ```sql
  SELECT MAX(SUBSTRING(official_name FROM '\d{4}')::int) + 1 AS next_pod_number
  FROM machines
  WHERE official_name ~ '^[A-Z]+-\d{4}';
  ```
  Confirm naming with CS before locking — brand prefix (`AMZ`, `OMD`, etc.), pod_number, location_id, format suffix (`W0`, `O1`, `B1` per existing fleet conventions).
- `pod_address`, `contact_person`, `contact_email`, `contact_phone` — copy from `sales_leads`, override per machine if branches differ.
- `source_of_supply` — `'boonz'` (default), `'partner'` (e.g., VOX-style, partner supplies most SKUs), or `'mixed'`. Critical for procurement filtering downstream.

---

### Phase 4 — SIM and Adyen terminal pre-assignment

**SIM card.** Pick from the unassigned pool:

```sql
SELECT sim_id, sim_ref, sim_serial, sim_code, contact_number, sim_renewal, paid_by, notes
FROM sim_cards
WHERE machine_id IS NULL
  AND is_active = true
ORDER BY sim_renewal DESC NULLS LAST, sim_ref ASC
LIMIT 20;
```

Show CS the candidates, get a pick, write `sim_id` into `lead_deployment_plan` (NOT into `sim_cards.machine_id` — that linkage happens at execution time after the machine row exists).

**Adyen terminal serial.** No DB pool yet — CS supplies the physical terminal serial when one is assigned. Capture in `lead_deployment_plan.adyen_terminal_id`. Surface a soft warning if the same `adyen_terminal_id` already exists in `machines.adyen_unique_terminal_id` (could be a stale mapping that needs nulling).

**WEIMI device id.** Capture if known; nullable.

---

### Phase 5 — Smart planogram recommendation

Pull demand-anchored ranking from comparable machines, weighted by similarity. Priority order: (a) `location_type` exact, (b) `area` proximity, (c) `venue_group`. Same-building > same-area > same-city > same-country.

Reference query (adapt the JOIN on `machines.location_type` / `area` to your data — verify `v_sales_history_attributed` columns first):

```sql
WITH comparable AS (
  SELECT m.machine_id
  FROM machines m
  WHERE m.status = 'Active'
    AND m.location_type = '<target_location_type>'
    AND (m.area ILIKE '%<area>%' OR m.venue_group = '<venue_group>')
)
SELECT
  pp.pod_product_name,
  COUNT(*) AS units_60d,
  ROUND(SUM(sh.total_amount)::numeric, 0) AS revenue_60d,
  COUNT(DISTINCT sh.machine_id) AS comparable_machines
FROM v_sales_history_attributed sh
JOIN comparable c ON c.machine_id = sh.machine_id
JOIN pod_products pp ON pp.pod_product_name = sh.pod_product_name
WHERE sh.transaction_date >= NOW() - INTERVAL '60 days'
  AND sh.pod_product_name IS NOT NULL
GROUP BY pp.pod_product_name
ORDER BY units_60d DESC
LIMIT 60;
```

**Apply guardrails before producing the shortlist:**
- If `location_type IN ('office','coworking')` → drop Evian-1L (memory: `feedback_evian_1l_guardrail`).
- If `venue_group='VOX'` and `source_of_supply='partner'` → drop the VOX-sourced list (memory: `reference_vox_sourced_products`).
- If `comparable_machines < 3` for a SKU → flag as "weak signal" but keep in the candidate set.

**Failure mode:** if there are fewer than 3 comparable machines with ≥30 days history, the velocity is priors-only. Surface a warning. CS can choose to proceed using a generic baseline (top sellers fleet-wide for the location_type) or pause until the signal exists.

**Hand to the interactive editor (Phase 6).** The single-door takes the top 16 SKUs; the double-door takes the top 16 mirrored on the right side, OR breaks the mirror with a thematic split (confirm with CS — AMZ split into "Wellness/Pepsi" left vs "Premium snacking/Coke" right).

Every name in the shortlist MUST exist in `pod_products`. Validate:

```sql
SELECT pod_product_name FROM pod_products
WHERE pod_product_name = ANY(ARRAY[<list>]);
```

If any fail, drop them or escalate — never invent brand-flavor SKUs ("Barebells (Salty Peanut)" is wrong; `pod_products` only has `Barebells`).

---

### Phase 6 — Interactive planogram editor

Pre-populate `assets/interactive_editor_template.html` with:
- The velocity-ranked shortlist
- Pricing — default to `pod_products.recommended_selling_price`, override per partner constraint (e.g., AMZ price endings)
- Default capacities from `assets/shelf_capacity_registry.csv` based on shelf and product type

Save the per-machine editor to `BOONZ BRAIN/leads/<slug>/machines/<n>/planogram_editor.html`. Hand the link to CS. They edit in place, the editor autosaves to localStorage and exports a CSV when locked.

When CS exports the locked CSV (`planogram.csv`), validate every row:
- `pod_product_name` exists in `pod_products`
- Slot ID matches the Pod-26 schema (`A01..A04`, `B01..B04`, `C01..C03`, `D01..D03`, `E01..E02` for single-door; double-door doubles with `F..J` or however your scheme runs — confirm).
- No duplicate SKU within a single door unless velocity justifies it.
- `price` is positive and ends per partner constraint.
- `capacity` is within the registry's bounds for shelf+product type.

Set `lead_deployment_plan.planogram_locked=true` on success.

**Pod-26 geometry — hardware-fixed, do not violate:**
- Bottle SKUs (1L, 500ml) → Shelf 5 only
- Cans (330ml) → Shelf 4 only
- Bars/biscuits/yogurt cups → Shelves 1–3
- Capacity ≠ slot count. A "12-unit" slot is depth (12 units stacked, single SKU per lane).

---

### Phase 7 — Product mapping review per machine

For each unique `pod_product_name` on the locked planogram, surface the active mappings:

```sql
SELECT
  pm.mapping_id,
  pp.pod_product_name,
  bp.boonz_product_name, bp.product_brand,
  pm.split_pct, pm.mix_weight,
  pm.is_global_default, pm.machine_id,
  COALESCE(pm.avg_cost, bp.avg_cost) AS unit_cost,
  pm.status
FROM product_mapping pm
JOIN pod_products pp ON pp.pod_product_id = pm.pod_product_id
JOIN boonz_products bp ON bp.product_id = pm.boonz_product_id
WHERE pp.pod_product_name = ANY(ARRAY[<locked_list>])
  AND pm.is_global_default = true
  AND pm.status = 'Active'
ORDER BY pp.pod_product_name, bp.boonz_product_name;
```

For each pod_product, ask CS:
- Use global default split, or override per machine (writes a per-machine `product_mapping` row at execution time, not now)?
- Are any mappings missing entirely? Flag — procurement total will be a lower bound.
- Are any `avg_cost` NULL? Flag — same effect.
- Special cases known: `Be-Kind Bar Protein` and `Popit Mix` have historical mapping/cost gaps; flag explicitly.

Capture overrides as JSON in `lead_deployment_plan.notes` (or a sub-file `product_mapping_overrides.json`) so the EXECUTE intent can apply them after the machine row exists.

---

### Phase 8 — Procurement draft (held)

Run `assets/build_procurement.py`. Inputs: locked planograms across all machines for this lead. The script:

1. Sums `total_inventory_per_slot` per `pod_product_name` across machines.
2. Adds 10% buffer (rounded up).
3. Fans out via `product_mapping` (global default for now, plus any per-machine overrides) to boonz-level demand.
4. For each `boonz_product`: looks up `pod_products.supplier_id` (multi-pod_product → boonz traversal handled inside script).
5. Filters by `source_of_supply`: drops VOX-sourced SKUs for any machine with `venue_group='VOX'` AND `source_of_supply IN ('partner','mixed')`.
6. Applies box-rounding from procurement memory — round up to nearest box-multiple per SKU.
7. Groups by `supplier_id` and `procurement_type` (walk-in vs supplier-delivered).
8. Outputs `procurement_draft.xlsx` with sheets:
   - **Summary** (total cost, total units, supplier count, flag count)
   - **Pod-Level Demand** (per pod_product_name × machine)
   - **Boonz-Level Procurement** (per boonz_product, before and after box-rounding)
   - **By Supplier** (one block per supplier, ready to feed `create_purchase_order`)
   - **By Brand** (sanity check)
   - **Shelf Capacity Registry** (reference)
   - **Validation Flags** (missing mappings, missing avg_cost, missing box size, VOX exclusions applied, Evian-1L exclusions applied)

CS reviews. On approval, set `lead_deployment_plan.procurement_drafted=true`. The Excel is **held** — actual PO creation happens later via boonz-master's EXECUTE_DEPLOYMENT_PLAN, which calls `create_purchase_order` per supplier block.

---

### Phase 9 — Dispatch draft (held)

Per machine, build a pack list mapped to warehouse routing. The dispatching skill (separate, future) will handle the live writes — this skill produces the draft Excel only.

Output `dispatch_draft.xlsx` with:
- One sheet per machine: shelf, slot, pod_product, boonz_product (per mapping split), quantity, source warehouse (WH_CENTRAL / WH_MM / WH_MCC default per geography or CS override).
- Summary sheet: per-warehouse pull totals.
- Flags sheet: products without warehouse stock at the install_target_date — these block dispatch.

Set `lead_deployment_plan.dispatch_drafted=true` when CS signs off.

---

### Phase 10 — Validation gate and lock

Final pass before the plan is `ready_to_execute`:

| Check | Pass condition |
|---|---|
| Every `pod_product_name` on every planogram resolves in `pod_products` | All rows return |
| Every `boonz_product` on the BOM has `avg_cost IS NOT NULL` | If any NULL, list them; CS confirms whether to proceed |
| Every machine has `pod_address`, `contact_person`, `contact_email`, `source_of_supply` | All filled |
| Every machine has a `sim_id` linked in `lead_deployment_plan` | All filled |
| `adyen_terminal_id` on each machine is unique against `machines.adyen_unique_terminal_id` | No collisions |
| If `venue_group='VOX'` → VOX-sourced SKUs absent from procurement BOM | Excluded |
| If any machine has `location_type IN ('office','coworking')` → Evian-1L absent from candidate set | Excluded |
| Comparable demand baseline ≥ 3 machines × 30 days | OR CS explicitly accepted prior-only mode |
| `planogram_locked = true` AND `procurement_drafted = true` AND `dispatch_drafted = true` for every row | All true |

If all pass, set `ready_to_execute=true` for every machine row in this lead. Notify CS:

```
✅ Deployment plan locked and ready for execution.
Lead: [company_name] (ref [lead_ref])
Machines: [N] | Total units to dispatch: [X] | Total PO value: AED [Y]
Suppliers: [count] | Install target: [date]

Dossier: BOONZ BRAIN/leads/<slug>/

To execute, ask Master:
  "Master, execute the deployment plan for <company_name>"
```

Boonz-master's `EXECUTE_DEPLOYMENT_PLAN` intent picks up from there.

---

## Outputs

For each run, deliver:

**Database:**
- One row per machine in `lead_deployment_plan`, with all status gates
- Multiple rows in `sales_lead_activities` documenting decisions

**Filesystem (`BOONZ BRAIN/leads/<slug>/`):**
```
dossier.docx                              ← partner-shareable readable plan
machines/<n>/
  config.json                             ← spec mirror of lead_deployment_plan row
  planogram_editor.html                   ← interactive editor (during phase 6)
  planogram.csv                           ← locked (after phase 6)
  planogram_visual_single.png             ← matplotlib render
  planogram_visual_double.png             ← if double-door
  product_mapping_review.csv              ← phase 7 output
  product_mapping_overrides.json          ← per-machine overrides for execution
procurement_draft.xlsx                    ← phase 8 output (held)
dispatch_draft.xlsx                       ← phase 9 output (held)
decisions_log.md                          ← what was decided, by whom, when
```

---

## Critical principles

- **Demand-anchor, don't deck-anchor.** Curation decks are wishlists. Real velocity from comparable machines is the only reliable input. The AMZ proposal almost shipped a 50-SKU range based on a curation deck until a `v_sales_history_attributed` query showed 75% of the deck wasn't in the top-30 office sellers.
- **Use canonical `pod_product_name` from `pod_products`.** Never invent brand-flavor SKUs. Catch-all SKUs (`Chocolate Bar`, `Snack Bar`) are intentional design — they fan out via `product_mapping` splits.
- **`recommended_selling_price` from `pod_products` is the default.** Override only if partner mandates.
- **Pod-26 geometry is hardware-fixed.** 4-4-3-3-2. Bottles only on Shelf 5. Cans only on Shelf 4. Don't put Vitamin Well on Shelf 1.
- **Constitutional discipline.** This skill never writes to a protected entity. Every Article-1 entity goes through its canonical RPC at execution time, called by boonz-master.
- **Validate against the database before locking.** Every `pod_product_name` must return a row from `pod_products`. Every `boonz_product` must have `avg_cost`. Every machine must have a SIM and a contact.
- **Box-round procurement.** Reference `procurement_min_order_qty.md`; never propose single-digit orders for box-only SKUs.
- **VOX is special.** When the venue_group is VOX and source_of_supply is partner or mixed, the VOX-sourced list is excluded from Boonz procurement. The shelf still plans the SKU; physical stock comes from the VOX team.

---

## Common pitfalls

1. **The product line break is the demand line break, not the deck line break.** Curation decks are wishlists.
2. **Catch-all SKUs (`Chocolate Bar`, `Snack Bar`) are not a bug.** Don't replace with single brands unless CS explicitly asks.
3. **Price endings ending in `.05` are partner-driven.** Confirm before propagating across machines.
4. **"Mirror the single-door on the right side of the double-door"** is the default for consistency. Partners can break the mirror — confirm explicitly.
5. **Capacity ≠ slot count.** A "12-unit" slot means 12 units stacked depth. Single-SKU lane.
6. **Be-Kind Bar Protein and Popit Mix have known mapping/cost gaps.** Flag in every procurement run until the mapping is fixed.
7. **Multi-machine deals are not always single-format.** A four-machine deal might be 2x double-door + 2x single-door. Confirm format per machine_index.
8. **Repeat partners inherit conventions.** When AMZ adds a third site, pull pricing rules and exclusions from prior `lead_deployment_plan` rows for the same partner. Don't redo phase 1.

---

## Hand-off to boonz-master

When `ready_to_execute=true` on every machine row for a lead, the planning skill's job is done. CS triggers execution via boonz-master:

> "Master, execute the deployment plan for [company_name]"

Boonz-master's `EXECUTE_DEPLOYMENT_PLAN` intent (see `boonz-master_execute_deployment_plan_intent.md` patch):
1. Reads `lead_deployment_plan WHERE lead_id = ? AND ready_to_execute = true`
2. For each machine: calls `add_new_machine` RPC → captures returned `machine_id`
3. UPDATE `sim_cards SET machine_id = ?` for the pre-assigned SIM
4. UPDATE `machines SET adyen_unique_terminal_id = ?` for the pre-assigned terminal
5. Writes per-machine `product_mapping` overrides via `UPSERT product_mapping`
6. Calls `create_purchase_order` once per supplier block in the procurement draft
7. Calls `write_dispatch_plan` per machine using the dispatch draft
8. UPDATE `sales_leads SET funnel_stage = 'Installed', updated_at = now() WHERE id = ?`
9. Writes a `sales_lead_activities` row documenting execution
10. Returns a summary to CS

---

## Tools used

- **Supabase MCP** — all reads, plus writes to `lead_deployment_plan` and `sales_lead_activities`
- **xlsx skill** — for procurement and dispatch workbooks
- **docx skill** — for the dossier
- **bash** — to run the procurement and renderer Python scripts
- **canvas-design / brand-guidelines** — for the dossier styling and the planogram visuals

---

## Reference assets

- `assets/interactive_editor_template.html` — drop-in HTML template for Phase 6
- `assets/build_procurement.py` — Phase 8 script (BOM fan-out, supplier grouping, box rounding, exclusion filters)
- `assets/render_planograms.py` — Phase 6/9 matplotlib renderer for single + double-door PNGs
- `assets/shelf_capacity_registry.csv` — default capacities by shelf × product type

---

## Schema dependency

Requires `lead_deployment_plan` table — see `dara_lead_deployment_plan.sql` for the migration spec. If the table doesn't exist yet, the skill should report:

> ⚠️ `lead_deployment_plan` table missing. Apply migration `dara_lead_deployment_plan.sql` (Cody-reviewed) before running this skill.

---

## Memory updates

At end of run, propose memory writes for any partner-specific conventions established:
- Pricing rules ("[Partner] uses .45/.95 price endings")
- Exclusion lists ("[Partner] excludes energy drinks")
- Sourcing arrangements ("[Partner] supplies their own water")
- Refill cadence preferences ("[Partner] requested weekly refills")

Surface for CS approval, write only with consent (per memory hygiene rules).
