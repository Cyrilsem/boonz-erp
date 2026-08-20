# PRD-113 — In-Machine Moves Are Not Returns + Expired Stock Never Auto-Consumed

Branch: `prd-113-internal-moves-expired-guard`
Started 2026-08-10. Report is append-only; each leg adds a section.

---

## Leg 1 — reconnaissance

### The incident, read off live data

`MC-2004-0100-O1`, plan `2026-08-07`. Two shelves swapped contents **inside one machine**:

| shelf       | Add New           | Remove             |
| ----------- | ----------------- | ------------------ |
| `6a0a2954…` | Coca Cola Zero ×8 | Pepsi Black ×1, ×1 |
| `702bca73…` | Pepsi Black ×6    | Coca Cola Zero ×3  |

Pepsi Black left shelf `6a0a…` and landed on `702bca73…`; Coke Zero did the reverse. Both
Remove legs therefore had an **Add New counterpart for the same product, on another shelf of
the same machine, in the same plan** — and both were sitting in the warehouse return queue.
That pairing is the detection rule the PRD asks for, and the live rows confirm it exactly.

The positive control is on the same plan: three `Machine To Warehouse` legs of Freakin
Protein Balls (4 + 3 + 3) with **no** Add New counterpart. Genuine returns; they must keep
queueing. Three other Remove legs (Tamreem Peach/Mango, Nutella Biscuit) likewise have no
counterpart and were correctly approved on 2026-08-07.

The three MC-2004 legs still carry the hand-fix comment
`" | PRD-113 class bug: in-machine move leg wrongly queued as warehouse return"` with
`wh_approved_at = 2026-08-08 15:49:10Z`. That neutralisation is what this PRD retires.

### The queue

`public.v_pending_wh_remove_confirmations` — `action='Remove'`,
`driver_confirmed_at IS NOT NULL`, `wh_approved_at IS NULL`, not `item_added`, not
`returned`, not `is_m2m`. `is_m2m` is the _cross-machine_ exclusion added by PRD-054-A /
PRD-070; there was no _same-machine_ concept at all. `monitor_stuck_remove_dispatches`
(cron 12) reads this same view, so fixing the view fixes the nag for free.
`cron_pending_return_alert` reads `v_pending_return_approvals`, a different
(`warehouse_inventory`) queue — out of scope, untouched.

Three RPCs credit the warehouse for a Remove leg: `wh_approve_remove_receipt`,
`wh_approve_remove_receipt_multivariant`, `approve_stuck_remove`. All three already carry a
PRD-070 `is_m2m` refusal; all three needed the same-machine sibling.

### The decrementer, and its complete call graph

    refresh-stage1 (edge fn v48, step "FIFO decrement... N processed")
      -> run_pod_inventory_decrement()          -- thin counter wrapper
        -> auto_decrement_pod_inventory()       -- the actual FIFO loop

`auto_decrement_pod_inventory` orders candidate batches
`expiration_date ASC NULLS LAST, snapshot_date ASC` with **no expiry filter at all**, so
expired batches are drained first. Verified 2026-08-10 across `cron.job` (48 jobs), the repo
(`src/`, `supabase/functions/`) and `pg_proc`: **no other caller exists**. There is exactly
one implementation, so the PRD's "cron parity — one shared implementation, not two copies"
holds by construction and one edit is the whole fix. `refresh-stage1` needs no redeploy.

### Golden baseline

71 enabled fixtures (P0 9 / P1 10 / P2 13 / P3 22 / P4 17). `golden.run_all` cannot be
driven through the MCP `execute_sql` channel — its statement timeout kills fixture 3
mid-engine-run and the whole `run_all` transaction rolls back, banking nothing. Per the
PRD-110 leg-138 lesson (S-250), fixtures are fired **one at a time** through
`/tmp/prd110_sql.sh` with `SET statement_timeout='600s'`, and adjudicated by reading
`golden.runs` back, never off the response body.

---

## Leg 1 — backend, drafted

Four additive migrations written; **not yet applied — Cody review is the gate.**

| file                                                                | what                                                                                                                               |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `20260810110000_prd113_a1_is_internal_move_column.sql`              | `refill_dispatching.is_internal_move boolean NOT NULL DEFAULT false` + partial pairing index                                       |
| `20260810110500_prd113_a2_internal_move_predicate_and_writer.sql`   | `is_internal_move_dispatch()` (the one definition), `mark_internal_move_legs()`, `tg_mark_internal_move_pair` AFTER INSERT trigger |
| `20260810111000_prd113_a3_return_queue_excludes_internal_moves.sql` | queue view exclusion + refusal in all three `approve` RPCs                                                                         |
| `20260810111500_prd113_a4_fifo_never_consumes_expired.sql`          | FIFO skips batches expired as of the Dubai date; overflow reported, never silent                                                   |

### Design note — why a trigger, not an edit to each writer

The PRD names four writer families. `stitch_pod_to_boonz` alone is 51 KB and
`push_plan_to_dispatch` 24 KB; re-emitting protected engine code to append one `PERFORM`
each is a large diff for no extra coverage. More decisive: **the pair is not knowable when
the Remove leg is inserted** — its Add New counterpart is normally written later in the same
batch. Only a post-insert pass can see both legs. The trigger is the codebase's own
established shape for this (`trg_flag_remove_with_transfer_intent`,
`trg_flag_multivariant_return_without_correction`), and it covers every writer that exists
today and every writer added tomorrow with one implementation.

The stored column is deliberately **not** the safety net. The queue view and all three
`approve` RPCs call the live predicate `is_internal_move_dispatch()`, so a leg the trigger
somehow missed still cannot produce a phantom warehouse credit.

### Design note — the false-positive direction, stated plainly

The pairing rule can misfire: a genuine return of product X could coincide with a
warehouse-sourced Add New of X on another shelf of the same machine, same day. The cost of
that misfire is an **uncredited** warehouse return (WH understated, reversible by clearing
one boolean); the cost of the opposite error is **phantom stock** (WH overstated, silently
wrong, the incident this PRD exists to stop). The asymmetry is chosen deliberately.

