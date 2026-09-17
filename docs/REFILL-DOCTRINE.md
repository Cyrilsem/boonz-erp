# Refill doctrine

The one page a new session reads first. Last updated 2026-09-17/18 (PRD-127).

## The six decisions (PRD-125), as they now stand

**D1. Fill to capacity is the rule, not the exception.** A lane whose product sells at 3/day
or more (`refill_policy_params.hero_velocity_floor`), or whose product's `source_of_supply` is
`venue_team`, fills to `max_stock` (WEIMI capacity, `slot_capacity_max` override applied).
Every other lane caps at `least(10, max_stock)`. Encoded in `engine_add_pod`'s `target_stock`
(candidates_with_machine_velocity CTE); the banded scoring (base_stock `want`, or the legacy
band-fraction model) still decides ordering/urgency, D1 only changed the ceiling `need_raw` is
clamped against.

**D2. WEIMI is the only source for what is on a shelf.** `weimi_shelf_now(machine_id)` is the
canonical read: product identity, stock, capacity, lane by lane. `pod_inventory` is read for
one thing only: the expiry date of what is physically there. It is never used to decide where
a Remove goes, what quantity, or whether a lane is empty. `align_pod_lots_to_weimi` runs
nightly at 22:00 UTC to keep `pod_inventory` lots aligned to WEIMI shelves.

**D3. Available stock means the warehouse that supplies that machine.** `wh_available_for(
machine_id, boonz_product_id)` is the one function: `venue_team`-supplied products resolve
against WH_MCC + WH_MM, everything else against WH_CENTRAL. Every caller (`engine_add_pod`,
`find_substitutes_for_shelf`, `validate_refill_plan` G8, `push_plan_to_dispatch`) goes through
it. Free stock subtracts pins from non-cancelled/skipped/returned/packed/dispatched dispatch
rows dated within the next 30 days -- nothing older, nothing further out.

**D4. The engine substitutes, not a human.** `substitution_rules` (rule_id, priority,
when_pod_product_id, when_condition, then_pod_product_id, then_qty_rule,
never_if_on_machine, active, note), read by `find_substitutes_for_shelf` in priority order,
checked against `wh_available_for` and against `weimi_shelf_now` for "never a product already
on another lane of this machine." Seeded rules: Evian -> Al Ain Zero (else Aquafina on a VOX
site), Hunter bags -> Hunter Canister, the snack chain (Freakin Roasted, Dubai Popcorn, Rice &
Corn, G&H, Ritz, Zigi) -> Benlian, Sunbites, Krambals in that order. No match: the lane stays
at its current level and the plan-date's exceptions surface it (see below). Scarce stock
(under 12 fleet-wide) needs no separate code -- `engine_add_pod`'s existing `prior_need`
allocation window, ordered by velocity then score, already gives a scarce product's warehouse
stock to the single highest-velocity lane that wants it first, and zeroes every lower-priority
lane once it runs out.

**D5 -- replaced.** The cron does NOT build every night unconditionally.
`refill_policy_params.gate0_require_manual_confirm` stays `true`. CS keeps the manual pick
gate. `confirm_and_build(plan_date, machine_names, cars)` sets the pick list to exactly the
given machines, assigns cars by cluster-then-`p_score_aed`, and runs the build for those
machines only -- called from the FE or from chat, never automatically. Cron 13
(`cron13_build_or_alert_v3` / `phaseF_stage1_prep_8pm_dubai`, 16:00 UTC / 20:00 Dubai) builds
only when something is confirmed+included; when nothing is, it writes one `monitoring_alerts`
row ("no picks confirmed for `<date>`") and exits.

**D6. The gate checks the engine's rules, nothing else.** `validate_refill_plan` runs exactly
five blocking checks, none waivable (the waiver table and argument are retired):

- **G3** an empty lane has no line and no substitution rule matched
- **G5** a product has no Active mapping anywhere
- **G7** a Remove with nothing coming in behind it on the same lane
- **G8** stock short at the supplying warehouse, per D3
- **G10** a line lands on a lane WEIMI says holds a different product, with no Remove

G1, G2, G4, G6, G9 were removed as gates. G2 (lane already >= 9 refilled) and G9 (FEFO expiry
within plan_date + 21) live on as informational booleans (`g2_flag`, `g9_flag`) on
`get_pod_refill_draft`. G4 (a low-fill lane with no line) is reinterpreted machine-level:
`g4_flag` is true on every row of a machine's draft when that machine has some OTHER WEIMI
lane at or below 20% full with no line today -- the original per-lane predicate can never be
true for a row that, by definition, already has a line.

## The truth table

| Question                                       | Source of truth                                    |
| ---------------------------------------------- | -------------------------------------------------- |
| What product is on a shelf, how much, capacity | WEIMI (`weimi_shelf_now`)                          |
| Expiry of what's physically on a shelf         | `pod_inventory`, expiry column only                |
| Available stock for a machine's product        | `wh_available_for` (D3 routing)                    |
| Price for AED-denominated scoring              | `v_current_price_filled` (fallback ladder below)   |
| What a machine should be refilled to           | `target_stock` inside `engine_add_pod` (D1)        |
| Who is on today's pick list                    | `machines_to_visit`, status `picked` or `cs_added` |
| Is a plan safe to push                         | `validate_refill_plan`'s five gates (D6)           |

## The five gates (D6)

See above. All blocking, none waivable, all read live data at validation time.

## Substitution rules -- where they live

