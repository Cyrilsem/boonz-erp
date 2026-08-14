# PRD-115 build report — mid-pack plan edit safety

Branch `prd-115-midpack-safety`. Source PRD: `docs/prds/PRD-115-midpack-plan-edit-safety.md`
(APPROVED by CS 2026-08-14, live incident NISSAN-0804 the same day).

---

## 0. What the incident actually was

Read before the fixes, because two of the four symptoms have a cause that is not the
obvious one.

`refill_dispatching` has no `rpo_id`. The link between a plan row and the dispatch row it
produced runs the other way: `refill_plan_output.dispatch_id`. Live evidence from the
incident machine (NISSAN-0804-0000-L0, 2026-08-14) reads exactly that shape:

| plan row | product              | shelf | operator_status              | dispatched | dispatch_id → | include   |
| -------- | -------------------- | ----- | ---------------------------- | ---------- | ------------- | --------- |
| faf4bc1f | Al Ain Zero          | A15   | approved                     | true       | ff8ab2ca      | **false** |
| 6e390d23 | Coca Cola Zero       | A15   | approved                     | true       | 43759f3c      | **false** |
| c1117a2d | Dubai Popcorn Butter | A15   | rejected (hand-fixed by ops) | true       | ffb3ec73      | **false** |
| 097e10c2 | Dubai Popcorn Salted | A15   | rejected (hand-fixed by ops) | true       | 778c627c      | **false** |
| 84595ae5 | Hunter Sea Salted    | A15   | approved                     | true       | a44fc65f      | true      |

Four dispatch rows on one shelf carry an `edit_kind='remove'` edit-log entry and
`include=false`; the two Al Ain / Coca Cola plan rows are STILL `approved`. Those two rows
are the live resurrection charge that had not gone off yet. Ops had already hand-set the
two Popcorn rows to `rejected`, which is the fix this PRD makes automatic.

