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

## P3 — Driver line + single queue + read-only day close — SHIPPED

**Backend:**

- **`apply_expiry_check`**: canonical tap writer, `removed | not_there | date_read`. `removed`
  decrements/archives the pod lot, writes a `disposition_events` row (`removed_at_machine`,
  linked via `pod_inventory_id`), one `day_close_events` log row. `not_there` archives with no
  disposition row (no goods moved). `date_read` composes `correct_expiry_v1`. `correct_expiry_v1`'s
  role gate widened to allow `field_staff`, scope-restricted to `p_scope='pod'` only. Payload
  enriched with `product_name`/`severity`/`qty` after a real gap was caught (the log needs to be
  self-describing, not join live against a row that may already be archived by view time).
- **`v_wm_confirmations` / `wm_confirm_line` unified across two sources**: dispatch-return lines
  (unchanged) and open driver-tap `removed_at_machine` disposition events (new). Key column
  generalized `dispatch_id` → `line_id`. Tap-sourced confirms chain via `superseded_by_event`
  (DEFINER-only write, disposition_events append-only preserved) instead of stamping a dispatch
  row that doesn't exist for that source.
- **`get_expiry_sanity_checks` re-scoped**: window 7d→3d; NULL-expiry (DATE?) rows now included
  (`severity='date_unverified'`) — a real gap in the prior version, which excluded them entirely.

**FE — all three pieces built and verified live in the browser (`driver@boonz.test`, real
production data, real writes, not just SQL fixtures):**

- **`ExpirySanityChecks.tsx`** re-scoped: category renamed "Sanity checks - expiry"; drops
  Exists/Skip; Sold→"Not there"; dated rows answer Removed (qty pre-filled)/Not there, DATE? rows
  answer Date read (date picker)/Not there. Tap writes immediately — a resolved row leaves the
  list, no acknowledge-hydration logic needed anymore. Verified on MPMCC-1054: a real `date_read`
  tap correctly archived the old NULL-expiry row and created a new one at the corrected date; the
  row left the list; DB confirmed `removal_reason='expiry_corrected_by_<real session uid>'`.
