---
name: refill-engine
description: "Run the Boonz refill brain. Stock data is refreshed automatically every 4 hours via n8n. This skill queries Supabase directly to generate a refill plan. Usage: /refill-engine [filter] [date] [--fill=max|target|conservative]. Filter options: all, office, coworking, vox, wpp, addmind (group = ADDMIND-1007 + USH-1008), vml, ohmydesk, or exact machine name like ADDMIND-1007-0000-W0. Date options: tomorrow (default), today, YYYY-MM-DD. Fill modes: max (default, fill heroes to max), target (velocity-only v5.10), conservative (14d cover)."
---

# Refill Engine (v6 — P0 rewrite)

## Overview

Stock and sales data is kept fresh automatically by n8n (every 4 hours). This skill
queries Supabase directly — no terminal, no local server, no Weimi calls. It reads
live slot data via one DB function per machine, applies v5.10 business rules, writes
the plan with a single batch call, and opens /refill. The packing UI fires
`push_plan_to_dispatch()` when the operator approves — the skill does NOT write to
`refill_dispatching` for Leg-2.

For VOX machines that have staging rooms, the skill also produces **Leg 1** (WH_CENTRAL
→ staging top-up) rows. Leg-1 is still a direct INSERT into `refill_dispatching`
because it has no machine_id/shelf_id.

**Target runtime:** ~60–90 seconds for a full run (down from 10+ min). If a run
exceeds 3 minutes, something went wrong — stop and diagnose rather than retrying.

## Supabase connection

- Project: `eizcexopcuoycuosittm` (ap-south-1)
- Use the Supabase MCP tool for all queries
- Warehouse IDs:
  - WH_CENTRAL = `4bebef68-9e36-4a5c-9c2c-142f8dbdae85`
  - WH_MM = `0aef9ccf-32ad-4545-8413-29bebd931d0b`
  - WH_MCC = `4fcfb52c-271f-4aa7-a373-3495e3271cd3`

## Argument parsing

```
/refill-engine [filter] [date] [--fill=<mode>]
```

**filter** (positional, optional):

- nothing or `all` → all machines
- `addmind` → venue_group = 'ADDMIND' (ADDMIND-1007 + USH-1008)
- `ADDMIND-1007-0000-W0`, `USH-1008-0000-W1`, etc → exact machine
- `vml`, `vox`, `ohmydesk`, `wpp` → venue_group
- `office`, `coworking` → location_type

**date** (positional, optional):

- nothing or `tomorrow` → CURRENT_DATE + 1
- `today` → CURRENT_DATE
- `YYYY-MM-DD` → as-is

**--fill** (optional flag, default `max`):

- `--fill=max` (default) — top sellers fill to max_stock; KEEP uses 28-day cover; MONITOR uses 14-day + 70% cap. This is what CS was forcing manually every run.
- `--fill=target` — strict v5.10: velocity_target + floors, no max-filling. Safer when warehouse stock is tight.
- `--fill=conservative` — 14-day cover, flat floor=3, no max-filling. For new machines or low-confidence weeks.

---

## The six v5.10 rules (applied by this skill — no longer in a separate memory file)

1. **Variant floor** — for multi-variant products, `variant_floor = MIN(variant_count × (3 if drink else 1), FLOOR(0.80 × max_stock))`. Applied in target computation.
2. **MONITOR 70% cap** — MONITOR slots cap at `FLOOR(0.70 × max_stock)` regardless of other signals.
3. **First-2-swaps-free** — the first 2 SWAP pairs per machine bypass the 14-day cooldown. Swap #3+ on the same machine obeys cooldown. Max 2 pairs/machine still enforced per cycle.
4. **Local velocity override** — if a product is globally WIND DOWN but is a top-3 seller on _this_ machine (rank ≤ 3 AND daily_avg ≥ 0.10), force classification to KEEP. Do not wind down a machine's best sellers.
5. **No SWAP label unless swapping** — never write action = `SWAP` unless the plan specifies a concrete replacement SKU. If a slot only needs a refill, use REFILL. If it needs nothing, omit it.
6. **Driver-friendly comments** — `Refill +N (to X/Y). [one-line reason].` Use `⚠️ ALERT:` prefix for expiry, audit issues, or manual overrides. No jargon (no "VF=9, DAvg=0.40, MONITOR cap"). Drivers are not analysts.

