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

## D-007. Phase 4 deferred items

Built and verified: `substitution_rules` table (RLS + S-308 revoke), seeded with CS's D4
rules against real `pod_products` ids, `find_substitutes_for_shelf` rewritten to read it
rule-first (old correlation logic retired, confirmed correct "nothing" behaviour on
NOVO-1023 where the chain targets are already on other shelves).

Not done, disclosed:

- **The scarce-stock and expired-on-shelf rules are seeded as rows but not engine-enforced.**
  They describe a cross-cutting ENGINE BEHAVIOUR (consolidate to one lane fleet-wide; pair a
  Remove with a substitute on the expired shelf), not a single-product substitution
  `find_substitutes_for_shelf` can express with its current signature. Wiring them requires
  touching `engine_add_pod`'s allocation loop directly, which was not attempted tonight given
  the engine_add_pod regression risk already noted in D-006b.
- **`get_pod_refill_draft` `exceptions` array** (every `no_rule_matched`, every gate failure,
  every WEIMI/lot disagreement) -- same reason as the G2/G4/G9 draft columns in D-006b: that
  function has not been read this session and needed its own budget.
- **FE settings table under `/refill` to list/add/deactivate rules.** Database-only session
  scope tonight; no FE work has been attempted yet (Phase 11 covers FE build/deploy). CS can
  manage rows via SQL against `substitution_rules` until a screen exists.
