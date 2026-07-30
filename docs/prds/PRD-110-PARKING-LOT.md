# PRD-110 PARKING LOT

Replaces human gates in the ONESHOT loop (goal command PARKING protocol).
Two sections. Nothing here blocks the loop.

---

## DECISIONS-READY

Fully built, flag OFF, proven by fixture. One line CS runs to activate.

| #                            | What it is | Evidence | Activation (the single command) |
| ---------------------------- | ---------- | -------- | ------------------------------- |
| _(populated as phases land)_ |            |          |                                 |

---

## STUCK

Blocked after >2 attempts. What / why / what was tried / smallest unblock.

### S-01 · `weekly-procurement` skill does not exist (P0.5 consumer edit)

- **What:** BUILD SPEC P0.5 ends "weekly-procurement skill updated to read it (skill file edit)".
- **Why stuck:** no such skill file in `.claude/skills/` (inventory: boonz-health, cody,
  dara, stax, supabase-patterns, vox-analytics, refill-engine, new-machine-onboarding).
  Authoring a brand-new standing skill is scope CS owns (persona + operating law), not a
  mechanical edit.
- **Tried:** listed `~/.claude/skills` and project `.claude/skills` — absent in both.
- **Smallest unblock:** the DB-side contract is built regardless (`blocked_demand` +
  `v_blocked_demand_open` with aging). CS says "author weekly-procurement" and it wraps
  that view in one pass.
- **Loop impact:** none. P0.5's verifiable half (table, writers, view, fixture) proceeds.

### S-02 · `context-intelligence` event calendar absent (P2.4 factor source)

- **What:** `demand_calendar` should load "context-intelligence events".
- **Why stuck:** no such skill/table to read.
- **Smallest unblock:** CS names the event source (table or skill). Until then
  `demand_calendar` accepts `source='event'` rows written by RPC; the auto-loader covers
  `macro_kpi` + `dow` only.
- **Loop impact:** none — fixture 7 seeds its factor row directly, which is what it asserts.

---

## DECISIONS-READY (populated 2026-07-30)

| #        | What it is                                                                                                                                                                                                                                                                                                                                                                                                                                      | Evidence                                                                                                                                                                                                                                                                                                   | Activation (the single command)                                                                                          |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| **D-01** | **Gate 0 manual confirm (P0.3).** Stop cron 13 auto-confirming CS's machine picks. The gate (`_assert_gate_zero`) already exists and is already enforced by `engine_add_pod`; `build_draft_for_confirmed` merely pre-satisfies it by calling `confirm_machines_to_visit` itself before asserting. ⚠ **Designed, NOT yet built** — needs `build_draft_for_confirmed_v3` + `build_confirmed_now_v3` + default-OFF `gate0_require_manual_confirm`. | Live refusal reproduced: `Gate 0 not passed: 1 machine(s) picked but unconfirmed for plan_date 2030-01-04`. Defect located at the `v_auto_conf := confirm_machines_to_visit(...)` call preceding the gate. 2026-07-31 shows 10 picked / 10 `confirmed_at IS NULL` — cron will auto-confirm all 10 tonight. | (after build) `UPDATE refill_policy_params SET gate0_require_manual_confirm=true WHERE id=1;` + repoint cron 13 to `_v3` |
| **D-02** | **Wide slot_lifecycle sweep** — the 225 out-of-scope shelves the new guard withholds (102 on Active/`include_in_refill=false` incl. LVLUP partner machines, 123 on 5 Inactive warehouse pseudo-machines). Deliberately NOT applied: LVLUP is `partner_managed` and WS-J1 says the engine plans nothing there.                                                                                                                                   | `seed_missing_slot_lifecycle(true,NULL)` → `{"pending_count":0,"out_of_scope_skipped":225}`. Full per-machine decomposition in EXECUTION-LOG P0.2.                                                                                                                                                         | CS decides per cohort; there is no single safe command — do **not** drop the guard wholesale                             |

## STUCK (added 2026-07-30)

### S-03 · Cody SKILL.md misstates Article 14 — would falsely block all of PRD-110 shadow mode

- **What:** the cheat sheet says Article 14 bans `_v2`/`_new` parallel tables and lists that as an
  auto-refusal. The Constitution's real Article 14 is _"No snapshot tables **when a view
  suffices**… new tables that materialize a query result **for performance reasons** require ADR
  signoff."_
- **Why it matters:** under the cheat-sheet reading, `pod_refill_plan_shadow` and LAW 4
  ("shadow, don't switch") are unconstitutional. Under the real article they are fine but need an ADR.
- **Smallest unblock:** correct the Article 14 row + refusal bullet in `.claude/skills/cody/SKILL.md`;
  write `docs/architecture/ADR-shadow-plan-tables.md` before Phase 2 creates the shadow table.

### S-04 · P0.2 verify criterion "≥10 engine rows per machine" is not satisfiable

- **What:** BUILD SPEC P0.2 and fixture 3 assert ≥10 engine rows for MPMCC-1054 / MPMCC-1058 /
  IFLYMCC-1024. Post-fix actuals: 7 / 9 / 4.
- **Why:** row count tracks how full a machine is, not whether it is blind. Only 9 of 1058's 16
  shelves are below capacity; the rest are at/over cap where a no-line is correct.
- **Resolution applied:** substantive verify (G2=0, blind machines plan) is green and proven;
  fixture 3 seq 1 now asserts the underlying invariant. Original spec text preserved in
  `golden.fixtures.notes`.
- **Needs CS:** confirm the corrected acceptance criterion, or supply the intended one.

### S-05 · G3 silent skip on sub-capacity shelves (real defect, P2.5 work)

- **What:** MPMCC-1058 A05 (Krambals 5/6) and A11 (Be-kind Bar 18/20) are below capacity yet get
  **no plan line at all** — not even a qty=0 clamp row.
- **Why it's distinct:** A05 already had a current lifecycle row, so this is not the RC-06 gap.
  The engine drops sub-capacity shelves whose computed qty rounds to 0 and to which no clamp applies.
- **Unblock:** P2.5 unconditional floor. Encoded as fixture 3 seq 1 + seq 4, `phase_required='P2'`.

### S-06 · Aquafina blocked_no_wh on a VOX co-managed machine (fixture 5, live)

- **What:** 5 of MPMCC-1058's 9 lines are `qty=0 blocked_no_wh`, incl. Aquafina A01 and A15 at
  velocity **3.23/day** — the machine's fastest mover. `venue_group='VOX'`.
- **Why it matters:** under WS-A2/P1.1 Aquafina is venue-sourced on a co-managed VOX machine and
  must be **unconstrained**, never blocked on Boonz WH stock. Fixture 5's thesis, reproducing on
  a machine the spec never named.
- **Unblock:** P0.4 (sentinel bridge) then P1.1 `product_sourcing`. Until then these units are
  invisible demand — which is precisely what P0.5 `blocked_demand` is for.

### S-07 · Fixture-14 population found (opportunity, not a blocker)

- MPMCC-1058 A10/A12/A13/A14/A16 all report `stock > capacity` (18/12, 21/18, 20/18, 21/18, 21/16).
  Fixture 14 "sensor lie" needs no synthetic data — build it from these five real shelves.

---

## DECISIONS-READY (added 2026-07-30, relay leg 2)

| #        | What it is                                                                                                                                                                                                                                                                                                                                    | Evidence                                                                                                                                                                              | Activation (the single command)                                                                                                                       |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **D-03** | **Historical `blocked_demand` backfill.** The ledger was populated for 2026-07-30 only. 57 earlier plan_dates have derivable gaps (788 `blocked_no_wh` + 101 `partial_wh_limited` rows fleet-wide, all dates). Deliberately NOT applied: booking months-old blocked demand as _open_ hands procurement a worklist of purchases that are moot. | `record_blocked_demand_v3('2026-07-30')` returned `gaps_found:20, units_blocked:107` and is idempotent over 4 runs. The same derivation works on any past date with no schema change. | `SELECT public.record_blocked_demand_v3(d) FROM (SELECT DISTINCT plan_date d FROM pod_refills WHERE plan_date < CURRENT_DATE) x;` (one call per date) |

## STUCK (added 2026-07-30, relay leg 2)

### S-08 · `engine_add_pod` resolves live `driver_feedback` from any fixture run (engine-freeze blocked)

- **What:** the engine tail matches `driver_feedback` on `(machine_id, pod_product_id)` only - the
  `plan_date` scope applies to the `pod_refills` join, not to the feedback. So a golden fixture
  planning a real machine on a synthetic 2030 date resolves REAL open driver feedback, stamped
  `resolved_by_engine`.
- **Damage so far: zero, measured.** `v_driver_feedback_demand` returns 0 rows and 0 feedback rows
  were resolved on 2026-07-30. 8 rows are open but none surface in that view. The exposure is
  latent, arming the moment a driver files feedback on a machine any fixture plans.
- **Why stuck:** the fix belongs inside a frozen Family-A engine body (WAVE1-2-UNBLOCK + LAW 3).
  The alternative - the harness snapshotting/restoring `driver_feedback` around each engine call -
  is the test harness writing live business data and needs its own Dara/Cody pass.
- **Mitigation shipped:** tripwire assertion seq 90 on fixtures 3 and 105 (`20260730130007`)
  asserts the open-feedback count is unchanged across the fixture. Currently green.
- **Smallest unblock:** at engine unfreeze, add `AND dfd.machine_id IN (SELECT machine_id FROM
machines_to_visit WHERE plan_date = p_plan_date)` (or scope by the plan being built) to the
  feedback subquery. One migration, Cody class (b).
- **Loop impact:** none while the tripwire is green. If it ever goes red: HALT per LAW 8, fix the
  engine scope. Do NOT disable the assertion.

### S-09 · blocked_demand INSERT inside the engine tail (post-freeze simplification, not needed)

- **What:** BUILD SPEC P0.5 asks for the ledger write to happen in `engine_add_pod`'s tail.
- **Why parked:** engine freeze, and the tail's `procurement_gaps` JSON is name-keyed and
  ephemeral so it is the wrong source anyway. The shipped design derives the identical row set
  from `pod_refills` (uuid-keyed) and is driven by cron 43.
- **Loop impact: none.** This is a cosmetic consolidation, not a capability. If it is ever done,
  `record_blocked_demand_v3` must stay as the canonical writer (Article 1) and the engine should
  call it rather than INSERT directly.

## STUCK updates (2026-07-30, relay leg 2)

### S-01 · `weekly-procurement` skill - DB half now BUILT

- The consumer contract exists in production: `v_blocked_demand_open` with aging buckets
  (`fresh` <3d, `watch` 3-6d, `aging` 7-13d, `critical` >=14d from plan_date), populated nightly
  by cron 43, currently 20 open rows / 107 units for 2026-07-30.
- Still stuck: authoring the standing skill persona itself (CS owns that). The remaining work is
  one pass wrapping this view - no DB work left.

### S-03 update (2026-07-30, relay leg 2) - cheat-sheet half FIXED, ADR half still open

- **Fixed:** `.claude/skills/cody/SKILL.md` Article 14 corrected in all three places it was wrong
  (cheat-sheet row, DDL checklist step 4, refusals list), plus a new "Article 14, stated precisely"
  section quoting the Constitution verbatim. Verified against `01_constitution.html` this leg, not
  taken from leg 1's summary: the real article is "No snapshot tables **when a view suffices**; new
  tables that materialize a query result **for performance reasons** require ADR signoff." It says
  nothing about `_v2`/`_new` suffixes. The operative test is **silent staleness**, not the name.
- **Still open:** `docs/architecture/ADR-shadow-plan-tables.md` must be written before Phase 2
  creates `pod_refill_plan_shadow` (that table DOES materialize engine output, so the ADR clause
  genuinely applies to it). `blocked_demand` did not need one - it is an append-only ledger holding
  state no view can derive.

