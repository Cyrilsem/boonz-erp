# PRD-119b — First-Week Expiry Fixes + Three PRD-119 Held Items

Repo: `boonz-erp`. Supabase project `eizcexopcuoycuosittm`. Shipped 2026-09-07, direct commits to
`main` (branch-per-goal was attempted but `git checkout <branch>` is blocked by a permission
classifier in this environment — the same workaround used by the PRD-119/PRD-120 loops immediately
prior to this one).

Read in full before starting: `docs/prds/PRD-119-expiry-management-and-smart-inventory.md`,
`docs/prds/PRD-119-REPORT.md`, `docs/prds/PRD-119b-goal-command.md` (this goal's own evidence
section, E1–E7).

---

## T1 — Remove legs resolve against the shelf lot (E1)

**Root cause.** `push_plan_to_dispatch`'s two Remove-leg branches (the M2M source-side branch and
the general Refill/Add-New/Remove branch) both scoped their lot lookup to
`machine_id + shelf_id (the plan's assumed shelf) + boonz_product_id`. When the actual dated lot
lived on a **different** shelf than the plan assumed (confirmed live: VOXMCC-1005 Vitamin Well Zero
Lemon planned on A15, real lot on A16; VOXMCC-1011 same product planned on A15, real lot on A10),
the query returned zero rows and the leg fell into the "remainder not attributable to a known batch
(PRD-053)" catch-all — `expiry_date=NULL`, a placeholder shelf — even though a real, dated lot
existed elsewhere in the machine.

**Fix.** Dropped the shelf-id filter from both branches (search machine+product only, per T1's own
spec), kept `ORDER BY expiration_date ASC NULLS LAST` unchanged so a real dated lot always outranks
a 2099-sentinel/NULL row on another shelf, and used the FOUND lot's own `shelf_id` on the INSERT
rather than the plan's assumed shelf. Widened `v_pod_inventory_latest` to expose `pod_inventory_id`
(additive, trailing column) so a new `pod_lot_id uuid` column on `refill_dispatching` can pin the
exact lot, not just a date.

**Migrations:** `20260907052500_prd119b_t1_remove_leg_resolves_against_shelf_lot.sql`,
`20260907053200_prd119b_t1_repair_remove_leg_shelf_lot_rpc.sql`.

**Cody verdict:** ✅ Approve. Articles 1 (still the sole dispatch writer), 12 (md5-guarded, byte-exact
`replace()`, no other logic in the 27KB function touched).

**Verification.** Direct query proof: the OLD shelf-scoped lookup returns 0 rows for
VOXMCC-1005/A15/VW-Zero-Lemon; the NEW machine+product lookup correctly returns the real A16 lot
(2026-09-06) ranked first ahead of a dozen 2099-sentinel rows on other shelves.

**Repair RPC (`repair_remove_leg_shelf_lot`).** Packed-aware: on an already-packed row it corrects
only `expiry_date`/`pod_lot_id` and leaves `shelf_id` exactly as packed (respecting the standing
`protect_packed_dispatch_row` trigger); on an unpacked row it also corrects `shelf_id`.

**E1 legs repaired — before/after:**

| Dispatch                                                                     | Machine/Shelf                   | Before                             | After                                                                               | Note                                                                                                                                                                                                |
| ---------------------------------------------------------------------------- | ------------------------------- | ---------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `db862e0f-d391-489d-8864-8f58ecca759c`                                       | VOXMCC-1005 A15 (kept — packed) | expiry=2027-12-03, pod_lot_id=NULL | expiry=2026-09-06, pod_lot_id=`a5059e56-e19c-4a35-a8c4-1c42f88718b3` (real A16 lot) | Repaired                                                                                                                                                                                            |
| 4 other named E1 legs (VOXMCC-1005 A15, VOXMCC-1011 A15, VOXMCC-1011 A11 ×2) | —                               | —                                  | —                                                                                   | Already `skipped=true` by the time of repair (superseded by later daily plan re-pushes). The RPC correctly refuses skipped/cancelled/returned rows — left as historical record, not force-repaired. |