- **"Freakin Roasted"** has no matching `pod_products` row -- left out of the seed rather than
  guessed (see the migration file's own note).

**Why:** the four items above are all things `find_substitutes_for_shelf` and the table
schema genuinely cannot express alone -- forcing them in would mean guessing at
`engine_add_pod`'s internals or `get_pod_refill_draft`'s shape without having read either
carefully enough tonight to do so safely.

---

## D-008. Phase 5 (picker brain): a real, fleet-wide price-data gap blocks full A3/A6 proof

Built and verified: `pick_urgency_params.horizon_days` explicitly set to 3 (it already
existed at 2 from an earlier PRD -- overwritten, not silently left), `p1_threshold_aed`/
`p2_threshold_aed` confirmed at 150/50, `cooldown_days` confirmed at 1 (a
`cooldown_days_v126` column was mistakenly added first when I didn't check for the
existing column, then dropped -- caught before committing). `v_machine_priority` gains
`daily_revenue_aed`, `s_runout_aed`, `s_gap_aed`, `expiry_penalty_aed`, `stale_penalty_aed`,
`p_score_aed`, `p_tier_aed` as new trailing columns -- every existing column (`p_score`,
`p_tier`, `svc_track`, etc.) is untouched, per R7. `check_priority_surface_consistency()`
still returns 0 rows after this change.

**A1 PASSES**: AMZ-1038 (169.84) and AMZ-1029 (140.53) are the top two by `p_score_aed`.
**A2 PASSES**: GRIT/WPP/ALJLT/JET are not P1 under `p_tier_aed`.
**A4 PASSES** (trivially): every named "visited today" machine is P3 already, at or below
the P2 cap the rule asks for.

**A3 (ACTIVATEMCC should be P1) does not currently pass**, and the root cause is not a
formula bug: `v_current_price` returns `effective_price_aed = NULL` for Aquafina on this
exact machine (`machine_price` and `global_default_price` both NULL there) -- Aquafina is
this machine's highest-velocity lane (lane_dvel ~2.6/day across 3 facings, i.e. ~9/day at
the product grain, matching the PRD's own "9/day" claim almost exactly), so its real
revenue-at-risk is being priced at zero, and `p_score_aed` comes out 0.00. This is not
isolated: fleet-wide, 19,686 of 119,136 `v_current_price` rows (16.5%) have a NULL
`effective_price_aed`. An AED-denominated model is only as good as the price data under it,
and this is a genuine, pre-existing gap this session cannot fix (fabricating a price would
be worse than reporting a stale-priced lane as zero-risk).

**Not attempted, disclosed rather than faked**: the 30-day backtest (A7) and threshold
tuning, `pick_machines_for_refill` v12's `p_cars`/`p_per_car` cluster fill (R5, A5),
`get_machine_health`/Machine Health card exposure of `p_score_aed` (R6, FE). Given the price
gap just found materially affects the SAME score these all depend on, running a full
backtest or tuning thresholds against under-priced data tonight would produce a confidently
wrong answer rather than an honestly incomplete one.

**Choice:** ship the schema/scoring work, verified where the underlying data supports it,
and stop rather than paper over A3/A5/A6/A7 or invent price data to make them pass.

**Why:** the whole point of Rule Zero's "a proof fails, the phase is not done" is to prevent
exactly this -- reporting green on a number that is quietly built on a hole in the data.

---

## D-009. Phase 7 item 5 (junk 2029+ rows): `cancel_dispatch_line` cannot be used as specified

`mark_dispatched(p_dispatch_ids uuid[])` was built and verified (mirrors `mark_picked_up`
exactly; added to `enforce_canonical_dispatch_write`'s allowlist, which it was missing from).

The 76 `dispatch_date >= 2029-01-01` rows were confirmed live (matches the PRD's own count).
25 carry a `from_wh_inventory_id` pin. But **all 76 have `dispatched = false`**, and
`cancel_dispatch_line` explicitly requires `dispatched = true` to cancel a row, and
separately REFUSES any row with `from_wh_inventory_id IS NOT NULL` outright ("Use a
reverse-cancellation RPC (not yet implemented) to credit back WH stock" -- that comment is
in the function's own live body). So the literal instruction ("release pins, cancel through
the RPC") cannot be carried out with the RPC named: it would raise on every one of the 76
rows, for two independent reasons.

**Choice:** do not build a new bespoke writer to force this through under time pressure.
Releasing a warehouse pin incorrectly is a real stock-integrity risk (crediting back a
reservation that shouldn't be released, or leaving one dangling), and this is explicitly an
S2 item, not S1. Left undone, disclosed, with the exact blocker named, rather than inventing
a new RPC whose warehouse-reservation semantics were not verified tonight.

**Why:** "the engine is wrong and must be fixed" applies here too, just to `cancel_dispatch_line`
itself -- the fix is a genuine "reverse-cancellation RPC" as its own comment names, which is
schema/writer design work Dara and Cody should see before it ships, not a rushed patch.

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

---

## D-010. ONE-LOOP-2 Block A0 (1): horizon_days 3 to 4

`pick_urgency_params.horizon_days` was 3 (set last night in `prd12x_p5`, PRD-126 R1-R4), not
the 2 that a PRD-122 note assumed when it was written. Set to 4 per explicit CS instruction,
migration `20260915002000_prd122_r4_horizon_days_4.sql`. Both `s_runout_hero` (PRD-122) and
`s_runout_aed` (PRD-126) read this single row, so one change applies to both scores.

**Verified before/after:** `check_priority_surface_consistency()` (PRD-122 A11) returned 0
rows before and 0 rows after. `v_machine_priority` tier counts moved P1_RESTOCK 15 -> 16,
P2_MAINTAIN 0 -> 2, P3_OK 17 -> 14 (32 machines total, unchanged). `s_runout_hero` is nonzero
and tier improved (P3->P1 or into P2) for all four named machines: ALJLT-1015-0200-O1
(s_runout_hero 10.00, P1_RESTOCK), AMZ-1029-3003-O1 (79.17, P1_RESTOCK), AMZ-1038-3001-O1
(58.72, P1_RESTOCK), VOXMCC-1005-0201-B0 (23.11, P2_MAINTAIN).

**Why:** explicit CS instruction, and the doctrine reason holds: a longer horizon widens the
runout window, which should only ever pull machines up in priority, never down, so this
result is exactly the expected direction and the two consistency gates (A11) still pass.
Block B's backtest tunes `p1_threshold_aed` / `p2_threshold_aed` against horizon 4, not the
old horizon 3.

## D-011. ONE-LOOP-2 Block A0 (2): VOX-day dead-branch documentation

`pick_machines_for_refill`'s VOX-day branch (`vox_centroid`, the `hero_runway_days` off-day
gate, the `vox_emergency_offday` tag, its `ORDER BY`) is unreachable: the 3 `partner_filled`
machines have zero rows in `v_machine_priority`, so `svc_track='vox'` matches nothing,
`bool_and` over the empty set is NULL, `COALESCE(...,true)` makes `v_vox_all_equip` true, and
`IF v_is_vox_day AND NOT v_vox_all_equip` never fires. MCC clustering still works via
`sibling_ranked` on `r_cluster='VOX'` capped at `p_max_siblings`.

**Choice:** documented via `COMMENT ON FUNCTION` (migration
`20260915002100_prd122_r4_vox_day_branch_dead_code_comment.sql`) rather than an inline code
comment requiring a full `CREATE OR REPLACE` of the function body, because `COMMENT ON` is
metadata-only and carries zero risk of a transcription error in a large existing function.
Removal is out of scope, a separate later PRD. This comment will be carried forward verbatim
into v12 when Block B rebuilds `pick_machines_for_refill`, this time as an inline comment
since that CREATE is being written fresh anyway.

**Why:** CS asked for documentation only, no behaviour change; a metadata comment is the
lowest-risk way to satisfy that literally.
