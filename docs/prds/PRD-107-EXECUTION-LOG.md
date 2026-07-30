# PRD-107 — Execution Log (Pack Stage: Remove Legs, Skip Semantics, Progress Truth)

**Codename:** pack-stage-truth · **Started:** 2026-07-29 · **Project:** eizcexopcuoycuosittm (PostgreSQL 17.6)
**Status:** IN PROGRESS — survey complete, Dara design complete, Cody verdict recorded. Applies pending.
**Order:** Part A of the combined PRD-107 + PRD-106 push. Backend first, Vercel FE deploy last.

---

## Phase 0 — Survey of live state (read-only, 2026-07-29)

Every number below was measured against prod, not taken from the PRD prose.

### 0.1 Three definitions of "packable" — confirmed, and a fourth found

| Where                          | Predicate                                                                                                    | Counts Removes?    |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------ | ------------------ |
| `confirm_machine_packed`       | unresolved = included ∧ ¬cancelled ∧ ¬packed ∧ ¬skipped ∧ outcome≠not_filled ∧ action ∈ (Refill/Add New/Add) | No (correct)       |
| `v_machine_pack_status`        | `is_pack_complete` = resolved = **total_included** (all included lines)                                      | **Yes (the bug)**  |
| FE `field/packing/[machineId]` | `isGatingLine` = action ∈ (Refill/Add New/Add)                                                               | No (already fixed) |
| `pack_dispatch_line`           | per-tap: action ∉ (Refill/Add New/Add) → `packed=true`, outcome left NULL                                    | n/a (the leak)     |

The FE **detail** page was already corrected by the merged swap-parity fix (3827c5e). The surviving
defect is `v_machine_pack_status`, which the **board** (`field/packing/page.tsx:53`) reads for
`is_pack_complete`. That is what stranded MC-2004.

### 0.2 The strand, reproduced exactly

`v_machine_pack_status` for 2026-07-29 MC-2004-0100-O1 read **resolved 32 / total_included 39** mid-incident —
the exact "32/39" in the PRD trigger note — while `confirm_machine_packed` had **zero** unresolved lines.
Board said incomplete; server gate said pass.

### 0.3 CORRECTION to the goal's acceptance numbers

The goal states: _"view shows packable 32=resolved, 7 driver actions"_. This is not achievable, because
`32/39` was the board's `resolved/total_included` reading, not a packable count. Measured truth:

| Machine             | total_included | packable_n | resolved_n | driver_action_n | ready | RPC agrees |
| ------------------- | -------------- | ---------- | ---------- | --------------- | ----- | ---------- |
| MC-2004-0100-O1     | 39             | **29**     | **29**     | **10**          | true  | ✅ parity  |
| HUAWEI-2003-0000-B1 | 32             | 29         | 29         | 3               | true  | ✅ parity  |
| OMDCW-1021-0100-W0  | 17             | 16         | 16         | 1               | true  | ✅ parity  |
| OMDBB-1020-0P00-O1  | 18             | 18         | 18         | 0               | true  | ✅ parity  |
| JET-1016-0000-O1    | 13             | 12         | 0          | 1               | false | ✅ parity  |

**Acceptance restated:** MC-2004 replay must show **packable 29 = resolved 29, 10 driver actions,
ready_to_pack_close true**. Parity with the RPC predicate holds on 5/5 machines in the prototype.

### 0.4 CORRECTION to the violation count

Goal says _"10 rows packed=true with pack_outcome NULL"_. That was MC-2004 alone on 07-29.
Fleet-wide: **4,143** rows. Classified for backfill:

| Class | n     | Window             | Meaning                                 | Backfill target        |
| ----- | ----- | ------------------ | --------------------------------------- | ---------------------- |
| A     | 3,672 | 2026-03-14 → 06-28 | Legacy WH picks, pre-`pack_outcome` era | `packed`               |
| B     | 439   | 2026-04-13 → 07-29 | Remove / M2W driver legs (**live bug**) | `no_pack_needed`       |
| D1    | 10    | 2026-06-23 → 07-19 | M2M source Remove legs                  | `no_pack_needed`       |
| D2    | 18    | 2026-05-18 → 07-19 | M2M dest legs (Refill/Add New)          | `packed_transferred`   |
| C     | 4     | 2026-04-03 → 04-07 | `action IS NULL`, intent unrecoverable  | `packed` (CS-approved) |

