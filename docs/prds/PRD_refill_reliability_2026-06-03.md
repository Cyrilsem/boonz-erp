# PRD — Refill Pipeline Reliability & Recommendation Intelligence

**Date:** 2026-06-03 · **Owner:** CS · **Status:** Open
**Trigger:** 2026-06-03 refill failed across submission, dispatch, inventory accuracy, and recommendation fidelity. Post-mortem: `BOONZ BRAIN/refill_postmortem_2026-06-03.md`.

---

## 0. Operating constraints (READ FIRST — Backend Constitution)

This system is governed by the Backend Constitution (`boonz-erp/docs/architecture/01_constitution.html`). Every change in this PRD MUST honor:

- **Cody review** before any `CREATE OR REPLACE` of a SECURITY DEFINER function or any DDL on an Appendix A protected entity (`machines, shelf_configurations, planogram, slots, slot_lifecycle, pod_inventory, warehouse_inventory, daily_sales, sales_lines, settlements, refill_plan_output, refill_dispatching, machines_to_visit, pod_refill_plan, strategic_intents, …`).
- **Dara** designs schema (columns/indexes/RLS shape); Cody rules compliance; only then apply.
- **No raw `UPDATE/INSERT/DELETE`** on `pod_refill_plan`, `refill_plan_output`, `refill_dispatching`, or any Appendix A entity — every state change goes through a canonical RPC. If no RPC exists, build it first.
- **No destructive change** (delete, stock reduction) without showing CS the row-level diff and getting sign-off.
- **`warehouse_inventory.status`** is manager-only (propose-then-confirm via `warehouse_inventory_status_proposal`); no trigger/RPC/cron may silently write it.
- **Multi-variant splits** distribute EVENLY (±1), FEFO oldest-expiry first.
- Engine `CREATE OR REPLACE` cascades require Cody review of the version diff (the 2026-05-19 v4→v7 cascade is the anti-pattern).

Supabase project: `eizcexopcuoycuosittm`. Conductor skill: `boonz-master-3`.

---

## 1. Goals

1. A refill can always be **submitted/dispatched end-to-end** — no silent failures, no unpackable rows that hard-block a machine.
2. The **dispatch reflects operator reality** — manual swaps/edits are durable and not clobbered by re-push.
3. **Inventory ledger is trustworthy** — WH ↔ pod movement nets to 0; `consumer_stock` drains on receive; no phantom availability.
4. **Driver/ground recommendations drive the plan** — prioritized, persisted across visits.
5. **Free-text recommendations (Jojo/CS/Simran) translate into structured intents** that update `product_mapping` (per-machine flavor/SKU mix weights and shelf product changes).

## 2. Non-goals (explicit)

- **Do NOT gate refills on WH availability yet.** Inventory is not stable enough; gating now would mass-suppress rows and create more confusion. Revisit after Workstream 3 stabilizes the ledger. (CS directive 2026-06-03.)

---

## 3. Workstreams

### WS1 — Stitch atomicity + REMOVE resolution ⟶ partially DONE

**Problem:** `stitch_pod_to_boonz` called `confirm_stitched_plan` unconditionally after `write_refill_plan`. On a `validation_error` (unmappable REMOVE `boonz_product_name`), the pod plan flipped to `stitched` while `refill_plan_output` stayed empty → silent whole-machine dispatch loss (this is what stranded VML).

**Done (2026-06-03):** `phaseF_stitch_gate_confirm_on_write_ok` — stitch now only confirms when `write_refill_plan` returns `status='ok'`; otherwise returns `skipped_write_failed` and leaves the pod plan `approved` (retryable, visible). Cody-approved (Articles 1,4,8,12,14).

**Remaining (WS1b):** the underlying rejection. `write_refill_plan` V5 rejects REMOVE/M2W lines whose pod maps to a multi-variant/combined boonz (`Evian` vs `Evian - Regular`, `Vitamin Well`, `Krambals & Zigi`).

- Fix in stitch line-builder: resolve a REMOVE/M2W pod to a **concrete boonz variant** (FEFO / live-shelf attribution), or skip qty-0 REMOVE lines from the V5 name check.
- Acceptance: a swap with a REMOVE (e.g. VML Evian→Popit) stitches and dispatches in one pass, no `validation_error`.
- Files: `stitch_pod_to_boonz`, `write_refill_plan`. **Cody required.**

### WS2 — Dispatch ↔ pod_refill_plan durability + submittable refills