To keep it from being silent (LAW 5), every auto-flag lands a `monitoring_alerts` row
(`prd113_internal_move_flagged`) naming the leg, the machine, the product and the writer
that stamped it, with the instruction for reversing it.

### Repair report — 30-day expired consumption

Generated 2026-08-10 from `pod_inventory_audit_log` (`source='sale'`, `delta<0`) joined to
the batch's `expiration_date`. **3 batches, 14 units.** Full table in
`docs/prds/PRD-113-expired-consumption-report.md`. No automatic restoration; CS decides.

---

## Leg 1 — backend applied and proven

All four migrations applied to production and registered in
`supabase_migrations.schema_migrations` with versions matching the filenames exactly.

`ALTER TABLE ... ADD COLUMN` on a 37k-row table is metadata-only and instant; the
`CREATE INDEX` is not, and it blocked long enough to kill the first attempt. Applied with an
explicit `SET lock_timeout` so a lock wait fails fast instead of hanging the whole migration.

### Cody verdict — ⚠️ Approve with revisions, 7 conditions, none waivable

Articles checked: 1, 2, 3, 4, 5, 7, 8, 11, 12, 14, 15, 16. Knowledge base loaded in full.

Passing as drafted: Article 12 (all four idempotent and forward-only), Article 14 (a column,
not a table), Article 7 (A4 only INSERTs into the audit log), Article 11 (the no-cron-caller
claim independently verified across all 48 `cron.job` rows).

The seven conditions, all implemented **before** apply:

1. **Article 4 — `mark_internal_move_legs`.** A DEFINER writer on `refill_dispatching` that
   set neither `app.via_rpc` nor `app.rpc_name`, validated no caller role, and was granted to
   `authenticated`. Now sets both GUCs, validates role, and is registered in the
   `enforce_canonical_dispatch_write` allowlist — without that entry, its newly compliant
   write would have landed a `bypass_violation_log` row on every call.
2. **Article 4 — the trigger.** It set `app.via_trigger` but not `app.rpc_name`, so
   `write_audit_log` would have credited `stitch_pod_to_boonz` for a write it did not make.
   It now stamps its own name and restores the prior value (S-160; PRD-016B GUC leak).
3. **Least privilege — the predicate.** `refill_dispatching` carries
   `authenticated_read FOR SELECT` with `qual = true`, so `SECURITY DEFINER` bought nothing.
   Dropped to INVOKER.
4. **Articles 1 + 3 — the sharpest finding.** All three refusal messages instructed the
   operator to "clear `refill_dispatching.is_internal_move` on the leg". Verified live:
   `authenticated` holds table-level UPDATE on that table, and policy
   `field_and_warehouse_update_dispatch` passes five roles with `qual = true`. The
   instruction was **executable**, and it opened the exact credit gate this PRD exists to
   close. Replaced by canonical writer `clear_internal_move_flag(dispatch_id, reason)` —
   authenticated caller required, four roles, 10+ character reason, `warning`-level alert.
5. **Durability.** A cleared flag was re-stamped the moment another Add New landed, so the
   human override did not survive the trigger. `internal_move_cleared_at` /
   `internal_move_cleared_by` added; "a human has ruled" is now the FIRST branch of the
   predicate and a skip condition in both stamping writers.
6. **Article 16.** `is_internal_move_dispatch` registered in `METRICS_REGISTRY.md`.
7. **Article 15.** `CHANGELOG.md`, `MIGRATIONS_REGISTRY.md`, `RPC_REGISTRY.md` updated.

Recorded and explicitly **out of scope**: `refill_dispatching` grants `authenticated` full
table-level DML (the S-308 Supabase default) on top of that permissive UPDATE policy.
Pre-existing; closing it would break live FE writers. Logged so it is not rediscovered as new.

### Live smoke tests — every one inside a rolled-back subtransaction

Verified afterwards that nothing was left behind: 0 synthetic dispatch rows, 0 sales, 0
alerts, 0 flagged live legs.

| probe                                                                     | result                |
| ------------------------------------------------------------------------- | --------------------- |
| Add New arriving after its Remove stamps that Remove                      | ✅                    |
| Remove arriving after its Add New stamps itself                           | ✅                    |
| genuine Remove with no counterpart NOT flagged                            | ✅                    |
| genuine Remove still in the queue, still approvable, still credits        | ✅ `item_added` flips |
| flagged legs absent from the queue                                        | ✅                    |
| `wh_approve_remove_receipt` refuses, and names `clear_internal_move_flag` | ✅                    |
| `approve_stuck_remove` refuses identically (the back door)                | ✅                    |
| `clear_internal_move_flag` re-opens the leg; predicate honours it at once | ✅                    |
| a later Add New does NOT re-stamp a cleared leg                           | ✅                    |
| a reason under 10 characters is refused                                   | ✅                    |
| FIFO: expired batch keeps all 8 units, stays Active, 0 sale audit rows    | ✅                    |
| FIFO: non-expired batch drains to 0; sales settled; overflow alert raised | ✅                    |

**A red herring worth recording.** The first FIFO probe used the synthetic 2030 dates and
read like the OLD behaviour — the expired batch drained. The code was right and the fixture
was wrong: the expiry rule is anchored to the **real** current Dubai date, so
`expiration_date = 2030-04-01` is in the _future_ from 2026 and correctly ineligible for the
skip. Re-anchored to `CURRENT_DATE - 10`. This trap is written into the golden fixture's
notes, because any future edit that "tidies" those dates into `{{plan_date}}` arithmetic
silently disarms the whole expired-stock half of the fixture.

### Golden fixture 113 — 25/25 green, 221 ms, no scenario error

Fixture-20 pattern: the scenario RAISEs, so every synthetic dispatch row, pod batch, sale and
alert rolls back and only the observation blob survives (contrast fixture 112, which commits
its 2030 rows). Encodes the MC-2004 incident plus both positive controls — a Remove with no
counterpart and a genuine M2W — and asserts the credit path still ACCEPTS and credits a real
return, which is the assertion that would catch an over-broad rule.

---

## Leg 1 — FE