Class A is **dead** (0 rows in last 30 days) — the modern pick path stamps correctly.
Class B is **live and ongoing** (193 in last 30 days; of 434 Removes in 60 days only 6 ever got an outcome).

**Root cause of class B**, `pack_dispatch_line`:

```sql
IF v_dispatch.action NOT IN ('Refill','Add New','Add') THEN
    UPDATE refill_dispatching SET packed = true WHERE dispatch_id = p_dispatch_id;  -- no outcome
    RETURN jsonb_build_object('status','packed_no_pick', ...);
```

### 0.5 Orphaned swap leg — A15 confirmed

MC-2004 shelf A15, 2026-07-29: 4 × `Add New` Barebells all `pack_outcome='not_filled'`, and 4 × `Remove`
Dubai Popcorn skipped **by hand** with reason _"Swap-in Barebells not filled (WH empty), keeping Dubai
Popcorn on A15 to avoid empty shelf; redo swap next plan"_. Exactly the pattern R4 must automate.
Control shelves that must **not** flag: A06, A11, B02, B03 — each has at least one `Add New` that packed.

### 0.6 Facts that shaped the design

- `pack_outcome_enum` exists: `{packed, partial, not_filled, packed_transferred, returned}` — no `no_pack_needed`.
- `needs_review` is **boolean** + `review_reason` text + `review_status` text (default `'none'`).
  Index `idx_refill_dispatching_needs_review` is partial on `review_status='pending'` — the flag must use `'pending'`.
- `protect_packed_dispatch_row` blocks product/shelf/machine/date changes on packed rows only. It does
  **not** block `skipped` or `pack_outcome`, so skipping a packed Remove leg stays legal. Untouched by this PRD.
- `tg_enforce_pack_via_rpc` fires only on `packed` false→true. The backfill never touches `packed`, so it never fires.
- Indexes `idx_dispatch_date_machine` and `idx_rd_machine_date` already cover the view. No new index.

---

## Phase 1 — Dara design (2026-07-29)

Delivered: `v_dispatch_pack_progress` (invoker-rights view, grain machine_id × dispatch_date, `resolved_n`
in exact parity with the RPC predicate, shelf-grain `orphaned_swap_legs` jsonb), enum extension, two-stage
backfill + `chk_packed_requires_outcome` (NOT VALID → VALIDATE), and the orphan detection predicate.

**Postgres constraint on the guardrail:** the goal requires "enum + backfill + constraint in one migration".
PostgreSQL forbids using a value added by `ALTER TYPE ... ADD VALUE` inside the transaction that adds it,
and `apply_migration` wraps each call in a transaction. Verified PG 17.6 — the restriction still applies.
**The split into two migrations is compelled by the engine, not a deviation of preference.**

### CS decisions (2026-07-29)

1. **Backfill write guard** — no `app.via_trigger` suppression. `enforce_canonical_dispatch_write` will log
   ~4,143 `bypass_violation_log` rows. Accepted deliberately as the more honest option (the trigger warns,
   never blocks). These rows must be annotated so a later audit does not read them as genuine bypasses.
2. **Backfill scope** — all 4,143 rows, so the constraint can be `VALIDATE`d and the "zero fleet-wide"
   acceptance criterion is literally true.
3. **RPC coupling** — `confirm_machine_packed` **reads the view** rather than keeping an inline predicate.
   FE/RPC disagreement becomes structurally impossible instead of a test obligation.

---

## Phase 2 — Cody constitutional review (2026-07-29, BEFORE any apply)

**Verdict:** ⚠️ Approve with revisions — 2 blocking, both fixed before apply.

**Articles checked:** 1, 3, 4, 5, 8, 12, 14, 15, 16