**Problem A (clobber):** manual `add_dispatch_row`/`remove_dispatch_row` edits live only in `refill_dispatching`; `push_plan_to_dispatch` regenerates dispatch from `pod_refill_plan`, restoring stale rows and wiping swaps (VML A01 Popit came back over Coke Zero).
**Problem B (hard-block):** an `include=true` row that can't be packed (no stock / stale after swap) blocks the whole-machine submission with no clean "skip".

**Fix:**

- Make `push_plan_to_dispatch` **idempotent & edit-aware** — never recreate rows already cancelled/edited at dispatch level (track an edit marker), or push manual dispatch edits back into `pod_refill_plan` so the two cannot diverge.
- Add a **canonical "skip line"** path (FE + RPC) so an operator can mark a line skipped/unfulfillable and still submit the machine. Skipped lines log a reason; do not block.
- Acceptance: re-pushing a plan after a manual swap does not resurrect the swapped-out product; a machine with one unfulfillable line is still submittable.
- Files: `push_plan_to_dispatch`, FE pickup/packing tab, new `skip_dispatch_line` RPC. **Cody + Dara (edit marker col).**

### WS3 — Inventory reconciliation to 0 balance (D + C)

**Problem:** `consumer_stock` (reserved/in-transit) only drains on receive; packed-not-picked lines leave it parked; availability UX over-reads "physical" (warehouse+consumer). Specific physical corrections outstanding (Simran doc).

**Fix / tasks:**

1. **Drain mechanical:** for 2026-06-03, complete the receive flow on truly-delivered packed lines so `consumer_stock → pod_inventory`. EOD release for genuinely un-picked (`defer_dispatch_lines`).
2. **Apply Simran's physical corrections** (per-item, with row diff + CS sign-off — these move real counts):
   - Mindshare: Vit Well Upgrade +2 (exp 02/08/26); Care/Antioxidant/Zero Peach showing 0-stock rows (suppress, WS6).
   - WPP: Perrier Regular ×2, Lime ×2, Peach ×2 (various expiries).
   - AMZ-1038: Smart Classic Hummus +1 (25/01/27), Beetroot Hummus +1 (01/08/26).
   - AMZ-1068: Al Ain Water 14 (10/04/27), Vit Well Reload +1 (23/08/26), Red Bull Regular ×3 (variant repin, WS6).
   - AMZ-1057: Pepsi Black +3 (29/10/26), Sunbites Cheese +2 (21/09/26), Green Olives Krambals transfer from 0705.
   - OMDBB/OMDCW/HUAWEI: Hunter variants, Al Ain Water, BE-KIND, Iced Tea (see doc).
3. **C (refill log):** log the manual/driver-added refills that the system missed (VML Coke Zero 23/Popcorn/Popit splits/Evian removed; AMZ-1068 Al Ain 14; AMZ-1057 Pepsi Black/Sunbites; OMDCW Al Ain 19) into the refill log / action_tracker.
4. **Verify 0 balance:** WH `warehouse_stock + consumer_stock` reconciles to physical; pod_inventory matches `v_live_shelf_stock`; no negative/phantom rows.

- Constraint: archival pattern (status→Inactive, never DELETE); `reactivate_warehouse_row` for re-adds; `warehouse_inventory.status` propose-then-confirm. **Per-row CS sign-off mandatory.**

### WS4 — Driver feedback prioritized into the engine

**Problem:** `driver_feedback` captured but never ingested (G5 "Track D" never wired); engine plans from velocity only, overrides ground truth (OMDCW Mars).

**Fix:** wire `driver_feedback` into `engine_add_pod` as a **priority demand input** — a driver-requested product/qty boosts/forces that line (above velocity targets) for the next plan, with decay so it doesn't persist forever. Account for both per-shelf qty asks and "bring back product X".

- Acceptance: a driver rec "OMDCW +5 Mars" appears in the next plan at the requested qty.
- Files: `engine_add_pod`, new `v_driver_feedback_demand` view, `driver_feedback` weight/decay columns (Dara). **Cody + Dara.**

### WS5 — Recommendation translator → product_mapping (the big one)

**Problem:** CS/Jojo/Simran share recommendations as free text (this doc, WhatsApp). No path from text → structured intent → system wiring. Recommendations should **update `product_mapping`**, and there are two levels:

- **Boonz-product recommendation** = a machine consumes more of a specific **flavor/SKU** than the shared-shelf average → adjust that machine's **`product_mapping.mix_weight`** for that boonz variant on that shelf (so future splits favor it).
- **Pod-product recommendation** = change the **product on the shelf** (planogram-level) → swap/decommission flow.