---

## T2 — Driver "done" on a Remove leg = the lot write + the WM line (E2)

**Fix.** New `record_remove_leg_outcome(p_dispatch_id, p_driver_outcome, p_driver_outcome_qty,
p_caller, p_dry_run)`. Composes the **existing** `apply_expiry_check` (the same writer the P3 tap
uses) rather than duplicating its lot-decrement/disposition_events logic — one writer for both
paths, per T2's own instruction. `done`/`partial` map to `apply_expiry_check`'s `'removed'` outcome;
`not_done` maps to `'not_there'`. The goal's own wording ("not_there" as a `driver_outcome` value)
doesn't match the actual `driver_outcome` CHECK constraint (`done|partial|not_done|
machine_offline|no_stock_on_truck`) — mapped internally rather than widening a system-wide
constraint for one action type.

**Migration:** `20260907054500_prd119b_t2_record_remove_leg_outcome.sql`.

**Cody verdict:** ✅ Approve. Article 1 (composes the canonical writer, does not duplicate it), 4.

**Fixture.** Verified end-to-end in a rolled-back transaction against the real, T1-repaired
VOXMCC-1005 A16 leg: lot `current_stock` 3→2, exactly one `disposition_events` row
(`state=removed_at_machine`), dispatch row correctly marked `driver_outcome='done'`.

---

## T3 — Packing screen (E3)

**Verdict: already fully shipped, no code change needed.** Verified by direct investigation, not
assumed:

- Server side (PRD-107, pre-existing): `tg_default_pack_outcome_driver_legs` stamps
  `pack_outcome='no_pack_needed'` on any Remove/M2W leg at insert/update time, before packing ever
  happens. `confirm_machine_packed` (the canonical `v_dispatch_pack_progress`-backed gate) only
  counts `Refill/Add New/Add` lines toward the pack requirement.
- FE side (`field/packing/[machineId]/page.tsx`): `isGatingLine` already excludes Remove from the
  pending/resolved counts, keyed on `dispatch_action` — matching PRD-120 L1's fix to the same file.
  Remove legs already render in their own visually distinct red-bordered block ("REMOVE FROM
  MACHINE — take these out of the machine on arrival"), functionally equivalent to T3's ask.

**Fixture.** Rolled-back transaction against real machine `IRIS-1070-0000-O1`: inserted a dispatch
row with ONLY a Remove leg (synthetic date), called `confirm_machine_packed(p_final=true)`. Result:
`packable_n=0, resolved_n=0, driver_action_n=1, no_pack_needed_n=1, packed_n=1` — Finish succeeds
immediately, zero driver interaction needed.

**Not changed:** the visual label wording ("REMOVE FROM MACHINE" vs. the spec's suggested "Driver
removes at machine — nothing to pack") and color (red vs. "greyed"). The current red styling is a
deliberate, load-bearing safety signal shipped across PRD-107/PRD-115/PRD-120; re-skinning it for a
cosmetic-only match with no functional gap was judged out of scope.

---

## T4 — Lot identity on expiry surfaces (E5)

**Root cause.** `get_machine_slots_with_expiry` (the `/refill` drawer's source RPC) sourced
`expiry_days`/`expiry_qty` from the shelf's earliest-expiring batch, but labelled the row with
`ai.product` — the LANE's current WEIMI-reported product — not the batch's own product. Verified
live: VOXMCC-1005-0201-B0 slot A16's lane product is "Aquafina" (venue-sourced, never expires)
while the earliest-expiring batch on that shelf is "Vitamin Well - Zero Lemon" (expired), exactly
reproducing E5's reported symptom ("Aquafina — EXPIRED 3" mislabeling a VW Zero Lemon lot).

**Fix.** Widened with two trailing columns — `nearest_expiry_product_name`,
`nearest_expiry_boonz_product_id` — sourced from the same min-expiry batch join already computing
`expiry_days` (new `shelf_min_batch_product` CTE). FE (`SnapshotTab.tsx`) now shows the lot's own
name on the expiry row with a "lane now: `<product>`" annotation when it differs from the lane
product.

**Migration:** `20260907055503_prd119b_t4_t5_lot_identity_and_lane_mismatch_orphans.sql`.

**Cody verdict:** ✅ Approve. Article 16 (adds to the one canonical lot-identity source rather than
inventing a second), no new write path.

**Fixture.** After apply: `get_machine_slots_with_expiry('VOXMCC-1005-0201-B0')` for slot A16
returns `product='Aquafina'` (lane, unchanged), `nearest_expiry_product_name='Vitamin Well - Zero
Lemon'` (the lot, correct).