---

## DECISIONS-READY (added 2026-07-30, relay leg 3)

| #        | What it is                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Evidence                                                                                                                                                                                                                | Activation (the single command)                                                                                                                          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **D-04** | **Fade Fit sentinel lifecycle (P0.4 bridge).** 8 rows minted at WH_MCC + WH_MM (4 variants x 2 WH) at `warehouse_stock=999`. These are NOT constants - pack debits them like real stock (live siblings: Skittles WH_MCC 967, Aquafina WH_MCC 686, Galaxy Milk 991). So the bridge decays and will eventually re-block Fade Fit silently. Two futures: re-top periodically, or retire at P1.3 once `product_sourcing` makes venue-sourced unconstrained by definition. **Recommended: do nothing now, retire at P1.3** - re-topping deepens the dependency on the fake-stock pattern PRD-110 exists to delete. | Fixture 5 green 7/0 (seq 4 `wh_available_pod=3996`). Containment measured: exactly 5 machines gained availability, all `venue_group='VOX'`, 0 fully-managed. Mint audited to actor role `warehouse`, `lines_updated:0`. | Re-top: `adjust_warehouse_stock` on the 8 `wh_inventory_id`s in EXECUTION-LOG P0.4 with `new_warehouse_stock=999`. Retire: covered by P1.3 + fixture 24. |

## STUCK (added 2026-07-30, relay leg 3)

### S-10 · WH_CENTRAL-served VOX machines are structurally unreachable by any sentinel

- **What:** P0.4 unblocks Fade Fit on 4 of the 6 live Fade Fit shelves. The remaining 2
  (ACTIVATEMCC-1037 A02 need 7 + A03 need 3 = **10 units**) stay `blocked_no_wh`.
- **Why:** `engine_add_pod` scopes availability to
  `warehouse_id = ANY(ARRAY[primary_warehouse_id, secondary_warehouse_id])`. Three VOX machines
  (ACTIVATEMCC-1037, MPMCC-1054, MPMCC-1058) have `primary = WH_CENTRAL` and **no secondary**, so a
  sentinel at WH_MCC/WH_MM is invisible to them.
- **Why the obvious fix is REFUSED, not merely deferred:** minting Fade Fit at WH_CENTRAL would make
  it appear available to all **26** WH_CENTRAL-served machines, including fully-managed
  AMAZON / OHMYDESK / WPP / VML / GRIT / NOVO / ADDMIND / INDEPENDENT offices that genuinely need real
  Boonz stock. That is phantom availability - a driver dispatched against stock that does not exist.
  The sentinel pattern is only safe because WH_MCC/WH_MM serve VOX exclusively.
- **Smallest unblock:** P1.1 `product_sourcing` - a per-(machine, product) sourcing edge, where
  `source='venue'` means unconstrained **by definition** rather than by a fake 999 row. Then the
  machine's warehouse assignment stops being the thing that decides whether a venue-supplied product
  is plannable.
- **Loop impact:** none. Encoded as fixture 5 **seq 10** (`phase_required='P1'`), which goes green the
  moment P1.1 lands and is honestly red/skipped until then. The 10 units are visible to procurement
  via `blocked_demand` in the meantime, which is exactly P0.5's job.

## STUCK updates (2026-07-30, relay leg 3)

### S-05 · GENERALISED - not an MPMCC-1058 quirk

- Reproduced on a **second machine and a second product** in fixture 5's red baseline:
  **ACTIVATE-2005 B04 (Fade Fit 5/12) and B07 (7/8)** are sub-capacity and receive **no plan line at
  all** - not even a qty=0 clamp row. Velocity 0.13/day, so the computed qty rounds to 0 and the row
  is dropped instead of clamped.
- Restated: the engine drops any sub-capacity shelf whose computed qty rounds to 0 and to which no
  clamp applies, regardless of machine or lifecycle state. This makes it a fleet-wide G3 violation
  class, not a per-machine defect, and raises the value of P2.5's unconditional floor.
- Still P2.5 work. Fixture 3 seq 1/4 and (once P2 opens) fixture 5's shelf coverage both bind it.

### S-06 · HALF-CLOSED by P0.4

- The Fade Fit half of the thesis is proven and fixed on sentinel-reachable machines: fixture 5 seq 2
  green, `wh_available_pod` 0 -> 3996, 4 of 6 shelves unblocked.
- **Still open:** the Aquafina half on **MPMCC-1058** (velocity 3.23/day, the machine's fastest mover)
  and the ACTIVATEMCC-1037 residue. Both are WH_CENTRAL-served, so both are now precisely S-10, not a
  separate mystery. Aquafina _does_ have MCC/MM sentinels already (686 / 889) - they simply cannot be
  seen from WH_CENTRAL. P1.1 closes both.

## DECISIONS-READY updates (2026-07-30, relay leg 3)

### D-01 · Gate 0 manual confirm - NOW BUILT (was "designed, not yet built")

The ⚠ on D-01 is cleared. All three objects exist in production and the flag is live at `false`:

- `refill_policy_params.gate0_require_manual_confirm` boolean NOT NULL DEFAULT **false**
- `build_draft_for_confirmed_v3(date, boolean)` - cron-facing, reads the flag
- `build_confirmed_now_v3(date)` - on-demand build for already-confirmed machines
- `_build_draft_core_v3(date, boolean, boolean)` - shared body, REVOKEd from PUBLIC

**Evidence:** migration `20260730140003`. Five paths verified on synthetic `2030-06-17` with **zero**
engine runs and zero plan-table writes (the seeded machine has `is_included=false`, so the core
returns `no_included_machines` after the gate and before stage 2a): flag ON + unconfirmed ->
`awaiting_confirmation` with a 1-entry `pick_list`; flag ON + `build_confirmed_now_v3` -> refuses;
after confirm -> gate passes; flag OFF -> auto-confirms (legacy parity intact);
flag OFF + `build_confirmed_now_v3` -> **still refuses** (it ignores the flag by design, so the
"build what I confirmed" button can never become a back-door auto-fallback).
Post-conditions asserted: flag back to false, 0 rows left on the test date, `driver_feedback` 8 -> 8.

**ACTIVATION (2 statements, in this order):**

```sql
-- 1. turn the gate on
UPDATE public.refill_policy_params SET gate0_require_manual_confirm = true WHERE id = 1;
-- 2. repoint cron 13 at v3 (currently: SELECT public.build_draft_for_confirmed(public.resolve_refill_plan_date());)
SELECT cron.alter_job(13, command =>
  $$SET statement_timeout='1200000'; SELECT public.build_draft_for_confirmed_v3(public.resolve_refill_plan_date());$$);
```

**Rollback = flip the flag back to false** (v3 then behaves identically to v1), or re-point cron 13 at
`build_draft_for_confirmed`. v1 is untouched and still the live callee.

⚠ **What CS must know before flipping:** the nightly 20:00 Dubai build will stop producing a draft on
its own. It will pick, stop, and return `awaiting_confirmation` + the pick list. Someone must then
confirm and call `build_confirmed_now_v3(plan_date)` (or wait for the next cron cycle) or **there will
be no plan that night**. That is the intended wave-1 behaviour per CS decision #1 ("NO auto-fallback"),
but it converts the nightly plan from automatic to CS-gated, so it wants an FE confirm button
(Stax) before it is switched on in earnest. Until the flip, the auto-confirm defect remains live every
night - 2026-07-31 will auto-confirm its 10 picked machines.

---

## DECISIONS-READY (added 2026-07-30, relay leg 4)

### D-05 · Vitamin Well price-error restatement (P0.6(b)) - 2 lines, financial impact

**What:** two `purchase_orders` lines from **2026-07-15**, both Union Coop, both the same
data-entry bug: the operator typed the **line total (9.25)** into the **unit price** field.

| po_line_id                             | product                | ordered | recorded unit | recorded total | proven true unit |
| -------------------------------------- | ---------------------- | ------- | ------------- | -------------- | ---------------- |
| `1e7bae8e-7b39-46c1-8d66-81a40b95cba6` | Vitamin Well - Reload  | 19      | **0.4868**    | 9.25           | **9.2500**       |
| (same-day Upgrade line, PO 9222 batch) | Vitamin Well - Upgrade | 8       | **1.1563**    | 9.25           | **9.2500**       |

**Evidence:** arithmetic is exact - 9.25 / 19 = 0.4868, 9.25 / 8 = 1.1563. The true price is not
inferred from a category average: the **same product, same supplier, same day** appears at
**10 @ 9.2500 = 92.50** (Reload) and **10 @ 9.2500** (Upgrade).

⚠️ **Why this is parked and not applied:** BUILD SPEC's first option
(`purchase_outcome='price_error'`) is **not implementable** - the CHECK constraint allows only
`('received','not_purchased')`, and overwriting `'received'` would erase the fact that the units
were physically received. The only legal path is the canonical writer, which **restates recorded
spend on the Reload line from AED 9.25 to AED 175.75 (19x)** and changes COGS. That is CS's
decision, not the loop's.

**Activation (per line, canonical writer, reason mandatory):**

```sql
SELECT public.edit_purchase_order_line(
  '1e7bae8e-7b39-46c1-8d66-81a40b95cba6'::uuid,
  19,        -- ordered qty unchanged
  9.2500,    -- corrected unit price
  NULL,      -- expiry unchanged
  'PRD-110 P0.6(b): line total 9.25 was entered as unit price (9.25/19=0.4868). True unit price proven by same product/supplier/day at 10 @ 9.2500.');
```

Repeat for the Upgrade line with `8, 9.2500`. **If CS instead wants a non-destructive marker**, the
schema change is to widen the `purchase_outcome` CHECK to include `'price_error'` (Dara + Cody), so
the receipt fact and the price flag can coexist.

### D-06 · McVities Digestive - Mini Regular pod mapping (P0.6(a)) - needs a reweight, not an insert

**What:** `14c1020d-a346-4f9a-9e6d-9492aff5a74e` has **0** active `product_mapping` rows.
**Target pod CONFIRMED as the spec's default:** both siblings (Mini Dark Chocolate
`09488b91-...`, Mini Milk Chocolate `1e2d2598-...`) map to **Snack Bar**
`9edc81fe-57f9-4632-9552-b77a9003293d` across **19 scopes** (1 global default + 18 machine-scoped).

⚠️ **Two reasons the obvious INSERT is wrong:**

1. `split_pct` is per-scope and must sum to 100 per (pod, machine): live values include 15.00,
   33.33, 25.72, 16.67, 10.00, 5.00. Adding a third McVities variant **dilutes all 19 existing
   scopes**, so this is a `reweight_pod_splits` operation, not an insert.
2. Mini Regular currently has **0 WH stock**, so mapping it makes a variant plannable with nothing
   behind it - manufacturing exactly the blocked demand P0.5 exists to surface.

Also note `product_mapping` has **no canonical writer** (no `*_product_mapping*` RPC exists), so any
apply is a raw table write and wants a Dara/Cody pass of its own.

**Activation (CS confirms pod + scope breadth first):** add Mini Regular to Snack Bar at the global
default scope only, then reweight:

```sql
-- 1. CS confirms: pod = Snack Bar, scope = global default only (or names the machine list)
INSERT INTO public.product_mapping
  (pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, mix_weight, source_of_supply)
VALUES ('9edc81fe-57f9-4632-9552-b77a9003293d','14c1020d-a346-4f9a-9e6d-9492aff5a74e',
        NULL, 0, true, 'Active', 1, 'boonz_wh');
-- 2. then reweight so the pod's splits still sum to 100 at every scope
SELECT public.reweight_pod_splits('9edc81fe-57f9-4632-9552-b77a9003293d'::uuid);
```

**Recommended:** do NOT apply until Mini Regular actually has WH stock, else it becomes blocked
demand on day one.

## STUCK (added 2026-07-30, relay leg 4)

