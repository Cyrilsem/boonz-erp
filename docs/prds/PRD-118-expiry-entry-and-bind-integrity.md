# PRD-118 — Expiry-entry integrity, sourcing truth, and bind correctness

**Raised by:** CS, 27 Aug 2026 · **Class:** 1 data-entry defect · 4 engine/stitch defects · 4 missing or broken RPC doors
**Owner:** Dara (schema/RPC design) → Cody (constitutional review) → Stax (FE)
**Evidence:** the 27 Aug morning pack (Jojo's four reports) and the 28 Aug VOX route build

---

## Why this exists

In one day, six separate failures reached the warehouse floor. Every one was caught by a **human reading a
carton or remembering what was on a shelf** — none by the system. Two of them (A, C) would have put wrong
data into `pod_inventory`; two (C, E) would have shown the packer "no stock" for stock that was physically
on the rack; one (F) would have doubled a dead product on a machine.

The common shape: **the system trusts a value it never verified, and has no door to correct it once wrong.**

---

## Item A — Bulk goods receipt copies one expiry across every line

### Evidence

Two receipts, both entered as a batch, both wrong on multiple lines.

**Vitamin Well, received 2026-08-25 06:51:14 — all five rows share one `created_at`**

| Flavour     | Recorded   | Actual         | Status                                                   |
| ----------- | ---------- | -------------- | -------------------------------------------------------- |
| Antioxidant | 2027-01-17 | **2027-01-24** | wrong                                                    |
| Care        | 2026-12-27 | ?              | **unverified — only 2026 date in the receipt, 48 units** |
| Upgrade     | 2027-01-10 | ?              | unverified                                               |
| Zero Lemon  | 2027-01-03 | ?              | unverified                                               |
| Zero Peach  | 2027-12-27 | **2027-01-10** | wrong                                                    |

The error has a signature: Zero Peach's recorded date is **Care's date with the year bumped**, and Zero
Peach's true date is **Upgrade's recorded date**. That is a row-shifted paste, not a typo.

**Keen Health Dipped Crackers, received 2026-08-04 22:35:25 — identical `created_at`**

| Flavour             | Recorded   | Actual         |
| ------------------- | ---------- | -------------- |
| Dark Chocolate      | 2027-04-05 | **2027-07-06** |
| Raspberry Chocolate | 2027-04-05 | **2027-06-25** |
| Milk Chocolate      | 2027-04-05 | **unverified** |

Three flavours from three production runs cannot share an expiry to the day.

### Blast radius

A wrong expiry does not stay in the warehouse. It is stamped onto the dispatch line at FEFO bind and onto
`pod_inventory` at receive. The 2027-04-05 Keen Health date is now on **20 live pod rows across 9 machines**
(ADDMIND, AMZ-3001, AMZ-3003, HUAWEI, MINDSHARE, OMDBB, OMDCW, USH). Every one of those units is invisible
to expiry alerting on its true date.

### What to build

1. **Per-line date entry is mandatory on goods receipt.** No "apply to all", no carry-down from the previous
   line. If a delivery genuinely has one date across flavours the operator types it N times — that is the point.
2. **Same-timestamp same-date detector.** At receipt commit, if ≥2 lines with different `boonz_product_id`
   share an identical `expiration_date`, warn before save. Warn, never block — single-flavour multi-carton
   receipts are legitimate.
3. **Wire up the checks that already exist.** `check_wh_expiry_anomaly()` and `log_expiry_entry_suspect()`
   are in the database and neither fired on either receipt. Audit both, then make one the receipt-time gate.
4. **Shelf-life sanity band.** Add `boonz_products.typical_shelf_life_days`; warn when
   `expiration_date - receipt_date` falls outside ±25%. This alone catches the Zero Peach case.

---

## Item B — No canonical door to correct a wrong expiry

| RPC                          | Behaviour on a wrong expiry                                                                                                                          |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apply_inventory_correction` | `expiration_date = COALESCE(expiration_date, p_expiration_date)` — **cannot overwrite an existing date**                                             |
| `reactivate_warehouse_row`   | **works**, but refuses `stock <= 0`, and is named for a different job                                                                                |
| `adjust_pod_inventory`       | matches the target row **on `expiration_date`** — a new date never matches, so it silently INSERTs a duplicate active lane row instead of correcting |

The 27 Aug fixes had to be done as: `reactivate_warehouse_row` for the three batches with stock;
`set_dispatch_line_breakdown` for the zero-stock batch; and a **zero-then-reinsert two-step** through
`adjust_pod_inventory` for each field row. That last one is a footgun — a single call with the new date
creates a duplicate rather than a correction.

### Build

`correct_expiry_v1(p_scope, p_row_id, p_new_expiry, p_reason, p_caller_id, p_dry_run default true)`

- `p_scope` ∈ `'warehouse'` | `'pod'` | `'dispatch'`; works at any stock level including zero
- requires a reason ≥20 chars; records the old date in the audit log
- warehouse scope reuses `sync_dispatch_expiry_from_pinned_wh` — that trigger is correct and worked
  perfectly on 27 Aug, cascading to 11 open dispatch rows automatically
- pod scope does the zero-then-reinsert **inside the function** so callers cannot get it wrong
- refuses a past date, or >36 months out, without an explicit override

### Companion: `propagate_expiry_correction(p_wh_inventory_id, p_dry_run)`

When a warehouse batch's date is corrected, units already delivered from it still carry the old date in the
field. On 27 Aug this was found by hand (Zero Peach: 5 units across ALJLT, VML-1003, OMDBB). List every
Active `pod_inventory` row matching the old value for that product and offer a single audited pass.
**Dry-run by default** — matching on the old date alone can catch legitimate rows from a different delivery.

---

## Item C — Post-stitch edits do not re-bind FEFO

### The incident

MC-2004 A06, Pepsi Black ×2. The row was cut, then restored on CS's instruction via `edit_pod_refill_row`
**after** the stitch had already allocated batch `66f8c3f4` (7 units) to ADDMIND's 5. No re-bind ran. The
row reached `refill_dispatching` with `from_wh_inventory_id = NULL`, the packing screen showed no stock, and
Jojo could not mark it packed. The batch in fact held `warehouse_stock 2 / consumer_stock 5` — the two units
were on the rack.

An unbound fill line cannot be packed, produces no warehouse debit, and lands in the day's numbers as a
silent shortfall with `pack_outcome = 'not_filled'` and no operator having decided not to fill it. This is a
**manufactured stockout**.

### Build

1. `restitch_after_edits` must call `bind_dispatch_fefo(plan_date, affected_machines)` for every machine
   whose rows changed. The RPC exists and does exactly the right thing — it is simply never invoked here.
2. Any edit RPC that **raises** a quantity or **adds** a row post-stitch must re-bind — audit
   `add_pod_refill_row` and `swap_pod_refill_row` for the same hole.
3. **Gate-2 preflight assertion:** refuse to complete `approve_refill_plan` while any non-M2M, non-venue
   fill row for the date has `from_wh_inventory_id IS NULL AND quantity > 0`. Report the rows; do not fail
   silently. Exclude `source_kind = 'm2m'` (PRD-116 K4) and `source_origin = 'vox_at_venue'`.
4. The packing UI must distinguish **"not bound to a batch — call ops"** from **"out of stock"**. Those are
   different problems and the second sends the warehouse looking in the wrong place.

---

## Item D — VOX machines stitch against a warehouse that holds no real stock

### The incident — 28 Aug build, 16 rows

ACTIVATE-2005, VOXMCC-1005, VOXMCC-1011 and VOXMM-1013 have `primary_warehouse_id` = **WH_MCC / WH_MM**.
Those are VOX consignment locations holding only the **×999 sentinel rows**, not real inventory. The stitch
sourced every Boonz-supplied line on those machines from the machine's primary warehouse, FEFO could not
bind, and **16 rows (29 units)** — Nutella, Loacker, Popit, Hunter, Barebells, Sun Blast, Vitamin Well —
would have shown the packer "no stock" on a morning when all of it was sitting in CENTRAL.

This is the **same defect as 25 Aug**, when 7 lines stitched to WH_MCC. It is structural, not a one-off.

### Build

1. Stitch must source a line from the warehouse that **holds real stock for that SKU**, not from
   `machines.primary_warehouse_id`. Sentinel rows (`warehouse_stock` ≥ 999 at WH_MCC / WH_MM) must be
   excluded from every availability calculation, everywhere — they are a consignment marker, not stock.
2. Model the sentinel explicitly rather than by magic number: add `warehouses.is_consignment boolean`, or
   `warehouse_inventory.is_sentinel`, and filter on the flag.
3. Add a nightly check: any Active `warehouse_inventory` row with `warehouse_stock` between 900 and 1100 at
   a consignment warehouse is a sentinel — assert none is ever FEFO-bindable.

---

## Item E — `source_origin` is not derived from `product_mapping`

`add_pod_refill_row` hard-defaults `source_origin = 'warehouse'`, and the stitch carries that value through
instead of re-deriving it from `product_mapping.source_of_supply`. On 28 Aug this put **Aquafina ×15 on the
office pack list** for ACTIVATEMCC A11 — a product Boonz does not stock at all, whose mapping says
`venue_team` at global default _and_ at that machine.

Worse: **the tag could not be corrected.** Once a machine's rows have bridged to dispatch,
`push_plan_to_dispatch` will not re-fire for it, so a rewritten `refill_plan_output` row with the correct
`vox_at_venue` tag sits `approved / dispatched=false` forever. Three attempts (write+approve, explicit
`push_plan_to_dispatch`, action-variant rewrite) all failed. The row had to be restored through
`add_dispatch_row`, which offers no `source_origin` parameter, so it is live with the wrong tag and a
warning in its comment.

### Build

1. Stitch derives `source_origin` from `product_mapping` (machine-scoped first, then global default) and
   **ignores** whatever the pod row carried.
2. `add_pod_refill_row` and `add_dispatch_row` take an explicit `p_source_origin`, defaulting to the mapping
   lookup rather than the literal `'warehouse'`.
3. `push_plan_to_dispatch` must be **idempotent and re-runnable** for a machine — bridging newly-approved
   rows without re-bridging existing ones. Today it is effectively one-shot per machine per date, which
   makes any post-bridge correction impossible without raw SQL.
4. Assertion: no dispatch row may carry `source_origin='warehouse'` for a SKU whose only Active mapping is
   `venue_team`.

---

## Item F — The swap engine can propose a product the machine already has, and already isn't selling

### The incident

ADDMIND-1007 A07: remove Smart Gourmet Hummus ×8, add Krambals ×8 — while **A06 of the same machine held
Krambals at 6/6, 3 units sold in 30 days, last sale 10 Aug.** Both sides of the swap were dead: Smart Gourmet
had sold **zero** at ADDMIND in 30 days. Post-swap the machine carries ~14 Krambals against ~3 units of
monthly demand.

The same class produced two Vitamin Well duplications the same day: ADDMIND A08 opened a Vitamin Well lane
while **A16 was Vitamin Well at 4 of 16**, and MC A14 opened one while **B14 was Vitamin Well at 6/12 selling
2 units in 30 days** — 14 units against 2/month, seven months of runway.

### Build

In `find_substitutes_for_shelf` (v2), two filters before scoring:

1. **Same-machine duplicate** — exclude any pod product already on another shelf of the target machine,
   unless the existing lane's runway is under 7 days (a real second-facing case for a fast seller).
   Downgrade rather than hard-exclude if the product is the machine's top seller.
2. **Dead-on-this-machine** — exclude any candidate whose `units_30d` **on this machine** is below the dead
   threshold. Fleet-wide performance is not a licence to re-open a lane that already failed in this venue.

Surface both in the Gate-1 diff as `duplicate_on_machine` / `dead_on_machine`, and add a third flag
`existing_lane_below_50pct` — when a machine already has that product on a lane under half full, the correct
action is to refill the existing lane, not open a second one.

**Every one of these was caught by a human's memory. That is not a control.**

---

## Item G — Two RPC doors that cannot be opened

Found while executing the 27–28 Aug fixes:

1. **`warehouse_expire_writeoff` cannot write anything off as waste.** It requires `p_reason` ≥10 characters
   and writes `p_reason` straight into `warehouse_inventory.disposal_reason`, which has
   `CHECK (disposal_reason IN ('Waste','Returning to supplier','Returned to supplier'))`. `'Waste'` is five
   characters. The only reasons that satisfy both are the two supplier ones — so **expired stock can only be
   written off by mislabelling it as returned to the supplier.** Five units of Activia Honey & Oats that
   expired 27 Aug are still sitting Active in CENTRAL because of this.
   → Separate the audit reason from the disposal code: `p_disposal_code` (constrained) + `p_reason` (free text).
2. **There is no `set_wh_quarantine`.** `release_wh_quarantine` exists; nothing sets the flag. FEFO already
   honours `NOT COALESCE(quarantined,false)`, so quarantine is the natural lever for "don't ship this batch,
   it is too close to expiry" — but it can only be cleared, never applied. On 28 Aug this meant an Activia
   line whose only bindable batch expired in 4 days had to be **dropped from the plan entirely** rather than
   steered to the 25 Sep batch.
   → Add `set_wh_quarantine(p_wh_inventory_id, p_reason, p_caller_id)`; require a reason; log it.

---

## Open physical checks for the warehouse

- [ ] **Vitamin Well – Care**, batch `7d4e3452`, 48 units, recorded **2026-12-27** — the only 2026 date in a
      receipt where two of five dates are proven wrong, and 9 units shipped 27 Aug.
- [ ] **Vitamin Well – Upgrade** (`de7dcdd4`, 10 u, 2027-01-10) and **Zero Lemon** (`7dda8717`, 34 u,
      2027-01-03) — same receipt, unverified.
- [ ] **Keen Health – Milk Chocolate**, recorded 2027-04-05 alongside two proven-wrong flavours. 20 pod rows
      across 9 machines carry this date.
- [ ] **Activia Honey & Oats**, 5 units expired 27 Aug, still Active in CENTRAL — blocked by item G1.
- [ ] **Activia Strawberries**, 7 units expiring 31 Aug — needs a call: bin, or push to a fast-turnover site.
- [ ] The 25 duplicate warehouse batch groups (58 rows / 756 units sharing product + warehouse + expiry)
      from PRD-117 — same physical-count visit.

## Procurement, from the 28 Aug analysis

| SKU                  | Signal                                                                                                                                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Evian still**      | ACTIVATEMCC A11 sold 28 units/30d into a 2/15 shelf; engine `STAR` clamped `blocked_no_wh`. 2 units of Evian 330ML left. Lane reassigned to Aquafina 28 Aug.                         |
| **YoPRO**            | AMZ-1068 A01 at 0/8, 9 units/30d, **zero warehouse stock**.                                                                                                                          |
| **Leibniz Zoo**      | One lane in the entire fleet (MPMCC-1054 A13, 0/6, 5 units/30d). 8 units left: 6 Regular exp 24 Sep, 2 Milk & Honey exp **4 Sep**.                                                   |
| **McVities Nibbles** | **CS decision 27 Aug: do not re-order.** Zero stock; the 49 units on hand are McVities _Mini_, a different SKU family. Propose a `decommission` intent to drain the remaining lanes. |

---

## Acceptance criteria

- [ ] Goods receipt cannot be saved with a carried-down expiry; identical dates across flavours warn.
- [ ] `correct_expiry_v1` exists, works at zero stock, and is the only documented way to fix a date.
- [ ] `propagate_expiry_correction` lists field rows carrying a superseded date, dry-run by default.
- [ ] No fill row reaches `refill_dispatching` unbound; Gate 2 refuses and names the rows.
- [ ] Stitch never sources from a consignment warehouse; sentinel rows are excluded fleet-wide by a flag.
- [ ] `source_origin` is always derived from `product_mapping`; no venue SKU appears on an office pack list.
- [ ] `push_plan_to_dispatch` is idempotent and re-runnable per machine.
- [ ] The packing screen distinguishes "unbound" from "out of stock".
- [ ] The swap engine never proposes a product already on the machine, or dead on that machine, without an
      explicit Gate-1 flag.
- [ ] `warehouse_expire_writeoff` can record waste; `set_wh_quarantine` exists.
- [ ] Regression fixtures: correct expiry on a 0-stock batch · correct expiry with delivered field stock ·
      raise a quantity post-stitch and confirm the row binds · stitch a VOX machine and confirm CENTRAL
      sourcing · swap into a lane whose product is already on the machine and confirm the flag fires.

---

## Fixed in prod, 27–28 Aug 2026

| Object                                                               | Was                             | Now                                               |
| -------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------- |
| `bebccdb1` Zero Peach (WH, 35 u)                                     | 2027-12-27                      | **2027-01-10**                                    |
| `14498a7b` VW Antioxidant (WH, 7 u)                                  | 2027-01-17                      | **2027-01-24**                                    |
| `97a0fd01` Keen Dark Choc (WH, 1 u)                                  | 2027-04-05                      | **2027-07-06**                                    |
| dispatch `8c064301` Keen Raspberry ×2                                | 2027-04-05                      | **2027-06-25** (0-stock batch, line-level fix)    |
| 11 open dispatch rows, 27 Aug                                        | old dates                       | cascaded by `sync_dispatch_expiry_from_pinned_wh` |
| Zero Peach field stock — OMDBB A16 ×2, ALJLT A03 ×1, VML-1003 A05 ×2 | 2027-12-27                      | **2027-01-10**                                    |
| 16 VOX dispatch rows, 28 Aug                                         | sourced WH_MCC / WH_MM, unbound | **re-sourced to WH_CENTRAL, FEFO-bound**          |

Net stock movement across all corrections: **zero**.

---

## ADDENDUM — 27 Aug, evening: item D's premise is contested, verify before building

Dara proposed `warehouses.is_consignment boolean` as the exclusion mechanism for item D. Before that goes
to Cody, three findings from the live database and the architecture docs have to be resolved. They are
recorded here as evidence, not as a decision.

### D-1. The concept may already have a canonical owner

`docs/architecture/METRICS_REGISTRY.md` line 160 registers **`v_shelf_availability_v3`**, LIVE since
2026-07-30 (`prd110_p13_availability_contract`), described as **"the VOXSOURCE sentinel pattern"**. Its
contract, verbatim from the registry:

> `available_units IS NULL` means **unconstrained** — the venue or partner supplies that shelf and Boonz WH
> stock is irrelevant to whether it can be planned. Otherwise it is real Boonz WH stock **with sentinel rows
> excluded**. This is the object that makes the 40 fake `999` rows **unnecessary**: it returns the same
> answer whether or not they exist.

There is also a fourth warehouse, **WH_VOX_SOURCING** (`9e3eaa11-faaa-43ed-bfbe-f0f5fbeb1d11`), holding
zero inventory rows.

What actually reads what, verified 27 Aug:

| Function                | reads `v_shelf_availability_v3` | reads `v_wh_pickable` | reads `machines.primary_warehouse_id` |
| ----------------------- | ------------------------------- | --------------------- | ------------------------------------- |
| `stitch_pod_to_boonz`   | no                              | yes                   | —                                     |
| `push_plan_to_dispatch` | no                              | no                    | **yes**                               |
| `wh_fefo_for_line`      | no                              | yes                   | **yes**                               |
| `engine_add_pod`        | no                              | no                    | **yes**                               |

Nothing in the sourcing chain consumes the object whose stated job is "can this shelf be planned, given who
supplies it". Warehouse scoping is re-derived from `primary_warehouse_id` in three places. **The open
question is therefore whether item D is a schema gap at all, or an Article 16 wiring gap.** The registry
warns in bold that the availability objects are DELIBERATELY DISJOINT and must not be consolidated; adding a
fifth mechanism without settling this risks being the violation rather than the fix.

### D-2. The invariant is already violated — 8 rows, ~38 units

| Warehouse  | Active rows | Sentinel (`expiration_date = 2099-12-31`) | Rows with real expiry dates |
| ---------- | ----------- | ----------------------------------------- | --------------------------- |
| WH_MCC     | 37          | 32 (stock 828–1003)                       | **5** (stock 1–12)          |
| WH_MM      | 34          | 32 (stock 997–1002)                       | **2** (stock 4)             |
| WH_CENTRAL | 193         | **0**                                     | 193 (max stock 104)         |

The non-sentinel rows at the consignment warehouses: Tamreem Date Ball ×12 (exp 2026-11-30), Zigi Sea Salted
×6 (2027-05-18), Tamreem Dried Freeze Peach ×6 (2027-03-12), 7Up ×5 (2026-10-25), Vitamin Well Zero Lemon ×1
(2027-12-03) at WH_MCC; Tamreem Coconut ×4 (2026-12-31) and Tamreem Sesame ×4 (2026-11-30) at WH_MM.

Real products, real expiry dates, small counts. **Excluding these warehouses wholesale strands all 38 units
from FEFO permanently.** Either they are real stock physically at the venues — in which case "never holds
real stock" is false and the design needs revisiting — or they are misfiled and must be reconciled first.
Resolving this is a precondition for any warehouse-level exclusion, whichever mechanism wins.

### D-3. The sentinel discriminator is the 2099 date, not the stock band

The PRD's own 900–1100 band (and Dara's canary built on it) is the wrong signal:

- `expiration_date = 2099-12-31` separates perfectly — 64 rows across WH_MCC and WH_MM, **zero** at WH_CENTRAL.
- The band does not. The Aquafina sentinel at WH_MCC is already at **warehouse_stock 828 with consumer_stock
  24** — sentinels decay as they are consumed, and this one has fallen out of the band while still being a
  sentinel.

A band-based canary would flag that healthy sentinel as an invariant breach nightly, and would miss a genuine
500-unit delivery landing in a consignment warehouse. Use the 2099 date as the sentinel test and keep the
stock band, if at all, only as a secondary smell.

**Add a third assertion Dara did not list:** no `expiration_date = 2099-12-31` row may exist at a
non-consignment warehouse. WH_CENTRAL is clean today; that is the invariant worth locking before it isn't.

### Confirmed available for the implementation

- `safe_monitoring_alert(p_source text, p_severity text, p_payload jsonb)` exists, SECURITY DEFINER — use it
  rather than a raw insert to `monitoring_alerts`.
- `docs/architecture/METRICS_REGISTRY.md` and `docs/architecture/DARA-warehouse-availability-canonical.md`
  both exist and must be read before touching any availability path.
- 16+ front-end files reference `warehouse_stock`; `src/app/(app)/admin/wh-quarantine/` and
  `src/components/inventory/CanaryIndicator.tsx` already exist (quarantine UI is built even though the
  setter RPC in item G2 is not).

---

# PRD-118 — ADDENDUM 2 (status ledger + items H, I, J, K)

**Date:** 2026-09-01. Append to `docs/prds/PRD-118-expiry-entry-and-bind-integrity.md`.
Where this addendum disagrees with the main body or Addendum 1, THIS addendum wins.

## Status ledger as of 2026-09-01 (verified live this week)

| Item                                 | Status          | Fresh evidence since the PRD was written                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------------------ | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A — receipt copies one expiry        | OPEN            | Fleet resync on 5 machines (31 Aug) surfaced **145 units physically present with no recorded expiry** and wrote off 226 phantom units; Jojo validated on-site 01 Sep that NISSAN's "no date" Activia are all printed 05.09.26                                                                                                                                                                                               |
| B — no expiry-correction door        | OPEN            | Two more manual zero-then-reinsert surgeries performed (NISSAN Activia 01 Sep; the pattern is now routine, which is the indictment)                                                                                                                                                                                                                                                                                         |
| C — post-stitch edits don't re-bind  | OPEN            | —                                                                                                                                                                                                                                                                                                                                                                                                                           |
| D — VOX consignment sourcing         | OPEN            | Now 4 runs in a row: 25 Aug (7 rows), 28 Aug (16), 30 Aug (11), 31 Aug (5). Same manual repair every time                                                                                                                                                                                                                                                                                                                   |
| E — source_origin / one-shot push    | OPEN            | Mechanics now decoded (see §E-2 below) — the "one-shot" is the push preserve-check matching removed rows                                                                                                                                                                                                                                                                                                                    |
| F — swap engine proposes dupes/dead  | OPEN            | —                                                                                                                                                                                                                                                                                                                                                                                                                           |
| G — broken writeoff/quarantine doors | OPEN            | Blocked writeoffs now queued: 5 Activia H&O expired 27 Aug (CENTRAL), 1 H&O dated 05 Sep (CENTRAL, pulled from a plan per CS doctrine), 22 units on WH2-2001, 15 Nescafe expiring 04–05 Sep (CENTRAL, CS accepts expiry)                                                                                                                                                                                                    |
| H — FEFO bind not quantity-aware     | OPEN            | **Five sightings**: Nutella/SunBlast 30 Aug (19 units mispinned), Activia 31 Aug ×2, Ice Tea 01 Sep, Leibniz 30 Aug. Full write-up in §H below (was never committed to the repo)                                                                                                                                                                                                                                            |
| I — pack screen commitment smear     | **DONE 31 Aug** | Backend: migrations `prd118_i_commitment_batch_grain` + `prd118_i_commitment_expose_breakdown` (additive columns on `v_dispatch_open_wh_commitment`). FE: commit `fix(prd-118): item I` on main, deployed, validated in production packing same morning (3-machine Sunbites deadlock cleared, all lines packed on-screen). **Loop owes only the docs**: METRICS_REGISTRY entry for the view, CHANGELOG, MIGRATIONS_REGISTRY |

## §E-2 — push_plan_to_dispatch one-shot mechanics (decoded 2026-08-30)

The "one-shot" behaviour is not a flag; it is two checks inside `push_plan_to_dispatch`:

1. **Tombstone check**: an rpo line whose `dispatch_id` points at an include=false row with an edit_log `remove` entry is skipped.
2. **Preserve check**: for a machine/date/shelf/pod_product, any dispatch row with `created_by_edit OR edit_count > 0` (skipped/cancelled/returned excluded — but **include=false NOT excluded**) is "preserved": the rpo line is marked dispatched pointing at that possibly-dead row and no new row is inserted.
   Fix: the preserve check must require `include = true`. A removed row must never absorb a new line. Test: remove a row, write a fresh plan line for the same lane, approve, assert a live dispatch row exists.

## §H — FEFO bind is not quantity-aware and does not net in-run commitments

`bind_dispatch_fefo` picks `ORDER BY expiration_date ASC ... LIMIT 1` with only `warehouse_stock > 0`:

1. No quantity check — an 8-unit line binds to a 1-unit batch.
2. No netting — N rows in one run all pin the same earliest batch regardless of depth (stock only moves at pack, so re-running never corrects it).
3. `wh_fefo_for_line` (push-time) is _supposed_ to be quantity-aware via `is_satisfiable` but pinned Ice Tea ×10 to a 2-unit batch on 01 Sep — audit why its satisfiability check passed.
4. **No re-pin door exists**: `repair_unbound_dispatch` refuses bound rows and requires `packed=true`; `set_dispatch_line_breakdown` writes the PRD-053 breakdown + expiry but never `from_wh_inventory_id`. Every mispin so far was papered over with breakdown stamps.

Fix: allocate through `pick_wh_batch_for_machine` (already quantity-aware, honours reservations/quarantine) row by row with a running per-batch tally; split lines across batches into `driver_confirmed_breakdown` when no single batch suffices; add `repin_dispatch_batch(p_dispatch_id, p_wh_inventory_id, p_reason, p_dry_run default true)` (SECURITY DEFINER, role-checked, refuses packed rows, validates product match + net depth); nightly assertion that no unpacked same-batch group exceeds its batch stock.
Test fixture: three lines totalling more than the earliest batch; assert no over-commit, correct per-row expiry, splits recorded.

## §J — NEW: delivery/receive merges fresh stock onto an old expiry row

31 Aug: AMZ-1068 A05 held ~3 Activia dated 31 Aug; we delivered 4 fresh units dated 25 Sep; afterwards `pod_inventory` showed **one row: 6 units @ 2026-08-31**. The fresh batch's identity was destroyed at the merge — the shelf then looked fully expired in every view and the app.
Audit the delivery-confirm / receive writer's merge key (it merges per machine+shelf+product, flattening expiry instead of keeping one row per expiry). Fix: the pod-side unique grain must include expiration_date (one Active row per machine+shelf+product+expiry), and the delivery writer must land received units on THEIR batch expiry, never COALESCE into the existing row's date. This is the pod-side sibling of item A. Test: deliver fresh-dated stock onto a lane holding older-dated stock; assert two rows with correct dates.

## §K — NEW: date-less inventory needs a guard and a closing loop

`resync_pod_inventory_from_weimi` correctly registers physically-present units, but with `expiration_date NULL`; nothing then forces the date to ever be captured (NISSAN's null Activia sat until Jojo happened to read the label). Add:

1. Nightly assertion/alert: any Active pod row with `expiration_date IS NULL` older than 3 days → `safe_monitoring_alert('expiry_unvalidated', ...)` listing machine/shelf/product.
2. Gate-2 hard guard (CS doctrine 2026-08-31, non-negotiable): **approve_refill_plan refuses any Refill/Add line whose resolved batch expiry is ≤ plan_date + 7 days or NULL** unless the line carries an explicit override comment. Expired stock must be physically impossible to plan onto a shelf.

## Constraints refresh for the loop

- DO NOT touch plan_date **2026-09-01** (delivered today; reconciliation may still be running) or any live/future plan rows. Migrations + fixtures only.
- Item I is done in code — do not rewrite the packing page or the commitment views; ship its missing registry/doc entries only.
- Everything else as the original goal command: Cody verdict per migration, Dara for schema, canonical RPCs only, copy `reactivate_warehouse_row` as the DEFINER reference, never downgrade engines.
