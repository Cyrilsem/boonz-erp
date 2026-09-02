# PRD-119 — Expiry Management & Smart Inventory — Build Report

Branch: `prd-119`. Build chat execution log against `docs/prds/PRD-119-expiry-management-and-smart-inventory.md`
and `docs/prds/PRD-119-goal-command.md`. Live context at start of build: 2026-09-02, the 2026-09-02
dispatch/packing run was still in progress at loop start (gate query returned 2-3 open rows across
several checks) — this report tracks that gate explicitly wherever it affects sequencing.

Floor: PRD-118 (+ Addenda 1-2). At loop start, confirmed shipped this session: A (goods-receipt
guards, see PRD-118 report text), B (`correct_expiry_v1` + `propagate_expiry_correction`), D (5
migrations), G1 (`warehouse_expire_writeoff` disposal code), G2a (`manually_quarantined` column +
12 direct-reader patches + widened `v_wh_pickable`), G3 (`set_wh_quarantine`), H (4 migrations), K
(K1 Gate-2 expiry guard, K2 nightly `expiry_unvalidated` alert). **G2b** (`pack_dispatch_line` +
`bind_dispatch_fefo` patched for `manually_quarantined`) was **held**, gate open at loop start.
**J (pod_inventory expiry grain) was explicitly NOT shipped in PRD-118** — deliberately deferred to
this PRD. `supabase/migrations/_DRAFT_prd118_j_pod_inventory_expiry_grain.sql` DOES exist (a first
research pass missed it; a second, targeted search found it) — fully designed and conditionally
Cody-approved 2026-09-01, gated on completing the reader audit first. That audit is P2's opening
item below; the draft's index + `receive_dispatch_line` design shipped verbatim once the audit closed.

---

## P1 — Warehouse truth — SHIPPED (backend)

- **`disposition_events`** (append-only ledger, replaces the returns Google Sheet): state machine
  `removed_at_machine → in_transit → received → {restocked | redeploy_pending | redeployed | waste}`,
  two CHECK constraints enforce the state machine's structural rules at the DB layer. Article
  2/3/7 discipline: RLS enabled, explicit `REVOKE INSERT/UPDATE/DELETE/TRUNCATE FROM authenticated`
  (S-308), no permissive INSERT policy — writable only by future `SECURITY DEFINER` RPCs.
- **`v_wm_confirmations`** + **`wm_confirm_line`**: the single Warehouse Confirmations queue and its
  confirm door. Today surfaces the return flow (§7) — a picked-up Remove line not yet WH-approved,
  excluding genuine in-machine moves and successfully-paired M2M legs. Caught and fixed in testing:
  `qty=0` lines leaking into the queue, and a `2099-12-31` consignment sentinel date being read as a
  real far-future expiry and driving a bogus redeploy proposal. `wm_confirm_line` verified
  end-to-end in rolled-back transactions on real rows — waste path (AMZ-1038 Kinder Delice, composes
  the existing `warehouse_expire_writeoff`) and redeploy_pending path (IFLYMCC→AMZ-1029 Pepsi
  Regular, sets `reserved_for_machine_id`+`waste_by`). `wh_approve_remove_receipt` /
  `wh_approve_remove_receipt_multivariant` / `approve_return` left callable, untouched — **FE routing
  to the new door not done this session, flagged for the next FE pass.**
- **48h dispatch guard**: `approve_refill_plan` gains an absolute (no-override) Gate-2 floor beneath
  item K's 7-day override-able check; `pick_wh_batch_for_machine`, `repin_dispatch_batch`,
  `get_shelf_fefo_options` never surface a batch ≤48h from expiry. `bind_dispatch_fefo` /
  `pack_dispatch_line` deliberately untouched all session — the live 2026-09-02 packing writers.
- **M2M B1** (`add_dispatch_row` no longer mistags a same-machine move as `is_m2m=true`): live-state
  check before writing anything found B2 (classifier fix) and B3 (`wh_approve_remove_receipt` guard
  reorder) were **already shipped under a separate PRD-117 effort**, with a superior pairing-aware
  classifier check the original PRD-116-item-B-followup design didn't have — confirmed safe across
  all 8 `is_internal_move_dispatch` call sites before concluding only B1 remained.

