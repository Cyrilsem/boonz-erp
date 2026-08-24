# PRD-117 — Consolidated remediation (one-loop overnight brief)

**Date:** 24 Aug 2026 · **Author:** Claude for CS · **Status:** READY TO RUN
**Supersedes as an index:** PRD-116 (phase 1 + phase 2), PRD-116-item-B-followup, PRD-016c/d, PRD-113b
**Repo:** `~/Documents/Boonz Script and Data/BOONZ BRAIN/boonz-erp` · **Project:** `eizcexopcuoycuosittm`

---

## 0. How to use this document

This is the single brief for one unsupervised overnight run. Everything CS has opened across PRD-016, PRD-113 and PRD-116 is consolidated below into **three tiers**:

- **Tier 1 — SHIP.** Writer patches. md5-guarded `CREATE OR REPLACE`, no schema, no data mutation. Test in a rolled-back transaction against real rows, then apply. These are the night's actual work.
- **Tier 2 — PREPARE.** Branches, migration files written but unapplied, evidence lists produced. No prod effect.
- **Tier 3 — DO NOT TOUCH.** Schema, engine version bumps, data mutations on protected entities, FE deploys. Design only.

**If a Tier 1 item fails its rolled-back test, do not apply it. Record why and move on.** A partial run that ships four correct fixes beats a complete run that ships one wrong one.

### Hard rules (non-negotiable)

- Load `cody` before ANY migration and get a verdict. Load `dara` before ANY schema design.
- Every migration: pull the current body with `pg_get_functiondef`, reproduce it **verbatim**, guard with an md5 of that body, change only the intended lines, apply via `apply_migration` — never DDL through `execute_sql`.
- Every migration applied to prod gets a git file in `supabase/migrations/` **and a commit in the same session**.
- Canonical RPCs only. No raw INSERT/UPDATE/DELETE on `pod_refill_plan`, `refill_plan_output`, `refill_dispatching`, `slot_lifecycle`, `pod_inventory`, `warehouse_inventory`.
- WEIMI (`weimi_aisle_snapshots`) is shelf-**quantity** truth. WEIMI `product_name` is **not** identity truth — it is only as fresh as the last manual relabel (proven 24 Aug: WAVEMAKER A1 held Sunbites while WEIMI said "Perrier"). `pod_inventory` is expiry only.
- Never touch a packed or picked-up dispatch row except through the RPCs whitelisted in `protect_packed_dispatch_row`.
- If you are unsure whether an action is reversible, do not take it. Write down what you would do and why.

---

## 1. Where this came from — three incidents in one day

All three cost zero stock. All three were found by a human noticing something looked wrong. That is the actual problem being fixed.

| # | Symptom | Real cause |
|---|---|---|
| A | "WPP Popit refill not deducted from inventory" | It was deducted — at **pack**, four hours before the **receive** event that correctly reads delta 0. Underneath: FEFO picked 1 unit each from three near-expiry cartons, so no physical count can ever match the row split. |
| B | "Starbucks was supposed to be removed, Cappuccino was removed instead" | The plan said *REMOVE Starbucks ×5 from A03* — a lane holding **3** for a week. It took product+shelf from A03 and quantity from A04 (Nescafé, 5 units). The driver did the sensible physical thing. |
| C | (found while fixing B) | `tg_rebind_slot_lifecycle_on_add_confirm` then **rewrote what Boonz believed was on A03** from the wrong plan. A wrong lane does not stay still — it propagates into the next day's plan. |

---

## 2. TIER 1 — SHIP TONIGHT

### T1.1 — Item B: same-machine transfers are unclassifiable (and sometimes unapprovable)

**Full spec:** `docs/prds/PRD-116-item-B-followup-internal-move-classification.md`. Read it in full; it is complete and Cody-ready.

**Live evidence, re-verified 24 Aug:** `115` rows have `source_kind='m2m' AND source_machine_id = machine_id AND is_m2m=true`. **107 are still open** (8 already `wh_approved_at`-settled and must stay untouched). Up from 72 when the doc was written — this is growing.

Three coordinated changes, all three or none:

- **B1 — `add_dispatch_row`:** only set `is_m2m` when the source is genuinely a different machine.
  `(p_source_kind = 'truck_transfer' OR (p_source_kind = 'm2m' AND p_source_machine_id IS DISTINCT FROM p_machine_id))`
- **B2 — `is_internal_move_dispatch`:** move the same-machine ground-truth branch **above** the `is_m2m` early-exit. Today branch 4 (`is_m2m → false`) makes branch 5 dead code.
- **B3 — `wh_approve_remove_receipt` and `wh_approve_remove_receipt_multivariant`:** reorder so `is_internal_move_dispatch` is checked **before** the `is_m2m` raise. Without this, B2 is invisible to both writers.

**Why it matters more than it reads:** a same-machine driver-split child inherits `is_m2m=true` (PRD-116b, working as specced) but gets `m2m_transfer_id = NULL`. `wh_approve_remove_receipt` refuses it → `approve_m2m_transfer` refuses it → `is_internal_move_dispatch` says false so `clear_internal_move_flag` doesn't apply. **A row with no approval path at all.**

**Verification (rolled-back tx, report actual JSON):**
1. Pick 5 of the 107 open mistagged rows. Confirm `is_internal_move_dispatch` returns `false` today and `true` after B2.
2. Call `wh_approve_remove_receipt` on one — assert it raises **INTERNAL MOVE**, not the M2M message.
3. `add_dispatch_row` with `source_kind='m2m'`, `source_machine_id = p_machine_id` → assert `is_m2m=false`.
4. `insert_driver_remove_line` child of that parent → assert it inherits `is_m2m=false` and classifies as an internal move.

**Backfill is OUT OF SCOPE tonight.** B2+B3 make classification correct regardless of the stored flag. Leave the 107 rows alone.

---

### T1.2 — Item L (NEW): a REMOVE quantity is never checked against its own lane

**This is the root cause of incident B and it is not rare.**

Over the last 60 days: **25 of 149 REMOVE plan rows (17%) planned a quantity larger than the lane's own WEIMI stock on the plan date.** One in six. WAVEMAKER was not an outlier — it was the one that happened to be visible.

**Fix — a WARNING, never a block.** A hard block could stop-ship a live plan overnight, and there are legitimate cases (WEIMI stale by a day, driver finds more than the sensor knew). Add to the plan-build / Gate-1 path:

> when `REMOVE.qty > (latest WEIMI current_stock for that shelf, within 3 days)`, insert a `monitoring_alerts` row of source `remove_qty_exceeds_lane` carrying `{machine, shelf, pod_product, plan_qty, lane_stock, snapshot_date}`, and surface it in the Gate-1 review output.

**Also emit it at `push_plan_to_dispatch`** so a plan edited after Gate 1 is re-checked.

**Verification:** replay the 24 Aug WAVEMAKER plan in a rolled-back tx — assert exactly one alert on A03 (`plan_qty 5, lane_stock 3`). Then replay a known-good plan and assert zero alerts.

---

### T1.3 — Item M (NEW): the re-binding trigger propagates a wrong lane silently

`tg_rebind_slot_lifecycle_on_add_confirm` re-binds a shelf to whatever an Add New confirms into it. It faithfully copied incident B's error into `slot_lifecycle`, which is what the next day's engine reads.

**Fleet census run 24 Aug: only 2 shelves currently drift** (AMZ-1046 A07, HUAWEI-2003 A08 — both "Freakin Awesome Filled Dates"). So the acute damage is contained. The *mechanism* is not.

**Fix tonight — alert only, do not change the trigger's behaviour.** When the trigger is about to bind shelf X to pod P, compare against the latest WEIMI reading for that slot. On disagreement, still bind (WEIMI labels are unreliable — see the hard rules), but insert a `monitoring_alerts` row of source `slot_rebind_disagrees_with_weimi`.

**Rationale for alert-only:** WEIMI labels go stale, so a hard block would have refused the *correct* A01 Sunbites binding on 24 Aug. Two unreliable sources, neither authoritative alone — the honest move is to surface the disagreement to a human, not to pick a winner in a trigger.

**Verification:** rolled-back replay of the 24 Aug WAVEMAKER receive — assert one alert on A03 and none on A01.

---

### T1.4 — Item I: expiry entry sanity check

**Carried from PRD-116 phase 2, unchanged, now cleared to ship as warning-only.**