- **Problem 3 done.** The dead purple "🤖 Review All" button, its `handleReviewAll` handler
  and both of its state hooks are gone (4.5 KB). The "N machines reviewed by Claude" badge
  survives, minus its `reviewingAll` guard — `reviewResults` is also fed by the _working_
  per-machine review, so removing the badge would have deleted a live feature.
- **One FE helper, not three copies.** `isInternalMoveLeg` / `dispatchActionChip` live in
  `src/lib/dispatch-types.ts`. The backend flag is the authority; the FE never re-derives the
  pairing rule.
- **Display-only legacy backfill (PRD-113 fix 4)** is anchored on a shelf-code target
  (`A01`…`A99`). The live comment corpus also contains "Move to AstroLabs", "Move to IRIS",
  "Move to NOOK" — those are moves to another _venue_, genuine departures from the machine,
  and labelling them "Move within machine" would be exactly the wrong error.
- **Driver view** (`/field/dispatching/[machineId]`): an internal-move Remove renders
  `MOVE WITHIN MACHINE`, never REMOVE or RETURN; its paired Add New shows `Moved from A07`;
  the toggle reads "✓ Moved to its new shelf"; and the return confirm no longer promises a
  warehouse credit the backend now refuses.
- **Office dispatch detail** (`DailyDispatchingTab`): chip reads "Move within machine" with
  the explanation on hover. The move flag was added to the **group key** — without it an
  in-machine move and a genuine return of the same product on the same shelf collapse into
  one row and the operator reads one label for two different physical acts.
- **Packing page already had a pod-grain in-machine-move detector** (`internalMoveAddIds`,
  keyed on `pod_product_id`) that drives its layout and already shows a source shelf. It is a
  second derivation of the same idea at a different grain — Article 16 debt worth converging,
  but converging it means reworking the packing layout engine, which is beyond this PRD and
  is recorded rather than attempted.

`npx tsc --noEmit` clean. `npm run build` ✅ compiled successfully. `npm run lint`: 98 errors
on this branch and **98 on `main`** — no new lint errors.

---

## Leg 1 — A5: a hole I opened, found by the advisors and closed

`get_advisors(security)` run straight after A2 returned 810 lints. 809 are the fleet-wide
pre-existing families (338 + 270 identical `*_security_definer_function_executable` warnings
across every DEFINER function, 80 `security_definer_view` errors). Nine mention PRD-113
objects, and one of those nine is a **defect A2 introduced**.

Supabase grants `EXECUTE` on every new function to `PUBLIC` by default, so A2's explicit
`GRANT ... TO authenticated, service_role` was additive noise on top of a grant `anon`
already held. All three new functions were reachable unauthenticated at `/rest/v1/rpc/<name>`.

For `clear_internal_move_flag` that was only untidy — it refuses a NULL `auth.uid()`
outright. For `mark_internal_move_legs` it was real. Its role check read:

```sql
IF v_uid IS NOT NULL THEN ...check the role... END IF;
```

which trusts a NULL uid as "the service_role / cron context". **An `anon` caller also has
`auth.uid() = NULL`**, so an unauthenticated POST would have skipped the role check entirely
and relabelled dispatch legs on any plan date it chose — dropping every leg it flagged out of
the warehouse return queue. That is the same denial-of-credit this PRD is trying to make
impossible in the other direction. `tg_mark_internal_move_pair` was exposed too; calling a
trigger function over REST raises "trigger functions can only be called as triggers", so it
was never exploitable, but a trigger function has no business being an RPC endpoint.

`20260810140000_prd113_a5_close_anon_execute_on_new_writers.sql` fixes it **forward**
(Article 12 — A2 is not edited) with two independent layers, because either alone would be
luck rather than posture:

1. `REVOKE EXECUTE ... FROM PUBLIC, anon` on all three (and from `authenticated` on the
   trigger function).
2. The NULL-uid branch now names the roles it actually means — `current_user IN
('service_role','postgres','supabase_admin')` — so the guard holds even if a future
   migration re-grants EXECUTE. That is the S-308 lesson: a default grant comes back whenever
   someone is not looking.

Verified post-image:

| function                     | EXECUTE holders                                                                               |
| ---------------------------- | --------------------------------------------------------------------------------------------- |
| `mark_internal_move_legs`    | authenticated, postgres, service_role                                                         |
| `clear_internal_move_flag`   | authenticated, postgres, service_role                                                         |
| `tg_mark_internal_move_pair` | postgres, service_role                                                                        |
| `is_internal_move_dispatch`  | PUBLIC — read-only and `security_invoker`, so `anon` gets RLS-filtered reads and nothing more |

Probed live as `SET LOCAL ROLE anon`: `mark_internal_move_legs` →
`REFUSED_no_execute_grant`.

**Cody on A5** (Articles 1, 3, 4, 8, 12, 13, 16): ✅ Approve. Strictly more restrictive than
A2 in both dimensions; provenance GUCs and the audit path are unchanged; forward-only with
`CREATE OR REPLACE` and an idempotent `REVOKE`; no object dropped; no metric touched. No new
conditions.

---

## Leg 1 — A6: the trigger was testing less than the predicate

Found by reading the two objects side by side rather than by a failing test, which is the
only way this one surfaces.

`is_internal_move_dispatch()` only counts an Add New as a pairing counterpart when it is live
work — `cancelled = false AND skipped = false AND include = true`.
`tg_mark_internal_move_pair`'s `WHEN` clause tested only `cancelled` and `is_m2m`. So an Add
New inserted with `include = false` or `skipped = true` still fired the Add-arm and stamped a
Remove that **the predicate itself does not consider paired**.

That is not cosmetic, because the predicate's first live branch is
`WHEN COALESCE(rd.is_internal_move, false) THEN true` — **the stored column overrides the
pairing test.** An over-stamp propagates straight through to the queue view and all three
approve RPCs, so a genuine warehouse return could have dropped out of the approval queue on
the strength of an Add New that was never going to happen. Two objects answering one question
and disagreeing at the edges: the exact Article 16 disease the predicate exists to cure.

