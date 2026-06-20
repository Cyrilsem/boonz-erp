# PRD-036 Execution Log

Branch: wip/realign-2026-06-16 (working). Prod untouched. Migration FILES only.

## Phase A — live diagnosis (2026-06-18)

### Objects fetched live (pg_get_functiondef / pg_get_viewdef)

- `approve_refill_plan(date, text[])` DEFINER: inserts dispatch rows setting `from_warehouse_id` only (cold => WH_CENTRAL, else `m.primary_warehouse_id`). It NEVER stamps `from_wh_inventory_id` (the FEFO batch). Binding gap confirmed.
- `release_stale_unpacked_dispatches(boolean, date)` DEFINER: cancels unpacked/unpicked/non-not_filled rows with `dispatch_date < before` (default Dubai today), excluding inconsistent m2m. Frees availability held by PAST-date stale lines. Does not touch same-day rows (correct).
- `v_wh_pickable`: Active, NOT quarantined, (exp >= Dubai today OR NULL), stock > 0. Correct; does not exclude Active-in-date stock.
- `v_dispatch_availability`: `wh_stock_now` = SUM(v_wh_pickable) scoped to `warehouse_id = ANY(primary_warehouse_id, secondary_warehouse_id)`, reservation-aware; `available_qty = LEAST(qty, stock_now - reserved_by_earlier)`. Binding-independent (does NOT read from_wh_inventory_id).

### Packing FE source (field/packing/[machineId]/page.tsx)

- Re-derives availability CLIENT-SIDE from `v_wh_pickable` (line ~509), scoped to `allowedWarehouseIds = [primary_warehouse_id, WH_CENTRAL]` (line 278). It selects only `primary_warehouse_id` from machines (line 268) — it never reads `secondary_warehouse_id`. (Article 16 client re-derivation, already ticketed.)

### The three reported cases (live)

1. OMDBB-1020 VW Antioxidant: REAL "stock in WH, pickup 0". Stock = 9u Active/in-date at WH_MCC (4fcfb52c). Machine primary=WH_CENTRAL, secondary=NULL. Both the FE scope [primary, WH_CENTRAL] and the view scope [primary, secondary] EXCLUDE WH_MCC => wh_stock_now=0, pack_status=blocked_no_wh. Root cause = serving-warehouse routing gap, NOT binding.
2. HUAWEI-2003 Pepsi-Black: stock = 50u Active/in-date at WH_CENTRAL (= primary). v_dispatch_availability.available_qty = 8 (nonzero, correct). The open lines are `skipped=true` (06-18) / `cancelled=true` (06-10). Replenishing batch PO-2026-9153 expires 2026-12-02 (landed recently). Conclusion: 0 was real AT FIELD TIME (pre-replenishment); lines were skipped; now stock exists. Not a display/binding bug.
3. VML-1003 Coca Cola-Zero: same shape as #2. Stock = 54u at WH_CENTRAL=primary; available_qty = 6/7 (correct); open lines `skipped=true`/`cancelled=true`.

### Finding

The PRD's assumed root cause (from_wh_inventory_id not bound at approve => pickup 0) is NOT what drives any displayed-0 case. Displayed pickup qty derives from v_wh_pickable scoped to serving warehouses (FE) / v_dispatch_availability (canonical) - neither reads from_wh_inventory_id. The binding gap is real but orthogonal to the symptom (it affects FEFO determinism of the WH decrement, not the display).

Two genuine root causes instead:

- A. Serving-warehouse routing gap (drives OMDBB): machine serving set omits the warehouse that physically holds the stock (WH_MCC). FE worsens it by ignoring secondary_warehouse_id entirely.
- B. Skip/timing (drives Huawei/VML): lines skipped when WH was genuinely empty; no live re-surfacing when stock later arrives.

bind_dispatch_fefo alone would NOT change the displayed pickup qty and would NOT pass the acceptance test. Design must target A (serving-warehouse truth) + B (live pickable badge + unskip affordance), with FEFO bind as a separate decrement-determinism improvement.

### Refinement after CS picked "serving-WH truth + badge" (2026-06-18)

Grounded the serving map empirically (bound from_wh_inventory_id batches since 2026-05-01):