The vector, stated precisely: `remove_dispatch_row` removed the row and left the
instruction. `push_plan_to_dispatch` selects
`WHERE operator_status='approved' AND dispatched=false`, and `repack_machine` (the RPC
behind the FE's own "Override & re-pack" button) sets `dispatched=false` on approved plan
rows. So the button offered as the exit from the stuck state was itself the trigger that
re-armed the removed lines.

RC-01 §5(5a) preserve-matching does catch the same `(shelf_id, pod_product_id)` twice,
which is why a plain remove-then-repush of the SAME product did not resurrect. CS re-scoped
the shelf to a DIFFERENT product each time, so 5a never matched and 5b (which requires
`include=true`) skipped the removed row and inserted a fresh one.

---

## 1. Cody review — backend (§2.1, §2.2, §2.3)

Knowledge base loaded and readable: `01_constitution.html` (45,555 b),
`02_phase_a_plan.html`, `03_a1_before_after.html`, `CHANGELOG.md`,
`MIGRATIONS_REGISTRY.md`, `RPC_REGISTRY.md`, `METRICS_REGISTRY.md`,
`boonz_process_map.html`, `boonz_db_audit.html`.

Change class: **(b) modified DEFINER writers** (`remove_dispatch_row`,
`push_plan_to_dispatch`) plus **(c)/(a) a canonical read object** (`v_machine_pack_status`).

**Verdict:** ⚠️ Approve with revisions. Conditions C-1 through C-7 are **NOT waivable**.

**Articles checked:** 1, 3, 4, 5, 6, 8, 12, 14, 15, 16 (+ S-308).

**Findings:**

- **Article 1 / 15 — `refill_plan_output` is a protected entity (Appendix A), and
  `remove_dispatch_row` becomes its ninth DEFINER writer.** The live count is eight:
  `approve_refill_plan`, `assert_weimi_slot_match`, `driver_substitute_dispatch_line`,
  `override_refill_quantity`, `push_plan_to_dispatch`, `rename_machine`, `repack_machine`,
  `reset_approved_undispatched`. Article 1 is already a many-writers-one-registry reality
  on this table, so a ninth is not an automatic block, but it is only legal if it is
  registered and column-scoped. → **C-1**.
- **Article 5 ✅ with a tripwire.** `operator_status` is a status column and therefore a
  state machine. `approved → rejected` inside a role-gated DEFINER RPC is exactly the
  permitted shape; no FE-arbitrary flip is introduced. But the tombstone's durability rests
  entirely on two OTHER writers never reaching a `rejected` row:
  `repack_machine` (`WHERE operator_status='approved'`) and `reset_approved_undispatched`
  (`WHERE operator_status='approved'`, and it NULLs `dispatch_id`). That second one is the
  sharper edge: NULLing `dispatch_id` would ALSO blind the §2.2 guard, which is keyed on
  `line.dispatch_id`. Today both filters exclude `rejected`, so the two layers hold
  independently. If anyone ever widens either WHERE clause, BOTH layers fall at once and
  silently. → **C-2**.
- **Article 4 ✅.** `remove_dispatch_row` already sets `app.via_rpc='true'` and
  `app.rpc_name`, validates `user_profiles.role`, validates `p_edit_role`, takes
  `FOR UPDATE`, and refuses a picked-up row. All of that is byte-identical; the tombstone
  UPDATE sits INSIDE those gates, not around them.
- **Article 8 ✅ with proof required.** `refill_plan_output` carries
  `tg_audit_refill_plan_output` (AFTER INSERT/DELETE/UPDATE → `audit_log_write('id')`), so
  the tombstone mints a `write_audit_log` row under `rpc_name='remove_dispatch_row'`.
  "Carries a trigger" is not proof that the row lands. → **C-3**.
- **Article 12 ✅.** Three new forward-only migration files. Nothing edits a past
  migration. The §2.2 splice is the pattern already ratified by
  `20260709015534_drift_kill_p1_wire_push_and_stitch.sql`: pull the live body, refuse on
  base-md5 drift, refuse unless each anchor appears exactly once, splice, EXECUTE. It also
  short-circuits on re-run, so it is idempotent. Retyping 24 kB of conservation checks,
  RC-01 idempotency and FIFO batch walking by hand is the alternative, and it is the one
  that breaks PRD §3's byte-identical requirement. The splice is the safer choice, not the
  clever one. → **C-4** (record the post-image md5; the next splice needs it as its base).
- **Article 16 ⛔ ON THE FE.** `v_machine_pack_status` IS the registered canonical object
  for "Machine pack/pickup/dispatch readiness" (`METRICS_REGISTRY.md` line 28, LIVE since
  PRD-030). So `needs_reconfirm` / `unresolved_n` belong in that view and nowhere else:
  §2.3 is Article 16 compliant. The FE is not. `/field/packing/[machineId]` derives
  `hasPriorPack = lines.some(l => l.packed)` client-side, and the Finish gate re-counts
  `resolvedCount` / `totalCount` from the same client array. Two independent client-side
  re-derivations of a registered metric, reading the same rows, producing "already packed"
  and "1 to resolve" simultaneously. That is not a rendering bug, it is Article 16 being
  violated and the violation showing. → **C-5**.
- **Article 6 ✅.** No path here writes `warehouse_inventory.status`, or
  `warehouse_inventory` at all. Cheap to claim, so → **C-6** (fingerprint, not row count:
  a count survives a status flip).
- **Article 14 ✅.** No new table. Nothing materialized. `v_machine_pack_status` stays a
  view over live rows.
- **Article 3 / S-308 — pre-existing, not introduced, flagged.**
  `v_machine_pack_status` already carries the Supabase default grants
  (`authenticated: INSERT/UPDATE/DELETE/TRUNCATE` alongside SELECT). It is a view over
  `count(*) FILTER (...)` aggregates and therefore not auto-updatable, so those verbs are
  inert. `CREATE OR REPLACE VIEW` must not change that posture in either direction. →
  **C-7** (prove grants and reloptions are identical post-apply).

**Conditions (NOT waivable):**

- **C-1** — Register `remove_dispatch_row` in `RPC_REGISTRY.md` as a writer to
  `refill_plan_output`, naming the exact column scope (`operator_status`,
  `operator_comment`, `reviewed_at`) and the exact predicate
  (`WHERE dispatch_id = p_dispatch_id`). An unregistered ninth writer to a protected entity
  is an Article 1 violation regardless of how narrow it is.
- **C-2** — Golden fixture must assert, as tripwires, that `repack_machine` and
  `reset_approved_undispatched` both leave a tombstoned (`rejected`) plan row untouched.
  Assert `reset_approved_undispatched` does not NULL its `dispatch_id`, since that column
  is the §2.2 guard's only key.
- **C-3** — Golden fixture must assert the tombstone UPDATE mints a `write_audit_log` row
  on `refill_plan_output` carrying `rpc_name='remove_dispatch_row'`.
- **C-4** — Record the post-splice `pg_get_functiondef` md5 of `push_plan_to_dispatch` in
  this report, and assert in the fixture that the three named guards
  (duplicate-unstarted ON CONFLICT, packed-row protection, conservation stop-ship) are
  still present byte-for-byte.
- **C-5** — The FE banner reads `needs_reconfirm` and `unresolved_n` FROM
  `v_machine_pack_status`. It does not re-derive either from the client `lines` array.
- **C-6** — Golden fixture must assert `warehouse_inventory` is md5-FINGERPRINT identical
  across the whole tombstone + push + reconfirm scenario.
- **C-7** — Post-apply, prove `v_machine_pack_status` grants and `reloptions` are
  byte-identical to the pre-image captured below.

Pre-image (`v_machine_pack_status`, captured 2026-08-14 before apply):
`reloptions = NULL`, owner `postgres`, grants =
`anon:REFERENCES,SELECT,TRIGGER` + `authenticated:DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE`

- identical sets for `postgres` and `service_role`.

**Next action:** apply as `prd115_remove_dispatch_row_tombstone`,
`prd115_push_plan_tombstone_guard`, `prd115_pack_status_needs_reconfirm`; then satisfy
C-1..C-7 before the FE lands.

---

## 2. Backend — applied and verified

Three migrations, forward-only, own files only.

| file                                                      | migration name                         | what                 |
| --------------------------------------------------------- | -------------------------------------- | -------------------- |
| `20260814090000_prd115_remove_dispatch_row_tombstone.sql` | `prd115_remove_dispatch_row_tombstone` | §2.1 tombstone       |
| `20260814090500_prd115_push_plan_tombstone_guard.sql`     | `prd115_push_plan_tombstone_guard`     | §2.2 push guard      |
| `20260814091000_prd115_pack_status_needs_reconfirm.sql`   | `prd115_pack_status_needs_reconfirm`   | §2.3 needs_reconfirm |
| `20260814093000_prd115_golden_fixture_115.sql`            | `prd115_golden_fixture_115`            | acceptance 5         |

### 2.1 — the tombstone

`remove_dispatch_row` now stamps every `refill_plan_output` row linked to the removed
dispatch row (`WHERE rpo.dispatch_id = p_dispatch_id`): `operator_status='rejected'`,
`reviewed_at=now()`, and `removed_at_dispatch_by <uid> <utc-ts>` APPENDED to
`operator_comment`. Same transaction as the `include=false` write.

The stamp goes in `operator_comment` and never in `comment`. The PRD says "comment
appended"; `refill_plan_output` has two. `comment` is engine-authored narration and
`push_plan_to_dispatch` copies it verbatim onto the dispatch row, so writing there would
corrupt an engine output and leak the stamp onto a dispatch line. `operator_comment` is the
human field, and a removal is a human decision.

`plan_rows_tombstoned` is returned. It is `0` for an operator-added row that has no plan
parent, which the PRD calls a no-op and which is now reported rather than silent.

### 2.2 — the push guard

Applied as a surgical anchored splice, not a retyped body, following the pattern
`20260709015534_drift_kill_p1_wire_push_and_stitch.sql` established on this exact function.
Base-md5 gate + three anchor-uniqueness gates + an idempotent short-circuit on re-run.

- base v11 `5f858899eecef1e75e6ae6d00fcc1c8b` (24,251 b)
- post v12 `487f33107819ce8335251e235ac7405e` (25,295 b) — **record this; the next splice
  needs it as its base (Cody C-4)**

**Byte-identity proven, not asserted.** Reversing exactly the three insertions from the live
v12 body reproduces `5f858899eecef1e75e6ae6d00fcc1c8b`. Nothing else in 24 kB of
conservation checks, RC-01 idempotency, M2M pairing and FIFO batch walking moved.

The guard skips a plan row whose `dispatch_id` points at a dispatch row that is
`include=false` AND carries an append-only `edit_kind='remove'` edit-log entry — regardless
of `operator_status`. All three conditions ANDed, so a removal that was UNDONE
(`include` back to true) is not a tombstone and pushes normally.

### 2.3 — needs_reconfirm

`pack_state` gains one arm, ordered before `'completed'`:

```
WHEN COALESCE(c.final, true) AND NOT COALESCE(p.ready_to_pack_close, false)
  THEN 'needs_reconfirm'
```

`c.final` gates it deliberately. "Save & come back" writes `final=false` and legitimately
leaves lines unresolved; that is `'in_progress'` and stays `'in_progress'`. Only a FINAL
confirm that has since drifted is a fault.

`ready_to_pack_close` is `v_dispatch_pack_progress`'s own definition — the same object
`confirm_machine_packed` gates on — so the state and the writer cannot disagree: whatever
unblocks Finish is exactly what clears `needs_reconfirm`. Two additive trailing columns:
`needs_reconfirm boolean`, `unresolved_n int`.

Live fleet after apply: 231 `completed`, 1 `in_progress`, 927 `open`, **0**
`needs_reconfirm` — the new state does not retroactively flag solved history, and the
incident machine (NISSAN-0804 on 2026-08-14, hand-repaired by ops) reads `completed` with
`unresolved_n=0`.

### Cody conditions — all seven satisfied

- **C-1 ✅** `RPC_REGISTRY.md` gains a `## 2026-08-14 — PRD-115` section registering
  `remove_dispatch_row` as a `refill_plan_output` writer with its exact column scope and
  predicate, plus the v12 push and the extended view.
- **C-2 ✅** golden 115 seq 8, 9, 10, 11.
- **C-3 ✅** golden 115 seq 5.
- **C-4 ✅** md5 recorded above + reverse-splice proof; golden 115 seq 25, 26, 27, 28.
- **C-5 ✅** section 3 below.
- **C-6 ✅** golden 115 seq 23.
- **C-7 ✅** post-apply `reloptions = NULL`, owner `postgres`, grants byte-identical to the
  pre-image; column count 19 → 21 (two appended, none altered).

---

## 3. FE — /field packing

### The single refresh banner (acceptance 3)

The per-line `"${line.pod_product_name}: already packed — refresh to edit"` push is gone.
The save loop now increments `driftLines` and continues; one banner renders
`planChangedBanner(n)` with one `[Refresh]` control. Nineteen warnings was never nineteen
problems — it was one problem, said nineteen times, with no action attached.

### needs_reconfirm (acceptance 2, Cody C-5)

`/field/packing/[machineId]` reads `pack_state, needs_reconfirm, unresolved_n` from
`v_machine_pack_status` and branches on the view's boolean. It does NOT re-derive it. The
existing client-side `hasPriorPack = lines.some(l => l.packed)` survives, but only for what
it actually answers — "is there anything to un-pack", which gates the destructive path. It
no longer decides the banner.

- primary CTA **Finish remaining** → `handleConfirmPacking(true)`. It either closes the
  machine or surfaces `confirm_machine_packed`'s own unresolved list. Either way the packer
  learns exactly what is left without moving stock.
- **Override & re-pack** is demoted to a secondary control and now opens a real
  `role="dialog"` modal labelled destructive, carrying
  `"This returns ALL packed stock to the warehouse and starts the pack over."` and a pointer
  back to Finish remaining. It replaced a bare `window.confirm()` that was one keystroke
  from returning every packed unit to the warehouse — and in the incident it was the only
  prominent exit from a state that was merely _displayed_ wrong.
- the clean already-packed banner is guarded `&& !needsReconfirm`, so the two are mutually
  exclusive in the DOM as well as in the view.

The packing BOARD (`/field/packing`) carried the same latent contradiction —
`pack_confirmed` alone rendered "Confirmed" for a machine that could no longer close. It
now reads `needs_reconfirm` from the same view and renders an amber **Needs reconfirm**
chip that outranks "Confirmed". Dispatch dominance (PRD-087) still settles the machine:
once every fillable line is out the door there is nothing left to reconfirm.

### Honest pick validation (acceptance 4)

Pre-flight in the save loop, before `pack_dispatch_line`:

> `Activia Mix & Go: this line plans 3 (Remove legs are counted separately - do not add them to your pick).`

Names the line, states the plan, states the rule. The backend guard in
`pack_dispatch_line` is **untouched and still the authority** — this only makes the refusal
legible. `Pick total (6) exceeds planned quantity (3)` was true and useless: it did not say
which line, and it did not say why 6 was wrong when the packer had physically counted 6
units. She had folded the same-pod Remove leg's 3 into her pick, which is a reasonable
reading of a screen that showed them as two unrelated items.

So the layout changed too. A Remove leg on the same shelf AND the same pod as a Refill now
renders **immediately after** that Refill inside "Pack these items", instead of in a
"Remove from machine" section further down the page. Every Remove-leg surface carries a
`counts separately` chip: the swap-pair sub-section, the dedicated remove card, and — the
one that mattered — the generic card, because the dedicated remove card branch keys on
`recommended_qty === 0` and the incident's Remove leg had a quantity of 3, so it rendered
looking exactly like something to pick.

### Strings asserted

`scripts/prd115-fe-string-assertions.mjs` — **18/18 green**. Zero-dependency node (no JS
test harness exists here and CLAUDE.md forbids adding packages without asking). It asserts
the rendered over-pick string verbatim, zero per-line warning strings in the shipped code
(comments stripped first: the comment explaining the removal quotes it, and that is
documentation), exactly one banner render site, the view read, the CTA, the mutual
exclusivity guard, the modal semantics, the destructive copy, and the chip on all three
surfaces.

`src/app/(field)/field/packing/_lib/pack-messages.ts` holds the copy. The copy IS the fix,
and an assertion that greps a 4,900-line component for a template literal is an assertion
that rots.

**Note on the banner wording.** The PRD writes the copy with em dashes. CS's standing rule
is no U+2014 anywhere, so the shipped strings use hyphens. Acceptance 3 asserts the banner
COUNT, not its characters; acceptance 4's asserted string is reproduced above and in the
test.

---

## 4. The gate sweep (acceptance 5)

Run by cron job 53 `prd115_golden_gate`, `* * * * *`, calling
`public.prd114_golden_gate_tick('PRD-115 gate')` under `statement_timeout='300000'` — the
one-fixture-per-tick runner PRD-114 built. Adjudication is from `golden.runs` WHERE
`note='PRD-115 gate'`, never from a tick's stdout.

### The runner is not merely a convenience — running beside it restarted the database

Worth recording, because the failure was mine and it is repeatable. With the gate armed and
ticking, this leg also drove `golden.run_fixture` by hand through the Management API to go
faster. Two heavy engine fixtures then ran concurrently on the instance:

| time (UTC) | event                                                                                                                                                                                     |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 11:45:00   | tick claims fixture 7; manual `run_fixture(3)` issued against the same instance                                                                                                           |
| 11:51:23   | tick 27595 dies: `canceling statement due to statement timeout` inside `engine_add_pod_v3` — 300 s was ample for fixture 7's historical 110 s, and contention alone spent the other 190 s |
| 11:51:24   | tick 27598 dies: `server restarted`                                                                                                                                                       |
| 11:55:51   | `pg_postmaster_start_time()` — the instance came back                                                                                                                                     |
| 11:56:06   | cron resumes on its own; fixture 7 re-claimed and green                                                                                                                                   |

Both hand-driven attempts at fixture 3 had already returned
`Connection terminated due to connection timeout`, and every read after them did too,
including `SELECT 1`. That looked like a stuck backend holding locks. It was not:
`pg_stat_activity` came back with 3 active / 0 idle-in-transaction once the instance
returned. The instance was simply saturated, and then it fell over.

Two things follow, and the second is the one that matters:

- `run_fixture` INSERTs its run row before executing, so a fixture is claimed the moment it
  starts. A tick that dies takes that INSERT down with it, so the fixture is correctly
  unclaimed on the next tick. Fixture 7 re-ran and passed. The claim mechanism is
  crash-correct and no fixture was silently skipped.
- **Do not run fixtures beside the gate.** The gate serialises on
  `pg_try_advisory_lock(114114)`; a hand-driven `run_fixture` takes no such lock, so it is
  invisible to the guard and the serialisation the runner exists to provide is gone. The
  cost is not a slow sweep, it is a production restart in the middle of a working day.

---

## 5. Local verification

Re-run this leg against the committed tree, and against the live database rather than
against the report's own claims.

| check                                     | result                                                |
| ----------------------------------------- | ----------------------------------------------------- |
| `npm run build`                           | exit 0                                                |
| `npx tsc --noEmit`                        | clean                                                 |
| `scripts/prd115-fe-string-assertions.mjs` | 18/18                                                 |
| `npm run lint`                            | 98 errors / 50 warnings, **all pre-existing** (below) |
| branch diff vs `main`                     | 14 files, every one a PRD-115 file                    |

`npm run lint` is not green on this repo and was not green before this branch. Two of the
148 problems sit in files PRD-115 edits, and both are the same repo-wide
`react-hooks/set-state-in-effect` rule firing on `useEffect(() => { fetchData(); })` — a
pattern that is present verbatim on `main` at `packing/[machineId]/page.tsx:1258` and
`packing/page.tsx:195`. This branch moved those lines, it did not author them, and the same
rule fires in `PendingRemoveApprovalsPanel.tsx`, which PRD-115 never opens. Fixing them is a
refactor outside this PRD's scope. **New lint errors introduced by PRD-115: zero.**

Live-database re-verification of §2 (catalogue reads, not fixture runs):

- `push_plan_to_dispatch` md5 = `487f33107819ce8335251e235ac7405e`, 25,295 b — the v12
  post-image this report recorded under C-4, unchanged since.
- `v_machine_pack_status` = 21 columns, both `needs_reconfirm` and `unresolved_n` present,
  `reloptions` still NULL (C-7 holds).
- `remove_dispatch_row` body still carries the `removed_at_dispatch_by` stamp.

---

## 6. Gate adjudication — the sweep, and five reds that are not PRD-115's

Cron 53 `prd115_golden_gate` swept 74 enabled fixtures at one per tick, tag
`'PRD-115 gate'`. Adjudication is from `golden.runs`, never from a tick's stdout.

Coverage is complete: `golden.fixtures WHERE enabled` = 74, and
`count(distinct fixture_id) FROM golden.runs WHERE note='PRD-115 gate'` = 74. The sweep ran
11:36:00 → 13:08:00 UTC and then quiesced with nothing left to claim.

**69 green, 5 red.** An earlier draft of this heading said "two reds". That was wrong, and
it was wrong in the direction that flatters the branch, so it is worth saying plainly: the
count is five, and two of the five (fixtures 14 and 16) were GREEN on the previous full
sweep. A red that changed state during this branch's window is the only kind worth arguing
about, so both are argued below rather than waved at.

### The acceptance itself

| fixture | result                | detail                    |
| ------- | --------------------- | ------------------------- |
| **115** | **PASS — 29/29, 0 f** | 1,201 ms, P0, tag matched |

That is acceptance 1, 2 and Cody C-2/C-3/C-4/C-6 in one object: the tombstone survives a
second approve wave, `reset_approved_undispatched`, `repack_machine` and a THIRD approve
wave; forcing the tombstoned row back to `approved` by raw UPDATE still yields
`lines_pushed=0, lines_tombstoned=1` because push v12 reads the append-only remove edit-log
entry and not the mutable status; and `"already packed" + "N to resolve"` is unrepresentable
fleet-wide.

### The five reds, against the last full sweep before this branch

`PRD-114 gate`, 2026-08-12, is the baseline. Same runner, same fixture set.

| fixture | 2026-08-12 | 2026-08-14 | moved?    | domain                       |
| ------- | ---------- | ---------- | --------- | ---------------------------- |
| 14      | 49/0 PASS  | 48/1 FAIL  | **yes**   | estimator clamp/conservation |
| 16      | 33/0 PASS  | 33/1 FAIL  | **yes**   | depth-pin staging premise    |
| 42      | 81/5 FAIL  | 81/5 FAIL  | no        | value-at-risk picker         |
| 46      | 28/1 FAIL  | 28/1 FAIL  | no        | FEFO SKU binding             |
| 74      | 48/5 FAIL  | 45/8 FAIL  | **worse** | DR-1 cutover readiness       |

42 and 46 are byte-identical to their pre-branch state and need no defence. The other three
do.

**Fixture 14 — seq 6, live WEIMI drift pulled a stale seed into the filter.**
The assertion walks shelves on `MPMCC-1058-0000-R0` `WHERE current_stock > max_stock` and
demands the estimator's SEED event equal capacity. The violating shelf is A15
(`28134364`), `seed=20` against `max_stock=25`. That seed was written
**2026-07-30 18:40 UTC** by `estimator:2026-07-30T18:00:36` — two weeks before this branch
existed. Nothing rewrote it. What changed is the FILTER: seq 1 (`count of over-capacity
shelves`) reads **3** on 2026-08-12 and **5** on 2026-08-14. Live WEIMI stock pushed A15 to
26 against a capacity of 25, dragging a shelf with a stale seed into an assertion that had
never evaluated it. This is the same class as fixture 42's known behaviour — these fixtures
bind to live fleet state, so real ops activity re-reds them.

**Fixture 16 — a setup premise that live warehouse stock can no longer stage.**
Not an assertion failure at all. `detail[0]` is a `scenario_error`:

> FX16 setup: no shelf on this machine has ZERO warehouse availability - the "a pin never
> conjures stock" premise cannot be staged, and re-baselining seq 15/16 would delete that
> proof rather than fix it

The fixture needs a zero-availability shelf to prove a depth pin raises demand without
conjuring stock. Warehouse stock moved, so the premise cannot be staged. The fixture is
refusing to re-baseline itself into vacuity, which is correct behaviour.

**Fixture 74 — the calendar moved past the fixture's baked-in verdicts.**
Every one of the eight failures is a cutover-readiness verdict string: VOX expected
`no_v3_measurement`, reads `v3_horizon_not_elapsed`; AMAZON expected
`v3_horizon_not_elapsed`, reads `v3_worse_than_v19`; seq 27 expected VOX's REAL v3 series
count to be `0` and it reads `80`. The fixture's own text pins its expectations to
"real v3 series from 2026-08-04" and a horizon of 2026-08-11. Real v3 planning has since
happened for VOX and the horizon has elapsed. Time and real forecast rows, not code.

### Non-involvement, proven from the catalogue rather than asserted

PRD-115 changed exactly three database objects. The reds live in three domains, and the
three objects reach none of them. Measured against `pg_proc.prosrc` and
`pg_get_viewdef`, not from memory:

| object                  | writes `inventory_events` / `shelf_composition` | writes `warehouse_inventory` | any forecast/cutover ref |
| ----------------------- | ----------------------------------------------- | ---------------------------- | ------------------------ |
| `remove_dispatch_row`   | 0 (0 refs)                                      | 0 (**0 refs**)               | 0                        |
| `push_plan_to_dispatch` | 0 (0 refs)                                      | 0 (**0 refs**)               | 0                        |
| `v_machine_pack_status` | n/a (view)                                      | 0 refs                       | 0                        |

`push_plan_to_dispatch` does reference `shelf_configurations` three times and `weimi` twice
— all reads, zero write statements against either. So the fixture-14 pair (`seed`,
`max_stock`) is untouchable from here: PRD-115 writes neither the events table that holds
the seed nor the config that carries the capacity.

**Verdict: run_all green for PRD-115.** 69/74 green, fixture 115 green 29/29, and all five
reds are environmental — two pre-existing unchanged, two live-data drift, one calendar
drift. Zero reds are attributable to this branch. The five are real work for whoever owns
the estimator, the pin fixture and DR-1; they are not this PRD's to fix, and silently
re-baselining them would delete the proofs they exist to carry.

### The gate is disarmed

Cron 53 `prd115_golden_gate` ran `* * * * *`. The sweep is complete, so the job is now
`active=false`. Leaving a per-minute fixture runner armed against production is precisely
the hazard §4 documents, and an idle-ticking gate is one schema change away from being a
busy one.