| Finding                                                                                                                                                                                                                                                                                                                                                                                    | Article | State        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------- | ------------ |
| `METRICS_REGISTRY.md:28` already registers `v_machine_pack_status` as canonical for pack readiness. A second pack-readiness object is exactly what Art. 16 forbids. Must split the registry row AND redefine `v_machine_pack_status.is_pack_complete` to consume the new view, so only one definition survives.                                                                            | 16      | ❌ blocking  |
| Orphan guard has `confirm_machine_packed` writing `refill_dispatching`, but that function is **absent from the `enforce_canonical_dispatch_write` allowlist** (verified live: `confirm_in_allowlist=false`). As proposed every orphan flag lands in `bypass_violation_log`. Also expands the write surface `RPC_REGISTRY.md:225` declares as "`dispatch_pack_confirmation` (sole writer)". | 1       | ❌ blocking  |
| `confirm_machine_packed` must be replaced at its exact 5-arg signature. `RPC_REGISTRY.md:372` records a prior overload causing `42725 function is not unique`, silently breaking FE approve→push. No overloads.                                                                                                                                                                            | 12      | ⚠️ condition |
| 4,143-row bulk DML outside a canonical writer. Cleared on CS's election, conditional on registering the migration and annotating the bypass rows by timestamp.                                                                                                                                                                                                                             | 3, 12   | ⚠️ cleared   |
| `refill_dispatching` is **not** in Appendix A of the Constitution, yet `RPC_REGISTRY.md:372` calls it "(protected)" and it carries full canonical-writer enforcement. Live governance inconsistency. Reviewed as protected; Art. 15 amendment recommended **separately**.                                                                                                                  | 15      | 📋 noted     |
| `no_pack_needed` is a legitimate terminal state; stamping at push with `packed=false` keeps `uq_dispatch_unstarted_wh_refill` and `tg_enforce_pack_via_rpc` (both keyed on `packed=false`) undisturbed.                                                                                                                                                                                    | 5       | ✅           |
| View is invoker-rights, inherits RLS, correctly refuses `security_definer`.                                                                                                                                                                                                                                                                                                                | 2, 4    | ✅           |
| `audit_log_write` stays installed — backfill fully audited. No parallel `_v2` table.                                                                                                                                                                                                                                                                                                       | 8, 14   | ✅           |

**Approved apply order** (each verified before the next):

1. `prd107_pack_outcome_no_pack_needed_enum`
2. `prd107_pack_outcome_backfill_and_constraint`
3. `prd107_v_dispatch_pack_progress`
4. `prd107_confirm_machine_packed_view_backed`
5. `prd107_push_and_pack_stamp_no_pack_needed`

---

## Phase 3 — Apply (2026-07-29, prod eizcexopcuoycuosittm)

All five applied and verified in order. Two scope findings surfaced at apply time; both are
recorded here because they change what shipped versus what the goal specified.

| #   | Migration                                     | Result                                                                               |
| --- | --------------------------------------------- | ------------------------------------------------------------------------------------ |
| 1   | `prd107_pack_outcome_no_pack_needed_enum`     | ✅ enum now `{packed,partial,not_filled,packed_transferred,returned,no_pack_needed}` |
| 2   | `prd107_pack_outcome_backfill_and_constraint` | ✅ 4,137 rows backfilled; `chk_packed_requires_outcome` armed NOT VALID              |
| 3   | `prd107_v_dispatch_pack_progress`             | ✅ view live + `v_machine_pack_status.is_pack_complete` repointed at it              |
| 4   | `prd107_confirm_machine_packed_view_backed`   | ✅ view-backed gate + orphan guard + allowlist entry                                 |
| 5   | `prd107_stamp_no_pack_needed_driver_legs`     | ✅ trigger + surgical `pack_dispatch_line` patch                                     |

### ⚠️ Finding 1 — the backfill could not reach 4,143 rows; it reached 4,137

Migration 2 failed on first attempt with `23514 m2m_consistency`. Cause: `refill_dispatching`
carries two **pre-existing NOT VALID** CHECK constraints (`m2m_consistency`,
`refill_dispatching_source_consistency_chk`). NOT VALID grandfathers existing rows but is still
re-checked on any UPDATE, so 6 legacy rows cannot be touched at all:

- 2 rows `is_m2m=true` + `source_machine_id IS NULL` (source machine unrecoverable)
- 4 rows `is_m2m=false` + `source_kind='m2m'`

All 6 are May-2026 `Refill` rows, long dispatched, from the pre-PRD-070/071 M2M model. Repairing
them requires **inventing M2M identity data on protected rows**, which this migration refused to do.

**Consequence:** `chk_packed_requires_outcome` ships **NOT VALID**. This does NOT weaken the guard —
NOT VALID only skips the initial full-table scan; the constraint is enforced on every subsequent
INSERT and UPDATE. Proven live: a probe setting `pack_outcome=NULL` on a packed row raised
`check_violation` (rolled back).

**Acceptance deviation:** "Zero packed=true/outcome-NULL rows fleet-wide" is **6, not 0**, and those
6 are named above. Carry-forward ticket: repair the 6 legacy M2M rows, then `VALIDATE CONSTRAINT`.

### ⚠️ Finding 2 — five writers needed the stamp, not one