`20260810150000_prd113_a6_trigger_matches_the_predicate.sql` re-creates the trigger with
`skipped` and `include` added to the `WHEN` clause, making its gate a strict subset of the
predicate's. Fixed forward — A2 and A5 are not edited. The function body, the Remove arm, the
alerts and every grant are untouched.

Applied on the second try: the first hit a 20s `lock_timeout`, because `DROP TRIGGER` needs
ACCESS EXCLUSIVE and the golden sweep was holding `refill_dispatching`. Retried at 60s.

Probed live:

| probe                                                     | result                              |
| --------------------------------------------------------- | ----------------------------------- |
| a de-scoped (`include = false`) Add New stamps the Remove | ✅ no — flag false, predicate false |
| a live Add New stamps the Remove                          | ✅ yes                              |

**Cody on A6** (Articles 12, 16): ✅ Approve. Strictly narrowing; one trigger re-created;
no function body, grant or signature changed; forward-only. It closes an Article 16
divergence rather than creating one. No new conditions.

---

## Leg 1 — the legacy-comment backfill, validated against the real corpus

PRD-113 fix 4 asks for display-only backfill of rows whose comment "matches the existing move
conventions". Rather than guess the conventions, the regex set was run against all **217
distinct Remove / M2W comments** in `refill_dispatching`.

The first draft matched 5 and **missed 3 genuine in-machine moves**: `into A04` (not `to`),
the arrow form `A12 -> A02`, and the CONSOLIDATION phrasing. Widened to
`(?:move[ds]?|consolidat\w*) ... (?:in)?to A\d{1,2}` plus an `A\d+ -> A\d+` pattern.

Final result — **8 matched, 209 skipped**, and every one of the six cross-machine comments
still correctly skipped:

| matched (renders "Move within machine")                  | skipped (a real departure from the machine)              |
| -------------------------------------------------------- | -------------------------------------------------------- |
| `Move to A2` · `Moved to A13`                            | `Move to AstroLabs` · `Move to IRIS` · `Move to NOOK`    |
| `CS 2026-06-01: move Krambals A12 -> A02`                | `Move to USH` · `Move to ADDMIND`                        |
| `CONSOLIDATION: move ALL 8 Tamreem from A16 into A04` ×2 | `[MOVE TO AMZ-3003 A01] ... carry to AMZ-3003 shelf A01` |
| `Popit relocated to A14`                                 |                                                          |
| the two hand-neutralised MC-2004 legs                    |                                                          |

The last skipped row is the one that justifies the shelf-code anchoring: it contains a shelf
code (`A01`) **and** the word MOVE, but names a different machine. Anchoring on the word
"move" alone would have labelled a genuine cross-machine transfer as an in-machine move.

`npx tsc --noEmit` clean, `npm run build` ✅ compiled successfully.

---

## Leg 1 — A7: the guard was on the wrong layer

The most serious finding of the build, and it came from asking a question the PRD does not
ask: **who else calls `receive_dispatch_line`?** — the function all three approve RPCs
delegate their "credit/archival logic" to.

A3 guarded the three functions the PRD names. Those are not the three ways a Remove leg gets
credited:

- **`receive_all_dispatches_for_machine(machine, date, use_filled)`** loops over _every_
  dispatched, unreceived, included row for a machine/date — Remove legs included — and calls
  `receive_dispatch_line` directly. It is wired to the "Mark All" bulk action on `/refill`
  (`DailyDispatchingTab.tsx:381`). Live, reachable, and it walks straight past all three A3
  guards. One click would have credited every in-machine move on the machine.
- `src/app/(field)/field/trips/[machineId]/page.tsx` also calls `receive_dispatch_line`
  directly, per line.

Guarding N call sites is the disease the canonical predicate exists to cure, so
`20260810160000_prd113_a7_guard_the_credit_writer.sql` puts the guard on the single writer
that actually moves the stock. Every present and future caller inherits it. The three approve
RPCs keep their own guard and still fire first, with a message aimed at a warehouse manager
rather than at a developer.

The bulk loop **skips** such legs rather than raising — a RAISE inside it would take down the
whole "Mark All" for every other line on the machine — and names what it skipped in the
return value (`skipped_internal_moves`, `internal_move_legs`), so the operator is told rather
than left to infer.

`receive_dispatch_line` is re-emitted as its live definition with **one** guard inserted
immediately after its existing already-received check. Nothing else in the 18 KB body is
touched.

Probed live, inside a rolled-back subtransaction:

| probe                                                                 | result                           |
| --------------------------------------------------------------------- | -------------------------------- |
| `receive_dispatch_line` called directly on a move leg                 | ✅ REFUSED                       |
| bulk receive over a machine holding one move leg + one genuine return | ✅ skipped 1, received 1         |
| the move leg credited?                                                | ✅ no — `item_added` still false |
| the genuine return credited?                                          | ✅ yes — `item_added` true       |

**Cody on A7** (Articles 1, 4, 8, 12, 16): ✅ Approve. This is Article 1 being _applied_
rather than bent — the guard moves onto the canonical write path instead of being replicated
at each caller. Provenance GUCs, signatures and audit behaviour unchanged; forward-only; no
drops. The bulk skip is the LAW 5 shape (report, do not silently do nothing). No new
conditions.

**Honest note on the review process:** my own Cody pass listed the three approve RPCs because
that is what the PRD listed. It took a second, independent question — "what else reaches the
credit writer?" — to find the hole. A6 and A7 are both cases where the specified scope and
the actual invariant were not the same thing.

---

## Leg 1 — golden sweep: the one red, diagnosed rather than waved through

**Fixture 2 "Censored velocity cold-start" — 53/54, seq 20 red.** It was 54/54 on every recent
run (leg 173 A/B/C, leg 175 A/B/C). So it is a genuine change of state, and it deserved a
diagnosis rather than an assumption.

**It is not PRD-113.** Three independent lines of evidence:

1. **Structural.** Seq 20 reads `public.v_shelf_instock_velocity_v3`. That view reads
   **neither `refill_dispatching` nor `pod_inventory`** — verified against its definition.
   Those two tables are the entire surface PRD-113 touches.