---

## STEP 1 — Get machines in scope

One small query. Keep this — it returns warehouse routing info needed for Leg-1.

```sql
SELECT m.machine_id, m.official_name, m.location_type, m.venue_group,
       m.cabinet_count, m.source_of_supply,
       m.primary_warehouse_id,
       pw.name AS primary_warehouse_name,
       m.secondary_warehouse_id,
       sw.name AS secondary_warehouse_name
FROM machines m
LEFT JOIN warehouses pw ON pw.warehouse_id = m.primary_warehouse_id
LEFT JOIN warehouses sw ON sw.warehouse_id = m.secondary_warehouse_id
WHERE m.include_in_refill = true
  AND m.repurposed_at IS NULL
  -- FILTER: replace the WHERE clause based on argument:
  -- all:       (no extra filter)
  -- addmind:   AND m.venue_group = 'ADDMIND'
  -- vox:       AND m.venue_group = 'VOX'
  -- vml:       AND m.venue_group = 'VML'
  -- ohmydesk:  AND m.venue_group = 'OHMYDESK'
  -- wpp:       AND m.venue_group = 'WPP'
  -- office:    AND m.location_type = 'office'
  -- coworking: AND m.location_type = 'coworking'
  -- exact:     AND m.official_name = 'ADDMIND-1007-0000-W0'
ORDER BY m.official_name;
```

If 0 machines returned → report "No machines found for filter" and stop.

Identify which machines have a staging warehouse (primary*warehouse_name ≠ 'WH_CENTRAL').
Currently: VOXMM-* → WH*MM, VOXMCC-* → WH_MCC, everything else → WH_CENTRAL (no Leg-1).

## STEP 2 — Get per-machine slot state (one call per machine)

**This replaces old Steps 2, 3, 4, and 6a in a single server-side call per machine.**
The function returns slot + current stock + max + expiry_days + expiry_qty + 7d velocity +
classification + suggested replacement, all pre-computed.

For each machine in scope:

```sql
SELECT * FROM get_machine_slots_with_expiry('<machine_official_name>');
```

Returns one row per slot with columns:

- `slot`, `product`, `current_stock`, `max_stock`, `fill_pct`
- `expiry_days`, `expiry_qty` — batch-level expiry from pod_inventory
- `target_stock`, `refill_qty` — from refill_instructions (fallback: max_stock)
- `strategy`, `action_code` — Engine output (PROTECT/PROMOTE/SUSTAIN/BLEED/MAINTAIN)
- `global_product_status`, `local_performance_role`, `local_product_strategy`
- `suggested_product` — swap-in candidate from refill_instructions
- `units_sold_7d`, `product_base_score`

**Performance note:** each call is ~10–20ms on the DB. 83 machines × ~20ms ≈ 1.7s total.
Batch these calls — do NOT add narration between calls.

### Map function output to v5.10 classification

| Function `local_performance_role` | Function `global_product_status` | v5.10 classification             |
| --------------------------------- | -------------------------------- | -------------------------------- |
| 👑 Local Hero                     | any                              | **DOUBLE_DOWN**                  |
| ✅ Standard                       | 💎 Global Hero                   | **KEEP (priority)**              |
| ✅ Standard                       | anything else                    | **KEEP**                         |
| 🐕 Local Dog                      | any                              | **MONITOR** (caps at 70%)        |
| 💀 Dead Stock                     | any                              | **DISCONTINUE** (swap candidate) |

Then apply **rule 4 (local velocity override)**:

- Compute per-machine rank by `units_sold_7d` DESC.
- If classification = MONITOR AND rank ≤ 3 AND `units_sold_7d / 7 ≥ 0.10` → promote to **KEEP**.