A day/month transposition moved a batch 11 months (Vitamin Well Zero Lemon entered 2027-01-03, true 2027-12-03).

Add to `receive_purchase_order`, `receive_purchase_order_addition` and `receive_dispatch_line`: expiry under `purchase_date + 30d`, over `purchase_date + 24m`, **or** a day/month swap that lands more plausibly (3–18 months out) → insert a `monitoring_alerts` row of source `expiry_entry_suspect` carrying both candidate dates.

**Never a block. Never an auto-correction.**

⏰ **Timing constraint: apply this EARLY in the run, not after 03:00 UTC.** These are the three writers the warehouse uses from 07:00 Dubai. Leave hours of margin to notice a problem, and re-verify all three after applying.

---

## 3. TIER 2 — PREPARE, DO NOT APPLY

### T2.1 — Housekeeping (do this FIRST, it has been blocked for two days)

- `rm -f .git/index.lock` (an editor on CS's machine has been holding it).
- Commit the five staged migrations: `prd016c`, `prd016d`, `prd113b`, `prd116a`, `prd116b`, `prd116c`.
- Commit the PRD docs: `PRD-116-refill-edge-case-hardening.md`, `PRD-116-phase2-capacity-and-batch.md`, `PRD-116-item-B-followup-internal-move-classification.md`, and this file.
- The uncommitted FE work in `procurement/page.tsx` (the receive-destination modal, PRD-016d) is **deliberate and tsc-clean** — commit it, do not revert it. `pods/page.tsx` and `field/config/machines/page.tsx` predate this work; leave them alone.

### T2.2 — Item N (NEW): duplicate warehouse batch rows

**25 duplicate groups, 58 rows, 756 units** where two or more Active `warehouse_inventory` rows share `(boonz_product_id, warehouse_id, expiration_date)`. These are physically indistinguishable, so every inventory count against them is a guess — this is what made the WPP Popit count look wrong.

**Produce the list as a CSV** (`BOONZ BRAIN/duplicate_wh_batches_2026-08-24.csv`) with product, warehouse, expiry, row ids, units each. **Do not merge anything.** `warehouse_inventory` is a protected entity and a merge needs CS's decision per group.

Sketch the merge RPC (`merge_wh_inventory_batches(p_keep_id, p_merge_ids[], p_reason)`) in the file, unapplied — must sum stock onto the keeper, mark the others Inactive, write `inventory_audit_log` rows with `provenance_reason='batch_merge'`, and assert total unchanged.

### T2.3 — Item O (NEW): impossible dispatch dates

**76 rows dated in 2030** — 68 at `2030-04-23`, 8 at `2030-11-05`. Find how they were written (check `refill_dispatching_edit_log` and the audit trail), and whether they are inert or being picked up by any query using `max(dispatch_date)`.

Produce findings. **Do not mutate.** A date fix on `refill_dispatching` needs a canonical RPC that does not exist yet.

### T2.4 — Item H + J1 + K: FE branch `prd116-fe-dialogs`

Branch only, **no deploy**. Run `npx tsc --noEmit` and `npx eslint` on every file touched. The only acceptable pre-existing error is `react-hooks/set-state-in-effect` at `procurement/page.tsx` ~line 633.

- **H** — convert the remaining 9 `window.prompt`/`window.confirm` sites (6 on the procurement page) to in-app modals, on the pattern of the receive-destination modal already in that file.
- **J1** — `src/app/(field)/field/packing/[machineId]/page.tsx` ~line 4886: the swap shelf-picker is built from the visit's `lines`, so WPP showed 3 of 16 live shelves and A13 was unreachable. Source it from `shelf_configurations` for the machine, label each option with its current WEIMI pod, and **annotate** rather than exclude shelves already in the plan.
- **K** — the "redirect this return to another machine" affordance. **The backend already exists and is correct** — `convert_removes_to_m2m_transfer` + `approve_m2m_transfer`, both used successfully on 24 Aug (JET → OMDBB, 5 Vitamin Well, `wh_delta 0`). This is a front door for a working backend, nothing more. Full spec in `PRD-116-phase2-capacity-and-batch.md` item K.

### T2.5 — Item D: engine ADD_NEW sizing

`engine_swap_pod` sizes swap-ins to the **outgoing** product's WEIMI lane max (Sunbites 14 in a Perrier lane; Krambals 16 in a Vitamin Well lane). Mirror the PRD-116c fix inside the engine: cap at the **incoming** pod product's own fleet facing (max `weimi_aisle_snapshots.max_stock`, 30d), falling back to lane max.

**Write the migration SQL and the fixture plan. Do not apply.** This is a live engine version bump and needs a fixture run with CS present.

---

## 4. TIER 3 — DESIGN ONLY, DO NOT TOUCH

| Item | Why it stays here |
|---|---|
| **E** — per-product lane capacity model (lane geometry × product form factor, replacing "last WEIMI reading") | Schema. Needs Dara. Open question: does a `product_form_factor` classification exist anywhere today? |
| **F** — `pod_inventory` multi-batch (drop `unique(machine,shelf,product)`) | Schema + a writer sweep across `adjust_pod_inventory`, `record_actual_refill`, `receive_dispatch_line`, `receive_po_addition_into_machine`. **Rollback is not clean once real multi-batch data exists** — Cody must read this before it is ever applied. |
| **G** — Red Bull Regular 0% global split; ~15 machine-scoped-only SKUs invisible to procurement | A mapping decision that affects stitch fleet-wide. CS's call in a weekly session. |
| **J2** — Remove validated at flavour level against pod-level data | A UX consequence of F. Ships with F or immediately after, not before. |
| **21 units of possible phantom WH stock** from 7 historically-approved internal moves (carried from 20 Aug, **re-verify before acting**) | Needs a physical count, not code. |

---

## 5. Morning verification (schedule for 05:45 Dubai = 01:45 UTC)

Use the Claude Code Remote MCP `create_trigger` — **never** the local `CronCreate` tools, which die with the session.

Report, and wake CS on any deviation:

1. `preflight_refill_plan(<tomorrow>)` = PASS.
2. Row count in `v_pending_wh_remove_confirmations` and `v_pending_return_approvals`.
3. `po_additions` where `status='pending_receive'`.
4. Dispatch totals for the live plan date; count of unbound fill lines — **excluding `source_kind='m2m'`**, which are deliberately not FEFO-bound (they carry the source shelf's expiry) and would otherwise false-positive on every redirect.
5. Any `monitoring_alerts` with source `dispatch_bridge_nonok`, or any `stitch_leakage` rows, created since the run started. Expect none.
6. **New tonight:** counts for `remove_qty_exceeds_lane`, `slot_rebind_disagrees_with_weimi`, `expiry_entry_suspect`. First-night counts are a baseline, not a failure — report them, don't alarm on them.
7. `rebind_slot_lifecycle_from_weimi(NULL, true, ...)` dry run — expect the 2 known drifting shelves (AMZ-1046 A07, HUAWEI-2003 A08) and nothing new. **Never run it live without checking the WEIMI label is fresh** — on 24 Aug it would have reverted a correct binding.

---

## 6. Deliverable

A single report at `BOONZ BRAIN/OVERNIGHT_REPORT_2026-08-25.md`. Per item: what you did, the verification output verbatim, what you deliberately did not do and why, and anything CS must decide before the team starts at 07:00.

If an item blocks you, record the blocker and move to the next. Do not stall the run on one item.

---

## Appendix — the numbers, all re-verified 24 Aug 2026

| Metric | Value |
|---|---|
| Mistagged same-machine `m2m` rows | 115 (107 open, 8 settled) |
| REMOVE plan rows exceeding their own lane stock (60d) | 25 of 149 — **17%** |
| Duplicate Active WH batch groups | 25 groups / 58 rows / **756 units** |
| Slot bindings currently drifting from WEIMI | 2 |
| Dispatch rows with impossible dates | 76 (2030) |
| Fill rows where `filled_quantity <> quantity` (30d) | 523 of 2,251 — **23%** |
| Remove legs driver-confirmed (30d) | 184 of 286 |
| …**carrying who confirmed them** | **2** |

That last row is the one to sit with. The system records what happened; it almost never records who did it. Every "who is complying" question is currently unanswerable from the database alone — which is the subject of the separate Operations Record audit, not this run.