**Fix (design WS5a, build WS5b):**

- **Translator:** an ingestion skill/RPC that takes free text (or a structured paste) and emits typed `recommendation_intents` rows: `{machine, shelf, level: boonz|pod, product, action: increase_weight|decrease_weight|add|remove|set_qty, magnitude, source: driver|cs|jojo, raw_text}`. Use Claude to parse; require human confirm before apply.
- **Apply boonz-level:** writer RPC `apply_mix_weight_recommendation(machine_id, shelf_id, boonz_product_id, delta)` → updates per-machine `product_mapping.mix_weight` (machine-scoped row; create if only global default exists). Re-normalize shelf weights to sum 1.
- **Apply pod-level:** routes to existing swap/decommission flow.
- New table `recommendation_intents` (Dara) + audit. Translator is human-in-the-loop (confirm before write).
- Acceptance: paste "VML A15 Popit: Original Cola sells 2× the others" → creates intent → on confirm, VML-scoped mix_weight for Original Cola on A15 increases and future splits reflect it.
- Files: new skill `recommendation-translator`, `recommendation_intents` table, `apply_mix_weight_recommendation` RPC, `product_mapping` machine-scoped rows. **Dara + Cody.**

### WS6 — Variant resolution + suppress 0-stock rows

**Problem:** Red Bull Regular packed but Diet dispatched (wrong variant pin); Vitamin Well variants generate packing rows with 0 inventory; in-stock variant (Upgrade) not surfaced.

**Fix:**

- Repin Red Bull and Vitamin Well `product_mapping`/`pod_inventory` variant attribution (data, with diff).
- Stitch/engine: do not emit a dispatch row for a resolved boonz variant with 0 WH stock **at write time** (note: this is variant-row suppression, NOT the WH-availability _gate_ from Non-goals — scope it to "don't generate a row for a SKU with literally zero stock anywhere").
- Acceptance: no packing row for a 0-stock variant; packed variant == dispatched variant.

### WS7 — FE quality-of-life

- **Stock + 7d sales columns** on `RefillPlanningTab` pending view (currently 0/0) — enrich the pending reader like `get_pod_refill_draft` does (join `v_live_shelf_stock` + 7d sales).
- **Availability UX:** packing screen should say "reserved to {machine list}", and explain "committed vs pickable", so "shows 0 but stock there" reads correctly.
- Files: `src/app/(app)/refill/RefillPlanningTab.tsx` + pending reader; packing component. **Stax.**

---

## 4. Sequencing (recommended)

1. WS1b (REMOVE resolution) — unblocks swaps end-to-end. _Cody._
2. WS2 (dispatch durability + skip) — stops re-push clobber + hard-blocks. _Cody+Dara._
3. WS3 (inventory reconcile to 0) — restores ledger trust. _Per-row CS sign-off._
4. WS6 (variant repin + 0-stock suppression).
5. WS4 (driver feedback priority).
6. WS5 (recommendation translator) — the strategic one; design first.
7. WS7 (FE) — parallelizable.

## 5. Already done (2026-06-03)

- WS1a stitch confirm-on-error gate — applied, Cody-approved, verified.
- VML A01 unpackable Popit line cancelled (safe unblock; machine now submittable).
- Picker v7 (velocity+shelf, P1/P2, VOX track) + get_machine_health v2 + FE filters — earlier today.

## 6. Blocked / needs-CS (security & constitutional — NOT auto-applied)

These were deliberately NOT executed autonomously; CS to approve:

- **All physical inventory corrections (WS3.2/3.3)** — move real stock counts; require per-row diff sign-off (no-destructive rule) and physical confirmation. Logged, not written.
- **Draining the 19 `consumer_stock` units** (VML Popit 16, McVities 1, AMZ-1029 Popcorn 2) — requires confirming whether each packed line was physically delivered (receive) vs un-picked (release). State change on protected `refill_dispatching`/`warehouse_inventory`; needs CS call per line.
- **Any `warehouse_inventory.status` change** — manager-only propose-then-confirm.
- **VML A01/A15 dual-product reconciliation** — the swap left Coke Zero + residual packed Popit on A01; reconciling consumer_stock + pod_inventory needs the physical truth of what the driver actually loaded.
- **WS2 edit-marker schema, WS4/WS5 schema** — need Dara design + Cody before any apply.

---

## 7. /goal for Claude Code

See `goal_refill_reliability.md` (companion). Start with WS1b, gate every protected write through Cody, never raw-write protected tables, and surface diffs for all inventory corrections.