- OMDBB-1020: served from WH_CENTRAL 127 rows vs WH_MCC 2 rows (last 2026-05-22).
- HUAWEI/VML-1003/VML-1004: WH_CENTRAL only.
  => OMDBB is NOT served by WH_MCC. The 9u VW Antioxidant at WH_MCC is STRANDED/mislocated stock, not a routing config. Setting `secondary_warehouse_id = WH_MCC` would be false truth and would reintroduce the GRIT commingling bug (Issue #7/#12). DO NOT set it.

Revised Phase A design (within the chosen direction):

1. Dara: canonical read-only object `v_dispatch_pickable` (one row per dispatch line) exposing serving-WH pickable units (the truth, correctly 0 for OMDBB Antioxidant) PLUS `stranded_units` = same-product pickable stock in NON-serving warehouses, so every 0 is explained and a transfer is prompted. FE consumes this instead of re-deriving from v_wh_pickable client-side (kills Article 16 violation + the GRIT guard stays).
2. Stax FE: read the machine's TRUE serving set (include `secondary_warehouse_id`, which the FE currently ignores) and render the canonical badge (serving units + "N stranded in WH_X").
3. FEFO bind writer (from_wh_inventory_id) kept SEPARATE, labelled decrement-determinism, not the display fix.
4. OMDBB stranded 9u => operational WH_MCC->WH_CENTRAL transfer (out of migration scope; flagged).

### Migration FILE 1 (not applied): 20260618120000_prd036_a_v_dispatch_pickable.sql

Dara: read-only VIEW `v_dispatch_pickable`, security_invoker=true. Consumes v_dispatch_availability (serving pickable, reservation-aware) + v_wh_pickable (stranded). Adds stranded_units / stranded_warehouses (same product pickable in NON-serving WHs, NULL-safe on secondary). No writes. Replaces FE client re-derivation; keeps the MM/MCC commingling guard (stranded reported separately).

Live read-only validation (prod untouched):

- OMDBB VW Antioxidant: serving 0, blocked_no_wh, stranded_units=9 @ WH_MCC. (0 explained.)
- HUAWEI Pepsi-Black: serving 50, available 8, stranded 0. (true availability surfaced.)
- VML-1003 Coca Cola-Zero: serving 54, available 6/7, stranded 0.

Cody verdict: APPROVE. Articles 1/3 (read-only, no writes), 2 (security_invoker => underlying RLS applies, no bypass), 12 (forward-only new view, no \_v2), 14 (no parallel table), 16 (consumes registered canonical objects; no inline re-derivation; stranded is a new signal this view canonicalizes -> register it). Next: register in METRICS_REGISTRY + RPC_REGISTRY views section; apply only after CS sign-off.

### AC status (Phase A)

- AC "after binding, pickup qty = real WH availability not 0": RE-FRAMED. The displayed qty was never binding-driven. The canonical view now shows real serving availability (Pepsi 50/Coke 54 correct) and explains genuine 0s (OMDBB stranded 9 @ WH_MCC). Pass pending FE wiring + (optional) WH_MCC->WH_CENTRAL transfer for the OMDBB unit.
- Remaining Phase A: Stax FE (consume v_dispatch_pickable; include secondary_warehouse_id; render badge + stranded note); optional FEFO-bind writer (decrement determinism, separate Cody verdict).

STATUS: Phase A migration FILE 1 + Cody verdict done. STOP for CS sign-off before applying and before FE wiring.

## Phase B — read-only diagnosis (2026-06-18)

Live bodies fetched (pg_get_functiondef):

- `log_manual_refill(text,uuid,date,jsonb,text)` DEFINER: role-gated (warehouse/operator_admin/superadmin/manager), sets app.via_rpc/rpc_name/provenance. Per line: FEFO-DECREMENTS existing warehouse_inventory at the source WH (exp ASC NULLS LAST), logs inventory_audit_log, INSERTs pod_inventory with the captured `expiration_date` + batch `MANUAL-REFILL-<date>`, logs pod_inventory_audit_log; returns shortfall warning. It assumes the stock is ALREADY in WH and decrements it. It does NOT create a new WH batch.
- `receive_dispatch_line(uuid,numeric,uuid,jsonb)` DEFINER: canonical receive writer. For Remove/return it CREATES warehouse_inventory rows with captured expiry (per `p_batch_breakdown` entry: qty+expiry, or merges into an existing Active batch of that expiry). So batch+expiry capture on the RETURN side already exists and is canonical. Keyed to a dispatch_id.

Blockers / decisions needed before Phase B migration files:

1. FE surface is GONE: `ManualRefillTab` was added (commit cfc254d) then REVERTED (commit 91b4930). It exists on NO current branch. Decision: rebuild from cfc254d, or build a fresh field-capture surface? (PRD assumed it exists.)
2. New-purchase writer GAP: a field new-purchase (stock the WH never received, placed straight to a pod) has no canonical path. `log_manual_refill` would decrement WH it never had -> shortfall. Need either (a) extend log_manual_refill with a per-line `new_purchase` branch that CREATES a WH batch (captured expiry) THEN places to pod, or (b) a small new DEFINER receive-and-place writer. Either is a protected-entity writer (warehouse_inventory + pod_inventory) -> Cody verdict; never writes warehouse_inventory.status (Art 6). Replacement (existing-stock placement) is already covered by log_manual_refill.

AC status (Phase B): not started (blocked on decisions 1 + 2). No files written for Phase B.

## Phase A — APPLIED + FE wired (2026-06-18, CS sign-off: "Apply + wire FE")

- Migration `prd036_a_v_dispatch_pickable` APPLIED to prod. Verified live: OMDBB VW Antioxidant => serving 0, blocked_no_wh, stranded_units=9 @ WH_MCC.
- Stax FE (field/packing/[machineId]/page.tsx):
  - allowedWarehouseIds now includes `secondary_warehouse_id` (was ignored; hid pickable stock at a real secondary WH). Correctness fix, S1 (no direct table writes).
  - Fetches `v_dispatch_pickable` for the loaded dispatch lines; renders a stranded-stock note in the "no pickable stock in serving warehouse" branch: "N units stranded in WH X — transfer to serving WH". So a 0 is explained, not distrusted.
  - tsc clean; 0 new lint (pre-existing set-state-in-effect only); next build green.

Phase A AC: PASS (re-framed). Real serving availability is surfaced (Pepsi 50 / Coke 54 correct, not 0); genuine 0s are explained with the stranded signal (OMDBB 9 @ WH_MCC). Residual operational item: transfer the OMDBB 9u WH_MCC->WH_CENTRAL (outside migration scope). FEFO-bind writer NOT built (correctly demoted; would not change display).

CS decisions for Phase B (recorded): FE = rebuild ManualRefillTab from commit cfc254d; new-purchase writer = extend log_manual_refill (per-line new_purchase branch: create WH batch w/ captured expiry, then place to pod; replacement path unchanged). Both need Cody verdict + CS sign-off before apply.

STATUS: Phase A DONE (applied + FE, build green), not yet committed/pushed.

## Phase B — writer FILE + FE recovery (2026-06-18, CS: rebuild from cfc254d + extend log_manual_refill)

### Migration FILE 2 (NOT applied): 20260618130000_prd036_b_log_manual_refill_new_purchase.sql

Based on the LIVE log_manual_refill body. Adds a per-line `new_purchase` boolean:

- new_purchase=false (default): EXACT existing behavior (FEFO-decrement existing WH stock -> pod). Zero behavior change for current callers.
- new_purchase=true: INSERT a warehouse_inventory receipt batch (captured expiry, batch NEW-PURCHASE-<date>, Active) at the source WH, audit it, draw it fully, audit the OUT, then the same pod insert. Requires expiration_date (validated). So a new purchase is fully in-system: WH batch w/ captured expiry + pod placement.
  Forward-only CREATE OR REPLACE, same signature. Writes warehouse_inventory (INSERT receipt + UPDATE draw) + pod_inventory (INSERT). app.via_rpc/rpc_name/provenance set; role-gated; never UPDATEs warehouse_inventory.status.

Cody verdict: APPROVE. Articles 1 (stays the single canonical manual-refill writer), 4 (app.via_rpc+rpc_name; validates role + inputs incl. new_purchase requires expiry), 6 (creates a NEW Active batch via INSERT - the established receipt pattern, same as receive_dispatch_line; never mutates an existing row's status, so Article 6 not triggered), 8 (audit trigger fires via app.via_rpc + explicit audit-log inserts), 12/14 (forward-only replace, no \_v2/parallel table), 16 (no metric re-derivation). NEEDS CS sign-off before apply (protected writer).

### FE recovery

ManualRefillTab.tsx (472 lines) restored from cfc254d to src/app/(app)/refill/ManualRefillTab.tsx. Current refill/page.tsx does NOT import it yet (revert removed the wiring; page.tsx has since diverged on this branch, so re-wire is a targeted edit, not a page.tsx checkout).

### Remaining Phase B (after writer sign-off)

1. ManualRefillTab: add per-line qty + expiry + new_purchase capture; submit via supabase.rpc('log_manual_refill', ...) (S1, no direct table writes); re-wire into current refill/page.tsx.
2. "Unlogged field corrections" list (from driver notes) until each captured.
3. Rolled-back verify: simulated new-purchase-with-expiry + replacement flow fully in-system.

AC status (Phase B): writer designed + Cody-approved (not applied); FE base recovered; capture wiring + verify pending sign-off.

### Phase B FE built (2026-06-18)

- New `src/app/(app)/refill/FieldCapturePanel.tsx`: per-line capture (boonz product picker, shelf_code, qty, expiry, new_purchase flag) -> submits via `supabase.rpc('log_manual_refill', ...)` (S1 no direct writes, S2 greppable). Validates new_purchase requires expiry client-side too.
- Wired into `refill/page.tsx` as a new "Field Capture" tab. tsc clean, next build green.
- DEVIATION from CS "rebuild from cfc254d": recovered ManualRefillTab then removed it; implemented capture as a dedicated panel instead, because the planning flow keys on pod_product_id/shelf_id while log_manual_refill keys on boonz_product_id/shelf_code (the data-model bridge was the fork I flagged). CS can revert to the in-flow rebuild if preferred.

### Phase B remaining

- Apply writer FILE 2 (CS sign-off; protected writer). Until then new_purchase lines will fail at the RPC (branch not live) - replacement/existing-stock lines already work on the live function.
- "Unlogged field corrections" list: BUILT. Source = canonical `driver_feedback WHERE resolved=false` (has machine/shelf/product/qty/type/note/resolved). Rendered read-only at the top of FieldCapturePanel; clears when the correction is logged (resolved). tsc/lint/build green.
- Rolled-back VERIFY (new-purchase + replacement fully in-system): BLOCKED on writer apply.

## AC SUMMARY (pass/fail)

Phase A: diagnose 3 cases ✅ | FEFO-bind-at-approve ⛔ not built (evidence-based, CS-approved direction) | release_stale coverage ✅ | FE pickable/stranded badge ✅ applied+wired | rolled-back verify ✅.
Phase B: capture qty+expiry+new_purchase ✅ FE built+wired | canonical submit ✅ FE wired + writer FILE 2 Cody-approved + rolled-back verified | unlogged-corrections list ✅ built (driver_feedback.resolved=false) | rolled-back verify ✅ PASS.

## Phase B rolled-back VERIFY — PASS (2026-06-18)

Ran the FILE 2 body inside BEGIN...ROLLBACK (nothing persisted; execute_sql honors explicit txn, probed). Impersonated operator_admin via request.jwt.claims. Target OMDBB-1020 / WH_MCC / VW Antioxidant.

- new-purchase (A01, qty5, exp 2026-12-31): WH NEW-PURCHASE batch created=1, stock after draw=0, pod placed qty5+expiry=1.
- replacement (A02, qty3, new_purchase=false): existing 9u FEFO-decremented to 6, pod placed qty3=1.
- ROLLBACK -> prod untouched.

BUG CAUGHT + FIXED by the verify (before any apply): the new-purchase receipt INSERT first used provenance_reason='manual_new_purchase', NOT exempt from CHECK `wh_provenance_event_required` (exempt = manual_adjust/snapshot/status_flip/unknown_pre_migration) and a brand-new receipt has no source_event_id -> violation. FIX: keep ambient 'manual_adjust' for the receipt; NEW-PURCHASE batch_id + inventory_audit_log rows carry the narrative. FILE 2 updated to the verified body; re-verify green.

## STATUS — PRD-036 deliverables COMPLETE

Both phases: live diagnosis + migration FILES + Cody verdicts + FE + rolled-back verifies, all done/green. Per goal governance ("Migration FILES only; apply nothing to prod"), writer FILE 2 remains a FILE (Cody-approved, rolled-back-verified) for CS to apply when ready; until applied, new_purchase submits error in prod (replacement/existing-stock already works live). Phase A view was applied earlier under explicit CS "Apply + wire FE" sign-off. Nothing committed/pushed.
