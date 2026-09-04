# PRD-119 — Expiry Management & Smart Inventory

**Raised by:** CS, 02 Sep 2026 · **Status:** DESIGN — decisions D0–D6 below are CS-stated on 02 Sep; open items marked ⏳
**Owner:** design chat (this document) → Dara (schema) → Cody (constitution) → build chat / Stax (FE)
**Floor:** PRD-118 (+ Addenda 1–2). **Base to extend, not rebuild:** PRD-114 (driver "Sanity checks — expired products" category), PRD-112 (day-close events), PRD-113 (expired never auto-consumed), PRD-100 (`record_actual_refill` atomic writer).

---

## 0. The one-paragraph version

Expiry truth is destroyed at five moments (receipt, plan-time pinning, delivery merge, sales decrement, return) and the system asks humans to re-type what it could have captured. This PRD makes the shelf record a **dated lot ledger** written only by human touch, stops the system guessing which unit a sale consumed, carries the date on every movement (pack → load → move → return), and puts the only two expiry actions a driver needs (**check a date**, **remove an expired lot**) inside the refill screen he already uses. Pull/refill/redeploy _decisions_ stay in the refill engine; this PRD feeds it dates, it does not command it.

---

## 1. Scope boundary (CS, 02 Sep — firm)

| In PRD-119                                                                                  | NOT in PRD-119 (belongs to the refill engine)                                                     |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Capture and carry the expiry of every unit at every touch                                   | Deciding to pull short-dated-but-not-expired stock                                                |
| Driver line: **CHECK** (lot has no / unverified date)                                       | Deciding to redeploy stock to another machine                                                     |
| Driver line: **REMOVE EXPIRED** (lot at/past date, or dated ≤3 days from the visit) → waste | Deciding what refills a lane after a pull                                                         |
| Return receipt: pre-filled, system proposes disposition, WM confirms/edits                  | Category-based day thresholds — **rejected**                                                      |
| M2M moves never touch the warehouse and carry the lot                                       | "Quarantine" as a state — **dropped**; a pulled unit is stock-with-a-deadline (redeploy) or waste |
| 48h rule at the warehouse door (nothing dispatched with ≤48h to expiry; not overridable)    |                                                                                                   |
| Expiry & waste module in the app (replaces the returns Google Sheet)                        |                                                                                                   |
| Stop the sales-cycle decrement of `pod_inventory`                                           |                                                                                                   |

**Representation rule (CS):** if the engine keeps a product on a lane, it refills it. One unit on a shelf is not acceptable. This is an engine rule, recorded here because the lot signal must never be used to justify leaving a lane thin.

**Never pull without a plan (CS):** pulling short-dated stock with no redeploy destination and no fresh refill for the lane grows waste and destroys margin. Either the engine swaps fresh in and moves the older units to a machine that will sell them, or the units stay until they expire (≤3 days) and are removed as waste then.

---

## 2. Evidence (02 Sep, read-only, live DB)

### 2.1 The sales decrement is wrong 28% of the time and deletes live stock

`auto_decrement_pod_inventory` matches a sale to `pod_inventory` by **pod product name across the whole machine** (no `goods_slot`/shelf predicate), FEFO order, then archives the row at zero as `sold_through_<date>`.
Last 30 days: **4,385** sale decrements, 5,016 units, 34 machines. **1,158 of 4,187** resolvable events (**28%**) drained a row on a **different lane** than the sale came from. **697** events flipped a row Inactive. Not scheduled by pg_cron — invoked externally (n8n/edge); locate the caller before disabling.

### 2.2 PRD-114's expiry checks are used but never applied

`day_close_events kind='expiry_check'` since ship (12 Aug): **8 taps** (5 Remove, 2 Sold, 1 Exists) on 6 machines. **0 acknowledged.** The design made CS's day-close click the write; it has never been clicked, so every removed batch is still Active. The screen works; the write never lands.

### 2.3 Warehouse side today

