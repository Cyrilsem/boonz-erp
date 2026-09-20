# Decisions — PRD-127, 2026-09-17

## D-001. Base branch

`PRD-127-propose-refill-plan.md` does not exist (see below), and neither does any prior PRD-127
work. The overnight PRD-123/124/125/126 branch (`overnight-2026-09-15-prd123-126`) was fully
built, applied live, and proven, but its `git push` was blocked by the Claude Code auto-mode
permission classifier in the prior session — it never merged to `main`. The live database
already reflects all of it (migrations were applied directly). Branching `prd127-propose-refill-plan`
from `main` would leave the repo's file history out of sync with the live schema for every
PRD-123-126 object `propose_refill_plan` needs to read (`wh_available_for`, `validate_refill_plan`,
`v_machine_priority`, `substitution_rules`, etc.), and would force re-deriving ~55 commits' worth
of migration files from live bodies as part of tonight's own ledger reconciliation — pure
duplicated effort. Branched from the tip of `overnight-2026-09-15-prd123-126` instead
(commit `fb91351`). The PR this session opens will therefore also bring the PRD-123-126 work to
`main` for the first time — disclosed explicitly in the PR description, not silently bundled.

## D-002. `PRD-127-propose-refill-plan.md` did not exist — reconstructed

Searched the repo root, every local and remote branch (`git ls-tree -r <branch>`), and the
entire `BOONZ BRAIN` parent directory on disk for any file matching `*127*` or `*PRD-127*`.
Zero matches anywhere. This is not "hadn't looked yet" — it was verified genuinely absent. The
turn's own goal prompt gave a detailed inline specification (Block A's `refill_directives`
shape, Block B's `propose_refill_plan` non-negotiables, Block D's acceptance-test hints for
A1/A2/A3/A6/A8/A9) but explicitly deferred exact wording to "PRD-127 section N," sections that
were never written down. Rather than block the entire session on a document CS's own prompt
assumed already existed, reconstructed `PRD-127-propose-refill-plan.md` from the goal's own
inline spec plus doctrine-consistent choices for the genuinely undetermined parts (the exact
chat-summary shape, the reason-code taxonomy, the eleven acceptance criteria's precise wording).
Logged so CS can correct anything the reconstruction got wrong relative to what he actually
meant, rather than the session silently guessing and moving on unflagged.

## D-003. "Event triggers" in the goal prompt means DML triggers, not literal Postgres event triggers

PostgreSQL event triggers (`CREATE EVENT TRIGGER`) fire only on DDL (`ddl_command_end`,
`sql_drop`, `table_rewrite`) — they cannot intercept `INSERT`/`UPDATE`/`DELETE` on a normal
table. The goal's Block B ("run it inside a transaction with event triggers that raise on any
write to `pod_refill_plan`, `refill_plan_output`, `refill_dispatching`, `pod_inventory`,
`warehouse_inventory`") is calling for exactly this DML-level guarantee, so the correct
implementation is a real `AFTER INSERT OR UPDATE OR DELETE ... FOR EACH ROW` trigger installed
on each of the five tables for the duration of one rolled-back transaction (A1 in
`docs/prd127-acceptance.sql`), not a literal `CREATE EVENT TRIGGER`. This is the technically
correct realization of the stated intent, not a scope reduction — implemented as such and noted
in `PRD-127-propose-refill-plan.md` section 4.

## D-004. Bug #2 root cause is `approve_m2m_transfer`, not "push pairing"

Traced the exact mechanism behind "insert_driver_remove_line excludes M2M parent legs carrying
item_added=true, but push pairing sets exactly that flag on both legs." Read `push_plan_to_dispatch`,
`pair_internal_transfer_m2m`, and `convert_removes_to_m2m_transfer` in full: none of the three
ever write `item_added` — every M2M leg is inserted with `item_added=false`, and
`pair_internal_transfer_m2m` only ever _reads_ `item_added` (as a filter for "not yet closed").
The actual writer is `receive_dispatch_line`'s blanket `UPDATE ... SET item_added = true` at the
end of every receipt, called on BOTH legs of a transfer by `approve_m2m_transfer` — the
warehouse-side approval RPC, gated to warehouse/operator_admin/superadmin/manager, which a
manager can run before the driver has physically reconciled a mixed-flavour lane. Confirmed
live: today's `refill_dispatching` has real `is_m2m=true, item_added=true` pairs from 12 and 17
September with exactly this "6/8, fit what fits" shape. `approve_m2m_transfer` is not on the
Daytime Rule's protected list, but `insert_driver_remove_line` is — so the fix (see D-005) still
lands on the protected function and is correctly gated by Block C's own clock check regardless
of which function actually sets the flag.

## D-005. Bug #2 fix: drop the `item_added` filter, accept and disclose the residual risk

Two literal options were offered ("drop `item_added` from that predicate, or stop the pairing
writing it"). Since the true writer (`approve_m2m_transfer`) legitimately needs to keep setting
`item_added=true` at approval time — that is its entire purpose, marking the transfer
reconciled — "stop the pairing writing it" is not actually available without breaking
`approve_m2m_transfer`'s own idempotency guard. Implemented the other option: dropped
`AND NOT COALESCE(rd.item_added, false)` from `insert_driver_remove_line`'s M2M-parent search.
**Residual risk, disclosed rather than silently accepted:** this now lets a driver split a
Remove leg's quantity even after a warehouse manager has already approved (and thus financially
reconciled) that transfer, via `UPDATE refill_dispatching SET quantity = quantity - p_quantity`
on an already-`item_added=true` row — the reconciliation that already ran used the OLD quantity
and will not be recomputed. CS's own bug report (and the fact that this blocked a real driver
this morning) reads as a deliberate judgment that "sometimes reopens a settled record" is a
smaller cost than "permanently blocks a legitimate field correction," so this session followed
that judgment rather than overriding it with a more conservative but unrequested design (e.g.,
scoping the bypass to only-if-quantity-still-available). Written as
`20260917_prd127_c2_insert_driver_remove_line_drop_item_added.sql`, gated on the Daytime Rule
like the other two Block C fixes (`insert_driver_remove_line` is on the protected list).