2. **Arithmetic.** The assertion is
   `abs(velocity_instock/velocity_raw - 720/stock_hours) > 1e-4`, and both violating rows
   carry `velocity_raw = 0.033333` — the 6-decimal rounding of exactly one unit per 30 days
   (`1/30 = 0.0333333…`). That rounding is a relative error of `1.0e-5`, and the ratio it
   divides into is ~12.4, so it lands as `1.24e-4` absolute — just over the fixture's `1e-4`
   tolerance. Recomputed with an unrounded `1/30`, the same two rows give `6.7e-6` and
   `1.8e-5`, comfortably inside. The assertion's own description says "to the view's own 6dp
   rounding"; the tolerance simply is not wide enough for the smallest `velocity_raw` bucket.
3. **Subjects.** The two rows are HUAWEI-2003-0000-B1 and ADDMIND-1007-0000-W0, neither
   touched by any PRD-113 object, migration, probe or fixture.

| machine              | velocity_instock | velocity_raw | stock_hours | delta        | delta if velocity_raw unrounded |
| -------------------- | ---------------- | ------------ | ----------- | ------------ | ------------------------------- |
| HUAWEI-2003-0000-B1  | 0.415229         | 0.033333     | 57.7994     | **1.179e-4** | 6.7e-6                          |
| ADDMIND-1007-0000-W0 | 0.397944         | 0.033333     | 60.3099     | **1.009e-4** | 1.8e-5                          |

So it is a **fixture tolerance defect that live data drifted into** — it fires whenever a
shelf settles at exactly 1 unit / 30 days with a high in-stock-to-raw ratio. Left alone
deliberately: fixture 2 is PRD-110 territory, this build unit is instructed not to touch
PRD-110 files, and widening someone else's tolerance to make my own sweep look green is
exactly the wrong move. **Handed to the PRD-110 owner**: the fix is to compare at the view's
own precision (or widen to ~5e-4), not to re-baseline the fixture.

---

## Leg 1 — production walk (backend live, FE pre-merge baseline)

Same method as PRD-112: the branch preview alias is a 64-character DNS label and does not
resolve, so production is signed into with the real test accounts (password grant) and driven
with a hand-built `@supabase/ssr` session cookie. Script kept at `/tmp/prd113_walk.sh`.

The backend is already live, so the guards are provable from a real client now; the FE rows
below are the pre-merge baseline and are re-walked after the merge.

| probe                                                                                          | as          | result                                                                                          |
| ---------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------- |
| `/refill`                                                                                      | warehouse   | HTTP 200                                                                                        |
| `/field/dispatching`                                                                           | driver acct | HTTP 200                                                                                        |
| `v_pending_wh_remove_confirmations`                                                            | warehouse   | HTTP 200, 7 rows, all genuine                                                                   |
| `refill_dispatching` incl. `is_internal_move`, `internal_move_cleared_at`                      | warehouse   | HTTP 200, both columns present                                                                  |
| same select                                                                                    | driver acct | HTTP 200, both columns present                                                                  |
| `is_internal_move_dispatch` on an unknown id                                                   | warehouse   | HTTP 200 `null` — the documented NULL contract, and callers COALESCE it                         |
| `clear_internal_move_flag` with reason `"ok"`                                                  | warehouse   | HTTP 400, the 10-character refusal                                                              |
| `anon` → `mark_internal_move_legs` / `clear_internal_move_flag` / `tg_mark_internal_move_pair` | anon        | HTTP 404 PGRST202 — **not in the schema cache at all for anon**, which is A5 working end to end |

### A stale line in CLAUDE.md cost a false alarm

Two probes that were _supposed_ to be refusals came back HTTP 200 as `driver@boonz.test`,
which looked like a privilege hole in a brand-new DEFINER writer. It was not.
**`driver@boonz.test` carries role `warehouse`, not `field_staff`** — CLAUDE.md's test-user
table is wrong on that line. The only real `field_staff` accounts are `anthony001@boonz.test`
and `vox_admin@boonz.me`, and no password is known for either.

The role gate was therefore proven at the DB layer against a real `field_staff` uid, using
the same `request.jwt.claims` impersonation the golden fixtures use:

| probe                                     | result                                            |
| ----------------------------------------- | ------------------------------------------------- |
| `mark_internal_move_legs` as field_staff  | ✅ REFUSED — "may not relabel dispatch legs"      |
| `clear_internal_move_flag` as field_staff | ✅ REFUSED — "may not re-open a warehouse credit" |

**For CS:** the `## Test Users` block in `CLAUDE.md` lists `driver@boonz.test` under
`field_staff`. It is `warehouse`. Not corrected here — editing CLAUDE.md is outside this
PRD's scope — but it will mislead the next role probe exactly as it misled this one.

---

## Leg 1 — A8: the path the driver can actually reach

A7 guarded `receive_dispatch_line`. `return_dispatch_line` is a **separate** credit writer —
it does not call `receive_dispatch_line` at all — and its Remove branch does this:

```sql
IF v_dispatch.action = 'Remove' THEN
  v_return_qty := ABS(v_dispatch.quantity);
  ... UPDATE warehouse_inventory SET warehouse_stock = warehouse_stock + v_return_qty
```

A full warehouse credit, under the mutation reason `confirmed_removal`. And it is reachable
from **the driver's own second button on `/field/dispatching`**. Of every path found in this
PRD, this is the one most likely to fire in the field — a driver tapping a button on a phone
while standing at the machine.

`20260810170000_prd113_a8_guard_return_dispatch_line.sql` refuses it in the **same shape** as
the PRD-070 `is_m2m` block it now sits above: a structured `{'status':'refused'}` object, not
a RAISE. The driver page submits every line of a trip in one pass, and one refused leg must
not abort the remaining lines.

Probed live:

| probe                                          | result                                        |
| ---------------------------------------------- | --------------------------------------------- |
| in-machine move → `return_dispatch_line`       | ✅ `refused` / `internal_move_return_blocked` |
| warehouse stock moved?                         | ✅ **delta 0**                                |
| leg marked returned?                           | ✅ no                                         |
| genuine return (packed, picked up, real actor) | ✅ `returned`                                 |
| its warehouse credit                           | ✅ **+5**, exactly the quantity — unchanged   |