Phantom `consumer_stock` (BUG-006): **zero** (57 rows with commitments, none above genuine in-flight). Quarantine flag: 788 rows flagged but only **2 Active rows / 5 units** in CENTRAL — not a FEFO blocker. **Returns:** 255 dispatch rows / 79 units marked returned in 60 days, **3** approvals logged, 2 parked; returned stock re-enters as zero-qty Inactive rows (movement recorded, restock never). Remove legs mostly carry **no expiry** (M2M: 50 of 73) → the WM re-types the date.

### 2.4 M2M

90 days: 73 M2M Remove legs / 556 u, 59 Add legs / 563 u. 0 in the remove-confirm queue today, 1 traceable WH credit by event id (23 Jun, 4 u). PRD-113b closed the queue path for same-machine moves. Still open: driver multi-variant split children lose `source_kind`/`source_machine_id`/`is_m2m`; 7 historical approved legs merged credits into existing batches (~21 u, WPP / OMDCW / MC-2004 — settle by physical count only). **36 of 59 Add legs and 50 of 73 Remove legs have no expiry on the leg** → moved units arrive undated.

### 2.5 Fleet

927 of 5,655 machine units (16.4%) have no expiry; warehouse is 100% dated. 145 units surfaced date-less by the 31 Aug resync.

---

## 3. Decisions

**D0 — Shelf record = dated lot ledger, human-touch writes only.** `pod_inventory` holds one Active row per machine + shelf + product + **expiry** (PRD-118 J grain). `current_stock` = units of that lot as of the last human touch. Writers: delivery confirm (LOAD), driver REMOVE EXPIRED / CHECK, engine Remove/Add legs (carrying the lot), M2M carry-across, write-off. **Sales never write it.** Live quantity on a lane = WEIMI, as today. Display may show "sold since last visit = WEIMI total − ledger sum" as an estimate; nothing writes it.

**D1 — Play B.** Planning decides product + quantity. The batch is chosen at pack: the system **recommends** (earliest expiry first, quantity-aware, honours reservations and the 48h rule) and the packer's tap **confirms or changes** it. The tap is the record. Plan-time FEFO pinning remains only as the recommendation source. _(CS 02 Sep: "the system recommends which product to take, with the option to update".)_

**D2 — Grain.** One row per product per expiry per lane (unblocks PRD-118 J). Delivery never merges a fresh lot into an older lot's date.

**D3 — Receipt capture** ⏳ open (photo of printed date / barcode + manual / typed with ±25% shelf-life band). PRD-118 A ships the per-line guard; the UX is decided here later.

**D4 — Horizon.** No category thresholds. One rule for every product: will it sell before its date **in this machine** (28-day velocity there)? That question is the engine's input, not a 119 command. The only 119 horizon is **≤3 days at the visit → remove as expired**, and **≤48 h → never dispatched**.

**D5 — Field writer permissions.** From the machine the driver may write: a lot's expiry (CHECK), a lot's removal with count (REMOVE EXPIRED), a lot's closure (Not there). He may not change products or lane assignments.

**D6 — Disposition.** A returned/pulled unit has two destinations: **redeploy** (a named target machine that sells it fast enough to clear it before the date, minus travel and the 48h rule, with a waste-by deadline) or **waste**. The system proposes; the WM confirms or edits. "Quarantine" is not a state. The returns Google Sheet is replaced by the disposition ledger (§6).

---

## 4. The driver line (extends PRD-114 §3.2 — same category, same style)

**Decided 02 Sep (CS):** ONE confirmation flow, owned by the **warehouse manager**. CS's Day Close stops being a gate — it becomes a read-only log/summary; a review view is built later on top of it to spot glitches and repeat problems. Nothing waits on CS.

Category "Sanity checks — expiry", last in the dispatch list, auto-expanded when non-empty. Rows come from the lot ledger for that machine:

| Row condition                               | Colour                | Driver answers                                  | Write on tap                                                                                                                                                   | Goes to WM queue?                                |
| ------------------------------------------- | --------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| Lot expiry < visit date                     | red, `EXPIRED`        | **Removed** (count, pre-filled) · **Not there** | Removed → lot `current_stock -= n` (unit is off the shelf), archive at 0; disposition row `removed_at_machine` (§6). Not there → archive `sold_through_<date>` | Removed → **yes** (goods travel). Not there → no |
| Lot expiry within **1–3 days** of the visit | red, `EXPIRES <date>` | same                                            | same                                                                                                                                                           | same                                             |
| Lot expiry NULL or unverified               | amber, `DATE?`        | **Date read** · **Not there**                   | Date read → `correct_expiry_v1('pod', row, date, 'driver read label', driver)`; Not there → archive                                                            | no (no goods move)                               |