## D-006. Bug #1 fix: idempotent `_bind_tally`, not a per-call-scoped table

`push_plan_to_dispatch(plan_date, ONE machine name)` calls `bind_dispatch_fefo(plan_date,
ARRAY[machine_name])` once per machine at the end of its own run. `bind_dispatch_fefo` does
`CREATE TEMP TABLE _bind_tally ON COMMIT DROP AS ...` unconditionally — fine for a single call,
but a second machine's call within the same transaction (which is exactly what a multi-machine
`approve_refill_plan`/`confirm_and_build` push does) hits `relation "_bind_tally" already exists`,
caught by `push_plan_to_dispatch`'s own `EXCEPTION WHEN OTHERS`, logged as one
`push_fefo_bind_failure` alert per machine (matches the reported "135 alerts on 17 Sep" for a
135-row multi-machine plan). The two options in the goal text were "idempotent" or "scoped per
call" — scoping it per call (e.g. a unique temp table name per invocation) would be actively
wrong here: `_bind_tally.remaining` is a shared, cross-call-persisting ledger of physical
warehouse stock within the transaction, and re-creating it fresh per machine would let two
machines in the same push run double-allocate the same physical batch (nothing else decrements
`warehouse_inventory.warehouse_stock` at bind time — only `from_wh_inventory_id` gets stamped on
`refill_dispatching`). Made the `CREATE TEMP TABLE` conditional on
`to_regclass('pg_temp._bind_tally') IS NULL`, preserving exactly the current allocation
behaviour across multiple calls in one transaction while eliminating the crash on the second and
subsequent calls.

## D-007. Bug #3 fix: sum `wh_available_for` across every Active flavour of the pod product