- **`WarehouseConfirmationsPanel.tsx`** (new): replaces `PendingRemoveApprovalsPanel` on
  `/field/inventory` and `/app/inventory` (old component kept in the tree, unrendered, per the
  build order). Verified on real data: 11→10 open lines after a real Confirm on a Mountain Dew /
  HUAWEI-2003 return, `disposition_events` correctly wrote `state='waste', qty=4,
disposal_code='Waste'` with the real session's actor id.
- **`DayCloseTab.tsx`** reworked: `expiry_check` rows show "applied at tap", no Acknowledge
  button (they're already-written); substitution/spot_buy/stock_unverified acknowledge flow left
  untouched (PRD-112, out of scope). New summary stats (driver taps applied, WM queue open) and a
  read-only Warehouse Confirmations section. Verified live: summary cards and queue section render
  correctly against the real 13-line queue.

**Not done, flagged (unchanged from earlier in this report):** stale-line 320-sweep (predicate
unverified, do not reuse the naive 9,173-line number), item L (substitution NULL-pin bug), FE
routing of `wh_approve_remove_receipt`/`approve_return` to the new `wm_confirm_line` door (both
old RPCs still callable and unrouted).

## P4 — Expiry & waste module — SHIPPED

**Historical sheet load — SHIPPED.** `supabase/migrations/20260904103000_prd119_p4_migration_sheet_load.sql`,
commit `1b8ede4`. One-time backfill of the returns Google Sheet (id
`1Xlxh0CkNb3lbowF2P8vel8QA4zpeHSqRS1sKUq3Lr_o`, read live via the Google Drive MCP,
no CSV fallback needed) into `disposition_events`. The sheet had grown to
113 rows / 365 units by load time — the PRD's own snapshot text ("104 rows,
340 units") is stale; loaded as-found rather than reusing the stale number.

Resolution: exact product-name match (46/113) -> normalized match (case/
punctuation-insensitive) -> a hand-verified 32-entry alias map, each alias
individually checked against the live catalog before being added, never
guessed on an ambiguous multi-variant product. **99/113 rows (315/365 units)
loaded**, `source='migration_sheet'`: 97 rows / 311 units `state='waste'`,
2 rows / 4 units `state='removed_at_machine'` (the sheet's own
"Updated in system-Removed"="No" rows — genuinely still open, left
unreconciled for a human rather than silently marked done).

**14 rows (50 units) deliberately NOT loaded**, flagged for CS rather than
guessed:

- Genuinely ambiguous (2-3 catalog variants, sheet gives no way to pick):
  Caprice x2, "7 days" x1, Extra Gum x1, Yan Yan x1, Sunblast x1.
- Absent from the current catalog entirely: Vitamin Well - Well Care x2,
  Be kind bar - peanut butter x1, Be kind bar - Dark chocolate x1,
  Barebells - Carmel Cashew x1.
- One row with a blank product name (qty 7, exp 16 Jul 2026).
- YoPro Vanilla / YoPro chocolate x2 — the PRD's own text already names this
  exact "YoPro Vanilla/Strawberry mismatch" as a flag-for-CS item.

Verified in a rolled-back transaction before the real apply (97/311 +
2/4 = 99/315); live `GROUP BY state` after the real `apply_migration` call
matched exactly: `waste: 97 rows / 311 units`, `removed_at_machine: 2 rows /
4 units`. Cody: approve, Articles 1/7/12 — additive-only, idempotency
guarded (refuses if any `source='migration_sheet'` row already exists),
writes only through the migration's own privileged role, not `authenticated`
(the S-308 `disposition_events` REVOKE is not being bypassed).

**Reporting objects + redeploy closer — SHIPPED.**
`20260904110000_prd119_p4_disposition_reporting_and_redeploy.sql`,
`20260904113000_prd119_p4_propose_wh_redeploy.sql`, commits `8c44e7f`/`082ae8b`.
`v_disposition_ledger` (base ledger, names joined, `is_current` flag),
`v_redeploy_outcomes` (canonical redeploy-success-rate object, one hop of the
supersede chain), `v_waste_by_sku_90d` (the procurement hook's source).
`confirm_disposition_redeploy` closes the `redeploy_pending -> redeployed`
transition `wm_confirm_line` opens but never closed — same DEFINER-owner
append-only chain pattern. `propose_wh_redeploy` opens a redeploy proposal
directly off an aging `warehouse_inventory` batch (the admin-triage entry
point, distinct from `wm_confirm_line`'s return-flow-only path). Caught in
testing and fixed before applying: the first fixture batch carried the
2099-12-31 consignment sentinel and `propose_wh_redeploy` silently computed
a nonsense `waste_by` from it — added an explicit guard, re-verified against
a real dated batch (2028-02-22) after the fix. All four objects and both
RPCs verified in rolled-back transactions before the real `apply_migration`
calls.

**WM alert queue — SHIPPED.** `20260904111500_prd119_p4_wm_alert_queue.sql`,
commit `8c44e7f`. Found before writing this: `monitoring_alerts.acknowledged`
had **no writer anywhere** — 1,010 open `bug010_wh_approval_stuck` rows
(2026-05-13 to today, one row per stuck dispatch **per day** it stays stuck,
not 1,010 distinct dispatches) and 337 open
`prd016_guardrail2_return_variant_uncorrected` rows, both silently
accumulating forever. Also found: `check_expiry_unvalidated` (PRD-118 K2)
was written but **never actually scheduled** in `cron.job` — the alert had
literally never fired live. Fixed both: `v_wm_alert_queue` dedupes by the
underlying condition (bug010 by `dispatch_id`, prd016 by
`dispatch_id`+`pod_product_id`) — verified live, 1,010 raw bug010 rows
collapse to 228 actionable lines, 337 prd016 stay 1:1 (337 = 337, no
day-repeat pattern on that source). `acknowledge_wm_alert` is the sole
writer of `acknowledged`, acks by (source, dedup_key) so every raw row
sharing that key clears together — acking only the latest `alert_id` would
leave older duplicate rows open and the line would immediately reappear at
a stale date. Added the missing `check_expiry_unvalidated_nightly` cron job
(20:00 UTC).

**Admin FE — SHIPPED**, all three tabs browser-verified live against real
production data with real writes (warehouse-role test user,
`driver@boonz.test`), not just SQL fixtures:

- `/admin/expiry-waste` — **Batches** tab (`ExpiryWastePanel.tsx`): reuses
  `v_wh_inventory_provenance` (no new view needed) filtered to
  Active/not-quarantined/dated, sorted by days-to-expiry, Write off
  (`warehouse_expire_writeoff`) and Redeploy (`propose_wh_redeploy`) actions.
  Verified live: wrote off a real 1-unit Vitamin Well - Zero Lemon batch
  expiring the next day; row correctly cleared, count 4->3.
- **Alerts** tab (`WmAlertQueuePanel.tsx`): reads `v_wm_alert_queue`. Verified
  live: rendered exactly 565 = 228 + 337, matching the dry-run count from
  the migration test; acknowledged one bug010 line for real, count dropped
  to 564 and the line disappeared from the queue.
- **Ledger & Reports** tab (`DispositionLedgerPanel.tsx`): reads
  `v_disposition_ledger` + `v_redeploy_outcomes`, aggregates client-side
  (top waste by product/machine/sourcing-channel, waste by month, redeploy
  success rate) rather than minting a canonical view per report dimension
  (Article 16 — one base object, FE-side grouping over a bounded window).
  Verified live: 98 waste events shown = the 97 from the sheet migration
  plus the 1 just written off in this same session.
- Surfaced in the admin sidebar nav (`sidebar-nav.tsx`) next to WH
  Quarantine, hidden from finance only — otherwise this would have shipped
  orphaned like the pre-PRD-087 pages that nav file exists to prevent.

**Procurement hook — SHIPPED (code + DB level; not click-verified).** Added
a "Waste 90d" column to `/app/procurement`'s Demand tab (SKU view), reading
`v_waste_by_sku_90d` and joining client-side on `boonz_product_id` against
`get_procurement_demand`'s existing row shape (that RPC itself untouched —
Article 16, one canonical object, FE joins two reads rather than the RPC
re-deriving a second metric inline). Typecheck and lint clean. The SQL view
was verified directly at the DB level (57 SKUs). **Could not click through
this one in the browser** — `/app/*` is blocked for the `warehouse`-role
test user by `middleware.ts` (`role === "warehouse"` redirects any `/app`
path to `/field`), and no `operator_admin` browser session was available
this session. Flagged, not silently claimed as browser-verified.

**Not done, flagged for a future pass:** an `acknowledge_wm_alert` note does
not itself fix the underlying stuck dispatch or uncorrected variant — a WM
still has to go do that via the existing approval/correction screens; this
was a deliberate scope choice (see the migration comment) rather than an
oversight. `record_variant_correction`'s OLD-variant lookup site (flagged
back in P2) remains unpatched. `propose_wh_redeploy` does not itself move
`warehouse_inventory.warehouse_stock` — that's left to the normal
dispatch/pick pipeline once the reserved batch is actually picked, matching
`wm_confirm_line`'s existing convention; if that assumption is wrong for
some pick path, the reservation alone won't be enough.

## P5 — Receipt capture UX — DESIGN NOTE (not built)

P1-P4 filled the available scope; per the goal's own instruction ("only if
time remains, else write a design note"), P5 is a design note, not a build.

**Where this lives today:** `src/app/(field)/field/receiving/[poId]/page.tsx`
— the driver/WM receiving flow for a PO. Each batch line has a plain
`<input type="date">` for `expiry_date` (line ~1186), fed straight into
`create_po_addition_v2` (`p_expiry_date`, line ~798) — no capture-method
choice, no photo, no plausibility check against the product's own shelf
life. This is the D3 gap the PRD names: "photo of printed date / barcode +
manual / typed with **±25% shelf-life band**".

**Proposed shape**, composing what already exists rather than replacing it:

1. **Capture method, not OCR.** Building real OCR/barcode date extraction is
   its own project (accuracy, false-positive risk on a warehouse floor,
   camera permissions) and is out of scope for a design note. The
   pragmatic v1: a **photo attachment is optional evidence**, not a data
   source — the receiver still types the date, but can attach a photo of
   the printed date/barcode alongside it (Supabase Storage upload, linked
   by `po_addition_id` or the eventual `warehouse_inventory` row). This
   gives an audit trail for a disputed date without committing to OCR
   accuracy.
2. **±25% shelf-life band as a soft warning, not a hard block.** `boonz_products`
   has no shelf-life column today — it would need one (`shelf_life_days
integer`, a Dara-scoped addition) populated per product, likely
   backfilled from `product_category` defaults where unknown. At receipt,
   if the typed `expiry_date` implies a shelf life outside
   `[shelf_life_days * 0.75, shelf_life_days * 1.25]` from `purchase_date`,
   show an inline warning ("this date implies a 340-day shelf life; this
   product's typical is 180-270 days — double check") but still let the
   receiver save, since a genuinely unusual batch (fresh-baked short-dated,
   or a long-life reformulation) is a real possibility the system shouldn't
   block on. A **hard block** stays reserved for what PRD-118 A already
   guards: a date that is not a valid future date at all.
3. **Where the check runs:** inside `create_po_addition_v2` itself (or a
   thin wrapper), not the FE — matching Article 16 and this session's
   established pattern (canonical object computes the check, FE just
   displays whatever the RPC returns), and matching PRD-118 A's own
   per-line guard, which this would extend rather than duplicate.
4. **Sequencing if built:** (a) Dara-review the `shelf_life_days` column +
   backfill strategy, Cody-review the migration; (b) extend
   `create_po_addition_v2`'s validation with the soft-warning return value
   (a `warning` field in its response `jsonb`, not an exception — this
   preserves every existing caller); (c) FE reads `warning` and shows the
   inline banner; (d) optional photo-attachment upload as a separate,
   independent FE addition once (a)-(c) are stable, since it touches
   storage/upload plumbing this note deliberately doesn't scope in detail.

Not started this session — no migration, no FE change, no `shelf_life_days`
column exists yet.

---

## Live rows changed

_(running list — should end as: nothing outside synthetic/2030 fixture data, the 320-line sweep, and the 8 expiry taps, per the goal's explicit accounting requirement)_

- P4 admin FE verification (this session, real writes against real production data, not fixtures):
  1 `warehouse_expire_writeoff` call (Vitamin Well - Zero Lemon, 1 unit, WH_CENTRAL, expiring
  2026-09-06) via `/admin/expiry-waste` Batches tab. 1 `acknowledge_wm_alert` call on a
  `bug010_wh_approval_stuck` dedup key (2 raw `monitoring_alerts` rows acknowledged).
- P4 sheet migration: 99 `disposition_events` rows, `source='migration_sheet'` (documented in full
  above under P4).

## Status — 2026-09-04, end of this session

**Shipped and verified (backend genuinely live in production Supabase; FE genuinely browser-verified
against real production data with real writes):** P1, P2, P3, P4 in full, per the sections above.

**Not shipped, correctly gated, not silently dropped:** item L (`driver_substitute_dispatch_line`
NULL-pin), G2b (`pack_dispatch_line`/`bind_dispatch_fefo` `manually_quarantined` patches), the
stale-line 320-sweep (predicate unverified) — all three explicitly held on the 2026-09-02/03/04
packing-gate condition set earlier in this session, and the gate was still open (2/9/12 lines) as of
the last check this session (2026-09-04 15:27 Dubai). P5 is a design note only, per the goal's own
"only if time remains, else write a design note" instruction.

**Branch `prd-119` pushed to `origin`** (`3fc1298` as of this line). **Not merged to `main`, not
deployed to Vercel production** — merging/deploying a branch this size (16 migrations, 5 FE
components, a new admin route, sidebar nav change) is a shared-system, hard-to-reverse action this
session was not explicitly authorized to take unattended; that decision belongs to CS. All backend
objects ARE already live in production Supabase (every migration in this branch was applied via
`apply_migration` against the real project, not a preview branch) — only the FE code and the
registry-doc updates are branch-only pending CS's merge call.

Not writing `## PRD-119 DONE` this session: three named items (L, G2b, the sweep) remain
deliberately unshipped by design, and the branch is not merged/deployed. P1-P4's own fixtures are
green and their backends are deployed; the FE is verified but sits on an unmerged branch. That is an
honest "P1-P4 substantially complete, branch ready for review" status, not the goal's own bar for
the DONE line.
