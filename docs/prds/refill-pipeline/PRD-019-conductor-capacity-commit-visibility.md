---
id: PRD-019-refill-pipeline
program: PROGRAM-2026-06-16
title: Conductor reliability — capacity-aware fills, a fully-equipped session, a compact all-rows planning view, and a commit that is provably committed
status: Proposed
severity: P1
reported: 2026-06-16
source: 2026-06-15/16 live conductor session. A clean-slate rebuild of the 5 non-VOX machines (NISSAN, USH, VML-1003, VML-1004, NOVO) surfaced four recurring failure modes: a chat/FE stitch collision, a blind over-fill of a new product, repeated RPC re-discovery, and no compact view to sanity-check the engine.
routing:
  [
    Dara (schema: shelf capacity / size-class view, WH-availability view, compact planning view, single-writer lock table),
    Cody (constitution: commit transactionality, plan-level write lock, new canonical read views, Articles 4/6/9/12/14),
    Stax (FE: compact refill-planning table + WH availability column + comments/upsert inline, Commit transactionality + truthful verified banner + lock),
    Skill (boonz-master-3: embed the live RPC execution kit so a session executes add/remove/edit/swap without rediscovery),
  ]
---

## TL;DR

The pipeline works on the happy path. The moment an operator does anything real (rebuild a scoped route, swap a live seller, introduce a new product, top up a hero shelf, correct a quantity, then commit) four weaknesses show up every time:

1. **Fills are not capacity-aware.** When the conductor places a multi-flavor product on a shelf it has no built-in sense of that shelf's true physical capacity by size class (small / big / large), so it guesses. On 2026-06-16 the conductor filled an empty Hunter shelf to ~14, which fanned out to "4 of each flavor" across batches and read as a gross over-order. The planogram already carries `max_stock` per shelf; the conductor must be forced to read it and never set a manual fill above it.

2. **The conductor is not equipped at session start.** Every add / remove / edit / swap required re-discovering which RPC to call, its signature, its gates, and its gotchas (which one auto-confirms the pick, which finalize is plan-wide vs scoped, which leaves `refill_plan_output` at `pending`, which needs the expiry guard). This is slow and error-prone. The session should boot with the full, current RPC kit.

3. **There is no compact all-rows view to catch what the engine misses.** The per-machine screen shows scored rows, but the operator wants every slot in one compact table, sorted by fill %, with the existing stance / scores / 7d sales / comments-and-upsert fields plus a new **WH Availability** column, so a human can see at a glance where the engine under- or over-reached.

4. **Commit is not provably committed.** A chat-side engine run collided with a live FE Commit, producing duplicate pending rows and clobbered edits, and the FE reported success while the dispatch table was empty. Commit must be single-writer, atomic, scoped, and verified.

This PRD specifies the four fixes. Family A and C are the operator's explicit asks; B is the conductor-reliability ask; D is the commit-safety ask and overlaps with PRD-018.

---

## The session that exposed this (2026-06-15/16)

Context: the 8pm advisory found the cron had picked but not built a draft. The operator asked to rebuild from scratch for 5 non-VOX machines, edit live in chat, then commit, and to add Keen Health (a PO received that day) plus several swaps and fills.

What went wrong, in order:

1. **Chat/FE stitch collision.** While the conductor ran `engine_add_pod` / `engine_swap_pod` from chat, the operator ran a full Commit in the FE at the same second (audit log: operator edits at 21:44:37, chat swap at 21:44:38, operator stitch at 21:46:09). The chat engine rebuilt the shared `pod_refills` working table mid-Commit, so the FE stitch wrote a different set than the reviewed draft. Result: duplicate `pending` `refill_plan_output` rows on the three already-dispatched machines and ten clobbered manual edits. Nothing reached a truck, so it was recoverable, but only via a full wipe.

2. **Blind over-fill.** The operator said "add Hunter Chips" with no quantity. The conductor filled the empty shelf toward its 14 capacity. The stitch correctly split that across the 3 in-stock flavors (~4 each) and across FEFO batches, yielding a packing list that looked like a massive over-order. The math was right; the **target** was a blind guess because the conductor never consulted the shelf's size-class norm for that product.