A first pass at this probe showed the genuine return "refused" too, which briefly looked like
over-blocking. It was the pre-existing `no_actor_non_physical` guard — my probe had passed a
NULL actor on a line that was never packed. Re-run with a real actor and a physical history,
it credits exactly as before. Worth recording: a refusal object is not self-evidently _your_
refusal, and reading only `status` would have produced a false alarm in one direction or a
missed regression in the other.

**FE follow-through.** `return_dispatch_line` returns jsonb, so a refusal arrives with
`rpcErr === null` — the driver page would have treated it as success, and the leg would have
silently stayed unresolved. Two changes:

- the save path now branches on `status === 'refused'` and shows the driver plain language:
  _"This is a move within the machine — it does not go back to the warehouse, so there is
  nothing to return."_
- the return button is **disabled** on an internal-move Remove, with the explanation on
  hover, rather than offered and then refused.

`npx tsc --noEmit` clean, `npm run build` ✅.

### The pattern across A6, A7 and A8

Three of the eight migrations exist because the PRD's named scope and the actual invariant
were not the same thing. The PRD said "the Inventory Approval query and the approve receipt
RPC". The real invariant is **no path may credit the warehouse for units that never left the
machine**, and the paths are: three approve RPCs, `receive_dispatch_line` (with its bulk
looper wired to a "Mark All" button), and `return_dispatch_line` (wired to a driver's
button). Each was found by asking _who else writes the credit_ rather than by re-reading the
PRD.

---

## Leg 1 — the credit surface, enumerated rather than assumed

After A8 I stopped finding paths by intuition and asked the database instead: every function
that reads `refill_dispatching` **and** increments `warehouse_inventory.warehouse_stock`.

```sql
SELECT p.proname, p.prosrc ILIKE '%is_internal_move%' AS already_guarded
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND p.prosrc ILIKE '%refill_dispatching%'
  AND p.prosrc ILIKE '%warehouse_stock%'
  AND p.prosrc ~* 'warehouse_stock[[:space:]]*=[[:space:]]*(COALESCE\()?warehouse_stock';
```

Five functions. All five accounted for:

| function                    | status                                                                                                                                                                                                                                                             |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `receive_dispatch_line`     | ✅ guarded (A7) — and with it every caller, including `receive_all_dispatches_for_machine` and the direct FE calls                                                                                                                                                 |
| `return_dispatch_line`      | ✅ guarded (A8) — the driver's button                                                                                                                                                                                                                              |
| `credit_dispatch_remainder` | ✅ safe by construction — returns `skipped` on `action = 'Remove'` ("Remove line has no fill remainder") before touching stock                                                                                                                                     |
| `pack_dispatch_line`        | ✅ no Remove path — the string `Remove` does not appear in its 10.5 KB body, and Remove legs are stamped `no_pack_needed` at insert by `tg_default_pack_outcome_driver_legs`, so nothing is ever drawn from the warehouse for one and nothing can be released back |
| `repair_unbound_dispatch`   | ✅ no Remove path — same, 3.2 KB body, no `Remove` reference                                                                                                                                                                                                       |

Plus the three approve RPCs from A3, which are entry points rather than credit writers.

**The invariant, stated once:** no path may credit the warehouse for units that never left
the machine. As of A8 that holds at the writer layer, not merely at the entry points the PRD
happened to name.

---

## Leg 1 — A9: I broke another PRD's Cody condition, and the sweep caught me

**Golden fixture 26 seq 14 went red: `28195f57` expected, a different hash actual.** The
assertion is:

> ⛔ the incumbent `receive_dispatch_line` is BYTE-FOR-BYTE UNCHANGED (md5 `28195f57`). The
> whole design rests on composing it, not editing it — **Cody condition 1 is void the moment
> this moves.**

That is PRD-110's ratified condition for the spot-buy design (`receive_dispatch_line_sourced_v3`
composes this function rather than replacing it). **A7 edited it.** Conditions are not
waivable, and that includes conditions belonging to another unit — re-baselining someone
else's pin so my own sweep reads green would be exactly the wrong move.

`20260810180000_prd113_a9_restore_rdl_and_guard_the_event.sql` reverts A7's function edit
verbatim and moves the invariant to where it always belonged — **the credit event, not one
function that happens to cause it**:

```sql
BEFORE UPDATE ON refill_dispatching
WHEN (NEW.item_added = true AND COALESCE(OLD.item_added,false) = false
      AND NEW.action = 'Remove' AND COALESCE(NEW.is_m2m,false) = false)
```

This is strictly **better** than the A7 edit, not a concession:

- it covers every caller of `receive_dispatch_line`, present and future, plus a direct
  PostgREST call — which an in-function guard never could;
- it survives `receive_dispatch_line` being rewritten by a later PRD;
- it composes rather than edits, which is the very principle fixture 26 protects.

**Scope kept deliberately narrow.** The trigger fires only on the `item_added` credit event
for a Remove. It does **not** police `returned = true`: A8 already refuses there with a
structured object rather than a RAISE, so bulk callers keep working. A RAISE on `returned`
would have turned `eod_auto_release_unpicked` / `release_stale_unpacked_dispatches` into a
hard nightly failure the first time either met one of these legs.

A7's other change — the skip inside `receive_all_dispatches_for_machine` — **stays**. That
function carries no pin, and the skip is what keeps "Mark All" working rather than dying on
the first move leg.

Verified: `left(md5(prosrc),8)` on `receive_dispatch_line` is **`28195f57`** again.

| probe                                                                    | result                                                  |
| ------------------------------------------------------------------------ | ------------------------------------------------------- |
| `receive_dispatch_line` direct on a move leg (function no longer guards) | ✅ BLOCKED by the trigger                               |
| `wh_approve_remove_receipt`                                              | ✅ still refuses first, with its own friendlier message |
| bulk receive                                                             | ✅ skipped 1, received 1                                |
| move credited / genuine credited                                         | ✅ false / true                                         |

