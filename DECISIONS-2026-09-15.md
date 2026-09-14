# Decisions log — overnight 2026-09-15

Every entry: what the PRDs did not settle, the choice made, and why. Written as they happen, not after.

---

## D-001. Canary fingerprint PK column

The ONE LOOP canary SQL references `refill_dispatching.id`, which does not exist. The table's
primary key is `dispatch_id` (confirmed via `information_schema.columns`).

**Choice:** use `dispatch_id` in place of `id` everywhere the canary/baseline queries reference
it. No other change to the fingerprint's shape (still quantity + shelf_id + include).

**Why:** keeps the doctrine (prove the canary numerically, do not skip it) while fixing an
literal schema mismatch the prompt could not have anticipated exactly.

---

## D-002. `validate_refill_plan(..., 'plan_output')` is vacuous for 2026-09-12 and 2026-09-15

Both dates' `refill_plan_output` rows are 100% `operator_status IN ('approved','rejected')` --
zero `'pending'` rows remain (09-12: 90 approved / 6 rejected; 09-15: 218 approved / 6
rejected). `validate_refill_plan`'s `plan_output` branch filters `operator_status = 'pending'`
by design, so it returns `{blocking: 0, warnings: 0, violations: []}` for both dates today,
**before any change to the function** -- this is the live baseline, not a bug and not a sign
the gates are already fixed. The `'dispatch'` branch (no `operator_status` filter, reads
`refill_dispatching` directly) returns real signal: 09-15 dispatch shows 81 blocking / 65
warnings today, matching PRD-124/125's described problem almost exactly (G1 capacity
violations dominate, plus G7 two Removes-with-no-replacement, G8 seven products short in
CENTRAL, G2/G4/G9 warnings).

**Choice:** report the literal `'plan_output'` numbers for 09-12/09-15 as the prompt asks
(0 blocking both, both before and after every phase -- they cannot move since the underlying
rows are frozen at `pending=0`), but treat `'dispatch'` on 09-15 as the real regression
surface for proving G1/G3/G5/G7/G8/G10 actually changed behaviour, since it is the only one
of the two sources with live, unresolved rows to check. Phase 3's "list every violation, each
must be real" proof runs against `'dispatch'`. The `'plan_output'` code path for the five new
gates is additionally exercised against a synthetic, rolled-back 2026-09-17 scenario inside
Phase 3's own proof, so the rewritten function is proven on both sources before it ships.

**Why:** keeps the doctrine (prove real gate behaviour on real data) without reporting a
trivially-zero number as if it were evidence the gates work.

---

## D-003. `v_wm_confirmations` baseline is 1, not 11

PRD-123 was measured at 11 open lines on 2026-09-14. Live now (2026-09-15 morning) it is 1.
Time has passed and some lines were evidently confirmed by hand since the PRD was written
(consistent with the ONE LOOP prompt's own note that Simran hand-confirmed the eight lines
with the split recorded in the reason text).

**Choice:** use the live count (1) as this session's own before/after regression baseline.
Phase 8's dry-run replays still run against whatever of the eight named lines remain
`v_wm_confirmations`-open (checked per-line, not assumed as a block of 8), and any that are
already closed are noted as already-resolved rather than treated as a failure to find them.

**Why:** the number the PRD states is a snapshot in time, not a live invariant; the actual
invariant this session must protect is "my own changes do not close or reopen any line",
which requires reading current state, not the PRD's stated count.

---

## D-004. `v_live_shelf_stock` does not need the weimi_shelf_now swap

PRD-125 Phase 1 names `v_live_shelf_stock` as a `pod_inventory`-reading object to replace.
Read its live `pg_get_viewdef` before touching it: it is already built entirely from
`weimi_device_status` (WEIMI's live per-door polling table, distinct from the periodic
`weimi_aisle_snapshots` table `weimi_shelf_now()` reads), with a four-tier product-name match
cascade (direct, case-insensitive, `product_name_conventions`, `weimi_product_alias`) plus
`is_eligible_machine` (Adyen status + repurpose grace). It does not reference `pod_inventory`
anywhere.

**Choice:** leave `v_live_shelf_stock` as-is. Re-pointing it to `weimi_shelf_now()` would be a
regression, not a fix: it would lose the four-tier match cascade and `is_eligible_machine`,
which PRD-122's `v_lane_grain` (and everything built on it) depends on, in exchange for
nothing -- the doctrine D2 protects (WEIMI is the shelf truth, not `pod_inventory`) already
holds here.

**Why:** the PRD's problem description of this view does not match its current body. Fixing
a function that already satisfies the doctrine, by replacing it with a strictly weaker one,
would make the pipeline worse while "completing" a checklist line that was already true.

---

## D-004b. `bind_dispatch_fefo`'s `_bind_tally` already has `ON COMMIT DROP`

PRD-124 #39 / ONE-LOOP Phase 7 item 4 describe `_bind_tally already exists` warnings from a
missing `DROP TABLE IF EXISTS` between batches in `push_plan_to_dispatch_v16`. Read the live
body: (a) there is no function named `push_plan_to_dispatch_v16` -- the temp table lives in
`bind_dispatch_fefo`, which `push_plan_to_dispatch` calls at the end of every push; (b) that
`CREATE TEMP TABLE _bind_tally` already reads `... ON COMMIT DROP AS ...`. The bug as described
does not exist in the live function.

**Choice:** no change. Phase 7 item 4 is marked superseded, not done -- the underlying defect
was already fixed in a prior session's work, before this one started.