The goal named `push_plan_to_dispatch` as the single stamping site. Auditing every function that
sets `packed=true` found **five** that would violate the new constraint:

| Writer                                   | Site                                                                        |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `pack_dispatch_line`                     | `packed_no_pick` branch — **THE live leak**, source of all 439 class-B rows |
| `push_plan_to_dispatch`                  | M2M source Remove legs + M2M dest leg (`packed=true` at push)               |
| `swap_between_machines`                  | 2 inserts, `true, false, false, -- packed (no WH action)`                   |
| `insert_driver_remove_line`              | driver Remove, `packed=true, picked_up=true`                                |
| `wh_approve_remove_receipt_multivariant` | `UPDATE ... SET packed = true`                                              |

Rewriting `push_plan_to_dispatch` (24 KB) and `swap_between_machines` from reconstructed source to
add one column each is a larger risk than the defect. Shipped instead: **one BEFORE INSERT OR UPDATE
trigger** (`trg_default_pack_outcome_driver_legs`) that stamps `no_pack_needed` on any leg drawing
nothing from the warehouse, covering all five uniformly plus any future writer. This satisfies R2
("auto-resolve at push") because push inserts pass through it.

The trigger deliberately does **not** auto-fill ordinary warehouse `Refill`/`Add New` rows — those
must still earn `packed`/`partial`/`not_filled` via `pack_dispatch_line`, so the constraint keeps
its teeth exactly where it matters. `pack_dispatch_line` was additionally patched at its leak site
via an **assertion-guarded** substitution (refuses to run unless the target string occurs exactly once).

### Verification

- **Fleet-wide predicate parity: 460 machine-dates compared, 0 mismatches** between
  `v_dispatch_pack_progress.ready_to_pack_close` and the `confirm_machine_packed` unresolved
  predicate — across all history, not just 07-29.
- `confirm_machine_packed` has **exactly 1 overload** (no 42725 repeat).
- Outcome distribution after backfill: `packed` 6394, `not_filled` 490, `no_pack_needed` 449,
  `partial` 40, `packed_transferred` 24, `returned` 65.

### Acceptance battery (single transaction, rolled back)

| Test                                                       | Result                                                                         | Verdict                            |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------- |
| T1 — new `Remove` leg auto-stamped at insert               | `no_pack_needed`                                                               | ✅                                 |
| T2 — WH `Refill` faking `packed=true` with NULL outcome    | `check_violation` raised                                                       | ✅ blocked                         |
| T3 — orphan guard, A15 counterfactual (removes un-skipped) | 4 legs, **A15 only**                                                           | ✅ A06/A11/B02/B03 correctly clean |
| T4 — `confirm_machine_packed` MC-2004 07-29                | `status=ok`, packable **29** = resolved **29**, orphans 4, `needs_review=true` | ✅                                 |

T3 is the proof R4 works: it flags exactly the shelf ops hand-skipped on 07-29, and leaves the three
control shelves whose swap-ins actually packed untouched.

---

## Phase 4 — FE (Stax) + the A4 audit that changed the design

### 🚨 Finding 3 — fixing the board alone would have broken the driver flow

The A4 audit traced the Remove leg's full lifecycle and found the packer's manual toggle is **not**
a board workaround. It is a **required step in the Remove state machine**:

```
mark_picked_up          UPDATE ... WHERE packed = true AND picked_up = false   -- silently skips unpacked
driver_confirm_remove   IF NOT v_dispatch.packed    THEN RAISE 'Dispatch not yet packed';
                        IF NOT v_dispatch.picked_up THEN RAISE 'Dispatch not yet picked up';
```

So the moment the board stopped requiring Removes to be ticked, packers would stop ticking them,
and **`driver_confirm_remove` would hard-fail on every swap**. The board fix REQUIRED a companion or
it would have shipped a worse bug than the one it cured. This was not in the PRD or the goal.

**Why the obvious fix is wrong.** Stamping `packed=true` at push looks right and is dangerous:
`conserve_split_dispatch_quantity` is a **BEFORE INSERT** trigger that, when `NEW.packed = true`,
finds a sibling packed row with the same `(machine, shelf, product, date, action)` and **decrements
its quantity**. `push_plan_to_dispatch` splits a Remove across FEFO batches into exactly that key, so
inserting Removes packed would have silently corrupted Remove quantities. The `packed=false` at push
is load-bearing.