Rule: **the shelf record changes at Jojo's tap** (the unit physically left the shelf); **the warehouse and the waste ledger change at the WM's confirm** (the unit physically arrived). Field actions that move no goods (date read, not there) apply immediately and never queue.

Changes vs PRD-114 as shipped: window 7d → **3d**; Exists/Skip removed; "Sold" renamed "Not there"; tap writes through the canonical writer instead of parking in `day_close_events` for an acknowledge that (evidence §2.2) never comes. `day_close_events` keeps receiving a log row per tap (kind unchanged) with `acknowledged_at` set by the system at write time — the table becomes the log CS asked for, not a gate.

### 4.1 Warehouse Confirmations tab (WM) — the single queue

One tab on the WM's inventory screen replacing today's two panels (`PendingRemoveApprovalsPanel` + returns-awaiting-approval). Every field action that moves goods lands here as one line, pre-filled from the driver's tap: **expired removals**, **engine Remove legs** (returns / redeploys), **substitutions** where the unplanned product came from her stock, **M2M legs** only if the pairing failed (otherwise never). Each line shows product, count, date, machine, lane, driver, time, and the system's **proposed outcome** (back to stock / redeploy → machine X, waste by <date> / waste). She counts, taps **Confirm** or edits qty/date/outcome. Her confirm is the only write to `warehouse_inventory` and `disposition_events` for that line. Lines older than 48 h turn red here and in CS's Day Close summary.

### 4.2 CS Day Close (read-only)

Shows, per day: what Jojo did (all taps, applied), what the WM confirmed, what is still unconfirmed and for how long. No acknowledge button. Later: a review view over `day_close_events` + `disposition_events` for recurring patterns (same lane always "not there", same product always undated, etc.).

---

## 5. Data flow — every movement carries its date

