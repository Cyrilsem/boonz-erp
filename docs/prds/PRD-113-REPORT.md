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

| probe | result |
|---|---|
| a de-scoped (`include = false`) Add New stamps the Remove | ✅ no — flag false, predicate false |
| a live Add New stamps the Remove | ✅ yes |

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

| matched (renders "Move within machine") | skipped (a real departure from the machine) |
|---|---|
| `Move to A2` · `Moved to A13` | `Move to AstroLabs` · `Move to IRIS` · `Move to NOOK` |
| `CS 2026-06-01: move Krambals A12 -> A02` | `Move to USH` · `Move to ADDMIND` |
| `CONSOLIDATION: move ALL 8 Tamreem from A16 into A04` ×2 | `[MOVE TO AMZ-3003 A01] ... carry to AMZ-3003 shelf A01` |
| `Popit relocated to A14` | |
| the two hand-neutralised MC-2004 legs | |

The last skipped row is the one that justifies the shelf-code anchoring: it contains a shelf
code (`A01`) **and** the word MOVE, but names a different machine. Anchoring on the word
"move" alone would have labelled a genuine cross-machine transfer as an in-machine move.

`npx tsc --noEmit` clean, `npm run build` ✅ compiled successfully.