3. **RPC re-discovery friction.** Applying the edits required, in sequence, discovering and verifying: `pick_machine_manually` (and learning it auto-confirms the whole date), the difference between plan-wide `engine_finalize_pod(date)` and scoped `engine_finalize_pod(date, ids[])`, `edit_pod_refill_row` vs `swap_pod_refill_row` vs `add_pod_refill_row` (and that swap requires an existing draft row), `reset_approved_undispatched` vs `reset_and_restitch`, `receive_purchase_order` (and its hard expiry guard), the `product_mapping` shape (per-machine, generated `is_global_default`, `mix_weight` must sum to 1.0), and the commit tail (`approve_pod_refill_plan` then `stitch_pod_to_boonz(false)` then `approve_refill_plan` to fire the dispatch bridge). All of this is stable and should be pre-loaded.

4. **No compact sanity view.** There was no single compact table of all slots sorted by fill % with WH availability, so catching what the engine skipped (e.g. a low-velocity hero shelf left unfilled) depended on manual cross-checking.

None of this was exotic operator behaviour. It was a scoped rebuild with a product launch and a handful of edits.

---

## Root cause analysis

Four families. Each defect has an R-ID referenced by the Acceptance Criteria.

### Family A: fills are not capacity-aware

- **R-A1.** The conductor (and any manual ADD / fill path) can set a quantity that exceeds the shelf's physical `max_stock`. There is no hard clamp at the pod level; over-fill is only caught downstream (or not at all). `add_pod_refill_row` and `edit_pod_refill_row` accept any non-negative qty without checking shelf capacity minus current stock.
- **R-A2.** Shelf capacity is shelf-size-dependent (small / big / large slot), and the same product on a small shelf vs a large shelf has a different correct fill. The conductor has no quick lookup of "for this shelf, what is the real capacity and the remaining headroom" so it guesses, especially for ADD_NEW where current stock is 0 and the only sane target is `max_stock`.
- **R-A3.** For a multi-variant pod product (Hunter, Chocolate Bar), filling to capacity multiplies into a large per-flavor and per-batch line count, which is correct arithmetic but a poor default for a brand-new placement. There is no "seed quantity" convention for ADD_NEW of a multi-variant product.

### Family B: the conductor is not equipped at session start

- **R-B1.** `boonz-master-3` documents the pipeline stages but does not ship the concrete, current RPC execution kit (exact signatures, argument order, role/auth behaviour under the service context, the gates each one trips, and the known gotchas). Every session rediscovers them from `pg_proc`.
- **R-B2.** Several RPCs have non-obvious, must-know behaviours that are not captured anywhere the conductor reads first: `pick_machine_manually` auto-confirms the whole plan_date; `engine_finalize_pod` has a plan-wide and a machine-scoped overload; `swap_pod_refill_row` requires a pre-existing draft row and carries the old qty; `stitch_pod_to_boonz(false)` leaves `refill_plan_output` at `pending` and needs `approve_refill_plan` to dispatch; `receive_purchase_order` hard-requires a non-null batch expiry; `product_mapping.is_global_default` is generated and `mix_weight` must sum to 1.0 per machine to avoid the inflation bug.

### Family C: no compact all-rows planning view

- **R-C1.** The refill-planning screen surfaces scored / picked rows but there is no compact table of **all 16 slots** per machine, sorted by fill %, in one scan.
- **R-C2.** There is no **WH Availability** column tying each shelf's product to its current sellable warehouse stock, so the operator cannot see at planning time whether a target is even sourceable (the Keen Health "no stock", G&H "no stock", and several WH-clamped bumps were only discovered at stitch).
- **R-C3.** The existing per-row comments and upsert fields (driver notes, stance, badges, final score, 7d sales) are not shown inline in a single compact row, so the human review that catches engine misses is harder than it needs to be.

### Family D: commit is not provably committed

- **R-D1.** No single-writer guarantee. Chat (service role) and FE (operator_admin) can both drive the pipeline on the same `plan_date` simultaneously; the engine working-table rebuild is destructive to an in-flight commit. (Same root as the PRD-018 incident, observed again here.)
- **R-D2.** The Commit chain is not atomic and reports success optimistically: the FE printed "committed" while `refill_dispatching` was empty, and a mid-chain engine rebuild left duplicate `pending` rows.
- **R-D3.** `engine_finalize_pod` run plan-wide can un-approve a subset approval, and the dispatch bridge only fires on `approve_refill_plan`, so a commit can silently end "stitched but not dispatched."

---

## Acceptance criteria

### A. Capacity-aware fills