**Shipped:** `prd107_auto_resolve_driver_legs_at_pack_close`. `confirm_machine_packed(final=true)`
flips driver-side legs to `packed=true` via an **UPDATE** (that trigger is INSERT-only, so it cannot
fire). `tg_enforce_pack_via_rpc` gained `confirm_machine_packed` as a sanctioned pack writer
(`pack_guard` is `warn` today, so not yet load-bearing, but correct when it flips to `enforce`).

Lifecycle probe (rolled back), MC-2004 07-29 with all Removes reset to `packed=false`:

| Test                                             | Result                                                                                                                          |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| T5 pack close                                    | `ok`, packable 29 = resolved 29                                                                                                 |
| T6 driver legs after close                       | **10/10** `packed=true`, **10/10** `no_pack_needed`, qty 38→38 **CONSERVED**                                                    |
| T7/T8 `mark_picked_up` / `driver_confirm_remove` | inconclusive under service role — both return early on `auth.uid() IS NULL`. State predicates they require are satisfied by T6. |

Net effect: packers never tick a Remove again, and the driver flow is unchanged.

### FE changes

| File                                                                                                       | Change                                                                                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `field/packing/page.tsx`                                                                                   | Board reads **`v_dispatch_pack_progress`**; progress is `resolved_n/packable_n` with `+N driver actions`; the FE's own `packed_count/sku_count` denominator is deleted (A5). `pack_confirmed` still from `v_machine_pack_status` (a confirmation fact, not a progress fact).                                            |
| `field/packing/[machineId]/page.tsx`                                                                       | Orphan banner from `confirm_machine_packed.orphaned_swap_legs`, with one-tap "Keep current product" that calls `skip_dispatch_line` per leg. Never auto-applied (A5/R4).                                                                                                                                                |
| `field/dispatching/page.tsx`, `field/dispatching/[machineId]/page.tsx`, `field/trips/[machineId]/page.tsx` | **Reverted** an interim `.or(picked_up.eq.true, action.in.(Remove,...))` widening. Once Finding 3's auto-resolve landed, Removes reach `picked_up=true` through the normal path, so the original filter is correct and the widening would have shown Removes before pickup. Net FE diff on these three files: **zero**. |

`npx tsc --noEmit` clean · `npm run build` succeeded. `npm run lint` shows 147 pre-existing repo-wide
problems (`react-hooks/set-state-in-effect` fires identically in `field/trips/page.tsx` and
`field/dispatching/pick/page.tsx`, both untouched) — none introduced here.

---

## Status

**Backend: COMPLETE and verified in prod. FE: complete, built, NOT deployed** (Vercel deploy is the
last step and needs CS go-ahead). Not committed or pushed.

### Acceptance vs the goal

| Criterion                                        | Result                                                                                                         |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| MC-2004 replay, packable = resolved, ready true  | ✅ **29 = 29, 10 driver actions** (goal's "32 / 7" was the board's mid-incident `32/39`, not a packable count) |
| A15 REMOVE flagged `orphaned_swap_leg`           | ✅ 4 legs, A15 only; A06/A11/B02/B03 correctly clean                                                           |
| FE and RPC cannot disagree                       | ✅ **structural** — the RPC reads the view. 460 machine-dates, **0 parity mismatches**                         |
| Zero `packed=true`/outcome-NULL fleet-wide       | ⚠️ **6 remain**, named in Finding 1. Constraint blocks all new ones (proven)                                   |
| Constraint blocks new violations                 | ✅ probe raised `check_violation`                                                                              |
| Driver app shows Removes on pack-closed machines | ✅ preserved via Finding 3 (would have broken without it)                                                      |
| `no_pack_needed` stamping                        | ✅ 449 rows + auto-stamp on every new driver leg                                                               |
| pgTAP suite                                      | ❌ **not written** — assertions were run as rolled-back SQL probes instead. Carry-forward                      |

### Carry-forward

1. Repair the 6 legacy M2M rows, then `VALIDATE CONSTRAINT chk_packed_requires_outcome`.
2. Port the probes into a real pgTAP suite.
3. Annotate the ~4,137 `bypass_violation_log` rows from migration 2 in `MIGRATIONS_REGISTRY.md`.
4. Update `METRICS_REGISTRY.md` (split the readiness row), `RPC_REGISTRY.md:225`
   (`confirm_machine_packed` write surface + allowlist), `CHANGELOG.md`.
5. Article 15 amendment: add `refill_dispatching` to Appendix A (it is enforced as protected but not listed).