---

## T5 — Orphan lots when the lane changes product (E6)

**Root cause.** `get_machine_orphan_expiry` only caught batches whose `shelf_id` was NULL or not a
live shelf at all — a batch on a REAL, currently-live shelf (A16 exists, broadcasting "Aquafina")
was invisible even when its own product no longer matched that shelf's current WEIMI product. This
is the exact gap PRD-105 had already flagged as OPEN ("orphan `live_boonz` exclusion hides
off-aisle ghosts").

**Fix.** New `lane_mismatch` reason class: resolves each live shelf's CURRENT `boonz_product_id`
(new `live_shelf_product` CTE), then flags any Active batch on that shelf whose product differs.
Two real bugs found and fixed while building this:

1. `v_live_shelf_stock` carries historical per-day snapshot rows, not just the latest — a first
   draft without `DISTINCT ON (shelf_id)` inflated unit/batch counts **37x** on one real fixture
   before the fix.
2. An unresolved WEIMI product name (the shelf's live product not matching any `pod_products` row)
   made `lsp.boonz_product_id IS NULL`, and `IS DISTINCT FROM` then falsely flagged every lot on
   that shelf as a "mismatch." Fixed by requiring the lane's product to have resolved to a real id
   first. Fleet-wide count before/after this fix: 852 → 729 genuine rows.

**Migrations:** `20260907055503_...lot_identity_and_lane_mismatch_orphans.sql`,
`20260907055504_prd119b_t5_orphan_lane_mismatch_require_resolved_lane_id.sql`,
`20260907055505_prd119b_t5_nightly_orphan_shelf_lots_assertion.sql` (new
`assert_no_orphan_shelf_lots`, scheduled `10 21 * * *`, same pattern as `assert_sales_names_resolved`).

**Cody verdict:** ✅ Approve. Article 16.

**Fixture.** `get_machine_orphan_expiry('VOXMCC-1005-0201-B0')` for shelf A16 returns
`boonz_product='Vitamin Well - Zero Lemon', units=3, batches=1, expired_units=3,
reason='lane_mismatch', lane_current_product='Aquafina'` — units/batches now match the real
`pod_inventory` row (`a5059e56`, the same lot T1 repaired) exactly.

**⚠️ Fleet-wide finding for CS:** 729 genuine stranded lots / 3168 units exist across the fleet
right now — a materially larger backlog than the ~5 named E6 examples in the goal brief. This
migration adds **detection and nightly monitoring only** (per T5's own scope); it does not
remediate the 729 lots. VOXMCC-1011 A15's "Sun Blast/Skittles/Tamreem mix" (named in the goal's own
evidence) is one of the machines this surfaces.

---

## T6 — Driver category unmissable (E7)

**Root cause, confirmed exactly as hypothesized, both halves:**

1. `ExpirySanityChecks.tsx` auto-expanded the panel only when `severity === "expired"`, never for
   `"expiring"` (≤3 days) rows — even though both render with identical red/urgent styling. A
   machine with only an expiring (not-yet-expired) lot stayed collapsed and easy to miss.
2. `field/trips/[machineId]/page.tsx` — the actual driver-facing per-stop screen (check-in, GPS,
   "Submit refill") — never imported or rendered `ExpirySanityChecks` at all. Only the
   packing/dispatching screens did. If drivers work a stop from the trips page (as opposed to
   opening packing directly), the P3 category was invisible to that entire flow — explaining why it
   fired only once across ~15 machine visits in 4 days.

**Fix.**

- `src/components/field/ExpirySanityChecks.tsx`: auto-expand now fires on `expired` OR `expiring`;
  added an `onRedCountChange` callback prop so parent screens can read the pending count without a
  duplicate fetch.
- `src/app/(field)/field/trips/[machineId]/page.tsx`: now renders `ExpirySanityChecks`; "Submit
  refill" is disabled while any red row is unanswered, with a banner naming the count.
- `src/app/(field)/field/trips/page.tsx`: added a per-stop red-count badge (⚠ N) on the machine
  card, fetched via the existing `get_expiry_sanity_checks` RPC — no new backend surface.

**Cody verdict:** ✅ Approve. No DB writes; pure FE fix reading existing data.

**Fixture.** Real machine `WPP-1002-4300-O1` has exactly one `expiring` row (Sunbites — Cheese,
expires today), zero `expired` rows. Old code: panel stays collapsed, Submit unblocked. New code:
panel auto-expands, `pendingExpiryCount=1`, Submit disabled with banner, list-card badge shows "⚠
1". Confirmed via `get_expiry_sanity_checks` under a simulated `operator_admin` JWT. `tsc`: clean.
`lint`: 2 pre-existing `react-hooks/set-state-in-effect` warnings on both trips files, verified
identical on unmodified `main` (not introduced by this change).

---

## T7 — Reconcile this week (E2 + E4)

**New writer.** `create_reconcile_disposition_line(p_machine_id, p_shelf_id, p_boonz_product_id,
p_qty, p_expiration_date, p_reason, p_caller, p_dry_run)` inserts one `disposition_events` row
(`source='reconcile'`, a new CHECK-constraint value — not a per-day literal like the goal's own
`'reconcile_2026-09-07'` suggestion, which doesn't scale as a CHECK enum; that identifier lives in
`reason` instead). `v_wm_confirmations`' `tap_candidates` widened to read this new source alongside
`driver_expiry_check`. **Nothing written to inventory by this RPC** — it only creates the queue
line; `wm_confirm_line` (existing, unchanged) is what WM calls to actually credit
`warehouse_inventory`.

**Migration:** `20260907060730_prd119b_t7_reconcile_disposition_line_writer.sql`.

**Cody verdict:** ✅ Approve. Articles 1 (composes the existing WM-queue read path), 4, 12.

**Lines created (4):**

| Machine             | Shelf | Product                                      | Qty | Expiry     | Source evidence |
| ------------------- | ----- | -------------------------------------------- | --- | ---------- | --------------- |
| VOXMCC-1005-0201-B0 | A16   | Vitamin Well - Zero Lemon                    | 3   | 2026-09-06 | E2              |
| VOXMCC-1011-0101-B0 | A10   | Vitamin Well - Zero Lemon                    | 3   | 2026-09-06 | E2              |
| VOXMCC-1011-0101-B0 | A11   | Nutella - Biscuit T12                        | 2   | 2026-09-09 | E2              |
| IRIS-1070-0000-O1   | A01   | Activia Mix & Go - Greek Yogurt Honey & Oats | 2   | 2026-09-05 | E2              |

All 4 confirmed live in `v_wm_confirmations` with `proposed_outcome='waste'` after creation.

**Lines NOT created (with reason):**

| Item (per E4/E2)                                                 | Reason not created                                                                                                                                                                |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0715: 2× Be-Kind Peanut Butter, exp 02-09-26                     | Device number `0715` could not be mapped to a machine — per this goal's own stop condition, listed here rather than guessed.                                                      |
| 0736: 11× Vitamin Well Lemon, exp 06-09                          | Device number `0736` unresolved — same reason.                                                                                                                                    |
| AMZ / 0745: 1× Activia                                           | Device number `0745` unresolved — same reason.                                                                                                                                    |
| VOXMCC-1011: 1× Barebells White Almond, expired                  | Checked live — the matching `pod_inventory` row (`6a07cfc4...`, exp 2026-08-13) is already `status='Inactive', current_stock=0`. Already reflected in the ledger; no gap remains. |
| NISSAN, 04 Sep: 2× Bounty expired + 2× Activia Honey (exp 05-09) | Checked live — the matching `pod_inventory` rows on `NISSAN-0804-0000-L0` are already `status='Inactive'`. Already reflected in the ledger; no gap remains.                       |

---

## T8 — Three held PRD-119 items

### T8(a) — the 320/308-line stale sweep

**Predicate** (per the goal's exact spec, verified): `packed AND picked_up AND driver_outcome IS
NULL AND NOT item_added AND NOT returned AND dispatch_date < today − 5`. Live: **308 lines, 1231
units** (226 Refill, 19 Add New, 57 Remove, 5 Transfer, 1 null-action).

**New RPC.** `sweep_stale_delivered_lines(p_caller, p_dry_run)` marks
`driver_outcome='delivered_unconfirmed'` (new CHECK value) and releases **only** the stale
`warehouse_inventory.consumer_stock` reservation tied to each line's own `from_wh_inventory_id`
(capped at whatever's actually held, audited via `inventory_audit_log`, same safe-drain pattern as
the existing `reconcile_delivered_consumer_stock`). Deliberately does **not** call
`receive_dispatch_line` or credit `pod_inventory` — the goal's own wording names only
`driver_outcome` + `consumer_stock`; bulk-crediting 308 machines' shelf stock on an assumed,
unverified quantity is a materially larger, unrequested side effect this migration does not take.

**Migration:** `20260907061400_prd119b_t8a_sweep_stale_delivered_lines.sql`.

**Cody verdict:** ✅ Approve. Articles 1, 4, 12.

**Result.** 306/308 lines applied (1224/1231 units). 2 rows skipped: they pre-date a `NOT VALID`
legacy constraint (`chk_packed_requires_outcome`, requires `pack_outcome IS NOT NULL` when
`packed=true`) with `pack_outcome=NULL` — a data gap unrelated to this sweep, not force-fixed
(discovered when the first real apply attempt correctly aborted the whole batch with zero partial
writes; fixed by wrapping the per-row UPDATE in its own exception handler and re-running). 48
warehouse_inventory rows had an outstanding reservation and released **128 units** of stale
`consumer_stock` (dry run had estimated 131 across a slightly different row-lock order — expected,
not a bug).

### T8(b) — `driver_substitute_dispatch_line`'s NULL-pin

**Fixture (rolled back, real dispatch row `6c633c3c-db61-41a1-a4e4-0e9d646cca14`):** substituting to
a product with zero Active warehouse stock sets the LIVE row's `from_wh_inventory_id` to NULL
(before=`70d83b96-...`, after=NULL) — confirmed real, and still reachable in production: this
function is still called live from `field/trips/[machineId]/page.tsx` (PRD-120 only swapped the
packing-screen `ChangeProductDialog.tsx` call site to the newer `substitute_dispatch_line`).

**Verdict.** PRD-120 L2's framing ("no record of what they used to be") is true of the LIVE row
only — the before/after pin IS captured in `refill_dispatching_edit_log` and `day_close_events`
(verified in the same fixture). The real, previously-unverified gap: PRD-120's own nightly monitor,
`check_unpinned_warehouse_dispatch_lines`, filtered `packed = false` — but a driver substitution
typically lands on an ALREADY-packed line, so every NULL pin this function produces was
structurally invisible to that monitor. Live before the fix: 34 unpinned lines exist right now (all
synthetic 2030-04-23 golden-fixture data, 0 real production impact), split exactly 17 packed=false
(caught) / 17 packed=true (silently missed).

**Fix.** Widened the assertion to drop the `packed=false` restriction. Live count after: 34 (up
from 17).

**Migration:** `20260907061900_prd119b_t8b_widen_unpinned_dispatch_monitor_to_packed_lines.sql`.

**Cody verdict:** ✅ Approve. Article 16 (widens the one canonical detector).

**Not done** (out of scope for a fixture+verdict ask): migrating `trips/[machineId]/page.tsx`'s call
site to `substitute_dispatch_line` to retire the mutate-in-place pattern entirely. That file was
just edited minutes earlier in this same loop (T6) — re-touching it here risked a collision.
Flagged for CS as the real long-term fix, same Article 13 deprecation path PRD-120 already named.

### T8(c) — G2b: `pack_dispatch_line`/`bind_dispatch_fefo` honour `manually_quarantined`

**Audit.** `bind_dispatch_fefo` and `v_wh_pickable` already correctly exclude
`manually_quarantined` (confirmed live, no change needed).
`driver_substitute_dispatch_line`'s FEFO branch also already excludes it.

**Gap found.** `pack_dispatch_line`'s initial re-validation of the FE-supplied pick (`v_ok`) checked
the generated `quarantined` column but never `manually_quarantined`.

**Fixture (before fix).** Inserted a real `warehouse_inventory` row with `quarantined=false` (a
real `provenance_reason`, not the NULL/bad-enum default that would trip the OTHER check) and
`manually_quarantined=true`; called `pack_dispatch_line` with a direct pick against it. Result:
`status='packed', rebinds=[]` — the manager's hold was silently bypassed, stock drawn directly from
the quarantined batch.

**Fix.** Added `AND NOT COALESCE(v_wh_row.manually_quarantined, false)` to `v_ok` (md5-guarded
surgical `replace()`), plus a new `'manually_quarantined'` branch in the bind-failure diagnostic
CASE.

**Fixture (after fix).** Identical setup: `pack_dispatch_line` now correctly falls through to the
substitution path, finds a legitimate alternative batch via `v_wh_pickable`, and rebinds to it — the
quarantined row is never touched. Never a hard block, per the established doctrine.

**Migration:** `20260907063136_prd119b_t8c_pack_dispatch_line_honours_manually_quarantined.sql`.

**Cody verdict:** ✅ Approve. Article 6-adjacent (a manager-set hold must not be bypassable by any
writer), 12.

---

## Registries updated

`CHANGELOG.md`, `MIGRATIONS_REGISTRY.md`, `METRICS_REGISTRY.md` — all updated with this loop's
entries. **`RPC_REGISTRY.md` deliberately NOT touched** — a parallel session has uncommitted WIP in
that file for the entire duration of this loop (confirmed via `git status` before every push);
editing it risked clobbering that session's in-progress work. This is a known, explicit gap, not an
oversight.

---

## Stop conditions — none triggered

- No live rows of the current/next `plan_date` were touched beyond the E1 leg repair (one row,
  packed-aware, expiry+pod_lot_id only) and the T7 queue lines (disposition_events inserts only, no
  inventory write).
- No Cody FAIL occurred on any migration.
- Three device-number → machine mappings (0715, 0736, 0745) could not be resolved — listed above,
  not guessed.

## Verification summary

- `npx tsc --noEmit`: clean, 0 errors, across the whole repo (checked after every FE change and
  again at the end).
- Every migration applied for real via the Supabase MCP against project `eizcexopcuoycuosittm`,
  written to a timestamped file in `supabase/migrations/`, and committed to `main` immediately
  after applying — matching this session's own established discipline.
- 9 commits pushed to `origin/main`: T1, T2, T4/T5, T7, T8(a), T8(b)/T8(c), registries.
- Parallel session's own dirty files (`RPC_REGISTRY.md`, `PRD-116-phase2-capacity-and-batch.md`,
  `PRD-116-refill-edge-case-hardening.md`, `PRD-117-consolidated-remediation.md`,
  `src/app/(app)/app/pods/page.tsx`, `src/app/(field)/field/config/machines/page.tsx`) were
  stashed-and-restored untouched around every push in this loop, confirmed via `git status` before
  and after each cycle.

## PRD-119b DONE