- **AC-A1.** `add_pod_refill_row` and `edit_pod_refill_row` reject (or clamp with a returned warning) any qty that would push `current_stock + qty` above the shelf's `max_stock`. The clamp reason is returned so the conductor can report it.
- **AC-A2.** Dara exposes a read view (e.g. `v_shelf_capacity`) giving, per `shelf_id`: `max_stock`, `current_stock`, `headroom = max_stock - current_stock`, shelf size class, and the product currently on the shelf. The conductor MUST read this before setting any manual fill or ADD_NEW qty.
- **AC-A3.** For ADD_NEW of a multi-variant pod product, the default target is `headroom` but the conductor surfaces the resulting per-flavor split count and asks for confirmation when the split would exceed N lines (default N configurable), or applies a "seed quantity" convention (default: fill to headroom for single-variant, seed to a smaller default for first-time multi-variant placement). Behaviour is documented in the skill.
- **AC-A4.** `boonz-master-3` is updated so the conductor never sets a manual fill/ADD qty without first reading `v_shelf_capacity` for that shelf. The Hunter A13 case (empty 14-slot shelf, "add Hunter") produces a confirmed, capacity-justified number, not a blind 14.

### B. A fully-equipped session

- **AC-B1.** `boonz-master-3` ships an embedded **RPC execution kit**: for every write RPC in the daily flow (pick, confirm, add, swap, edit, stop, finalize plan-wide and scoped, approve pod, stitch dry-run and commit, approve refill, reset_approved_undispatched, reset_and_restitch, unpick, receive_purchase_order, product_mapping setup) the exact signature, argument order, what gate it trips, its service-context auth behaviour, and its known gotcha.
- **AC-B2.** The kit includes the canonical **order of operations** for the three flows (full route, single-machine Path C, post-commit amend) and the commit tail, so no session has to infer sequencing.
- **AC-B3.** The kit is verified against `pg_proc` at author time and carries a "last validated" date; a lightweight check flags drift when a signature changes.
- **AC-B4.** Outcome test: a fresh session can execute a 5-machine rebuild with edits/swaps/adds and a clean commit using only the kit, with zero ad-hoc `pg_proc` lookups.

### C. Compact all-rows planning view (with WH availability)

- **AC-C1.** The refill-planning screen offers a compact per-machine table of **all slots** (A01..A16), one row each, sorted by fill % ascending by default (lowest fill first), with sort toggles already present (Slot, Stock, Fill %, Expiry).
- **AC-C2.** Columns: Slot, Product, Stock (x/max), Fill %, Stance, Global badge, Local badge, 7d Sales, Final Score, the engine's planned action+qty for tomorrow, **WH Availability** (current sellable warehouse stock for that shelf's product, refund/reserve aware), and the inline **comments / upsert** fields already in the model.
- **AC-C3.** WH Availability is sourced from the canonical sellable-stock view (warehouse_stock > 0, reserve-aware), shown per shelf product, and visibly flags `0` (unsourceable) so a target against empty stock is caught at planning time, not at stitch.
- **AC-C4.** The view is exportable / readable by the conductor (a matching read RPC or view) so chat and FE show the same compact picture, and the conductor can present it inline when asked "show me the machine."

### D. A commit that is provably committed

- **AC-D1.** Plan-level single-writer lock: while a `plan_date` is being committed (FE or chat), any second writer context for that date is rejected with a clear error. Lock TTL is 15 min (an older lock is treated as orphaned and may be stolen); `force_release_refill_plan_lock(plan_date, reason)` (operator_admin/superadmin, reason >= 10 chars, audited) clears a wedged lock. Engine refusal is **per-machine** (updated 2026-06-16, Phase F): the engines refuse/skip ONLY machines that already have an approved `refill_plan_output` row; building a fresh machine on a date that has other dispatched machines is allowed (the scoped-add path); amending an already-committed machine still requires `reset_approved_undispatched` first.
- **AC-D2.** Commit is atomic via the canonical `commit_refill_plan_atomic(plan_date, machine_names)` RPC (Phase E): in ONE transaction it approves the pod draft, finalizes scoped to the committed machines, stitches, and approves the boonz plan (dispatch bridge), then asserts pre-commit invariants (stitch lines > 0; every named machine has >= 1 output and >= 1 dispatch row; no leftover pending) and RAISEs to roll back on any violation. The pipeline can never land "pod stitched, output empty." The earlier multi-step FE saga is retired.
- **AC-D3.** The FE banner reports **verified** counts (rows written to `refill_plan_output` and `refill_dispatching`), never optimistic intent. "Committed" requires the dispatch rows to exist.
- **AC-D4.** Commit never re-finalizes; the reviewed `pod_refill_plan` draft is the source of truth. Commit = `approve_pod_refill_plan` -> `stitch_pod_to_boonz(false)` -> `approve_refill_plan`, lock-wrapped. (Corrected 2026-06-16: scoped `engine_finalize_pod` supersedes-then-rebuilds the draft from `pod_refills`, which would erase manual adds/swaps and revert manual qty edits — the PRD-018 clobber. Finalize stays only in the BUILD path: cron + Path C.)
- **AC-D5.** The atomic commit enforces a set-level HARD invariant inside the transaction and rolls back on violation: across the whole committed set, `lines_built > 0` AND `refill_plan_output` approved rows > 0 AND `refill_dispatching` rows > 0 (catches the empty-stitch bug). A per-machine zero-dispatch outcome is a SOFT flag in the returned summary (`{machine, note:'committed_no_actionable_lines'}`), never a rollback, so one dud machine cannot abort the rest of the route (Complete-but-Partial, cf. PRD-020).