**Fixture 26 re-run post-A9: 89/0 green** (it was 88/1). **Fixture 113 re-run post-A9: 25/0
green.**

### Fixture 46 — the third red, also not mine

`46 seq 7` ("the merge really is cross-SKU: 20 units draw on at least 2 distinct SKUs")
expected `>= 2`, got `1`. It was 29/0 on leg 173 A/B/C and leg 175 A/B/C.

Its scenario references **none** of `refill_dispatching`, `is_internal_move`,
`receive_dispatch_line`, `return_dispatch_line` or the FIFO decrement — checked, all false.
It calls `resolve_fefo_sku_legs_v3(TODAY, …)` against **live `warehouse_inventory`**, which
PRD-113 never writes.

Run live now, that call returns `status: "partial"`, `n_legs: 1`, `qty_bound: 2` of 20 — the
warehouse holds only two units of a single SKU for that pod today. The sibling SKU that made
it cross-SKU yesterday has been consumed or has expired. **Warehouse stock depletion**, the
same class of defect as fixture 2: a fixture whose premise is live data it does not own.
Left for the PRD-110 owner.

---

## Leg 1 — A10: the A9 trigger could strand a multi-variant return

`wh_approve_remove_receipt_multivariant` splits one Remove into child Remove rows, one per
variant, and calls `receive_dispatch_line` on each **inside the same transaction**. A9's
trigger evaluates the pairing predicate on every child — and a child carries the _parent's_
shelf but a _variant_ product id. If that variant happened to have an unrelated Add New on
another shelf of the same machine that day, the child would be blocked, the whole call would
abort, and the child would never exist — so there would be nothing for
`clear_internal_move_flag` to clear. A warehouse manager would be stuck mid-task on a
**genuine** return with no recovery path.

The parent has already been through the A3 guard by then, so the children inherit a verdict
that was made properly once. `20260810190000_prd113_a10_multivariant_children_exempt.sql`
exempts them by their own creation marker (`[multi-variant child of …]`).

The failure this prevents is a _refusal_, not a bad credit — but a refusal with no way out is
still a defect, and this one lands on a person mid-task.

| probe                                           | result                  |
| ----------------------------------------------- | ----------------------- |
| plain Remove, paired Add New present            | ✅ BLOCKED              |
| multi-variant child, same product, same pairing | ✅ ALLOWED and credited |

---

## Leg 1 — full golden sweep: 72 fixtures, one red was mine and it is fixed

Fired **per fixture** through `/tmp/prd110_sql.sh` at `statement_timeout = 600s`, scratch
cleared from outside each fixture's transaction (S-254), and adjudicated by reading
`golden.runs` back — never off the response body (S-212). `golden.run_all` through the
management API is not usable here: one heavy fixture trips the timeout and the whole
`run_all` transaction rolls back, banking nothing (S-250).

**72 banked · 68 green · 4 red.** Every red diagnosed, not assumed:

| fixture                                | red  | mine?   | cause                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------- | ---- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **26** `receive_dispatch_line` md5 pin | 88/1 | **YES** | A7 edited a byte-pinned function. **Fixed by A9; re-run 89/0 green.**                                                                                                                                                                                                                                                                                                                                                                           |
| **2** censored velocity cold-start     | 53/1 | no      | fixture tolerance defect: `velocity_raw` rounds to `0.033333` (= 1 unit / 30 d); that 1.0e-5 relative error across a ratio of ~12.4 lands at 1.24e-4 against a 1e-4 threshold. Unrounded, the same rows give 6.7e-6 and 1.8e-5. The view reads neither `refill_dispatching` nor `pod_inventory`.                                                                                                                                                |
| **46** FEFO SKU binding                | 28/1 | no      | warehouse depletion. `resolve_fefo_sku_legs_v3` now returns `status: partial, n_legs: 1, qty_bound: 2` of 20 — only two units of one SKU left for that pod. Scenario references none of PRD-113's surfaces.                                                                                                                                                                                                                                     |
| **74** DR-1 cutover authority          | 51/2 | no      | **the nightly cron did its job.** `VML` moved from `no_v3_measurement` to `v3_horizon_not_elapsed`, so the fixture's hard-coded 6/4 split reads 5/5. `engine_forecast_error_v3` holds 44 VML rows dated **2026-08-10** — written by cron 45 `prd110_p27_nightly_shadow_runner_v3` (21:22 UTC) between fixture 74's last green run (2026-08-09 01:20 UTC) and this sweep (23:07 UTC). `v_cutover_readiness_v3` reads none of PRD-113's surfaces. |

**The honest verdict on acceptance item 5.** PRD-113 introduced exactly **one** golden
regression, fixture 26, and it is fixed and re-verified. The other three are pre-existing
fixtures whose premises are live data they do not own — a rounding tolerance, warehouse
stock, and the v3 engine's own progress. Making them green means editing PRD-110's fixtures,
which this unit is instructed not to touch and which would be the wrong instinct anyway:
**re-baselining someone else's pin to make my sweep read green is exactly the failure mode
fixture 26 just caught me in.** All three are handed to the PRD-110 owner with the diagnosis
above.

Final state of the two fixtures this PRD is responsible for, re-run after the last migration
(A10):