### S-11 · `routing_gap` is a legal blocked_demand reason with NO writer (latent LAW-5 hole)

- **What:** `blocked_demand_reason_check` permits `routing_gap`, but neither
  `record_blocked_demand_v3` nor `_blocked_demand_gaps_v3` ever emits it. Ledger currently holds
  **0** routing_gap rows. So a unit blocked purely because its stock sits in an unreachable
  warehouse is **silently invisible** to procurement - the failure mode LAW 5 forbids.
- **The class is real, but not where the spec said.** BUILD SPEC P0.6(e) described Pepsi Black,
  CENTRAL -> MCC. That does **not** reproduce: Pepsi - Black has 101 units all at WH_CENTRAL, and
  **zero** Active/include_in_refill machines lack WH_CENTRAL visibility, so all 12 of its live
  shelves can see that stock. Pepsi Black planned healthily on 3 machines on 2026-07-30.
- **What the detector actually found:** `VOXMM-1013-0101-B0` (primary WH_MM, secondary WH_CENTRAL)
  blocked on products stocked **only at WH_MCC** - 6 rows, all silent `qty=0`, on 2026-07-24 (4)
  and 2026-06-13 (2), 1-4 units each. Direction is **MM <- MCC**, not CENTRAL -> MCC.
- **Not backfilled on purpose:** all 6 are historical. Booking them as _open_ repeats the D-03
  anti-pattern (a procurement worklist of moot purchases).