---

## Out of scope / dependencies

- Overlaps with **PRD-018** (amendable committed plans): D1-D4 here are the prevention layer; PRD-018 is the post-commit repair layer. Ship the lock (D1) first; it would have prevented this incident outright.
- The packing-list line merge (collapse FEFO batch-split duplicate rows into one SKU line with a batch breakdown) is a related packing-FE improvement, tracked separately, not in this PRD.
- Strategic capture of recurring swaps/phase-outs (moving the manual swaps into weekly `strategic_machine_tags`) is an operating-process change covered in the 2026-06-16 post-mortem, not engineering scope here.

## Priority order

D1 (single-writer lock) → A1/A2/A4 (capacity clamp + view + conductor read) → C (compact view + WH availability) → B (RPC kit) → D2-D5 (atomic, verified, scoped commit).

---

## Execution log

All migrations authored as FILES only, applied to prod only after CS sign-off. Forward-only, timestamp-prefixed. Apply in ascending filename order.

| Migration / file                                            | Phase          | What                                                                                                                                                                       | Cody                                          |
| ----------------------------------------------------------- | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `20260616110411_prd019_d1a_refill_plan_lock.sql`            | D1a            | `refill_plan_lock` + acquire/release RPCs                                                                                                                                  | approved (fixed audit PK arg)                 |
| `20260616110412_prd019_d1b_assert_refill_plan_writable.sql` | D1b            | writability guard helper                                                                                                                                                   | approved                                      |
| `20260616110413_prd019_d1b_engine_guards.sql`               | D1b            | engine add/swap/finalize guard                                                                                                                                             | approved                                      |
| `20260616110414_prd019_a1_v_shelf_capacity.sql`             | A1             | `v_shelf_capacity`                                                                                                                                                         | approved (view)                               |
| `20260616110415_prd019_a2a3_clamp_add_edit.sql`             | A2/A3          | capacity clamp on add/edit row                                                                                                                                             | approved (no-silent-cut ok)                   |
| `20260616110416_prd019_c1_v_refill_planning_compact.sql`    | C1             | compact all-rows view                                                                                                                                                      | approved (view)                               |
| `20260616110417_prd019_e_commit_refill_plan_atomic.sql`     | E1-E3          | `commit_refill_plan_atomic` (re-authored 2026-06-16 in place: removed engine_finalize_pod to stop the draft clobber; HARD invariant now set-level + per-machine soft flag) | approved (revised)                            |
| `20260616110418_prd019_f1_per_machine_refusal.sql`          | F1             | helper v2 + engine add/swap per-machine skip                                                                                                                               | approved                                      |
| `20260616110419_prd019_f2_lock_ttl_force_release.sql`       | F2             | acquire TTL 15 + `force_release_refill_plan_lock`                                                                                                                          | approved                                      |
| FE `RefillPlanningTab.tsx`                                  | C2 / D2-5 / E4 | compact table; commit repointed to `commit_refill_plan_atomic`; lock acquire/release                                                                                       | Cody class (d): all writes via canonical RPCs |
| Doc `docs/architecture/RPC_EXECUTION_KIT.md`                | B              | conductor RPC kit (last validated 2026-06-16)                                                                                                                              | n/a (doc)                                     |

Note: the F1 file supersedes the D1b engine guard (whole-date refusal -> per-machine skip); apply 110413 then 110418. The F2 file supersedes the D1a acquire body (30 min -> 15 min TTL); apply 110411 then 110419.