`engine_add_pod`'s `wh_avail` column already wraps `wh_available_for` in a `SUM(...)`, but the
boonz_product_id it sums over comes from a `LATERAL ... ORDER BY ... LIMIT 1` join
(`rmap`) that picks exactly ONE representative flavour mapped to the shelf's pod product — so
if that one flavour happens to be out of stock while a sibling flavour of the same pod product
has plenty, `wh_avail` reports 0 and the whole lane gets `blocked_no_wh`, even though the pod
product itself is fillable. Fixed by summing `wh_available_for` over every DISTINCT Active
`boonz_product_id` mapped to that pod product for that machine (still resolved with the same
machine-specific-over-global-default preference per distinct flavour, just no longer collapsed
to a single row before the sum). `propose_refill_plan` (Block B, a different code path built
fresh tonight) does not inherit this bug — it resolves one representative flavour per lane by
design (a human-facing recommendation must name one specific product to add), so bug #3's fix is
scoped to `engine_add_pod` only; it was not "reused" into the new function, which would have
reintroduced ambiguity into a tool whose whole job is naming one specific thing to buy.

## D-008. G8's `internal_transfer` skip is present and unchanged

Read `validate_refill_plan` in full: the G8 clause still carries
`AND COALESCE(l.source_origin,'warehouse') <> 'internal_transfer'` with its original comment
("M2M dest legs are supplied by the source machine, not the warehouse"). Not reverted — no
action needed, verified rather than assumed.

## D-009. `wh_fefo_for_line` reused instead of hand-copying `bind_dispatch_fefo`'s temp-table logic

Block B's mandate is "reuse the reservation, quarantine and phantom-batch predicates from
`bind_dispatch_fefo` verbatim, including `_is_phantom_wh_row_v3` and the
`reserved_for_machine_id` check." `bind_dispatch_fefo` itself is a writer (creates a temp table,
mutates `refill_dispatching`) and not something a `STABLE` read-only function should call.
Found `wh_fefo_for_line` — an existing `STABLE SQL` function already used by
`push_plan_to_dispatch` and `receive_dispatch_line` — which already encapsulates the identical
phantom/reserved/quarantine/committed-elsewhere logic in read-only form (via `v_wh_pickable` and
`v_dispatch_open_wh_commitment`). Reused this existing canonical object directly rather than
re-copying the predicate a third time into `propose_refill_plan`'s own body — this satisfies
"verbatim, no drift" more strongly than a textual copy would (a copy can still drift later; a
shared function call cannot). For the pool-level allocation (`wh_available_for` summed once per
routing class per boonz_product_id, D3), used `wh_available_for` directly per Block B's explicit
instruction to reuse it for free stock.

## D-010. `refill_swap_params` — what it actually holds

Block B says "swap engine weights live in a `refill_swap_params` table, not in the function
body," without specifying which weights. `propose_refill_plan` only has two tunable constants
that would otherwise be inlined magic numbers: how much to boost an expired-on-shelf lane's
effective urgency so it outranks an equally-AED-at-risk ordinary refill in the allocation
contention (`expired_priority_boost_aed`), and the minimum warehouse stock a substitute
candidate needs before it's worth proposing as a special trip
(`min_substitute_stock_units`). Both went into `refill_swap_params` (single-row config table,
same shape as `refill_policy_params`/`pick_urgency_params`). No other "swap weights" exist in
this function to extract — did not invent additional parameters purely to make the table look
more substantial.

## D-012. Real bug caught on first live test run: lane fan-out from non-unique join keys

Running `propose_refill_plan('2026-09-18', null, '[]')` against the day's real 11-machine
confirmed pick list first returned `lanes_total: 1112` against an independently-counted true
value of 192 real lanes -- a ~5.8x duplication, visible immediately as the same fill/exception
line repeated dozens of times for one shelf. Root-caused to two non-unique join keys: (1)
`v_lane_grain` has one row per PHYSICAL SHELF, not per (machine, pod_product) -- a pod product
sitting on N shelves of one machine produces N identical-velocity rows, and joining a single
WEIMI lane onto it by `(machine_id, pod_product_id)` alone fans that lane out N-fold; (2)
`v_current_price_filled` is independently not unique per `(machine_id, pod_product_id,
boonz_product_id)` either -- its own fallback-tier logic can surface 5-15 rows for the exact
same triple. Fixed by collapsing both to exactly one row per join key before joining
(`AVG(lane_dvel) GROUP BY machine_id, pod_product_id` for velocity; the same `DISTINCT ON (...)
ORDER BY ..., effective_price_aed DESC NULLS LAST` collapse `v_machine_priority`'s own
`price_by_boonz` CTE already uses, for price). Re-ran: `lanes_total` now matches the
independently-counted 192 exactly, `by_reason_code` sums to 192. This is exactly the class of
bug the rest of this session has been keeping an eye out for (drift between two things that
were supposed to be interchangeable) -- caught here because the function was actually run
against real data before being called done, not because the design was reviewed harder.