Table `public.substitution_rules`. Read by `find_substitutes_for_shelf`, and by
`engine_add_pod`'s expired-on-shelf pass (writes a `pod_swaps` row with both
`pod_product_id_out`/`qty_out` and `pod_product_id_in`/`qty_in` when a rule resolves; nothing
written when it doesn't -- surfaces instead via `get_pod_refill_draft_exceptions`'
`no_rule_matched` category). No FE settings screen exists yet for listing/adding/deactivating
rules; edits go through SQL today.

## Picker brain (PRD-126)

`v_machine_priority.p_tier_aed` / `p_score_aed`: `s_runout_aed + 0.5*s_gap_aed +
expiry_penalty_aed + stale_penalty_aed`, all AED. `horizon_days = 4` (raised from 3 the night
before, per an explicit CS instruction so `s_runout_hero` and `s_runout_aed` both widen their
runout window). `p1_threshold_aed = 150`, `p2_threshold_aed = 50`, `hero_velocity_floor = 3`,
`cooldown_days = 1`. Prices resolve through `v_current_price_filled`, a fallback ladder built
2026-09-15 to close a 16.5% price-data gap: `effective_price_aed` when set, else this
machine's own 30-day realised price (from `sales_history`) when at least 3 units sold, else
the fleet median effective price for that pod product, else the fleet median realised price,
else 0 with `price_source='unpriced'` (5 lanes remain unpriced as of this writing, all at
0 velocity -- see `docs/unpriced-lanes-2026-09-15.md`). Not unique per `(machine_id,
pod_product_id, boonz_product_id)` -- its own fallback tiers can surface several rows for the
same triple; any caller joining onto it needs a `DISTINCT ON` collapse first (`v_machine_priority`'s
own `price_by_boonz` CTE does this; `propose_refill_plan`'s `lane_price` CTE does the same,
the hard way, after shipping without it first -- see PRD-127 below). `pick_machines_for_refill`
v12 (cluster fill by car, R5) and the Machine Health FE surface (R6) shipped 2026-09-15
(ONE-LOOP-3).

## PRD-127 -- propose_refill_plan (2026-09-17/18)

A read-only, chat-native "what would happen" proposal, sitting _before_ `confirm_and_build` in
the daily loop, not replacing it: `propose_refill_plan(p_plan_date, p_machine_names,
p_overrides)` builds from the full WEIMI lane list of every in-scope machine (default: the
plan date's confirmed pick list), never from a velocity ranking, and returns pre-rendered chat
strings, never raw lane rows. Every lane gets exactly one of ten `reason_code`s (see
`PRD-127-propose-refill-plan.md` section 6); an unclassified lane is a hard `RAISE`, not a
silent default. Genuinely writes nothing -- proven with real per-table DML guard triggers in
`docs/prd127-acceptance.sql` A1, not merely declared `STABLE` (that keyword is an optimizer hint,
not an enforced guarantee).

`refill_directives` (`directive_type='block'` only) lets CS durably tell the engine "never
recommend this again" -- on a `machine`, `pod_product`, or `boonz_product` -- via
`add_refill_directive`/`retire_refill_directive`, resolved by exact name match against
`machines`/`pod_products`/`boonz_products`, raising on zero or more than one match rather than
guessing (some real names collide across those three tables, e.g. "Evian - 1L" is both a
pod_product and a boonz_product name). `refill_swap_params` holds the two tunable constants the
allocation logic needs (`expired_priority_boost_aed`, `min_substitute_stock_units`) so CS can
retune without a migration.

The warehouse pool for contended allocation is built by calling `wh_available_for` directly
(once per distinct routing class present, summed) -- never a second copy of its
phantom/reservation/quarantine predicates, which is the only way to guarantee they can never
drift apart. Global allocation sorts by `aed_at_risk` (PRD-126 R1's own per-lane formula,
reused verbatim) descending, one running ledger per `boonz_product_id`, identical in shape to
`engine_add_pod`'s own `prior_need`/`final_qty` window.

Full spec: `PRD-127-propose-refill-plan.md` (reconstructed 2026-09-17 -- the file did not exist
anywhere in the repo or its git history when that turn started; see its own closing note and
`DECISIONS-2026-09-17.md` D-002). Daily-loop placement: `docs/REFILL-DAILY-LOOP.md`.

## What is NOT yet done (as of 2026-09-17/18, PRD-127)

- PRD-125 Phase 4's `exceptions` array on `get_pod_refill_draft` covers `no_rule_matched` and
  G5/G8 only, not the full G3/G7/G10/WEIMI-vs-lot-disagreement set the PRD asked for.
- PRD-124 PRD-116 leftovers and the 8-named-lines PRD-123 item (resolved by the real team
  before this session reached them).
- 57 of the 76 junk 2030-dated dispatch rows (all `packed=true`) still need a human-reviewed
  cleanup path; `reverse_cancel_dispatch_line` deliberately refuses them.
- A structural gap between committed migration filenames and the database's own
  `schema_migrations.version` values, historical (~30 files from before 2026-09-15) --
  reconciled going forward each session since (see DECISIONS-2026-09-15.md D-024).
- `align_pod_lots_to_weimi`'s expiry-inheritance fix (D-027, ONE-LOOP-3): written and
  dry-run-verified, gated on CS's own requested apply time.

Full detail on every decision, proof, and deferral: `DECISIONS-2026-09-15.md`,
`DECISIONS-2026-09-17.md`, `OVERNIGHT-REPORT-2026-09-15.md`.