| Moment                 | Who                    | Writes                                                              | Date comes from                         |
| ---------------------- | ---------------------- | ------------------------------------------------------------------- | --------------------------------------- |
| Goods receipt          | WM                     | `warehouse_inventory` row per line                                  | typed per line (PRD-118 A; D3 UX later) |
| Pack                   | WM (Jojo if she's off) | `pack_dispatch_line` stamps `from_wh_inventory_id` + `expiry_date`  | the tapped batch                        |
| Load / deliver         | Jojo                   | `receive_dispatch_line` → lot row for **that** expiry (D2)          | dispatch line                           |
| M2M move               | Jojo                   | Remove leg + Add leg, both carrying the lot; **no warehouse write** | source lane lot                         |
| Remove expired / Check | Jojo                   | §4                                                                  | lot / label                             |
| Return to WH           | Jojo → WM              | Remove leg pre-filled with lot; WM confirms disposition (§6)        | lot on the leg                          |
| Write-off in WH        | WM                     | `warehouse_expire_writeoff(row, reason, caller, disposal_code)`     | batch                                   |
| Sale                   | machine                | **nothing** on the lot ledger (sales_history only)                  | —                                       |

Deletion list (Play B + D0): `auto_decrement_pod_inventory` (disable behind a flag, keep function 30 days, then drop); the `resync_pod_inventory_from_weimi` count-truing of Active lots (resync may still _register_ physically-present unknown lots as `DATE?` rows — it may not change quantities of dated lots); every "at most one Active row per machine+shelf+product" assumption listed in `_DRAFT_prd118_j_pod_inventory_expiry_grain.sql`.

---

## 6. Disposition ledger (replaces the returns Google Sheet)

`disposition_events` (append-only): id, created_at, actor, source (`driver_expiry_check` / `return_receipt` / `wh_writeoff` / `m2m` / `migration_sheet`), machine_id, shelf_id, boonz_product_id, expiration_date, qty, **state** ∈ `removed_at_machine` → `in_transit` → `received` → {`restocked` | `redeploy_pending(target_machine, waste_by)` | `redeployed` | `waste(disposal_code)`}, plus `value_aed` (cost at receipt), reason, linked dispatch_id / wh_inventory_id.
Who confirms: driver writes `removed_at_machine`; WM writes `received` + final state (system-proposed, she confirms/edits); `redeploy_pending` auto-flips to a proposed `waste` when `waste_by` passes with no dispatch — WM confirms.
Migration: the 104 sheet rows (340 u, Mar–Sep 2026) load as `source='migration_sheet'` with the sheet's state; the 5 "not updated in system" rows and the YoPro Vanilla/Strawberry mismatch are flagged for CS.
Reports: waste by product / supplier / machine / month, value; redeploy success rate; feeds procurement (`weekly-procurement` reads waste per SKU before proposing quantities).

---

## 7. Return flow (P1 — first to build)

1. Engine Remove leg (or driver REMOVE EXPIRED) leaves the machine **with product, qty, expiry** from the lot. If the lane's lot is `DATE?`, the driver's CHECK resolves it first.
2. Leg arrives in WM's "Returns to receive" list pre-filled. System proposes: **redeploy → machine X, waste by <date>** (X sells it at ≥ qty/(days-left − 2) per day and has a lane for it) or **waste**. Expired-at-arrival → waste, no proposal.
3. WM taps confirm (or edits qty/date/destination). Write: `warehouse_inventory` credit **on the batch with that expiry** (new row if none), `disposition_events` state, and for redeploy a `reserved_for_machine_id` + `waste_by`.
4. No approval step beyond the WM's receipt (CS 02 Sep); her confirm in the Warehouse Confirmations tab (§4.1) IS the receipt. Returns never credit the WH via `adjust_warehouse_stock` directly. Consignment (VOX-sourced) returns must never mint a `2099-12-31` sentinel row tagged `dispatch_return` (seen twice, WH_MCC, Jul 2026).

M2M rule: a Remove leg paired with an Add leg on another machine never enters this flow; the driver multi-variant split must inherit `source_kind`, `source_machine_id`, `is_m2m` (closes the last PRD-113b hole).

---

## 8. Build order

| Phase                        | Content                                                                                                                                                                                                            | Fixtures                                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| **P1 Warehouse truth**       | Return flow §7 (pre-fill + propose/confirm); M2M never touches WH + carries lot; driver split inherits m2m tags; receipt per-line dates (118 A); watch 118 H bind on live runs; 48h dispatch guard non-overridable | return a dated lot → WH batch credited on that expiry; M2M move → 0 WH writes, dest lane lot dated; split children carry m2m tags |
| **P2 Shelf**                 | J grain (two indexes per draft); disable `auto_decrement_pod_inventory` behind flag; `receive_dispatch_line` lands on its own expiry; resync registers, never re-counts dated lots                                 | deliver 25-Sep onto a lane with 31-Aug → two rows; 100 sales → 0 lot writes                                                       |
| **P3 Driver line**           | PRD-114 category re-scoped per §4; tap = write via canonical writer; day-close = review                                                                                                                            | expired lot → Removed 2 of 4 → 2 written off + 2 sold_through; DATE? → date read → `correct_expiry_v1` audit row                  |
| **P4 Expiry & waste module** | `disposition_events` + WM screens + reports; sheet migration; procurement hook                                                                                                                                     | 104 sheet rows loaded, totals match sheet                                                                                         |
| **P5 Receipt capture UX**    | D3                                                                                                                                                                                                                 | —                                                                                                                                 |

Rollback per phase is additive: flags off, functions retained, tables dropped only after P4 sign-off.

---

## 9. Open ⏳

- ~~Day-close gate~~ → DECIDED 02 Sep: read-only log; WM Confirmations tab is the single gate.
- D3 capture method at receipt.
- Where `auto_decrement_pod_inventory` is invoked from (n8n / edge) — build chat to locate before P2.
- Physical count to settle the ~21 u of historical M2M credits.
- Sunbites/Activia live cases (NISSAN 04 Sep visit, AMZ-1068 A05 truing) to be used as P3 acceptance runs.

---

## 10. Wiring scan — 02 Sep 2026 (read-only). Every human gate in the chain, and whether anyone works it

| Gate / queue                                                                                              | Volume                                                                                                                                                                           | Worked?                                           | Consequence                                                                                                                                          | PRD-119 disposition                                                                                                                                             |
| --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CS Day Close acknowledge (`day_close_events`)                                                             | 105 events since 10 Aug: 57 substitutions, 40 stock_unverified, 8 expiry_check                                                                                                   | **0 acknowledged, ever**                          | none of Jojo's substitutions or expiry removals ever reached inventory                                                                               | §4: log only, writes move to tap / WM confirm                                                                                                                   |
| `monitoring_alerts`                                                                                       | ~7,000 rows in 60 d across 15+ sources (`pack_variant_unconfirmed` 2,846, `dispatch_bridge_nonok` 1,292, `bug010_wh_approval_stuck` 564, `bug012_phantom_dispatch_expiry` 514 …) | **0 acknowledged, ever**                          | alerts are write-only noise; the nightly `expiry_unvalidated` alert (118 K2) will join them                                                          | P4: alerts that need a human become **lines in the WM tab or the CS summary**; the rest become metrics. No new alert without an owner                           |
| WM remove-receipt (`wh_approve_remove_receipt`)                                                           | 242 calls / 60 d, 6 in queue now                                                                                                                                                 | **yes — the one gate that works**                 | —                                                                                                                                                    | keep; becomes a line type in §4.1                                                                                                                               |
| WM return approval (`approve_return`)                                                                     | 1 call / 60 d vs 255 returned lines; 2 in queue                                                                                                                                  | effectively no                                    | returns re-enter as zero-qty Inactive rows (handover ⑤)                                                                                              | folded into §4.1; `approve_return` retired as a separate door                                                                                                   |
| Packed lines never closed by a driver outcome                                                             | **320 lines / 1,142 units**, oldest 31 Mar, 225 older than 30 d, 308 marked picked up                                                                                            | never closed                                      | 131 units of `consumer_stock` still "committed" on 87 batches → packing screen under-states pickable stock; the lot ledger never received their LOAD | P1: auto-close rule — a picked-up line with no outcome after N days closes as `delivered_unconfirmed` and is listed in the CS summary; one-off sweep of the 320 |
| `driver_tasks` open > 7 d                                                                                 | **119**                                                                                                                                                                          | not worked (backlog re-grew after the 19 Aug fix) | driver's task list is noise                                                                                                                          | out of 119 scope — flag to PO/driver-tasks owner                                                                                                                |
| Expired lots still Active on shelves                                                                      | 4 lots / 22 units                                                                                                                                                                | —                                                 | visible in §4 red rows once P3 ships                                                                                                                 | P3 acceptance data                                                                                                                                              |
| Date-less lots                                                                                            | 164 lots (927 units)                                                                                                                                                             | —                                                 | §4 amber rows                                                                                                                                        | P3                                                                                                                                                              |
| `auto_decrement_pod_inventory`                                                                            | **31,185 calls / 60 d** (~520/day), caller role NULL → service role (n8n or edge)                                                                                                | n/a                                               | §2.1                                                                                                                                                 | P2: locate the caller, flag off                                                                                                                                 |
| `correct_expiry_v1`, `propagate_expiry_correction`, `set_wh_quarantine`, `driver_confirm_expired_removal` | 0 calls                                                                                                                                                                          | never used                                        | doors exist, nothing opens them                                                                                                                      | wire `correct_expiry_v1` behind the DATE? tap (§4); others reviewed in P4                                                                                       |
| `record_actual_refill`                                                                                    | 47 calls (04–22 Aug)                                                                                                                                                             | occasionally, from chat                           | the canonical atomic writer is not what the app calls                                                                                                | P3: driver/WM taps go through it (or a thin wrapper)                                                                                                            |

Pattern: **every gate that asks CS to click is dead; the one gate that asks the warehouse manager to receive physical goods is alive.** Design accordingly — that is §4.1.