## D-013. Block C applied live (Dubai time passed 22:00 mid-turn)

Dubai time crossed 22:00 partway through this turn (session-elapsed real time, not a
manipulated clock -- verified via `now() AT TIME ZONE 'Asia/Dubai'` returning 2026-09-18 02:13
at the point of the check). Per the goal's own instruction, wrote all three Block C migrations
first, then re-checked the clock and applied all three since it had passed:

- **Bug #1** (`bind_dispatch_fefo` idempotent `_bind_tally`): verified live inside a rolled-back
  transaction with two sequential calls to `bind_dispatch_fefo` against different machine-name
  arrays -- the second call previously would have raised `relation "_bind_tally" already
exists`; it now returns a clean `status: ok` result.
- **Bug #2** (`insert_driver_remove_line` drops the `item_added` filter): verified via
  `pg_get_functiondef` regex that the specific filter clause `NOT COALESCE(rd.item_added` no
  longer appears in the live function body.
- **Bug #3** (`engine_add_pod` sums `wh_available_for` across all flavours): verified the
  applied function body diffs from the pre-change live body in exactly the three places
  intended (the `wh_avail` expression, the `engine_version` string, a trailing semicolon) via
  a byte-for-byte `diff` before applying. Then proved the fix changes real behaviour in the
  intended direction: scanning every multi-flavour pod product against one real WH_CENTRAL
  machine, several products that the OLD single-flavour-`LIMIT 1` computation reported as
  `0` free stock (which would trigger a false `blocked_no_wh`) resolve to real stock under the
  NEW sum-across-all-flavours computation -- e.g. one pod product went from `old=0` to
  `new=113` units, another from `0` to `114`, another from `39` to `2236`.

Canary re-checked after each of the three applies and once more after all three: unchanged
throughout (167 rows, fingerprint `9a7f47322e4e2d50585094d81d704ce0`).

## D-014. Renamed two Block C files to fix a self-inflicted timestamp collision

All three Block C migration files were written with the identical timestamp prefix
`20260917222552` (a copy-paste slip -- one `date -u` call, reused for three separate `Write`
calls instead of re-running it each time). This didn't break `apply_migration` itself (it stamps
the real wall-clock apply time as `version`, independent of the filename, per the established
D-024 finding), but it broke migration-ledger _reconciliation_: `schema_migrations.version` is
unique, and reconciling all three files to their filename-derived timestamp would try to write
the same `version` value twice. Caught during Block D's own reconciliation pass, before either
file was pushed anywhere. Fixed with a plain `git mv`, bumping the second and third file's
timestamp by one second each (`...222553` for C2, `...222554` for C3) -- no content changed,
only the filenames, and `CHANGELOG.md`'s two references were updated to match. Not a violation
of "never edit a past migration": the files' SQL bodies are untouched, and nothing had consumed
the old filenames yet (not pushed, not reconciled into the ledger).

## D-011. `propose_refill_plan`'s default scope is the plan date's confirmed pick list, not the whole fleet

The goal's Block D says "Time `propose_refill_plan` on the full confirmed set," implying
"confirmed set" is a pre-existing, named concept — it is: `machines_to_visit.status IN
('picked','cs_added')` for a given `plan_date`, the exact same set `engine_add_pod` reads.
Made `p_machine_names IS NULL` default to that set (raising if nothing is confirmed for that
date, mirroring `engine_add_pod`'s own guard) rather than silently defaulting to "every
`include_in_refill` machine in the fleet," which would answer a different question than the one
CS actually asks in the morning ("what does TODAY's confirmed run look like").
