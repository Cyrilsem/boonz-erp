# PRD-114 - Dispatch list: "Sanity checks - expired products" - build report

Branch `prd-114-visit-checklist`. Started 2026-08-12, after the PRD-003 relay exited `## PRD-003 DONE`.

The PRD title carries an em dash. This repo's rule is no U+2014 anywhere, code comments and UI
strings included (PRD-003 leg 5 fixed 47 of them). Every string this PRD authors - the category
heading the driver reads included - uses an ASCII hyphen. The PRD document itself is CS's and is
left as written.

---

## Leg 1 - 2026-08-12 - backend

### What was built, in the order the PRD asks for it

| #   | object                                                                                                      | kind                                             | file                                                     |
| --- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------- |
| 1   | `get_expiry_sanity_checks(uuid)`                                                                            | read RPC, SECURITY DEFINER, STABLE               | `20260812221900_prd114_get_expiry_sanity_checks.sql`     |
| 2   | `day_close_events.kind` += `expiry_check`, partial unique index, `record_expiry_check(uuid,text,date,uuid)` | writer (day_close_events only)                   | `20260812222400_prd114_expiry_check_kind_and_writer.sql` |
| 3   | `acknowledge_day_close_event(uuid,text)` + `expiry_check` branch                                            | writer (delegates to the existing archival path) | `20260812223000_prd114_acknowledge_expiry_check.sql`     |

All three applied to production via `apply_migration`, and the migration files carry the same text.

### The read RPC (§3.1)

Candidate rule, verbatim from §2: `status='Active' AND coalesce(current_stock,0)>0 AND
expiration_date <= today(Dubai)+7`. `severity` is `expired` when the date is strictly behind today
(Dubai) and `expiring` otherwise, so a batch expiring TODAY is amber, not red - §3.1 words the amber
band as `today..today+7`.

Ordering is expired-first, then soonest, then shelf code. The shelf tiebreak is not cosmetic: it is
what lets the driver walk the machine in one direction instead of hopping aisles.

Reads `pod_inventory` directly, per §4.5. That is a deliberate divergence from the canonical expiry
object and it is the one thing Cody made conditional - see C-1 below.

Live proof, as the real `field_staff` driver (`bddaec3c`), against `WH2-2001-3000-O1`:

| shelf | product                                    | qty | expiry     | days | severity |
| ----- | ------------------------------------------ | --- | ---------- | ---- | -------- |
| A05   | Kinder Delice - Cake                       | 21  | 2026-05-05 | -99  | expired  |
| A03   | Santiveri - Coco Quinoa                    | 6   | 2026-06-12 | -61  | expired  |
| B09   | McVities Digestive Nibbles - Choco Caramel | 5   | 2026-06-23 | -50  | expired  |
| A07   | Vitamin Well - Hydrate                     | 13  | 2026-06-28 | -45  | expired  |
| B04   | Nutella - Biscuit T12                      | 5   | 2026-07-29 | -14  | expired  |
| B08   | Benlian Chips - Sour Cream                 | 5   | 2026-08-12 | 0    | expiring |
| B05   | Be-kind Cluster - Peanut Butter            | 6   | 2026-08-18 | 6    | expiring |

Seven rows, five red and two amber, on one real machine. The fleet carries 14 candidates and 5
expired right now, across 6 machines - so this category is not a hypothetical screen.

ACL after apply: `{postgres=X/postgres, authenticated=X/postgres, service_role=X/postgres}`. No
`anon`, no `PUBLIC`. A new function is born EXECUTE-to-PUBLIC (the PRD-113 finding), so the revoke
is written explicitly rather than assumed.

### The disposition writer (§3.2)

`record_expiry_check(p_pod_inventory_id, p_outcome, p_event_date, p_actor)`.

It writes ONE `day_close_events` row and nothing else. `pod_inventory` is read under a
`SELECT ... FOR UPDATE` row lock - a lock, not a write; it serializes two taps on the same batch and
trips no write guard.

Decisions worth recording:

- **Severity is recomputed in the backend from the ledger and the real clock.** The client sends an
  outcome, never a severity. The red/amber rule is therefore a backend fact and an FE bug cannot
  turn a red row amber to unlock the Exists chip.
- **Expired takes `sold` or `remove` only.** §3.2's "it cannot exist and stay" is enforced in SQL,
  not just by which chips the FE renders.
- **Re-tap UPDATEs the same event.** Acceptance 2 asks for exactly one event per row, updated in
  place. A partial unique index on `(event_date, payload->>'pod_inventory_id') WHERE kind =
'expiry_check'` makes that a guarantee rather than an intention: two concurrent taps cannot both
  insert.
- **An acknowledged check is locked**, refused by name pointing the driver at the office.
- **Closed days are refused**, matching `driver_substitute_dispatch_line`. `p_event_date` defaults
  to today (Dubai) and pack-ahead dates (PRD-111) are allowed.

### Acknowledge (§3.3)

The PRD-112 substitution branch is carried byte-for-byte; the new work is one `ELSIF`.

| outcome | what fires                                                                  | pod_action          |
| ------- | --------------------------------------------------------------------------- | ------------------- |
| Remove  | `backfill_archive_pod_inventory_row(pod, 'expired_writeoff', NULL, caller)` | `expired_writeoff`  |
| Sold    | same writer, reason `sold_through_<event_date>`                             | `sold_through`      |
| Exists  | nothing; `verified_at` + `verified_by` stamped into the payload             | `verified_no_write` |
| Skip    | nothing                                                                     | `skipped_no_write`  |