## STEP 3 — Get 14-day cooldown history (for swap rate limits)

Small query; keep as-is.

```sql
SELECT machine_name, shelf_code, action, plan_date
FROM refill_plan_output
WHERE machine_name = ANY(<array of machine names>)
  AND action IN ('SWAP', 'REMOVE', 'ADD NEW')
  AND plan_date >= CURRENT_DATE - INTERVAL '14 days'
  AND operator_status = 'approved'
LIMIT 1000;
```

Build `cooldown[machine_name]` → set of shelf_codes. Note: under **rule 3** the first
2 swaps per machine ignore this set; only swap #3+ checks it.

## STEP 4 — Get variant counts (for Rule 1)

Run once per engine invocation; cache the result in a map.

```sql
SELECT pp.pod_product_name,
       bp.product_category,
       bp.attr_drink,
       COUNT(DISTINCT pm.boonz_product_id) AS variant_count
FROM product_mapping pm
JOIN pod_products pp   ON pp.pod_product_id = pm.pod_product_id
JOIN boonz_products bp ON bp.product_id = pm.boonz_product_id
GROUP BY pp.pod_product_name, bp.product_category, bp.attr_drink;
```

Drink categories for variant floor: `Soft Drinks`, `Iced Coffee & Tea`,
`Energy & Sports Drinks`, `Sparkling Water`, `Vitamin & Health Drinks`, `Water`,
`Protein Pudding`, `Dairy & Yogurt`. Everything else is snack.

`variant_floor_raw = variant_count × (3 if drink else 1)`

## STEP 5 — Get warehouse stock (one query, scoped to warehouses actually needed)

Smaller version of the old Step 6 — needed for swap-candidate validation, Leg-1
top-up sizing, and the 60% shelf rule.

```sql
SELECT wi.boonz_product_id, wi.warehouse_id,
       w.name AS warehouse_name,
       bp.boonz_product_name, bp.product_category, bp.attr_drink,
       bp.storage_temp_requirement,
       wi.warehouse_stock, wi.expiration_date,
       pp.pod_product_name
FROM warehouse_inventory wi
JOIN warehouses w         ON w.warehouse_id = wi.warehouse_id
JOIN boonz_products bp    ON bp.product_id = wi.boonz_product_id
JOIN product_mapping pm   ON pm.boonz_product_id = wi.boonz_product_id AND pm.is_global_default = true
JOIN pod_products pp      ON pp.pod_product_id = pm.pod_product_id
WHERE wi.status = 'Active'
  AND wi.warehouse_stock >= 4
  AND (wi.expiration_date IS NULL OR wi.expiration_date > CURRENT_DATE + 14)
  AND wi.warehouse_id IN (
    '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'           -- WH_CENTRAL (always)
    -- + WH_MM if any VOXMM machines in scope
    -- + WH_MCC if any VOXMCC machines in scope
  )
ORDER BY w.name, bp.product_category, wi.expiration_date ASC NULLS LAST
LIMIT 2000;
```

Build two maps:

- `central_stock[boonz_product_name]` → qty
- `staging_stock[warehouse_name][boonz_product_name]` → qty

## STEP 6 — Compute target and action per slot

For each slot from Step 2, combine the v5.10 classification with `--fill` mode:

### 6.1 Target calculation by --fill mode

Let `daily_avg = units_sold_7d / 7`, `mode_floor = 3`.

**`--fill=max` (default)**:

| Classification                        | Target                                                                 |
| ------------------------------------- | ---------------------------------------------------------------------- |
| DOUBLE_DOWN                           | `max_stock`                                                            |
| KEEP AND top-3 seller on this machine | `max_stock`                                                            |
| KEEP (regular)                        | `MIN(MAX(CEIL(daily_avg × 28), mode_floor, variant_floor), max_stock)` |
| MONITOR                               | `MIN(CEIL(daily_avg × 14), FLOOR(0.70 × max_stock))`                   |
| DISCONTINUE                           | `0` (triggers SWAP)                                                    |