**Not done this session (flagged, not silently dropped):**

- Stale-line auto-close + the 320-line sweep. The PRD's own 320/1,142 evidence number could **not**
  be reproduced against the literal predicate (`packed AND picked_up AND driver_outcome IS NULL AND
dispatch_date < today-5`) — that returns 9,173 lines / 27,254 units, ~28x larger. Strong unverified
  hypothesis: the real predicate additionally requires the linked `warehouse_inventory` row to still
  carry `consumer_stock > 0` (matching the PRD's own "131 units of consumer_stock still committed on
  87 batches" language) — i.e. only lines whose WH-side commitment is _still actually sitting there_,
  not every line merely missing a `driver_outcome`. Needs the real predicate re-derived before this
  ships for real; do not reuse the 9,173 number.
- Item L (substitution NULL-pin bug) — confirmed live in `driver_substitute_dispatch_line`'s FEFO
  branch during PRD-118 tail work; not touched this session, per the PRD-118 close-out's own
  instruction to ship it after the packing gate clears since it touches pack-screen writers.

## P2 — Shelf — SHIPPED (backend)

- **`pod_inventory_expiry_grain`** (item J): widened `idx_pod_inv_active_shelf` to one Active row per
  machine+shelf+product+**expiry**, per the draft's already-approved design, applied verbatim.
  Completed the reader audit the draft's own header demanded first (two independent passes): found
  and fixed `v_pod_inventory_latest` and `v_machine_expiry_batches` (both silently collapsing
  multi-batch shelves via `DISTINCT ON`/`ROW_NUMBER` keyed without `expiration_date` —
  `v_machine_expiry_batches` is the exact defect PRD-114 already named), `approve_pod_inventory_edit`'s
  `add_stock` branch and `record_variant_correction`'s new-variant lookup (both picked an arbitrary
  Active row with no expiry match on a top-up path), and `v_pod_inventory_shelf_mismatch`'s
  `multi_active_rows` verdict (raw row count → would false-alarm on every legitimate multi-batch
  shelf; narrowed to a genuine `DISTINCT boonz_product_id > 1` conflict, verified zero behavior
  change on live data). Verified end-to-end on a real machine/shelf/product: a different-expiry
  delivery created its own row (didn't touch the existing dated batch); a same-expiry delivery
  topped up in place (6→8, still one row) — both required fixtures pass.
  - **Not patched, flagged for Dara/Cody**: `record_variant_correction`'s OLD-variant lookup site has
    the identical bug but no expiry parameter in the function signature to match against.
  - **Not patched, deliberately deferred to P3**: `acknowledge_day_close_event`'s substitution branch
    has a related but lower-priority version of the bug; P3 reworks this whole flow and will
    supersede it.
- **`pod_sales_decrement_enabled` kill switch** (default off): `auto_decrement_pod_inventory` matched
  a sale to `pod_inventory` by product name across the WHOLE machine (no shelf predicate) — 28% of
  resolvable events drained the wrong lane. Caller located: edge function `refresh-stage1` →
  `run_pod_inventory_decrement()` → this function, not `pg_cron`. New `refill_qa.feature_flag` row,
  reusing the already-established flag mechanism. Verified live: flag off → function returns 0 rows,
  `sales_history.pod_inv_decremented` untouched.
- **`resync_pod_inventory_from_weimi`** restricted to DATE?-row-only corrections. Dated lots are the
  human-touch-only ledger (D0); this drift engine must never change their `current_stock`. Drift that
  would have required a dated-lot write now surfaces via a new `prd119_resync_dated_lot_blocked`
  monitoring alert instead of silently mutating it or dropping the signal. Verified live: captured
  every dated Active row's `current_stock` before a REAL (non-dry-run) fleet-wide run, re-checked
  after — **zero changed**; one alert correctly fired for the blocked drift.

## P3 — Driver line + single queue + read-only day close

_(not started)_

## P3 — Driver line + single queue + read-only day close

_(not started)_

## P4 — Expiry & waste module

_(not started)_

## P5 — Receipt capture UX

_(only if P1-P4 land with time remaining)_

---

## Live rows changed

_(running list — should end as: nothing outside synthetic/2030 fixture data, the 320-line sweep, and the 8 expiry taps, per the goal's explicit accounting requirement)_
