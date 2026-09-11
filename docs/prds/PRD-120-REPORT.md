# PRD-120 close-out - L4, L5, and the two 2026-09-09 blockers

Repo: `boonz-erp`. Supabase project `eizcexopcuoycuosittm`. Shipped 2026-09-09, direct commits to
`main`. L1/L2/L3 shipped earlier - see `docs/prds/PRD-120-pack-and-identity-integrity.md`.

Read in full before starting: `docs/prds/PRD-120-pack-and-identity-integrity.md`,
`docs/prds/PRD-119b-REPORT.md` (T1/E1 - the incomplete prior fix L5 closes).

---

## Blocker 1 - junk 2030 rows in `machines_to_visit`

**Root cause.** `pick_machine_manually` INSERTs a `machines_to_visit` row with no upper bound on
the caller-supplied `p_plan_date` (its own `add_source` column defaults to `'picker'`, distinct
from `add_machine_to_plan`'s explicit `add_source='operator'`). A single ~100-minute exploratory
session on 2026-08-04 (03:09–04:49 UTC) against this function wrote 72 `status='cs_added'` rows
dated 2030-11-01..04 across 24 machines. `pick_machines_for_refill` (a different writer, already
implicated in the separate 2026-09-08 incident's 64 `status='picked'` rows) shares the identical
defect. `days_to_next_planned_visit`, read by `approve_refill_plan`'s K1 visit-aware floor, computed
~1,500 days from these rows, refusing every warehouse line on the affected 24 machines - 7 of them
hit today's 2026-09-09 plan (80 lines total) and were unpicked by hand to get through.

**Fix.** `20260909170426_blocker1_reject_far_future_plan_dates_at_source.sql` adds
`IF p_plan_date > CURRENT_DATE + 30 THEN RAISE EXCEPTION` to all three writers:
`pick_machine_manually`, `add_machine_to_plan` (same defect, unexploited, fixed anyway), and
`pick_machines_for_refill` (adds the missing upper bound beside its existing 7-day lower bound).

**Cody:** ✅ Approve. Articles 1, 4, 12 - no new write path, validation added not removed,
md5-guarded forward-only `replace()` on all three functions.

**Row count - before/after.** 72 poisoned rows before this session; **0 after**, cleared via the
canonical `unpick_machine_to_visit` RPC (never a direct `UPDATE`) - all 72 calls returned
`dropped: 1`. `check_far_future_picked_visits()` (already live from the 2026-09-08 incident)
confirms `status: "ok"` post-cleanup.

**Written by, confirmed:** `pick_machine_manually`, via elimination against `add_source` (72/72
rows carry the column default `'picker'`, not `add_machine_to_plan`'s explicit `'operator'`) and
against `created_at` clustering (all 72 in one 100-minute window, one calling session).

**Fixture (rolled back):** all three functions correctly `RAISE` on `p_plan_date='2030-01-01'`;
`pick_machine_manually(CURRENT_DATE+5, ...)` still succeeds normally.

**Commit:** `0d66528`.

---

## Blocker 2 - flavor-mismatch guard for Gate-1

**`check_eg_resolvable(p_plan_date date)`** - read-only, `SECURITY INVOKER` (plain SQL `STABLE`,
deliberately no `DEFINER`/role gate: it mutates nothing and RLS on `refill_plan_output`/
`pod_inventory` already governs visibility). Returns any Remove line in `refill_plan_output` whose
named `boonz_product_id` has no Active pod lot on that exact `machine_id + shelf_id`, alongside the
shelf's real Active flavor(s).

Wired into `src/components/RefillPlanReview.tsx` (the Gate-1 review screen) as a non-blocking amber
warning banner, listed above the plan rows - never a block, per the goal's own instruction.

**Cody:** ✅ Approve. Article 16 (new diagnostic object, not a re-derivation of a registered metric).

**Commits:** `44c95d6` (backend), `d3c51a1` (FE).

---

## L5 - planning names a flavor the shelf does not hold (root cause of L4's noise)

**Root cause.** T1/E1 (PRD-119b) dropped the `shelf_id` filter from `push_plan_to_dispatch`'s Remove
lot lookups to fix the WRONG-SHELF case (same flavor, different shelf) - but left the exact
`boonz_product_id` filter in place, so the WRONG-FLAVOR case (same shelf, different flavor - a
multi-flavor pod lane, e.g. Rice & Corn / Dubai Popcorn) still fell into the `NULL pod_lot_id`
catch-all. `record_remove_leg_outcome` then refuses those legs, the driver can't zero them from the
app, and has to insert his own `[DRIVER-INSERT]` rows - 6 of those on 2026-09-09 alone, across the
two live cases named in the goal (VML-1004-0500-O1/A11 Rice & Corn, HUAWEI-2003-0000-B1/B16 Dubai
Popcorn).

**Fix (`20260909173544_prd120_l5_push_plan_flavor_fallback.sql`, `push_plan_to_dispatch` v13→v14).**
Both the general Remove/M2W branch and the M2M source branch: when the exact-flavor lot lookup
finds zero lots (`v_remaining = line.quantity`, i.e. no progress at all - a genuine partial
shortfall on the correctly-named flavor is untouched, stays on the old catch-all), fall back to a
shelf-wide search (`machine_id + shelf_id`, no product filter), splitting across lots/flavors if the
shelf holds several, each leg tagged `[FLAVOR-CORRECTED: plan named %s, shelf actually holds %s]`.
If even the fallback finds nothing, a non-blocking `quantity=0` `[NO LOT ON SHELF]` leg is created
instead of an unresolvable `NULL pod_lot_id` leg. The M2M destination leg is rewritten to mirror the
ACTUAL flavor(s) pulled at source - one destination leg per distinct resolved flavor, correctly
`m2m_partner_id`-linked to only its own source leg(s) - instead of always copying the originally
planned flavor.

**Cody:** ✅ Approve. Articles 1 (still the sole dispatch writer), 4, 12 (md5-guarded, byte-anchored
`replace()` against the live function; no other logic touched).

**Fixtures (all rolled back, real reference data):**

- (a) Remove naming Flavor A on a lane holding only Flavor B → single fallback leg binds to Flavor
  B, `pod_lot_id` set, tagged `FLAVOR-CORRECTED`. Passed.
- (b) Lane holding two flavors → two legs, quantities split across lots, total preserved. Passed.
- (c) M2M with a flavor swap → destination leg carries the pulled flavor, correctly partner-linked.
  Passed.
- Exact reproduction of the live HUAWEI-B16→AMZ-1029-A11 case (multi-flavor popcorn pod, planned
  Salted, shelf held Butter) - confirms the fix resolves the concrete incident, not just the
  synthetic cases.

**L5 item 2 - bulk repair + auto-run at push (`20260909175530_prd120_l5_bulk_repair_and_auto_run.sql`).**
New `repair_remove_leg_shelf_lot_bulk(p_plan_date, p_machine_name DEFAULT NULL, p_reason, p_caller
DEFAULT NULL, p_dry_run DEFAULT true)` - `SECURITY DEFINER`, role check (operator_admin/
superadmin/manager), `p_reason` ≥10 chars, `app.via_rpc`/`app.rpc_name` set - aggregates the
existing single-row `repair_remove_leg_shelf_lot` over every undelivered (`NOT picked_up AND NOT
dispatched`, not cancelled/skipped/returned) Remove leg with `NULL pod_lot_id` for a plan_date
(+machine), catching per-row exceptions so one un-repairable leg doesn't abort the batch.
`push_plan_to_dispatch` now auto-calls it (`p_dry_run:=false`) right after `pair_internal_transfer_m2m`,
same non-fatal `monitoring_alerts`-on-failure pattern; `rpc_version` v14→v15.

Note: the wrapped single-row RPC's own exact-flavor lot lookup is unchanged - a leg whose flavor
has zero lots anywhere still reports "no Active pod lot found." This is correct: the wrapper only
aggregates, L5's push-time fallback is the actual fix, and this auto-run is a defense-in-depth
safety net for whatever the fallback still can't resolve.

**L5 item 4 - nightly assertion.** `check_null_pod_lot_remove_legs()`, same family as
`check_far_future_picked_visits`, via `safe_monitoring_alert`. Cron `check_null_pod_lot_remove_legs_nightly`
at 20:25 UTC.

**Verification (all real data, all read-only or `p_dry_run=true` - no live-plan mutation):**

- Bulk wrapper against `2026-06-03` (2 real legacy `NULL pod_lot_id` Remove legs, predating L5):
  aggregates 2 attempted / 0 succeeded / 2 failed, each failure the expected "no Active pod lot
  found" from the untouched single-row RPC - proves per-row exceptions are caught, not fatal.
- Bulk wrapper against `2026-09-09` (today's pushed plan, post-L5): 0 attempted.
- Role guard: a field_staff caller UUID → `forbidden for role field_staff`.
- Reason guard: `p_reason='short'` → `must be at least 10 characters`.
- `check_null_pod_lot_remove_legs()`: reports `status: "violation"`, `count: 4` - see "Open items"
  below.

**Commits:** `893557d` (push/bind fallback), `20cdcd3` (bulk repair + auto-run + nightly assertion).

---

## L4 - Remove rows rendered the planned quantity, not the delivered one

**Root cause.** `handleMarkAllAdded` in
`src/app/(field)/field/dispatching/[machineId]/page.tsx` unconditionally reset every line's
`filled_qty` to the planned `quantity` - including Remove lines. A driver who zeroed a Remove
line's Filled field (correctly recording "not on the shelf") and then tapped the bulk "✓ All added"
button had that zero silently clobbered back to the planned quantity **before** Save ran, and that
wrong quantity was what actually reached `driver_confirm_remove`'s `p_qty_removed` argument and got
persisted as `driver_confirmed_qty`. This reproduces the live VML-1004-0500-O1/A11 case exactly:
dispatch `c37a3c9e-c59a-492b-aa50-d217b8e43f4c` carries `driver_confirmed_qty=1` in the database
today, not `0` - the driver's zero never survived to the write, which is why the screen "still
showed −1": the ledger itself recorded 1, not just the display.

Three secondary render bugs, all the same class the codebase's own `addTotal` was already fixed for
(`BUG-010` / IFLY Coconut comment, same file) but whose Remove-side siblings were never brought in
line:

- Per-line render: `−{line.filled_qty || line.quantity}` - a legitimate `filled_qty=0` fell back to
  the planned quantity (`0` is falsy in `||`).
- Post-save shelf `removeTotal`: `l.filled_qty || l.quantity || 0` - same bug, at the aggregate
  level (HUAWEI-2003-0000-B1/B16's reported "×3 −5" against a 3-unit lane).
- Pre-save shelf-total chip: summed raw planned `quantity` for Remove lines unconditionally, never
  reflecting the driver's own Filled-field edits at all.
- `src/app/(field)/field/pickup/page.tsx`: `filled_quantity > 0 ? filled_quantity : quantity` - same
  bug, same fix.

**Fix (commit `f3a7c12`):**

1. `handleMarkAllAdded` no longer touches `filled_qty` for Remove-action lines - Add/Refill lines
   are unaffected (unchanged behavior: bulk-mark still defaults them to planned).
2. Per-line Remove render and the post-save `removeTotal` now use `line.filled_qty || 0` (dropped
   the `|| line.quantity` fallback) - matching `addTotal`'s already-correct pattern.
3. The pre-save shelf chip gained `removeFilled` (sums actual `filled_qty`, mirroring `addFilled`)
   and now displays `−{removeFilled}` with a dimmed `/ {removePlanned}` suffix when they differ,
   exactly mirroring the existing Add/Refill chip's own planned-vs-filled UX.
4. `pickup/page.tsx`'s `qty` now reads `line.filled_quantity` directly - its fetch-time derivation
   (`filled_quantity ?? quantity ?? 0`) already resolves the untouched-pre-pack case to planned, so
   the redundant render-time fallback only ever reintroduced the same bug.

**Verification.** `npx tsc --noEmit` and `npm run lint` both clean on the touched files (pre-existing
unrelated lint errors elsewhere in the repo, untouched by this change). No test harness exists in
this repo for field-PWA screens, and I did not do a live browser walkthrough as a real field_staff
user this session - **that is an explicit gap, not a claimed pass.** In its place I hand-traced the
fix against real production data for both exact live cases:

- Simulated the PRD's own regression fixture (one Remove zeroed by the driver + one driver-inserted
  Remove of a different flavor) against the actual HUAWEI-2003-0000-B1/B16 row set fetched live:
  post-fix, `removeTotal` sums to the real 5 units moved (2 Salted + 3×1 Butter), matching the shelf
  exactly; the zeroed case renders `−0` rather than reverting to the plan.
- Confirmed `handleMarkAllAdded`'s fix leaves Add/Refill bulk-marking byte-identical to before.

**Recommendation:** before this ships to real drivers, do a live walkthrough on `/field/dispatching`
as `driver@boonz.test` - actually zero a Remove line, tap "✓ All added", Save, and confirm the
post-save summary shows `−0` and the shelf total matches.

---

## The AMZ-1029-3003-O1 / A11 transfer flavor correction - NOT done, CS decision needed

The destination leg named in the goal, `dispatch_id 1bd1e07a-1378-4c60-a57a-aaef85a53141`
("Dubai Popcorn - Salted" ×3, comment `POPCORN CONSOLIDATION: 3 carried from HUAWEI B16 (any
flavor). Lane 0->6 with VML-1003 units"), is **`packed=true`, `picked_up=true`, `dispatched=true`,
dated `2026-09-09`** - it satisfies all three of this goal's own "do not touch" conditions.

It also is not a clean 1:1 case: the actual HUAWEI B16 Remove legs moved 2× Salted (correctly
flavored, `7110136b-...`, `filled_quantity=2`) plus 3× Butter (the `[DRIVER-INSERT]` rows,
1 unit each) - 5 units total, not the 3 the consolidation note claims, and the correct destination
label is a mix (2 Salted + 3 Butter from HUAWEI, plus a separate 3 Butter from VML-1003 A16 on
sibling leg `f206e0dc-...`, which is itself correctly labeled and does **not** need correction).
This was a hand-annotated one-off consolidation, not a `push_plan_to_dispatch`-generated M2M pair
(its comment doesn't match that branch's own `format('M2M: %s -> %s', ...)` pattern), so L5's fix
does not retroactively touch it.

**I did not UPDATE this row.** The goal's own safety rule ("do not touch packed/picked_up/dispatched
rows or 2026-09-09+ live rows") directly conflicts with the goal's own instruction to "fix the
pairing and correct that row" - I resolved that conflict in favor of the general safety rule and am
surfacing it here rather than picking a side unilaterally.

**Decision needed from CS:** should `1bd1e07a` be corrected, and if so, to what split (it's not a
single flavor - the true HUAWEI contribution was 2 Salted + 3 Butter, not a flat re-label to
Butter)? I can write and Cody-review a one-off, hand-verified correction migration once you confirm
the intended split.

**Closed, 2026-09-11 - no correction.** Re-checked live: `1bd1e07a` is still `packed=true,
picked_up=true, dispatched=true` (inside the "do not touch" rule), its comment already reads
"POPCORN CONSOLIDATION: 3 carried from HUAWEI B16 (**any flavor**)... Lane 0->6 with VML-1003
units" - the row itself already documents that the exact flavor was never pinned down to a single
value. The shelf's current Active `pod_inventory` lot is Dubai Popcorn - Butter, 2 units @
2027-03-15, matching WEIMI's own read of the shelf. There is nothing left to reconcile the dispatch
row's recorded flavor against that isn't already either (a) inside the do-not-touch window, or (b)
already correctly reflected in live pod_inventory. **Known historical artifact, deliberately not
corrected.** Closing this open item.

---

## Open items - flagged for CS

1. **The AMZ-1029 A11 correction above** - CLOSED 2026-09-11, no correction made (see above).
2. **4 historical `NULL pod_lot_id` Remove legs**, all dated 2026-06 (`a85b3386-...`,
   `4a6924e7-...`, `42efe575-...`, `8f8baa80-...`), all `packed=true`, none `picked_up`/
   `dispatched` - flagged live by the new `check_null_pod_lot_remove_legs()` assertion, deliberately
   **not** repaired this session (they predate L5 and are `packed=true`, so the same "don't touch
   packed rows" caution applies). `repair_remove_leg_shelf_lot_bulk(p_plan_date, p_machine_name,
..., p_dry_run:=false)` is ready to run against them on your say-so - dry-run first is
   recommended given the underlying single-row RPC's exact-flavor lookup will likely still fail for
   at least some of them (they predate the L5 fallback entirely).
3. **L4's live-browser verification** - recommended above, not done this session.

## Confirmed

- No dispatch row with `packed=true`, `picked_up=true`, `dispatched=true`, or dated `>= 2026-09-09`
  was mutated by anything shipped this session. Every write-capable call used above ran with
  `p_dry_run=true`/`true` (i.e., no-op) against historical (2026-06 or earlier) data, or was a
  role/input-validation rejection that raised before any write; the two live migrations that touch
  `push_plan_to_dispatch` only change function _definitions_, not data, and were verified via
  `pg_get_functiondef` introspection plus the fixtures above rather than a live re-run against
  today's plan.
- `machines_to_visit`: 72 junk rows → 0, confirmed via `unpick_machine_to_visit` return values and a
  follow-up count query.

**Commits (in order):** `0d66528`, `44c95d6`, `d3c51a1`, `893557d`, `20cdcd3`, `f3a7c12`, `decc83b`
(registry docs). All pushed to `main`.