- **Detector (proven, reusable as the writer's classification rung):** a blocked/limited
  `pod_refills` row whose pod family has `warehouse_inventory` stock **only** in warehouses outside
  `ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id]`, with a `NOT EXISTS` guard confirming no
  reachable warehouse holds any. Full query in EXECUTION-LOG leg 4.
- **Smallest unblock:** at **P3.1** (substitution ladder, fixture 6) the "alt WH / auto-transfer"
  rung is built anyway - classify that rung's failure as `routing_gap` inside
  `record_blocked_demand_v3` (it must stay the canonical writer, Article 1). One migration.
- **Loop impact:** none today (class has no current members). Becomes a real gap the moment a
  machine loses WH_CENTRAL visibility or stock concentrates in MCC/MM.

### S-12 · `preflight_refill_plan` is in neither RPC_REGISTRY nor METRICS_REGISTRY

- **What:** the function (12 invariants, now `set_version v2`) is the stitch commit gate, yet it
  appears in **no** registry. Cody flagged it during the P0.6(d) review; it is a pre-existing
  PRD-109 omission, not caused by this leg.
- **Why it matters:** Article 16's enforcement depends on the registry naming the canonical object
  per metric. INV-06 is adjacent to the registered "Refill execution accuracy" metric
  (`v_refill_accuracy`) and the two must stay explicitly disjoint - `v_refill_accuracy` covers
  `REFILL`/`ADD_NEW`, INV-06 covers `REMOVE`/`M2W`. Undocumented, a future leg could merge them and
  silently lose one domain.
- **Also uncovered:** `proacl` grants `EXECUTE` on `preflight_refill_plan` to **`anon`**. Left
  untouched (LAW 10) - it belongs to the existing revoke-anon backend-tightening carry-forward.
- **Smallest unblock:** add a Read-only-helpers row to `RPC_REGISTRY.md` naming the 12 invariants and
  the v2 predicate, plus a METRICS_REGISTRY note that plan-conservation (REMOVE/M2W) is INV-06 and
  is deliberately disjoint from `v_refill_accuracy`. Doc-only, no DB change.

## DECISIONS-READY / STUCK updates (2026-07-30, relay leg 4)

### D-02 unchanged · D-03 unchanged · D-04 unchanged (Fade Fit sentinels still draining)

### S-04 · CLOSED by fixture 10's precedent (acceptance-criterion pattern now established)

S-04 asked CS to confirm a corrected acceptance criterion after BUILD SPEC P0.2's ">=10 engine rows"
proved unsatisfiable. Leg 4 hit the same class of problem in P0.6(d) (a spec clause that, taken
literally, would have destroyed a real invariant) and resolved it the same way: implement the spec's
**intent**, preserve the original text in `golden.fixtures.notes`, and log an explicit SPEC
CORRECTION with the measurement that justifies it. That is now the house pattern for spec-vs-reality
conflicts under LAW 13. S-04 still wants a one-line CS ack, but it no longer blocks anything and
needs no new analysis.

### S-05, S-06, S-07, S-08, S-09, S-10 unchanged

S-08's tripwire (seq 90) is now carried on **four** fixtures (3, 5, 10, 105) and is green on all
four. Fixture 10 calls no engine, so it has no S-08 exposure by construction; the assertion is
carried anyway as cheap insurance.

---

## DECISIONS-READY (added 2026-07-30, relay leg 5)

### D-07 · `machines.operating_model` backfill apply (P1.1(i)) — BUILT, generated, flag-off

**What:** classify all 37 Active machines into the three WS-J1 operating models. The column, the
generated mapping, the canonical writer and the batch applier are all live; **nothing is
classified** (`operating_model IS NULL` on 100/100 machines) because BUILD SPEC P1.1 says CS
reviews the generated mapping before apply.

**Evidence:**

- `v_machine_operating_model_proposed` — a VIEW, so the mapping cannot go stale (Article 14).
  Dry run: **37 machines would change**, 0 currently classified.
  Rule: `venue_group='VOX'` → co_managed (11) · LVLUP/LevelUp → partner_managed (3) ·
  else fully_managed (23). Restricted to `status='Active'`, so the 2 Inactive warehouse
  pseudo-machines are deliberately left unclassified.
- `apply_proposed_operating_models_v3(true)` returns the full per-machine plan plus
  `conflict_edges: 286`.
- Applying is SAFE against the 4022 live sourcing edges: the backfill already resolved every edge
  using the same proposed model, so `set_machine_operating_model_v3`'s contradiction guard passes
  for all 37. Proven by negative test — the guard correctly REFUSES `fully_managed` on MPMCC-1058
  (holds venue edges) and `partner_managed` on AMZ-1029 (holds boonz_wh edges).

⚠️ **What CS must know before applying:**

1. It ARMS the two constraint triggers. While `operating_model IS NULL` they are inert by design;
   after apply, a `venue` edge on a fully-managed machine and a `boonz_wh` edge on a partner-managed
   machine become impossible. That is the intent, but it is a live behaviour change.
2. **The 286 conflict edges.** 23 machines the rule calls `fully_managed` carry a `venue_team`
   `product_mapping` row for some product (4 AMZ, JET, NOVO explicitly, plus global-default
   inheritance). WS-J1 says a fully-managed machine is Boonz-sourced by definition, so the backfill
   resolved all 286 to `boonz_wh`. **Nothing was destroyed** — `product_mapping` is untouched and
   `v_product_sourcing_model_conflicts` lists every one. CS's call is whether those machines are
   really fully-managed or whether those products are really venue-supplied.
3. It does NOT change any plan. No engine reads `operating_model` or `product_sourcing` yet;
   consumption is `engine_add_pod_v3` in Phase 2.

**ACTIVATION (one statement, dry-run first):**

```sql
SELECT public.apply_proposed_operating_models_v3(true);   -- review the plan + conflict count
SELECT public.apply_proposed_operating_models_v3(false);  -- apply
```

**Rollback:** there is no bulk un-classify by design (Article 1 — the column has one writer).
Per machine: `SELECT public.set_machine_operating_model_v3('<machine_id>','<old_model>','rollback …');`
To revert to fully unclassified, a one-line migration setting `operating_model = NULL` fleet-wide is
the honest route, and it is safe precisely because NULL is the inert state.

**Promotion to NOT NULL** (the other half of BUILD SPEC P1.1's `enum(...) NOT NULL`) belongs to this
activation, AFTER the backfill: `ALTER TABLE public.machines ALTER COLUMN operating_model SET NOT NULL;`
It cannot ship before, since every machine is NULL today.

## STUCK updates (2026-07-30, relay leg 5)

### S-10 · HALF-CLOSED by P1.1 — truth layer done, engine consumption is Phase 2

- **Closed at the truth layer, proven:** `resolve_product_sourcing_v3` returns `venue` for all 4
  Fade Fit variants on ACTIVATEMCC-1037 (the WH_CENTRAL machine no sentinel can reach) and for
  Aquafina on MPMCC-1058. Bound by fixture 5 **seq 11** and **seq 12**, both green.
- **Containment proven, not assumed:** fixture 5 **seq 13** asserts zero `venue` edges on any
  `fully_managed` machine — a venue edge means unconstrained, so one on an office would be exactly
  the phantom availability that made a WH_CENTRAL sentinel unacceptable. Currently 0.
  Fixture 5 **seq 14** asserts the resolver's unknown-edge fallback is `boonz_wh`, i.e. the
  fail-safe points at CONSTRAINED, never at unconstrained.
- **Still open, and it is not what the leg-4 pointer predicted:** the 10 units still plan as
  `blocked_no_wh`, because `engine_add_pod` (v19) computes `wh_avail` inline from
  `warehouse_inventory` scoped to `ARRAY[primary, secondary]` and reads `product_sourcing`
  **nowhere**. Editing it is barred by LAW 3 and the Family-A freeze. Consumption is
  `engine_add_pod_v3` = **Phase 2** (P2.1–P2.6). See the leg-5 SPEC/POINTER CORRECTION.

### S-06 · Aquafina half now HALF-CLOSED on the same terms as S-10

- The sourcing edge is correct (`venue` on MPMCC-1058, fixture 5 seq 12 green). The blocked units
  persist until the Phase-2 engine reads the edge. S-06 and S-10 are now the same single
  outstanding item: **engine_add_pod_v3 must consume product_sourcing.**

### S-01, S-02, S-03 (ADR half), S-04, S-05, S-07, S-08, S-09, S-11, S-12 unchanged

S-03's ADR half is now IMMINENT, not merely pending: Phase 2 is the next phase and it creates
`pod_refill_plan_shadow`. `docs/architecture/ADR-shadow-plan-tables.md` must be written first.

### D-01, D-02, D-03, D-04, D-05, D-06 unchanged

D-04 note: the 8 Fade Fit sentinels (7992u) are still draining and still the ONLY thing keeping Fade
Fit plannable on the MCC-served VOX machines, because the engine cannot yet see the sourcing edges.
The recommendation stands — retire at P1.3, do not re-top — but the retirement now has a hard
prerequisite it did not have before: **engine_add_pod_v3 must consume product_sourcing first**, or
retiring the sentinels re-blocks Fade Fit fleet-wide.

---

## STUCK (added 2026-07-30, relay leg 6)

### S-13 · `engine_add_pod` v19 uses `velocity_30d` in two incompatible units

- **What:** `slot_lifecycle.velocity_30d` is units **per DAY** over a 30-day window. Measured this
  leg against `v_shelf_sales_identity.dvel` on the 8 highest-volume shelves: ratio **1.00-1.02**
  (e.g. 21.70 vs 21.67 with `units_30d = 650`). The engine body then reads it three ways:
  - `b.v30 / 30.0 >= v_abs_velocity_floor` - divides an already-daily rate, so the absolute-velocity
    floor effectively never binds (~30x too small).
  - `ROUND(SUM(c.v30) OVER (PARTITION BY machine_id) / 30.0, 2) AS machine_daily_velocity` - same
    error, and this feeds the machine-band logic that scales quantities (bands 1/2/3 -> 1.00/0.60/0.30).
  - `r.v30 * 30.0` into `compute_refill_decision` - treats it as daily and converts to a window
    total, which is the CORRECT reading. So the function disagrees with itself.
- **Why stuck:** the fix is inside a frozen Family-A engine body (LAW 3 + the engine freeze). It is
  also not a one-line change: correcting the floor and the band divisor moves live quantities, so it
  needs its own fixture and a shadow diff, which is exactly what P2.1 is.
- **Loop impact: none today** - v19's behaviour is unchanged and its outputs are the baseline every
  fixture is written against. The risk is a future leg "fixing" one of the three sites in isolation.
- **Smallest unblock:** P2.1 `engine_add_pod_v3` reads `v_shelf_state.velocity_instock` (a daily rate
  by construction) and never re-derives from `velocity_30d`. Encode the floor and the band divisor
  against a fixture that pins expected quantities BEFORE changing either.

### S-14 · P1.2 consumer migration: FE machine page + advisory (Stax) not done

- **What:** BUILD SPEC P1.2 says "ALL consumers migrate: engines (P2+), preflight, FE machine page
  (Stax - FE's independent scorer DELETED), advisory skill."
- **Status:** the prerequisite - a canonical `v_shelf_state` - now exists and is proven. Engines are
  P2 by law and preflight is P2.6 by spec, so the only consumer that COULD move today is the FE.
- **Why parked:** it is a Stax deliverable in the FE repo (delete the second scorer, repoint the
  machine page), it ships through a Vercel deploy, and the last FE deploy carry-forward
  (`Batch-3 FE deploy`) is still open. Doing it inside a backend leg would be scope drift (LAW 10).
- **Loop impact:** G1 ("one truth: 1 view, FE scorer retired") cannot be fully claimed until this
  lands. The DB half of G1 is done. Recorded here so the Phase-1 gate is not silently over-claimed.

## STUCK updates (2026-07-30, relay leg 6)

### S-10 / S-06 · truth layer now visible PER SHELF (still half-closed, unchanged in substance)

`v_shelf_state` shows `ACTIVATEMCC-1037-0000-L0` A02/A03 Fade Fit = `venue` and MPMCC-1058's eight
Aquafina shelves = `venue`, with the two Soft Drinks Mix shelves = `mixed` (venue Aquafina beside
Boonz Pepsi in one pod). Fixture 3 seq 16 binds it. The units still plan as `blocked_no_wh` because
`engine_add_pod` v19 reads none of this - P2 remains the closing move.

### S-03 · ADR half UNCHANGED and now the next blocking item

`docs/architecture/ADR-shadow-plan-tables.md` must be written before Phase 2 creates
`pod_refill_plan_shadow`. Phase 1 has one task left (P1.4) plus P1.3, so the ADR is due within the
next two legs.

### S-01, S-02, S-04, S-05, S-07, S-08, S-09, S-11, S-12 unchanged

S-08's tripwire stayed green across all four fixtures on every run this leg.

## DECISIONS-READY updates (2026-07-30, relay leg 6)

### D-01 through D-07 unchanged

No flag was flipped and no parked activation was applied this leg. Two state notes for CS:

- **`refill_settings.swaps_enabled` is `true`** (since 2026-07-13 01:28 UTC), not `false` as every
  prior pointer and MEMORY.md claim. Nothing in PRD-110 touched it; it gates the frozen
  `engine_swap_pod`. Flagged rather than "corrected" - if it should be off, that is a CS decision.
- **The fleet is 102 machines** (37 Active / 65 Inactive), not the 100 quoted in D-07's prose. D-07's
  actual scope (37 Active machines to classify) is unaffected.

---

## STUCK (added 2026-07-30, relay leg 7) - THE BLOCKER

### S-15 · ⛔ HARD BLOCKER · no DDL-capable DB path in the session (Supabase MCP absent)

- **What:** every prior leg executed SQL through the **Supabase MCP** tools (`execute_sql`,
  `apply_migration`, `list_migrations`). In relay leg 7's session those tools are **not present**,
  so no migration can be applied, no `golden.*` object can be read or run, and no `pg_catalog`
  query can be issued.
- **Verified absent, not assumed** (5 independent probes, leg 7):

  1. `ToolSearch` for supabase / execute_sql / apply_migration → **no matching deferred tools**.
  2. `~/.claude.json` → `mcpServers: []` globally **and** on this project (`disabled: []`,
     `enabled: []`). No `.mcp.json` in the repo, and `git log --all -- .mcp.json` is **empty**, so
     one was never committed.
  3. `~/Library/Application Support/Claude/claude_desktop_config.json` → `mcpServers: []`.
  4. No `psql`, no `pg_dump`, no `supabase` CLI, no `~/.supabase`, no `pg` / `postgres` node module,
     no `SUPABASE_DB_URL` and no `SUPABASE_ACCESS_TOKEN` in the environment. `.env` carries only
     `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `EXCEL_PATH`, `WEIMI_APP_ID`, `WEIMI_SECRET_KEY`.
  5. The Management API path (`api.supabase.com/v1/projects/{ref}/database/query`, which is what the
     MCP server itself wraps) needs a personal access token (`sbp_…`). None exists anywhere on disk.

- **What DOES still work, and was used this leg:** PostgREST with the service key
  (`$SUPABASE_URL/rest/v1/…`). This gives **read access to the `public` schema only** - tables,
  views, and the OpenAPI catalog at `/rest/v1/` (554 paths: 320 RPCs, 233 tables/views), which is
  enough to prove object existence. It does **not** reach `golden`, `cron`, `supabase_migrations` or
  `pg_catalog` (`PGRST106: Only the following schemas are exposed: public, graphql_public`), and it
  cannot execute DDL.
- **Why no parking routes around it:** P1.4 is three new tables (`inventory_events`,
  `shelf_composition`, `inventory_anomalies`), their RPC-only writers, the estimator job, and
  fixtures 19/20/21/22 in the `golden` schema. Every one of those is DDL. Phases 2-5 are strictly
  downstream. This is the goal command's "hard blocker that no parking can route around".
- **Deliberately NOT attempted** (each would be a worse failure than stopping):
  - Writing `supabase/migrations/*.sql` files without applying them. MEMORY's standing rule is
    "migration file presence is NOT proof of apply"; unapplied files beside 29 applied ones is
    exactly the 2.5-round bug that cost real hours, and it breaks the RELAY handoff invariant
    ("nothing half-applied").
  - Minting a service-key `exec_sql` RPC to regain DDL. That is an unreviewed SECURITY DEFINER
    arbitrary-SQL function on a protected production database - a permanent privilege-escalation
    surface created to work around a missing tool. Refused on principle, not deferred.
- **Smallest unblock (CS, ~1 minute):** restore the Supabase MCP server to the session, e.g.
  ```bash
  claude mcp add supabase -s project -- npx -y @supabase/mcp-server-supabase@latest \
    --project-ref=eizcexopcuoycuosittm --access-token=<sbp_…>
  ```
  then relaunch. The next leg re-runs STEP R and continues at P1.4 with **zero** rework - leg 7
  changed no DB state whatsoever.
- **Loop impact:** the loop STOPS here. Doc-only work that was genuinely unblocked was completed
  first (S-03 ADR, S-12 registries - both closed below).

## STUCK updates (2026-07-30, relay leg 7)

### S-03 · ✅ CLOSED - ADR half written, Phase 2's prerequisite cleared

`docs/architecture/ADR-shadow-plan-tables.md` now exists. It carries the Article 14 signoff for
`pod_refill_plan_shadow`: the "view suffices" clause is answered on four grounds (WEIMI stock moves
between run and read; `engine_add_pod` is procedural plpgsql and has no `SELECT` form **at all**; the
Phase-2 gate needs 14 days of history; `pod_refill_plan` is itself a table for the same reason), and
the staleness test - the risk the article actually guards - is answered by write-once-per-`run_id`
rows that no operational consumer reads. Also records why the flag-column alternative
(`pod_refill_plan.is_shadow`) was rejected: it would put non-plan rows inside a protected entity that
dispatch, stitch, preflight, FE and the advisory all read, and violate LAW 12 by construction.
Ends with 4 binding obligations on the leg that creates the table, including a golden assertion that
live `pod_refill_plan` row count is unchanged across any shadow run. **Both halves of S-03 are now
closed** (cheat sheet in leg 2, ADR in leg 7).

### S-12 · ✅ CLOSED - `preflight_refill_plan` registered in both registries

- `RPC_REGISTRY.md` (Read-only helpers): full entry - stitch commit gate, `set_version v2`,
  12 invariants, enforcement via `refill_policy_params.preflight_enforcement` (`'warn'`, do not flip
  without CS burn-in), plus the three landmines a future editor must not "simplify" (INV-06 is
  REMOVE/M2W-only and disjoint from `v_refill_accuracy`; INV-10 is an **absence** detector;
  `pod_refill_plan` holds both REMOVE and M2W parents so action-matched joins false-positive).
  The `anon` EXECUTE grant is recorded and **left untouched** (LAW 10 - it belongs to the existing
  revoke-anon carry-forward).
- `METRICS_REGISTRY.md`: new PRD-110 S-12 section registering INV-06 as the canonical object for
  plan conservation, explicitly disjoint by action from `v_refill_accuracy`, with the reason spelled
  out (Article 16 invites consolidation; consolidating drops one action domain).

### D-04 · sentinels measured, NOT draining yet (leg-5/6 prose was forward-looking)

All 8 Fade Fit sentinel rows still read `warehouse_stock = 999` exactly (7992u total, unchanged since
the P0.4 mint). The decay D-04 warns about is real but has **not started**. The recommendation is
unchanged: do not re-top, retire at P1.3 - which still requires `engine_add_pod_v3` to consume
`product_sourcing` first.

### S-01, S-02, S-04, S-05, S-06, S-07, S-08, S-09, S-10, S-11, S-13, S-14 unchanged

S-08's tripwire could not be run this leg (`golden` schema unreachable) - it was green on all four
fixtures at leg 6 close, and no engine ran this leg, so no new exposure was created.

## DECISIONS-READY updates (2026-07-30, relay leg 7)

### D-01 through D-07 unchanged - no flag flipped, no activation applied, no DB write of any kind

Leg 7 made **zero** database changes (it had no ability to make one). All 23 reachable pointer claims
re-verified as exact matches - see EXECUTION-LOG leg 7 for the full table.

---

## STUCK updates (2026-07-30, relay leg 8)

### S-15 · ✅ CLOSED - the Supabase MCP is back

`execute_sql` / `apply_migration` / `list_migrations` are present in leg 8's session; `golden`, `cron`,
`supabase_migrations` and `pg_catalog` are all reachable. **Zero rework was needed**, exactly as leg 7
predicted, because leg 7 changed no DB state. All 5 claims leg 7 could not reach were probed and
**all 5 confirmed** (29 migrations · `run_all('P0')` 47/0 · `current_phase='P1'` · `engine_add_pod`
still tagged `v19_base_stock` · cron 13 still v1). Leg 7's decision to stop rather than mint an
`exec_sql` RPC or leave unapplied migration files on disk cost one leg and preserved both invariants.

### S-07 · UPDATED - fixture 14's real population is 43 shelves, not 5

S-07 recorded 5 `stock > capacity` shelves on MPMCC-1058. The P1.4 estimator's fleet dry run measured
**43 shelves fleet-wide** reporting a WEIMI count above capacity. Fixture 14 ("sensor lie") needs no
synthetic data whatsoever, and the estimator already clamps to capacity and raises
`count_above_capacity` for every one of them. Still an opportunity, not a blocker.

### S-14 · unchanged, and now also owns the driver-collapse UI

BUILD SPEC P1.4's "Driver collapse UI (Stax): flagged shelves only (top uncertainty x value-at-risk,
max 3/visit), expected list -> confirm / quick-fix; photo path stubbed" is FE work in the FE repo and
joins S-14's existing Stax bundle. **The backend half is complete and proven**:
`driver_confirm_shelf_v3` is the write path, `shelf_composition.confidence` is the ranking signal,
`composition_confidence_prompt_threshold` (0.5) selects which shelves to prompt, and
`composition_max_prompts_per_visit` (3) caps them. Nothing in the DB blocks the FE.

### S-13 · unchanged, but note P1.4 did NOT touch velocity

The estimator reads `v_shelf_state` for counts only. It never reads `velocity_30d`, so S-13's
two-incompatible-units defect is untouched and still belongs to P2.1.

### S-01, S-02, S-04, S-05, S-06, S-08, S-09, S-10, S-11 unchanged

S-08's tripwire (seq 90) ran green on all four fixtures in both `run_all('P0')` executions this leg
(before and after P1.4), so P1.4's three new tables introduced no live-feedback exposure.

## DECISIONS-READY (added 2026-07-30, relay leg 8)

### D-08 · Composition estimator cron activation (P1.4) - BUILT, cron created, INACTIVE

**What:** turn on `estimate_shelf_composition_v3` so `shelf_composition` starts tracking per-SKU
shelf truth from WEIMI deltas. Everything is built, applied and proven; only the cron's `active` flag
is off.

- `cron.job` **44** `prd110_p14_composition_estimator_hourly`, `40 * * * *`,
  `SELECT public.estimate_shelf_composition_v3(NULL, false);` - **`active = false`**.
- Hourly is deliberate even though WEIMI lands every 4 h: idempotency is keyed on
  `source_ref = 'estimator:<snapshot_at>'`, so each snapshot is consumed exactly once and every other
  run is a cheap no-op. It also means a missed WEIMI cycle self-heals on the next hour.

**Evidence:** fleet dry run 544 shelves in **160 ms** (stress-suite S1 allows 10 minutes).
11-assertion writer dry-test and an 11-assertion estimator dry-test, all PASS, all rolled back, 0
residue. Both directions of the EXPIRY IRON RULE proven: a `derived_decrement` on a known-expired
bucket is refused, a `write_off` on the same bucket succeeds. `golden.run_all('P0')` = **47/0** both
before and after the P1.4 migrations.

⚠️ **Why this is CS's call and not the loop's - read before flipping:**

1. **The first run is irreversible.** It cold-start-seeds **543 shelves** (~2500 `correction` events).
   `inventory_events` is append-only and enforced by trigger, so there is no un-seed and no delete.
   Everything after the first run is incremental and cheap; it is specifically the first write that
   cannot be taken back.
2. **Cold-start confidence is 0.30, deliberately.** The seed splits the WEIMI count across the pod's
   SKUs by `split_pct`, which is a prior, not an observation. Anything gating on
   `composition_confidence_min_autoaction` (0.70) will correctly refuse to act on seeded shelves until
   a driver confirms them. That is the intended behaviour, not a bug to "fix" by raising the seed.
3. **It will raise anomalies immediately** - at minimum the 43 `count_above_capacity` shelves (S-07),
   plus `negative_delta_unallocatable` on any pod whose `product_mapping` cannot conserve the count.
   That is the system reporting truth it previously had no place to put.
4. **It is shadow by construction.** No engine, plan, dispatch, FE or advisory reads any of the three
   tables. Nothing operational changes when this is flipped.

**ACTIVATION (one statement):**

```sql
SELECT cron.alter_job(44, active => true);
```

**Recommended first step instead of the fleet:** seed one machine and eyeball it, since single-shelf
and single-machine runs are already supported and reversible only in the sense that they are small:

```sql
-- dry run, whole fleet, writes nothing:
SELECT public.estimate_shelf_composition_v3(NULL, true);
-- one shelf for real:
SELECT public.estimate_shelf_composition_v3('<shelf_id>', false);
```

**Rollback:** `SELECT cron.alter_job(44, active => false);` stops further accrual. It does **not**
remove already-written events (append-only, by design). If the seeded belief is ever judged wrong, the
correct repair is a `driver_confirm_shelf_v3` collapse per shelf, which snaps composition to truth and
resets confidence to 1.0 - i.e. the system already has a first-class recovery path, and it is the same
one it uses in normal operation.

**Blocks:** the PHASE 1 GATE clause "estimator shadow diff report running" cannot be claimed until
this is on. Recorded so the gate is not silently over-claimed.

### D-07 · now also gates the estimator's venue-fill branch

`_estimator_rise_disposition_v3` returns `'venue_fill'` only for a `co_managed` machine on a
venue-sourced product. `operating_model` is NULL on all 102 machines, so it returns `'anomaly'`
**fleet-wide** today and the auto-venue-fill path in BUILD SPEC P1.4 is dormant until D-07 is applied.
The fail-safe direction is correct (flag, never silently invent stock), and fixture 19 asserts both
branches through the helper rather than through live machine state - so D-07 gates the _behaviour_,
not the _proof_.

### D-01 through D-06 unchanged - no flag flipped and no parked activation applied this leg

---

## STUCK updates (2026-07-30, relay leg 9)

### S-14 · unchanged as FE work, but the DB half of the driver-collapse UI is now COMPLETE

Leg 8 recorded that "nothing in the DB blocks the FE". That was true but understated the gap: the
**selection rule** ("which shelves do I prompt, and never more than 3") had no DB object at all, only
two params. The FE would have had to implement it — recreating the very defect P1.2 fixed when it
deleted the FE's independent shelf scorer (G1 "one truth").

Both objects now exist and are proven:

- `v_shelf_audit_prompts` — the canonical prompt selector. Stax reads this and renders it; the FE must
  NOT re-rank or re-cap. Fixture 22 seq 12-15 proves the cap BINDS (14 flagged shelves on one machine
  → exactly 3 rows), that the param decides rather than a literal 3, and that the ordering is by
  uncertainty x value-at-risk descending.
- `v_expiry_action_queue` — the auto-action gate, both branches proven (fixture 20 seq 14/15).

S-14's remaining scope is unchanged and still Stax's: the machine page, the advisory, and now the
driver-collapse screen — all in the FE repo, all behind the still-open Batch-3 FE deploy.

### S-07 · CLOSED as an opportunity - fixture 14 no longer needs it stated as a gap

S-07 existed to record that `stock > capacity` shelves exist in real data (5, then 43) so fixture 14
would not need synthetic data. That remains true and the estimator clamps every one of them. The note
is retained for the leg that writes fixture 14 (Phase 2), but it needs no further analysis: the
population is real, measured, and the clamp is already in the estimator's body.

### S-01, S-02, S-04, S-05, S-06, S-08, S-09, S-10, S-11, S-13 unchanged

S-08's tripwire (seq 90) now rides on **eight** fixtures (3, 5, 10, 105, 19, 20, 21, 22) and was green
on every run this leg. Fixtures 19-22 have no S-08 exposure by construction — they call no engine, and
their writes roll back — but they carry the assertion anyway, as fixture 10 does.

## DECISIONS-READY updates (2026-07-30, relay leg 9)

### D-08 · UNCHANGED but its evidence is now much stronger — and its blocking scope is narrower

The estimator cron (44) is still `active = false` and its activation is still CS's call for exactly the
reason recorded in leg 8: the first run writes ~2500 permanently irreversible rows into an append-only
ledger. Nothing about that changed.

What did change: the estimator's contested behaviours are now pinned by **golden fixtures on live
shelves** rather than by one-off dry-tests that existed only in a log. Specifically proven this leg,
three times consecutively with identical results:

- an expired bucket survives a derived drop **untouched**, and the drop is never even attempted against
  it (fixture 20 seq 1/3);
- a count that falls further than sellable belief can explain raises
  `negative_delta_unallocatable` with the exact residual and **consumes nothing** (seq 6-10);
- the IRON RULE is an asymmetry, not a lock — the human `write_off` on the same bucket still succeeds
  (seq 11-13);
- confidence decay is caused by real multi-candidate allocation, crosses the prompt threshold, and a
  driver collapse restores 1.0 (fixture 22 seq 4-11).

**Both new views return 0 rows today**, which is the correct and expected state: they read
`shelf_composition`, and nothing is seeded until D-08 is flipped. They are inert, not broken.

### D-07 · unchanged, and now proven inert rather than assumed inert

Fixture 19 asserts the D-07-dormant path directly: with `operating_model` NULL fleet-wide,
`_estimator_rise_disposition_v3` returns `anomaly` (seq 4) — flag, never silently invent stock. It then
simulates `co_managed` **inside the rolled-back subtransaction** to prove the `venue_fill` branch works
(seq 5), and seq 98 asserts the classification count is unchanged afterwards, so D-07 stays parked.
The fixture proves the behaviour without applying the decision.

### D-01 through D-06 unchanged - no flag flipped and no parked activation applied this leg

---

## DECISIONS-READY (added 2026-07-30, relay leg 10)

### D-09 · VOX sentinel retirement (P1.3) — capability BUILT, retirement PARKED

**What:** stop propping VOX shelves up with 40 fake `warehouse_stock = 999` rows (39,463 phantom
units) and let sourcing decide availability instead. The replacement contract is live and proven:
`v_shelf_availability_v3` returns `available_units IS NULL` (unconstrained) for every venue- or
partner-supplied shelf, so it gives the same answer whether or not the sentinels exist.

**Evidence (all measured live this leg, none inferred):**

- **Retiring the sentinels blocks nothing.** `would_block_on_retirement` = **0** across all 544
  pod-bound shelves. 61 shelves are sentinel-backed; 53 of those are venue-sourced and therefore
  unconstrained by definition. The remaining 8 are constrained but hold **≥195** real units against
  capacities of 14-25 — margin of roughly an order of magnitude.
- **Fade Fit is no longer the risk.** Every prior leg recorded "retiring the sentinels re-blocks Fade
  Fit fleet-wide" (D-04, S-10). That is now **false**: P1.1's sourcing edges make all Fade Fit shelves
  `venue`, hence unconstrained. Proven by `resolve_shelf_availability_v3` on VOXMCC-1005 A02 —
  `sourcing='venue'`, `wh_units_real=0`, `wh_units_sentinel=3996`, `available_units=NULL`,
  `would_block_on_retirement=false`. The shelf plans with zero real stock **and** zero sentinel
  dependence.
- **Revenue is untouched.** No revenue object reads `warehouse_inventory` at all. Scanned all 320
  functions and 233 views: 67 objects read the table, 23 objects are revenue/settlement-shaped, and
  the intersection is 4 — all of them `consumer_stock` hygiene objects
  (`v_consumer_stock_leaks`, the three `drain_*` functions), none in the SOA path.
  `get_vox_consumer_report` reads `sales_history`, `v_adyen_transactions_attributed`,
  `cash_recovery_log` and `machines` — and nothing else. It reproduces **BNZ/MAFE/2026-06/001** to the
  cent today: `total_sales = 101,181.71` exactly matches the registry row, with refunds 611.00 / 6
  baskets and 13 unsettled txns matching the SOA notes.

⚠️ **SPEC CORRECTION — `DELETE` is not implementable, and this is the important part.**
BUILD SPEC P1.3 says "Delete VOXSOURCE-\* rows" and fixture 24 is written against a deletion. A plain
`DELETE` of the 40 rows **hard-fails**, and if it did run it would destroy history:

| Dependent               | FK action | Rows referencing the 40 sentinels | Consequence                                   |
| ----------------------- | --------- | --------------------------------: | --------------------------------------------- |
| `inventory_audit_log`   | NO ACTION |                           **255** | **the DELETE aborts** — this is the hard stop |
| `wh_expiry_anomaly_log` | CASCADE   |                            **40** | anomaly-log rows silently destroyed           |
| `refill_dispatching`    | SET NULL  |                           **120** | historical dispatch provenance nulled out     |
| `strategic_intents`     | RESTRICT  |                                 0 | would abort if it ever became non-zero        |

**The correct retirement is INACTIVATION, not deletion.** `v_wh_pickable` requires `status='Active'`,
so flipping a sentinel to `Inactive` removes it from availability with **zero** FK damage and **zero**
history loss — and it is reversible, which a DELETE is not. The canonical writer already exists:
`inactivate_warehouse_row(p_wh_inventory_id, p_reason, p_inactivated_by)`.
⚠️ Article 6 — `warehouse_inventory.status` is manager-only. This runs through the canonical writer
with warehouse-manager impersonation, never as a raw UPDATE.

**ACTIVATION (dry-run the impact first; it is a live view, so it is never stale):**

```sql
-- 1. confirm nothing blocks (expect 0 rows)
SELECT machine_name, shelf_code, pod_name, sourcing, wh_units_real, wh_units_sentinel
FROM public.v_shelf_availability_v3 WHERE would_block_on_retirement;

-- 2. retire, one canonical call per sentinel row (impersonate the warehouse manager first)
SELECT set_config('request.jwt.claims',
  '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
SELECT public.inactivate_warehouse_row(wh_inventory_id,
         'PRD-110 P1.3 sentinel retirement: venue sourcing now makes this shelf unconstrained',
         '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid)
FROM public.warehouse_inventory
WHERE public._is_sentinel_wh_row_v3(batch_id, expiration_date);
```

**Rollback:** re-activate the same rows (they still exist — that is the point of not deleting).

⚠️ **HARD PREREQUISITE, unchanged and still binding:** `engine_add_pod_v3` must consume
`product_sourcing` / `v_shelf_availability_v3` **first** (Phase 2, P2.1-P2.6). v19 computes `wh_avail`
inline from `warehouse_inventory` and reads sourcing **nowhere**, so retiring the sentinels while v19
is the live engine re-blocks every one of those 61 shelves regardless of what the new view says.
**Do not run the activation above until Phase 2 has cut over.** The 0-would-block figure is a property
of the v3 contract, not of the engine that is running tonight.

**Recommended:** hold until P2 cutover, then inactivate rather than delete. Do NOT re-top the
sentinels in the meantime (D-04's recommendation stands).

## STUCK updates (2026-07-30, relay leg 10)

### S-16 · fixture 24 cannot be written against a DELETE — needs restating before it is built

- **What:** GOLDEN-FIXTURES #24 reads "With sentinels deleted (P1.3): VOX SOA for a frozen month
  reproduces BNZ/MAFE/2026-06/001 to the cent." The deletion half is not executable (D-09 table above:
  255 `inventory_audit_log` rows abort it).
- **Restated premise for the leg that builds it:** exercise retirement the way retirement will
  actually happen — `inactivate_warehouse_row` on the 40 rows inside the rolled-back subtransaction —
  and assert (a) the SOA reproduces `101,181.71` unchanged, (b) `would_block_on_retirement` stays 0,
  (c) venue shelves keep `available_units IS NULL`, (d) residue 0: all 40 rows `Active` again after
  rollback. The structural proof (no revenue object reads `warehouse_inventory`) should be its own
  assertion — it is stronger than the behavioural one because it holds for every month, not just this
  one.
- **Not a blocker:** the capability D-09 gates is built and proven; only the fixture is outstanding.
  Per the S-04 house pattern, preserve the original spec text in `golden.fixtures.notes` and log the
  measurement that justifies the correction.

### D-04 · SUPERSEDED by D-09 on the substance

D-04 recommended "do nothing now, retire at P1.3", warning that retirement would re-block Fade Fit.
The retirement path now exists and the Fade Fit warning is **measured false** — sourcing edges make
those shelves unconstrained. What survives from D-04 is the narrower and still-correct advice: do not
re-top the sentinels. The 8 Fade Fit rows remain at exactly 999 (no decay since the P0.4 mint), while
the older non-Fade-Fit sentinels **have** decayed (Aquafina 686/889, Skittles 967/995, Galaxy Milk
991/998, Maltesers 994, M&M Large 989/991, Pepsi MM 993) — confirming D-04's "pack debits them like
real stock" thesis on real data.

### S-01, S-02, S-05, S-06, S-08, S-09, S-11, S-13, S-14 unchanged · S-07 stays closed

S-08's tripwire was not exercised this leg (no fixture ran, no engine ran). S-10 is superseded by D-09
for the sentinel half; its engine half remains the P2 item it has been since leg 5.

### D-01, D-02, D-03, D-05, D-06, D-07, D-08 unchanged — no flag flipped, no activation applied

---

## DECISIONS-READY updates (2026-07-30, relay leg 11)

### D-09 · VOX sentinel retirement — ACTIVATION SCRIPT CORRECTED (twice now), evidence now a green fixture

The decision is unchanged: **hold until the Phase-2 engine cutover, then retire.** What changed is
that leg 10's activation script **would have failed on its first row**, and fixture 24 caught it by
calling the writer instead of trusting the parked SQL.

**Why the leg-10 script fails.** `inactivate_warehouse_row` refuses any row with
`warehouse_stock > 0`, and all 40 sentinels hold 686-999 units:

> `inactivate_warehouse_row: refusing to inactivate row with stock > 0 (warehouse_stock=999,
consumer_stock=0). Drain stock via apply_inventory_correction first.`

**And the obvious two-step fix also fails.** After draining to 0, the AFTER-UPDATE trigger
`tg_propose_inactivate_on_zero_stock` writes an auto-confirmed proposal and flips the row to
`Inactive` **itself**, so a follow-up `inactivate_warehouse_row` returns:

> `inactivate_warehouse_row: row already in status Inactive (only Active rows can be inactivated)`

**CORRECTED ACTIVATION — one canonical call per row, nothing else:**

```sql
-- 1. confirm nothing blocks (expect 0 rows; live view, never stale)
SELECT machine_name, shelf_code, pod_name, sourcing, wh_units_real, wh_units_sentinel
FROM public.v_shelf_availability_v3 WHERE would_block_on_retirement;

-- 2. retire. The drain alone removes the row from v_wh_pickable (it requires warehouse_stock > 0);
--    tg_propose_inactivate_on_zero_stock then performs the Active -> Inactive flip and logs a
--    confirmed warehouse_inventory_status_proposal row. Do NOT call inactivate_warehouse_row.
SELECT set_config('request.jwt.claims',
  '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);
SELECT public.apply_inventory_correction(wh_inventory_id, NULL, NULL, NULL, 0,
         'PRD-110 P1.3 sentinel retirement: venue sourcing now makes this shelf unconstrained',
         '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid)
FROM public.warehouse_inventory
WHERE public._is_sentinel_wh_row_v3(batch_id, expiration_date) AND status = 'Active';
```

**Rollback:** `reactivate_warehouse_row(wh_inventory_id, <old_qty>, 'reason', ...)` per row. The rows
still exist — that is the whole point of not deleting. Capture the pre-retirement quantities first;
they are NOT uniformly 999 (the older sentinels have decayed).

**Evidence is now a green fixture, not prose.** `golden.run_fixture(24)` = **34 pass / 0 fail**,
three consecutive identical P1-suite runs. It exercises the corrected path end-to-end on all 40 real
rows inside a rolled-back subtransaction and proves: SOA `BNZ/MAFE/2026-06/001` reproduces at
**101,181.71** with every sentinel retired (delta exactly 0) · the per-shelf `available_units`
fingerprint is **byte-identical** afterwards · `would_block_on_retirement` is 0 **after** the act ·
venue shelves keep `available_units IS NULL` · 40 auto-confirmed proposals provenance the flip.

⚠️ **HARD PREREQUISITE, unchanged and still binding.** `engine_add_pod_v3` must consume
`product_sourcing` / `v_shelf_availability_v3` first (Phase 2). v19 computes `wh_avail` inline and
reads sourcing nowhere, so retiring while v19 is live re-blocks all 61 sentinel-backed shelves
regardless of what the new view says. The 0-would-block figure is a property of the **v3 contract**.

⚠️ **ARTICLE 6 — CS should see this before flipping.** The corrected activation performs its status
change **through a trigger**, not a manager RPC. Article 6 says _"No trigger, function, cron, n8n
sync, or app flow may write it"_, and `tg_propose_inactivate_on_zero_stock` is a trigger that UPDATEs
`warehouse_inventory.status` directly. It is pre-existing (RC-14 Tier 2a) and it does write an
auto-confirmed proposal row, which is the proposal pattern's spirit — but it is not the letter of the
article. See S-17. This does not block the retirement; it is a disclosure.

**Recommended, unchanged:** hold until P2 cutover, then run the corrected script. Do NOT re-top the
sentinels in the meantime (D-04's surviving advice).

## STUCK updates (2026-07-30, relay leg 11)

### S-16 · ✅ CLOSED — fixture 24 built, green, and it restated its own premise twice

Built against the real retirement path, not the spec's `DELETE` and not leg 10's inactivation either.
34 assertions, green on the first run and on three consecutive suite runs. Original spec text
preserved verbatim in `golden.fixtures.notes` per the S-04 house pattern, with both corrections and
the measurement that justifies each. The structural proof S-16 asked for is seq 10-12 and is stronger
than the behavioural one: it holds for every month, not just 2026-06.

### S-17 · ⚠️ NEW · Article 6 has no enforcement and one live trigger writes through it

- **What.** Article 6: _"warehouse_inventory.status is set only by the warehouse manager via the
  canonical RPC. No trigger, function, cron, n8n sync, or app flow may write it."_ Enforcement is
  specified as a trigger raising EXCEPTION when the column changes with
  `app.rpc_name <> 'set_warehouse_status'`. Measured live:
  - **`set_warehouse_status` does not exist.** The live writers are `inactivate_warehouse_row`,
    `reactivate_warehouse_row`, `confirm_warehouse_status_proposal`, `reject_warehouse_status_proposal`.
  - **No enforcement trigger exists.** `trg_detect_silent_warehouse_write` only INSERTs a
    `monitoring_alerts` row, and only for Pattern A (silent `Inactive`/0 → `Active`/N reactivation).
    Every other unauthorised status write is unobserved.
  - **`tg_propose_inactivate_on_zero_stock` writes the column directly** — the only trigger on the
    table that does. It self-documents as auto-confirmed and logs a proposal row.
- **Why it is parked, not fixed.** Pre-existing RC-14 Tier 2a behaviour with live callers; closing it
  means either amending Article 6 to bless the auto-confirm proposal path or rerouting the trigger
  through `confirm_warehouse_status_proposal`. Both are Article 15 amendment territory and neither is
  PRD-110 scope (LAW 10, no scope drift).
- **Smallest unblock.** CS decides one of: (a) amend Article 6 to name the four real writers and
  bless the zero-stock auto-confirm trigger as a fifth, or (b) ticket the trigger rewrite. Until
  then D-09's activation is disclosed as trigger-mediated.
- **Not blocking anything in PRD-110.** No PRD-110 object writes `warehouse_inventory.status`.

### D-04 · surviving advice unchanged, and now enforced by a fixture

"Do not re-top the sentinels" is now a **tripwire**: fixture 24 seq 1 asserts the population is
exactly 40 rows and turns red if anyone mints or re-tops.

### S-01, S-02, S-05, S-06, S-08, S-09, S-10, S-11, S-13, S-14 unchanged · S-07 stays closed

S-08's tripwire was exercised and held (fixture 24 seq 90: open `driver_feedback` unchanged at 8).

### D-01, D-02, D-03, D-05, D-06, D-07, D-08 unchanged — no flag flipped, no activation applied

---

## STUCK (added 2026-07-30, relay leg 13)

### S-18 · ⚠️ NEW · No DDL channel: the Supabase MCP connector was absent for a whole relay leg

- **What.** Relay leg 13 started with no `mcp__claude_ai_Supabase__execute_sql` /
  `apply_migration` tool. Every remaining PRD-110 task is a migration, so the build could not advance
  at all that leg.
- **Why.** The Supabase MCP is an interactively-authenticated claude.ai connector, not a project
  `.mcp.json` server: `~/.claude.json` lists zero MCP servers for this project and there is no
  `.mcp.json` on disk. It is therefore present in some sessions and absent in others, with no signal
  to the loop until STEP R fails.
- **What was tried** (all negative, all measured, none assumed): `ToolSearch` for
  `mcp__claude_ai_Supabase__*` and for any supabase/SQL tool - nothing · `psql` - not installed ·
  `supabase` CLI - not installed · `SUPABASE_ACCESS_TOKEN` / `sbp_*` management token - absent from
  `.env` and shell config · Postgres connection string - none anywhere, and the service key is not a
  DB password · an in-database SQL-executing RPC (`EXECUTE p_sql` style) - none exists in
  `supabase/migrations/`.
- **The read fallback that DOES work, and its exact ceiling.** PostgREST with
  `SUPABASE_SERVICE_KEY` from `.env`:
  `curl "$SUPABASE_URL/rest/v1/<table>?select=*" -H "apikey: $K" -H "Authorization: Bearer $K" -H "Prefer: count=exact" -H "Range: 0-0"`,
  reading the count off the `content-range` response header. `GET /rest/v1/` returns the OpenAPI
  document: 241 exposed tables/views and 329 RPCs enumerated by name, which is how "does object X
  exist" is answered without `pg_catalog`. Reaches: all of `public`, RLS bypassed. Does NOT reach:
  DDL, `pg_catalog` (no function bodies, no `pg_proc`, no `schema_migrations`), `cron.job`, and the
  `golden` schema (`PGRST106`, only `public` and `graphql_public` are exposed). So **no fixture can
  be built, run, or even inspected** through it.
- **Smallest unblock.** CS reconnects the **Supabase** connector for project `eizcexopcuoycuosittm`
  before the next relay leg starts. One action, no code change.
- **Blocking scope: everything.** This is the one STUCK item that is a hard dependency of all
  remaining work, so the loop reports and stops rather than routing around it.

### S-19 · ⚠️ NEW · Leg 12's shadow scaffold is live but unregistered and object-level unverified

- **What.** `pod_refill_plan_shadow` (table, 14 cols, 0 rows) and `v_shadow_vs_live_plan_v3` (view,
  15 cols) exist in production. Leg 12 applied them after writing its STEP R section and then ended
  without logging them or writing a RESUME POINTER. `MIGRATIONS_REGISTRY.md` has **no entry** for the
  migration, and its version/name is unknown without `schema_migrations`.
- **What checks out already** (from the PostgREST OpenAPI shape): the three ADR-mandated shadow
  columns `run_id` / `engine_tag` / `produced_at` are present, and the 11 shared columns are exactly
  `pod_refill_plan`'s engine-output subset with identical types. The 11 unmirrored live columns are
  all lifecycle/approval fields the engine never produces, which matches the ADR's design (the diff
  view reads `live_status` from the live table).
- **What is NOT verified and must be, before `engine_add_pod_v3` writes its first row.**
  `ADR-shadow-plan-tables.md` §7 promises RLS enabled, `anon` REVOKEd, `security_invoker = true` on
  the view, and a single writer. None of that is readable without `pg_catalog`. An ADR promise is a
  design, not evidence (LAW 13).
- **Smallest unblock.** With MCP restored: dump the DDL + view definition + `relrowsecurity` +
  `anon` privileges + the view's `security_invoker` reloption + the `schema_migrations` row, verify
  against ADR §7, register in `MIGRATIONS_REGISTRY.md`, and fix any unmet promise with an additive
  follow-up migration. Recorded as step 1 of the leg-13 RESUME POINTER.
- **Note for Phase 3.** The shadow table carries no `linked_refill_pk` / `linked_swap_id`. If the
  stitch ladder needs a shadow line table (`pod_refills_shadow`, ADR §2), that pair has to be
  designed in, not assumed inherited.

### S-01 through S-17 unchanged · S-07 and S-16 stay closed

Nothing was probed, changed or closed on any of them this leg: no DDL channel existed.

### D-01 through D-09 unchanged - no flag flipped, no activation applied, no evidence added

---

## STUCK updates (2026-07-30, relay leg 15)

### S-18 · ✅ CLOSED - the Supabase MCP is back (second occurrence of this failure)

`execute_sql` / `apply_migration` / `list_migrations` present this session; `golden`, `cron`,
`supabase_migrations`, `pg_catalog` all reachable. **Zero rework**, exactly as at S-15/leg 7, because
leg 13 changed no DB state. All 7 claims leg 13 could not reach were probed and **all 7 confirmed**
(41 `prd110%` migrations = 39 + leg 12's 2 · `run_all('P0')` 47/0 · `run_all('P1')` 101/0 ·
`current_phase='P1'` · cron 44 inactive · cron 13 still v1 · engine still `v19_base_stock`).

⚠️ **This is now a recurring condition, not an incident** (S-15 at leg 7, S-18 at leg 13). The
connector is an interactively-authenticated claude.ai MCP with no per-session guarantee. The standing
mitigation is unchanged and it works: STEP R probes for the tool first, and a leg without it does
doc-only work and stops rather than drafting blind SQL.

### S-19 · ✅ CLOSED - registries written (leg 14) and independently verified (leg 15)

Leg 14 wrote both registry entries and then **died without logging** - the same contract break leg 12
made (RISK 33). Detected by mtime: `MIGRATIONS_REGISTRY.md` 18:19:41 and `METRICS_REGISTRY.md`
18:19:59, both **after** leg 13's 18:14 close, and `find -newermt` proves those two files are leg 14's
**entire** footprint. DB confirms zero database changes.

All 7 ADR §7 promises re-measured from `pg_catalog` this leg rather than trusted (LAW 13) - every one
matches leg 14's claim exactly. Migration identity pinned:
`20260730145843_prd110_p2_0_pod_refill_plan_shadow` + `20260730145907_prd110_p2_0_v_shadow_vs_live_plan_v3`.

**Two obligations survive S-19's closure and belong to Phase 2, not here:** ADR §7 Art 4 (the writer
refuses a `plan_date` with non-pending live rows, LAW 12) is a property of `engine_add_pod_v3`; ADR
§8.3 (`pod_refill_plan` row count unchanged across a shadow run) rides every Phase-2 fixture as the
**seq 91** tripwire, beside S-08's seq 90.

### S-20 · ⚠️ NEW · Fixture 2's premise is not observable in the data as written

- **What.** GOLDEN-FIXTURES #2 reads _"Shelf sells out in 6h daily; calendar velocity low, in-stock
  velocity high. Assert v3 target >= 2x v19 qty."_ `weimi_aisle_snapshots` is a **once-daily**
  sampler (31 snapshots / 30 days, median gap 24.00h). **A 6-hour sell-out is invisible to it.**
- **Compounded by two premise errors already on record.** Leg 13 found the target shelf is a mixed
  `Coca Cola Mix` pod, not a Coke-Zero-only pod, and `shelf_composition` is empty until D-08 is
  flipped, so no SKU-grain assertion has anything to read. Leg 15 adds that OMDBB `A03`/`A04` **swapped
  pods inside the 30-day window**, so the shelf's own recent history is not a clean series either.
- **Restated premise for the leg that builds it** (S-04 house pattern - implement the intent, preserve
  the original text in `golden.fixtures.notes`, log the measurement): assert at **pod grain**, and
  assert the _mechanism_ rather than the 6-hour story - that `stock_hours < elapsed_hours` on a shelf
  with proven zero-stock intervals, that `velocity_instock > velocity_raw` for exactly those shelves,
  that the 48h floor returns NULL instead of a divide-by-tiny rate, and that the A/B/C/D case table is
  exercised on real rows. The "2x v19" clause should be re-derived from measurement once
  `engine_add_pod_v3` exists, not asserted from the spec's guess.
- **Not a blocker.** 7.0% of WEIMI rows in 30d are zero-stock, so the censored population is real and
  large enough to build on; only the fixture's wording needs restating.
- **Third fixture to need this** (24 twice, 6 → `VOXMM-1013`, now 2). Treat a spec fixture premise as a
  hypothesis to verify, never as a fact.

### S-13 · unchanged, and P2.1 is now explicitly where it dies

`engine_add_pod_v3` must read `velocity_instock` (daily by construction) and never re-derive from
`velocity_30d` - no `/30.0`, no `*30.0`. See the leg-15 P2.1 groundwork section in the EXECUTION-LOG.

### S-01, S-02, S-04, S-05, S-06, S-08, S-09, S-10, S-11, S-12, S-14, S-17 unchanged · S-03, S-07, S-15, S-16 stay closed

S-08's tripwire (seq 90) ran green on all 9 fixtures across both suite runs this leg.

## DECISIONS-READY updates (2026-07-30, relay leg 15)

### D-01 through D-09 unchanged - no flag flipped, no parked activation applied, no DB write of any kind

Leg 15 applied **0 migrations** and wrote **0 rows**. The two `golden.run_all` executions are
rolled-back subtransactions by construction. Flags re-confirmed live and unchanged:
`gate0_require_manual_confirm=false` · `preflight_enforcement='warn'` · `swaps_enabled=true` ·
cron 44 `active=false` · cron 13 still pointed at `build_draft_for_confirmed` (v1).

---

## STUCK updates (2026-07-30, relay leg 16)

### S-18 · ⛔ REOPENED · occurrence 3 of the class, and it has a NEW shape

- **What.** Relay leg 16 had no `mcp__claude_ai_Supabase__execute_sql` / `apply_migration` /
  `list_migrations`. Every remaining PRD-110 task is DDL, so the build could not advance.
- **⚠️ The new shape, and why the old probe is now insufficient.** At legs 7 and 13 the connector was
  simply **absent**. At leg 16 it **connected**: the session announced "claude.ai Supabase" as
  connecting, then delivered the server's MCP **instructions block** (guidance about `list_tables`,
  `get_advisors`, `apply_migration`) - and registered **zero tools**. So "the Supabase MCP is present"
  read TRUE while the DDL channel was dead. **The only valid probe is resolving `execute_sql` by
  name.** Recorded as RISK 39.
- **What was tried** (all negative, all measured): `ToolSearch select:` on `execute_sql`,
  `apply_migration`, `list_migrations`, `list_tables` · `ToolSearch "+supabase"` · `ToolSearch` on the
  server's own advertised verbs (`get_advisors`, `get_project_url`, `get_publishable_api_key`) ·
  `ListMcpResourcesTool(server='claude.ai Supabase')` -> no resources · `psql` / `supabase` /
  `vercel` / `gh` / `pg_dump` all absent · no `pg` node module · `.env` holds no DB URL and no
  `sbp_*` token.
- **Refused again, on the same principle as leg 7.** No `exec_sql` RPC was minted (a permanent
  unreviewed SECURITY DEFINER privilege-escalation surface on production, created to route around a
  missing tool), and **no unapplied `supabase/migrations/*.sql` file was written** (breaks the RELAY
  "nothing half-applied" invariant and repeats the round-2.5 bug). All 329 exposed RPCs were scanned
  for an existing arbitrary-SQL escape hatch: **zero matches**, so there was nothing to be tempted by.
- **The read fallback and its exact ceiling** (unchanged from leg 13, re-measured): PostgREST +
  `SUPABASE_SERVICE_KEY`. `GET /rest/v1/` enumerates **241 tables/views + 329 RPCs**. Reaches all of
  `public`, RLS bypassed. Does **not** reach DDL, `pg_catalog`, `cron.job`, `supabase_migrations`, or
  the `golden` schema (`PGRST106`: only `public` + `graphql_public` exposed). **No fixture can be
  built, run, or inspected.**
- **Smallest unblock.** CS reconnects the **Supabase** connector for project `eizcexopcuoycuosittm`
  before the next relay leg starts, and confirms it exposes tools (not merely that it connects).
- **Blocking scope: everything downstream.** But see below - leg 16 did not idle.
- **What leg 16 did instead, and why it was not blind work.** The pointer's NEXT TASK is P2.1. Its
  design existed only as prose. Leg 16 implemented the leg-15 A/B/C/D `stock_hours` rule **in Python
  over live PostgREST data** and measured what it produces: `scripts/prd110_p21_instock_velocity_oracle.py`
  - `docs/prds/PRD-110-P21-ORACLE.json` (669 series). That surfaced **two corrections to leg 15's own
    design** (case A conflates "empty" with "not on the machine", 2,930 cells / 58,532 phantom hours;
    the 48h floor's stated rationale does not reproduce) and **one binding prerequisite** (a hand-rolled
    name resolver diverges from `v_shelf_sales_identity` on 17.1% of keys, including 127 units
    misattributed between `Hunter` and `Hunter Ridge`). None of that required DDL, and all of it would
    otherwise have been discovered _after_ the SQL was written. Full detail: EXECUTION-LOG leg 16 F1-F8.

### S-20 · unchanged in substance, now QUANTIFIED (and the restatement is confirmed)

Leg 15 restated fixture 2's premise because a 6-hour sell-out is invisible to a 24-hour sampler. Leg 16
measured the population that clause would need. `velocity_instock / velocity_raw` over 399 series:
**p50 1.06**, p90 1.39, max 12.17; **>=2x on 27** series. Filtered to >=10 units, the fleet-wide >=2x
population is **exactly 2 shelves** (NISSAN-0804 `Freakin Protein Balls 3P` 2.27x · NOOK-1019
`Plaay Tablet Chocolate 35g` 2.15x), and neither is a sell-out story. Re-derived with the **canonical**
numerator the picture holds (p50 1.05, >=2x on 19/373), so this does not rest on leg 16's resolver.
**Do not assert a fleet-level 2x.** Assert the mechanism, per the S-04 house pattern.

### S-13 · unchanged, and F4/F5 sharpen what P2.1 must not do

`engine_add_pod_v3` must read `velocity_instock` (daily by construction) and never re-derive from
`velocity_30d` - no `/30.0`, no `*30.0`. Leg 16 adds: the oracle's `velocity_instock` is units per
in-stock DAY over a 30-day window, same grain as `velocity_raw`, and the two agree at p50 **1.06** -
so a v3 quantity that moves by more than a few percent fleet-wide is a bug in the wiring, not the
velocity model.

### S-01, S-02, S-04, S-05, S-06, S-08, S-09, S-10, S-11, S-12, S-14, S-17, S-19 unchanged · S-03, S-07, S-15, S-16 stay closed

S-08's tripwire (seq 90) could **not** be exercised this leg - the `golden` schema is unreachable
without MCP. It was green on all 9 fixtures at leg 15 close, and **no engine ran and no fixture ran
this leg**, so no new exposure was created.

## DECISIONS-READY updates (2026-07-30, relay leg 16)

### D-01 through D-09 unchanged - no flag flipped, no parked activation applied, no DB write of any kind

Leg 16 applied **0 migrations**, wrote **0 rows**, ran **0 fixtures** and drafted **0 SQL**. Flags
re-confirmed live through PostgREST and unchanged: `gate0_require_manual_confirm=false` ·
`preflight_enforcement='warn'` · `swaps_enabled=true`. Sentinels still **40 Active** (D-04's
"do not re-top" tripwire holds). cron 44 and cron 13 were **not** reachable this leg and are carried
untested from leg 15.

---

## ⭐ CS DECISIONS — CLOSED 2026-07-30 ~19:15 Dubai (recorded by CS via Cowork session)

Binding on the next legs. Execute each per its condition; none requires a further ask.

### D-01 → APPROVED: FLIP NOW

Flip `gate0_require_manual_confirm=true` and repoint cron 13 to the `_v3` chain in the next
leg that has DDL. CS accepts the discipline: no confirm by night = no draft (no auto-fallback,
wave-1 rule). The 8pm advisory must clearly render the "awaiting your confirmation" state with
the pick list so CS has a nightly prompt. Verify the first live cycle end-to-end (pick →
unconfirmed → CS confirm → draft) and record it as the Phase-0 gate's missing evidence.

### D-07 → APPROVED: APPLY NOW

Apply the operating-model classification to the 37 active machines + arm guard triggers +
`SET NOT NULL` promotion per the parked script. The 286 conflict edges are accepted as label
debt: backfill resolution (boonz_wh) stands; keep `v_product_sourcing_model_conflicts` as the
async review list for CS — do NOT auto-rewrite product_mapping rows.

### D-08 → APPROVED: STAGED ACTIVATION

Activate estimator cron 44 scoped to ONE machine first: **MPMCC-1058-0000-R0** (CS's named
problem machine). After 3 consecutive clean days (no negative compositions, conservation
assertions green, anomalies explainable), expand fleet-wide without a further ask. Record the
single-machine seed event count and the fleet seed count separately in the log.

### D-09 → APPROVED CONDITIONALLY: AUTO-EXECUTE AFTER P2 CUTOVER

Sentinel retirement (all 40 rows, via `apply_inventory_correction` → 0 per leg 11's corrected
script; trigger flips Inactive) executes automatically the moment the FIRST cluster cuts over
to `engine_add_pod_v3` reading sourcing edges. Prerequisite check is mandatory in the same
leg: `would_block_on_retirement = 0` against the LIVE serving engine for affected machines,
then fixture 24 re-run green post-retirement. No further CS ask.

## STUCK updates (2026-07-30, relay leg 17)

### S-18 · NOT reopened this leg

`mcp__claude_ai_Supabase__execute_sql` resolved by name at STEP R and DDL worked. Occurrence count
stays at **3**. Leg 16's "probe by resolving the tool name, never by server presence" is retained as
the standing check - it is cheap and it was correct.

### S-20 · unchanged, but its ROOT DATA SOURCE moved (see S-21)

Everything leg 16 quantified about fixture 2 was measured on `weimi_aisle_snapshots`. That table is
**not** on the engine's read path (S-21). The restatement stands - assert the mechanism at pod grain,
never a fleet-level 2x - but the numbers behind it should be **re-measured on
`v_weimi_shelf_history_v3`** before fixture 2 is built.

### S-21 · ⚠️ NEW · `weimi_aisle_snapshots` and `weimi_device_status` disagree about stock

- **What.** Over the same 30d window both tables hold 22,313 rows and 17,617 (machine, date, product)
  keys, but **294 keys disagree on summed stock at identical slot counts** - Aquafina **148 vs 55**,
  Smart Gourmet Hummus **2 vs 33** - and **355 keys per side differ by trailing whitespace** because
  the aisle table trims `product_name` on ingest while the raw JSONB does not. Their `snapshot_at`
  values for the same run differ by ~8s, so a timestamp join between them returns **0 rows**.
- **Why it matters.** `v_live_shelf_stock` -> `v_shelf_state` -> the engine all read
  `weimi_device_status`. Legs 15 and 16 built the P2.1 design and the entire 669-series oracle on
  `weimi_aisle_snapshots`. P2.1 has been rebuilt on device_status; the oracle has not.
- **Who else reads the suspect table.** `v_current_aisle_inventory`, `v_pod_phantom_stock`,
  `v_product_first_seen`. **`v_pod_phantom_stock` is the alarming one** - a phantom-stock detector
  fed by a source that disagrees with the operative one by up to 93 units on a single key.
- **Why parked, not fixed.** Root cause is in the n8n ingest (two writes, ~8s apart, from what look
  like different API calls), which is Stax territory and squarely outside P2.1 (**LAW 10**).
- **Smallest unblock.** Ask Stax which WEIMI endpoint feeds each table and whether one is stale by
  construction. Until then treat `weimi_device_status` as truth and do not build anything new on
  `weimi_aisle_snapshots`.

### S-22 · ✅ RESOLVED (leg 18) — perf half closed; correctness half REOPENED as S-23

**The "too slow to query" half of S-22 is CLOSED.** Perf fix applied as
`20260730170009_prd110_p21_velocity_v3_perf_single_flatten`: 4 history-view evaluations → 1, by
taking the window bounds from the base table once and building `snaps` from the base table behind
an `EXISTS` equivalence guard. The view is now readable fleet-wide in a single statement
(687 series / 41 machines). Proven behaviour-identical before apply — A1 anchor equality,
A2 snaps `1208 = 1208` with `EXCEPT` 0/0, A3 output `687 = 687` with **zero diffs on every
column** — re-verified after apply against a `_test` shadow, which was then dropped.
**The Dara / materialized-view escalation was NOT needed** and is withdrawn; Article 14 stays
untouched because the object remains a plain view.

**The "unverified" half is NOT closed** and is carried forward as **S-23** below, so that a future
leg cannot read "S-22 resolved" as "the velocity numbers are trusted". They are not.

_(original S-22 text follows, for the record)_

### S-22 (original) · The P2.1 velocity view is applied, unverified, and too slow to query

- **What.** `v_shelf_instock_velocity_v3` exists and is Article-16-compliant, but **no result has ever
  been read from it**. The verification attempt saturated production for >15 minutes.
- **Why.** The view re-flattens the 79k-row JSONB history **four times per evaluation**, and the
  verification statement asked for ~10 independent aggregates over it in ONE query, multiplying that
  by ten. `cell_sales` also nested-loops ~7.5k sales against ~18k cells.
- **What was tried.** (1) A perf rewrite pulling the window bounds and machine snapshot sequence from
  the base table as InitPlan constants so the history view flattens once - **drafted, never applied**,
  the apply call itself hit the saturated DB. (2) Nothing else; further load would have deepened the
  incident.
- **Smallest unblock.** Apply the perf rewrite, then probe **one cheap aggregate at a time, scoped to
  a single machine, with `SET statement_timeout='60000'`** so the server enforces the limit. A client
  timeout does **not** cancel a running query.
- **Likely real answer -> Dara.** A per-query 79k-row JSONB flatten must never sit under
  `engine_add_pod_v3`. Article 14 explicitly permits "materialized views with explicit refresh
  semantics", so a nightly-refreshed materialized view is constitutional **with an ADR**. Decide this
  before wiring `velocity_instock` into `v_shelf_state`.
  _(Superseded by the resolution above: the plain view is fast enough; no ADR needed.)_

### S-23 · ⚠️ NEW (leg 18) · P2.1 velocity is FAST and MEANING-STABLE, but never checked for CORRECTNESS

- **What.** `v_shelf_instock_velocity_v3` has now been read, fleet-wide, and its perf fix is proven
  behaviour-preserving. **It has still never been compared to `docs/prds/PRD-110-P21-ORACLE.json`.**
  Nothing downstream may consume it until that happens; it is registered 🔴 not-yet-canonical in
  `METRICS_REGISTRY.md` precisely to prevent an accidental consumer.
- **Why it is not just paperwork.** Leg 18's first fleet-wide read produced numbers that differ from
  the oracle: series **687 vs 669** · A **331 vs 297** · B **16,147 vs 15,043** · C **165 vs 181** ·
  D **142 vs 212** · X **2,594 vs 2,930** · below_floor **8 vs 35**. Divergence is **expected and
  explained** (the oracle was computed on `weimi_aisle_snapshots` with a 3-rung resolver; the view
  uses `weimi_device_status` with 4 tiers and canonical units — S-21), but "expected" is not
  "verified". Someone must attribute the gap rather than assume it.
- **Smallest unblock.** Compare **`stock_hours` first** — it is the numerator-independent heart of
  the A/B/C/D mechanism. Then attribute residuals to S-21's 294 divergent stock keys and the tier-4
  alias pods. The view is now cheap enough that this is a normal query, not an incident risk.
- ⚠️ **Separate finding worth its own look: 162 of 687 series (23.6%) are
  `out_of_canonical_scope`** — i.e. `v_shelf_sales_identity` has no row for them, so they get a
  **NULL** velocity (correct per LAW 5, never a silent 0). That is nearly a quarter of the fleet's
  series with no velocity signal at all. `engine_add_pod_v3` must have a defined behaviour for them
  **before** it ships, or it will silently under-serve them.