**`--fill=target`** (strict v5.10):

- `target = MIN(MAX(CEIL(daily_avg × 21), mode_floor, variant_floor), max_stock)`
- If MONITOR: `target = MIN(target, FLOOR(0.70 × max_stock))`

**`--fill=conservative`**:

- `target = MIN(MAX(CEIL(daily_avg × 14), 3), max_stock)`
- MONITOR still caps at 70%.

In all modes, `refill_qty = MAX(target - current_stock, 0)`.

### 6.2 Expiry override (always applied)

If `expiry_days ≤ 14` AND `expiry_qty ≥ current_stock × 0.5`:

- Force `refill_qty = 0` (don't pile more on top of about-to-expire stock)
- Add `⚠️ ALERT: <expiry_qty> units expire in <expiry_days>d — pull before restocking` to comment
- Propose SWAP if classification is already DISCONTINUE and a `suggested_product` is available

### 6.3 Action assignment (Rule 5)

- `refill_qty > 0` AND classification ≠ DISCONTINUE → action = **REFILL**
- classification = DISCONTINUE AND `suggested_product` not null AND (first-2-swaps-free OR not in cooldown) AND warehouse has ≥ 60% of max_stock → action = **SWAP** (emit REMOVE + ADD NEW pair)
- classification = MONITOR AND daily_avg = 0 AND slot_age implied from 7d=0 → action = **SWAP** (only if candidate and stock available; else skip)
- Otherwise → skip the slot (do NOT write a `SWAP` row with no replacement — that confuses the driver)

### 6.4 Swap rate limits

Per machine, cap at **2 SWAP pairs per run**. Across the whole run, cap at **5 machines with swaps per day** (pick the machines with the most DISCONTINUE slots first).

For each candidate swap:

- Candidate not already on this machine
- Not VOX-exclusive (Aquafina, VOX Popcorn, VOX Lollies, VOX Cotton Candy, Maltesers Bag, M&M Bag, Skittles Bag) unless machine is VOX
- **60% shelf rule**: initial fill ≥ `CEIL(0.60 × max_stock)`, min 6 for drinks, min 4 for snacks
- Must have that qty available in the machine's source warehouse (staging for VOX ambient, else central). Cold products always from WH_CENTRAL.
- If not enough in source, try brand-level fallback SKU; if still short, skip the swap.

## STEP 7 — Trip-efficiency gate (machine level)

Before finalising, sum `refill_qty` across all slots per machine.

Drop a machine from the plan if **all** of these hold:

- `total_refill_units < 6`
- no SWAP pair on that machine
- no slot has `expiry_days ≤ 7` (there's no expiry pressure)
- it is NOT clustered with another included machine (same `location_id` or same `venue_group` at a shared building)

Log dropped machines in the report with reason `deferred: low volume (<N> units)`.
Drivers see what got cut and why.

## STEP 8 — Leg 1 staging top-up (VOX machines only)

Skip entirely if no machines in scope have a staging warehouse.

For each unique staging warehouse (WH_MM, WH_MCC):

```
For each ambient SKU currently stocked in that staging warehouse:
  machines_served = machines in scope whose primary_wh = this staging warehouse
  combined_daily_avg = SUM(daily_avg for this SKU across machines_served)
  projected_stock = current_staging_stock - SUM(Leg-2 refill_qty for this SKU today)
  days_cover_remaining = projected_stock / combined_daily_avg

  If days_cover_remaining < 7 (or projected_stock < 0):
    top_up_qty = CEIL(combined_daily_avg × 21) - projected_stock
    top_up_qty = MIN(top_up_qty, central_stock[boonz_product_name])
    If top_up_qty > 0: emit Leg-1 row
```

Cold products never route through staging — skip them here.

### Writing Leg 1 (direct INSERT — no DB function covers this yet)

```sql
INSERT INTO refill_dispatching (
  dispatch_id, machine_id, shelf_id, pod_product_id, boonz_product_id,
  dispatch_date, action, quantity, include, comment,
  from_warehouse_id, to_warehouse_id
) VALUES (
  gen_random_uuid(),
  NULL, NULL, NULL,
  '<boonz_product_id>',
  '<date>',
  'Restock Staging',
  <top_up_qty>,
  true,
  'Leg 1: WH_CENTRAL → <staging_warehouse_name> | <days_cover_remaining> days cover remaining after today',
  '4bebef68-9e36-4a5c-9c2c-142f8dbdae85',
  '<staging_warehouse_id>'
);
```

Note: `machine_id` has a NOT NULL constraint in the current schema. If that's not
yet migrated, emit Leg-1 into the Step 10 report only and flag that the migration
is still pending.

## STEP 9 — Write the plan (ONE batched call)

Build the lines array as jsonb, then call `write_refill_plan(plan_date, lines)`.
**This replaces ~N individual INSERTs from the old Step 8.**

### 9.1 Build the jsonb lines array

Each REFILL slot → one line:

```json
{
  "machine_name": "VML-1003-0400-O1",
  "machine_priority": 1,
  "shelf_code": "A06",
  "pod_product_name": "Coca Cola Zero",
  "boonz_product_name": "Coca Cola Zero - Regular",
  "action": "Refill",
  "quantity": 5,
  "current_stock": 3,
  "max_stock": 10,
  "smart_target": 8,
  "tier": "KEEP",
  "global_score": 7.2,
  "sold_7d": 12,
  "fill_pct": 30,
  "comment": "Refill +5 (to 8/10). Top seller (12 sold/7d)."
}
```

Each SWAP pair → two lines on the same (machine_name, shelf_code): one with
`action: "Remove"` (old product, quantity = current_stock, tier = "DISCONTINUE"),
one with `action: "Add New"` (new product, quantity = 60% fill). The ADD NEW comment
**must** start with the literal `REPLACES: <old pod_product_name>` — the UI parses
this to render the swap card.

### 9.2 Call the batch writer

```sql
SELECT write_refill_plan(
  '<plan_date>'::date,
  '[ ...lines... ]'::jsonb
);
```

Returns `{"status":"ok","plan_date":"...","lines_written":N}`. The function DELETEs
existing pending rows for that date first, then INSERTs — no need for ON CONFLICT
handling and no per-row round-trip.

### 9.3 Leg-1 INSERT (per Step 8)

Run the Leg-1 INSERT(s) separately after `write_refill_plan`.

### 9.4 Dispatching is NOT the engine's job

Do NOT write to `refill_dispatching` for Leg-2. When the operator approves a row in
the /refill UI, the UI calls `push_plan_to_dispatch(plan_date, machine_name)` which
resolves shelf_id + pod_product_id + boonz_product_id + from_warehouse_id server-side
and writes the dispatch row. The engine's responsibility ends at a pending plan.

### 9.5 Post-write verification (cheap sanity check)

```sql
SELECT COUNT(*) AS lines,
       SUM(quantity) AS units,
       COUNT(*) FILTER (WHERE action = 'Refill')   AS refills,
       COUNT(*) FILTER (WHERE action = 'Add New')  AS add_news,
       COUNT(*) FILTER (WHERE action = 'Remove')   AS removes
FROM refill_plan_output
WHERE plan_date = '<plan_date>' AND operator_status = 'pending';
```

Numbers should match what Step 6/7 produced. If not, stop and investigate before
reporting.

## STEP 10 — Report and open /refill

Driver-facing report — print what changed, what was skipped, what to watch:

```
✅ Refill plan generated (<fill_mode>)
📅 Date: <date>
🏭 Filter: <filter> (<N> machines in scope, <M> in plan)
📊 Snapshot: <snapshot_at> (<X>h ago)

By machine (sorted by total units DESC):
  VML-1003 — 18 units · 6 refills · 1 swap                [🟩 Star]
  VML-1004 — 12 units · 4 refills · 0 swaps               [🟨 Stable]
  ...
  ADDMIND-1007 — deferred: low volume (3 units, no swap, no expiry)

⏳ Expiry flags (3):
  VML-1003 A06: Coca Cola Zero — 8 units expire in 6d
  USH-1008 B02: Evian Regular — 4 units expired (pull on arrival)
  ADDMIND-1007 A12: Krambals — 6 units expire in 11d

🔁 Swaps proposed (N pairs across M machines):
  VML-1004 A09: Perrier Slim → Oh! Sparkling Lemon (1st of 2 free, cooldown bypassed)
  ...

── Leg 1 — Staging Top-Up ──
  WH_MM:
    Evian - Regular × 24  (projected 4d cover remaining)
    Coca Cola - Regular × 18
  WH_MCC:
    (no top-up needed)

📋 Plan total: <N> lines · <U> units
🔗 https://boonz-erp.vercel.app/refill
```

Then open https://boonz-erp.vercel.app/refill.

---

## Critical rules (non-negotiable)

- **Never call localhost** or any terminal command. This skill is Supabase-only.
- **Never call Weimi API** — n8n handles it.
- **Never modify `weimi_device_status`** — read-only.
- **Always show `snapshot_at`** so operator knows data freshness. If >6h old, warn: `⚠️ Data is Xh old — n8n refresh may have failed`.
- **VOX-exclusive products never go on non-VOX machines.**
- **Cold products (`storage_temp_requirement = 'cold'`) always source from WH_CENTRAL** — staging rooms are ambient-only.
- **Don't write `SWAP` unless you have a specific replacement SKU** (rule 5). Drivers can't act on a SWAP row with no ADD NEW counterpart.
- **Never write per-row INSERTs into `refill_plan_output`.** Always use `write_refill_plan(date, jsonb)` — it's faster and atomic.
- **Never write `refill_dispatching` rows for Leg-2** — that's the UI's job via `push_plan_to_dispatch`. The engine only owns `refill_plan_output` plus Leg-1 dispatch rows.
- **Trip-efficiency gate** (Step 7) is mandatory — if you can't justify a van opening a machine for <6 units, don't.

## Quick reference — the six v5.10 rules (one-liners)

1. **Variant floor** — multi-variant products need more slot depth. `floor = MIN(vc × (3 drinks / 1 snacks), 0.80 × max_stock)`.
2. **MONITOR 70% cap** — winding-down slots cap at 70% of max_stock.
3. **First-2-swaps-free** — first 2 SWAP pairs per machine ignore 14-day cooldown.
4. **Local velocity override** — top-3 sellers per machine stay KEEP even if globally wind-down.
5. **No SWAP without replacement** — never emit `SWAP` without a concrete ADD NEW.
6. **Driver-friendly comments** — plain-English, `⚠️ ALERT:` prefix for exceptions, no formula jargon.

## Where work is done

| Task               | Before (v5.10 skill)                                       | Now (v6)                                                       |
| ------------------ | ---------------------------------------------------------- | -------------------------------------------------------------- |
| Per-slot data pull | 4 joined queries + LLM synthesis                           | 1 call to `get_machine_slots_with_expiry()` per machine        |
| Velocity           | Separate 30-day aggregate                                  | Embedded in function (7d + 15d)                                |
| Expiry             | Not checked                                                | Embedded in function (`expiry_days`, `expiry_qty`)             |
| Classification     | LLM reconstructs from global/slot signals + 6 memory rules | Function returns role + strategy; skill applies 6 rules on top |
| Target             | Formula in skill, no variant_floor                         | Formula in skill with `--fill` mode + variant_floor            |
| Plan write         | N × per-row INSERT                                         | 1 × `write_refill_plan(jsonb)`                                 |
| Dispatch mirror    | Skill wrote to `refill_dispatching` directly               | UI fires `push_plan_to_dispatch` on approve                    |
| Leg-1 staging      | Skill INSERTed directly                                    | Unchanged — still direct INSERT                                |

If a run is still >3 minutes, the bottleneck is almost certainly LLM narration between DB calls. Tighten the loop — don't explain each machine individually during Step 2, just collect the data.