No new `pod_inventory` writer was created. `backfill_archive_pod_inventory_row` is the existing
registered archival writer and it is called, not copied. A batch already `Inactive` returns
`already_archived` and is NOT re-archived - re-archiving would overwrite a truer `removal_reason`
(the sweep's, or a manual one) with ours.

`removal_reason` is set to exactly `expired_writeoff` / `sold_through_<date>` as §3.3 words it. The
audit context lives in the event payload and `app.mutation_reason`, not smuggled into the reason
string, so an equality read of that column still means what the PRD says it means.

### End-to-end probe on live data, unwound

Run as one `DO` block that writes, measures, then `RAISE`s so the transaction unwinds - the PRD-003
T11 pattern. Driver taps as `field_staff`, acknowledges as `operator_admin`.

| measure                                              | result                                                                                           |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Remove tap on an expired batch                       | `ok`, severity `expired`, one event                                                              |
| Sold tap on a second expired batch                   | `ok`, one event                                                                                  |
| Exists tap on an amber batch, then re-tapped to Skip | same `event_id` both times, `updated=true` on the second                                         |
| `exists` on an EXPIRED batch                         | refused: `an EXPIRED batch takes sold or remove only (got exists) - it cannot stay on the shelf` |
| events written for the date                          | **3** - one per batch, no duplicate from the re-tap                                              |
| acknowledge Remove                                   | `pod_action=expired_writeoff`, batch `Active/21` -> `Inactive/expired_writeoff/0`                |
| acknowledge Remove **again**                         | `already_acknowledged=true`, no second write                                                     |
| acknowledge Sold                                     | `pod_action=sold_through`, reason `sold_through_2026-08-12`                                      |
| acknowledge Skip                                     | `pod_action=skipped_no_write`, `pod_result` null                                                 |
| `warehouse_inventory` Active rows                    | 324 -> 324                                                                                       |

Verified after the unwind: `day_close_events` carries **0** rows of kind `expiry_check`, the probed
batch is back to `Active / 21`, `warehouse_inventory` Active is 324. Production carries nothing from
this test.

---

## Cody constitutional review

Cody was run against all three migrations. **Verdict: approve with revisions - seven conditions,
none waivable.** Articles checked: 1, 3, 4, 5, 6, 8, 12, 14, 16.

The findings, in Cody's order. **Article 4** passes on both new functions: anon is refused BY NAME as
its own statement rather than folded into the role test (the D-41/D-42 short-circuit class), roles
are checked against `user_profiles`, `search_path` is pinned, the read RPC is `STABLE` and contains
no write statement, and the writer sets `app.via_rpc` + `app.rpc_name`. Cody recorded one privilege
observation rather than a block: `get_expiry_sanity_checks` is `DEFINER` where `INVOKER` would have
sufficed, because `pod_inventory` already carries `authenticated_read_inventory_pod USING (true)` -
accepted on the `get_machine_expiry_detail` precedent and on the explicit role gate being stricter
than the policy, but recorded so it is not later cited as the house default. **Article 1** passes in
its strongest form: PRD-114 creates **zero** new `pod_inventory` writers and delegates to a
registered one. Cody noted that a third body already writes this same Active->Inactive transition
(`driver_confirm_expired_removal`, keyed on a `pod_inventory_edits` row queued by
`sweep_expired_inventory`); PRD-114 cannot reach it - there is no edit row in this flow - and
correctly does not invent one. Two entry points converging on one writer is legal; a fourth body
would not be. **Article 6** is satisfied - no branch names `warehouse_inventory`, let alone
`.status` - but Cody refused to accept the 324->324 row count as the proof, which became C-3.
**Articles 3, 5, 8, 12, 14** all pass: no write verb is granted to `authenticated`; the
`pod_inventory` status transition goes through an RPC rather than an FE flip; `tg_audit_day_close_events`
fires `AFTER ... FOR EACH ROW` and therefore before the writer clears its GUCs, and the
`pod_inventory` write carries `app.via_rpc` from the archival writer; the migrations are new files
using `CREATE OR REPLACE` with no edit-in-place; and there is no new table, snapshot or cron.

**Article 16 is the finding that mattered.** `v_machine_expiry_summary` over
`v_machine_expiry_batches` is the registered canonical object for machine expiry
(`METRICS_REGISTRY.md:32`), and the retired-list on that very row records that the detail and slots
RPCs were _realigned off `pod_inventory` onto the batches view_. `get_expiry_sanity_checks` reads
`pod_inventory` directly, which is what §4.5 instructs. Cody granted it, and the reason is specific
rather than deferential: the canonical batches view dedupes to one row per
`(machine, COALESCE(shelf,'noshelf'), boonz_product_id)` and takes the `MIN` expiry, so building the
checklist on it would **silently drop sibling batches the driver has to physically pick up**. A
worklist at batch grain is a different question from a count at machine grain - the same disjointness
`v_expiry_action_queue` was granted at `METRICS_REGISTRY.md:137`. Granted on that precedent, and
conditional on it being written down (C-1).

### The seven conditions, and how each was discharged

| #   | condition                                                                                                       | discharge                                                                                                     |
| --- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| C-1 | Art. 16 - register the new RPC as DISJOINT from the canonical expiry object; it must never publish a count      | `METRICS_REGISTRY.md` row added, `v_expiry_action_queue` precedent cited; RPC returns rows only, no aggregate |
| C-2 | Art. 4 - `record_expiry_check` clears the writer GUCs on exit; document it as a leaf writer and pin the residue | body comment + fixture 114 seq 21 asserts `app.via_rpc` UNSET after it returns                                |
| C-3 | Art. 6 - prove `warehouse_inventory` untouched by fingerprint, not row count                                    | fixture 114 seq 18 pins an md5 over `status` + `warehouse_stock` across the acknowledge                       |
| C-4 | Art. 1 - record the second caller of `backfill_archive_pod_inventory_row` and register both new RPCs            | `RPC_REGISTRY.md` updated                                                                                     |
| C-5 | Art. 3 - FE reaches both surfaces only through the RPCs; pin the ACLs                                           | fixture 114 seq 19/20 pin `anon`=none and zero write verbs for `authenticated`                                |
| C-6 | reachability - both refusals must be run tripwires, not code                                                    | fixture 114 seq 14/15/16/17                                                                                   |
| C-7 | Art. 4 - the `manager` refusal stays a refusal; do not widen the archival gate, do not make it a silent no-op   | left as a `RAISE`; gate on `backfill_archive_pod_inventory_row` untouched                                     |

Two items Cody flagged for CS, outside this PRD's scope, recorded so they are not lost:
`backfill_archive_pod_inventory_row` writes no `inventory_events` row, so the write-off is invisible
to movement truth under the eventual `pod_inventory` freeze (pre-existing, not introduced here); and
`sold_through_<date>` is a **new** `removal_reason` vocabulary word, so anything downstream that
parses that column needs to learn it.

---

## Leg 1 (cont.) - golden fixture 114, and the premise it falsified

Fixture 114 runs on `DATE '2030-01-01' + 114` = **2030-04-25**. No other fixture uses that date.

Two design notes worth keeping:

- **The two clocks are deliberately different.** `event_date` is the synthetic 2030 date, so these
  `day_close_events` can never collide with a live Day Close. `expiration_date` is anchored to the
  REAL Dubai clock (`today-30`, `today+3`, ...), because the 7-day window is measured against the
  real date. This is the PRD-113 lesson applied: a fixture that planted 2030 expiries would find
  every batch OUTSIDE the window and prove nothing.
- **The whole scenario runs inside one deliberately rolled-back subtransaction** and leaves ZERO
  rows. Stricter than fixture 112, which plants durable rows on its synthetic date, and necessary
  here: a permanently planted Active stock-bearing `pod_inventory` row would feed
  `v_machine_expiry_summary` and the refill engine with fiction on a real machine.

### ⛔ Seq 0 earned its place on the first run

The v1 fixture planted two Active batches of the **same product on the same shelf** to prove that
`v_machine_expiry_batches` collapses siblings and the checklist must not. The run came back
**4 pass / 22 fail**, and seq 0 said why:

> `duplicate key value violates unique constraint "idx_pod_inv_active_shelf"`

`idx_pod_inv_active_shelf` is `UNIQUE (machine_id, shelf_id, boonz_product_id) WHERE status='Active'`.
**A shelf-bound sibling pair cannot exist.** The scenario was not merely unproven, it was impossible,
and the grain argument that Cody's C-1 was granted on was false as I had written it. Without seq 0 -
the "did the scenario actually run" guard - the 22 reds would have been read as an implementation bug
and chased in the wrong place, since every count assertion was comparing against its `-1` sentinel.

Two further corrections fell out of the same check, both of which had been asserted from memory
rather than from the view body:

| claim as first written                                 | what `v_machine_expiry_batches` actually does                                |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- |
| "dedupes and then takes the `MIN` expiry"              | keeps `rn=1` by `snapshot_date DESC, pod_inventory_id` - the NEWEST SNAPSHOT |
| "a second batch of the same product on the same shelf" | impossible; the collapse only reaches `shelf_id IS NULL` rows                |

### The corrected justification for C-1, which is stronger than the original

A btree unique index treats NULLs as **distinct**, so `idx_pod_inv_active_shelf` does not constrain
off-shelf rows, while the view partitions on `COALESCE(shelf_id::text,'noshelf')`. So N off-shelf
batches of one product on one machine publish as ONE. Live count of that class today: **zero** -
PRD-059 cleaned 61 of them and PRD-105 RC-4 swept the tail. The collapse is therefore **inert in
production and structurally live**.

That is the honest reason the checklist reads the ledger: not that the canonical view is wrong today,
but that a resolution rule cannot promise never to return **fewer** rows than the ledger holds, and
on a safety worklist a silently hidden row is a pack of expired food left in a machine.
Over-inclusion is the correct failure mode here; silent omission is not.

The fixture now proves both halves rather than asserting one:

- **seq 4** plants the off-shelf pair and measures `rpc=2 / view=1`. The divergence, live.
- **seq 26** measures the shelf-bound set at `4/4`. The two surfaces agree everywhere else, so this
  is a **reconciled disjointness and not a fork**. Without seq 26, seq 4 would license one.
- **seq 27** pins the `idx_pod_inv_active_shelf` refusal itself, so a later leg reading only the C-1
  prose cannot rebuild the impossible test.

`METRICS_REGISTRY.md` carries the corrected mechanism, not the first draft.

### Fixture 114: 28 / 28 green

Adjudicated from `golden.runs`, never from the runner's stdout - the note in project memory is the
reason: a sweep's stdout is an assertion COUNT and reads identical for green and red.

| run                                       | passed   | n_pass | n_fail | duration |
| ----------------------------------------- | -------- | ------ | ------ | -------- |
| `PRD-114 leg1 v2 run`                     | **true** | **28** | **0**  | 129 ms   |
| `PRD-114 leg1 first run` (v1, superseded) | false    | 4      | 22     | 79 ms    |

Coverage: acceptance 1 (seq 1-6), acceptance 2 (seq 10, 24), acceptance 3 (seq 11-13, 18, 22, 23),
acceptance 4 (the fixture itself). Cody's conditions land at seq 4 + 26 (C-1), 21 (C-2), 18 (C-3),
19 + 20 (C-5), and 14-17 + 24 + 27 (C-6). Six tripwires, all reached and all refusing.

### Production carries nothing from the fixture

| probe                                          | after both runs      |
| ---------------------------------------------- | -------------------- |
| `day_close_events` rows of kind `expiry_check` | **0**                |
| `pod_inventory` Active + stock-bearing         | **1177** (unchanged) |
| `warehouse_inventory` Active                   | **324** (unchanged)  |

The one Active NULL-shelf row on the fixture's machine is dated **2026-05-10**, carries zero stock
and no expiry, and predates this PRD. It is not a leak.

Both fixture migration files are byte-verified against the database rather than assumed: the v2
`scenario_sql` md5 is `fcbb4bbeabb1c00bfe3bc9b9d0b46d64` in the file and in `golden.fixtures`. The
v1 file is left in place as the record of what ran first; v2 supersedes it forward-only via
`ON CONFLICT DO UPDATE`, per Article 12 and the PRD-003 rule that editing an applied migration is how
a file stops describing what actually ran.

---

## Leg 1 (cont.) - the FE

### One component, mounted on both surfaces the PRD names

`src/components/field/ExpirySanityChecks.tsx`, mounted AFTER the line list on
`/field/dispatching/[machineId]` (the trip line view) and `/field/packing/[machineId]`.

| behaviour    | as shipped                                                                       |
| ------------ | -------------------------------------------------------------------------------- |
| heading      | `Sanity checks - expired products`, same `h2` classes as the `Shelf A01` groups  |
| auto-expand  | whenever any `expired` row exists; amber-only stays collapsed                    |
| expired row  | red tint + `⚠ Expired` badge, chips **Sold / Remove** only                       |
| expiring row | amber tint + "expires in 3 days", chips **Exists / Sold / Remove / Skip**        |
| tap          | one `record_expiry_check` call; tap again to change until acknowledge locks it   |
| header chips | `N expired` + a `done/total` counter, so the driver can see the category is open |

Two RPCs and nothing else. The component never SELECTs `pod_inventory` and never writes
`day_close_events` by hand - it could not anyway, since `authenticated` holds no write verb on that
table (Cody C-5, pinned at fixture 114 seq 20).

There is deliberately **no confirm dialog**. A tap moves no stock; nothing it does is irreversible
before someone in the office looks at it. Confirm dialogs are for the acknowledge side.

### Decisions worth recording

- **`eventDate` follows the pack-ahead toggle on the packing page.** A check done while packing
  tomorrow's trip lands on tomorrow's Day Close, not today's. The dispatching page passes nothing and
  the backend defaults to today (Dubai).
- **The hydration read is filtered by `event_date`, and that filter is load-bearing.** Without it,
  yesterday's disposition on the same batch would render as today's answer.
- **An off-shelf batch renders "No shelf on record"** rather than an empty shelf label. Those rows
  are real stock with no slot, and they are exactly the class fixture 114 seq 4 exists for.
- ⛔ **A failed load renders the failure, not nothing.** The first cut returned `null` whenever
  `rows.length === 0`, which collapsed "this machine is clean" and "the checklist could not be read"
  into the same blank screen. On a safety list only one of those means there is nothing to check.
  This is the same reasoning that decided C-1: silent omission is the failure mode to design against.
- **Additive (§4.4).** A machine with no batch inside the window renders nothing at all, so the
  packing / pickup / dispatch flows are unchanged.

### Day Close (§3.3)

`expiry_check` rows sit under **Changes**, not Gaps - they are a thing the driver DID and CS
confirms, the same shape as a substitution, not a hole someone still has to chase. Red chip for
`expired`, amber for `expiring`, read off the event payload and never recomputed on the client.

Each outcome is named by its consequence rather than its enum, because CS is authorising a stock
write on two of the four:

| outcome  | label on the card                    |
| -------- | ------------------------------------ |
| `remove` | driver pulled it (write off)         |
| `sold`   | already sold through (close batch)   |
| `exists` | still on the shelf (no stock change) |
| `skip`   | skipped (no stock change)            |

`payload` was added to the `v_day_close_events` select for this; the view already exposed it.

### Verify gates

| gate               | result                                                                            |
| ------------------ | --------------------------------------------------------------------------------- |
| `npx tsc --noEmit` | clean, exit 0                                                                     |
| `npm run build`    | exit 0, compiled successfully                                                     |
| `npm run lint`     | **148 problems (98 errors, 50 warnings) - byte-identical to the `main` baseline** |

The lint number is measured, not assumed. The first cut of the component made it **149 / 99** by
adding one `react-hooks/set-state-in-effect` error; it was rewritten to the pure-loader shape
`DayCloseTab` and `RefillLogTab` already use (resolve into state from inside a `.then` rather than
awaiting in the effect body) and the count returned to the baseline. **PRD-114 adds no lint debt.**

Every string this PRD authored is ASCII: `git diff main` over the three edited pages returns **zero**
em dashes on added lines, and the component file contains none.

### Carried, not authored

The dispatching page diff includes a two-line prettier wrap inside PRD-113's
`internal_move_return_blocked` branch. It is content-free, and it is **not** revertible in any durable
sense: `npx prettier --check` on `main`'s copy of that file **fails**, so the reformat is what the
repo's own config produces and it returns on any touch. PRD-003 G-2 reverted it once and it came
back. Recorded here rather than reverted again.

---

## Leg 1 (cont.) - the full-suite gate

PRD-003 unscheduled its job 51 after its own sweep ("with every fixture claimed it would have
returned immediately forever"), so acceptance 5 needed the runner rebuilt. Same shape, same two
guards: an advisory lock so a slow fixture is not joined by the next tick, and a stand-down across
`:39-:42` because cron 44 rewrites `shelf_composition` at `:40` and six fixtures straddle it.

Scheduled as pg_cron job 52 `prd114_golden_gate`, one fixture per minute over 73 enabled fixtures.

### ⛔ The gate's own first run was vacuous, and Guard 3 is the only reason that was visible

The first cut called `golden.run_fixture(fx, tag, 'P0')`. `golden.run_all` does **not** do that - it
computes `GREATEST(COALESCE(p_phase,'P0'), config.current_phase, fixture.phase_required)`. Live,
`golden.config.current_phase` is **P4**, and fixture 1 is a **P3** fixture whose 59 assertions all sit
at that phase. Running it at `P0` **skipped every one of them**, and the run came back
`0 pass / 0 fail / passed = false`.

That is `run_fixture`'s Guard 3 - "a run that evaluated NOTHING is not a pass" - doing its job. It is
worth naming what it prevented: a gate that skipped every assertion in the suite would otherwise have
reported **73 fixtures with zero failures**, which is exactly the false green PRD-003 G-3 said was
worth more than any single red. Two harness bugs in two PRDs, both caught by a guard that exists only
to distrust the harness.

The tick function now computes the same expression `run_all` does. The vacuous run row was
**retagged** `PRD-114 gate VOID (phase bug, ran at P0)` rather than deleted, so the mistake stays in
`golden.runs` where the next reader will find it.

**Sweep status: IN FLIGHT.** Adjudicate from `golden.runs WHERE note='PRD-114 gate'` and from nothing
else - a sweep's stdout is an assertion COUNT and reads identical for green and red.