**Why:** verify before fixing; a `DROP TABLE IF EXISTS` added on top of an already-working
`ON COMMIT DROP` would be redundant, not a correction.

---

## D-006b. Phase 3 deferred items: G2/G4/G9 as draft columns, D1's literal ceiling

Two Phase 3 items are disclosed as not done, not silently dropped:

1. **G2/G4/G9 as boolean columns on `get_pod_refill_draft`.** That function is a large,
   separate object not yet read this session. Adding three informational booleans to it
   correctly requires reading it in full first (this session's own standing discipline), which
   the remaining time did not allow alongside everything else in Phase 3-12. The three checks
   themselves are simply gone from `validate_refill_plan`'s gate output (per spec: they are
   deleted, not silently blocking) -- what's missing is only their surfacing as an FE-visible
   flag on the draft.
2. **D1's literal "target = max_stock at velocity>=3 or venue_team, else least(10,max_stock)"
   fully encoded inside `engine_add_pod`.** That function's actual sizing logic is a banded
   score (`machine_band` 1/2/3 with fractional multipliers 1.00/0.60/0.30 against
   `cover_units`), not a two-branch literal -- D1's rule doesn't map onto it as a drop-in
   replacement, and attempting a deeper rewrite of an already-twice-modified 400+ line function
   risked a real regression for a QUALITY concern, not a safety one: G1 (the gate that used to
   block over-capacity fills) is already deleted from `validate_refill_plan`, so there is no
   gate depending on this ceiling being exact tonight. `hero_velocity_floor` (default 3) was
   added to `refill_policy_params` so this can be finished without another schema migration.

**Choice:** ship both PRD-125 Phase 3 acceptance-critical pieces (the five-gate rewrite, the
non-waivable approval) fully proven; carry these two forward as explicit open items rather
than reporting them done or quietly cutting them from the PRD.

**Why:** the checklist (Phase 12) is supposed to distinguish "done" from "open," not paper
over a gap -- and a rushed rewrite of engine_add_pod's scoring model, untested, would be worse
than leaving D1 partially applied and saying so.

---

## D-005. Three more Phase-1 "replacement targets" were already compliant

Read before writing, per standing discipline, on the remaining three named objects:

- `is_internal_move_dispatch` / `tg_mark_internal_move_pair`: read their live bodies --
  zero `pod_inventory` references anywhere. Detection is entirely `refill_dispatching`-based
  (a Remove and an Add New/Add on a different shelf of the same machine, same plan_date,
  same `boonz_product_id`) -- exactly D2's "from the plan's own Remove and Add New... not
  from lots." Already correct.
- `return_dispatch_line` / `receive_dispatch_line`: both archive/credit `pod_inventory` using
  `v_dispatch.shelf_id` -- the dispatch row's OWN shelf, set once at push time and never
  re-derived here. Neither function re-resolves shelf from a lot; the one `pod_inventory`
  write in each is a side effect (archiving/updating stock at a shelf already fixed by the
  dispatch row), not a placement decision. Already correct.

**Choice:** no migration for any of these four. Phase 1's actual code changes are:
`weimi_shelf_now` (new), `push_plan_to_dispatch` Remove path, `add_dispatch_row` Remove path,
and `align_pod_lots_to_weimi` + its cron wiring.

**Why:** applying "the same fix" to code that doesn't have the bug is not surgical -- it is
change for its own sake, and risks introducing a regression (D-004) or a needless behavioural
diff against the read-before-write discipline this whole session runs on.

---

## D-006. Phase 1's named proof machines cannot be replayed against real 09-15 rows

The proof asks to "rebuild the 09-15 IFLYMCC A08 and MPMCC-1058 A02 swaps... through the
real push." Both lanes' REMOVE plan_output rows are `operator_status='rejected'` today (all
three IFLYMCC-1024 A08 Remove rows, all three MPMCC-1058 A02 Remove rows) -- rejected sometime
after they were originally dispatched, per PRD-125's own account of "3 approval attempts...
6 shelves rewritten by hand" the night this plan was built. Their parent `pod_refill_plan`
rows still carry the ORIGINAL qty (8 and 15 respectively), so calling
`push_plan_to_dispatch('2026-09-15', ...)` for either machine trips the pre-existing
conservation/leakage guard (PRD-053) before it ever reaches the Remove-path logic being
tested -- `SUM(approved, undispatched children) = 0 <> pod_refill_plan.qty`. This is real,
already-there drift on live data, not something my change caused, and not in Phase 1's scope
to fix (it is a stitch-leakage / plan-hygiene question, not a WEIMI-vs-`pod_inventory`
question).

**Choice:** exercise the fix on a synthetic scenario on 2026-09-16 (no live rows, per the
standing rule's own named alternative to a rolled-back transaction) using the SAME real
machines, shelves, and the SAME real mismatch pattern found on this exact live data:
IFLYMCC-1024 A08's plan names "Pepsi - Black" but the Active `pod_inventory` lot for that
product actually sits on A07; MPMCC-1058 A02's plan names "Be-kind Bar - Almond & Sea Salt"
but its Active lot sits on A11. This is the literal bug shape D2 exists to kill (the lot's
shelf winning over the plan's shelf), reproduced from real current drift, not invented.

**Why:** proving the fix against a live plan already broken for an unrelated reason would
either report a false failure (blocked by the leak guard) or require weakening that guard
inside the test, which risks touching the canary. A synthetic same-shape scenario on a dead
date proves the same code path without either risk.