| fixture              | result           |
| -------------------- | ---------------- |
| 26 (the pin I broke) | **89 / 0 green** |
| 113 (PRD-113's own)  | **25 / 0 green** |

---

## Merge

`prd-113-internal-moves-expired-guard` → `main` as **`8af5557`** (no-ff), 14 commits.
`npx tsc --noEmit` clean and `npm run build` ✅ on merged `main` **before** the push.

The pull hit `cannot pull with rebase: You have unstaged changes` — `docs/prds/PRD-112-REPORT.md`
was already modified in the working tree when this unit started and is **not mine to commit**.
Stashed by path (not `-u`, which would have swept up the two relay scripts), rebased with
`--rebase=merges` per the PRD-072 deploy-recorder push-race lesson, then popped. The PRD-112
edit and both untracked relay scripts are exactly as this unit found them.

## Ten migrations, applied and ledger-matched

Every file's name matches its `supabase_migrations.schema_migrations` row exactly, verified
after the last apply.

| #   | migration                              | what                                                                   |
| --- | -------------------------------------- | ---------------------------------------------------------------------- |
| A1  | `is_internal_move_column`              | the column, the durable-override pair, the pairing index               |
| A2  | `internal_move_predicate_and_writer`   | canonical predicate, stamp writer, un-stamp writer, trigger, allowlist |
| A3  | `return_queue_excludes_internal_moves` | queue view + the three approve RPCs                                    |
| A4  | `fifo_never_consumes_expired`          | expired batches ineligible; overflow reported                          |
| A5  | `close_anon_execute_on_new_writers`    | the `anon` hole A2 opened                                              |
| A6  | `trigger_matches_the_predicate`        | trigger gate ⊆ predicate gate                                          |
| A7  | `guard_the_credit_writer`              | the bulk receiver behind "Mark All"                                    |
| A8  | `guard_return_dispatch_line`           | the driver's own button                                                |
| A9  | `restore_rdl_and_guard_the_event`      | md5 pin restored; guard moved to the credit event                      |
| A10 | `multivariant_children_exempt`         | a genuine multi-variant return is not stranded                         |

---

## Production verified

The **shipped bundle** is the verdict, not the local build and not an HTTP code. Polled
production with a hand-built `@supabase/ssr` session cookie until the new chunks were being
served, then scanned every chunk on both pages.

| page                                    | evidence in the deployed chunks                                                                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/refill` (warehouse)                   | HTTP 200 · **"Move within machine"** present in `2e0c07e874d92f67.js` · **"Review All" absent from all 13 chunks**                                                       |
| `/field/dispatching/<MC-2004>` (driver) | HTTP 200 · `22381207dcc2fcd0.js` carries **"MOVE WITHIN MACHINE"**, **"Moved from "**, **"Moved to its new shelf"**, **"move within the machine"**, **"Could not move"** |

A first bundle scan reported nothing and briefly looked like a stale deploy. The probe was
wrong, not the deploy: a nested shell loop over a 150 KB variable silently mis-handled it.
Re-run writing each chunk to disk before grepping, every string is there. Recorded because
"the scan found nothing" and "the deploy did not land" look identical and are not.

**Data contracts through PostgREST, as the real roles** (this is what catches a grant or RLS
hole that reading `pg_proc` cannot):

| probe                                                                                 | as                                       | result                                            |
| ------------------------------------------------------------------------------------- | ---------------------------------------- | ------------------------------------------------- |
| `v_pending_wh_remove_confirmations`                                                   | warehouse                                | 200, 7 rows, all genuine returns                  |
| `refill_dispatching` incl. `is_internal_move`, `internal_move_cleared_at`             | warehouse                                | 200, both columns present                         |
| same                                                                                  | driver acct                              | 200, both columns present                         |
| `is_internal_move_dispatch` on an unknown id                                          | warehouse                                | 200 `null` — the documented contract              |
| `clear_internal_move_flag` with reason `"ok"`                                         | warehouse                                | 400, the 10-character refusal                     |
| `mark_internal_move_legs` / `clear_internal_move_flag` / `tg_mark_internal_move_pair` | **anon**                                 | **404 PGRST202** — not in the schema cache at all |
| `mark_internal_move_legs`, `clear_internal_move_flag`                                 | **field_staff** (DB-layer impersonation) | both REFUSED with the role message                |

## Acceptance

| #   | criterion                                                                                                              | status                                                                                                                       |
| --- | ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1   | fixture: same-machine swap → flagged → absent from queue → WH unchanged; genuine M2W queues and credits once           | ✅ golden 113, 25/25 — both pair orders, two positive controls, and the genuine return proven to still **credit**            |
| 2   | Refresh Data over a machine with an expired batch + sales: expired unchanged, non-expired decremented, overflow logged | ✅ golden 113 seq 20–25, on a real `run_pod_inventory_decrement()` run, not a re-implementation of its predicate             |
| 3   | 30-day repair report saved                                                                                             | ✅ `docs/prds/PRD-113-expired-consumption-report.md` — 3 batches, 14 units, report only                                      |
| 4   | "Review All" gone; page builds and renders                                                                             | ✅ gone from all 13 shipped `/refill` chunks; `/refill` HTTP 200                                                             |
| 5   | golden green; build green; merged; production verified                                                                 | ⚠️ **see below** — build ✅, merged ✅ (`8af5557`), production ✅; golden has **3 pre-existing reds this PRD did not cause** |

**On item 5, precisely.** PRD-113 introduced exactly one golden regression — fixture 26's
`receive_dispatch_line` md5 pin — and it is fixed (A9) and re-verified at 89/0. Fixtures 2,
46 and 74 are red for reasons proven to be outside this PRD: a rounding tolerance, warehouse
depletion, and cron 45 planning VML for the first time. Each was diagnosed structurally (none
of the three reads `refill_dispatching`, `pod_inventory` or any PRD-113 object) and
numerically where applicable. They are **not** re-baselined: doing that to another unit's
fixtures is the exact failure mode fixture 26 caught in A7, and this unit is instructed not
to touch PRD-110 files.

## For CS

1. **Three golden fixtures need their owner** (PRD-110): 2 (widen the `1e-4` tolerance or
   compare at the view's own precision), 46 and 74 (both hard-code counts over live data that
   has since moved).
2. **`CLAUDE.md` test-user table is wrong**: `driver@boonz.test` is `warehouse`, not
   `field_staff`. It cost a false security alarm here and will cost the next one too.
3. **The 14 units in the repair report** need a physical check of three shelves. If the
   expired units are still there, write them off through the manual flow so the exit is
   recorded as a write-off rather than a sale. No automatic restoration was performed.
4. **Recorded debt, deliberately not fixed here:** the packing page carries a second,
   pod-grain in-machine-move detector (Article 16); and `refill_dispatching` grants
   `authenticated` full table-level DML on top of a permissive UPDATE policy (S-308,
   pre-existing — closing it would break live FE writers).

## PRD-113 DONE
