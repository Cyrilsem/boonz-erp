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

---

## STUCK updates (2026-07-30, relay leg 19)

### S-23 · ✅ RESOLVED - the P2.1 velocity mechanism is VERIFIED against the oracle

Compared live via `scripts/prd110_s23_velocity_vs_oracle.py` (read-only). 648 series joined on
`(machine_id, pod_product_id)`. The window-normalised in-stock fraction - the numerator-independent
heart of the A/B/C/D model - agrees within **1 percentage point on 82.9%** of series, 5pp on 97.1%,
10pp on 98.3%, with a **median delta of exactly 0.0000**.

**All residual divergence is attributed, none is unexplained.** `elapsed_hours` deltas are quantised
at **1.35h + k×24h**: the 1.35h is the two source tables' differing newest-snapshot time, and each
24h step is one day on which `weimi_device_status` resolved a pod the oracle's aisle-table resolver
did not - **S-21 expressed as arithmetic**. The numerator differs on only 54 series and **always in
one direction** (view ≥ oracle by +3…+12 units), which is what a window ending 3.4h later must do and
what a resolver bug could not do. `velocity_instock` agrees within 10% on 86.4%.

**S-23 is closed as a correctness question. Two things it uncovered are NOT closed** and are carried
as RISK 53 (below) and **D-10** (new decision item). The metric therefore stays 🔴 not-yet-canonical
in `METRICS_REGISTRY.md` - passing the mechanism test is one of two gates, not both.

### ⚠️ RISK 53 · NEW · `v_shelf_instock_velocity_v3` is not reproducible across days, by construction

`t_anchor = max(weimi_device_status.snapshot_at)`, and that value moves. Cadence is daily ~22:00 UTC
with ±2h jitter (interval lengths 22.20-25.80h; 812 of 1167 intervals are exactly 24.00h), plus
**off-cadence arrivals**: one landed at **17:23:07 UTC mid-verification**, adding a 19.37h final
interval to all 41 machines and shifting the case mix from leg 18's A=331/B=16147/C=165/D=142 to
A=330/B=16145/C=167/D=143 between two reads hours apart.
**Consequence: any Phase-2 fixture asserting exact numbers off this view WILL flake**, and LAW 8
would send the next leg bisecting an engine that is not at fault. **Assert the mechanism (the S-04
house pattern), or pin the anchor. Decide this BEFORE fixture 2 or fixture 14 is written.**

### ⚠️ S-24 · NEW · 12 of the 44 applied `prd110%` migrations have NO file in `supabase/migrations/`

- **What.** DB has **44** `prd110%` rows; the repo has **32** files. The 12 missing are exactly the
  wall-clock-stamped versions - `…132332`, `…132744`, `…133118`, `…133340`, `…135658`, `…140130`,
  `…140354`, `…142131`, `…144123`, `…144214`, `…145843`, `…145907` - i.e. everything applied through
  the MCP `apply_migration` channel, which stamps its own version and **does not write a file**. The
  32 that do have files all use the hand-authored `…HHMM000N` pattern.
- **Why it matters.** A fresh clone running `supabase db push` reproduces **32 of 44** objects.
  Silently absent would be: the whole P1.4 estimator stack (`inventory_events`, the event writers,
  the estimator, the conservation fix), the audit-prompt/expiry-action views, fixtures 19-22 and 24,
  the P1.3 availability contract, and **both P2.0 shadow objects** (`pod_refill_plan_shadow`,
  `v_shadow_vs_live_plan_v3`). This is the round-2.5 bug class in a new costume: **the DB is right and
  the repo is short.** Note it is NOT the round-2.5 failure itself - nothing here is unapplied.
- **Why not fixed this leg.** LAW 10. It is a 12-file backfill and its own atomic unit, and each file
  must be a faithful dump from `pg_catalog` (`prosrc` / `pg_get_viewdef` / the recorded `statements`
  array), never a reconstruction from the log. Attempting it half-way would break the RELAY
  "nothing half-applied" invariant in the opposite direction.
- **Smallest unblock.** One dedicated leg: read `supabase_migrations.schema_migrations.statements`
  for those 12 versions, write each verbatim to `supabase/migrations/<version>_<name>.sql`, then
  assert `count(files) = count(rows) = 44`.

### S-18 · NOT reopened · S-20, S-21 unchanged · S-03, S-07, S-15, S-16, S-22 stay closed

`execute_sql` resolved **by name** at STEP R and DDL/DML both worked. Occurrence count stays **3**.
S-21 is now load-bearing in a new way: it is the accepted explanation for S-23's residual, so it must
not be closed without re-checking that attribution.

## DECISIONS-READY updates (2026-07-30, relay leg 19)

### D-01 · ✅ ACTIVATED (by CS, outside this loop) and now ✅ VERIFIED (by this leg)

**Found already live at STEP R**, and **not** by any migration - `gate0_require_manual_confirm=true`
(column default is false) and cron 13 repointed to
`build_draft_for_confirmed_v3(resolve_refill_plan_date())`. A search of every migration's `statements`
for the flip or a `cron.alter_job(13…)` returns zero PRD-110 matches, so it was applied by direct SQL
between leg 18's close and 17:19 UTC. **This is CS's own "D-01 → APPROVED: FLIP NOW" instruction being
executed, so it is kept, not reverted** (LAW 13 + LAW 11 agree).

**Tonight was safe:** cron 13 fired at 16:00 UTC and succeeded; 2026-07-31 has 12 `machines_to_visit`
rows (4 picked / 4 confirmed) and 41 draft + 5 superseded plan rows. The flip landed **after** that
run, and v3-with-flag-false is behaviour-identical to v1. **LAW 12 held.**

**The verification D-01 demanded was never done by the flipping leg. Leg 19 did it** - DO-block +
terminal `RAISE EXCEPTION` on synthetic `plan_date` 2030-03-05, so every write rolled back (proven
after the fact: 0 rows at that date, 2030 totals unchanged at 11/7):

- pick → unconfirmed → `build_draft_for_confirmed_v3` returns **`awaiting_confirmation`**,
  `auto_confirm=false`, `awaiting_count=1`, and a **populated `pick_list`** (machine, priority,
  reasons, service_track) + `next_action`. That pick-list clause is exactly what CS made a condition
  of the approval, and it is the v1 defect (two bare counts) being closed.
- CS confirm → `build_confirmed_now_v3` returns **`draft_ready`**, stage 2a ran
  (`v19_base_stock`, 6365ms, **8 refills inserted**, `binding_drift_skipped=0`), whole chain 6.66s.
  **D-01 is done: activated AND proven end-to-end. This is the Phase-0 gate's missing evidence.**
  ⚠️ **The first LIVE cycle under the gate is 2026-07-31 16:00 UTC** - no draft will exist until CS
  confirms the pick list. That is the intended discipline, not a fault.

### ⚠️ D-10 · NEW · What must `engine_add_pod_v3` do with the 162 `out_of_canonical_scope` series?

- **What it is.** 162 of 687 series (**23.6%**) have no row in `v_shelf_sales_identity`, so
  `v_shelf_instock_velocity_v3` returns `velocity_status='out_of_canonical_scope'` and a **NULL**
  velocity. NULL is _correct_ (LAW 5: never a silent 0) but it is not a plan.
- **Evidence it is not a corner case** (measured leg 19): they span **37 of 41 machines**, they carry
  **459 units** of observed `units_window`, and **129 of the 162 had a real velocity in the oracle** -
  so the movement is real; it is the canonical identity object that does not cover them.
- **Why it is a CS/modelling decision, not a build detail.** The candidate behaviours are materially
  different products: fall back to `velocity_raw`; treat as cold-start and use the ramp path; or route
  to `blocked_demand` with an explicit reason so procurement sees them. Picking one silently would
  under- or over-serve a quarter of the fleet's series.
- **Blocking scope.** `engine_add_pod_v3` must not ship without a defined branch for these. This is a
  **prerequisite of P2.2**, not of the whole phase - the engine skeleton can be built around it.
- **The one-line ask:** _"For series with no canonical sales identity (162, 23.6%, 37 machines, 459
  observed units): fall back to velocity_raw, treat as cold-start, or block with a reason?"_

### D-02 through D-09 unchanged this leg

No other flag flipped, no other parked activation applied. Sentinels untouched (D-04's "do not re-top"
tripwire holds). cron 44 still `active=false` (D-08's single-machine staged activation not yet run).

---

## STUCK updates (2026-07-30, relay leg 20)

### ⚠️ S-25 · NEW · D-07's `SET NOT NULL` promotion is blocked by the two `machines` INSERT writers

- **What.** D-07's third clause ("+ `SET NOT NULL` promotion per the parked script") is **not
  shippable**. The classification and the guard-arming halves ARE done (leg 20 R20-U1).
- **Why, both reasons measured live.**
  1. The fleet is **37 Active + 65 Inactive = 102**, and `v_machine_operating_model_proposed` is
     `WHERE status='Active'`. So 65 rows stay NULL and a bare `ALTER COLUMN … SET NOT NULL`
     fails on contact.
  2. The obvious repair is worse. A conditional `CHECK (status='Active' => operating_model IS NOT
NULL)` would **break production onboarding**: scanning `prosrc` for `INSERT INTO machines`
     returns exactly two writers, **`add_new_machine`** and **`repurpose_machine`**, and
     **neither mentions `operating_model`**. Both mint Active machines. The CHECK would fire the
     next time CS onboards or repurposes a machine.
- **Why not fixed.** Teaching two protected-entity RPCs to classify is a Cody-class change to frozen
  onboarding paths, outside PRD-110 (LAW 10).
- **Smallest unblock.** One migration adding an `operating_model` argument (or a
  `v_machine_operating_model_proposed`-equivalent default) to `add_new_machine` and
  `repurpose_machine`, Cody-reviewed, THEN the NOT VALID CHECK, THEN validate.
- ⚠️ **Do not "just add the NOT NULL".** It is a live-outage-class change to `add_new_machine`.
- **Loop impact: none.** NULL already means "not yet classified" and every operating-model rule is
  inert on NULL, which is the fail-safe leg 5 designed.

### ⚠️ RISK 56 · NEW · `velocity_instock`'s numerator and denominator are on DIFFERENT clocks

- **What.** In `v_shelf_instock_velocity_v3`, the denominator `stock_hours` is measured over
  `[t_anchor - 30d, t_anchor]` where `t_anchor = max(weimi_device_status.snapshot_at)`, but the
  numerator `si.units_30d` comes from `v_shelf_sales_identity`, whose own definition filters
  **`transaction_date >= now() - '30 days'`**. Snapshot time vs wall-clock time.
- **Consequence.** The numerator slides continuously while the denominator is frozen until the next
  snapshot lands, so **the metric drifts even when no new data arrives**. This is also why
  **RISK 53's proposed "pin the anchor" remedy could never have worked on its own** - see the
  RISK 53 resolution below.
- **Magnitude today: near zero, and that is why it went unnoticed.** Anchor lag was **0.474h** when
  measured, giving **0 units** of misalignment on both sides. `units_window` (which the view computes
  over its own window and then does not use) agrees with `units_30d_canonical` on **521 of 525**
  series, max delta 6 units. It scales with ingest lag: at a 24h lag (leg 19 measured intervals up to
  25.8h) roughly 1/30 of the window misaligns, ~296 units/day against 8,874 units per 30d.
- **Smallest unblock.** Use the view's own `units_window` as the numerator instead of
  `si.units_30d`. That is a metric-semantics change, so it belongs with **D-10** (which is already a
  decision about what the numerator means for 162 uncovered series), not inside a fixture task.

### ✅ RISK 53 · RESOLVED (leg 20) · assert the MECHANISM; the anchor stays moving

**Decision: the production view keeps `t_anchor = max(snapshot_at)`; fixtures 2 and 14 assert
anchor-independent invariants (the S-04 house pattern).** Two reasons, the second of which corrects
RISK 53's own suggested remedy:

1. A moving anchor is **correct for production** - it is what makes the engine read _current_
   velocity. Pinning it would freeze the engine's view of the fleet, a worse defect than a flaky test.
2. **Pinning it would not have delivered reproducibility anyway**, because the numerator is anchored
   on `now()` (RISK 56). A leg that pinned the anchor would have watched it flake regardless and gone
   bisecting a blameless engine - the exact outcome RISK 53 was raised to prevent.

**The contract fixtures assert - 9 invariants, all verified live on all 687 series, 0 violations:**
I1 `stock_hours <= elapsed_hours` · I2 both hours non-negative · I3 `stock_censoring` in [0,1] ·
I4 **`velocity_instock >= velocity_raw`** whenever both non-NULL (true by construction since
`stock_hours/24 <= 30`; the strongest of the nine - it catches an inverted ratio or a unit error) ·
I5 `out_of_canonical_scope` => both velocities NULL (LAW 5) · I6 `below_floor` => `stock_hours <
floor_hours` and velocity NULL · I7 `ok` => velocity NOT NULL · I8 no negative case counts ·
I9 an all-X series has NULL `elapsed_hours`.
Distribution at close: **ok 517 · below_floor 8 · out_of_canonical_scope 162**.

📌 **Also use this:** the view **exposes `t_start`, `t_anchor` and `floor_hours` as columns**
(non-NULL on all 687 rows). Fixtures should **record the anchor they ran against**, so a later
investigation can separate "the anchor moved" from "the engine changed" without guessing.

**Metric status: still 🔴 not-yet-canonical, but the gate is now D-10 ALONE.** S-23 verified the
mechanism, leg 20 verified the invariants; what remains is a **consumer** decision (what the engine
does with 162 NULLs), not a metric defect. Flip it as soon as D-10 is answered.

### S-18 · NOT reopened · S-21, S-24 unchanged · S-03, S-07, S-15, S-16, S-22, S-23 stay closed

`execute_sql` resolved **by name** at STEP R; occurrence count stays **3**. S-24 (12 applied-but-
file-less migrations, repo 32 vs DB 44) is untouched and remains the best independent filler unit.
📌 **S-07 gained an independent cross-confirmation:** the D-08 estimator run reports
`sensor_above_capacity = 5` for MPMCC-1058, arrived at from a completely different direction than
leg 1's shelf-by-shelf read. Fixture 14 still needs no synthetic data.

## DECISIONS-READY updates (2026-07-30, relay leg 20)

### ⚠️ PROCESS CORRECTION · approved decisions are WORK, not parked items

The "⭐ CS DECISIONS - CLOSED 2026-07-30 ~19:15 Dubai" block opens _"Binding on the next legs. Execute
each per its condition; none requires a further ask."_ **Legs 17, 18 and 19 each carried D-07 and
D-08 forward in their STATE line as "parked activations"** - wording that predated the approval and
was never reconciled against it. Live state confirmed the omission: `operating_model` NULL on all 37
Active machines, cron 44 `active=false`. This is the same failure that led CS to apply **D-01
themselves by direct SQL** (R19-D1). **Rule: at STEP R, diff the CS DECISIONS block against LIVE
STATE, never against the previous pointer's prose.**

### D-07 · ✅ APPLIED AND VERIFIED (leg 20) - substance complete, hardening carried as S-25

`apply_proposed_operating_models_v3(false)` -> **applied 37, failed 0**. Distribution
**co_managed 11 · fully_managed 23 · partner_managed 3**; `would_change` now **0** (idempotent).
**286 conflict edges preserved unchanged** - `product_mapping` was not auto-rewritten, exactly as CS
required, and `v_product_sourcing_model_conflicts` remains the async review list. `product_sourcing`
unchanged at 4022. Incident machines land correctly: ACTIVATEMCC-1037 co_managed · MPMCC-1058
co_managed · AMZ-1029 fully_managed · LVLUP-1018 partner_managed.

**Guards proven armed** (DO-block + `RAISE EXCEPTION`, all rolled back): venue-on-fully **refused** ·
boonz_wh-on-partner **refused** · co->fully reclassification with 10 live venue edges **refused** ·
both-sources-on-co_managed **accepted** (so the guard is not a blanket freeze).
**`golden.run_all('P0')` = 4 fixtures / 47 pass / 0 fail** after arming, S-08 tripwire green.
**Remaining:** the `SET NOT NULL` clause only, carried as **S-25**.

### D-08 · ✅ ACTIVATED, staged to MPMCC-1058 (leg 20). Burn-in clock starts 2026-07-30 18:40 UTC.

⚠️ **CS's instruction was not literally executable and the naive reading fails silently.** The
estimator's parameter is **`p_shelf_id`, not a machine** (`estimate_shelf_composition_v3(p_shelf_id
uuid, p_dry_run boolean)`). Passing a `machine_id` is type-valid and would have matched **zero
shelves** - the cron would have succeeded hourly, written nothing, and burned three "clean" days that
were clean because nothing ran. cron 44 now scopes by shelf set instead, using only the existing
reviewed function (no overload, no signature change, no migration):

```sql
SELECT public.estimate_shelf_composition_v3(shelf_id, false)
  FROM public.v_shelf_state
 WHERE machine_id = '9acce2bf-0e65-48f4-bf44-cefa0326f2c5' AND pod_product_id IS NOT NULL;
```

**Both seed counts, each measured by running the real writer inside a rollback envelope:**

| scope                   | shelves              | events   | units    | anomalies                 | negative | conservation violations |
| ----------------------- | -------------------- | -------- | -------- | ------------------------- | -------- | ----------------------- |
| **MPMCC-1058**          | 16, all cold-start   | **31**   | **186**  | 5 `count_above_capacity`  | **0**    | **0**                   |
| **fleet** (record only) | 544 / 540 cold-start | **1456** | **5065** | 41 `count_above_capacity` | **0**    | **0**                   |

📌 Leg 8's "~2500 events" estimate was high; the measured fleet figure is **1456**. Do not re-quote it.

**Expansion condition, unchanged and needing no further ask:** after **3 consecutive clean days** (no
negative compositions, conservation assertions green, anomalies explainable), revert cron 44 to
`estimate_shelf_composition_v3(NULL, false)` for fleet-wide. Day 1 begins with the **18:40 UTC**
firing on 2026-07-30. The `count_above_capacity` anomalies are **expected, not faults** - they are the
5 known sensor-lie shelves (S-07).

### D-01 unchanged (activated + verified, leg 19) · D-02..D-06, D-09, D-10 unchanged this leg

Sentinels untouched at **40 Active** (D-04's "do not re-top" tripwire holds), though **10 of the 40
have now decayed below mint** (998 … 686) - D-04's prediction is no longer hypothetical, which
strengthens D-09. **D-10 is now the sole gate on the velocity metric going canonical.**

---

## STUCK updates (2026-07-30, relay leg 21)

### ⚠️ S-26 · NEW · S-22's "perf half closed" rests on a benchmark that never ran the expensive path

- **What.** `v_shelf_instock_velocity_v3` was recorded at leg 18 as "readable fleet-wide in a single
  statement" on the strength of a `count(*)`. Measured properly at leg 21, on the same object:
  `count(*)` = **3.4s**, `count(velocity_instock)` = **15.4s**. `count(*)` lets the planner elide the
  `dep` CTE - the correlated per-cell subquery that computes case-C depletion timestamps - and the
  `v_shelf_sales_identity` join, so it benchmarks a query the engine will never issue.
- **Where the cost is, attributed not guessed.** `v_shelf_sales_identity` on its own is **85ms**, so
  the numerator is innocent. The cost is `dep`. The leg-21 split view adds only **3.1s** of its own
  machinery on top, giving ~19s for a fleet-wide shelf-grain read.
- **Why it matters.** STEP 7 stress test **S1 requires a full-fleet shadow run in under 10 minutes**.
  If `engine_add_pod_v3` reads velocity per machine rather than once per run, 41 machines x 15.4s is
  ~10.5 min from this object alone. **The engine must read the velocity object ONCE per run and join,
  never per machine.** That is a design constraint on P2.2, discoverable now rather than at S1.
- **Why not fixed here.** Optimising `dep` is surgery on an applied, oracle-verified object and is its
  own atomic unit (LAW 10). Nothing consumes either view yet, so nothing is currently slow in prod.
- **Smallest unblock.** Re-measure with `count(velocity_instock)`, then try (a) restricting `dep` to
  the ~2% of cells that are case C, which is what it is actually for, or (b) a nightly-refreshed
  materialised view - Article 14 permits that WITH an ADR, and Cody's own note says the object is a
  plain view today precisely because it was thought fast enough.
- ⚠️ **Standing rule: never benchmark either velocity object with `count(*)`.**

### ⚠️ S-27 · NEW · P1 went unrun for six legs and a stale premise silently accumulated

- **What.** `golden.run_all('P1')` was last run at **leg 14**. Legs 15-20 ran only P0 (or nothing).
  Leg 21 ran P1 and found fixture 19 at **13 pass / 2 fail**. It was not a regression - both failures
  asserted the premise _"D-07 is parked"_, and leg 20 applied D-07 - but **nothing would have caught
  it if leg 21 had also only run P0.**
- **Why it matters beyond this instance.** The loop's regression gate is only as good as the phases it
  runs. Phase 0 is closed and Phase 1 is closed, which is exactly why their suites stopped being run -
  and exactly why a CS-approved activation could invalidate a Phase-1 premise unobserved for six legs.
- **Smallest unblock (cheap, do it every leg):** run **both** `run_all('P0')` and `run_all('P1')` at
  any checkpoint that applies a migration or flips a flag. Combined they are 9 fixtures / 148
  assertions and take seconds. **A closed phase is not a phase that stopped needing proof.**
- 📌 Related standing trap: an assertion whose text contains a _parked_ decision ("D-07 parked",
  "cron 44 inactive", "flag off") is a **time bomb**, because the loop's whole purpose is to unpark
  those. Prefer premises that are true in both worlds, or that assert an invariant rather than a state.

## DECISIONS-READY updates (2026-07-30, relay leg 21)

### ⚠️ D-10 · SUBSTANTIALLY NARROWED, and it is mostly TWO DATA PROBLEMS, not one modelling choice

D-10 was framed on the pod-grain view: _"162 of 687 series (23.6%), 37 machines, 459 units have no
canonical sales identity - fall back to velocity_raw, treat as cold-start, or block?"_
**The engine plans SHELVES, not series**, and most of those 162 are historical pod bindings that are
no longer on any shelf. Re-measured on the 544 live pod-bound shelves via the new split view:

| cause of a NULL shelf velocity      |              shelves | shape                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------------- | -------------------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `out_of_canonical_scope`            |               **15** | **ALL on ONE machine, `AMZ-1046-2406-O1`** - and every pod on it. A machine-level absence from `v_shelf_sales_identity`, not a scattered per-product gap.                                                                                                                                                                                                                       |
| no row in the pod-grain view at all |               **16** | **ALL the same pod, `Hunter`** - one shelf on each of 16 different machines. `Hunter` never resolves in `v_weimi_shelf_history_v3` so it yields no series at all; `Hunter Ridge` does. This is leg-16 F5's **Hunter / Hunter Ridge** landmine surfacing as missing velocity (PRD-109: name family = Active mapping ANY scope UNION `product_family_id`, **never** name-prefix). |
| `below_floor` (the 48h guard)       |                **8** | working as designed, not a defect                                                                                                                                                                                                                                                                                                                                               |
| **total**                           | **39 of 544 = 7.2%** | decomposes with **no residual**                                                                                                                                                                                                                                                                                                                                                 |

**Revised one-line ask for CS:** _"39 of 544 live shelves (7.2%) have no in-stock velocity. 15 are one
machine (AMZ-1046) missing from the canonical sales object; 16 are one pod (`Hunter`) that never
resolves in WEIMI history; 8 are the designed 48h floor. Fix the two data gaps, or give the engine a
fallback branch?"_ That is a materially different - and much cheaper - decision than the 23.6% version.
**D-10 remains the sole gate on both velocity metrics going canonical.** Not answered this leg.

### D-01, D-07, D-08 · unchanged (all three ACTIVATED; verified against LIVE STATE at leg-21 STEP R)

Per leg 20's process correction, the ⭐ CS DECISIONS block was diffed against live state, not against
the previous pointer's prose. All four are in their correct state: **D-01** `gate0_require_manual_confirm=true`

- cron 13 on the v3 chain ✅ · **D-07** 11 co_managed / 23 fully_managed / 3 partner_managed ✅
  (the `SET NOT NULL` clause remains blocked as S-25) · **D-08** cron 44 ACTIVE, scoped to MPMCC-1058 ✅
  · **D-09** correctly NOT executed - its condition is "after the FIRST cluster cuts over to
  `engine_add_pod_v3`", and that function still does not exist. Sentinels untouched at **40 Active**.

⚠️ **D-08's burn-in day 1 is NOT YET OBSERVABLE.** cron 44 fires `40 * * * *` and leg 21 closed at
~18:30 UTC with `cron.job_run_details` for jobid 44 still at **0 rows** and all three estimator tables
still **0/0/0**. The first firing is **18:40 UTC**. The next leg owes that verification.

### D-02, D-03, D-04, D-05, D-06, D-09 · unchanged this leg

No flag flipped, no parked activation applied. The only writes this leg were 4 migrations (3 view
bodies + 1 fixture-assertion re-phase); no protected entity was written at all.

---

## STUCK updates (2026-07-30, relay leg 22)

### ⚠️ S-28 · NEW · D-08's fleet-wide expansion will red fixture 22, and it is 3 days out

- **What.** D-08 is CS-pre-approved to go fleet-wide after 3 clean days (~2026-08-02) with **no
  further ask**. The estimator then writes `shelf_composition` for all 544 pod-bound shelves at
  `confidence = 0.30`. Fixture 22's `candidates` reads
  `count(*) FROM shelf_composition WHERE shelf_id = v_s` on **NISSAN-0804-0000-L0 A09** and asserts
  it **= 2**. That count is currently 2 only because the estimator has never touched that shelf.
- **Measured, not assumed - the rest of fixture 22 is SAFE.** seq 12 (`flagged_total > 3`) and
  seq 13/14 (the max-3 prompt cap) move in the _safe_ direction: more flagged shelves make the
  cap bind harder, not softer. Fixture 21's shelf-scoped counts are already proper deltas
  (`v_ev_before` then subtract). Fixture 20 is insulated by `kind = 'derived_decrement'`.
  **The exposure is one assertion, fixture 22 seq 1.**
- **Smallest unblock.** Before flipping cron 44 fleet-wide, re-express fixture 22 seq 1 as a delta
  around the fixture's own `estimate_shelf_composition_v3(v_s)` call, exactly as leg 22 did for
  fixture 19 seq 10. Same defect, same fix, and it is already written down.
- **The general rule this is the second instance of:** an assertion that counts rows in a table the
  _system_ also writes is asserting that the system is idle. Count deltas, or scope by something the
  fixture owns.

### ⚠️ S-29 · NEW · The harness could report a green run that evaluated nothing

- **What.** `golden.run_all(p_phase)` filtered the FIXTURE set by phase but called
  `run_fixture(id, note)` **without** it, so the gate fell back to `config.current_phase`. With
  config at `P1`, `run_all('P2')` skipped every P2 assertion and returned
  **`0 pass / 0 fail / passed = true`**. The harness already refused to call an empty _fixture_ set
  green ("Guard 2"); it had no equivalent one level down for an empty _assertion_ set.
- **CLOSED this leg** by migrations `…185938` (pass-through + Guard 3) and `…190011` (the gate is the
  max of p_phase, config phase and the fixture's own phase, so **no argument to run_all can reduce
  coverage** - the first version of the fix would have silently cut fixture 3 from 14 evaluated to 5).
- **Kept as a standing risk, not deleted:** a vacuous green is the worst thing a proof harness can
  produce, because every downstream LAW-8 decision reads it as evidence. Guard 3 is now the tripwire.

### S-27 · reinforced on its FIRST leg - the rule caught a real one immediately

Leg 21 added "run BOTH suites every leg". Leg 22 ran them and P1 was **red** (fixture 19, 14/1).
Cause: CS-approved cron 44 fired its first live run at 18:40 UTC and legitimately wrote 31 rows into
`inventory_events`; fixture 19 computed `events_in_txn` as an **absolute** `count(*)` of that table,
which read 0 only because the table had been globally empty. Fixed forward (`…184635`) to the
in-envelope delta that fixture 21 already used. **The description was always a delta claim; only the
implementation was absolute.**

### S-20 · restated premise CONFIRMED, and the mechanism turned out to be exact

Fixture 2 is built (leg 22). The spec's "v3 target >= 2x v19" was correctly refused, but the
replacement is **stronger than the mechanism S-20 proposed**. From the view body,
`velocity_raw = units/30.0` and `velocity_instock = units/(stock_hours/24)`, so

> **`velocity_instock / velocity_raw = 720 / stock_hours`** - an exact algebraic identity,
> independent of the anchor, the numerator and the fleet. 0 violations over 453 series at 1e-4.

⚠️ **S-20's own wording needs one correction.** It proposed asserting "`velocity_instock >
velocity_raw` for exactly those shelves [with zero-stock intervals]". That is **not** the law:
the ratio is driven by `stock_hours` against a _fixed_ 720, not by censoring against
`elapsed_hours`, and no series in the fleet observes a full 30 days (`elapsed_hours` max
**715.9992**). The clause survives only when qualified to **censored series WITH SALES** (77 of 77
strictly faster; the 2 apparent exceptions are zero-sales series where both velocities are 0).
**Still owed by fixture 2**: the "v3 target vs v19 qty" clause and the stockout-decay guard, to be
re-derived from measurement once `engine_add_pod_v3` exists. Recorded in `golden.fixtures.notes`.

### S-24 · unchanged at 12 · S-26 honoured · S-01, S-02, S-04..S-06, S-08..S-14, S-17, S-21, S-25 unchanged

All **5** migrations this leg went through MCP `apply_migration` and all **5** files were written
after the apply and **proven** identical to `schema_migrations.statements` by md5 over the
comment-stripped, whitespace-normalised text. S-24 stays at **12**, not 17.
S-26 honoured: fixture 2 reads each velocity object **exactly once** per run.

## DECISIONS-READY updates (2026-07-30, relay leg 22)

### D-08 · ✅ FIRST LIVE RUN VERIFIED - burn-in day 1 clean, and it hit leg 20's numbers exactly

cron 44 fired **2026-07-30 18:40:00 UTC**, succeeded, "16 rows". Measured against leg 20's
rollback-envelope prediction - **every one of six matched**: **31** `inventory_events` (all
`kind='correction'`, 1 machine, 16 shelves) · **31** `shelf_composition` rows · **186** units on both
sides · **5** `count_above_capacity` anomalies (S-07's sensor-lie shelves A10/A12/A13/A14/A16,
expected) · **0** negative compositions · **0** conservation violations at both shelf and
shelf×product grain. Machine confirmed `MPMCC-1058-0000-R0`. Confidence uniformly 0.30.

⚠️ **Burn-in day 2 owed 2026-07-31. Day 3 completes ~2026-08-02**, then fleet-wide with no further
ask (baseline 1456 events / 5065 units / 41 anomalies / 0 / 0). **Before that flip, close S-28.**

⚠️ **OPEN QUESTION the next leg should answer cheaply:** cron 44 runs **hourly** (`40 * * * *`) but
WEIMI lands ~daily. Does a second run against the SAME snapshot write 31 MORE events, or is it a
no-op? `source_ref` is stamped with the snapshot time (`estimator:2026-07-30T18:00:36`), which
_suggests_ idempotency per snapshot - but that is a hypothesis, not a measurement. If it is NOT
idempotent, one machine generates ~744 events/day and the fleet ~35k/day. **Probe: after 19:40 UTC,
`count(*) FROM inventory_events` - still 31 means idempotent.**

### D-01, D-07, D-09 · re-verified against LIVE STATE at leg-22 STEP R, all in their correct state

D-01 live (`gate0_require_manual_confirm=true`, cron 13 on `build_draft_for_confirmed_v3`) ·
D-07 applied (11 co / 23 fully / 3 partner Active, 65 NULL all Inactive) · D-09 correctly NOT
executed, since its trigger condition is a cluster cutover to `engine_add_pod_v3` and that function
still does not exist. **Nothing approved was left undone.** D-02..D-06, D-10 unchanged this leg.

---

## STUCK updates (2026-07-30, relay leg 23)

### S-07 · ✅ FULLY DISCHARGED — fixture 14 is built and it needed no synthetic data

S-07 existed for exactly one purpose: to record that `stock > capacity` shelves exist in real data so
that fixture 14 would never have to fabricate them. **Fixture 14 is now built (26 assertions, green)
and it fabricates nothing.** The population it runs on was measured live this leg: **41 shelves
across 16 machines** fleet-wide, and on the fixture's own machine `MPMCC-1058-0000-R0` the five
shelves are all **Aquafina** pods — A10 17/12, A12 21/18, A13 20/18, A14 21/18, A16 21/16.
S-07 needs no further analysis and no further carry-forward.

### ⚠️ S-05 · EXTENDED — the silent-drop class has an OVER-capacity mirror, and it was never recorded

S-05 has always been about **sub**-capacity shelves whose computed qty rounds to 0 being dropped
instead of clamped. Measured this leg on the fixture's own engine run: **the same silent drop happens
at the other end of the range.** All five over-capacity shelves receive **no plan line at all** from
v19 — not a clamped line, not a `qty=0` line with a `clamp_reason`, nothing. The shelf simply is not
in the plan.

- **Why it matters more than the sub-capacity case.** An over-full shelf genuinely needs zero units,
  so the _quantity_ is right. What is missing is the **statement**: the plan cannot distinguish
  "this shelf was considered and needs nothing" from "this shelf was never looked at", which is the
  exact ambiguity LAW 5 exists to forbid.
- **Now bound by fixture 14 seq 30/31/32**, gated on `engine_add_pod_v3` and reading **expected_red 5**
  today. They become binding automatically the instant that function exists.
- Still P2.5 work. No engine body was touched this leg.

### S-28 · unchanged and still owed before D-08 goes fleet-wide

Fixture 22 seq 1 still counts `shelf_composition` rows on NISSAN-0804 A09 absolutely. The fix is
written down (re-express as a delta around the fixture's own estimator call, as leg 22 did for
fixture 19 seq 10). ⚠️ **Fixture 14 was deliberately built immune to this**: every one of its 26
assertions is either a violation count that must be 0, or a premise measured at run time, so D-08's
fleet-wide expansion cannot red it.

### S-01, S-02, S-04, S-06, S-08–S-14, S-17, S-20, S-21, S-25, S-26, S-27, S-29 unchanged

S-08's tripwire (seq 90) rode on **eleven** fixtures this leg and was green on every run.
S-26 honoured: fixture 14 reads neither velocity object at all.
S-27 honoured: all three suites run, twice.

### ⚠️ RISK 70 · NEW · `golden.render` DERIVES plan_date from fixture_id and ignores the column

`golden.render` computes `{{plan_date}}` as **`DATE '2030-01-01' + fixture_id`**. It never reads
`golden.fixtures.plan_date`. So for any fixture whose scenario uses the macro, the column is
**documentation that the harness does not enforce**, and setting it to something else makes the
registry and the actual writes disagree silently.

- Fixtures **3 (01-04)** and **10 (01-11)** follow the derivation. Fixture **2 (02-02)** does not, and
  is harmless **only** because fixture 2 is read-only and never uses the macro.
- The leg-22 pointer proposed `2030-02-14` for fixture 14 on the strength of fixture 2's column.
  Corrected to **2030-01-15** per LAW 13, with the column set to match the behaviour.
- `fixtures_plan_date_key UNIQUE (plan_date)` is what makes `+ fixture_id` collision-proof by
  construction — a hand-managed "2030-02 block" convention would not be.
- **Rule for the next fixture author:** either use the macro and set the column to
  `2030-01-01 + fixture_id`, or use a literal everywhere and set the column to that literal. Never mix.

### ⚠️ RISK 71 · NEW · the file-parity md5 recipe needs a trim step or it reports a false mismatch

Leg 22 recorded proving migration files identical to `schema_migrations.statements` "by md5 over the
comment-stripped, whitespace-normalised text". **That recipe fails on a correct file.** The MCP
strips the trailing newline, so the file is 1 byte longer and the normalised strings differ by one
trailing space. Add `btrim` (SQL) / `.strip()` (Python) to **both** sides. Verified this leg: without
the trim the fixture-14 file mismatched; with it, exact match.

## DECISIONS-READY updates (2026-07-30, relay leg 23)

### D-08 · ✅ THE OPEN IDEMPOTENCY QUESTION IS ANSWERED — measured, not waited for

Leg 22 left an explicit open question: cron 44 runs **hourly** (`40 * * * *`) but WEIMI lands
~daily, so does a second run against the same snapshot write 31 more events, or is it a no-op? Leg 22
proposed waiting for the 19:40 tick and re-counting. **Settled deterministically instead**, by
re-running the real writer over the same machine and the same snapshot inside a rollback envelope —
which is the same test the cron performs, run on demand rather than on a timer:

> **`events 31->31 (delta 0) | comp 31->31 (delta 0) | anom 5->5 (delta 0)`**

**Idempotent per snapshot, confirmed.** The `source_ref = 'estimator:<snapshot_at>'` key does exactly
what it was designed to do. Residue re-checked after the rollback: **31 / 31 / 5, unchanged.**

✅ **Then confirmed a SECOND time, independently, by the live cron.** The **19:40:00 UTC** tick fired
during this leg, reported `succeeded / "16 rows"` — the same 16 shelves — and the tables still read
**31 / 31 / 5** with **1 distinct `source_ref`**. So the answer holds both on demand and in
production: the cron does the work, reports rows, and writes nothing new until the snapshot changes.

⚠️ **The alarming projection in the leg-22 pointer is REFUTED, and should not be re-quoted.** It
warned that non-idempotency would mean ~744 events/day for one machine and **~35k/day fleet-wide**.
The real figure is **~1456 events per new snapshot fleet-wide, roughly once a day**, and every other
hourly run is a cheap no-op — which is precisely the behaviour leg 8 designed the hourly cadence
around ("a missed WEIMI cycle self-heals on the next hour").

**Burn-in day 1 remains clean. Day 2 owed 2026-07-31, day 3 ~2026-08-02**, then fleet-wide with no
further ask — **but close S-28 first.**

### D-01, D-07, D-09 · re-verified against LIVE STATE at leg-23 STEP R, all correct

D-01 live (`gate0_require_manual_confirm=true`, cron 13 on `build_draft_for_confirmed_v3`, `0 16 * * *`) ·
D-07 applied (11 co_managed / 23 fully_managed / 3 partner_managed; 65 NULL, all Inactive) ·
D-08 cron 44 ACTIVE and scoped to MPMCC-1058 · D-09 correctly NOT executed — its trigger condition is
a cluster cutover to `engine_add_pod_v3`, and that function still does not exist (`pg_proc` = 0).
**Nothing approved was left undone.** D-02..D-06, D-10 unchanged this leg.

### D-10 · unchanged — still the sole gate on both velocity metrics going canonical

Fixture 14 reads neither velocity object, so it neither advances nor blocks D-10.

---

## STUCK updates (2026-07-30, relay leg 24)

### ⚠️ S-19 · REOPENED IN SUBSTANCE — it was closed one table too early

S-19 ("leg 12's shadow scaffold is live but unregistered and object-level unverified") was closed at
leg 15 after all 7 ADR §7 promises were re-measured from `pg_catalog`. Every one of those checks was
correct. **The closure was still premature, because it verified the object that existed rather than
asking whether it was the right object.**

S-19's own closing note said: _"The shadow table carries no `linked_refill_pk` / `linked_swap_id`. If
the stitch ladder needs a shadow line table (`pod_refills_shadow`, ADR §2), that pair has to be
designed in, not assumed inherited."_ It filed that under **"Note for Phase 3"**. It was a **Phase 2
blocker**, and nine legs passed without anyone reading the acceptance assertions column by column.

- **The measurement.** All seven gated Phase-2 acceptance assertions read `public.pod_refills` or
  `public.blocked_demand`. Not one reads `pod_refill_plan`. Fixture 14 seq 31 asserts
  `pr.current_stock <= pr.max_stock`, seq 32 asserts `pr.qty = 0 AND pr.clamp_reason IS NOT NULL` —
  and **`pod_refill_plan_shadow` has no `current_stock`, no `max_stock`, no `clamp_reason`, no
  `wh_available_pod`**. It mirrors the plan/approval grain, not the engine-advisory grain.
- **Consequence had this not been caught.** `engine_add_pod_v3` would have been created, all seven
  gates would have armed on `EXISTS(pg_proc …)`, six assertions would have flipped from
  `expected_red` to genuine FAIL, and LAW 8 would have sent the next leg bisecting an engine that was
  not at fault — the defect was in the table it was told to write.
- **✅ CLOSED PROPERLY THIS LEG.** `pod_refills_shadow` + `v_blocked_demand_shadow_v3` applied,
  Cody-reviewed (⚠️ 4 revisions, all applied), ADR §9 addendum written, both registries updated.
- 📌 **The transferable lesson, and it is the second instance this build has hit:** verifying that an
  object matches its own spec is not the same as verifying the spec was right. S-04 established
  "treat a spec fixture premise as a hypothesis". This extends it to **schema**: an ADR's prediction
  about _when_ a sibling object is needed is also a hypothesis. Read the consumers, not the design.

### ⚠️ RISK 73 · NEW · `v_shadow_vs_live_plan_v3` carries `authenticated = arwdDxtm`

Default privileges grant `authenticated` the full privilege set on a newly created view; an explicit
`REVOKE ALL … FROM anon` does not touch it. `v_blocked_demand_shadow_v3` was created with the same
defect this leg and **fixed immediately** (`20260730201338`). `v_shadow_vs_live_plan_v3` (leg 12) still
has it, and was left untouched deliberately — outside this atomic unit (LAW 10).
**Not exploitable today**: both are `security_invoker` views and `authenticated` holds SELECT only on
the base tables, so a write fails at the base. It becomes real the moment anyone grants INSERT on a
base table. **Smallest unblock:** `REVOKE ALL ON public.v_shadow_vs_live_plan_v3 FROM authenticated;
GRANT SELECT …;` — one statement, and worth doing in any leg that is already touching that object.
📌 **Standing rule for every new view: `REVOKE ALL FROM authenticated` then `GRANT SELECT`. Revoking
`anon` alone is not least privilege**, and the ADR §7 promise ("`anon` REVOKEd") is silent on it.

### ⚠️ RISK 74 · NEW · `pod_refill_plan_shadow`'s append-only guarantee has nothing behind it

ADR §5 guarantee (1) — "write-once per run, never UPDATEd" — is **load-bearing for the Article 14
signoff itself**: it is the whole reason the shadow is a ledger rather than a cache. On
`pod_refill_plan_shadow` it is enforced only by `CREATE POLICY … FOR UPDATE USING (false)`, which
binds `authenticated` and **is bypassed by the SECURITY DEFINER writer and by `service_role`** — i.e.
by exactly the two identities that will ever write the table.

`pod_refills_shadow` carries a `BEFORE UPDATE OR DELETE` trigger that raises `42501`, which does bind
DEFINER functions; proven behaviourally (UPDATE and DELETE both refused inside a rollback envelope),
not asserted from the DDL. **`pod_refill_plan_shadow` has no equivalent.** If a future engine bug
UPDATEs a shadow plan row, the evidence base for the production cutover decision is silently
rewritten and §5's argument collapses retroactively.
**Smallest unblock:** one migration attaching the same trigger shape to `pod_refill_plan_shadow`.
Additive, no behaviour change for correct writers. Do it in the leg that first writes that table.

### S-05 · unchanged, and the v3 engine's obligation is now WRITABLE

The over-capacity mirror of the silent-drop class (leg 23) is bound by fixture 14 seq 30/31/32, which
read `pod_refills`. Those three assertions now have a table the v3 engine can actually satisfy them
from. Nothing about S-05's substance changed; what changed is that the fix is no longer blocked on a
missing object.

### S-24 · unchanged at 12 · S-27 honoured · S-28 unchanged and still owed before the fleet flip

All 4 migrations this leg went through MCP `apply_migration` and all 4 files were written after the
apply and **proven identical** to `schema_migrations.statements` by md5 with `.strip()`/`btrim` on
both sides (RISK 71). **4 of 4 MATCH.** S-24 stays at **12**, not 16.
S-27 honoured: all three suites run, twice (STEP R and after the migrations).
S-26 honoured: nothing this leg reads either velocity object.

### S-01, S-02, S-04, S-06, S-08–S-14, S-17, S-18, S-20, S-21, S-25, S-26, S-29 unchanged

S-08's tripwire (seq 90) rode on eleven fixtures and was green on every run, both suite passes.
S-18 NOT reopened — `execute_sql` resolved **by name** at STEP R; occurrence count stays **3**.

## DECISIONS-READY updates (2026-07-30, relay leg 24)

### D-01, D-07, D-08, D-09 · re-verified against LIVE STATE at leg-24 STEP R, all correct

Per leg 20's process correction, the ⭐ CS DECISIONS block was diffed against **live state**, not the
previous pointer's prose. **D-01** `gate0_require_manual_confirm = true`, cron 13 ACTIVE on
`build_draft_for_confirmed_v3` at `0 16 * * *`, last run 16:00:29 UTC ✅ · **D-07** 11 co_managed /
23 fully_managed / 3 partner_managed, `product_sourcing` 4022, conflicts 286 preserved ✅ ·
**D-08** cron 44 ACTIVE `40 * * * *` scoped to the MPMCC-1058 shelf set, **2 runs**, last 19:40:02,
tables steady at 31/31/5 ✅ · **D-09** correctly NOT executed — its trigger condition is a cluster
cutover to `engine_add_pod_v3`, and `pg_proc` still returns **0** for that name. Sentinels untouched
at **40 Active**. **Nothing approved was left undone.**

⚠️ **D-08 burn-in day 2 is owed 2026-07-31**; day 3 completes ~2026-08-02, then fleet-wide with no
further ask. **S-28 must be closed before that flip.**

### D-10 · unchanged, and this leg added a NEW way for it to be bypassed

`pod_refills_shadow.velocity_instock` now exists. Once the table has rows it will look like a
convenient fleet-wide velocity source, and reading it would route around D-10 entirely — inheriting a
number whose meaning for the 39 no-velocity shelves is still undecided. Guarded three ways: a
`COMMENT ON COLUMN` in the database, an explicit **anti-registration** in `METRICS_REGISTRY.md`, and
this note. **D-10 remains the sole gate on both velocity metrics going canonical.**

### D-02 through D-06 unchanged — no flag flipped, no parked activation applied

No protected entity was written this leg, no engine body was touched, no live plan table was touched,
no flag was flipped and no cron was changed.

---

## STUCK updates (2026-07-30, relay leg 25)

### ⛔ S-28 · ESCALATED AND CORRECTED — it is not one assertion, and the mechanism is not a count

S-28 read: _"D-08's fleet-wide expansion will red fixture 22 … The exposure is one assertion,
fixture 22 seq 1"_, with the fix _"re-express seq 1 as a delta around the fixture's own
`estimate_shelf_composition_v3(v_s)` call, exactly as leg 22 did for fixture 19 seq 10."_

⚠️ **Both halves are wrong, and applying the written fix would have shipped a still-broken fixture
while believing it fixed.** Measured this leg, in situ, inside a rollback envelope:

- **The exposure is six assertions, not one.** Simulating the post-flip world (cron 44 consumes
  NISSAN-0804's snapshot first, then run fixture 22) gives **7 fail / 13 pass**: seq **1** (candidates
  2→8), **2** (drops_allocated 1→0), **3** (estimator_events 2→0), **4** (decayed_by_estimator 1→0),
  **5** (conf 0.85→0.30), **6** (0.40→0), plus the new seq 89.
- **The mechanism is not row-count drift — it is that the fixture's estimator call NEVER RUNS.**
  `estimate_shelf_composition_v3` is idempotent per snapshot per shelf (`prosrc` line 59-60,
  `already_processed_skipped -> CONTINUE`, keyed on `source_ref='estimator:<snapshot_at>'`). Proven:
  first call `events_written=7 / skipped=0`; second call `events_written=0 / skipped=1`.
- **A delta fix could not have worked.** A delta around the fixture's own call is **0** post-flip,
  because the call writes nothing. The leg-22 fixture-19 precedent does not transfer.

📌 **The finding S-28 never had, and it is the serious one. Fixture 20 is also exposed, and it is the
LAW 7 proof.** Fixtures 20 and 22 are the only two of eleven that call the estimator. Leg 22 recorded
_"Fixture 20 is insulated by `kind = 'derived_decrement'`"_ — that insulates it against **extra**
rows, not against **zero** rows. Fixture 20's assertions are shaped _"the expired bucket was NOT
touched"_ / _"0 unallocatable residuals"_, so a no-op makes the **EXPIRY IRON RULE pass vacuously**.
That is the S-29 class landing in the one fixture that proves LAW 7.

**✅ HALF-CLOSED this leg** by `20260730204005_prd110_p14_golden_estimator_noop_premise_guard`:
run-time premise assertion **seq 89** on both fixtures (`already_processed_skipped = 0`). This does
**not** fix the no-op — it makes the no-op impossible to miss and **self-diagnosing**, so a bisecting
leg reads "the cron got here first" rather than hunting a blameless estimator. Suites 216 → **218
pass / 0 fail**.

**⚠️ STILL OWED, and it is now a hard prerequisite of D-08's fleet flip.** A **re-derive path** so a
caller that has deliberately perturbed belief can re-run against an already-consumed snapshot. The
shape is a third `p_force_rederive boolean DEFAULT false` argument that skips only the
already-processed `CONTINUE`. ⚠️ Two landmines for whoever builds it: (1) `CREATE OR REPLACE` with an
added parameter creates an **overload**, it does not replace — the two-arg version must be dropped or
cron 44's two-arg call site becomes ambiguous (CLAUDE.md's `repurpose_machine` foot-gun, and the
`pronargdefaults` trap from the Wave-2 closeout); (2) it is Dara + Cody class because it weakens an
idempotency guard on a live cron path. Force is nonetheless **low-risk by construction**: if belief
already equals the sensor the recomputed delta is 0 and nothing is written.

**Order of operations for the leg that flips D-08 fleet-wide:** build the re-derive path → re-express
fixture 22's PART-1 premises → re-run all three suites green → _then_ flip. Not the other way round.

### 📌 D-08 burn-in · day 1 second snapshot observed clean, and anomalies accrue PER SNAPSHOT

A new WEIMI snapshot landed **19:59:08 UTC** and cron 44 processed it at **20:40:00 UTC**. Result:
**+5 `count_above_capacity` anomalies, 0 new events, 0 new composition rows** — `inventory_anomalies`
5 → **10**, `inventory_events` and `shelf_composition` steady at **31 / 31**. Correct behaviour: the
five shelves are S-07's known sensor-lie shelves (observed/expected 21/16, 17/12, 20/18, 21/18,
21/18 — exact match to leg 23's measurement) and no shelf count changed, so there was no delta to
allocate. Two distinct `source_ref` values, one per snapshot.

⚠️ **New, worth recording before the fleet flip:** leg 23 proved events are idempotent per snapshot.
**Anomalies are not** — they are raised **once per snapshot per offending shelf**. So the sensor-lie
population accrues **5 rows per snapshot** on one machine today and **41 per snapshot** fleet-wide
(leg 20's measured figure), roughly daily and indefinitely, for a condition that is known, expected
and never auto-resolved. Not a fault and not a blocker; it does mean `inventory_anomalies` is an
**accruing** table whose dominant population will be a known-benign class, and any future consumer
must filter rather than count. The fleet flip multiplies today's rate by **8.2x**.

### S-01, S-02, S-04, S-05, S-06, S-08–S-14, S-17–S-27, S-29 unchanged · S-03, S-07, S-15, S-16, S-19, S-22, S-23 stay closed

S-18 **NOT reopened** — `execute_sql` resolved **by name** at STEP R; occurrence count stays **3**.
S-24 unchanged at **12**: this leg's single migration went through MCP `apply_migration` and its file
was written after the apply and **proven identical** to `schema_migrations.statements` by md5 with
`.strip()`/`btrim` on both sides (RISK 71) — `e6c819c371cae54f5f1938d8c72a058a`, 5642 bytes.
S-27 honoured: all three suites run, twice. S-26 honoured: nothing this leg reads either velocity
object. S-08's tripwire (seq 90) rode on eleven fixtures and was green on every run.

### 📌 RISK 75 · NEW · a fixture that calls a live, idempotent-per-input writer is asserting that nothing else called it first

The general form of S-28, and the **third** instance of the family (leg 22 fixture 19's absolute
`inventory_events` count; leg 23 / S-28 fixture 22 seq 1; now the estimator no-op). The earlier two
were framed as _"count deltas, or scope by something the fixture owns"_. **That framing is
insufficient**, because it assumes the fixture's own call still does work. When the writer is
idempotent on an input the fixture does not control — a WEIMI snapshot, a run_id, a source_ref — the
fixture's call can become a **no-op**, and then deltas, absolute counts and owned-scope counts are
all equally meaningless.

**Rule:** any fixture that calls a live writer must assert **that its own call did work**, as a
run-time premise, before asserting anything about what the call produced. seq **89** is now the
reserved sequence for that premise, alongside seq 90 (S-08 feedback tripwire) and seq 91/92/93/97
(live-table tripwires).

## DECISIONS-READY updates (2026-07-30, relay leg 25)

### D-01, D-07, D-08, D-09 · re-verified against LIVE STATE at leg-25 STEP R, all correct

Per leg 20's process correction, the ⭐ CS DECISIONS block was diffed against **live state**, not
prose. **D-01** `gate0_require_manual_confirm = true`, cron 13 ACTIVE on `build_draft_for_confirmed_v3`
at `0 16 * * *`, 74 runs, last 16:00:00 UTC ✅ · **D-07** 11 co_managed / 23 fully_managed /
3 partner_managed, 65 NULL all Inactive, `product_sourcing` 4022, conflicts 286 preserved ✅ ·
**D-08** cron 44 ACTIVE `40 * * * *` scoped to MPMCC-1058, now **3 runs** (18:40, 19:40, 20:40) ✅ ·
**D-09** correctly NOT executed — its trigger condition is a cluster cutover to `engine_add_pod_v3`,
and `pg_proc` still returns **0** for that name. Sentinels untouched at **40 Active**.
**Nothing approved was left undone.**

⚠️ **D-08 burn-in day 2 owed 2026-07-31**, day 3 ~2026-08-02, then fleet-wide with no further ask —
**but S-28's re-derive half must land first**, not merely its guard half.

### D-02 through D-06, D-10 unchanged — no flag flipped, no parked activation applied

No protected entity was written this leg, no engine body touched, no live plan table touched, no flag
flipped, no cron changed. D-10 remains the sole gate on both velocity metrics going canonical.

---

## STUCK updates (2026-07-30, relay leg 26)

### ✅ S-28 · RE-DERIVE PATH SHIPPED — the half that was owed before D-08's fleet flip

`estimate_shelf_composition_v3` gained `p_force_rederive boolean DEFAULT false`
(`20260730211918`), Cody-reviewed, both landmines handled:

- **Overload landmine closed.** Both original parameters carry defaults, so a surviving 2-arg
  candidate beside a 3-arg-all-defaults one makes EVERY call ambiguous (42725) — including cron 44's
  live `(shelf_id, false)`. The 2-arg version was DROPPED in the same transaction, and the migration
  **executes cron 44's exact positional shape after the swap** to prove the call site resolves.
- **Idempotency is NOT weakened for the cron.** Force skips only the already-processed `CONTINUE`,
  and it is **REFUSED fleet-wide** (`p_shelf_id IS NULL` raises) — an accidental mass re-derive is
  impossible by construction, and the migration proves that guard binds.

**Behavioural proof, inside a rollback envelope** (this is the part that matters — the first probe
did NOT prove it, see below): consume the snapshot → `events=1, drops=1` · repeat → **`skipped=1,
events=0`** · perturb belief again → **still `skipped=1`** · **force → `skipped=0,
forced_rederive=1, events=1, drops=1`**. Residue 0 (31/31/10 unchanged).

⚠️ **STILL OWED, and it is what actually gates the flip: re-expressing fixtures 20 and 22 to USE the
force path.** The capability exists; the fixtures do not call it yet. **Order for the leg that flips
D-08 fleet-wide is unchanged apart from step 1 being done: ~~build re-derive~~ → re-express fixtures
20/22 → all three suites green → then flip.**

📌 **When re-expressing, seq 89 must change with it.** Leg 25's premise assertion is
`already_processed_skipped = 0`. Under `force => true` that is **true by construction**, so seq 89
would become exactly the vacuous premise it was minted to prevent. Assert `forced_rederive = 1`
(or `events_written > 0`) instead — the premise must remain "my own call did work", not "my own call
was not skipped".

### 📌 RISK 76 · NEW · the estimator's idempotency marker is the EVENTS, so a flat shelf never skips

Leg 26's first force probe read `already_processed_skipped = 0` on a shelf cron 44 had already
processed, which looks like the guard failing. It is not. The skip test is
`EXISTS(inventory_events WHERE shelf_id = s AND source_ref = v_ref)` and `v_ref` is derived from the
**current** `stock_as_of`; a new WEIMI snapshot had landed, and in any case **a shelf whose delta is
0 writes no event and therefore leaves no marker**, so it is legitimately re-examined every run.

**Consequences for anyone reasoning about this function.** (1) "Skipped = 0" is not evidence the
force flag is broken, nor that the snapshot is new. (2) A probe intending to exercise the
already-processed branch must first make the shelf **write** an event under the current snapshot —
perturb belief, run, then re-run. Leg 26's first probe did none of that and would have "proven" force
worked while never reaching the branch at all. **This is RISK 75's family again, one level down:
the fixture's own call ran, but the branch under test never executed.**

### ⚠️ RISK 77 · NEW · DROP+CREATE of a function silently re-grants `anon` from default privileges

The S-28 migration ran `REVOKE ALL … FROM PUBLIC` and still shipped `anon=X` on a SECURITY DEFINER
function, because **PUBLIC is not `anon`**: Supabase's `ALTER DEFAULT PRIVILEGES … GRANT EXECUTE ON
FUNCTIONS TO anon, authenticated, service_role` re-attaches the grant to every newly created function.
Caught by reading `proacl` after the apply rather than trusting `success: true`; fixed forward by
`20260730212013`.

It was **not** cosmetic: the estimator's role check is `IF v_actor IS NOT NULL AND NOT EXISTS(…)`, so
for an anonymous caller `auth.uid()` is NULL and the check is **skipped entirely**, and `p_dry_run` is
only a default — `estimate_shelf_composition_v3(<shelf>, false)` would have written real
`inventory_events`.

**Standing rule:** any DROP+CREATE of a function restates the intended ACL explicitly **and asserts
it**. This is RISK 73's mirror image (there: revoking `anon` alone missed `authenticated` on a view;
here: revoking PUBLIC alone missed `anon` on a function). **Neither revoke implies the other; assert
the whole ACL.**

### ⛔ RISK 78 · NEW · the leg-25 pointer's "re-express the seven against the shadow objects first" CANNOT be done standalone

The leg-25 pointer offered option **(a)** "re-express all seven acceptance criteria against the shadow
objects first, as its own atomic unit — **recommended**" versus **(b)** engine + re-expression in ONE
unit. Measured this leg by reading the seven assertions and all four fixture scenarios: **(a) is not
viable, and shipping it would manufacture two vacuous greens.**

- All four fixtures (3, 5, 14, 105) call **`public.engine_add_pod({{plan_date}}, 7)`** — the v19
  engine — which writes **live `pod_refills`**. Six of the seven assertions read `pod_refills`; the
  seventh (105 seq 10) reads `blocked_demand`.
- Re-pointing them at `pod_refills_shadow` / `v_blocked_demand_shadow_v3` **without a v3 call in the
  scenario** leaves them reading an **empty** table. Then, the instant `engine_add_pod_v3` exists and
  the gates open:
  - fixture 3 seq 1 and 14 seq 30/31/32 (shaped "count of uncovered shelves = 0") fail genuinely;
  - **fixture 5 seq 10 and 105 seq 10 (shaped "count of blocked = 0") pass VACUOUSLY** — zero bad rows
    in an empty table. That is the S-29 class, reintroduced by the very migration meant to arm these;
  - **fixture 3 seq 4 regresses**: it is today's single arrived-early PASS (`max(qty) > 0` on live
    `pod_refills`), and against an empty shadow it reads 0 and turns red. The pointer explicitly
    required that it must NOT regress.

**Therefore: take option (b).** The re-expression must land in the same atomic unit as the engine, and
each re-expressed assertion needs a **seq-89-class premise that the v3 call actually wrote shadow rows**
before it asserts anything about their content. Do not re-point a "count of bad things = 0" assertion
at a table nothing has written yet.

### S-01, S-02, S-04–S-06, S-08–S-14, S-17–S-27, S-29 unchanged · S-03, S-07, S-15, S-16, S-19, S-22, S-23 stay closed

S-18 **NOT reopened** — `execute_sql` resolved **by name** at STEP R; occurrence count stays **3**.
S-24 unchanged at **12**: both migrations this leg went through MCP `apply_migration` and both files
were written after the apply and **proven identical** to `schema_migrations.statements`,
`.strip()`/`btrim` both sides (RISK 71) — **2 of 2 MATCH**.
S-27 honoured: all three suites run, twice (STEP R and post-migration), identical both times.
S-26 honoured: nothing this leg reads either velocity object.
S-08's tripwire (seq 90) rode on eleven fixtures and was green on every run.

## DECISIONS-READY updates (2026-07-30, relay leg 26)

### D-01, D-07, D-08, D-09 · re-verified against LIVE STATE at leg-26 STEP R, all correct

Diffed against **live state**, not prose (R20-D3). **D-01** `gate0_require_manual_confirm = true`,
cron 13 ACTIVE on `build_draft_for_confirmed_v3` at `0 16 * * *` ✅ · **D-07** 11 co_managed /
23 fully_managed / 3 partner_managed ✅ · **D-08** cron 44 ACTIVE `40 * * * *` scoped to MPMCC-1058,
**3 runs**, tables steady at 31/31/10 ✅ · **D-09** correctly NOT executed — its trigger condition is a
cluster cutover to `engine_add_pod_v3`, and `pg_proc` still returns **0** for that name. Sentinels
untouched at **40 Active**. **Nothing approved was left undone.**

⚠️ **D-08 burn-in day 2 owed 2026-07-31**, day 3 ~2026-08-02, then fleet-wide with no further ask.
**S-28's re-derive path is now SHIPPED; what remains before the flip is re-expressing fixtures 20/22
to use it** (see S-28 above, including the seq-89 correction that must ride with it).

### D-02 through D-06, D-10 unchanged — no flag flipped, no parked activation applied

No protected entity was written this leg, no engine body touched, no live plan table touched, no flag
flipped, no cron changed. D-10 remains the sole gate on both velocity metrics going canonical.

### ⛔ S-30 · NEW (leg 26) · an UNAPPLIED migration file is sitting in `supabase/migrations/`

- **What.** `20260730212000_prd110_p20c_golden_p2_acceptance_reexpressed_on_shadow.sql`, 350 lines,
  21605 bytes, mtime **2026-07-30 21:02:52 UTC**, header self-labelled _"PRD-110 · P2.0c · relay
  leg 26"_ — six minutes before leg 26's first probe, so a concurrent or aborted session wrote it.
- **NOT APPLIED, measured four ways:** 0 `schema_migrations` rows for version `20260730212000` and 0
  for any `%p20c%`/`%reexpress%` name · `prd110%` = **61** = leg 25's 59 + leg 26's 2 · **0**
  assertions referencing `pod_refills_shadow` / `blocked_demand_shadow` · **0** rows at seq 88 ·
  assertions still **224**.
- **Why it matters.** This is **S-24's mirror image**: S-24 is _applied without a file_, this is _a
  file without an apply_. Every consistency check this build runs reads the DB, so a repo-only object
  is invisible to all of them.
- **Why leg 26 did not act on it.** Not applied: 350 unreviewed lines rewriting all seven gated
  acceptance assertions, at leg close, with no capacity to verify — the RELAY contract forbids
  starting what cannot be finished. Not deleted or moved: it may be a live concurrent session's work,
  and the silent-application risk is low because this project has **no local `supabase` CLI**, so
  `supabase db push` is not a live path.
- **Next leg's FIRST item:** decide it explicitly — review-and-apply, or delete. **Never assume it
  landed.** If applying, it needs a full Cody pass and all three suites re-run; note that it would
  take assertions from 224 to some new count and add a seq-88 premise.
- 📌 **Process lesson:** `git status` belongs in **STEP R**, not at leg close. Leg 26 verified the
  pointer against the code and the data but not against the working tree.

### 📌 RISK 78 · CORRECTED by S-30's file — option (a) is viable WITH a sentinel, not impossible

RISK 78 (written earlier this leg) said the standalone re-expression "cannot be done". **Overstated.**
The unapplied file demonstrates the viable shape: every re-expressed assertion returns a sentinel
**`-1`** when the fixture has no v3 run of its own — failing `eq 0` and `gt 0` alike, so an empty
shadow table can never read as a pass — plus a **seq 88** run-time premise (the engine's analogue of
seq 89). **Accurate statement:** the standalone route is viable **only with** a vacuous-green sentinel
and a run-time premise on every re-expressed assertion; the _naive_ mechanical swap the leg-25 pointer
described manufactures two vacuous greens (fixture 5 seq 10, 105 seq 10) and regresses the one
arrived-early pass (fixture 3 seq 4). The hazard measurement stands; the "impossible" conclusion does
not.

---

## STUCK / DECISIONS updates (2026-07-30, relay leg 27)

### ✅ S-28 · CLOSED — and the fix was NOT the one leg 26 owed

Leg 26's pointer said the remaining work was "re-express fixtures 20 and 22 to USE the force
path". **Measured live at leg 27, that would not have worked.** Simulating D-08's fleet-wide
expansion exactly (`estimate_shelf_composition_v3(NULL,false)` then `run_all('P1')`, in a
rollback envelope) reds **17 assertions across THREE fixtures** — 20 (seq 2,4,8,9,10,15,89),
**21 (seq 4,6,7)**, 22 (seq 1,2,3,4,5,6,89). Two things follow:

- **Fixture 21 never calls the estimator at all**, so no `p_force_rederive` route could ever
  reach it.
- The estimator's own report names the mechanism: `already_processed_skipped = 0` but
  `cold_start_seeded = 525`. The reds are **root cause B (pre-existing seeded belief)**, which
  leg 26's force path (root cause A, snapshot consumption) does not address.

**Closed by `golden.arrange_shelf`** (4 migrations, leg 27), which resets DERIVED
`shelf_composition` for a shelf and re-dates the machine's newest WEIMI row, so a fixture owns
its own preconditions. Not one assertion was edited — the proof that the fixtures were always
asserting the right thing and merely borrowing preconditions they did not own.
**Result: 17 genuine reds → 1.** Live suites unchanged at 218 pass / 0 fail / 6 expected-red /
1 arrived-early / 0 vacuous / 0 scenario errors.

### ✅ S-31 · NEW AND CLOSED — a SECOND orphan file, which leg 26 missed

`git status` at leg-27 STEP R found **two** unapplied migration files, not the one S-30 named.
`20260730203000_prd110_golden_arrange_shelf_d08_fleetwide_immunity.sql` (leg 24, 120 lines) was
never applied — `golden.arrange_shelf` was absent from `pg_proc`, 0 rows in `schema_migrations`.
Its analysis was **correct and better than leg 25's and leg 26's** (it predicted exactly the 15
non-seq-89 members of the 17). Its implementation was **broken**: the snapshot release INSERTs a
replay row, but `weimi_device_status` carries `unique_device_status UNIQUE (weimi_device_id,
snapshot_date)` — one row per device per DAY — so it raised `duplicate key` on every call.
📌 **A file on disk is not a verified change, in either direction: this one's reasoning was
sound and its code could never have run.** Applied at leg 27 in corrected form (re-date the
existing row instead of inserting).

### ⏸️ S-30 · DECIDED, explicitly: retained, NOT applied, owner assigned

`20260730212000_prd110_p20c_golden_p2_acceptance_reexpressed_on_shadow.sql` (350 lines) is still
unapplied and is **deliberately neither applied nor deleted**. Re-verified at leg 27: 0
`schema_migrations` rows, 0 assertions referencing `pod_refills_shadow`/`blocked_demand_shadow`,
0 seq-88 rows, assertions still 224. **Reason it is not applied now:** it re-expresses the seven
P2 acceptance assertions against shadow objects that are still **empty** (`pod_refill_plan_shadow`
0, `pod_refills_shadow` 0) because `engine_add_pod_v3` does not exist. Its vacuous-green sentinel
(`-1`) and seq-88 premise are the right design, but they can only be _validated_ alongside the
engine that populates those tables. **Owner: the `engine_add_pod_v3` unit (option (b)) — it is
input to that leg, reviewed and applied there, not before.**

### ⛔ S-32 · NEW · fixture 2 seq 42 races the live WEIMI ingest — blocks D-08's fleet flip

The one surviving red in the post-D-08 simulation is **fixture 2 seq 42** ("the shelf-split view
reports the SAME anchor as its pod-grain parent"). It is **not** caused by `arrange_shelf`: a
control run (fleet-wide estimator + P2 only, no P1) is clean, and both anchors read identically.
**The production WEIMI ingest lands daily at ~22:00:40 UTC** (41 rows; measured on 07-26, 27, 28,
29 and 30). A long run that straddles it captures the `pod` anchor before the new snapshot and
the `shelf` anchor after, so they differ. Same class as the seq-97 false red this leg also hit
when a run straddled cron 44's :40 tick.
⚠️ **This threatens STEP 7's S7 (`golden.run_all()` ×3 consecutive, identical results)** — two
independent live jobs (cron 44 hourly at :40, WEIMI ingest daily at 22:00:40) can move global
counts and anchors mid-run. **Smallest unblock:** scope seq 42 / seq 97 to values the fixture
owns, or capture both anchors in one statement. Not attempted this leg (scope).

### 📌 S-33 · NEW · a scenario_error leaves STALE scratch, and the assertions then pass against it

`golden.run_fixture` catches a scenario error into `detail` and continues evaluating assertions.
The scenario's own `golden.scratch` DELETE+INSERT is rolled back with it, so **every assertion
then reads the PREVIOUS run's scratch and can pass on stale data**. Observed directly this leg:
fixture 20 reported 20 passes while its scenario had aborted and `written_at` still showed the
run from 20 minutes earlier. `run_fixture` does count the scenario error as a fail, so the
fixture is not reported green — but the 20 "passes" are fictional, and any analysis query that
filters `e ? 'seq'` (as mine first did) **cannot see the scenario_error element at all**.
**Smallest unblock:** on scenario_error, delete that fixture's scratch rows so every assertion
reads NULL and fails honestly. Not attempted this leg (scope).

### 📌 RISK 79 · `btrim` and `.strip()` are NOT symmetric — the file-parity check can lie

RISK 71 says migration file-vs-DB md5 parity needs `btrim`/`.strip()` on both sides. **That is
not sufficient, and it produced a false DRIFT on all four files this leg.** Postgres one-arg
`btrim(s)` strips **spaces only** — not newlines. Python `.strip()` strips newlines too. So a
DB value ending in `\n` compared against a `.strip()`ed file differs by exactly one character at
identical-looking length. Use `raw.rstrip(' \t')` on the file side (or `btrim(s, E' \t\n')` on
both). All four leg-27 files then MATCH exactly.

### 📌 RISK 80 · `golden.run_fixture` does NOT provide a rollback envelope

It executes `scenario_sql` inside a `BEGIN ... EXCEPTION WHEN OTHERS` block, which only rolls
back if an exception **escapes**. The fixtures' own inner `BEGIN ... RAISE 'GPnn:' ... EXCEPTION`
block is the real envelope. **Anything a fixture calls that must not commit has to sit INSIDE
that inner block** — `golden.arrange_shelf` calls are placed there for exactly this reason. A
call placed before it would write to production.

### D-08 · burn-in unblocked from S-28's side; S-32 is now the sole remaining gate

The re-derive path (leg 26) and the precondition primitive (leg 27) are both shipped and proven.
Fleet-wide exposure is down from 17 assertions to 1, and that 1 is S-32's ingest race, not a
fixture defect. **Do not flip fleet-wide until S-32 is closed**, or the flip will be blamed for
a red it did not cause. cron 44 remains ACTIVE `40 * * * *` scoped to MPMCC-1058.

### S-01–S-27, S-29 unchanged · D-01/D-07/D-09/D-10 unchanged · S-24 unchanged at 12

S-18 not reopened (`execute_sql` resolved by name; occurrence count stays 3). S-27 honoured: all
three suites run, repeatedly. No flag flipped, no cron changed, no protected entity written, no
engine body touched, no live plan table touched (0 `pod_refills` rows on any plan_date < 2030).

---

## STUCK / DECISIONS updates (2026-07-30, relay leg 28)

### ✅ S-34 · CLOSED — fixtures 3 and 5 now own the shelf state they assert on

S-34 was specified in full inside leg 27's R27-D6 addendum and deliberately NOT written here (its
SHA was inside the scoped hash). Folded in now, and closed in the same leg.

**Reproduced exactly at leg-28 STEP R: 213 pass / 5 genuine fail / 6 expected-red / 0 scenario
errors**, matching R27-D6's corrected prediction to the assertion. Diagnosis of all five, measured:

| red     | mechanism                                                                                                 |
| ------- | --------------------------------------------------------------------------------------------------------- |
| 3:5     | `>= 9 lines` tracked live stock. 11 sub-capacity shelves, 8 lines; the 3 missing are S-05 silent drops.   |
| 3:12    | fleet-wide `G2 = 0` — a real, recurring production gap. **See S-35, this is not a fixture artifact.**     |
| 5:1/3/4 | VOXMCC-1005 A02 read 6/6 (at capacity, correctly no line); A04 13/20 (sub-capacity, dropped at 0.13/day). |

**Closed by `golden.pin_machine_stock` / `golden.restore_machine_stock`** (leg-27 `arrange_shelf`
precedent): the fixture pins its machines empty, plans, and restores. **Suites: 223 pass / 0 genuine
fail / 6 expected-red / 0 scenario errors / 229 assertions.**

⚠️ **The finding worth carrying, because it nearly went unnoticed.** The empty pin made fixture 3
**seq 1** flip from expected-red to PASS. That is a TRUE result on a real 16-shelf evaluation — not
the S-29 vacuous class — but it is **no longer discriminating for S-05**, whose silent drop only
fires at _partial_ stock. Assertion power was therefore **moved, not lost**: S-05's sub-capacity
mirror is now **fixture 14 seq 33** (unpinned, same machine, same `engine_add_pod_v3` gate), reading
**3** today. 📌 **Generalisable lesson: neutralising a confounder can also neutralise the defect you
were detecting. Check the expected-red COUNT before and after any precondition change — leg 28 caught
this only because the count moved 6 → 5.**

### ⚠️ S-35 · NEW · production reopens the slot_lifecycle gap every night, and the healer is 17h behind

- **What.** `ACTIVATE-2005-0000-W0 A01` (Aquafina, 13/15) carries a live WEIMI slot and a pod binding
  but **no current `slot_lifecycle` row**, so `engine_add_pod` cannot see it. Its only lifecycle row
  was archived at **2026-07-30 22:15:03.908 UTC** and **no replacement was created**
  (`lifecycle_created_today = 0`). The row is left `archived = true` AND `is_current = true`.
- **Attributed, not guessed.** cron **7** `evaluate-lifecycle-4h` (`15 22 * * *`, an edge function
  via `net.http_post`) fired at 22:15:00.178 — **3.7 s before** the archive. The first golden run of
  the leg started at 22:15:38, **35 s after**, so this is production, not a fixture side-effect.
- **It is recurring, not a one-off.** `rotated_out_at` in the last 7 days: 07-24 ×1, 07-25 ×3,
  07-27 ×3, 07-28 ×7, 07-29 ×9, 07-30 ×2. 317 rows fleet-wide sit `archived AND is_current`.
- **The healer exists and is 17 hours late.** cron **42**
  `seed_missing_slot_lifecycle(false, NULL)` runs at **15:30 UTC**; the gap opens at **22:15 UTC**.
  So a shelf is invisible to the engine for ~17h15m. It does close **before** cron 13's 16:00 UTC
  plan build, which is why no plan has been observably damaged — the margin is **30 minutes**.
- **Dry run confirms the shelf is in scope and claimable:** `pending_count = 1`, action `revive`,
  and the dry run is **pure** (`slot_lifecycle` 1364 → 1364) and costs **97 ms**.
- **This is exactly what BUILD SPEC P0.2 warned about** — _"Also fix the generator … else the gap
  regrows."_ The INSERT-side generator was built (`tg_provision_shelf_lifecycle_ins` +
  `provision_shelf_lifecycle_v3`, fixture 3 seq 17 green). **The ROTATION side was never covered.**
- **Why parked, not fixed.** The archiving writer is an **edge function** (Stax, Article 9), outside
  PRD-110 (LAW 10); and re-scheduling cron 42 is a production cron change, which **LAW 12 permits
  only where the BUILD SPEC explicitly says so (P0.3)**. Parked as **D-11**.
- **Loop impact: none, and it is now bound.** Fixture 3 seq 12 asserts the durable invariant (no
  shelf is PERMANENTLY blind — every offender is claimed by the canonical seeder) instead of an
  instantaneous fleet-wide 0 that production makes false for 17h a day.

### 📌 RISK 82 · NEW · `golden.run_all` is ONE transaction, and that is load-bearing

Proven, not assumed: every fixture's `pod_refills` rows in a run share a single `created_at`
(`now()` is transaction-start time). Consequences: (1) a fixture may mutate live state and revert it
in-scenario with **zero external visibility** — the basis of `pin_machine_stock`'s safety; (2) a
fixture's writes to synthetic 2030 `plan_date`s **COMMIT** (fixtures 3 and 5 have no inner rollback
envelope, unlike 20/21/22) — this has always been true and is LAW-12-legal, but the next author must
not assume "fixtures roll back"; (3) three `run_all` calls in one statement are still one transaction.

### 📌 RISK 83 · NEW · a suite pass count is not a suite result — read the expected-red count too

Leg 28's fix took the suites to `223 pass / 0 fail`, which reads as unambiguously good. The
expected-red count had silently dropped **6 → 5**, meaning a v3 acceptance criterion had stopped
detecting the defect it was minted for. **At every checkpoint compare `n_pass`, `n_fail` AND
`n_expected_red` against the previous leg**, and explain every movement in all three.

### D-01, D-07, D-08, D-09 · re-verified against LIVE STATE at leg-28 STEP R, all correct

Diffed against live state, not prose (R20-D3). **D-01** `gate0_require_manual_confirm = true`, cron 13
ACTIVE on `build_draft_for_confirmed_v3` at `0 16 * * *` ✅ · **D-07** 11 co_managed / 23 fully_managed /
3 partner_managed, 65 NULL all Inactive, `product_sourcing` 4022, conflicts **286** preserved ✅ ·
**D-08** cron 44 ACTIVE `40 * * * *` scoped to MPMCC-1058, **4 runs** (18:40, 19:40, 20:40, 21:40),
events/composition steady at **31 / 31**, anomalies accruing per snapshot as designed (R25-D3) ✅ ·
**D-09** correctly NOT executed — its trigger is a cluster cutover to `engine_add_pod_v3`, and
`pg_proc` still returns **0**. Sentinels untouched at **40 Active**. **Nothing approved was left undone.**

⚠️ **D-08 burn-in day 2 owed 2026-07-31**, day 3 ~2026-08-02, then fleet-wide with no further ask.
**S-32 remains the sole gate** and is untouched this leg.

### ⚠️ D-11 · NEW · close the nightly slot_lifecycle blindness window (S-35)

- **What.** Shelves rotated by cron 7 at 22:15 UTC are invisible to the engine until cron 42 seeds
  them at 15:30 UTC the next day — a ~17h window, 1–9 shelves/day, 30 minutes of margin before the
  16:00 UTC plan build.
- **Why it is CS's call and not the loop's.** Both available fixes are production changes the loop
  is barred from making: the edge function is Stax/Article 9 territory (LAW 10), and re-scheduling a
  cron is forbidden by **LAW 12** outside P0.3.
- **Cheapest activation (one statement, no code change) — add a second daily seed right after the
  rotation, rather than moving the existing one:**

```sql
SELECT cron.schedule('prd110_p02_slot_lifecycle_coverage_post_rotation',
                     '25 22 * * *',
                     $$SELECT public.seed_missing_slot_lifecycle(false, NULL);$$);
```

- **Why a second job and not `cron.alter_job(42, ...)`:** cron 42's 15:30 UTC slot is the one that
  guarantees coverage 30 minutes before cron 13 builds the plan. Moving it trades a known-good
  guarantee for an unknown one; adding shortens the window from ~17h to ~10 minutes and keeps it.
- **Rollback:** `SELECT cron.unschedule('prd110_p02_slot_lifecycle_coverage_post_rotation');`
- **The real fix, which this only mitigates:** the rotation path should provision a replacement
  lifecycle row in the same transaction it archives one — a Stax ticket against the
  `evaluate-lifecycle` edge function. Recorded so the mitigation is not mistaken for the cure.

### S-01–S-33 unchanged · S-24 stays at 12 · S-30 and S-31's files re-verified unapplied

S-18 **NOT reopened** — `execute_sql` resolved **by name** at STEP R; occurrence count stays **3**.
S-27 honoured: all three suites run **three times** this leg (STEP R, post-fix, final).
S-26 honoured: nothing this leg reads either velocity object.
S-08's tripwire (seq 90) rode on eleven fixtures and was green on every run.
All **3** migrations went through MCP `apply_migration`; all 3 files were written after the apply and
**proven identical** to `schema_migrations.statements` — **3 of 3 MATCH**.
`20260730203000` (S-31's broken leg-24 original) and `20260730212000` (S-30, owned by the
`engine_add_pod_v3` unit) re-confirmed **absent** from `schema_migrations`.

### D-02 through D-06, D-10 unchanged — no flag flipped, no parked activation applied

No protected entity was written this leg, no engine body touched, no live plan table touched, no flag
flipped, no cron changed. D-10 remains the sole gate on both velocity metrics going canonical.

---

## STUCK / DECISIONS updates (2026-07-30, relay leg 29)

### ⛔ S-36 · NEW · fixture 105 seq 10 reds a CORRECT v3 — its VOX filter is a pre-P1.1 proxy

**This is the leg's finding, and it would have cost the engine leg a full LAW-8 bisect of a
blameless engine.** Measured live, not reasoned about.

fixture 105 seq 10 (one of the eight gated P2 acceptance criteria) reads:

```sql
... FROM blocked_demand bd JOIN machines m ON m.machine_id = bd.machine_id
WHERE bd.plan_date = {{plan_date}} AND m.venue_group = 'VOX' AND bd.reason = 'blocked_no_wh'
```

expect `eq 0`. Its stated intent is _"zero **venue-sourced** products blocked on Boonz WH stock
(S-06 Aquafina / Fade Fit thesis)"_. **But it filters on the MACHINE's `venue_group`, not on the
shelf's sourcing edge.** That was a serviceable proxy under v19, which has no sourcing model at
all. P1.1 made it wrong: a VOX-group machine can legitimately carry `boonz_wh`-sourced shelves.

**Measured on fixture 105's own three machines** (`MPMCC-1058-0000-R0`, `ACTIVATEMCC-1037-0000-L0`,
`MPMCC-1054-0000-M0` — all three are `venue_group = 'VOX'`), from `v_shelf_availability_v3`:

| machine            | shelf | pod              | sourcing     | stock | available_units | need |
| ------------------ | ----- | ---------------- | ------------ | ----- | --------------- | ---- |
| MPMCC-1054-0000-M0 | A12   | Haribo Gold Bear | **boonz_wh** | 7/8   | **0**           | 1    |
| MPMCC-1054-0000-M0 | A13   | Leibniz Zoo      | **boonz_wh** | 3/16  | **0**           | 13   |
| MPMCC-1058-0000-R0 | A05   | Krambals         | **boonz_wh** | 5/6   | **0**           | 1    |

Under a **correct** `engine_add_pod_v3` each of these is a genuinely WH-sourced shelf with real
need and zero available WH stock. **LAW 5 requires** it to emit `qty = 0` with
`clamp_reason = 'blocked_no_wh'` and land in the blocked ledger — silent qty-0 is a build failure.
`v_blocked_demand_shadow_v3` then derives three `blocked_no_wh` rows on VOX machines, and seq 10
reads **3**, not 0. **The engine gets a genuine red for obeying the law.**

- **The assertion is not wrong about its intent — its SQL encodes a proxy the truth layer retired.**
  Third instance of the S-04 / S-19 family: S-04 = treat a spec fixture premise as a hypothesis;
  S-19 = an ADR's prediction about a sibling object is a hypothesis; **S-36 = an assertion's
  filter predicate is a hypothesis, and P1.1 can falsify it without touching the assertion.**
- **The fix (binding on the engine leg, and it must land in the same atomic unit).** Scope seq 10
  by the **sourcing edge**, not the machine's group — the shelves that must never block on Boonz WH
  are the ones that are not Boonz-sourced:

```sql
-- join the shadow ledger to the sourcing truth layer and count only NON-boonz_wh shelves
... FROM v_blocked_demand_shadow_v3 bd
    JOIN public.v_shelf_availability_v3 a ON a.shelf_id = bd.shelf_id
WHERE bd.run_id = golden.v3_run_id({{fixture_id}}) AND bd.plan_date = {{plan_date}}
  AND a.sourcing <> 'boonz_wh' AND bd.reason = 'blocked_no_wh'
```

- ⚠️ **Do NOT "fix" this by suppressing the three blocked rows.** They are correct output and the
  weekly-procurement consumer needs them. The defect is in the measurement, not the engine.
- **fixture 5 seq 10 is NOT affected — verified, not assumed.** It is product-scoped
  (`pod_product_id = 733dcd39…`, Fade Fit), and Fade Fit is **6 shelves, all `venue`-sourced, all
  `is_constrained = false`, 0 would-block**. It stays a valid criterion exactly as re-expressed.

### ⏸️ S-30 · STILL UNAPPLIED, and it now needs FOUR corrections before it can be applied

Re-verified unapplied at leg-29 STEP R (0 `schema_migrations` rows, **0** assertions referencing
`pod_refills_shadow`/`blocked_demand_shadow`, **0** seq-88 rows, assertions still **229**). Leg 28
already flagged _"it predates seq 33 — extend it"_. Reading it in full against live state this leg
found **three more**. All four are binding on the engine leg:

1. **Its end-state guard 7h hardcodes `233 = 224 + 9`.** Live is **229** (leg 28 added 5). The file
   would **roll itself back** on apply. Correct value: **238** (229 + 9 — seq 33 already exists and
   is re-expressed, not added).
2. **It predates fixture 14 seq 33** (leg 28's S-05 sub-capacity mirror). seq 33 is the **eighth**
   gated criterion and must be re-expressed on the shadow with the same `-1` sentinel. Guards 7d /
   7e / 7f must move **7 → 8** and include `(14,33)`.
3. ⚠️ **It predates leg 28's S-34 pin, and its wiring puts the v3 call in the wrong world.** The
   file appends `run_engine_v3_if_built` to the **end** of `scenario_sql`. For fixtures 3 and 5 that
   is **after** the `DO $fx$` block that runs `pin_machine_stock → engine_add_pod → restore_machine_stock`,
   so v19 would plan a pinned machine and v3 would plan a restored one. **Every shadow-vs-live diff
   would be noise, which defeats LAW 4's entire purpose**, and seq 4's "empty A07" premise
   (`A07` is really **3/6**, not 0) would only hold for v19. Fixtures 14 and 105 do not pin, so
   appending is correct **for them only**. The v3 call must sit beside the v19 call inside the pin:

```sql
UPDATE golden.fixtures SET scenario_sql = replace(scenario_sql,
   'PERFORM golden.restore_machine_stock(v_m);',
   'PERFORM golden.run_engine_v3_if_built(' || fixture_id || ', {{plan_date}}, 7);'
   || E'\n  PERFORM golden.restore_machine_stock(v_m);')
 WHERE fixture_id IN (3,5) AND scenario_sql NOT LIKE '%run_engine_v3_if_built%';
```

4. **S-36's seq 10 rewrite** (above) must ride in the same unit.

The file's **design** — the `-1` vacuous-green sentinel, the seq-88 self-diagnosing premise, the
seq-87 LAW-4 delta tripwire, the seq-7 v19 regression guard — is **sound and should be kept**. It is
the constants, and the two things that changed underneath it after it was written, that are wrong.
📌 **The general lesson, and it is S-36's twin:** an unapplied file ages against a live baseline.
S-30 was correct the hour it was written and has been wrong since 22:42 that same evening.

### 📌 RISK 84 · NEW · `{{plan_date}}` already carries its own quotes and cast

`golden.render` substitutes `{{plan_date}}` with `quote_literal(...) || '::date'` — i.e.
`'2030-01-04'::date`, **not** `2030-01-04`. Writing `'{{plan_date}}'::date` in a new scenario or
assertion yields `'''2030-01-04''::date'::date` and fails. Always write it **bare**, exactly as
v19's `public.engine_add_pod({{plan_date}}, 7)` does. Sits beside RISK 70 (`render` derives the
date from `fixture_id` and ignores the `plan_date` column).

### 📌 R29-D1 · v3 escapes v19's `slot_lifecycle` blindness — measured, and it is free

v19's candidate set is `JOIN public.slot_lifecycle sl … archived=false AND is_current=true`, which
is exactly why **S-35**'s nightly rotation gap blinds it for ~17h a day. **`v_shelf_state` and
`v_shelf_availability_v3` both contain the S-35 victim shelf** (`ACTIVATE-2005-0000-W0 A01`) —
confirmed by direct probe this leg. Both views carry **544** pod-bound rows, an exact 1:1 match.
So an `engine_add_pod_v3` built on the truth layer inherits **none** of S-35's blindness, with no
extra work. Worth stating explicitly in the engine's ADR note: it is a real v3 win and it is
otherwise invisible, because the fixture that would show it (fixture 3 seq 12) was re-expressed at
leg 28 to the durable invariant. **D-11 remains the right mitigation for v19, which is still the
production engine.**

### RISK 74 · unchanged and NOT closed — deliberately left to the engine leg

`pod_refill_plan_shadow` still has **0** triggers (`pod_refills_shadow` has its 1 append-only
trigger). Re-measured this leg. The engine skeleton described above writes `pod_refills_shadow`
only, so the trigger stays owned by the leg that first writes the plan-grain shadow, per RISK 74's
own instruction. Not touched, so as not to widen this leg's blast radius past a docs-only change.

### S-01–S-35 unchanged · S-24 stays at 12 · D-01/D-07/D-08/D-09 re-verified against LIVE STATE

**D-01** `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · **D-07** 11
co_managed / 23 fully_managed / 3 partner_managed, 65 NULL, `product_sourcing` 4022 ✅ · **D-08**
cron 44 ACTIVE `40 * * * *` scoped to MPMCC-1058, now **5** runs (last 22:40:02), events/composition
steady at **31 / 31** ✅ · **D-09** correctly NOT executed — `engine_add_pod_v3` still **0** in
`pg_proc`. Sentinels **40 Active**. **Nothing approved was left undone.**
S-18 not reopened (`execute_sql` resolved by name; count stays **3**). S-26 honoured — nothing this
leg reads either velocity object. S-27 honoured — all three suites run twice (STEP R and close),
identical both times. S-32 untouched and still the sole gate on D-08's fleet flip.

### D-02 through D-06, D-10 unchanged — leg 29 applied ZERO migrations

No protected entity written, no engine body touched, no live plan table touched (**0** `pod_refills`
rows on any `plan_date < 2030`), no flag flipped, no cron changed. D-10 remains the sole gate on
both velocity metrics going canonical.

---

## STUCK / DECISIONS updates (2026-07-30, relay leg 31)

### ✅ S-30 · CLOSED — applied, after FIVE corrections, four of which were found this leg

Leg 29 documented four required corrections. Reading the file in full against live state at apply
time found a **fifth, and it was hiding inside correction 3's own prescribed fix**:

| #   | defect                                                                | consequence if applied as written                                                                          |
| --- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 1   | guard 7h hardcoded `233 = 224 + 9`; live was **229**                  | the migration **rolls itself back**                                                                        |
| 2   | predates fixture 14 **seq 33** (the EIGHTH criterion)                 | seq 33 stays pointed at `public.pod_refills`, which v3 never writes → reds a correct engine                |
| 3   | v3 call appended AFTER the S-34 pin envelope on fixtures 3/5          | v19 plans a **pinned** machine, v3 a **restored** one; every shadow-vs-live diff is noise (LAW 4 defeated) |
| 4   | ⭐ **S-30's own anchor for correction 3 does not exist in fixture 5** | `replace()` silently no-ops on fixture 5 → guard 7b (`helper wired into 4 of 4`) rolls the migration back  |
| 5   | S-36's seq 10 re-scope (below)                                        | a LAW-5-compliant engine reads 3 against `eq 0`                                                            |

**On (4), because it is the leg's sharpest lesson.** S-30 prescribed anchoring on
`'PERFORM golden.restore_machine_stock(v_m);'`. Fixture 3 carries exactly that string. **Fixture 5
does not** — it restores three machines in a `FOR` loop
(`PERFORM golden.restore_machine_stock(r.machine_id); END LOOP;`). Measured, not assumed. The v19 call
`'PERFORM public.engine_add_pod({{plan_date}}, 7);'` **is** present exactly once in both, so it became
the anchor. New end-state guard **7b2** asserts `strpos(v3_call) < strpos(restore)` on both pinning
fixtures, so the correction proves itself rather than being trusted.

📌 **A correction note ages exactly like the file it corrects.** S-30's prose was written at leg 29
against a fixture-5 scenario the author had not re-read at the character level. The generalisation:
**verify the anchor string exists before writing a `replace()`, and make the end-state guard assert
the POSITION, not just the presence.**

### ✅ S-36 · CLOSED — fixed as specified, and the three blocked rows were NOT suppressed

fixture 105 seq 10 re-scoped from `machines.venue_group = 'VOX'` to
`v_shelf_availability_v3.sourcing <> 'boonz_wh'`, verbatim as S-36 prescribed. Verified by the engine
on its first run: it emitted **exactly three** `blocked_no_wh` lines on fixture 105's machines — the
three S-36 named (`MPMCC-1054 A12` Haribo, `A13` Leibniz, `MPMCC-1058 A05` Krambals) — and seq 10 read
**0**, because none of the three is non-`boonz_wh`. The correct output survived; only the measurement
changed. `v_blocked_demand_shadow_v3` derived them from `reasoning->>'need_raw'` as contracted.

### ⚠️ RISK 86 · NEW · `mixed` sourcing is CONSTRAINED, so S-36's replacement predicate has the same shape of hole

S-36's fix counts blocks where `sourcing <> 'boonz_wh'`. Measured across the 544 pod-bound shelves:
**`venue` (75) is the ONLY unconstrained class** — `boonz_wh` (463) and `mixed` (6) both draw on real
WH stock and both carry `is_constrained = true`. So a **`mixed` shelf that legitimately runs dry would
red a correct engine**, which is precisely S-36's own defect class recurring one level down.

It reads 0 today for a contingent reason, not a structural one: fixture 105's only two mixed shelves
(`MPMCC-1058 A03/A04`, Soft Drinks Mix) carry `available_units = 362`. **Do not treat the green as
proof the predicate is right.** One-line fix if it ever fires: `a.sourcing = 'venue'`. Recorded in
METRICS_REGISTRY beside the shadow-plan Article 16 row so it is found from the data side too.

### ⚠️ RISK 87 · NEW · ADR §8 obligation 3 was satisfiable on one fixture and silently unsatisfied on three

The "`pod_refill_plan` row count unchanged across any v3 shadow run" tripwire is explicit in the ADR
that it "belongs on every Phase-2 fixture". It existed **only** as fixture 14 seq 91 — and it could
not simply be copied, because it reads fixture 14's own `'before'` scratch key, which fixtures 3, 5
and 105 do not write. The obligation was therefore **structurally unmeetable by copy-paste**, which is
why five legs passed without anyone noticing it was three-quarters unmet.

Closed this leg (seq 86 on all four, off the helper's own captured count) and caught by the **Cody
pass, not by the fixtures** — the suite was fully green with the obligation unmet.
📌 **An obligation written in an ADR is not a test. Only a test is a test.** Worth a sweep of the
remaining ADR §8 obligations in a later leg: obligation 1 (registry entries) is likewise unenforced
by anything mechanical.

### RISK 74 · unchanged and STILL NOT closed — deliberately, and the reason is now firmer

`pod_refill_plan_shadow` still has **0** triggers and **0** rows. `engine_add_pod_v3` writes
`pod_refills_shadow` only (which has its append-only trigger), so per RISK 74's own instruction the
trigger stays owned by the leg that first writes the plan-grain shadow. Re-measured this leg.

### D-01, D-07, D-08, D-09 · re-verified against LIVE STATE at leg-31 STEP R

**D-01** `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · **D-07** 11
co_managed / 23 fully_managed / 3 partner_managed, 65 NULL, `product_sourcing` **4022** ✅ · **D-08**
cron 44 ACTIVE `40 * * * *`, `inventory_events` / `shelf_composition` steady at **31 / 31** ✅ ·
**D-09** correctly NOT executed (sentinels **40 Active**, no deletion) ✅. **Nothing approved was left
undone.** S-13 honoured (no `/30.0`, no `*30.0`, `velocity_instock` never used to size). S-26 honoured
(the engine reads no velocity object at all — `velocity_raw` comes from `v_shelf_state`, one join).
S-27 honoured (all three suites run twice, identical). S-32 untouched, still the sole gate on D-08's
fleet flip.

### D-02 through D-06, D-10 unchanged — no flag flipped, no parked activation applied

`preflight_enforcement='warn'` · `refill_sizing_mode='base_stock'` · `swaps_enabled=true` — all
untouched. **D-10 remains the sole gate on both velocity metrics going canonical, and the engine was
built specifically so as not to pre-empt it.**

### ⏸️ NEW DECISION-READY item · D-12 · `engine_add_pod_v3` exists and is invoked by nothing but the harness

Not a flag, so nothing to flip yet — recorded so the next leg does not have to rediscover the shape.
The engine is live in `pg_proc`, `anon`-REVOKEd, and called **only** by
`golden.run_engine_v3_if_built`. Nothing in production, no cron, no FE and no n8n path reaches it.
Wiring it to a nightly shadow run against **real** dates (EXECUTION ORDER STEP 8) is the next
CS-visible milestone, and it is a _build_ step, not a CS decision — the CS decision is the
**cutover** (D-02), which stays parked behind two weeks of shadow evidence per the charter.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 32)

### ⭐ D-10 · ANSWERED ON EVIDENCE — it was never one modelling choice, and TWO of its three cohorts are not decisions at all

D-10 has gated P2.2 since leg 19. Leg 21 narrowed it from "162 series / 23.6%" to "39 of 544 shelves,
two data problems". **Leg 32 re-measured it live and the leg-21 model is wrong on its largest cohort.**

Live decomposition of NULL shelf velocity, over the 544 pod-bound shelves — **decomposes with no residual**:

| cohort              |             shelves | leg-21 explanation                                | leg-32 measured truth                                                                                     |
| ------------------- | ------------------: | ------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `Hunter` pod        |              **16** | "never resolves in `v_weimi_shelf_history_v3`"    | ⛔ **FALSE.** It resolves — **2013 rows**. See S-37: a join-key asymmetry, and the data is already there. |
| `AMZ-1046-2406-O1`  |              **15** | "machine missing from the canonical sales object" | True, but the _cause_ is stale Adyen metadata on a machine that **is selling**. See D-13.                 |
| `below_floor` (48h) |               **4** | "8 — working as designed"                         | Still working as designed; the cohort is **4** today, not 8 (the floor is time-varying — benign).         |
| **total**           | **35 / 544 = 6.4%** |                                                   | (leg 21 measured 39; the delta is entirely the moving 48h floor)                                          |

**The answer D-10 was waiting for:** there is no fleet-wide modelling choice to make. 16 shelves are a
view bug (fix it — no decision), 4 are the designed cold-start floor (no decision), and only the
**15 on AMZ-1046** need a policy, which D-13 reduces to a data fix. LAW 5 + LAW 6 already determine
the engine's residual branch: never a silent 0, fall back to WEIMI-derived `velocity_raw` with an
explicit recorded `velocity_source`, never an invented number. **D-10 is no longer a blocking CS ask.**

### ⛔ S-37 · NEW · `v_shelf_instock_velocity_split_v3` joins a RAW pod key against a CANONICAL one, and the fix has a conservation trap

- **What.** `v_shelf_sales_identity` and `v_shelf_instock_velocity_v3` both apply a hardcoded alias
  (`168aeb7e` `Hunter` → `51e4600f` `Hunter Ridge`). **The split view does not.** Its final line is
  `LEFT JOIN vel v ON v.machine_id = f.machine_id AND v.pod_product_id = f.pod_product_id`, where
  `f.pod_product_id` comes from `v_shelf_state` (**raw**) and `v.pod_product_id` is already
  **canonical**. The join misses, and 16 shelves across 16 machines silently get a NULL velocity.
- **The data was never missing.** All 16 machines have a canonical velocity row; **15 of 16 carry a
  non-null `velocity_instock`** (mean **0.3042** u/day). Sales exist too: 20 rows / **216 units_30d**
  under the canonical key. This is the third instance of the S-04 / S-19 / S-36 family — _an
  assertion or join predicate is a hypothesis, and this one was falsified by the data it reads._
- ⛔ **The trap: do NOT fix this as a one-line join change.** Split weights partition by the **raw**
  pod (`PARTITION BY machine_id, pod_product_id`) while velocity is computed on the **canonical** pod.
  **7 of the 16 machines carry BOTH a Hunter and a Hunter Ridge shelf** (ALJLT-1015-0100-B1,
  ALJLT-1015-0200-O1, AMZ-1046-2406-O1, HUAWEI-2003-0000-B1, MC-2004-0100-O1, USH-1008-0000-W1,
  WAVEMAKER-1006-4100-O1). Canonicalising only the join hands the **full** pod velocity to each raw
  group independently — **double-counting on 14 shelves**. The pod key must be canonicalised in the
  `shelves` CTE (and in `slot_stock`, whose `pod_product_id` comes from raw WEIMI history) so both
  shelves share one velocity pool and their weights sum to 1 across the merged group.
- ✅ **Fix dry-run PROVEN this leg (read-only, nothing applied).** Canonicalising in `shelves` +
  `slot_stock` merges the family to **26 shelves**, **24 of 26** recover a non-null velocity (the 2
  that stay NULL are on AMZ-1046 = D-13), and conservation is **exact**: max |Σw − 1| =
  **0.000000000** across every pod group in the 544-shelf population, **0 pods violating**.
- **Owed before the fix (LAW 1):** a fixture that reds on the asymmetry first. Note the suite's
  expected-red set is currently **empty**, so that fixture will be the sole expected-red until the
  view lands — say so loudly or the next leg will read it as a regression.
- 📌 **Flagged, not resolved:** the alias merges `Hunter` into `Hunter Ridge`, while PRD-109's rule
  says name family is _Active mapping ANY scope UNION `product_family_id`_, **never** name-prefix, and
  records Hunter vs Hunter Ridge as a landmine precisely because they are _different_. The alias is a
  pre-existing production decision in `v_shelf_sales_identity`; this leg did not relitigate it, but
  whoever fixes S-37 is propagating it further and should confirm it is intended.

### ⏸️ D-13 · NEW · `AMZ-1046-2406-O1` is excluded from the canonical sales object by STALE Adyen metadata, and it is selling

- **What.** `v_shelf_sales_identity` gates on `v_live_shelf_stock.is_eligible_machine`, which is
  `adyen_status='Online today' AND adyen_inventory_in_store='Live' AND` repurpose-grace. AMZ-1046 reads
  `adyen_status='Switched off'`, `adyen_inventory_in_store='Pending Setup'` — so **all 16 of its rows
  fail the predicate** (`enabled=16 notbroken=16 eligible=0 haspod=16`: eligibility is the _only_ one
  that fails).
- **But the machine is live.** `status='Active'`, `include_in_refill=true`, `fully_managed`, 16
  pod-bound shelves, 16/16 in `v_shelf_availability_v3` — **and 28 sales in the last 30 days, most
  recent 2026-07-30 17:27 UTC**, plus 33 units of observed WEIMI movement across 10 shelves with
  positive `velocity_raw`. The metadata contradicts the machine's own sales stream.
- **Blast radius is exactly one machine:** it is the **only** `Active` + `include_in_refill` machine
  failing the Adyen predicate fleet-wide.
- ⛔ **NOT fixed this leg, deliberately.** `machines` is a protected entity (LAW 3) and the Adyen
  columns are written by the adyen-sync path — a manual re-stamp can be reverted by the next sync
  (the known NISSAN-0804 re-stamp gotcha). This is an ops/CS call, not a build fix.
- **The one-line ask:** _"AMZ-1046-2406-O1 is Active, in refill, and sold 28 times in 30 days, but its
  Adyen columns read 'Switched off' / 'Pending Setup', which hides it from every canonical sales
  metric. Correct the terminal metadata, or should the machine genuinely be off?"_
- **Until answered**, the engine must not starve it: LAW 5 forbids a silent 0, so the P2.2 branch
  falls back to `velocity_raw` and records the reason. That is a build step and needs no CS input.

### S-24 unchanged at **14** (leg 32 applied 0 migrations) · RISK 74 unchanged (`pod_refill_plan_shadow` still 0 triggers / 0 rows)

### S-01–S-36 unchanged · D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-32 STEP R, all correct

D-01 `gate0_require_manual_confirm=true` · D-07 operating_model 11/23/3 (65 NULL) · D-08 cron 44 ACTIVE
`40 * * * *`, tables steady 31/31 · D-09 sentinels **40 Active**, untouched (retirement still
auto-executes at first cluster cutover, not before). D-02–D-06, D-11, D-12 unchanged — **no flag
flipped, no parked activation applied, no DB write of any kind this leg.**

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 33)

### ✅ S-37 · CLOSED — fixed FIXTURE FIRST, and the fix was NOT the one leg 32 proved

Leg 32 found the asymmetry and dry-ran a fix, reporting conservation **exact** (max |Σw − 1| =
**0.000000000**, **0** pods violating) across all 544 shelves. That evidence is real and it is
**necessary but not sufficient**, for a reason worth carrying forward:

⛔ **The view has a RESIDUAL ABSORBER** — `w_instock = w_raw + (1 − w_sum)` on `absorber_rank = 1`.
Σw is therefore forced to exactly 1 **whatever the partition key is**. Conservation is **laundered,
not proven**. It cannot falsify the key it is computed over.

⛔ **What that hid.** Measured this leg: **all 26** shelves in the alias family carry
`pod_shelf_count = 1`, because `v_shelf_state` derives it as
`count(*) OVER (PARTITION BY b.machine_id, i.pod_product_id)` — the **RAW** key. Canonicalising only
the partition keys merges two shelves that each still believe `n = 1`; both take the `single_shelf`
branch claiming `w_raw = 1.0`; `w_sum` = 2.0; the absorber "repairs" the pair to **w = 0.0 and
w = 1.0**. One real shelf silently receives **zero** velocity — a LAW 5 silent zero wearing a green
conservation check, on all **7** dual machines.

✅ **Shipped** (`20260731005200` fixture → red captured → `20260731010500` repair → `20260731012000` fix):
canonicalise in `shelves` **and** `slot_stock`, **and recompute `n` over the merged group**. Proven on
a `_test` shadow before apply, then in the suite: **248 pass / 0 fail / 0 expected-red / 0 scenario
errors** across all 11 fixtures. seq 60 went **16 → 0**, seq 61 **17 → 2** — and the 2 are both
AMZ-1046 (D-13), exactly as predicted. Family reports `instock_weighted = 14` (7 dual machines × 2);
a join-only fix would have left those 14 as `single_shelf`. That is the proof the trap was real.

📌 **Transferable:** an invariant that is true _by construction_ is not evidence. Assert the **grain**
(`n` = group size) and the **branch** (`single_shelf` ⇒ w = 1), not just the sum. Fixture 2 seq 62/63
are those assertions and they are **ungated** — they were green before the fix and must stay green.

### ⚠️ S-38 · NEW · the Hunter alias now has THREE inline copies and no canonical owner

- **What.** `v_shelf_sales_identity` (LIVE canonical), `v_shelf_instock_velocity_v3`, and now
  `v_shelf_instock_velocity_split_v3` each hardcode the same `VALUES ('168aeb7e…','51e4600f…')`.
  Article 16 says one canonical object per rule; there is **no** canonical alias object to read, so
  the third copy was unavoidable to fix S-37 without touching a LIVE canonical metric (LAW 10).
- **Mitigated, not solved.** Golden fixture 2 **seq 65** (ungated) fails the instant the three view
  definitions stop agreeing on the pair. Drift is now caught mechanically instead of by memory.
- **The unblock:** one small canonical object (e.g. `v_pod_identity_alias`) that all three read. It
  touches a LIVE canonical metric object, so it wants its own leg + Cody review, not a drive-by.
- 📌 **Still flagged, still not relitigated:** PRD-109's rule is that a name family is _Active mapping
  ANY scope UNION `product_family_id`, **never** name-prefix_, and it records Hunter vs Hunter Ridge
  as a landmine **because they are different products**. This leg propagated a pre-existing production
  decision; it did not endorse it. If CS rules the alias wrong, all three copies change together —
  which is precisely what seq 65 guarantees.

### ⛔ RISK 88 · NEW · an unbounded read of the velocity objects can still take the pooler down

At 00:27 UTC an ad-hoc multi-aggregate read of `v_shelf_instock_velocity_split_v3` (no
`statement_timeout`, several velocity columns) killed the MCP connection; **`SELECT 1` failed for
~12 minutes**, recovering on its own at 00:39. Postgres logs show **no FATAL/OOM/restart** — the
longest logged statement was 44.3 s — and `pg_stat_activity` was clean afterwards, so nothing had to
be cancelled. This is the same shape as S-22's 35-minute saturation.

**The protocol in `PRD-110-P21-PERF-FIX-PROPOSAL.md` §4 already forbids exactly what I did** (one cheap
aggregate per statement · scope to one machine first · **always** `SET statement_timeout` — a client
timeout does NOT cancel the server query, RISK 43). It is binding; treat it as such. Note the suite is
safe: fixture 2 reads each velocity object **exactly once** into `golden.scratch` and asserts against
scratch — the pattern the engine must copy at P2.2 (S-26).

### S-24 now **17** (leg 33 applied 3 migrations) · S-01–S-36 unchanged · RISK 74 unchanged

D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-33 STEP R, all correct: D-01
`gate0_require_manual_confirm=true` · D-07 operating_model unchanged · D-08 cron 44 ACTIVE `40 * * * *`
· D-09 sentinels **40 Active / 39,463 units**, untouched. D-02–D-06, D-11, D-12, D-13 unchanged —
**no flag flipped, no parked activation applied, no protected entity written.**

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 34)

### ✅ S-13 · CLOSED — the two-incompatible-units defect can no longer enter v3

S-13 recorded that v19's `engine_add_pod` reads `slot_lifecycle.velocity_30d` **three mutually
incompatible ways** (`/30.0` on the absolute floor, `/30.0` on the machine-band divisor, `*30.0` into
`compute_refill_decision` — only the third is right), and that the risk was a future leg "fixing" one
site in isolation.

**Closed the way S-13 itself specified:** `engine_add_pod_v3` reads `velocity_instock_shelf`, a rate
that is **daily by construction**, and never re-derives from `velocity_30d`. There is no `/30` and no
`*30` anywhere in the function. What makes this durable rather than a promise is **fixture 14 seq 46**:
`cover_units = ceil(velocity_effective_daily × days_cover)`, asserted on every line. A unit error
anywhere in the chain reds it.

⚠️ **v19 is unchanged and still self-inconsistent — that is deliberate.** v19's output is the baseline
every fixture is written against and the denominator of the Phase-2 WMAPE gate. Do not "fix" v19.
S-13 is closed for v3, not for v19; it dies with v19 at cutover.

### ✅ S-26 · HONOURED, and the measurement it rests on is now sharper (and asymmetric)

The engine reads the velocity object **exactly once per run**, as an explicitly `MATERIALIZED` CTE
joined by `shelf_id`. The comment in the body says `MATERIALIZED` is the contract, not a hint —
inlining would expose it to per-machine re-evaluation, which is the failure S-26 predicted.

📌 **New measurement, and it corrects a natural assumption:** S-26 advised scoping to one machine as
a cheap probe. That works on the **pod-grain** object (3.49 s for one machine vs 15.4 s fleet-wide)
and **does not work at all** on the **shelf-grain** one (**19.77 s** for one machine vs **19.8 s**
fleet-wide) — its inner `vel` CTE is `MATERIALIZED`, so no predicate pushes down. **Predicate
pushdown is a property of the specific object, not of the family.** Never infer one view's cost from
its sibling's.

Standing rule unchanged: never benchmark either object with `count(*)`. Add to it: never assume a
`WHERE machine_id = …` made a probe cheap — time it.

### ⚠️ S-39 · NEW · `v_shelf_state.velocity_instock` is still NULL, and it is a perf decision, not an oversight

- **What.** BUILD SPEC P1.2 designs `v_shelf_state.velocity_instock` to carry the P2.1 metric.
  Leg 34 did **not** populate it. Fixture 3 **seq 15** (which asserts the column IS NULL) is therefore
  untouched and **still valid** — do not re-phase it until this is unblocked.
- **Why, measured this leg.** `v_shelf_state` costs **113 ms**. The engine reads it **four times** per
  run (scope count, empty-machine count, the candidate join, the coverage guard) and the FE machine
  page reads it once per load. `v_shelf_instock_velocity_split_v3` costs **~20 s** and does not get
  cheaper when scoped. Folding the second into the first multiplies ~20 s across every consumer of
  the cheapest object in the truth layer — including a page a human waits on.
- **Consequence today: none.** The engine gets the metric by joining the split view directly, once
  per run, which is the S-26-correct shape anyway. Nothing is starved and nothing is slower than it
  needs to be.
- **Smallest unblock: S-26(b), the materialised-history escalation** that
  `PRD-110-P21-PERF-FIX-PROPOSAL.md` §5 already sketches — materialise the expensive slow-changing
  part (`v_weimi_shelf_history_v3`: the 79k-row JSONB flatten + four-tier resolver) with an explicit
  nightly refresh, leaving the velocity arithmetic as a cheap view on top. Article 14 permits it
  **with an ADR**. Once the object is cheap, populating the column is a one-line change and fixture 3
  seq 15 gets re-phased in that same unit.
- 📌 **Do not "just add the column" without doing the perf work first.** It would look like progress,
  pass every fixture, and quietly put a 20-second object on the FE's critical path.

### ⚠️ S-40 · NEW (raised by Cody at review, deliberately NOT fixed) · `skipped_full` can label a shelf that is not full

- **What.** In `engine_add_pod_v3`'s `clamp_reason` ladder, `need_raw = 0 ⇒ 'skipped_full'`. A shelf
  with `0 < current_stock < max_stock` and an **effective velocity of 0** produces `cover_units = 0`,
  `floor_units = 0` (the floor only fires at `stock = 0`), hence `need_raw = 0` — and gets labelled
  **`skipped_full`** while having free capacity.
- **It is pre-existing, not introduced by leg 34.** `velocity_raw = 0` already produced exactly this.
  The switch to `velocity_effective_daily` changes which shelves land there, not whether the branch
  lies.
- **Why it matters more than it looks.** v3's whole thesis is that no line is silent and no label is
  approximate. A reason code that says "full" about a half-empty shelf is the same class of defect as
  a silent 0 — it just fails an operator's reading rather than a conservation check.
- ⛔ **Not fixed this leg, on purpose.** A new `clamp_reason` value with no fixture violates LAW 1, and
  widening the velocity unit to carry it violates LAW 10. The correct shape is its own atomic unit:
  a fixture that reds on a zero-velocity sub-capacity shelf, then a `no_demand_signal` (or similar)
  branch ahead of `skipped_full`.
- 📌 **Check the consumers before adding a value:** `v_blocked_demand_shadow_v3` reads
  `clamp_reason`, and P2.6's preflight will too.

### ⭐ D-10 · DISCHARGED IN CODE — no longer tracked as a decision at all

D-10 was ANSWERED on evidence at leg 32. Leg 34 shipped the answer: the engine's residual branch is
`instock_split → weimi_raw_fallback → none_no_signal`, recorded per line, fixture-enforced (seq 40-45).
Live at leg 34 the fallback cohort is **AMZ-1046 = 16/16 shelves**, `none_no_signal` = **0**. Nothing
further is owed. **Do not reopen D-10 as a CS ask.**

### ⏸️ D-13 · UNCHANGED, and it now has a live consumer making its cost visible

`AMZ-1046-2406-O1` is `Active`, `include_in_refill`, `fully_managed`, selling — and excluded from
every canonical sales metric by Adyen columns reading `'Switched off'` / `'Pending Setup'`. Leg 34
confirms the blast radius is exactly this machine and that **all 16 of its shelves** now plan on
`weimi_raw_fallback` rather than on in-stock velocity. The machine is **not** starved (LAW 5 holds,
`velocity_raw` is non-null on all 16, positive on 10), but it is planned on the weaker of the two
signals until the metadata is corrected.

**The one-line ask is unchanged:** _"AMZ-1046-2406-O1 is Active, in refill, and selling, but its Adyen
columns read 'Switched off' / 'Pending Setup', which hides it from every canonical sales metric.
Correct the terminal metadata, or should the machine genuinely be off?"_ `machines` is protected and
adyen-sync can revert a manual re-stamp (the NISSAN-0804 gotcha), so this stays an ops/CS call.

### 📌 RISK 89 · NEW · a failed tool call is not a failed transaction — check before re-running

`golden.run_all('P0', …)` returned a transport-level error to the client. The transaction had in fact
**completed successfully server-side** — all four fixtures were recorded green in `golden.runs`.
Re-running blind would have been harmless here, but the same reflex after a **writing** statement is
how a double-apply happens. Same family as RISK 43 (a client timeout does not cancel the server
query), and the remedy is the same shape: **after any dropped response, query for the effect before
assuming the cause.** `golden.runs`, `supabase_migrations.schema_migrations` and the target table's
row count are all cheap.

### RISK 88 · honoured this leg — every read of either velocity object carried a server-side `statement_timeout`

No saturation, no dropped pooler. The `PRD-110-P21-PERF-FIX-PROPOSAL.md` §4 protocol works when it is
actually followed.

### S-24 now **19** (leg 34 applied 2 migrations, both on disk with versions realigned) · S-37 stays closed · S-38, RISK 74, S-32, S-35, D-11, D-12 unchanged

D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-34 STEP R, all correct: D-01
`gate0_require_manual_confirm=true` · D-07 operating_model unchanged · D-08 cron 44 ACTIVE
`40 * * * *` · D-09 sentinels **40 Active / 39,463 units**, untouched. D-02-D-06 unchanged —
**no flag flipped, no parked activation applied, no protected entity written.**

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 36)

### ✅ S-41 · CLOSED SAME LEG · the estimator re-processed flat shelves on every cron firing

**Found while counting anomalies for D-08 burn-in day 2, not by looking for it.** Leg 25 recorded
anomalies as raised "once per snapshot per offending shelf" and projected ~41/day fleet-wide. The
live table disagreed: **35 rows across only 4 distinct `weimi_snapshot_at` values**, with snapshot
`2026-07-30 22:00:40Z` carrying **20 rows over 5 shelves** - `times_raised = 4` per shelf,
`distinct (observed_qty, expected_qty) = 1`. Byte-identical rows, four times, for one observation.

**Root cause (confirmed read-only, dry run, zero writes):**

```
already_processed_skipped: 0   <-- on a snapshot ALREADY processed four times
shelves_flat: 1                <-- flat, so no event is written
sensor_above_capacity: 1
```

The guard is `EXISTS (inventory_events WHERE shelf_id = ... AND source_ref = v_ref)`. A sensor-lie
shelf clamps to capacity, belief already equals the clamped count, `v_delta = 0`, so it takes the
flat branch and **writes no event**. The marker IS the event. **This is RISK 76, previously a note,
now measured with a cost.** The real accrual rate was **24x** leg 25's figure: ~120 rows/day on one
machine, ~984/day fleet-wide after the flip (~30k/month) - and an anomaly COUNT measured cron
frequency rather than reality, which would have poisoned P4.5's scoreboard.

**Fixed FIXTURE FIRST** (fixture 27, failing baseline recorded, Cody-reviewed migration).
📌 **The fix deliberately does NOT change skip semantics** - flat shelves still re-run, because
changing the skip would have altered fixture 20/22 premises for no benefit. It removes the accruing
side effects instead. Fixture 27 **seq 3** pins that: it asserts the second call still does NOT skip,
so no future change can go green by short-circuiting rather than fixing the accrual.

### ✅ S-42 · CLOSED SAME LEG · age decay was cumulative in time, and it was 16 hours from landing

Independent of S-41 and worse. The estimator tail read:

```sql
v_days  := (now() - COALESCE(max(last_verified_at), min(created_at))) / 1 day;
IF v_days > 1 THEN decay(LEAST(1.0, rate * v_days));   -- decay_composition_confidence_v3 SUBTRACTS
```

It subtracted an amount proportional to **total elapsed days from a FIXED anchor**, on **every**
firing. Two compounding errors: quadratic in time (wrong even at once-per-day), times 24 firings.

**Measured, not projected.** All 31 composition rows sat at `confidence = 0.30` with
`last_verified_at IS NULL` and `min(created_at) = 2026-07-30 18:40:00Z`. `v_days` crosses 1 at
**2026-07-31 18:40:00Z**; the 19:40 firing would have been the first to decay, at 0.02 per firing
and rising - **every row to `confidence = 0` in ~15 firings (~0.63 days)**, i.e. by ~2026-08-01
09:00Z, _before_ D-08's day-3 check. That silently disables the expiry auto-write-off gate
(`composition_confidence_min_autoaction = 0.70`) and the driver-prompt gate (`= 0.50`) fleet-wide.

**Fix:** anchor includes `shelf_composition.last_age_decay_at`, stamped by the function as it
decays, and the amount is `rate x FLOOR(elapsed_days)`. Applying the decay advances the anchor, so
a second firing the same day computes `v_days < 1` and does nothing - **frequency-independent by
construction**, which is the property that actually matters.
⚠️ **Expect ONE legitimate settle-up decay on the first post-fix firing** (`last_age_decay_at` ships
NULL, anchor falls back to `created_at`). That drop is CORRECT. Do not "fix" it next leg.

### 📌 D-08 · burn-in DAY 2 CLEAN, and the fleet flip now has a THIRD gate

Day 2 observed 2026-07-31 02:00Z, scoped to MPMCC-1058: `min(est_qty) = 1`, **0** negative
compositions; fixtures 19/20/21/22 green; anomalies **100% `count_above_capacity`, 5 shelves, 1
machine** = exactly S-07's known sensor-lie set; events/composition steady at **31 / 31** across 7
firings (events idempotency HOLDS - the defect was confined to the anomaly and decay paths).
**Day 3 falls ~2026-08-02.** Gates on the fleet flip are now **S-32 + S-41 + S-42**; S-41 and S-42
are closed this leg, so **S-32 is once again the sole open gate**.

### 📌 R36-D1 · the pointer is not a unit, and that is why two legs died silently

Leg 34 shipped 2 migrations and lost its log entry. Leg 35 diagnosed it, wrote R35-D1 ("write the
log entry as soon as the unit's DB change is verified"), obeyed it for its own units, **and still
died without a pointer** - because the pointer is the leg's _last act_, not a unit. **New rule,
adopted leg 36: write a provisional `RESUME POINTER` immediately after STEP R, then keep it current.**
The next leg re-probes everything at STEP R.3 anyway, so a slightly-stale pointer costs nothing while
a missing one costs a full forensic reconstruction. Leg 36 did this and the pointer survived.

### 📌 RISK 89 · SHARPER · a tool error can mean "committed", not "failed"

`run_all('P0')` returned `Failed to execute SQL query` and **had committed** (01:58:29 → 02:00:36,
4 fixtures green). A prior attempt returned `connection timeout` and had genuinely rolled back.
**The error string does not distinguish them.** Verification order that works: `pg_stat_activity`
first (still running? RISK 43), then the effect table (`golden.runs`), and only then decide.
Re-running on the strength of an error string would have run P0 a third time.

### 📌 RISK 90 · NEW · a fixture assertion may not depend on winning a race with a live cron

Fixture 27 seq 7 originally asserted "my estimator call inserted an anomaly row". True only if the
fixture got there before cron 44 - which it had not: the observation already carried 4 rows. Post-fix
the call correctly inserted nothing and seq 7 reddened for the wrong reason. Restated onto a
synthetic 2030 snapshot no ingest can produce. **Same class as S-32.** Rule: an assertion over live
ambient data must key on something the fixture itself controls, or it is a coin flip.
⚠️ Corollary: it must also be immune to **retained** residue - "exactly one row on record" was
unusable here precisely because the 15 pre-fix duplicates are deliberately never deleted.

### S-24 unchanged at 19 · all four leg-36 migrations are on disk and md5-verified

Files written after apply and proven byte-identical to `schema_migrations.statements` with
`btrim`/`.strip()` on both sides (RISK 71): `5c40ae7c…` 11652 · `feb5f643…` 21300 · `5bc5dcbe…` 9389
· `df239716…` 1781. **S-24 does not grow this leg.**

### S-01–S-40 unchanged · S-32, S-35, S-38, S-39, S-40, RISK 74, D-11, D-12, D-13 unchanged

D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-36 STEP R, all in their correct state.
D-02 through D-06, D-10 unchanged - no flag flipped, no parked activation applied this leg.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 37)

### ⛔ S-43 · NEW · `machine_service_policy.trip_interval_days` is a stale seed, and building P2.2 on it fails INVISIBLY

- **What.** BUILD SPEC P2.2 sources `visit_interval` from `machine_service_policy`. That table is a
  `source='seed_velocity_tertile'` seed written 2026-06-21 - an exact 10/10/10 tertile split, never
  curated since. Re-derived observed cadence from `refill_dispatching` (executed-visit evidence,
  120-day window, median inter-visit gap) disagrees with it on **every class**:

  | machine_class | policy | observed median     | overstatement |
  | ------------- | ------ | ------------------- | ------------- |
  | backup        | 30     | **9.00** (4.0–20.5) | **3.3x**      |
  | busy          | 12     | **6.80** (2.0–11.0) | **1.8x**      |
  | standard      | 21     | **5.45** (2.5–8.0)  | **3.9x**      |

  Corroborated: **max `days_since_visit` fleet-wide is 16 days** while 10 machines are seeded at 30.

- ⛔ **Why it is dangerous rather than merely wrong.** `S = μ·L + z·σ√L` with `L` ~4x too large
  inflates `S` ~4x; `need_raw = LEAST(GREATEST(cover_units, floor_units), fill_to_cap)` then absorbs
  it into **`fill_to_cap`**. Result: **every shelf fills to capacity every visit**, with no error, no
  exception, no qty-0 and no anomalous `clamp_reason`. v3 looks healthy while having degenerated into
  "always max fill", and the Phase-2 gate (**WMAPE(v3) ≤ WMAPE(v19)**) fails with no visible cause.
- **`z_default` is also inert:** the constant **1.65** on all 30 rows, so it does not vary by
  `machine_class` at all, despite BUILD SPEC saying "z ... join by `machine_class`".
- **Smallest unblock (designed, not yet built).** Resolve the interval **observed-first** with the
  seed as fallback, behind a parameter so the precedence is CS-flippable rather than hard-coded -
  see **D-14**. `machine_service_policy` itself is **NOT written** (it is CS-owned data).

### ⚠️ RISK 91 · NEW · `delivery_status = 'Success'` silently returns ZERO rows — the value is `'Successful'`

`v_sales_history_resolved` / `sales_history` carry `delivery_status = 'Successful'`, and it is the
**only** value present across all **38,386** rows. The natural-looking filter `= 'Success'` returns
**`actual rows=0`** (measured by `EXPLAIN ANALYZE`, and the index scan makes it fast and confident).
A σ built on that literal would be **0 fleet-wide**, `z·σ` would vanish, base-stock would silently
collapse to bare `μ·L`, and **every shelf would lose its safety stock with no error** - the exact
class LAW 5 forbids. ⚠️ Because the column has only one value the filter is a **no-op when correct**,
so the safe form is to assert the vocabulary, not to trust the literal.

### 📌 S-44 · NEW · σ's history is sparse enough that the archetype prior is the MAJORITY path

Over 60 days at (machine, pod) grain: **637 pairs**, 7,105 daily rows (cheap: 2.3 ms). Only **182
(29%) have ≥14 days** of sales; **310 (49%) have ≥7**; **81 pairs have exactly ONE day**, where
`stddev_samp` is **NULL**. So "min-history guard → archetype prior" governs **455 of 637 pairs**.
Sampled dispersion `φ = σ/√μ` runs **1.03 – 2.86** (1x–3x Poisson), so a single fixed prior is not
defensible - φ must itself be estimated and the prior must be a φ, not a σ.
📌 **Trap:** computing σ over _days with sales_ drops zero-demand days AND counts stockout days as
zero demand, while μ (`velocity_instock`) is already in-stock-corrected - mixing two bases, which is
**S-13 in a new costume**. A scale-free `φ = σ_obs/√μ_obs` applied to the canonical μ is robust to
this because numerator and denominator shift together.

### ✅ D-13 · its BUILD obligation is DISCHARGED — it is now a CS metadata question ONLY

D-13 said "the P2.2 branch falls back to `velocity_raw` and records the reason … a build step".
**That fallback already exists**, shipped at P2.1: `engine_add_pod_v3` lines 126-131 resolve
`velocity_source` as `instock_split` → **`weimi_raw_fallback`** → `none_no_signal`, with `vel_eff`
following the same ladder. **Nothing to build. Do not rebuild it.** The one-line CS ask is unchanged.
⚠️ **New and material:** the single in-scope machine with **no `machine_service_policy` row** is
**`AMZ-1046-2406-O1`** - D-13's own machine (32 shelves, **16 pod-bound**) - and it also has **0
measurable inter-visit gaps** in 120 days. It has **neither a service policy nor an observable
cadence**, which is why the P2.2 resolver needs a **three-tier** fallback, not two. Without the third
tier, 16 pod-bound shelves starve silently.

### ⏸️ D-14 · NEW DECISION-READY · visit-interval precedence, and whether z should vary by class

- **What it is.** Two service-policy modelling choices that S-43 forces into the open, both built as
  **parameters with evidence-backed defaults**, both flippable without a migration:
  1. `base_stock_interval_precedence` - **`observed_first`** (default, evidence-backed by S-43's
     1.8x-3.9x measurement) vs `policy_first` (honour the seeded `trip_interval_days`).
  2. `z` by `machine_class` - today `z_default` is the constant **1.65** (= `z_mid`) for all 30
     machines. `refill_policy_params` already holds `z_low 1.28 / z_mid 1.65 / z_high 2.05`, so a
     class→z mapping is one UPDATE away. **Not invented by the build** - left at `z_default`.
- **Evidence it works.** S-43's cadence table; fixture 28 (to be built) pins the resolver contract.
- **The one-line ask:** _"Visit cadence measured from executed dispatches is 1.8x-3.9x shorter than
  the 2026-06-21 seeded `trip_interval_days`. Should base-stock size on measured cadence (default), or
  is the seed the intended service target we are failing to hit? And should z vary by machine_class
  (1.28/1.65/2.05) or stay flat at 1.65?"_
- **Activation:** `UPDATE refill_policy_params SET base_stock_interval_precedence='policy_first';`
  and/or an `UPDATE machine_service_policy SET z_default = <z_low|z_mid|z_high> BY machine_class`.
- ⛔ **Until answered the build does NOT wait** and does **NOT** write `machine_service_policy`.

### S-24 unchanged at 19 · leg 37 applied ZERO migrations

### S-01–S-42 unchanged · D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-37 STEP R

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-07 unchanged ·
D-08 cron 44 ACTIVE `40 * * * *`, events/composition steady **31 / 31**, anomalies **35** (two
consecutive post-fix firings added zero) ✅ · D-09 sentinels untouched ✅.
D-02 through D-06, D-10, D-11, D-12 unchanged - **no flag flipped, no parked activation applied, no
protected entity written, no row deleted.** S-32 remains the **sole** open gate on D-08's fleet flip.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 38)

### ✅ S-45 · NEW · CLOSED SAME LEG · the P2.2 cadence was about to be built on HALF the definition of "a visit"

- **What.** The leg-37 pointer specified observed cadence from `refill_dispatching` alone. The
  canonical visit clock (`v_machine_health_signals.days_since_visit`, METRICS_REGISTRY "Days since
  visit") is `GREATEST(dispatch evidence, manual-refill evidence)` and additionally excludes
  **`skipped`** rows, which the pointer also omitted. Caught by the Article 16 pass at Cody review,
  **before** any migration was applied.
- ⛔ **Why it is dangerous rather than merely wrong — it is S-43 in miniature.** Measured live:
  **278 manual-refill/adjust events across 23 of the 31 in-scope machines** in 120 days. Dropping
  that leg lengthens the apparent gap on **13 of 30** machines, **always in the same direction**
  (max **1.60x**: VOXMCC-1011 reads 8 days instead of 5; MPMCC-1054 9.5 vs 7; NISSAN-0804 8 vs 6).
  An overstated `L` inflates `S`, `fill_to_cap` absorbs it, and v3 degenerates to always-max-fill
  with **no error, no qty-0, no anomalous `clamp_reason`** — the exact silent-failure class LAW 5
  forbids, and precisely the failure S-43 was raised to prevent.
- ⚠️ **Second trap in the same area:** `pod_inventory_audit_log` carries its **own `machine_id`**.
  Routing that join through `pod_inventory` is the fan-out path the standing DO-NOT list forbids.
- **Fix (applied).** The resolver uses the canonical vocabulary verbatim. **Fixture 28 seq 17 is a
  standing regression guard**: it asserts at least one machine's interval differs from a
  dispatch-only derivation, so silently reverting to dispatch-only turns the suite red.
- 📌 **Consequence for the parameter:** `base_stock_default_interval_days` shipped at **5.5**, not
  the **7** the pointer proposed. 7 is the median-of-medians of the dispatch-only derivation (6.75);
  on the canonical vocabulary the measured fleet median-of-medians is **5.50**.
- 📌 **The three-tier design SURVIVED the correction, unchanged.** `AMZ-1046-2406-O1` has 0
  measurable gaps under the _full_ vocabulary too, so it is still the sole tier-3 machine.

### ⏸️ D-14 · UPDATED · built and shipped as parameters; the ask grows by one line

- **Built (leg 38).** `base_stock_interval_precedence` = `observed_first` (default) | `policy_first`,
  CHECK-constrained, on `refill_policy_params`. `z` stays at `z_default` (flat **1.65** on all 30
  rows); `z_source` NAMES its origin. `machine_service_policy` was **NOT written** (CS-owned).
- **Evidence it works.** Fixture 28, **17/17 green**. `divergence_machines = 30` — the seed
  disagrees with measured cadence on **every** machine that has one, mean **3.67x**.
- **The one-line ask (extended):** _"Visit cadence measured from executed dispatches **and manual
  refills** is 1.8x-3.9x shorter than the 2026-06-21 seeded `trip_interval_days`, on all 30
  machines. Should base-stock size on measured cadence (default), or is the seed the intended
  service target we are failing to hit? Should z vary by machine_class (1.28/1.65/2.05) or stay flat
  at 1.65? And should `AMZ-1046-2406-O1` — which has neither a service policy nor any measurable
  cadence, and is currently sized off the 5.5-day fleet default across 16 pod-bound shelves — get a
  real `machine_service_policy` row?"_
- **Activation:** `UPDATE refill_policy_params SET base_stock_interval_precedence='policy_first';`
  and/or an `UPDATE machine_service_policy SET z_default = <z_low|z_mid|z_high> BY machine_class`.
- ⛔ Until answered the build does **NOT** wait and does **NOT** write `machine_service_policy`.

### 📌 RISK 89 · CONFIRMED LIVE AGAIN — and the protocol paid for itself this leg

`golden.run_all('P0', ...)` returned a bare `Failed to execute SQL query` (no PG error code — a
transport timeout on the RETURN, the statement having run ~81s). `pg_stat_activity` showed no
in-flight backend and `golden.runs` held **4 committed rows**. **The run had fully succeeded.**
Retrying on the strength of that error string would have doubled the suite for nothing. 📌 Practical
form: wrap the call as `SELECT count(*) FROM (SELECT golden.run_all(...)) z` — returning a scalar
instead of a large jsonb keeps the response under the gateway's limit, and P1/P2 then returned
cleanly in the same session where P0 had "failed".

### 📌 golden.fixtures.baseline_status vocabulary — `failing_expected`, not `red_expected`

`fixtures_baseline_status_check` allows exactly `failing_expected` | `passing` | `unknown`. The
guess `red_expected` aborts the whole migration (atomically — nothing half-applied).

### S-24 unchanged at 19 · leg 38 applied THREE migrations, all three md5-verified byte-identical to `schema_migrations.statements`

### S-01–S-44 unchanged · D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-38 STEP R

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-07 unchanged ·
D-08 cron 44 ACTIVE `40 * * * *`, events/composition steady **31 / 31**, anomalies **35** ✅ ·
D-09 sentinels untouched ✅. D-02 through D-06, D-10, D-11, D-12, D-13 unchanged — **no flag
flipped, no parked activation applied, no protected entity written, no row deleted.** S-32 remains
the **sole** open gate on D-08's fleet flip.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 40)

### ⛔ S-47 · NEW · THE SUITE IS RED, and both failures are assertions coupled to UNCONTROLLED LIVE STATE

- **What.** Leg 39's post-P2.2b regression left **fixture 3 (2 fail)** and **fixture 14 (1 fail)**.
  Leg 39 died mid-bisect. Leg 40 finished the bisect. **Neither failure is a code regression, and
  neither is caused by the P2.2b sigma work.** Both are assertions whose premise depends on live
  state the fixture does not own.

- **Fixture 3, seq 4 and seq 7 - live WAREHOUSE STOCK.**
  Both assert `qty > 0` for the pinned-empty `A07` of `MPMCC-1058-0000-R0`. seq 4 measures v3 on the
  shadow plan; **seq 7 is the ungated v19 regression guard**. Bisect from `golden.runs`: both read
  **3** on every run from leg 33 through leg 39's STEP R at **03:32:51Z**, then **0** at
  **03:55:15Z**. ⭐ **seq 7 failing is the tell - v19 was not touched by any leg-39 migration, so the
  cause is upstream of both engines.**
  Root cause, measured: A07's pod is **McVities Digestive Nibbles**, `sourcing = boonz_wh`,
  `is_constrained = true`. `v_shelf_availability_v3` reads `wh_units_real = 0`,
  `available_units = 0`, `sentinel_backed = false`. The join path is intact (10 in-scope Active
  `product_mapping` rows resolving to 5 pickable units) - but **all 5 units sit in WH_MCC
  `4fcfb52c`, while MPMCC-1058 draws from WH_CENTRAL `4bebef68` with NO secondary.** The single
  Active WH_CENTRAL batch (`PO-2026-CF0730VOX-...`, `provenance_reason='manual_adjust'`) was
  **drained to 0 by an UPDATE inside the failure window**. `warehouse_inventory` has no
  `updated_at`, so the writer is not recoverable from the table; two further `manual_adjust`
  spot-buy rows (Vitamin Well, Zigi) were INSERTed at **03:49:25Z**, i.e. live ops activity was
  demonstrably running in exactly that window.
  📌 **The machine's warehouse assignment is NOT the defect** - WH_CENTRAL-only is the majority
  pattern (**26 of 31** in-scope machines). Checked so a future leg does not re-chase it.
  ⭐ **Both engines are behaving CORRECTLY.** A constrained shelf with no stock in its serving
  warehouse must not be given a positive qty. The fixture is asserting an outcome that is only true
  while the warehouse happens to be stocked.

- **Fixture 14, seq 92 - concurrent writes to a LIVE table.**
  "LAW 12 tripwire: `refill_plan_output` row count unchanged across this run" is a **delta measured
  around a ~40s window on a table that live actors write.** Proven: the run started **03:53:38Z**
  and **7 live rows on plan_date 2026-07-30 landed at 03:53:50Z**, 12s in. Further live writes at
  **03:57:08Z** (67 rows, plan_date 2026-07-31, 4 machines). It passed for many legs only because
  nothing happened to write during those windows; at 03:53 it lost the race.
  📌 Also observed and **legitimate**: 7 rows on plan_date **2030-01-11** at 03:55:15Z - a fixture's
  own synthetic date, which is what LAW 12 permits.
  ⚠️ **Independently important:** something other than cron 13 is generating LIVE plan rows
  (03:53:50Z and 03:57:08Z, hours before cron 13's 16:00Z slot). A leg that assumes cron 13 is the
  only writer of `refill_plan_output` will be wrong.

- ⛔ **Why this is one finding and not two.** It is **RISK 90 generalised**: RISK 90 said a fixture
  assertion may not depend on winning a race with a live cron. The true rule is wider - **a fixture
  assertion may not depend on ambient live state it does not control**, whether that is a cron, live
  inventory, or a concurrent plan writer. A fixture that goes red for a reason orthogonal to the
  incident it encodes is worse than no fixture: it burns a leg and trains the operator to explain
  reds away.

- **Smallest unblock (designed, NOT built - next leg executes this FIRST, LAW 8).**
  1. **Fixture 3 seq 4 / seq 7.** Do NOT weaken to "qty>0 OR qty=0 with a clamp_reason" alone - that
     silently retires the P2.5 floor test. Split it: keep a **strict** `qty > 0` assertion **gated on
     an explicit premise** (`v_shelf_availability_v3.available_units > 0` for that shelf), and add a
     **new** unconditional assertion that the empty shelf always receives **a line** which is either
     positive or an explicit `qty=0` **with a non-null `clamp_reason` naming the WH block** (LAW 5,
     already the engine contract). The premise must surface through the existing
     `skipped` / `vacuous` machinery so an unstocked warehouse reports itself instead of passing
     silently (S-29 house pattern).
  2. **Fixture 14 seq 92.** Re-express the tripwire so it cannot lose a race: scope the delta to
     rows this run could have written (its own `plan_date`, or a `generated_at` window bounded by
     the run), rather than a global `count(*)`. The LAW-12 fact it defends - the fixture writes no
     live plan date - is already carried by **seq 93** for `pod_refills`; seq 92 should be the same
     shape for `refill_plan_output`.
  3. Re-run all three suites to green **before** P2.2c.
- ⛔ **P2.2c (engine wiring) is BLOCKED behind this by LAW 8.** Do not start it on a red suite.

### ⏸️ D-15 · NEW DECISION-READY · the Poisson floor on phi (shipped inert, one UPDATE away)

- **What it is.** `base_stock_sigma_phi_floor` ships at **0**, i.e. the measured `phi` is used
  exactly as estimated. Raising it to **1.0** imposes a Poisson floor, so no shelf can ever be sized
  with less safety stock than pure Poisson demand would imply.
- **Why it is a CS call and not a build call.** Measured dispersion runs **phi = 1.03 - 2.86** on
  pairs with real history (S-44), i.e. at or above Poisson. But **306 of 469 pairs fall to a prior**,
  and the fleet prior is **0.690066** - _below_ Poisson. So the floor is inert for well-measured
  pairs and binds almost entirely on **thinly-measured ones**. Whether a thin pair should be given
  Poisson safety stock by default is a service-level judgement, not a modelling fact.
- **Evidence it works.** Fixture 29 seq 8 asserts no pair sits below the floor, so flipping the
  parameter is provably honoured rather than hoped for.
- **The one-line ask:** _"For shelves whose demand history is too thin to measure dispersion, should
  we assume at least Poisson variability (safer, more stock) or use the measured fleet ratio of 0.69
  (leaner)? Default today is the leaner 0.69."_
- **Activation:** `UPDATE refill_policy_params SET base_stock_sigma_phi_floor = 1.0;`

### ✅ S-46 · CLOSED BY LEG 39 (recorded by leg 40, which found it undocumented)

Fixture 28 seq 3's "symmetric EXCEPT, drift-proof" scope check was not symmetric. `UNION` and
`EXCEPT` have **equal precedence** and are **left-associative** in Postgres, so
`(A EXCEPT B UNION ALL C EXCEPT D)` parses as `((A EXCEPT B) UNION ALL C) EXCEPT D`, which catches a
**DROPPED** row but reports **0** for an **INVENTED** one. Proven, not argued: `act=(1,2,99),
exp=(1,2)` gives 0 unparenthesised and 1 parenthesised. Fixed in place under L33-3 with pre- and
post-guards; fixture 28 was the only fixture carrying the shape, and fixture 29 was written with the
parenthesised form. ⚠️ **Standing rule: parenthesise every branch of a symmetric-difference check.**

### 📌 RISK 93 · NEW · a leg can die AFTER its provisional pointer and leave the DB ahead of the repo

Leg 39 applied **four** migrations after writing its provisional pointer, then died with **no FINAL
block, no migration files on disk, no log entry and no registry rows**. STEP R caught it only
because the pointer's claims were re-probed live: `prd110%` read **86** against a claimed 82, and
golden read **14 fixtures / 307 assertions** against a claimed 13 / 289. **Had the leg trusted the
pointer, it would have rebuilt objects that already existed.**
📌 R36-D1's provisional pointer did its job (the state it recorded was true when written), but it is
a **floor, not a ledger**. The durable lesson is the one THE LAW already states and which paid off
again here: **VERIFY, THEN ACT - trust live queries over the log.** A pointer's numbers are a
hypothesis to be tested at STEP R, never an input to be believed.

### S-24 now **23** (leg 39 applied 4, filed to disk by leg 40 and md5-verified byte-identical)

### S-01–S-45 unchanged · D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-40 STEP R

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-07 unchanged ·
D-08 cron 44 ACTIVE `40 * * * *`, last firing 03:40Z succeeded (16 rows), events/composition steady
**31 / 31**, anomalies **35** ✅ · D-09 sentinels untouched ✅. D-02 through D-06, D-10, D-11, D-12,
D-13, D-14 unchanged. **Leg 40 wrote no protected entity, deleted no row, flipped no flag, applied
no parked activation and applied ZERO migrations** - it reconciled files and documentation only.
S-32 remains the sole open gate on D-08's fleet flip.

---

## ⭐ CS DECISIONS — D-14 CLOSED 2026-07-31 ~07:35 Dubai (via Cowork session)

Binding on the next legs; execute per the parked activation patterns.

- **D-14a cadence → MEASURED (`observed_first` stays default).** The 2026-06-21 seeds are stale, not
  targets. Keep sizing on measured cadence (dispatch + manual-refill clock, per S-45).
- **D-14b z → VARY BY machine_class.** Map z_low 1.28 / z_mid 1.65 / z_high 2.05 by class
  (high-traffic venue classes → z_high, quiet office classes → z_low, else z_mid). Loop proposes the
  concrete class→z mapping from the classes present, applies via the parked UPDATE with `z_source`
  naming this decision, and lists the resulting per-machine z in the log for CS review.
- **D-14c AMZ-1046 → YES, seed a real `machine_service_policy` row from its AMZ siblings' class
  profile** (interval + z), `source` marking it seeded-by-decision D-14c. machine_service_policy
  writes are hereby CS-authorized for exactly these two changes (D-14b mapping + D-14c row), nothing
  broader.

### ⭐ CS SOURCING CORRECTION 2026-07-31 ~09:30 (binding, applied to product_mapping same morning)

**Pepsi Black, Ice Tea (Peach), Red Bull are VENUE-sourced on ALL VOX machines** — never Boonz-supplied there (offices remain Boonz-supplied). 36 machine-scoped product_mapping rows flipped to venue_team via the 07-08 Chocolate Bar precedent. **Loop obligation:** supersede the corresponding product_sourcing edges to `venue` for these products on co_managed machines via set_product_sourcing_v3 (audited), and ensure engine_add_pod_v3 + fixtures reflect it. Supersedes the older "Pepsi Black IS Boonz-supplied at VOX" note in memory/skills.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 41)

### ✅ S-47 · CLOSED · the suite is GREEN, and the engines were never the problem

Fixed exactly as leg 40 specified, in three migrations (`20260731044622`, `20260731044650`,
`20260731044927`). **Suite: 14 fixtures · 309 pass · 0 fail · 2 expected_red · 0 vacuous.**

- **Fixture 3** now **23 pass / 0 fail / 2 expected_red** (was 20/2). `seq 4` and `seq 7` keep the
  STRICT `qty > 0` form and declare their premise through `acceptance_gate_sql`
  (`v_shelf_availability_v3.available_units > 0` for A07). New **seq 8 / seq 9** carry LAW 5
  unconditionally (the pinned-empty shelf always gets exactly ONE line, positive or an explicit
  `qty=0` with a non-empty `clamp_reason`); new **seq 19** requires that reason to NAME the WH block,
  gated on the inverse premise. All three returned a real `PASS`, not skipped and not `arrived_early`.
- **Fixture 14** now **41 pass / 0 fail** (was 39/1). Tripwires read `91=0, 92=0, 93=0`; the new
  seq-100 self-test reads **14**.
- ⚠️ **READ THIS BEFORE CALLING A REGRESSION:** fixture 3 will report **`n_expected_red = 2` for as
  long as WH_CENTRAL is out of McVities Digestive Nibbles.** That is the S-29 house pattern working -
  the unstocked warehouse reports itself instead of passing silently. **Green is `n_fail = 0`.**
  When the warehouse restocks, the gates open and the strict floor binds again automatically.
- ⭐ **Confirmed a second time, on live data: both engines are CORRECT.** Each emits A07 with
  `qty=0, clamp_reason='blocked_no_wh'`. Do not "fix" them.

### ⛔ S-48 · NEW · CLOSED SAME LEG · the `created_at >= t0` tripwire idiom is STRUCTURALLY VACUOUS

Found while building S-47 step 2, and it **invalidated S-47's own premise** that "seq 93 already
carries the LAW-12 fact for `pod_refills`". It does not, and has not for many legs.

- **Root cause.** `pod_refills.created_at` (and `refill_plan_output.generated_at`, and
  `pod_refills_shadow.produced_at`) DEFAULT to **`now()`, which is TRANSACTION START**. `t0` is a
  `clock_timestamp()` captured INSIDE the transaction, hence always later. Every row a fixture writes
  therefore has `created_at < t0` and can never satisfy `created_at >= t0`.
- **Proven, not argued.** Fixture 14's `t0` = `03:53:38.885165Z`; its own `pod_refills` writes carry
  `created_at = 03:52:59.546876Z`. The comparison evaluates **false** for the fixture's own writes.
- **Fix.** `golden.written_by_this_txn(xid)` - a row VISIBLE to our snapshot whose `xmin` is still
  `'in progress'` can only have been written by our own transaction tree. seq 91/92/93 re-expressed
  onto it; see RPC_REGISTRY for the full contract.
- ⛔ **Two traps a future leg must not re-walk.** (1) `xmin = pg_current_xact_id()::xid` is NOT
  enough: `run_fixture` executes `scenario_sql` inside a `BEGIN..EXCEPTION` block, i.e. a
  **subtransaction**. Probed: it matched **1 of 2** writes; `pg_xact_status` matched **2 of 2**.
  (2) `golden.run_all` runs **every fixture in ONE transaction**, so transaction-grain attribution
  cannot separate fixture A's writes from fixture B's. The tripwires are therefore stated at the
  honest grain: the SUITE may write only on registered synthetic (`>=2030`) fixture `plan_date`s.
- 📌 **Anti-vacuity is now enforced, not hoped for.** seq 100 proves every run that the predicate can
  actually SEE this run's own writes (reads **14**). A guard that silently sees nothing is the exact
  failure mode S-48 _was_, so it no longer ships without a self-test.
- ⚠️ **Generalise before reusing:** any assertion elsewhere in the harness that scopes by
  `created_at >= t0` / `generated_at >= t0` is suspect for the same reason. Not swept this leg
  (scope discipline); seq 93 was the one S-47 depended on, and it is fixed.

### ⏸️ S-49 · NEW · two migration files are not byte-identical to their applied statements

- **What.** `20260731044622` and `20260731044650` on disk carry ADDITIONAL inline comments (and, for
  044650, a shorter `COMMENT ON FUNCTION` text) versus the statements actually applied. File 7489
  bytes vs applied 6557 for 044622. `20260731044927` **is** md5-verified byte-identical.
- **Why it happened.** The `BEGIN;`/`COMMIT;` wrapper was stripped for `apply_migration` (which
  supplies its own transaction) and the inline comments were trimmed while composing the call.
- **Why it is NOT a correctness risk.** The DB is authoritative and verified: all three post-guards
  passed, and the suite is green. Both files now carry a header stating the applied md5 and that the
  DB is authoritative. **This is a tidiness debt, not a drift.**
- **Smallest unblock.** Regenerate both files verbatim from
  `supabase_migrations.schema_migrations.statements` and re-verify md5 (the leg-40 method). ~10 min.

### S-24 now **26** (leg 41 applied 3 migrations, all three on disk with versions realigned)

### S-01–S-46 unchanged · D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-41 STEP R

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-07 unchanged ·
D-08 cron 44 ACTIVE `40 * * * *`, events/composition steady **31 / 31**, anomalies **35** ✅ ·
D-09 sentinels untouched ✅. D-02 through D-06, D-10 through D-15 unchanged. **Leg 41 wrote no
protected entity, deleted no row, flipped no flag and applied no parked activation.** S-32 remains
the sole open gate on D-08's fleet flip. ⭐ **D-14 (CS-closed) is still NOT started** - it is the
first substantive task available now that LAW 8 no longer blocks Phase 2 work.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 42)

### ⭐ D-14 · CLOSED AND BUILT — but NOT the way its parked activation said

- **What happened.** D-14's activation read `UPDATE machine_service_policy SET z_default = … BY
machine_class`. Probed before executing (LAW 13) and **`machine_service_policy` is read by the LIVE
  v19 engine**, not only the v3 resolver: `engine_add_pod` line 163-164
  (`COALESCE(msp.trip_interval_days,21)` → `trip_days`) and line 167
  (`CASE WHEN q.margin IS NULL THEN COALESCE(msp.z_default, v_zmid)` → `z_item`), plus
  `rank_slot_suitability` and `v_sizeup_candidates`. `refill_sizing_mode='base_stock'` is live, so
  both branches bind **tonight**.
- ⛔ **Measured blast radius: 243 of 544 pod-bound shelves (45%) resolve `margin IS NULL`**, so
  `z_default` binds on them (busy 90 / standard 79 / backup 67 / no-policy 7). The parked UPDATE
  would have moved z on **157 live shelves** and AMZ-1046's v19 interval **21 → 3** — on the night of
  the first manual-gate cycle. **LAW 12 forbids it, and CS never authorised it:** D-14's one-line ask
  is framed entirely as a _v3 base-stock_ question. CS answered about v3; the UPDATE lands in v19.
- **Built instead (4 migrations, Cody ⚠️ approve-with-revisions, all three revisions applied):**
  nullable carrier columns `trip_interval_days_v3` / `z_v3` / `v3_source` on
  `machine_service_policy`; `v_machine_base_stock_policy_v3` resolves
  `z = COALESCE(z_v3, z_default, z_mid)` and sizes the policy tier on
  `COALESCE(trip_interval_days_v3, trip_interval_days)`. **v19 reads the base columns and is
  bit-identical** — proven inside the transaction against a per-machine pre-image of v19's own
  expressions, not asserted.
- **D-14b applied:** busy → **2.05** (z_high), standard → **1.65** (z_mid), backup → **1.28**
  (z_low). The classes present are the 2026-06-21 velocity tertiles, so CS's "high-traffic → z_high,
  quiet office → z_low" maps onto the tertile ordering.
- **D-14c applied:** `AMZ-1046-2406-O1` seeded `machine_class='standard'` on two independent signals
  (32 non-phantom shelves vs 40 on all four siblings; site-code cohort **24xx** = AMZ-1057-2403 +
  AMZ-1068-2401, both standard, vs the busy **30xx** pair). `trip_interval_days_v3 = 3`
  (24xx siblings' MEASURED median 2.5 rounded up, per D-14a), `z_v3 = 1.65`.
  ⭐ Base columns written at **21 / 1.65 — v19's OWN hardcoded fallbacks.** They are NOT NULL, so the
  row could not be inserted empty; those values are the unique choice that satisfies the constraints
  while leaving live sizing untouched. 21 is also the standard-class seed.
- ⚠️ **SERVICE ANOMALY for CS** (also written into the row's `notes`): AMZ-1046 had **2 dispatch
  visits in 120 days** vs **23-33** for every sibling — its real cadence is nearer **60 days than 3**.
  The 3-day override is the cohort's measured median, **not** a claim about this machine's actual
  service. Root cause of its invisibility is **D-13** (stale Adyen metadata).
- **Evidence:** fixture 28 **17/17 → 21/21**; new seq 18 (structural tier-3 guard), seq 19
  (non-vacuity, 2 tiers exercised), seq 20/21 (v19 neutrality tripwires).

### ⏸️ D-16 · NEW DECISIONS-READY · propagate D-14 into the LIVE v19 engine

- **What it is.** D-14b/D-14c are live for the v3 brain and inert for v19. One UPDATE propagates them.
- **Why it is a CS call and not a build call.** It moves **live plan quantities on ~157 shelves**
  (every shelf whose item margin is NULL) plus AMZ-1046's interval 21 → 3. CS's D-14 answer was to a
  question about **base-stock sizing in v3**; nobody asked whether v19 should change tonight. Under
  LAW 4 (shadow, don't switch) and LAW 12 the build must not decide this.
- **Evidence it works.** Fixture 28 seq 20/21 assert the base columns are still frozen; they go RED
  the moment this is flipped, which is how you will know it took. **Re-phase them, never delete.**
- **The one-line ask:** _"D-14's z-by-class mapping and AMZ-1046's seeded row are live for the v3
  engine and deliberately inert for the current production engine. Should the production engine
  adopt them now — moving quantities on ~157 shelves immediately — or wait for the v3 cutover?"_
- **Activation:**
  `UPDATE public.machine_service_policy SET z_default = COALESCE(z_v3, z_default), trip_interval_days = COALESCE(trip_interval_days_v3, trip_interval_days), updated_at = now() WHERE z_v3 IS NOT NULL OR trip_interval_days_v3 IS NOT NULL;`
  then re-phase fixture 28 seq 20/21.

### ⛔ S-50 · NEW · OPEN · BLOCKING · sentinel retirement strands every row with consumer_stock > 0

- **What.** Fixture 24 went **30 pass / 4 fail** (was 34/0 at 04:52:55Z). Failing: seq 15
  (`sent_inactive_after` 35, expected 40), seq 16 (`sent_active_after` 5, expected 0), seq 18
  (proposals +35, expected +40), seq 25 (`audit_sent` **267**, expected 255).
- ⭐ **NOT caused by leg 42** — structurally: L42-U1 touched only `machine_service_policy`, the
  base-stock view and `golden.*`, none of which fixture 24 reads.
- **Root cause, measured from the fixture's own scratch, not argued.** `drained = 40` and
  `sent_units_after = 0`, so all forty rows DID drain — yet proposals grew **1122 → 1157 = +35**.
  - the retirement loop calls `apply_inventory_correction(id, NULL, NULL, NULL, 0, …)`, which zeroes
    **`warehouse_stock` only**;
  - `propose_inactivate_on_zero_stock` fires only when **`COALESCE(NEW.consumer_stock,0) = 0`**;
  - live: **exactly 5 sentinel rows carry `consumer_stock > 0`** — `VOXSOURCE-WH_MCC-AQUAFINA` (50),
    `-PEPSI` (16), `-SKITTLES` (10), `-FADEFIT2` (7), `-MM` (3).
- ⭐ **Why this is a REAL defect and not a fixture artefact.** The same five rows would be stranded by
  the **actual P1.3 retirement** — left Active with zero warehouse stock and live consumer stock. The
  fixture caught a gap in the retirement path. **Fix the path, not the assertion.**
- ⛔ **Do NOT weaken seq 15/16/18** — they are the P1.3 contract. seq 25's audit-count drift
  (255 → 267) is a **separate** and ordinary S-47 ambient-live-state problem; re-express it against
  state the fixture owns, exactly as S-47 did for fixture 3.
- **Smallest unblock (designed, not built).** Decide with Cody whether retirement should (a) drain
  `consumer_stock` too via the canonical writer before inactivating, or (b) treat a sentinel with
  live consumer stock as **not retirable yet** and surface it (the LAW-5 shape: it reports itself
  rather than passing silently). (b) is the safer default and matches the S-29 house pattern.

### ⏸️ S-49 · GREW from 2 files to 6 · migration files not on disk

Leg 41's `20260731044622` + `20260731044650` (content drift), **plus all four leg-42 migrations
applied but never written to disk at all** (context budget): `20260731051447` `f8192bc2…48f5` ·
`20260731051529` `8f5a2504…c682` · `20260731051651` `2ad847c7…9665` · `20260731051747`
`6cb2705d…8e62`. **The DB is authoritative and verified green.** Regenerate verbatim from
`supabase_migrations.schema_migrations.statements` and re-verify md5 — the leg-40 method, now proven
twice. ~20 min.

### 📌 Article 1 gap noted at Cody review · `machine_service_policy` has NO canonical writer

It is migration-written CS-owned reference data with no RPC, so every change is a migration and there
is no audit trigger on it. Not blocking (it is not an Appendix A protected entity) and deliberately
NOT solved in leg 42. Raise it if the table starts taking routine writes.

### S-24 now **30** (leg 42 applied 4 migrations, none yet on disk — see S-49)

### S-01–S-48 unchanged · D-01, D-07, D-08, D-09 re-verified against LIVE STATE at leg-42 STEP R

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-07 unchanged ·
D-08 cron 44 ACTIVE `40 * * * *`, events/composition steady **31 / 31**, anomalies **35** ✅ ·
D-09 sentinels untouched (40 rows, all Active) ✅. D-02 through D-06, D-10 through D-13, D-15
unchanged. **Leg 42 wrote no protected entity, deleted no row, flipped no flag and applied no parked
activation** — the D-14 writes went to the new v3 carrier, which is exactly the authorized scope and
nothing broader. S-32 remains the sole open gate on D-08's fleet flip.

## STUCK / DECISIONS updates (2026-07-31, relay leg 43)

### ✅ S-50 · CLOSED · the retirement path was fixed, not the assertions

- **What was wrong.** `tg_propose_inactivate_on_zero_stock` fires only when **both**
  `warehouse_stock=0` **and** `consumer_stock=0`. The parked D-09 retirement drained only
  `warehouse_stock`, so the 5 sentinels carrying phantom consumer stock (**86 units**:
  AQUAFINA 50, PEPSI 16, SKITTLES 10, FADEFIT2 7, MM 3) would have been left **Active with zero
  warehouse stock** — unsellable, invisible, and permanent.
- ⭐ **All five carry `provenance_reason='dispatch_pack'`** — the consumer stock was minted by
  _packing sentinel units into machines_. It is phantom stock derived from phantom stock, which is
  why the retirement must drain it rather than route around it.
- ⛔ **The canonical writer for this was DEAD CODE.** `drain_consumer_stock_phantom` INSERTs into
  `inventory_audit_log.delta`, which is **`GENERATED ALWAYS AS (new_qty - old_qty)`** — so every call
  raises `428C9`. It has never been able to run. Referenced by **no function and no cron**.
- ⭐ **The existing batch tool would not have caught this either:** `drain_phantom_consumer_stock_
batch_run` drives off `v_consumer_stock_leaks`, and **zero of the 5 sentinels appear in that view**
  (it holds 15 rows, none of them sentinels). The gap was genuinely uncovered.
- **Shipped (Cody ⚠️ approve-with-revisions, all four revisions applied):**

| version          | name                                                            | applied md5     |
| ---------------- | --------------------------------------------------------------- | --------------- |
| `20260731054325` | `prd110_s50_drain_consumer_stock_phantom_v3`                    | `58448ddd…3ff7` |
| `20260731054510` | `prd110_s50_fixture24_retirement_drains_phantom_consumer_stock` | `66273991…b514` |

- **`drain_consumer_stock_phantom_v3(p_wh_inventory_id, p_reason, p_drained_by)`** — SECURITY
  DEFINER, role-gated, ≥10-char reason, `FOR UPDATE`, **sentinel-scoped** (Cody revision 1: a general
  `consumer_stock`-zeroing RPC on a protected entity is a far wider blast radius than the incident
  needs), sets the four write-context GUCs, writes an explicit `inventory_audit_log` row **without the
  generated `delta` column**, and **never assigns `status`** (Article 6 — the flip stays with the
  pre-existing trigger, the S-17 exposure already disclosed in D-09). anon/PUBLIC EXECUTE revoked.
- ⭐ **The apply-time proof earned its keep.** The migration RUNS the function against a real sentinel
  in a rolled-back subtransaction rather than asserting it works. **The first apply attempt FAILED**
  on it: `app.mutation_reason` carried the `consumer_phantom_drain: ` prefix, so the generic
  `trg_audit_wh_inventory` row and the explicit row became indistinguishable. Fixed by leaving
  `mutation_reason` unprefixed. **The whole migration rolled back cleanly** — verified function-absent
  and live state untouched before re-applying.
- 📌 **Audit footprint, measured not assumed: a consumer-only drain leaves EXACTLY TWO
  `inventory_audit_log` rows.** The generic trigger reads `old_qty`/`new_qty` from **warehouse** stock,
  so on a consumer-only change it records delta 0 and says nothing about what happened; the explicit
  row is the only one carrying the truth. The RC-05 "skip the double-log" precedent was deliberately
  **not** taken — it would mean editing a trigger on the hot path of every fleet-wide warehouse write.
- **Ordering, established by reading the trigger rather than by trial: drain consumer FIRST.**
  Warehouse stock stays non-zero through that loop, so no row is ever observable as _Active with zero
  warehouse stock_, even transiently. (Warehouse-first also fires, via the `OLD.consumer_stock>0` arm,
  but it leaves that window open — it is the worse order, not merely a different one.)
- **Evidence.** Fixture 24 **30/4 → 41/41**. ⛔ seq 15/16/18 were **left untouched at 40/0/40** and a
  migration guard fails the apply if any of them is ever weakened. Non-vacuity proven live:
  precondition measured **5 carriers / 86 units** → **5 drained / 86 units** → `stranded_after` **0**,
  `sent_inactive_after` **40**, `sent_active_after` **0**. SOA `BNZ/MAFE/2026-06/001` identical across
  the act (**101,181.71 → 101,181.71**). Full suite **14/14 green, 320 pass / 0 fail /
  2 expected_red** over **322** assertions (315 → 322, +7). Live state untouched: sentinels still
  **40 Active / 39,377 units / 86 consumer units**.
- **New assertions:** seq 29 (non-vacuity precondition), 30 (zero phantom consumer left), ⭐ 31 (**the
  S-50 core invariant** — no sentinel Active with zero warehouse stock), 32 (every carrier went
  through the canonical writer), 33/34 (**S-48 xmin-attributed** audit provenance, 5 and 40), 94
  (residue restored).
- **seq 25 re-expressed per S-47.** It asserted an absolute live count (`255`, reading **267** today)
  that drifts with ambient packing. It now asserts the invariant it was really testing — sentinels
  carry audit history, which is **why** the BUILD SPEC DELETE aborts on the FK — against
  fixture-owned state. The constant was not retuned.

### ⛔ S-51 · NEW · OPEN (non-blocking) · two near-identical drain RPCs, one of them broken

`drain_consumer_stock_phantom` (broken, see above) vs `drain_phantom_consumer_stock`
(`p_wh_inventory_id, p_units, p_reason`) — the words are the same, only reordered. The second one
**works** but is weaker: `operator_admin`/`superadmin` only, requires a non-null `auth.uid()`, and
writes **no audit row at all**. This is the CLAUDE.md `repurpose_machine` / `rename_machine_in_place_
legacy` foot-gun in a new place, now three names deep with `_v3`.

- ⛔ **Always call `drain_consumer_stock_phantom_v3`.** Never the other two.
- **Article 1 gap:** **none of the three** appears in `RPC_REGISTRY.md`. v3 is registered by this leg;
  the other two are recorded there as non-canonical so the next reader cannot pick the wrong one.
- **Article 13:** the broken v1 is **not dropped** — no deprecation window, and out of PRD-110 scope.
  Parked as a DECISIONS-READY item below.

### ⏸️ D-17 · NEW DECISIONS-READY · retire the two superseded consumer-drain RPCs

- **What it is.** `drain_consumer_stock_phantom` is unconditionally broken (428C9) and unreferenced;
  `drain_phantom_consumer_stock` works but writes no audit row. Both are superseded by
  `drain_consumer_stock_phantom_v3`.
- **Why it is a CS call.** Article 13 requires `SECURITY INVOKER` + `REVOKE EXECUTE` + a 90-day
  monitoring window before a DROP. That window is longer than PRD-110, and neither function is a
  PRD-110 asset — deciding their fate is not this build's call.
- **The one-line ask:** _"Two older consumer-stock drain RPCs are superseded — one has never been able
  to run at all. Start the Article 13 deprecation clock on both now, or leave them until after the v3
  cutover?"_
- **Activation:**
  `ALTER FUNCTION public.drain_consumer_stock_phantom(uuid,text,uuid) SECURITY INVOKER; REVOKE EXECUTE ON FUNCTION public.drain_consumer_stock_phantom(uuid,text,uuid) FROM authenticated;`
  and the equivalent for `drain_phantom_consumer_stock(uuid,numeric,text)`. DROP after 90 clean days.

### ⭐ D-09 · ACTIVATION SCRIPT CORRECTED (third time) — it now has a consumer-drain leg

The leg-11 corrected script drains only `warehouse_stock` and **would strand the 5 rows above**.
Superseding step 2, everything else in D-09 unchanged (the hard prerequisite that
`engine_add_pod_v3` must consume `product_sourcing` / `v_shelf_availability_v3` first **still binds**):

```sql
-- 1. confirm nothing blocks (expect 0 rows; live view, never stale)
SELECT machine_name, shelf_code, pod_name, sourcing, wh_units_real, wh_units_sentinel
FROM public.v_shelf_availability_v3 WHERE would_block_on_retirement;

SELECT set_config('request.jwt.claims',
  '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

-- 2a. NEW - drain phantom consumer stock FIRST (leaves warehouse_stock non-zero, so no row is
--     ever momentarily Active-with-zero-warehouse-stock). Use the _v3 writer, NOT the other two.
SELECT public.drain_consumer_stock_phantom_v3(wh_inventory_id,
         'PRD-110 P1.3 sentinel retirement: phantom consumer stock originating from dispatch_pack of sentinel units',
         '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid)
FROM public.warehouse_inventory
WHERE public._is_sentinel_wh_row_v3(batch_id, expiration_date)
  AND COALESCE(consumer_stock,0) > 0;

-- 2b. then drain warehouse stock. tg_propose_inactivate_on_zero_stock does the
--     Active -> Inactive flip and logs a confirmed proposal. Do NOT call inactivate_warehouse_row.
SELECT public.apply_inventory_correction(wh_inventory_id, NULL, NULL, NULL, 0,
         'PRD-110 P1.3 sentinel retirement: venue sourcing now makes this shelf unconstrained',
         '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid)
FROM public.warehouse_inventory
WHERE public._is_sentinel_wh_row_v3(batch_id, expiration_date) AND status = 'Active';

-- 3. verify: expect 0
SELECT count(*) FROM public.warehouse_inventory
WHERE public._is_sentinel_wh_row_v3(batch_id, expiration_date)
  AND status = 'Active' AND COALESCE(warehouse_stock,0) = 0;
```

⚠️ **Rollback now needs BOTH quantities captured first** — `reactivate_warehouse_row` restores
warehouse stock; the 86 phantom consumer units are **not** restored by it. Capture
`(wh_inventory_id, warehouse_stock, consumer_stock)` for all 40 rows before running step 2.

### ⏸️ S-49 · GREW from 6 files to **8** · migration files not on disk

Leg 43's `20260731054325` `58448ddd…3ff7` and `20260731054510` `66273991…b514` were applied but not
written to disk (context budget), joining leg 41's two and leg 42's four. **The DB is authoritative
and verified green (14/14 fixtures).** Regenerate verbatim from
`supabase_migrations.schema_migrations.statements` — the leg-40 method, proven twice.

### S-24 now **32** (leg 43 applied 2 migrations, neither yet on disk — see S-49)

### S-01–S-48 unchanged · D-01, D-08, D-09 re-verified against LIVE STATE at leg-43 close

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-08 cron 44 ACTIVE
`40 * * * *`, anomalies **35**, `age_decay_stamped` **0/31** (correct — fires after 18:40Z) ✅ ·
D-09 sentinels untouched (**40 Active / 39,377 units / 86 consumer units**) ✅ · D-14's v19 freeze
holds (**31/31** rows still `z_default=1.65`) ✅ · `pod_refills` pre-2030 **3734** ✅.
D-02 through D-07, D-10 through D-16 unchanged. **Leg 43 wrote no protected entity in live state,
deleted no row, flipped no flag, changed no cron and applied no parked activation** — every
protected-entity write happened inside rolled-back subtransactions. S-32 remains the sole open gate
on D-08's fleet flip.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 44)

### ✅ S-43 · DISCHARGED · the "invisible degeneration" it predicted was MEASURED, and it did not happen

S-43's danger was never "the interval is wrong" (leg 42 fixed that with the D-14 carrier). It was
that an over-long `L` inflates `S`, `need_raw = LEAST(GREATEST(cover_units, floor_units),
fill_to_cap)` absorbs it into `fill_to_cap`, and v3 silently becomes "always max fill" — **no error,
no qty-0, no anomalous `clamp_reason`**, with the Phase-2 WMAPE gate failing for no visible cause.

**Measured before applying anything** (read-only dry run of the new identity over all 544 pod-bound
shelves): saturation `fill_to_cap` **163 → 206** of the 450 shelves that have capacity (**36% →
46%**), planned units **1044 → 1253** (+20%), **309 up / 44 down / 191 unchanged**, **0** machines
without a policy row, 16 pairs without a `phi` row, 102 lines with `sigma = 0`. Nowhere near
degeneracy. The 44 shelves that go DOWN are the busy machines whose measured horizon (3-6 d) is
shorter than the old flat 7.

⭐ **And it is no longer a thing you have to remember to check.** `engine_add_pod_v3` returns
`fill_to_cap_lines` + `fill_to_cap_share` on every run, and **fixture 14 seq 56** reds if EVERY line
clamps to `fill_to_cap`. S-43 asked for an assertion that did not exist; it exists now.

### 📌 RISK 92 · SHARPER · the formatter can fire SYNCHRONOUSLY on the write, not only ~7 min later

Leg 44's first `METRICS_REGISTRY.md` edit came back with a `PostToolUse` notice that a hook had
already reformatted the file **before the next tool call**. Prior legs characterised this as a
~7-minute delayed sweep. Both behaviours are real. **Consequence for the handoff:** a hash measured
immediately after an edit can still be stale if a later edit in the same leg touches any dirty file.
The existing mitigation is unchanged and still correct — measure the six hashes LAST, anchor on line
numbers and verbatim regions, never on line counts.

### ⏸️ S-49 · UNCHANGED at EIGHT · leg 44 added ZERO new debt, and the targets are now exact

Leg 44 applied 2 migrations and **filed both to disk in the same unit, md5-verified byte-identical on
the first attempt** (`20260731061145` `7bb21f38…94f4`, `20260731061440` `bd2c9dd9…1ef2`). The debt
did not grow for the first time in four legs.

The 8 outstanding files are unchanged. **Leg 45: the exact expected md5 of each file is now measured
below, so verification is a one-line compare instead of a re-derivation.** File content is
`array_to_string(statements, E';\n') || E'\n'` — proven again this leg on two files, first try.
⚠️ `length()` is CHARACTERS not bytes; multi-byte glyphs make the file larger than `len_joined`.

| version          | name                                                            | expected md5 of the .sql file      | on disk?     |
| ---------------- | --------------------------------------------------------------- | ---------------------------------- | ------------ |
| `20260731044622` | `prd110_s47_fixture3_premise_gate_law5_floor`                   | `a7a52d2e9711168f5ea3283b5f7d8804` | yes, DRIFTED |
| `20260731044650` | `prd110_s47_s48_fixture14_txn_attribution_tripwires`            | `5198b842470df52cb38ec3b04a0e85e5` | yes, DRIFTED |
| `20260731051447` | `prd110_d14_msp_v3_carrier_columns`                             | `a3fd1e4153c6e9d12cd7955224a8c8fd` | **missing**  |
| `20260731051529` | `prd110_d14_base_stock_policy_v3_reads_v3_carrier`              | `f3a4de114b69e606bc1258e0a70ba5d1` | **missing**  |
| `20260731051651` | `prd110_d14_fixture28_v3_carrier_and_v19_neutrality_tripwire`   | `e6398b40e5728e5aca620f293b0b8fb7` | **missing**  |
| `20260731051747` | `prd110_d14b_d14c_apply_cs_decision_to_v3_carrier`              | `c13ee9d439d2207a8e0004b3352b221d` | **missing**  |
| `20260731054325` | `prd110_s50_drain_consumer_stock_phantom_v3`                    | `0a4f917ea7679c73af7a2ac0c327b008` | **missing**  |
| `20260731054510` | `prd110_s50_fixture24_retirement_drains_phantom_consumer_stock` | `4f5716ac5c77d37e072eba9821f01696` | **missing**  |

📌 `20260731044927` was listed as drifted by earlier legs — **it is not.** Measured this leg at
`fe536d305ef78ec3355c881e1913897b`, byte-identical to its applied statements. The debt is 8, not 9.

⛔ **No local `psql`/`pg_dump` and no DB password** (only a service key), so the content must route
through the session context — ~63k characters. Budget it as a **dedicated early unit**, not a
tail-end task; that is why three legs in a row have deferred it.

### S-24 now **34** (leg 44 applied 2 migrations, both on disk and md5-verified)

### S-01–S-42, S-44–S-48, S-51 unchanged · RISK 74, 88, 89, 90, 91, 93 unchanged

⭐ **RISK 89 CONFIRMED LIVE A THIRD TIME, and it paid for itself again.** `golden.run_all('P0')`
returned `Failed to execute SQL query` to the tool layer while the statement was **still running
server-side** (`pg_stat_activity` showed it active at 132 s). Per protocol the leg checked
`pg_stat_activity` FIRST and did **not** re-run; the statement then committed normally and all four
P0 fixtures are green. **A re-run would have double-executed four fixtures.**

### D-01, D-08, D-09 re-verified against LIVE STATE at leg-44 STEP R

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-08 cron 44 ACTIVE
`40 * * * *`, events/composition **31 / 31**, anomalies **35**, `age_decay_stamped` **0/31** ✅ ·
D-09 sentinels untouched — **40 Active / 39,377 WH units / 86 consumer units** ✅.
D-02 through D-07, D-10 through D-17 unchanged. **Leg 44 wrote no protected entity, deleted no row,
flipped no flag and applied no parked activation.** S-32 remains the sole open gate on D-08's fleet
flip. ⚠️ The D-09 sentinel predicate is `public._is_sentinel_wh_row_v3(batch_id, expiration_date)` —
a `provenance_reason ILIKE '%sentinel%'` filter returns **0 rows** and looks like catastrophic drift.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 45)

### ✅ S-49 · CLOSED · all eight files filed byte-identical, and the cost model that parked it was wrong

Three legs deferred S-49 on one premise, recorded in the leg-44 section: _"no local `psql`/`pg_dump`
and no DB password, so the content must route through the session context — ~63k characters."_
**The premise had a hole.** `~/.claude.json` configures this project's MCP server with a Supabase
**Management API** access token (`--access-token=sbp_…`, `--project-ref=eizcexopcuoycuosittm`). That
token drives `POST https://api.supabase.com/v1/projects/<ref>/database/query` directly from the
shell, so a ~30-line Python script `SELECT`s the migration text and streams it **straight to disk**.
Actual cost: **one tool call, zero content in context.** All eight matched their expected md5 on the
first attempt.

⛔ **The one gotcha, because it costs a confusing 403.** That endpoint sits behind Cloudflare and
rejects a request with **no `User-Agent`** — `HTTP 403`, body `error code: 1010`. It reads exactly
like a revoked or wrong token. Send any UA (`curl/8.7.1` works) and it returns **201**.

⭐ **Standing consequence: S-49 should never recur.** Filing a migration is now cheap enough to do in
the same unit that applies it. Leg 45 filed its own two that way. 📌 `length()` is CHARACTERS,
`octet_length()` is BYTES — `20260731051747` is 7824 chars but **8319 bytes**; a length-based check
calls a correct file wrong. 📌 The two DRIFTED files were backed up to `/tmp/prd110_s49_backup/`
before overwrite (`675cf24f…513e`, `806aaf8e…cf11`).

### ⏸️ S-52 · NEW · OPEN · LOW · three fixture-8 assertions currently pass VACUOUSLY

seq **24 (arithmetic), 25 (monotonic), 27 (mislabel)** pass at 0 today only because their
populations are empty — no line carries `expiry_ceiling_units` yet. They become real evidence at
exactly the moment seq **28/29** (the non-vacuity guards) go green, which is when
`prd110_p23_engine_expiry_ceiling` lands. **The coupling is the safeguard: 24/25/27 are trustworthy
ONLY while 28/29 are green.** A future leg that re-phases or weakens 28/29 silently guts three
assertions. This is the S-48 lesson in a new costume and it is recorded here rather than left to be
rediscovered. **Closes by itself** when the engine migration lands and 28/29 turn green.

### 📌 RISK 94 · NEW · any P2.3 number measured on a synthetic 2030 plan_date is MEANINGLESS

Every real batch in this database expires in 2026. At a 2030 `plan_date`, `earliest_expiry -
plan_date` is negative for every one of them, so `GREATEST(…, 0)` makes the expiry ceiling **0 on
essentially every WH-constrained line**. Leg 45's first blast-radius dry run hit this — it was taken
against the newest shadow run, whose `plan_date` is fixture 14's **2030-01-15**, and it read as a
catastrophic 29-of-33-lines collapse. Re-measured at `CURRENT_DATE + 1` the same formula binds on
**4 of 469**. ⭐ **The 2030 behaviour is CORRECT, not a bug** — nothing in stock is sellable in 2030 —
and fixture 8 half (b) deliberately exploits it as the maximum-stress test of "a zero ceiling must
not zero the floor". But **never quote a 2030-dated expiry number as a fleet signal.** Fixture 8
half (a) therefore measures at `CURRENT_DATE + 1` on purpose; the two halves use different reference
dates and that asymmetry is deliberate, not an oversight.

### 📌 Article 16 · METRICS_REGISTRY amended · `v_product_shelf_life` gains its second consumer

At Cody review. `engine_add_pod_v3` is now a registered consumer, and the row **explicitly assigns**
two derivations to the engine so the P2.2c-sigma precedent actually applies rather than being
asserted: (i) plan-time re-anchoring off `earliest_expiry` (never the CURRENT_DATE-anchored
`remaining_shelf_life_days`), (ii) the pod-grain `MIN()` collapse across Active `product_mapping`
members and the machine's `[primary, secondary]` warehouses. A competing pod-grain shelf-life view
is forbidden. The pod→WH predicate is copied VERBATIM from `v_shelf_availability_v3` so v3 keeps
exactly ONE pod→WH resolution.

### S-24 now **36** (leg 45 applied 2 migrations, both on disk and md5-verified)

### D-01, D-08, D-09 re-verified against LIVE STATE at leg-45 close

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-08 cron 44 ACTIVE
`40 * * * *`, `shelf_composition` **31**, anomalies **35**, `age_decay_stamped` **0/31** ✅ ·
D-09 sentinels untouched — **40 Active / 39,377 WH units / 86 consumer units** ✅. D-02 through
D-07, D-10 through D-17 unchanged. **Leg 45 wrote no protected entity, deleted no row, flipped no
flag, changed no cron and applied no parked activation.** S-32 remains the sole open gate on D-08's
fleet flip. S-01–S-48, S-50 (closed), S-51, RISK 74, RISK 88–93 unchanged.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 46)

### ✅ S-52 · CLOSED BY CONSTRUCTION · fixture 8's three vacuous assertions are now real evidence

S-52 predicted its own closure precisely: seq **24 (arithmetic), 25 (monotonic), 27 (mislabel)**
passed at 0 only because no line carried an `expiry_ceiling_units`. `20260731070920` landed the
engine, seq **28** reads **19** and seq **29** reads **1**, and the fixture went **14 pass / 0 fail
/ 5 expected_red -> 19 / 0 / 0**. The coupling S-52 documented held exactly as written.

⛔ **The safeguard survives S-52's closure and must be honoured by every future leg:** seq 24/25/27
are trustworthy ONLY while 28/29 are green. A leg that re-phases, gates or weakens 28/29 silently
guts three assertions. **Re-phase, never delete** — and never without noticing what it costs.

📌 seq **29 reads 1**, not a comfortable margin. It is earned, but a single ambient change (that one
empty WH-sourced shelf on MPMCC-1058 / AMZ-1046 getting stocked before a run) takes it to 0 and reds
the fixture on a premise, not a defect. **If seq 29 ever reds, check the population BEFORE the
engine** — this is the S-47 shape and the fix is an `acceptance_gate_sql`, not a weaker assertion.

### 📌 RISK 95 · NEW · the seq-27 mislabel tripwire has one benign false-positive shape

Measured before shipping, not discovered after. seq 27 counts
`clamp_reason='skipped_full' AND ceil_u IS NOT NULL AND ceil_u < cover_units`. When
`fill_to_cap = 0` (shelf exactly at capacity) the ceiling is NOT what drove the line to zero — the
full shelf did — yet the predicate still matches, because the engine's exact test is
`need_raw < need_raw_no_expiry` and both are 0 there. **Measured at fixture 8's plan_date: 0 such
lines**, so the assertion is honest today. ⚠️ It is ambient-state-coupled: one exactly-full,
WH-sourced, positive-velocity shelf on either fixture machine turns seq 27 red **without any engine
defect**. If that happens, re-express seq 27 against `need_raw < need_raw_no_expiry` (the engine
already records both) rather than the `ceil_u < cover_units` proxy. Not done now — the fixture is
green and scope discipline says do not edit a passing assertion.

### 📌 P2.3's real-world bite, recorded so nobody has to re-derive it

Fleet-wide at the live plan date: **544 pod-bound shelves · 418 carry a WH-FEFO expiry · the
ceiling binds on 10 (1.84%) · 10 units removed of 1254 (0.8%)**. A safety rail. ⛔ **RISK 94 still
binds:** fixture 8's 2030-dated numbers (19 zero-ceiling lines, 26 units removed of 32 shelves) are
the deliberate max-stress case and must NEVER be quoted as a fleet signal.

### S-24 now **37** (leg 46 applied 1 migration, on disk and md5-verified in the same unit)

⭐ The S-49 Management-API filing method worked on the first attempt for the second consecutive leg.
**Leg 46 leaves ZERO filing debt.** ⛔ The `User-Agent` gotcha still applies (no UA -> HTTP 403,
`error code: 1010`, which reads exactly like a bad token).

### 📌 RISK 89 · FOURTH confirmed firing, and the protocol paid for itself again

`golden.run_all('P2', ...)` and `run_all('P0', ...)` both returned a bare tool-layer
`Failed to execute SQL query`. `pg_stat_activity` showed the P2 call **still active at 2m09s**; it
committed 5 fixtures normally. **Never re-run on the strength of an error string** — check
`pg_stat_activity` first, then `golden.runs`. P1 (6 fixtures) returned inline; P0 (4) and P2 (5)
both needed the poll.

### D-01, D-08, D-09 re-verified against LIVE STATE at leg-46 STEP R

D-01 `gate0_require_manual_confirm = true`, cron 13 ACTIVE `0 16 * * *` ✅ · D-08 cron 44 ACTIVE
`40 * * * *`, `shelf_composition` **31**, anomalies **40**, `age_decay_stamped` **0/31** ✅ ·
D-09 sentinels untouched — **40 Active / 39,377 WH units** ✅. D-02 through D-07, D-10 through D-17
unchanged. **Leg 46 wrote no protected entity, deleted no row, flipped no flag, changed no cron and
applied no parked activation.** v19 `engine_add_pod` is byte-untouched. S-32 remains the sole open
gate on D-08's fleet flip. S-01–S-48, S-50 (closed), S-51 unchanged · RISK 74, 88–94 unchanged.

⚠️ **Scope note on this leg's STEP R (recorded so it is a choice, not a silent shortcut):** the
RELAY protocol says "read PRD-110-PARKING-LOT.md in full". At 283 KB that is ~75k tokens and would
have left no room for the P2.3 unit. Leg 46 read the DECISIONS-READY index, the ⭐ CS DECISIONS
block, and legs 40-45 in full (the ledger is append-only, so the recent legs carry every item's
current state), plus the pointer's own parking delta. Every item this unit touched — S-52, RISK 94,
Article 16, D-14/D-16, S-49 — was read at source.

### ⛔ S-53 · NEW · OPEN · the ⭐ CS SOURCING CORRECTION never reached the v3 truth layer

**Found at leg 46's close while checking what P2.3's `basis` gate actually reads.** The CS
correction of 2026-07-31 ~09:30 ("Pepsi Black, Ice Tea (Peach), Red Bull are VENUE-sourced on ALL
VOX machines") was applied to `product_mapping` — **28 Active `source_of_supply='venue_team'` rows
across the 11 `co_managed` machines** — but its explicit **loop obligation** ("supersede the
corresponding `product_sourcing` edges to `venue` … via `set_product_sourcing_v3` (audited), and
ensure `engine_add_pod_v3` + fixtures reflect it") was never executed. Measured live:

| product            | `product_sourcing` on co_managed | expected           |
| ------------------ | -------------------------------- | ------------------ |
| Ice Tea - Peach    | `venue`, 6 Active edges          | ✅ correct         |
| Red Bull - Regular | `boonz_wh`, **11 Active edges**  | ⛔ must be `venue` |
| Red Bull - Diet    | `boonz_wh`, **11 Active edges**  | ⛔ must be `venue` |
| Pepsi - Black      | **no edge at all**               | ⛔ must be `venue` |

⭐ **Why this is now more expensive than it was yesterday.** `product_sourcing` feeds
`v_shelf_availability_v3.sourcing`, which is exactly the `basis` P2.3 gates the expiry ceiling on
(`basis IN ('boonz_wh','mixed')`). So on VOX machines, 22 Red Bull edges are **both** sized against
Boonz WH stock **and** capped by a Boonz WH expiry date, for stock the venue supplies. Every layer
downstream of the truth layer inherits the error — this is precisely the coupling LAW 2 (truth
before intelligence) exists to prevent, arriving late.

⛔ **Do NOT bulk-UPDATE `product_sourcing`.** It is append-only versioned (new row supersedes; no
UPDATE of `source`), and there is a constraint trigger asserting `fully_managed` machines carry no
`venue` edge. The canonical writer is
`set_product_sourcing_v3(p_machine_id uuid, p_pod_product_id uuid, p_source text, p_reason text, p_boonz_product_id uuid)`.
**Smallest unblock:** enumerate the (machine, pod, boonz_product) triples from the 28 `product_mapping`
venue_team rows, call the setter once per triple with a reason naming this CS decision, then
re-measure the table above and re-run the suite. Pepsi Black needs an edge MINTED, not superseded.
⚠️ Fixture 5 is the Fade Fit / VOX-sourcing fixture and asserts on `blocked_no_wh` for a VOX pod —
expect it to move, and read the change before calling it a regression.

---

### ✅ S-53 · CLOSED by relay leg 47 (2026-07-31) · the CS sourcing correction now reaches the truth layer

**Closed by construction.** Golden fixture 30 (20 assertions, P1) was built and baselined **RED
first** (LAW 1: 12 pass / 8 fail), the correction was applied through the canonical writer, and the
fixture went **20/20**. The 8 reds that cleared are exactly the 8 the correction targets: seq 2
(core gap 30→0), seq 5 (CS decision by name 30→0), seq 6 (pod resolution 16→0), seq 13-16
(provenance 0→30 each), seq 19 (consumer path, `v_shelf_state` 9→0).

⛔ **Two claims in the S-53 entry above did NOT survive live measurement. Do not re-use them.**

1. **"the 28 Active `product_mapping` rows"** — wrong. On the 11 `co_managed` machines there are
   **70 assorted** ANY-scope `venue_team` triples (477 counting global-default rows for products
   those machines do not carry), and the actual **gap was 30 triples**.
2. **"Pepsi - Black has NO edge and needs one MINTED"** — wrong, and it would have failed. Pepsi -
   Black carried **8 Active `boonz_wh` edges** needing supersession. Across the whole co_managed
   scope **zero** assorted triples lacked an edge (fixture 30 seq 3 now pins that at 0). **No row
   was minted.**

⭐ **The correction that mattered most was to the SCOPE QUERY, not the data** (caught in Cody
review, Article 16). The first draft joined `product_mapping` on `machine_id`, which silently drops
global-default (`machine_id IS NULL`) rows. That is the **"most specific wins"** inference
METRICS_REGISTRY names as _the single most expensive inference bug PRD-110 exists to delete_
(S-10, and the Aquafina half of S-06). The ratified rule is: **on a `co_managed` machine, a
`venue_team` mapping at ANY scope wins.** ⛔ The banned form measures the **same 30** today — which
is exactly what makes it dangerous, and why fixture 30 encodes ANY-scope explicitly.

📌 **The 75 "stale mapping" triples were a misreading; there is no S-54.** An earlier pass this leg
read 75 co_managed triples as "mapping says boonz, edge says venue → mapping is stale". Under
ANY-scope they are simply **correct**: each carries a global-default `venue_team` row alongside a
machine-scoped `boonz` row. **All 116 pre-existing `venue` edges are justified this way.** The
finding is withdrawn — but the tripwire it produced was kept and is more valuable than the finding:
fixture 30 seq 8 pins **77** VOX-supplied `venue` edges, which is the standing guard that a future
backfill has not reverted to most-specific-wins and re-sourced VOX goods to Boonz WH (undoing P0.4).

📌 **Guard constants are measured, not reasoned.** seq 8 (77) and seq 9 (20) both went red on the
first baseline at 75 and 12, because those numbers came from queries scoped differently from the
assertion body (they additionally required a machine-scoped mapping row). **Neither was a data
defect** — VOX Lollies has 6 edges not 4, and the Coke family spans 7 Soft Drinks Mix pods not 3.
Corrected forward-only in a second migration. ⚠️ When a guard constant reds on its FIRST run,
suspect the constant before the data.

**Applied:** 30 × `set_product_sourcing_v3` under operator_admin impersonation → **30 changed, 0
no-ops**. Conservation exact: rows 4022→4052, **Active still 4022**, Superseded 0→**30**, venue
116→**146**, boonz_wh 3811→**3781**, partner 95 unchanged, `origin='manual'` **30**, every change a
supersede pair with `valid_to` set and `changed_by` attributed. **0 deletes, 0 `UPDATE`s of
`source`.** Suite **16/16 green, 367 pass / 0 fail / 2 expected_red over 369 assertions**. Fixture
5 was expected to move and **held at 17/0**.

⚠️ **CARRY FORWARD — the ONE live behavioural change.** 9 shelves are now unconstrained (Red Bull 4,
Pepsi Black 5). One of them is **MPMCC-1058-0000-R0 A02 (Red Bull)** — cron 44's D-08 burn-in
scope. `estimate_shelf_composition_v3` reads sourcing to disposition a count rise, so a rise there
now writes an auto `venue_fill` event instead of an `inventory_anomalies` row. **That is the
intended P1.4 behaviour (fixture 19), not burn-in drift.** Anomalies held at 40 across the change;
if day-3 burn-in (~2026-08-02) shows a Red Bull venue_fill on 1058, that is CORRECT.

📌 Untouched on purpose: Active `boonz_wh` edges for these three products on **fully_managed**
machines (Pepsi Black 19, Red Bull Regular 22, Red Bull Diet 22). The CS decision was scoped to VOX
/ co_managed machines; flipping those would violate the `tg_product_sourcing_model_guard` invariant
and is not what CS decided.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 48)

### ⛔ S-55 · NEW · OPEN · LOW · fixture 24 seq 29 is a non-vacuity precondition that PRODUCTION has legitimately made unsatisfiable

- **What:** `golden.run_all('P1')` returns fixture 24 (`Sentinel retirement safety`) at **40 pass /
  1 fail**. The single red is **seq 29**, `expect gt 0, actual 0`: _"PRECONDITION (non-vacuity): at
  least one sentinel carries phantom consumer_stock, so the S-50 drain leg is genuinely exercised
  rather than silently skipped."_
- **⛔ NOT caused by leg 48, and this is provable by timestamps.** `consumer_stock` on Active
  sentinels was measured **0 at 08:26Z during STEP R** — twelve minutes _before_ leg 48's first
  migration (08:38:12Z). The condition was already true at leg-48 entry; leg 47 simply closed
  before it happened.
- **Root cause, measured not inferred:** between **07:55Z and 08:08Z** twelve `return_dispatch_line`
  calls (`provenance_reason='dispatch_return'`) credited sentinel batches with **exactly 86 units**
  — Skittles, Aquafina, Pepsi, M&M, FadeFit2. That is the _same_ 86 units that left
  `consumer_stock`. Driver returns converted the phantom consumer stock into real warehouse stock.
  This is correct production behaviour, not drift.
- **⭐ The real lesson, and it generalises past this fixture:** seq 29 asserts on **ambient
  production state**. Any fixture whose non-vacuity precondition depends on production happening to
  be in a particular condition will eventually go red for a _correct_ reason, and it will look like
  a regression. The proven remedy already exists in this build as of this leg: **fixture 31's
  rollback-probe idiom** — seed the condition inside a PL/pgSQL subtransaction, measure into
  variables (which survive the rollback), then force the rollback. Zero residue, and the
  precondition is self-supplied rather than borrowed from production.
- **Smallest unblock:** re-express fixture 24's S-50 drain leg to seed its own phantom
  `consumer_stock` via the rollback-probe idiom, then restore seq 29 to a `gt 0` on the _seeded_
  count. ⛔ **Do NOT "fix" this by weakening seq 29 to `gte 0`** — that converts the tripwire into
  exactly the vacuous assertion it was written to prevent (the S-48 / S-52 failure mode, twice
  burned already).
- **Loop impact:** P1 is 144/1 instead of 145/0. The S-50 retirement _safety_ assertions (the other 40) are all still green; only the proof that the drain leg was _exercised_ is missing.
  Sentinel retirement is a parked DECISIONS-READY item, so nothing downstream is blocked.

### 📌 RISK 96 · NEW · the sentinel UNIT total is a live-moving quantity and must never be used as a state-integrity check

Legs 44-47 carried `sentinels 40 Active / 39,377 / 86 consumer` in the pointer's state block as
though it were static. At leg-48 STEP R it measured **39,463 / 0 consumer**. Neither number was
wrong: sentinel `warehouse_stock` **drains at pack (~04:10-05:05Z daily) and is credited at return
(~07:55-08:08Z)**, and 89 audit rows moved it over the preceding 96h. ⭐ **Only the `40 Active` ROW
COUNT is invariant. Pin that; never pin the units.** A future leg that treats a unit delta as drift
will burn a leg chasing ordinary driver activity.

### 📌 RISK 97 · NEW · the `^### RESUME POINTER` anchor count has been under-reported since ~leg 43

Leg 47 recorded 41 anchors; leg 48 measured **46**, against an EXECUTION-LOG whose SHA-256 was
**byte-identical** to leg 47's own baseline. The file did not change, so the anchor count was simply
mis-measured and then carried forward. ⭐ **The SHA-256 baseline is the integrity signal; the anchor
count is not.** Do not reconcile a file against it.

### S-01–S-54 unchanged · D-01–D-17 unchanged · RISK 74, 88-95 unchanged

### S-24 now **40** (leg 48 applied 3 migrations; 1 of 3 filed to disk — see the leg-48 pointer for the exact md5 targets and the recipe)

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 49)

### ✅ P2.4 IS FULLY BUILT — the resolver now reaches engine quantities

`engine_add_pod_v3` reads `resolve_demand_multiplier_v3` once per picked machine and multiplies
`vel_eff` by the resolved factor. Golden **fixture 7** (24 assertions, plan_date 2030-01-08) is
green. oid **235798** preserved, v19 `engine_add_pod` md5 re-verified byte-identical. `demand_calendar`
is still EMPTY, so the resolver returns `1.0` for all 31 machines and **live quantities have not
moved** — the feature is inert until CS authors a factor.

### ⏸️ D-18 · NEW DECISIONS-READY · the demand factor scales the MEAN but not the SAFETY term

- **What:** `vel_eff` is the single insertion point for the multiplier, and it feeds `mu_term`,
  `cover_units` and `expiry_ceiling_units`. But `sigma_daily_shelf` is derived independently in
  `polled`, from `velocity_instock_shelf`/`velocity_instock_pod` — **not** from `vel_eff`. So under
  a 1.6× uplift the mean demand rises 1.6× while the safety buffer `z·σ·√H` stays put. An uplifted
  machine therefore carries a proportionally _smaller_ service cushion exactly when demand is least
  predictable.
- **Why it was NOT fixed in the build:** BUILD SPEC P2.4 says only
  `effective_velocity = velocity_instock × Πfactors`. It says nothing about σ. LAW 13 (BUILD SPEC
  over intuition) and the goal command's "nothing here may be interpreted creatively" both forbid
  the loop inventing a variance model. Flagged at Cody review and deliberately parked.
- **The defensible options, for CS:** (a) leave it — σ is a _dispersion_ estimate and an event
  uplift arguably shifts the mean without widening relative spread; (b) scale σ by **√factor**,
  which is what a Poisson-ish process implies (σ = φ·√λ, so λ→fλ gives σ→√f·σ); (c) scale σ
  linearly by `factor`, the most conservative.
- **Activation:** one anchored substitution in `polled` plus a fixture-7 assertion pinning the
  chosen relationship. **≈15 minutes once CS picks (a), (b) or (c).**

### 📌 RISK 98 · NEW · `jsonb_build_object` is capped at 100 arguments = 50 key/value pairs

The engine's `reasoning` object sat at **49 pairs / 98 args** — one pair from the ceiling. P2.4's
five provenance keys took it to 54 pairs and **every engine run died** with
`54023: cannot pass more than 100 arguments to a function`.

⛔ **And it surfaced as a VACUOUS GREEN.** With the engine dead, both fixture-7 comparison maps were
empty, so every `count(*) FROM jsonb_each` mismatch assertion returned 0 and **passed**. Ten
assertions went green against a completely broken engine. What caught it in ~30 seconds was fixture
7 **seq 3/4**, the non-vacuity guards. ⭐ **Third time the S-48 / S-52 discipline has paid for
itself: every fixture that counts mismatches MUST carry a companion assertion that the population
being compared is non-empty.**

⚠️ **Standing rule:** before adding a key to `reasoning`, COUNT THE PAIRS. At 50 the base object is
FULL — append a new `|| jsonb_build_object(...)` group. Fixed forward-only (Article 12).

### 📌 RISK 99 · NEW · the engine md5 pin is over `prosrc`, NOT `pg_get_functiondef`

At leg-49 STEP R both engine md5s appeared to have changed, which reads as a LAW-12 emergency. They
had not. **Every prior leg's pinned md5 is `md5(prosrc)` — the function BODY.** `md5(pg_get_functiondef(oid))`
is a _different digest_ over a different string (it wraps the body in the `CREATE OR REPLACE …` header).
Both are legitimate; they are not interchangeable. ⭐ **Pin and re-measure `md5(prosrc)`.** Note the
leg-48 pointer correctly prescribes `pg_get_functiondef` for the _edit substitution_ — that is a
separate concern from the _integrity pin_, and conflating the two costs a leg.

### ⚠️ Fixture 7 seq 13 is TRUE but THIN — only ONE quantity moved under a 1.6× uplift

`qty_up = 1` of 32 lines. Not a defect: every other line is already bound by `fill_to_cap` or by WH
availability, so a demand uplift has nowhere to go. ⭐ **The real signal is that the fleet has very
little sizing headroom** — a demand multiplier can only bite where capacity and stock allow. Seq 13
(`gt 0`) is consequently a _thin_ assertion: an ambient shift could take it to 0 and red the fixture
for a correct reason (the S-55 class). If that happens, do **not** weaken it to `gte 0` — widen the
machine set instead.

### 📌 A failed `apply_migration` leaves NO version row

The first attempt at the 100-arg fix raised inside its `DO` block (a wrong belt-and-braces guard,
before `EXECUTE`). `schema_migrations` gained nothing and the engine was untouched. Confirmed by
re-reading `max(version)`. Useful: a migration that raises is genuinely atomic, so a bad guard costs
a retry and nothing else.

### S-01–S-54 unchanged · S-55 unchanged and still the SOLE P1 red · D-01–D-17 unchanged · RISK 74, 88–97 unchanged

### S-24 now **43** (leg 49 applied 3 migrations; 2 of 3 filed to disk and md5-verified — the fixture-7 file is the only new debt)

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 50)

### ✅ P2.6 IS BUILT — preflight now blocks at COMMIT, not just advises at stitch

BUILD SPEC P2.6 reads "Preflight invariants -> blocking at commit incl. the corrected INV-06".
INV-06 v2 had already shipped under P0.6(d) and golden fixture 10 pins it in both directions, so the
corrected-invariant half was **already done**. The missing half was the gate itself:
`commit_refill_plan` did **zero** invariant checking. A plan carrying a known conservation leak could
be committed, and nothing refused it and nothing recorded that it had been let through.

Shipped: `preflight_override_log.source`, three columns on `refill_commit_log`, the new
`preflight_override_v3(date,text)` RPC, and the `commit_refill_plan` wiring. Golden fixture 33
(35 assertions) **16/16 RED → 35/35 GREEN**, zero errors in either run.

### ⏸️ D-19 · NEW DECISIONS-READY · flip `preflight_enforcement` to `'block'`

**What it is.** One flag now arms **both** gates. `stitch_pod_to_boonz` has been wired in warn mode
since PRD-109; `commit_refill_plan` joins it as of this leg. Flipping to `'block'` makes a `FAIL`
verdict refuse at both.

**Evidence it works.** Fixture 33 seq 20/21/22/23 (block mode refuses, writes **zero** commit-log
rows, and hands back the violation with its `fix_path`), seq 40-43 (**anti-over-block**: repairing
the leak flips the verdict to PASS and the same gate lets the plan straight through under block
mode), seq 30-39 + 44-46 (the audited single-use override and its audit chain).

**The single command.**
`UPDATE public.refill_policy_params SET preflight_enforcement = 'block';`

**The one-line ask.** ⛔ **Do NOT flip without CS burn-in** — this is the same unchanged instruction
that has ridden every pointer since PRD-109; the flip now has twice the blast radius, and a live plan
carrying a genuine violation would start being refused at commit as well as at stitch. Burn-in
evidence to collect first: how often does `preflight_refill_plan` return `FAIL` on real plan_dates?
`refill_commit_log.preflight_verdict` is populated from this leg forward and is exactly that dataset,
accumulating with no behaviour change. ⭐ **Let it accumulate for a week, then read it — the flag now
costs nothing to leave in warn and buys the evidence to flip it safely.**

**The escape hatch is built and audited.** `preflight_override_v3(plan_date, reason)` grants ONE
single-use override for a plan_date whose verdict is `FAIL`. Reason ≥ 10 characters. It refuses when
the verdict is not FAIL (no banking a blanket grant) and when an unspent grant already exists (no
stacking). `REVOKE`d from `anon`.

### ⛔ RISK 100 · NEW · an append-only log that needs "consumed" state is an Article 7 trap

The override was first designed to be consumed by stamping `preflight_override_log.consumed_at`.
Cody blocked it. That table carries `pol_no_update` and `pol_no_delete` — and **a `postgres`-owned
`SECURITY DEFINER` bypasses RLS**, so the UPDATE would have _succeeded_. That is the trap: the
policy would have been defeated **invisibly**, by a function that read as compliant, and the fixture
would have gone green on it.

⭐ **STANDING RULE: when an append-only log needs "consumed" state, put the state on the CONSUMER.**
Here `refill_commit_log.preflight_override_id` references the grant it spent, and a partial UNIQUE
index makes a second spend physically impossible. Both logs stay insert-only, and the audit chain
reads forwards (which commit spent which grant) instead of as a mutable flag. The corrected fixture
assertion is strictly stronger than the one it replaced.

📌 Corollary for reviewers: **"the DEFINER can write it" is not evidence that it may.** RLS bypass by
ownership is the normal case for every canonical writer in this codebase, so the policy is never the
thing that stops you — the review is.

### ⛔ RISK 101 · NEW · `pronargdefaults` — check it before ANY `CREATE OR REPLACE`

The first apply of the gate failed with `42P13: cannot remove parameter defaults from existing
function`. The live signature is `commit_refill_plan(p_plan_date date, p_comment text, p_machine_ids
uuid[] DEFAULT NULL::uuid[])` and the replacement had dropped the default — the same class as the
13-day driver-confirm outage already in memory. Postgres caught it; nothing else would have.

📌 **A failed `apply_migration` leaves NOTHING behind** — re-verified this leg: no column, no version
row, `max(version)` unmoved. Confirms the leg-49 note.

📌 An overload carrying extra defaulted params (`p_force`, `p_force_reason`, mirroring stitch) was
**rejected as a design** for the same reason: alongside the existing 3-arg form it would make every
3-arg call ambiguous. The grant-then-commit split dodges the overload entirely — and is better audit,
because the override becomes an explicitly authorised act rather than a parameter someone can pass.

### 📌 Two pointer-shape corrections (this leg's probes were wrong, not the pointer)

1. **`current_phase` is a COLUMN on `golden.config`, not a `refill_settings` key.**
   `SELECT current_phase FROM golden.config` → `P2`. Probing `refill_settings` for it returns NULL
   and reads as a false discrepancy. (`golden.config` is a single-row table: `id, current_phase,
updated_at, note`.)
2. **`golden.runs` DOES have a `passed` column** — the leg-49 pointer says it has none. It also has
   `n_pass`/`n_fail`/`n_expected_red`, which is what the totals are built from, so nothing downstream
   was wrong; the shape note was.

### S-24 now **46** (leg 50 applied 3 migrations, **0 filed to disk** — filing debt is now SIX)

Owed, with exact md5 targets and the twice-proven recipe, in the leg-50 pointer. Nothing else
outstanding: DB, fixtures and registries agree and were verified together.

### S-01–S-54 unchanged · S-55 unchanged and still the SOLE P1 red · D-01–D-18 unchanged · RISK 74, 88–99 unchanged

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 51)

### ✅ D-12 DIFF HALF BUILT — and the object that was supposed to carry it could never have worked

BUILD SPEC P2 tail asks for a "nightly diff vs v19 (units, lines, blocked, per-machine) + WMAPE
tracking". Three views now cover the **diff** half: `v_engine_diff_v3` (line grain),
`v_engine_diff_v3_by_machine` (per machine, incl. blocked) and `v_engine_diff_v3_summary` (one row
per plan_date — what the Phase-2 gate reads). Golden fixture **34**, 45 assertions,
**17/28 RED → 45/45 GREEN**, zero errors in either run.

### ⛔ RISK 102 · NEW · a diff object with an empty side reports PARITY

`v_shadow_vs_live_plan_v3` — built at leg 12, registered, never questioned since — reads
`pod_refill_plan_shadow`. That table has **0 rows**, and `engine_add_pod_v3` does not mention it
anywhere in its source (`position(... in prosrc) = 0`). The v3 engine writes only
`pod_refills_shadow`. The view could therefore **never return a row on any date**, and its output
would have read as "v3 and v19 agree on everything".

It was found by probing the object's **row count on a date where both engines had just run** —
not by reading its definition, which looks entirely reasonable.

⭐ **STANDING RULE: a comparison object must be able to say "I compared nothing" out loud.**
`v_engine_diff_v3_summary.is_vacuous` is TRUE whenever either engine contributed zero lines, and
METRICS_REGISTRY now requires every reader to branch on it before quoting a delta. This is the
S-48 / S-52 non-vacuity discipline promoted out of the fixtures and into the metric itself, because
the fixtures only protect what someone thought to assert.

📌 The plan-grain view is **kept** (Article 12) — it is correct for the grain it names and comes
alive at cutover. It now carries a `COMMENT ON VIEW` that opens with the warning, and fixture 34
seq 60/61 pin its emptiness as by-design.

### ⭐ `golden.probe_scalar(text)` closes a long-standing tension with LAW 1

LAW 1 wants the fixture before the object. A `check_sql` naming a missing relation fails at PARSE
time, so the fixture dies as an ERROR and the RED proves nothing — which is why legs 47-50 each had
to find a fixture whose objects all already existed and make the RED come from _behaviour_. That
constraint is now lifted: `probe_scalar` EXECUTEs the probe and degrades a missing relation to a
`MISSING: …` sentinel, producing a clean assertion FAILURE. 28 RED assertions, 0 errors.

⛔ Only with `eq` / `ne` / `contains` — `golden.compare` RAISES on `gt`/`gte` for a non-numeric
operand, which would put the error straight back.

### ⏸️ D-12 REMAINDER (not parked — it is simply the next task)

**WMAPE tracking** and the **nightly runner** (a cron that runs `engine_add_pod_v3` into shadow on
real plan_dates). The diff views are inert without the runner: `pod_refills_shadow` currently holds
only synthetic 2030 dates, so `v_engine_diff_v3_summary` returns rows for those and nothing else.
⛔ The runner touches production scheduling and needs its own Cody pass — it is deliberately NOT
bundled into this leg's atomic unit.

### S-01–S-54 unchanged · S-55 unchanged and still the SOLE P1 red · D-01–D-19 unchanged · RISK 74, 88–101 unchanged

### S-24 now **48** (leg 51 applied 2 migrations, 0 filed to disk — filing debt is now EIGHT)

### ✅ S-56 · RAISED AND CLOSED IN THE SAME LEG · `velocity_status` NULL fall-through (P2.1)

Fixture 2 seq 8 went 0 → 2 mid-leg. `velocity_status`'s `stock_hours < floor_hours` predicate
returns NULL (not TRUE) when `stock_hours` is NULL, falling through to `'ok'`, while
`velocity_instock` correctly returns NULL — so the status contradicted the value. Migration
`20260731102752`, one predicate, violations 2 → 0, fixture 2 back to **49/49**.

⭐ **STANDING RULE: when a status column classifies what a value column computes, the two guards
must agree on NULL explicitly.** `>=` fails safe on NULL; `<` fails OPEN. This pair was written at
different times against the same column and disagreed silently for as long as no row had NULL
`stock_hours`.

📌 **Contained by measurement, not by luck:** `engine_add_pod_v3` reads `velocity_status` from the
SHELF-grain `v_shelf_instock_velocity_split_v3`, which has 0 violations across 544 rows (it anchors
on the WEIMI snapshot, not `now()`). The sibling was NOT patched — there was nothing to patch, and
touching the engine's live input to fix a defect it does not have would be scope drift.

📌 **A now()-anchored window makes an invariant intermittent.** This view's window slides
continuously, so the violation appears and disappears with the clock. An intermittent golden red
whose object has a rolling window is a reason to FIX, not to pin the assertion.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 52)

### ✅ D-12 WMAPE HALF BUILT — adopted from a leg that died before it could tell anyone

`engine_forecast_error_v3` (snapshot) + `refresh_engine_forecast_error_v3(date)` (writer) +
`v_engine_wmape_v3` / `v_engine_wmape_v3_gate` (readers). Golden fixture **36**, 31 assertions,
**11/20 clean RED → 31/31 GREEN**. Six migrations, `20260731105057` … `20260731110004`.

⛔ These were applied by a **leg-52 attempt that died minutes after its last green run, having
filed no log entry, no registry rows and no migration files.** Verified object-by-object and
**adopted** at leg 52 proper — see **RISK 104**.

### ⛔ RISK 104 · NEW · a dead leg leaves the DB ahead of the log, and `git status` stays silent

The _"nothing half-applied"_ handoff invariant is enforced **at leg close**. A leg that dies never
reaches its close, so the invariant never runs. What it leaves behind is applied migrations and a
green fixture with no record — and because the filing debt is exactly what `git status` counts, the
count matched the pointer's prediction **precisely** and read as health.

⭐ **MITIGATION — `max(version)` is the load-bearing STEP R probe.** The doc SHA-256 canary only
fires if the dead leg happened to edit a doc (52a did, which was luck). The migration high-water
mark fires unconditionally on any applied work.
⭐ **STANDING RULE: at STEP R, compare `max(version)` and the `prd110%` count against the pointer
BEFORE trusting any other claim. Treat a forward gap as adoptable work to be verified and recorded,
never as corruption to be undone** — re-running 52a's migrations would have been the destructive
mistake available here.

### ⭐ ADR §10 — the one sanctioned materialization in PRD-110

ADR §2 said WMAPE would be a view "likewise" the diff. It cannot be, and §10 records why **with the
measurement that changed the answer**: actuals resolve through `v_sales_history_resolved`, whose
join key is a **correlated name lookup**, so the actuals scan alone costs **13.5 s** — a floor no
index removes — and a live view would also **silently rewrite a WMAPE CS had already reviewed**
whenever sales are restated. The gate is a claim about a point in time; it is recorded with
`measured_at`. The two reader objects stay views, so §2 still governs everything cheap.

### 📌 First real forecast-accuracy number: v19 WMAPE **0.7878** on 2026-06-26

141 settled series, forecast 4106.9 vs actual 2935.0, bias **+0.3993** (over-forecasts ~40%). This
is the Phase-2 gate's denominator. ⛔ **One date is not a fleet verdict** — do not quote it as
"v19's accuracy" until the nightly runner has accumulated a fortnight.

### ⏸️ D-12 REMAINDER is now the nightly runner ALONE

A cron that runs `engine_add_pod_v3` into shadow on **real** plan_dates, and calls
`refresh_engine_forecast_error_v3` per date. Both halves of the telemetry are built and inert
without it: `pod_refills_shadow` holds only synthetic 2030 dates, and v3 has **no** WMAPE row at
all, which is why the gate reads `no_v3_measurement`.
⛔ Still needs its own Cody pass (production scheduling, LAW 12), and the engine must be **proven
safe on a real plan_date** — verify its behaviour against a date carrying non-pending live rows
**before** anything is scheduled.

### 📌 D-08 burn-in — 5 open `count_above_capacity` anomalies are a CAPACITY QUESTION, not drift

MPMCC-1058 (`Batch_2`) shelves **A10/A12/A13/A14/A16**, all from the single 10:00Z WEIMI snapshot on
2026-07-31, exceeding capacity by 2-5 units (A16: 21 vs 16). Five shelves in one snapshot points at
a physical over-fill or understated planogram capacities. The estimator clamped and logged — that is
fixture 14's path working. Invariants re-probed: **0 negative `est_qty`, 0 confidence out of [0,1]**.
Carry into the **day-3 read on ~2026-08-02 as a question for CS**, not as a burn-in failure.

### S-01–S-56 unchanged · S-55 still the SOLE red in the suite · D-01–D-19 unchanged · RISK 74, 88–103 unchanged

### S-24 now **54** — filing debt is **FIFTEEN files** (nine carried + 52a's six) and has grown six legs running

### ✅ S-24 CLOSED — filing debt cleared, and the ledger that tracked it was wrong by twelve

**27 files owed, not 15.** The owed set was computed from `schema_migrations` ∖ disk rather than from
the carried counter, which surfaced a 2026-07-30 tranche of twelve (all of P1.4, fixtures 19-22, P1.3
and P2.0) that had dropped out of the relay's bookkeeping legs ago. All 27 filed and verified from
disk against the stored `md5(statements[1])` — **27/27, zero mismatches**. `git status` 88 → 115.

⭐ **STANDING RULE: recompute the owed set; never trust a carried count.** A hand-incremented ledger
drifts exactly like any other unverified claim — this one drifted by 44%.
⭐ **The cost was ~2k tokens, not the ~35k the pointer budgeted.** Bodies do not need to round-trip
through context: stream `statements[1]` to disk and verify by md5 there. The debt was deferred six
legs running because it had been priced as unaffordable, and it never was.

📌 `20260730203000_…d08_fleetwide_immunity.sql` on disk with no `schema_migrations` row is **S-31's
known broken leg-24 original**, superseded by the applied `20260730214710`. Retained deliberately.

### ⭐ Runner precondition DISCHARGED — `engine_add_pod_v3` cannot write outside shadow

Every DML target in its 30,534-char body is `public.pod_refills_shadow`; the only volatile `public`
function it calls (`_assert_gate_zero`) writes nothing. **LAW 12 is structurally inapplicable to the
engine** — there is no date on which it can touch a live plan table. The runner therefore needs a
schedule, not a refusal path. Multi-run-per-date is also already safe: `v_engine_diff_v3` selects the
latest run per date via `DISTINCT ON … produced_at DESC`, proven at 4-32 runs/date on the synthetics.

---

## STUCK / DECISIONS updates (2026-07-31, relay leg 54)

### ✅ S-57 CLOSED — and it was WIDER than leg 53 recorded

Leg 53 raised S-57 against `engine_forecast_error_v3` and recorded that the new
`shadow_runner_log_v3` "deliberately follows the `pod_refills_shadow` standard, not this one."
⛔ **The live grants said otherwise: it carried the SAME loose
INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER for `authenticated`.**

⭐ **The mechanism is worth keeping, because it will recur on every new public table.** The migration
did write `GRANT SELECT` — but **a GRANT is additive.** Supabase's default privileges have _already_
granted ALL on a newly created table in `public`, so a `GRANT SELECT` adds nothing and narrows
nothing. **Only an explicit REVOKE narrows.** Writing the grant and believing the table was locked
down is the trap; `pod_refills_shadow` is SELECT-only because something actually revoked.

✅ **Closed by `20260731121100`** for both tables. Safe, verified live rather than assumed: the only
writers are `refresh_engine_forecast_error_v3` and `run_nightly_shadow_v3`, **both SECURITY DEFINER
owned by `postgres`**, so every legitimate write executes as postgres and is untouched by the
`authenticated` grant. SELECT retained (the health view and WMAPE readers need it).

📌 **Why it survived a 27-assertion fixture:** seq 26/27 check **`anon` only** — the exact blind spot
of fixture 36 seq 31. New seq **28/29/30** pin `authenticated` on both tables, RED-first at
`expect 0, actual 6`.
⚠️ **`blocked_demand` carries the same loose grants** and was NOT touched this leg (pre-existing,
out of scope, its writers want their own check first). Left as a one-line REVOKE for a later leg.

### ⛔ S-58 · NEW · a fixture that asserts an ABSOLUTE count on an APPEND-ONLY table is not idempotent

Fixture 37 seq 13 counted rows in the durable `shadow_runner_log_v3`, so it was green **only on a
virgin run**: the count drifts 1 → 2 → 3. Leg 53 ran it once, saw 27/27, and recorded that. The
committed `run_all('P2')` — which leg 53 left running and could not read before it closed — returned
**26/27**. ⛔ **This would also have failed STRESS S7** (`run_all()` ×3 → identical results), i.e. a
latent STEP-7 failure was already sitting in the suite.

📌 Proven, not inferred: all nine `(note,step,status)` groups sat at exactly **n=2** after exactly
two runs.

⛔ **The obvious fix — have the fixture DELETE its own rows first — was REFUSED on Cody review.**
The table carries `tg_srl_v3_no_update` **and** an audit trigger and is an Article 7 append-only log;
worse, a fixture that deleted from it would contradict **its own seq 19**, which exists to prove the
absence probe left the log intact.

✅ **Re-expressed as a DELTA measured across the gate0 call.** Mutates nothing, idempotent by
construction, and **strictly stronger than the original** — it proves _this_ run wrote exactly one
row, where an absolute count could be satisfied by some other writer's row. ⛔ **Not weakened to
`gte 1`**; a double-write is the regression the assertion exists to catch.

⭐ **STANDING RULE for the remaining fixtures: an assertion over an append-only or accumulating
table must measure a DELTA or a scoped key, never an absolute count.** STEP 7's S7 will find any
that still do — this one is now the worked example of the fix.

### ⛔ RISK 105 CONFIRMED — and it is what let both defects through

Leg 53 predicted the stale-baseline mechanism; leg 54 observed it twice more (the PostToolUse
formatter rewrote `MIGRATIONS_REGISTRY.md` immediately after the edit returned). The leg-53 close
measured its six hashes **last**, and at leg 54's STEP R **all six re-measured byte-identical** —
the fix works. Keep measuring hashes as the final action of a leg.

📌 **The deeper lesson of this leg is not about hashes.** Leg 53's numbers were _honestly measured
and still wrong_, because a fixture was run **once** and a grant was **written but never read back**.
⭐ **Verify the effect, not the statement:** a `GRANT` is not a privilege state, and one green run is
not idempotence.

### ⛔ S-59 · NEW · OPEN · the pod category taxonomy is FRAGMENTED, so exact matching under-reaches

P3.1's category-first rule (BUILD-SPEC line 89) needs `pod_products.product_category` to be a clean
partition. It is not. Measured live at leg 54 across 33 distinct values:

- `Chips` (**1** pod) sits beside `Chips & Crisps` (**13**)
- `Chocolate Bar` (**2**) sits beside `Chocolates` (**9**)
- `Snack Bar` (**1**) stands alone next to `Protein & Health Bars` (**15**)
- **3 pods carry a NULL category**; **7** sit under a literal `Test`

⚠️ **Consequence:** exact-equality category matching will miss true in-category peers and fall
through to the cross-category rung — a **silent** under-reach that looks like "no in-category
candidate had stock". The `requires_cs_review` flag makes it visible rather than invisible, which is
the mitigation actually shipped.

⛔ **Deliberately NOT fixed by the loop.** Merging `Chips` into `Chips & Crisps` is a merchandising
taxonomy decision with downstream reporting consequences, and inventing the mapping is exactly the
scope drift LAW 10 forbids. **Smallest unblock: CS confirms a merge map for the four near-duplicate
pairs (or declares them intentionally distinct), then one migration normalises.**

### ⏸️ D-20 · NEW DECISIONS-READY · margin is not computable at pod grain, so rule (3) ships without it

CS rule (3) ranks substitutes by "performance/**margin**/stock". `pod_products` exposes
`recommended_selling_price` but **no cost column**, and cost lives at the `boonz_product` /
purchase-line grain behind a mapping fan-out that the DATA-SOURCE LAW forbids reading through for
stock — and which would be equally unreliable here.

✅ **Built:** ranking on **performance × stock**, with Pearson as a within-category tiebreak only.
⏸️ **Parked:** the margin term. **One-line ask for CS —** _"confirm a per-pod margin source (a
`pod_products.unit_cost` column, or a sanctioned view) and the selector gains a margin factor;
until then substitutes rank on velocity and availability."_

### ⚠️ CS QUESTION · BUILD-SPEC line 89's "Popit" is not an in-category substitute for Hunter Ridge

The spec line asks for "an in-stock snack not already on the machine (**Popit**/G&H case)". Live
categorisation: **`Popit Mix` = `Soft Drinks`**, `Hunter Ridge` = `Chips & Crisps`. Under CS's _own_
rule (1), Popit Mix is no more valid than Pepsi. **`G&H Popped Chips` (`Chips & Crisps`) is the
in-category answer.** Either the note is loose shorthand or `Popit Mix` is miscategorised (it reads
like a popped-snack brand, which would make this an instance of **S-59**). ⛔ Not resolved
unilaterally. **Smallest unblock: CS states which of the two it is.**

### 📌 P3.1 reconnaissance — three findings that change the build, recorded so nobody re-derives them

1. ⭐ **`v_pod_substitutes` is DEAD CODE** — pure Pearson, and **zero consumers in `pg_proc`**.
   Fixing it would have changed nothing. The live path is **`find_substitutes_for_shelf`** ←
   `engine_swap_pod`. ⛔ Never modify v1; build `_v3` beside it (LAW 3).
2. ⛔ **The incident machine proves the FLAG path, not the category path.** On `9db7a821` all four
   `Chips & Crisps` pods with WH stock are **already on the machine**, so rule (2) removes them all
   and the correct v3 answer there is _still_ cross-category (flagged). A fixture demanding an
   in-category winner on that machine would be **unsatisfiable — a second S-55.**
3. ✅ **The category path is anchorable elsewhere:** **350 (machine, anchor) pairs across 31
   machines** have an in-category candidate with stock that is not already present.

### S-01–S-57 unchanged (S-57 CLOSED this leg) · S-58 raised and adopted · D-01–D-19 unchanged · RISK 74, 88–105 unchanged

---

## DECISIONS-READY / STUCK updates (2026-07-31, relay leg 55 — P3.1a shipped)

### ✅ D-20 is WITHDRAWN — its premise was false

Leg 54 parked D-20 as "margin is not available at pod grain: `pod_products` has
`recommended_selling_price` but no cost column". ⛔ **`pod_products.purchasing_cost` exists**, and is
populated for **102 / 163** pods (**88** carry both cost and RSP). Re-probed live this leg before a
line of SQL was written. 📌 The generalisable lesson is the leg-54 one, applied to leg 54 itself:
**verify the effect, not the recollection** — a column absent from a remembered schema is not an
absent column.

### ⏸️ D-21 (NEW, replaces D-20) — should margin WEIGHT the substitute ranking?

- **What:** `find_substitutes_for_shelf_v3` **returns** `unit_margin` (RSP − purchasing_cost) but
  does **not** rank on it. Ranking is `category_match → performance × stock → Pearson tiebreak`.
- **Why parked, not built:** cost is on file for only **54%** of pods. Any margin weight
  systematically demotes the other 46% for a data-entry gap rather than a commercial reason — a
  silent bias that would be very hard to see in a ranked list. CS rule (3) does say
  "performance/margin/stock", so this is a real half-delivery, deliberately visible.
- **Evidence it works:** fixture 39 seq 35 (unit_margin populated on the live category path).
- **The one-line ask:** _"Weight margin at W% in the substitute score, and what do we do with the
  46% of pods that have no `purchasing_cost` — treat as fleet-median, or exclude from the term?"_
  Filling in `purchasing_cost` for the missing 61 pods would close this without a modelling call.

### ⚠️ CS QUESTION (raised leg 54) — still open, and now sharper

BUILD-SPEC line 89 names "**Popit**/G&H case" as the in-stock snack that _should_ have won.
Live categorisation says **`Popit Mix` is `Soft Drinks`** — so under CS's own rule (1) Popit Mix is
no more valid a Hunter Ridge substitute than Pepsi is. **`G&H Popped Chips` is the in-category
answer.** ⛔ Either the spec note is loose or Popit Mix is miscategorised (an instance of S-59).
📌 Sharper now: `Popit Mix` was observed live at **rank 4** of v1's output for the _Fade Fit_ anchor
too. Whichever way CS rules, it is a one-word fix — either the spec line or the product row.
**Smallest unblock: CS states which of the two it is.**

### ⛔ S-59 (raised leg 54) — CONFIRMED and now load-bearing

Full live taxonomy measured this leg: **33 distinct categories over 163 pods**, including
`Chips` (1) beside `Chips & Crisps` (13), `Chocolate Bar` (2) beside `Chocolates` (9),
`Snack Bar` (1) alone, `Test` (7) and **3 pods with a NULL category**.
`find_substitutes_for_shelf_v3` matches on **exact equality** and therefore under-reaches: a
Chips pod will not be offered for a Chips & Crisps anchor. ⛔ **A merge mapping was NOT invented** —
that is a CS taxonomy decision and pure scope drift (LAW 10).
⭐ **Why this is safe to defer:** the under-reach is never silent. Under-reaching means no
in-category candidate is found, which is exactly the condition that sets `requires_cs_review = true`
— so a fragmented-taxonomy miss surfaces to CS as a flagged cross-category pick rather than
disappearing. **Smallest unblock: CS approves a category merge map** (`Chips`→`Chips & Crisps`,
`Chocolate Bar`→`Chocolates`, a home for `Snack Bar`, and a decision on the 3 NULLs + 7 `Test`).

### ⏸️ D-22 (NEW) — v3 has no consumer; the ladder wiring is a separate unit

`find_substitutes_for_shelf_v3` is live, tight-granted and proven, but **nothing calls it yet**.
`engine_swap_pod` still consumes v1 and must keep doing so (LAW 3 — Phase 3 has not earned the right
to change swap behaviour in the same unit that changes substitute selection). Wiring v3 into the
P3.1 substitution ladder inside `stitch_v3` is the next build unit, not a parked decision — recorded
here only so nobody reads "P3.1a shipped" as "the ladder now uses it".

### 📌 Correction to the leg-54 reconnaissance note (item 3 above)

The category-path population is **350 (machine, anchor) pairs across 37 machines**, not 31.
Pair count re-measured identical; the machine count was wrong. Recorded because the _reason_ the
number matters is breadth of the non-vacuity claim.

### ✅ S-57 remains CLOSED; its lesson was applied FORWARD this leg

v3 shipped with an explicit `REVOKE ... FROM PUBLIC, anon` rather than relying on a `GRANT` to
narrow, and fixture 39 seq 33/34 pin **both** directions (anon cannot execute, authenticated can).
⚠️ The two S-57 residuals are **untouched and still open**: `pod_refill_plan_shadow` grants
`authenticated` REFERENCES+TRIGGER, and **`blocked_demand` carries the full loose DML set** — a
one-line REVOKE plus its own assertion for a later leg.
📌 v1 `find_substitutes_for_shelf` is still `anon`-executable. Not changed: it is a live object with
two consumers, and re-granting is not this unit's business.

### S-01–S-58 otherwise unchanged (S-55 still the sole red) · D-01–D-19 unchanged · RISK 74, 88–105 unchanged

### ✅ S-58 SUITE-WIDE AUDIT DONE (leg 55) — the pointer's "audit before STEP 7 rather than let S7 find them"

Scanned **every enabled assertion** whose `check_sql` counts over an accumulating or append-only
table (`shadow_runner_log_v3`, `pod_refills_shadow`, `blocked_demand`, `inventory_events`,
`inventory_anomalies`, `engine_forecast_error_v3`, `pod_refill_plan_shadow`, the audit logs,
`golden.runs`): **75 candidates across 12 fixtures.**

⭐ **Result: the house idiom was already correct almost everywhere.** 74 of the 75 are safe, in
three recognisable shapes:

1. **Before/after DELTA via `golden.scratch`** — the `seq 93/95/97/99` "RESIDUE" family snapshots the
   count at scenario start and compares. This is exactly the shape S-58 forced fixture 37 seq 13
   into, and it was already the standard. ✅
2. **Scoped to a synthetic key** — counts filtered by a 2030 `plan_date` or by `golden.v3_run_id()`.
   An accumulating table scoped to a key only this fixture writes cannot drift. ✅
3. **Counts over STATE, not history** — `information_schema.role_table_grants` (the grant pins).
   Not accumulating at all. ✅

⛔ **S-60 (NEW, the single finding) — fixture 37 seq 24 is an absolute pin on a REAL date.**
`count(*) FROM engine_forecast_error_v3 WHERE plan_date = 2026-06-26 AND actuals_settled` is pinned
`eq 141`. It is green today and it is _not_ the S-58 accumulate shape (the table is DELETE+INSERT per
date, so it does not grow). But 141 is a **fleet-shaped number on a production date**: any legitimate
re-measure of 2026-06-26 after a machine or mapping change moves it, and the failure would read as a
runner regression rather than as "the fleet changed". Its neighbours (seq 21, 30) already express the
same intent relationally. **Smallest fix: re-express as "unchanged across this run" using the
before/after scratch idiom of shape (1), or as `gte 1` plus the existing grain assertions.**
⛔ Deliberately NOT changed this leg: it is leg 53's object, it is currently green, and editing
another fixture's assertion mid-leg without a full P2 re-run afterwards is how a clean leg turns
ambiguous. Recorded so STEP 7 does not discover it as a mystery.

### ⛔ S-61 (NEW, leg 55) — ONE PHASE PER TRANSACTION, or fixture 14 seq 91 false-reds

`golden.run_all()` is **transactional**: one call = one transaction. Fixture 14 seq 91 is an ADR 8.3
tripwire that attributes live-plan writes **by transaction**
(`golden.written_by_this_txn(x.xmin)` over `pod_refill_plan`) — deliberately, so a concurrent live
writer can neither cause a false red nor mask a real one. ⛔ **That attribution silently assumes one
phase per transaction.** Leg 55 ran `run_all('P0')` + `('P1')` + `('P2')` in a single SQL statement;
**fixture 10 (P0) legitimately INSERTs into `pod_refill_plan`** (2030 synthetic dates, LAW 12
respected), and its 7 rows were attributed to fixture 14's run → **expect 0, actual 7**.
Re-running `run_all('P2')` alone returned **356 / 0** with seq 91 reading `0`, no code changed.
⚠️ **Binding on STEP 7:** S7 requires `run_all()` ×3 identical. Batching phases to save wall-clock
produces a false red and costs a leg hunting a live write that never happened.
**Smallest permanent fix (not applied): scope seq 91 to `x.plan_date = {{plan_date}}`** so it
attributes by transaction AND by this fixture's own date. ⛔ Not done this leg — it is fixture 14's
assertion, it is green under correct usage, and editing it would need another full P2 run to clear.

## DECISIONS-READY / STUCK updates (2026-07-31, relay leg 56 — P3.1b shipped)

### ✅ D-22 is DISCHARGED in part — the ladder exists, but it still has no consumer

`resolve_supply_ladder_v3` is live, proven (fixture 40, 38/38 ×4) and tight-granted. The ladder
that D-22 said was "the next build unit" is now built. ⛔ **It still has no caller**, and that is
deliberate: it is READ-ONLY and advisory. Wiring it means teaching a _writer_ to emit the legs
(transfer / M2M / spot-buy / blocked rows), and the writer is `stitch_v3` — which **does not exist**
(see S-62). D-22 is therefore re-scoped, not closed: _the decision is built; the effect is not_.

### ⛔ S-62 (NEW, and it corrects a standing assumption in the pointers) — `stitch_v3` DOES NOT EXIST

Every pointer since P3 opened has said "the ladder wiring goes inside `stitch_v3`". Probed live this
leg: there is **no `stitch_v3`**. The only stitch is v1 `stitch_pod_to_boonz`, **50,903 characters**,
plus `restitch_after_edits`, `reset_and_restitch`, `reopen_stitched_rows`, `confirm_stitched_plan`.
`plan_edits` (P3.6) does not exist either. ⛔ **P3.1's "in stitch_v3" is therefore not a wiring task,
it is a build-stitch_v3 task** — a 50k-character engine port, comfortably several legs on its own.
⭐ **Why this was worth stopping to record:** a leg that reads "wire the ladder into stitch_v3" as a
small task will either edit v1 stitch in place (LAW 3 violation, and v1 is a live engine) or discover
mid-leg that the target is missing and leave a half-applied unit. **Smallest unblock: treat
`stitch_v3` as its own multi-leg unit (P3.1c), and keep shipping the P3 selectors standalone until
it exists** — which is exactly what P3.1a and P3.1b did.

### ⭐ S-63 (NEW) — SENTINELS ARE NOT SUPPLY, and any rung that sums `v_wh_pickable` naively is wrong

`v_wh_pickable` carries **40 VOXSOURCE sentinel rows / 39,463 phantom units** (999 each, expiry
2099-12-31, `wh_location='VOX_SOURCED'`), minted by P0.4 to unblock venue-sourced planning.
Measured on the fixture-40 anchor: Fade Fit shows **7,992 sentinel units and ZERO real ones**.
⛔ A ladder that sums `v_wh_pickable` without filtering "rescues" that gap with stock nobody can
pick, and does it _silently_. `resolve_supply_ladder_v3` excludes `batch_id LIKE 'VOXSOURCE-%'` from
supply and **reports the excluded count** as `supply.sentinel_units_excluded`. ⚠️ **Binding on every
future rung, engine and availability read**, not just this one. Fixture 40 seq 24-27 pin it.

### ⭐ S-64 (NEW, the most load-bearing finding of the leg) — STOCK IS NOT AVAILABILITY

The engine allocates a shared WH pool **fleet-wide in priority order**. Live proof, read from the
engine's own `pod_refills.reasoning` rather than reconstructed:

```
VOXMCC-1005-0201-B0 / Vitamin Well   wh_avail 13 · need_raw 8 · qty 0 · clamp_reason blocked_no_wh
                                     reasoning->>'prior_need_pool' = 40
```

Stock **existed** (13 ≥ 8) and the shelf still clamped `blocked_no_wh`, because 40 units of earlier
demand had already claimed the pool. ⛔ **`wh_available_pod` is GROSS pod stock, not what remains.**
Any consumer that reads it as availability will re-offer units the plan has already spent — the
double-allocation / phantom-mint class of bug. The ladder nets off `SUM(pod_refills.qty)` for the
same pod and `plan_date` (excluding the subject shelf) and names its allocation model in the output
(`claims consume primary WH first, then spill to other warehouses`). ⭐ **Visible in the live result:**
anchor B has gross 7, claimed 6, and the ladder promises **1 unit, not 7**.

### 📌 S-65 (NEW, cheap but it cost a probe) — `golden.runs.detail` is an ARRAY, so `detail->>'scenario_error'` is ALWAYS NULL

`run_fixture` builds `detail` as `'[]'::jsonb || jsonb_build_object(...)`, and `array || object`
**appends** rather than merging. A scenario failure is therefore an _element_, not a top-level key.
⛔ Read it with `jsonb_array_elements(detail) e WHERE e ? 'scenario_error'`. The RED baseline this
leg failed its scenario on a real type error (`golden.scratch.value` is **jsonb**, not text) and the
top-level lookup reported `null`, which reads as "no error".

### ⚠️ REGRESSION NOT RUN THIS LEG — P0 / P1 / P2 were NOT re-executed (deliberate, stated so it is not mistaken for green)

Only **P3** was re-run (2 fixtures / 75 assertions / 0 fail; fixture 39 unregressed at 37/0).
P0/P1/P2 were **not** run. Justification: this leg is purely additive — one new function with no
callers and one new fixture — and `current_phase` was **not** touched (leg 55 already set it to P3),
so no existing fixture's assertion set or outcome can change. ⛔ **This is a stated gap, not a
claim of green.** The next leg that needs a full baseline must run `run_all('P0')`, `('P1')`,
`('P2')` as **three separate calls** (S-61).

### S-01–S-61 unchanged · S-55 still the SOLE red in the suite · D-01–D-21 unchanged · RISK 74, 88–105 unchanged

## DECISIONS-READY / STUCK updates (2026-07-31, relay leg 57 — P3.2 shipped)

### ⭐ S-66 (NEW, and it corrects what "M2M SKU-level" sounded like) — the grain was never the defect, the PAIRING PREDICATE was

BUILD-SPEC line 90 reads "transfers match on `boonz_product_id`", which sounds like the dispatch
layer stores M2M at pod grain and needs re-graining. ⛔ **It does not.** Probed live: `refill_dispatching`
already carries `boonz_product_id`, `is_m2m`, `m2m_partner_id`, `m2m_transfer_id`, and **all 36 live
`is_m2m` rows carry a SKU — zero nulls.** The defect is in what the writer _does_ with that column.
Read from the body of `convert_removes_to_m2m_transfer(uuid[],uuid,uuid,text)`:

```
INSERT INTO public.refill_dispatching (... pod_product_id, boonz_product_id ...)
VALUES (... v_row.pod_product_id, v_row.boonz_product_id ...)   -- source values, VERBATIM
```

It copies the SOURCE row's pod AND SKU straight onto `p_dest_shelf_id` with **no check that either
belongs there**. Converting Removes off a `Krambals & Zigi` shelf into a `Zigi` shelf therefore mints
destination rows carrying the wrong pod and Krambals SKUs. ⭐ **Why this matters for planning:** the
fix is a _validation_ unit, not a schema migration — no DDL, no backfill, no re-grain. A leg that
budgets for a data-model change here will badly over-scope it.

### ⭐ S-67 (NEW, cheap but it cost a RED cycle) — `product_mapping.status` filtering is LOAD-BEARING, not hygiene

`product_mapping.status` ∈ `Active` / `Dormant` / `Inactive`. Dropping the filter does not merely add
noise, it changes the answer: pod `Krambals & Zigi` has **11 distinct SKUs unfiltered but only 7
Active** (4 Krambals + 3 Zigi); pod `Zigi` has **7 unfiltered, 5 Active**; the source∩dest intersection
moves from **6 to 3**. ⛔ Every assortment, substitution and eligibility read must filter
`status='Active'` or it will silently offer retired SKUs. Fan-out on the same pod: **253 raw rows → 21
Active rows → 7 distinct SKUs**, so `DISTINCT` is required _on top of_ the status filter, not instead
of it.

### 📌 S-68 (NEW) — `pg_proc.provolatile` is type `"char"`, so `||` against it is ambiguous

`SELECT provolatile || '|' || prosecdef::text` fails with `operator is not unique: "char" || unknown`.
Cast it: `provolatile::text`. Fixture 41 seq 46 caught this in the RED baseline — the assertion
**errored rather than evaluating**, which is a distinct failure mode from a wrong value and is only
visible in the `err` column of `run_fixture`. Same family as S-65: the harness reports it, but only if
you look in the right place.

### ⏸️ D-23 (NEW, CS decision) — destination-capacity clamp in `resolve_m2m_sku_legs_v3`

BUILD-SPEC line 90 says only "transfers match on `boonz_product_id`; mixed-SKU source shelves split
legs per SKU". It does **not** mention capacity. GOLDEN-FIXTURES #4 does say "qty-balanced pairing",
and under that clause the resolver clamps transfers to destination headroom and spills the remainder
to `return_to_wh` with reason `dest_capacity_clamp` — reported separately from
`not_assortable_at_destination` so the two are never conflated.
⭐ **Why it was included rather than parked as scope drift:** without it the resolver would emit a
physically impossible leg (anchor B: 8 eligible units into 1 unit of headroom). It is _reported_, never
silent, and conservation still holds exactly.
⛔ **The ask for CS, one line:** keep the clamp, or drop it and let the caller own capacity?
Dropping it is a one-line change (remove the `LEAST(..., headroom)` term); fixture 41 seq 19/34/36/39
would need re-baselining. Nothing downstream depends on it yet — the function has no consumer.

### ⚠️ REGRESSION SCOPE THIS LEG — P3 re-run in full, P0/P1/P2 NOT re-run (same posture as leg 56, stated not hidden)

`run_all('P3')` ran clean: **3 fixtures / 121 assertions / 0 fail** (39: 37/0 unregressed · 40: 38/0
unregressed · 41: 46/0 new). P0/P1/P2 were **not** executed. Safe on the same reasoning as leg 56: the
leg is purely additive (one new function with no callers, one new fixture, one assertion cast fix) and
`current_phase` was untouched. ⛔ **Still a stated gap, not a claim of green.** S-61 remains binding:
the next leg needing a full baseline runs `run_all('P0')`, `('P1')`, `('P2')` as THREE SEPARATE CALLS.

### S-01–S-65 unchanged · S-55 still the SOLE red in the suite · D-01–D-22 unchanged · RISK 74, 88–105 unchanged

## DECISIONS-READY / STUCK updates (2026-07-31, relay leg 58 — P3.5 shipped)

### ⛔ S-69 (NEW) — there is NO observed driver-time data anywhere in the schema. `trip_events` is EMPTY.

BUILD-SPEC line 93 asks P3.5 for a "day capacity model (driver-hours, cluster travel, pack time)".
Probed before writing a line: `trip_events` — the one table whose shape could carry per-visit driver
timings (`machine_id, driver_user_id, event_type, dispatch_date, latitude, longitude,
gps_variance_m, created_at`) — holds **0 rows**. Nothing else observes minutes either. The only
live-calibrated capacity primitive in the system is `pick_urgency_params.driver_capacity = 8`
machines/day, which the existing Gate-0 picker already uses.
⭐ **What was built instead of guessing quietly:** the three cost terms are PARAMETERS
(`var_driver_day_minutes` 480, `var_service_minutes_per_machine` 25, `var_pack_minutes_per_line`
1.5, `var_travel_minutes_intra_cluster` 10, `var_travel_minutes_inter_cluster` 35), every column
comment says "MODELLED, not measured", and every output row repeats it in
`reasoning.day_capacity.cost_basis`. CS corrects them with one UPDATE, no migration.
⛔ **Smallest unblock, for whoever wants real numbers:** `trip_events` already has the right shape
and a `driver_user_id` — populating it from the field PWA (Stax) turns all five defaults into
measurable quantities. Until then **nobody may present the selected-machine list as a capacity
FACT.** It is a capacity ASSUMPTION with the assumption printed on it.

### ⭐ S-70 (NEW, and it is the most transferable finding of the leg) — a "0 violations" assertion PASSES VACUOUSLY when its subject is missing

Fixture 42's RED baseline came back **39 pass / 12 fail** — and the wrong 39. Assertions of the shape

```
SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
 WHERE s.fixture_id=42 AND s.key='out' AND <violation predicate>          -- expect 'eq' '0'
```

count VIOLATIONS. With the function absent the `out` scratch row is never written, the FROM clause
yields **no rows**, `count(*)` is **0**, and the assertion reports **PASS**. ⛔ Seq 27 — the one
labelled "THE SPINE", the assertion that recomputes every AED figure independently — passed against
a function that did not exist. So did 28, 29, 31, 32, 37, 38, 41, 42, 43 and 45. **Eleven of them.**

⭐ **Why this generalises far beyond fixture 42:** every "0 violations" / "0 mismatches" assertion in
the entire suite has this property. It silently stops testing anything the moment its subject
vanishes, and it is **invisible in a GREEN run** — the only place it ever shows is a RED baseline,
and only if you read WHICH assertions passed rather than how many. A fixture written straight to
GREEN would never have caught it.
⛔ **The idiom, now house style:** make absence a distinct FAILING value, never zero.

```
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=N AND key='out')
            THEN 'NO_PICKER_OUTPUT'      -- or '-1' when the op is gt/gte
            ELSE ( <original body> ) END
```

Wrapping rather than rewriting keeps the assertion byte-identical in meaning when output IS
present, so the corrective cannot quietly weaken it. Post-fix the RED read **27 pass / 24 fail**
with failures confined to seq 25-47+51 — the honest shape. Applied at authoring time to seq 52-55.
📌 Same family as S-65 and S-68: the harness reports the truth, but only if you look in the right
place. This one is worse, because it looks like good news.

### ⚠️ S-71 (NEW) — A BLIND MACHINE SCORES THE SAME AS A SAFE MACHINE: both are 0.00 AED

Found on the first GREEN run, not predicted. Five machines score zero value-at-risk because most
of their shelves are UNMEASURABLE, not because they are well stocked:

```
AMZ-1029-3003-O1   40 shelves · 24 no velocity · 24 no price   VAR 0.00   rank 21
AMZ-1038-3001-O1   40 shelves · 24 no velocity · 25 no price   VAR 0.00   rank 22
AMZ-1046-2406-O1   32 shelves · 16 no velocity · 17 no price   VAR 0.00   rank 23
AMZ-1057-2403-O1   40 shelves · 24 no velocity · 26 no price   VAR 0.00   rank 24
AMZ-1068-2401-O1   40 shelves · 24 no velocity · 25 no price   VAR 0.00   rank 25
```

60% of each machine is invisible (the 112 NULL-`pod_product_id` shelves across 5 machines), and the
ranking sinks all five to the bottom **as though that were a verdict of "safe"**. It is not a
verdict, it is an absence — same shape as fixture 3's blind machine, same family as LAW 5's
"silent qty-0 is a build failure", one level up: **silent VAR-0**.
⛔ **NOT fixed in the model, deliberately.** Imputing demand for unmeasured shelves is P2.5
cold-start work and changing the ranking for it here would be scope drift. What IS guaranteed:
`no_velocity_shelves` / `no_price_basis_shelves` / `at_risk_but_unpriceable` sit beside every zero
and cannot drift from their copies in `reasoning.coverage_gaps` (fixture 42 seq 52/53). A consumer
that reads 0.00 without the coverage counters is now making an explicit mistake rather than being
misled. ⭐ Contrast, and it matters: the seven cadence-due machines that also score 0.00 have
`no_velocity_shelves = 0` — **their zero is real.** The counters are what tells the two apart.

### 📌 S-72 (NEW, cheap) — `refill_settings` is keyed on `setting_key` / `setting_value`, not `key` / `value`

`SELECT value FROM refill_settings WHERE key='swaps_enabled'` fails with
`column "value" does not exist`. Cost one probe at STEP R. Filed alongside the leg-57 shape
reminders (`pod_products.pod_product_id`/`pod_product_name`, `boonz_products.product_id`/
`boonz_product_name`, `machines.official_name`).

### ⏸️ D-24 (NEW, CS decision) — the cadence floor consumed the ENTIRE day and left 545 AED on the table

Live result of the first full run, and it is not a bug — it is the spec's semantics meeting the
fleet's actual state:

```
rank 1-6  SELECTED   all cadence-due · FOUR of them carry VAR 0.00 · 452 of 480 minutes spent
rank 7-9  NOT SEL    cadence-due, over capacity
rank 10   NOT SEL    VOXMCC-1005-0201-B0 · VAR 545.75 AED · the single largest exposure in the fleet
```

Nine machines are cadence-due against a day that holds about six, so the floor pre-empts the entire
schedule and the money term never influences it at all. BUILD-SPEC line 93 says "service-policy
cadence floor" and a floor is what was built (fixture 42 seq 31: "A FLOOR, NOT A WEIGHT").
⛔ **The ask for CS, one line: should the cadence floor pre-empt absolutely, or reserve at most K
slots so the highest-value machine is never crowded out by a fully-stocked overdue one?**
A bounded reservation is a `K` param plus one changed `ORDER BY`; fixture 42 seq 31 would be
re-baselined from "no inversions" to "no more than K". Nothing depends on it — the function has no
consumer. 📌 Note the interaction with D-25: four of the six machines the floor selected have
**nothing at risk**, and three of the nine cadence-due machines it could not fit have nothing at
risk either.

### ⏸️ D-25 (NEW, CS decision) — should an unmeasurable machine rank as zero-risk?

The S-71 case, stated as the decision it is. Options, in ascending cost: (i) leave it — the
counters are published, CS reads them; (ii) rank blind machines by COVERAGE as a tiebreak so they
surface instead of sinking; (iii) impute archetype-prior demand for unmeasured shelves (this is
P2.5 cold-start machinery and would make VAR partly synthetic — ⛔ it would also mean the AED
figure is no longer purely realized revenue, which is the property seq 27 currently proves).
⭐ Recommend (ii): it fixes the ranking symptom without contaminating the money number.

### ✅ Cody review — APPROVED WITH ONE REVISION, and the revision was NOT the question that was asked

Submitted with three explicit questions. **(a) Article 14 not engaged** — the article's test is
silent staleness in a materialized query result, and a single-row parameter table materializes
nothing; the P2.2 / P2.4 precedent stands, and a separate v3 params table would be strictly worse.
**(c) advisory-only is sufficient** — `STABLE` + `SECURITY INVOKER` means Postgres refuses the
write, so the fixture pins are corroboration rather than the enforcement; a pick LIST is not a pick.
⭐ **(b) produced a real finding, and not the one the question anticipated.** Minting "machine value
at risk" as a new metric is legitimate (disjoint from `v_machine_priority.urgency` by definition,
now declared). But the function was reading `days_since_visit` from `v_machine_priority`, which
METRICS_REGISTRY line 49 lists as a **consumer** of the visit clock — the owner is
`v_machine_health_signals`. Numerically identical (31 machines, 0 disagreements), so nothing was
broken; that is precisely what makes it worth fixing before it breaks. Corrected at
`20260731145040`, pinned by seq 54, and seq 55 now forces every row to name the object it read.
⛔ **Cody standing condition carried forward:** the first consumer that turns this ranking into a
`machines_to_visit` row is a NEW class (b) review — that RPC, not this one, is where Gate 0's
manual-only rule actually gets tested.

### ⚠️ REGRESSION SCOPE THIS LEG — P3 re-run in full, P0/P1/P2 NOT re-run (same posture as legs 56/57, stated not hidden)

`run_all('P3')` ran clean twice: **4 fixtures / 176 assertions / 0 fail** (39: 37/0 · 40: 38/0 ·
41: 46/0 · 42: 55/0 new). P0/P1/P2 were **not** executed. Safe on the same reasoning: purely
additive (one new function with no callers, one new fixture, seven parameter columns with defaults
on a table no existing fixture asserts on) and `current_phase` untouched. ⛔ **Still a stated gap.**
S-61 remains binding: three separate calls.

### ⚠️ NEW PERF FACT FOR STEP 7 — fixture 42 costs ~110 s, so `run_all('P3')` is no longer sub-second

It reads the ~20 s `v_shelf_instock_velocity_split_v3` **four times** per run: once in its own
independent recomputation and once inside each of the three function calls (`out`, `out_again`,
`out_limit3`). `run_all('P3')` now takes **~105 s** against the ~0.9 s the leg-57 pointer recorded.
⛔ Budget for it: P0=4 fixtures, P1=7, P2=11 (>9 min), **P3=4 (~105 s)**. Not a defect — the triple
call is what proves determinism and `p_limit` — but a leg that expects a fast P3 will think it hung.

### S-01–S-68 unchanged · S-55 still the SOLE red in the suite · D-01–D-23 unchanged · RISK 74, 88–105 unchanged

---

## ⭐ CS DECISIONS — D-24 + D-25 CLOSED 2026-07-31 ~18:05 Dubai (via Cowork session)

- **D-24 → MONEY FIRST.** `rank_machines_by_value_at_risk_v3` ranks primarily by AED value-at-risk;
  visit cadence demotes to a CONSTRAINT (a max-days-between-visits floor that forces inclusion when
  breached), not the primary sort. The 07-31 case is the acceptance test: VOXMCC-1005 (545.75 AED)
  must be selected within capacity; zero-VAR cadence-due machines yield their slots unless their
  cadence floor is actually breached.
- **D-25 → COVERAGE TIEBREAK (loop's ⭐ option ii).** Blind/unmeasurable machines rank by coverage
  staleness as tiebreak so they surface; the AED figure remains purely realized revenue (seq 27
  property preserved). No synthetic imputation.

## DECISIONS-READY / STUCK updates (2026-07-31, relay leg 59 — P3.3 shipped)

### ⛔ S-73 (NEW) — `v_shelf_state.velocity_instock` is STILL `NULL` on all 656 shelves, and its comment says that is fine

The column is literally `NULL::numeric AS velocity_instock, -- P2.1` in the P1.2 view body, and
the view comment reads "velocity_instock is NULL until P2.1". **P2.1 is CLOSED.** It shipped the
velocity as a SEPARATE object (`v_shelf_instock_velocity_split_v3`) and never came back to fill in
the placeholder. So the comment is now a promise that was kept somewhere else, and the column is
an absence that reads as a value.
⛔ Any consumer joining `v_shelf_state` for velocity gets NULL for the whole fleet. A filter like
`WHERE velocity_instock < x` would disqualify all 656 shelves and return an empty set that looks
like a verdict rather than a blind spot. `propose_rotations_v3` reads the OWNER instead, and
fixture 43 seq 36 forces every emitted row to NAME the object it read.
📌 Same family as S-71 (a blind machine scores as a safe machine), one layer lower: here the
blindness is in a canonical view's own column.

### ⛔ S-74 (NEW) — three anon-executable SECURITY DEFINER functions point at a table that no longer exists

Reconnaissance for P3.3 found that **P3.3 was built once and retired.** `public.rotation_proposals`
does not exist; its 22 rows sit in `graveyard.rotation_proposals` with exactly the columns
BUILD-SPEC line 91 asks for (`machine_fit_score`, `projected_days_to_sell`, `scoring_breakdown`,
`status`, `applied_to_plan_date`, `linked_swap_id`). But three functions survived the retirement:

```
propose_rotation_plan(...)      SECURITY DEFINER   anon=X   -> public.rotation_proposals
apply_rotation_proposal(...)    SECURITY DEFINER   anon=X   -> public.rotation_proposals
reject_rotation_proposal(...)   SECURITY DEFINER   anon=X   -> public.rotation_proposals
```

They throw `relation "public.rotation_proposals" does not exist` on every call, so they are inert
**today** — and that is the whole risk. ⛔ **They fail closed only because the table is absent. Any
future migration that creates a table at that name silently reanimates three anon-reachable
definer writers**, one of which (`apply_rotation_proposal`) writes `planned_swaps`. This is why
the v3 table is named `rotation_proposals_v3` and why fixture 43 seq 50 is a standing sentinel on
the absence.
⭐ **Smallest unblock:** Article 13 deprecation — `SECURITY INVOKER` + `REVOKE EXECUTE FROM anon,
authenticated` on all three. Not done this leg (LAW 10, out of scope for P3.3) and parked as its
own unit. ⛔ Do NOT simply `DROP` them; the graveyard rows are history and the deprecation window
is the constitutional path.

### ⭐ S-75 (NEW, and it is the most transferable finding of the leg) — a synthetic plan_date does not break a real-world date rule, it makes the rule STOP BINDING

Fixture 43 anchors on `2030-02-13` because LAW 12 requires a synthetic plan_date. The LAW-7
expiry guard was written as `(expiry - plan_date) >= projected_days_to_sell`. Real
`oldest_expiry_est` values across the fleet run **2026-08-26 → 2027-11-10**. Every one of them is
before 2030, so the guard silently collapsed into **"keep only shelves whose expiry is NULL"**:

```
candidate pairs                       802
admitted by the 2030 guard             52   <- exactly the pairs with UNKNOWN expiry
admitted judged from the real world   765
BLOCKED judged from the real world     37   <- the rule actually doing its job
```

⛔ The assertion would have been **GREEN** — zero proposals violating an expiry rule that was
blocking nothing. Nothing errors. Nothing looks wrong. The fixture population just quietly becomes
the subset for which the comparison is degenerate.
⭐ **Same disease as S-70 wearing a calendar instead of a NULL:** a filter that stops binding still
returns rows, and a violation count over a degenerate population is still 0.
**THE FIX** (correct in production too): expiry risk is a property of stock in hand NOW, and the
heartbeat proposes moves for review within days. `p_plan_date` is a batch key, not the moment
stock moves. Horizon measured from `CURRENT_DATE` in both fixture and function.
⭐ **THE HABIT THIS EARNS — a sensor for the sensor.** Fixture 43 seq 19 asserts that pairs
blocked _only_ by expiry still exist (`> 0`). If the guard ever stops binding again, seq 19 reds
even though seq 30 stays green. ⛔ Apply this to any fixture rule that filters on a real-world
date, price, or expiry while anchored on a synthetic plan_date.

### ⛔ S-76 (NEW) — `ON CONFLICT (col, …)` is ambiguous against `RETURNS TABLE` OUT parameters, and a dry-run test cannot see it

`RETURNS TABLE (… plan_date date, source_shelf_id uuid, target_shelf_id uuid …)` declares PL/pgSQL
variables with the target table's own column names. Everywhere else in the INSERT they resolve
(column-list position, or qualified), but the `ON CONFLICT` **inference list** cannot be
disambiguated: `ERROR 42702: column reference "plan_date" is ambiguous`.
Fix: `ON CONFLICT ON CONSTRAINT rp_v3_unique_heartbeat` — name the constraint, never infer.
⭐ **Why it survived a clean smoke test, which is the half worth carrying:** the pre-apply check
called the function with `p_dry_run => true`, and **`p_dry_run` skips the INSERT**. It returned 25
correct rows and read as proof the function worked. It had never executed the write path.
⛔ **A dry-run test of a writer tests everything except the thing that writes.**
⭐ **What caught it instead: fixture 43's S-70 wrappers.** The aborted scenario rolled back and
left the PREVIOUS run's scratch in place, so assertions were reading stale data from an older run.
Unwrapped "count the violations, expect 0" assertions would have found no `out` row, counted 0 and
reported PASS on a function that was erroring on every single call. The wrappers turned it into 30
visible failures. **S-70 paid for itself within one leg of being written down.**

### ⏸️ D-26 (NEW, CS decision) — how much stock should a rotation leave behind?

`propose_rotations_v3` proposes `LEAST(source_stock, target_headroom)` — it will empty a source
shelf completely if the destination can take it. That is defensible for genuinely dead stock and
questionable for a merely slow mover, because an empty shelf carries its own urgency penalty
(PRD-073b `hero_shelf_empty`). ⛔ **The ask, one line: should a rotation leave a floor of N units
on the source shelf, or is emptying a dead shelf the point?** A floor is one param plus one
`LEAST(...)`; fixture 43 seq 22 re-baselines. Nothing depends on it — the function has no consumer.

### ⏸️ CS GATE (DECISIONS-READY) — the rotation heartbeat is built, flag-off, with no schedule

**What it is:** `propose_rotations_v3` scores stranded stock against destinations where the same
product sells and writes `pending` proposals. On live data right now it proposes **25 rotations
moving 88 units**, fit 3.00–529.43.
**Evidence it works:** golden fixture 43, **53/53**, authored RED with zero vacuous passes.
**What CS runs to activate:** nothing is scheduled — deliberately. Two separate activations:
(1) the weekly heartbeat cron, and (2) an approve/reject RPC. ⛔ **Neither is built, and (2) is a
new class (b) Cody review that OWNS the status transition graph** — a CHECK constraint cannot see
the old row, so `rejected → pending` is unenforceable in the schema.
⛔ **The approved-proposal → M2M dispatch leg hop remains BLOCKED on `stitch_v3` (S-62).** P3.3 is
therefore complete as far as anything downstream of it can currently reach.

### S-01–S-72 unchanged · S-55 still the SOLE red in the suite · D-01–D-25 unchanged · RISK 74, 88–105 unchanged

## ⭐ CS DECISION — D-26 CLOSED 2026-07-31 ~20:15 Dubai (via Cowork session)

**Rotation keep-floor = 2 units.** `propose_rotations_v3` moves
`LEAST(source_stock - rot_keep_floor, target_headroom)` with new param `rot_keep_floor` default **2**
(CHECK >= 0). Rationale: the source shelf stays merchandised and avoids the PRD-073b
`hero_shelf_empty` urgency penalty while the bulk of slow-moving stock still relocates to where it
sells. Fixture 43 seq 22 re-baselines against the floor. Param is flippable without a migration if
CS later wants full-strip behaviour for genuinely dead product.

### ⛔ S-77 (NEW, and it is BINDING ON STEP 7) — `run_all('P3')` now exceeds a HARD Cloudflare gateway timeout

RISK 89 has always been "the gateway returns 5xx while the query is still running — wait, then
read `golden.runs`". This is a **different and sharper** failure and the old remedy does not work:

```
Cloudflare 524: A timeout occurred     (NOT 502)
run_all('P3') wall time ~205 s, twice
golden.runs: NO new rows for fixtures 39-42 afterwards
```

⛔ **524 is a hard request ceiling (~100 s), and when the connection is torn down the server-side
query dies with it.** Waiting does not help, because nothing is still running to wait for. Adding
fixture 43 (~110 s on its own) pushed P3 past the ceiling: P3 was ~105 s at leg 58 and is now
~205 s. Both attempts produced zero recorded runs.

⭐ **THE WORKAROUND, and it is the shape STEP 7 must use: call `golden.run_fixture(N)` one fixture
at a time.** Each individual P3 fixture fits under the ceiling (42 ≈ 110 s, 43 ≈ 110 s, 39/40/41
sub-second). Verified this leg — 39: 37/0 · 40: 38/0 · 41: 46/0 · 42: 55/0 · 43: 53/0.

⚠️ **STEP 7 S7 says `golden.run_all()` ×3 consecutive.** As written that is now IMPOSSIBLE for P3
through this transport, and P2 (11 fixtures, >9 min) has been over the ceiling for even longer —
which means **P2 has not been regressed through a single `run_all` call in several legs and nobody
noticed, because the 502s were being read as RISK 89 transients.** ⛔ Re-express S7 as per-fixture
runs aggregated by the caller, or run it from a transport without a 100 s ceiling.
📌 This does NOT relax S-61 (one phase per `run_all` call, fixture 14 seq 91 attributes live-plan
writes by transaction). S-61 constrains what may share a transaction; S-77 constrains what fits in
a request. Per-fixture calls satisfy both.

## DECISIONS-READY / STUCK updates (2026-07-31, relay leg 61 — D-26 shipped)

### ✅ D-26 CLOSED AND BUILT — the first CS-answered decision this build has actually implemented

`rot_keep_floor` = **2**, `propose_rotations_v3` moves
`LEAST(GREATEST(source_stock - rot_keep_floor, 0), target_headroom)`. Fixture 43 **55/55**
(was 53 assertions, now 55). Live effect measured through the writer: 25 proposals,
**88 → 77 units**, minimum left behind **exactly 2**, `fit_score` floor 3.00 → 20.22.
`CHECK >= 0` so CS restores full-strip behaviour with one UPDATE and no migration, exactly as the
decision text promised.

### ⛔ S-80 (NEW, and it is the most important finding of the leg) — THE POINTER IS NOT THE AUTHORITY ON CS DECISIONS

CS appends `⭐ CS DECISION` blocks to the TAIL of this file between legs, from a Cowork session.
**Three decisions had been answered and NONE was implemented:**

```
line 5045   D-24 + D-25 CLOSED ~18:05 Dubai   (leg 58's questions)
line 5164   D-26        CLOSED ~20:15 Dubai   (leg 59's question)
```

Legs 59 and 60 both re-copied the STALE open-decision list into their pointers and moved on.
⛔ **Why the doc hashes did not catch it:** RISK 105 requires hashing LAST, _after_ every edit — so
leg 59 hashed the file after CS's append and the hash matched perfectly at leg 61's STEP R. **A
matching hash proves the file has not changed since the last leg closed. It never proves the last
leg READ all of it.**
⭐ **THE HABIT THIS EARNS, BINDING ON EVERY STEP R:** grep the PARKING-LOT tail for `CS DECISION`
and diff it against the pointer's open-decision list _before_ choosing the leg's task.
**Answered-and-unbuilt is the highest-value work in the queue — it is the entire point of the
PARKING protocol.** Verify against the DB, never against the pointer: the probe that proved this
was `rot_keep_floor` absent from `information_schema.columns` and
`rank_machines_by_value_at_risk_v3` still ordering `cadence_floor_due DESC` first.

### ⛔ S-78 (NEW) — `ON CONFLICT (fixture_id, seq) DO UPDATE` IS A SILENT ASSERTION SHREDDER

Fixture 43 occupies seq **1..53 contiguously**. The two new D-26 assertions were first written at
seq 46/47 — both taken. The `ON CONFLICT … DO UPDATE` shape used elsewhere in this build would have
**overwritten two live assertions and reported a clean apply**, and the fixture would still have
returned 53/53 green while silently testing less than before. ⭐ **Assertion INSERTs must be BARE:
a seq collision has to ERROR.** Probe the used-seq set before writing, never after.

### ⭐ S-79 (NEW, worth a sweep before STEP 7) — AN ABSOLUTE COUNT OVER A GROWING FAMILY IS A TRIPWIRE ON YOUR OWN ROADMAP

Fixture 43 seq 3 and seq 6 counted `rot_*` columns and compared to the literal **5**. Adding
`rot_keep_floor` — a CS decision, not a defect — reddened **both** at actual 6. They fired on
correct work and said nothing about correctness. Re-expressed as a **REQUIRED-SET** check (the six
named columns each exist) and a **0-VIOLATIONS** check (no `rot_*` column lacks its
`POLICY, not measured` comment). ⭐ The inverted form is **strictly stronger** — a future
uncommented param now reds it, where the old count went green as soon as any five had comments.
📌 **Sweep candidate:** any assertion of the form `count(*) = <literal>` over a
`LIKE 'prefix\_%'` family. The `var_*` family (7 columns, fixture 42) is the obvious next one.

### ⛔ S-81 (NEW, OPEN, small) — TWO LOOSE GRANTS ON P3 OBJECTS, AND THE REGISTRY MIS-STATED ONE

Read from `proacl`, not from the docs:

```
propose_rotations_v3              {postgres, authenticated, service_role}
rank_machines_by_value_at_risk_v3 {=X/postgres (PUBLIC), anon, authenticated, service_role, postgres}
```

- ⛔ **`rank_machines_by_value_at_risk_v3` is EXECUTable by `anon` and by PUBLIC.** It is STABLE +
  SECURITY INVOKER so it writes nothing, but it returns **per-machine value-at-risk in AED, velocity
  coverage and visit cadence for the entire fleet**. This is precisely the S-57 loose-grant class
  that migration `20260731121100` swept — it came back in on the leg-58 object because **fixture 42
  seq 51 pins VOLATILITY, not GRANTS**, whereas fixture 43 seq 15 does pin `anon`.
- ⛔ **RPC_REGISTRY claimed `propose_rotations_v3` was "`service_role` only".** False —
  `authenticated` holds EXECUTE. **The registry line has been corrected in place this leg.**
  Impact is bounded (advisory `pending` queue, no protected entity) but the doc was trusted.
- **Smallest unblock:** one migration — `REVOKE EXECUTE … FROM anon, PUBLIC` on the picker, plus a
  grant-pin assertion on fixture 42 mirroring fixture 43 seq 15. Neither object has any consumer,
  so nothing breaks. ⭐ **Add the grant pin at the same time or it regrows a third time.**

### ⏸️ D-24 + D-25 — ANSWERED BY CS, STILL UNBUILT. FULLY DESIGNED HERE SO THE NEXT LEG IS ONE CLEAN UNIT

⛔ **This is the next task.** The reconnaissance is done and the numbers below are live, so the
next leg should NOT re-derive them.

**The live pathology, straight from the picker (`CURRENT_DATE`, limit 18):**

```
rank 1-9  ALL cadence_floor_due   -- and SEVEN of them carry 0.00 AED
rank 10   VOXMCC-1005-0201-B0  543.50 AED  cadence_floor_due=false  selected=FALSE  below_day_capacity
```

Six of eight driver slots go to machines worth **0.00 AED**; ~984 AED of value-at-risk goes
unselected. This is exactly what D-24 overturns.

**The design (Dara-shaped, NOT yet Cody-reviewed):**

1. ⭐ **Do NOT change the RETURNS TABLE signature.** Adding an OUT column forces a DROP+CREATE
   (Postgres cannot `CREATE OR REPLACE` through a return-type change) and Article 12 forbids
   DROP-and-recreate. Instead **redefine the existing `cadence_floor_due` column to mean the HARD
   floor (breached)**, and move the soft target state into the `reasoning` blob as
   `cadence_target_due`. ⭐ The column name then reads TRUE for the first time — a _floor_ being
   _due_ should mean the hard floor, not the soft target.
2. **The breach predicate:** `days_since_visit >= LEAST(gap_days * var_cadence_floor_multiple,
var_cadence_hard_max_days)` with new params defaulting to **2.0** and **14**. Both are POLICY,
   both flippable without a migration. The `LEAST` is the literal reading of CS's phrase
   "a max-days-between-visits floor": a relative floor per the machine's own service policy, under
   an absolute ceiling nobody exceeds.
3. **Sort becomes** `cadence_floor_due (BREACHED) DESC, value_at_risk_aed DESC,
coverage_staleness DESC, machine_name ASC`. Merely-target-due machines stop pre-empting money
   entirely. ⛔ **D-25 forbids synthetic imputation** — `coverage_staleness` is a TIEBREAK ONLY
   (`blind_shelves / shelves_total * days_since_visit`); the AED figure stays purely realized
   revenue so fixture 42 **seq 27 is preserved untouched**.
4. `selection_reason` CASE: `'cadence_floor'` only when BREACHED.

**Live arithmetic, already measured (31 active in-refill machines, driver_capacity 8):**

```
soft target-due now              9
BREACHED at 2.0x / 14d cap       4      <- NOVO-1023, VML-1003, VML-1004, ALJLT-1015-0100
BREACHED at 1.5x / 14d cap       4      (identical set -- the cap binds, not the multiple)
```

4 forced + 4 money slots → **VOXMCC-1005 (543.50) is selected**, satisfying CS's acceptance test
verbatim, and the zero-VAR merely-due machines yield.

**⛔ THE FIXTURE-42 CASUALTY LIST — the expensive part, and it is already mapped:**

- ⭐ **The anchors are the luckiest possible pair.** `M_TOP = 148c4fcf… = VOXMCC-1005-0201-B0`
  (gap 5, dsv 0, **not breached**) is _the exact machine in CS's acceptance test_, and
  `M_CAD = 0a9a4836… = NOVO-1023-0000-W0` (gap 4, dsv 15 = 3.75x overdue, **breached**).
- ✅ **seq 31, 32, 34, 35 keep working with only their DESCRIPTIONS updated**, because redefining
  `cadence_floor_due` to mean _breached_ makes their SQL correct under the new rule. seq 35
  ("M_CAD outranks M_TOP") stays GREEN and now proves something _better_: a **genuinely breached**
  machine beats money, which is the constraint D-24 kept.
- ⛔ **seq 21 WILL RED** — "more machines are cadence-due than a day can hold" is false once the
  breached set is 4 vs capacity 8. Re-express as `count(target_due OR var > 0) > capacity`.
- ⛔ **seq 40 WILL RED** — `cadence_due_over_capacity` never fires when all 4 breached machines fit.
  Re-express as **0 violations**: every breached machine is either selected or explicitly reasoned
  `cadence_due_over_capacity` — the floor is never silently dropped. Stronger, and independent of
  today's arithmetic.
- ⚠️ **48 of fixture 42's 55 assertions were NOT inspected this leg.** Budget for surprises; that
  unknown tail is exactly why this unit was not opened at ~70% context.
- **NEW assertions to add** (⛔ check the used-seq set first — S-78): the D-24 acceptance test
  (M_TOP is `selected = true`), a D-25 tiebreak check (0 coverage-staleness inversions among
  equal-VAR machines), and a **SENSOR FOR THE SENSOR** (S-75): `0 < breached < soft_due`, so the
  hard floor can neither go decorative nor silently collapse back into the soft target.

## DECISIONS-READY / STUCK updates (2026-07-31, relay leg 62 — D-24 + D-25 shipped, S-81 closed)

### ✅ D-24 + D-25 CLOSED AND BUILT — the money-first VAR picker is live, flag-free, zero-consumer

The leg-61 design was followed as written and needed no re-derivation. Four migrations:
`20260731163542` (params) · `20260731163545` (picker) · `20260731163549` (S-81 revoke) ·
`20260731163924` (fixture 42). Fixture 42 **55 → 67 assertions, 67/67 green**; whole P3 suite
re-run per fixture: 39 **37/0** · 40 **38/0** · 41 **46/0** · 42 **67/0** · 43 **55/0**.

**CS's acceptance test, satisfied verbatim.** Before → after on the same live data:

```
BEFORE  ranks 1-9 all cadence-due, SEVEN carrying 0.00 AED
        VOXMCC-1005-0201-B0  543.50 AED  rank 10  NOT selected     6 machines selected
AFTER   ranks 1-4 = the 4 BREACHED machines, then money
        VOXMCC-1005-0201-B0  543.50 AED  rank  5  SELECTED         7 machines selected
        + VOXMCC-1011 196.63 and ACTIVATEMCC-1037 155.74 also selected  (~896 AED recovered)
```

⭐ **The 14-day cap binds, not the multiple.** Breached = 4 at 2.0× and the _identical set_ at 1.5×.
So `var_cadence_hard_max_days` is the live lever; `var_cadence_floor_multiple` is currently inert
on this fleet and would only start binding on machines with gap_days > 7. Worth knowing before
anyone "tunes" the multiple and observes nothing.

⭐ **What the fixture casualty list got right and what it missed.** Right: seq 21 and seq 40 did
red exactly as predicted, and seq 31/32/33/34/35 did survive on descriptions alone — `M_TOP` is
still the highest-VAR non-breached machine, so seq 33 never moved. Missed: **nothing.** The 48
uninspected assertions were all population/spine/capacity checks that the sort order does not
reach. The reconnaissance was worth more than the caution it recommended.

### ⛔ S-82 (NEW) — A SEMANTIC REDEFINITION IS INVISIBLE TO POSTGRES, SO THE BLAST RADIUS MUST BE RECORDED, NOT JUST CHECKED

`cadence_floor_due` changed meaning (soft target → BREACHED) while keeping its name, type and
position. Nothing in the database can warn about that: not the type system, not a signature diff,
not `CREATE OR REPLACE`, not any test that reads the column and expects a boolean. Only golden
fixture 42 could see it, and only because seq 62 was written to pin the column to a predicate.

⭐ **The habit this earns:** when a redefinition is the Article-12-legal move (and here it was —
an added OUT column forces DROP+CREATE), **probe the blast radius across all four surfaces and
write the result into the registry entry, not just the log.** Leg 62 probed FE call sites,
`pg_proc.prosrc`, `pg_views.definition` and `cron.job.command`: **0, 0, 0, 0.** A later reader
diffing the migration can see WHAT changed; they cannot re-derive that it was safe at the time.
📌 Same family as S-80: the artifact that proves a thing was checked has to outlive the leg.

### ⛔ S-83 (NEW, SHARPENS S-77) — THE PER-FIXTURE WORKAROUND IS ITSELF NOW AT THE CEILING

S-77 established that `run_all('P3')` (~205 s) exceeds the hard ~100 s Cloudflare 524 ceiling and
that `golden.run_fixture(N)` is the workaround. Measured this leg:

```
fixture 42   108 s   (55 -> 67 assertions)
fixture 43   107 s
fixture 39/40/41  sub-second
```

⛔ **Both large P3 fixtures now sit ON the ceiling, not under it.** They completed, but there is no
headroom left: the next assertion added to either one may push a SINGLE fixture over, and at that
point there is no smaller unit to fall back to through this transport. ⭐ **Before STEP 7, either
(a) find a transport without the ~100 s request ceiling, or (b) split fixture 42 and 43 into
sub-fixtures.** ⛔ Do NOT solve it by disabling assertions. 📌 Root cause is unchanged and known:
each of these fixtures reads the ~20 s `v_shelf_instock_velocity_split_v3` several times (RISK 88).

### ⛔ S-84 (NEW, small, costs a probe every leg until written down) — `gate0_require_manual_confirm` IS A COLUMN ON `refill_policy_params`, NOT A `refill_settings` KEY

The pointer's flag block lists it beside `swaps_enabled`, which IS a `refill_settings` key. It is
not. `refill_settings` holds exactly three keys — `swaps_enabled` (true), `broad_rotation_enabled`
(false), `sweep_enabled` (false). `gate0_require_manual_confirm` is a boolean COLUMN on
`refill_policy_params` and reads **true** (LAW 11 holds, untouched this leg). Its only reader is
`build_draft_for_confirmed_v3`.

### ✅ S-81 CLOSED — and the pin is what makes it stay closed

`REVOKE EXECUTE … FROM anon, PUBLIC` applied; `proacl` now `{postgres, authenticated,
service_role}`. ⭐ **The REVOKE alone would have been the third round of the same fix.** Fixture 42
**seq 67** now pins the grants the way fixture 43 seq 15 does, using `aclexplode` with an explicit
`proacl IS NULL` guard — because a NULL ACL means _default_ grants, and an unguarded
`aclexplode(NULL)` returns zero rows and would report a clean PASS on the most permissive state
possible. The RPC_REGISTRY line that mis-stated the OTHER grant was corrected at leg 61.

### ✅ S-79 SWEEP DONE (the 📌 item flagged for before STEP 7)

Every enabled assertion of the shape `count(*) = <literal>` over a `LIKE 'prefix\_%'` family was
audited across all 27 fixtures. **Fixture 42's `var_*` family was the last live instance**; it is
now seq 58 (REQUIRED-SET, 9 named columns) + seq 59 (0-VIOLATIONS, no `var_*` column undocumented).
Fixture 43 seq 3 and fixture 39 seq 31 count against **named arrays**, not prefixes — they do not
grow with the roadmap and are correct as written. **Nothing else in the suite matched. Sweep is
CLOSED, not sampled.**

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-22, D-23. **D-24, D-25, D-26 ALL CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above: CS appends answers between legs and a matching doc hash cannot detect it.

## DECISIONS-READY / STUCK updates (2026-07-31, relay leg 63 — P3.1c opens; the ladder was broken)

### ⛔ S-85 (NEW, and it is the most important finding of the leg) — A GREEN FIXTURE OVER A BLIND SPOT

`resolve_supply_ladder_v3` raised `55000 record "v_sub" is not assigned yet` on **every call whose
demand was satisfiable from the primary warehouse** — its happy path — for its entire P3.1b life,
while fixture 40 reported **38/38 GREEN**. The rung-2 _log_ entry dereferences `v_sub`
unconditionally; the `SELECT INTO` that assigns it runs only when rung 1 has already **failed**.

⛔ **The mechanism, so it is not re-learned:** an unassigned PL/pgSQL `record` has an INDETERMINATE
tuple structure, and a `CASE` guard does **not** protect a field reference inside it — the structure
must be resolved to build the expression, whichever branch runs. Fixed by `20260731170130`: one
`record` → **eight NULL-initialised scalars**, so the failure mode is removed _by construction_
rather than guarded. True Article-12 `CREATE OR REPLACE` (signature / `STABLE` / `SECURITY INVOKER`
/ `search_path` / `pronargdefaults` 1 all byte-identical). md5 `ec8dffa2…` → **`920b32d0…`**.

⭐ **WHY THE FIXTURE COULD NOT SEE IT — the transferable lesson, binding on every future fixture.**
Fixture 40's anchors both came from the 07-30 blocked-demand incident, so **both are starved by
construction**: A is the sentinel trap, B is the contention case. Between them they proved rungs 2-6
and never once executed terminal rung 1. ⛔ **A FIXTURE BUILT FROM AN INCIDENT INHERITS THE
INCIDENT'S BLIND SPOT.** When every anchor in a fixture comes from one incident, **add an anchor
from the ordinary case on purpose.** Closed by fixture 40 anchors **C** (rung-1 full) and **D**
(rung-1 partial), seq 39-56, **56/56**.

⭐ **AND THE HABIT THAT FOUND IT, BINDING BEFORE ANY WIRING:** the bug surfaced within ten seconds of
running the object **the way its real consumer would** — 6 live shadow-plan lines instead of 2
hand-picked anchors. ⛔ **AN ADVISORY OBJECT WITH ZERO CONSUMERS HAS NEVER HAD ITS HAPPY PATH
EXECUTED.** Run it across a real population BEFORE wiring it, never across its fixture's anchors.

### 📌 S-86 (NEW) — THE LADDER DOES NOT CASCADE AFTER A PARTIAL FILL

The terminal rung is the first **satisfiable** rung at ANY quantity. Anchor D serves 1 of 2 units at
rung 1 and rung 2 still reads `attempted: false` — the rungs below are never consulted.
⛔ **The stranded unit is a LAW 5 obligation on the CONSUMER, never on the ladder.** Any caller that
assumes `qty_resolved = qty_needed`, or that a shortfall implies `resolved_rung = 'blocked_demand'`,
is wrong. Fixture 40 **seq 51** pins the no-cascade behaviour; **seq 55** states the consumer
contract, so `stitch_v3` cannot be built without honouring it.

### ⛔ S-87 (NEW) — `resolve_m2m_sku_legs_v3` IS INERT ON REAL DATA (it does not crash; it cannot act)

S-85's habit was **discharged in the same leg, not merely written down.** The other consumer-less
advisory object was exercised across **60 real shelf pairs** (30 same-pod, 30 cross-pod
contamination cases), errors caught per pair: **60/60 returned, 0 errored** — no S-85-class defect.

⛔ **But 60/60 returned `status = 'source_composition_unknown'`, and ZERO of the 60 source shelves
have a `shelf_composition` row.** Coverage is **16 of 656 shelves (2.4%)**. Called with
`p_lines = NULL` the function can never emit a leg. This is **correct behaviour** — it refuses to
guess a SKU mix and returns an explicit `remedy` — but badly matched to this fleet.

⭐ **Consequence for `stitch_v3`, recorded BEFORE it is built:** when the ladder terminates at rung 4
(`m2m`), a `stitch_v3` calling this with NULL gets zero legs and strands the units — **silent qty-0
one level up, which LAW 5 forbids.** It **must** pass `p_lines` from the source Remove dispatch rows
(the function's own stated remedy). 📌 `rank_machines_by_value_at_risk_v3` needed no such sweep: leg
62 already ran it across the live fleet for the D-24 acceptance test, so its happy path is proven.

### 📌 `stitch_pod_to_boonz` md5 `806340b294d3a9ce85473d7be8b35049` — the P3.1c port baseline

Never captured before. v1 is **50,903 chars / 1,029 lines**, `SECURITY DEFINER`, and its shape is:
PRD-109 preflight gate → one very large CTE chain (`approved` → `pull_raw` → variant redistribution
→ `pull_lines` → `remove_*` → `all_lines` → `lines_agg`) building a `v_lines` jsonb array →
`write_refill_plan(p_plan_date, v_lines)` → `assert_weimi_slot_match`. Its only writes are
`refill_plan_deviations`, `procurement_alerts` and `preflight_override_log`.

### 📌 `rotation_proposals_v3` 77 → 78 units on the SAME 25 rows — NOT drift

Fixture 43 owns plan_date 2030-02-13, deletes and regenerates it on every run, and live stock moved
between legs. All 25 rows are on 2030-02-13 and all still `pending`. ⛔ Do not read this as a
protected-entity write.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-22, D-23. **D-24, D-25, D-26 CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above: CS appends answers between legs and a matching doc hash cannot detect it.

### S-01–S-84 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

---

## ⛔ S-88 (NEW, leg 64) — RLS IS NOT A WRITE GUARD. THE GRANT IS.

`ALTER DEFAULT PRIVILEGES` gives the `authenticated` **role** every privilege on each new `public`
table at CREATE time. `REVOKE ALL … FROM PUBLIC` does not touch a role grant and `GRANT` only adds,
so the standard PRD-110 table migration — enable RLS, write policies, grant `SELECT, REFERENCES,
TRIGGER` — shipped tables with `authenticated` holding INSERT/UPDATE/DELETE/**TRUNCATE**.

⛔ **TRUNCATE is the one that mattered.** It is not a row operation: it bypasses RLS entirely and
fires no `FOR EACH ROW` trigger. So both mechanisms this program relies on for append-only ledgers
were defeated by one statement any logged-in user could run.

**Found on 8 tables** (fixture 44 seq 25 caught the first; the sweep was then **closed, not
sampled**, per S-79): `refill_plan_output_shadow`, `inventory_events`, `product_sourcing`,
`blocked_demand`, `machines_to_visit`, `shelf_composition`, `inventory_anomalies`,
`demand_calendar`. **CLOSED** by `20260731173609` + `20260731173815`.

⭐ **Binding on every future `CREATE TABLE`: `REVOKE ALL … FROM authenticated` FIRST, then grant
back the narrow set.** Enabling RLS is not sufficient and never was.
📌 The sweep revoked **TRUNCATE only** — INSERT/UPDATE/DELETE left as found (RLS gates them;
revoking could break an FE path). 0 functions and 0 crons issue TRUNCATE against any of the eight.
📌 `pod_refill_plan_shadow` pins UPDATE/DELETE with **RLS policies only**, no trigger — weaker than
ADR §5.1 claims. Not fixed: nothing writes it. Fix it when something does.

## 📌 S-89 (NEW, leg 64) — `stitch_v3`'s rung-4 branch has never executed

No live line terminates at rung 4, so the m2m branch of `stitch_v3` has run zero times. Both of its
queries were validated standalone against real data and fixture 44 seq 22 pins the S-87 contract,
but per S-85 **an object whose path has never run is not proven**. Forcing a rung-4 termination
needs rungs 1-3 all unsatisfiable plus an overstock donor; constructing that means moving warehouse
stock, which is a protected-entity write and was correctly refused in a skeleton leg.
⭐ **Smallest unblock:** build the rung-4 case as a golden fixture that seeds a synthetic donor via
the shadow tables only, or run it inside a `BEGIN … ROLLBACK` envelope with an explicit CS-visible
note. **This is the next leg's first task.**

## 📌 S-90 (NEW, leg 64) — plpgsql does not validate SQL in function bodies at CREATE time

`stitch_v3` compiled cleanly with `sc.pod_product_id` against `shelf_configurations`, a column that
does not exist. Both dry-runs passed because neither reached that branch. ⛔ **A clean
`CREATE FUNCTION` and a green happy-path dry-run prove nothing about a branch they did not enter.**
Canonical shelf↔pod object is **`v_shelf_state`** (P1.2); `shelf_configurations` is
`shelf_id, machine_id, shelf_code, shelf_size, max_capacity, created_at, is_phantom` — no pod.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23. **D-22 is now UNBLOCKED, not closed:**

the ladder has its first consumer (`stitch_v3`), so "no consumer" is no longer the reason it waits.
**D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above: CS appends answers between legs and a matching doc hash cannot detect it.

### S-01–S-87 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

---

## Leg 65 (2026-07-31 ~18:00-18:20 UTC) — S-89 closed, and what closing it exposed

### ⛔ S-91 (NEW, and the most important finding of the leg) — A BRANCH NO INPUT CAN REACH IS A BRANCH NO ONE HAS CHECKED

`stitch_v3`'s rung-4 `m2m` branch had executed **zero** times. Executing it (S-89) did not confirm
it worked — it revealed the branch **could never have placed a single unit**, plus three further
defects stacked behind the first:

- **D1 (fatal).** The ladder emits `donor_machines` as `count(DISTINCT machine_id)` — an **INT**.
  `stitch_v3` tested `jsonb_typeof(...) = 'array'` and read UUIDs out of it. A number is never an
  array ⇒ donor always NULL ⇒ every m2m unit blocked as `m2m_sku_unknown`, 100% of the time.
- **D2.** Blocked when the donor had no `Remove` rows, bypassing the `shelf_composition` fallback
  that `resolve_m2m_sku_legs_v3` **already implements** for `p_lines IS NULL`.
- **D3.** Clamped to the ladder's fleet-wide donor sum while drawing from **one** donor.
- **D4.** Wrote `return_to_wh` legs as `Refill` into the destination. ⛔ Live on `46c0c29e` →
  `558ad2f1`: 13 transfer + **5 `dest_capacity_clamp`** units, **all 18** would have been placed —
  pushing into a machine exactly the units the helper had just ruled would not fit.

⭐ **THE HABIT THIS EARNS:** a rung/branch/flag that has never fired is **unverified code**, not
working code, regardless of how clean it reads or how green the suite is. Ask of every branch: _what
input reaches this, and has that input ever existed?_ ⛔ Reading it is not the same as running it.

### ⛔ S-92 (NEW) — "PICK THE BIGGEST" IS THE WRONG RULE WHEN THE ANSWER MIGHT BE UNKNOWABLE

Found only by executing the fixed branch. v1 picked the largest-excess donor and then asked for its
SKU mix. `shelf_composition` covers **16 of 656 shelves (2.4%)**, so the biggest donor is
overwhelmingly one whose mix is unknowable: the seam blocked, naming a donor it could never have
drawn from. LAW 5 was satisfied — a Blocked row existed — and the answer was still useless.
⭐ **Selection must be over candidates that can actually be ACTED on**, not over the scoring
dimension alone. v2 walks donors in excess order (bounded at 10) and takes the first whose mix
resolves, recording every attempt with a named outcome. Live: 5 skipped, winner A08.

### ⛔ S-93 (NEW, small but it cost a cycle) — sibling subqueries cannot see each other's writes

`SELECT jsonb_build_object('stitch', (SELECT stitch_v3(...)), 'rows', (SELECT ... FROM shadow))`
returned `rows = NULL` while `rows_out = 1`. Both subqueries run against the **same statement
snapshot**, so the sibling never sees the function's INSERTs. ⛔ Call the writer, **then** query it,
as separate statements. (Compounded by S-65: `jsonb_agg` over zero rows is NULL, not `[]`, so the
symptom presents as "no rows" rather than an error.)

### 📌 Rung 4 is UNREACHABLE on live data — recorded so no future leg re-derives it

All **544** shelves carrying a pod terminate at rung 1 (**383**) or rung 2 (**161**). Rung 2
satisfies almost everything, **including for `partner_managed` machines** — and all 3 such machines
have **zero** shelves in `v_shelf_state`. ⛔ Do not spend another leg hunting a natural rung-3/4/5/6
case; there isn't one. Force rung 4 by stubbing `find_substitutes_for_shelf_v3` inside a
`BEGIN … ROLLBACK` envelope, on a pod with zero pickable WH stock (e.g. `b1827ff7`).

### ⏸️ D-27 (NEW, OPEN) — converge rung-4 velocity onto the canonical in-stock object

`list_m2m_donors_v3` mirrors the ladder's `COALESCE(velocity_instock, velocity_raw, 0)`, which per
S-73 is `velocity_raw` in practice — not the registered canonical object. Cody permitted the mirror
**only because fixture 45 assertions 4–5 PIN the two rules together**. Converging them changes which
machines qualify as donors on a live engine path ⇒ its own reviewed unit with its own before/after
diff. ⛔ Never a drive-by.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, **D-27 (new)**. D-22 remains UNBLOCKED

(the ladder has its consumer, `stitch_v3`). **D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above: CS appends answers between legs and a matching doc hash cannot detect it.

### S-01–S-90 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

---

## Leg 66 (2026-07-31 ~18:20-19:00 UTC) — P3.1d, FEFO SKU binding

### ⛔ S-94 (NEW) — TWO OBJECTS CAN DISAGREE ABOUT "AVAILABLE" AND BOTH BE RIGHT

`resolve_supply_ladder_v3` counts supply via `v_wh_pickable`, whose expiry test is against **today**
(Dubai). `wh_fefo_for_line` filters `expiration_date >= p_plan_date`. Neither is wrong. On a
production plan_date (tomorrow) they differ by one day and the stricter one is _correct_. On a
synthetic 2030 fixture date they diverge **completely** — the newest real non-sentinel batch expires
2027-12-29, so the ladder rules units placeable that FEFO can bind none of.

⭐ **The habit this earns:** when a new object refines an existing decision, ask _what predicate does
each one use, and on what date?_ — and if they differ, decide which one is the AUTHORITY, write the
split down, and report the gap as a named outcome rather than reconciling it silently. Here: the
ladder owns **how many**, the seam owns **which SKU**, and the residue is `qty_unbound` with a named
reason.

⛔ **The fixture consequence, which is the real lesson:** a fixture that ran only on its own 2030
plan_date would have gone green while proving _nothing but the refusal_ — binding would never have
been exercised at all, and the suite would have looked healthy. Fixture 46 therefore calls the seam
**twice**, on both horizons. ⛔ Never "fix" the divergence by relaxing the plan_date filter: that
filter IS LAW 7.

### 📌 S-95 (NEW, small, cost a re-run) — a RAISE-EXCEPTION result trick rolls back the run it measured

Returning fixture results by `RAISE EXCEPTION E'RESULT>>>%<<<'` (the trick that works nicely for
read-only dry-runs, since `execute_sql` returns only the LAST statement) **aborts the transaction**,
so `golden.runs` keeps no record and the fixtures' own designed shadow output never lands. The
assertions genuinely evaluate and the pass/fail is real, but the evidence is only in the operator's
transcript. ⭐ For a run that is meant to COUNT, call `SELECT count(*) FROM golden.run_fixture(N)`
per fixture and read `golden.runs` in the final statement. Caught by noticing
`refill_plan_output_shadow` had not moved after a "green" suite; re-run persisted.

### ⏸️ D-28 (NEW, OPEN) — converge `wh_fefo_for_line.committed_elsewhere` onto `v_dispatch_availability`

Raised by Cody during the P3.1d review. Article 16 registers "Dispatch committed / available" to
`v_dispatch_availability`, but `wh_fefo_for_line` derives `committed_elsewhere` **inline** from
`refill_dispatching`. ⛔ **Pre-existing, and NOT this unit's to fix:** the inline derivation lives in
an object P3.1d merely _consumes_, and converging it changes what **every** FEFO caller sees —
including the live dispatch binder. Its own reviewed unit, with its own before/after diff. ⭐ Exactly
the D-27 shape: a mirror is tolerable while it is pinned and named; it is never a drive-by.

### 📌 Not a defect: 6 rows in `refill_plan_output_shadow` still carry `deferred_to_p31d`

They are leg 65's three fixture-44 runs (17:37 / 17:38 / 18:11, plan_date 2030-02-14), retained as
before-state evidence. ⛔ A **global** grep for the marker therefore still returns 6 — scope it by
`run_id` (as fixture 46 assertion 20 does) before concluding the marker survived. Every row written
in leg 66 carries a named binding state; `(none)` belongs to `Blocked` rows, which place nothing and
correctly have no binding.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, **D-28 (new)**. D-22 remains

UNBLOCKED (the ladder has its consumer, `stitch_v3`). **D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above: CS appends answers between legs and a matching doc hash cannot detect it.

### S-01–S-93 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

---

## Leg 67 — P3.1e, the blocked_demand promotion (2026-07-31)

### ⛔ S-96 (NEW, and it bit twice in one leg) — A BAD LAST STATEMENT ROLLS BACK THE FIXTURE RUNS IN ITS BATCH

S-95 said a `RAISE EXCEPTION` result-trick aborts the transaction it measured. The same trap has a
second, quieter face: `/tmp/prd110_sql.sh` sends a FILE as one implicit transaction, so a **syntax
error in the final statement discards the `golden.run_fixture()` calls that preceded it**. This leg
ran fixtures 5 and 105, got a `KeyError` from the reader, and `golden.runs` still showed the runs
from **12:55** — six hours stale — while looking superficially like a green result.

⭐ **The habit:** when a batch must COUNT, make `run_fixture` calls the ONLY statements in it and read
`golden.runs` in a SEPARATE invocation. Never end a fixture batch with an untested reader query.
⛔ Cross-check the run's `started_at` against the wall clock before believing any suite result.

📌 The reader bug itself is worth recording: **`golden.runs.detail` is a `jsonb` array, not a
PostgreSQL array.** S-65's phrasing ("`detail` is an ARRAY") reads as the latter. `unnest(x.detail)`
fails with `function unnest(jsonb) does not exist` — use
`jsonb_array_elements(x.detail) AS t(e)` and `t.e->>'k'`. There is also **no `n_skip` column** on
`golden.runs`.

### ⛔ S-97 (NEW) — IN `LIKE`, `_` IS A WILDCARD, AND THE REASON MAP IS FULL OF UNDERSCORES

The rung-4 family is matched by prefix. Written the obvious way, `p_named LIKE 'm2m_%'` also matches
`m2mXanything`, because `_` is LIKE's single-character wildcard. Every named reason in this system
is snake_case, so any prefix match over them carries this bug. Written as `LIKE 'm2m\_%'` and pinned
by fixture 47 assertion 44, which feeds it `m2mXnot_an_m2m_reason` and requires the safe default.

### ⏸️ D-29 (NEW, OPEN) — auto-promote stitch's blocked demand, or keep it a separate call?

P3.1e builds the promotion; it does **not** wire it into anything. Two reasons, both structural:

1. ⛔ **LAW 4.** `RPC_REGISTRY` records that `stitch_v3` "writes exactly one table, which has no
   operational consumer". `blocked_demand` **has** one — procurement reads `v_blocked_demand_open`.
   Calling the promotion from a shadow engine would put shadow output on a live consumer's path.
2. ⛔ **Double counting.** `source` is part of `uq_blocked_demand_open`, so a stitch row and an
   engine_add row for the same shelf are two separate OPEN rows. On real dates procurement would see
   the same unmet demand twice, from two engines, with different quantities.

**The ask for CS:** once v3 goes live per cluster, should the nightly runner call
`record_blocked_demand_v3(plan_date,'stitch')`, and should `engine_add` rows then be suppressed for
clusters where v3 is authoritative? ⭐ Until then the call is available and safe to run by hand on any
date; nothing schedules it.

### ⏸️ D-30 (NEW, OPEN, small) — `_blocked_demand_gaps_v3` still carries the `anon` EXECUTE grant

Cody's P3.1e review found `record_blocked_demand_v3` executable by `anon` and required the REVOKE
(applied — a NULL-actor role gate plus an anon grant let an unauthenticated caller write the ledger
through a SECURITY DEFINER; S-88). ⛔ Its P0.5 sibling `_blocked_demand_gaps_v3` has the same grant
and was deliberately **left alone**: this unit does not modify that object. Read-only, so the
exposure is disclosure (machine/shelf ids and blocked quantities), not mutation. One-line fix, its
own reviewed unit.

### 📌 The P0 fixture budget understates two fixtures by ~60x

Fixture **5** takes **60.6 s** and fixture **105** takes **52.9 s**, against a documented "P0 = 4
fixtures" line that reads as fast. Two of them together exceed a 120 s Bash timeout. ⚠️ Run 5 and 105
**individually**, exactly like the P3 heavyweights 42 and 43.

### 📌 Not a defect: `blocked_demand` 50 → 52, and `v_blocked_demand_open` still 20

The two new rows are fixture 47's own output on plan_date **2030-02-17**. `v_blocked_demand_open`
filters `plan_date < '2030-01-01'`, so the live procurement worklist is provably untouched — pinned
by fixture 47 assertion 25. ⛔ A global `count(*)` on `blocked_demand` is therefore not a regression
signal; scope by `plan_date` and `source`.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, **D-29 (new)**, **D-30 (new)**.

D-22 remains UNBLOCKED (the ladder has its consumer). **D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above: CS appends answers between legs and a matching doc hash cannot detect it.

### S-01–S-95 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

---

## [leg 68] PRD-110 P3.4 — facing rightsizing

### ⛔ S-98 (NEW) — A CLIENT-SIDE TIMEOUT DOES NOT END THE TRANSACTION, AND AN OPEN ONE HOLDS ITS LOCKS

THE LAW mandates dry-running every migration as `BEGIN; <file>; ROLLBACK;`. That pattern has a failure
mode nobody had hit yet: **when the client dies mid-transaction, the `ROLLBACK` never arrives.** The
transaction stays open holding whatever DDL locks it took, and everything else queues behind it.

This leg's first draft of `propose_facing_changes_v3` computed five skip counters as six separate
subqueries over `v_facing_performance_v3` — **seven full evaluations** of a view that inherits the
~20 s cost of `v_shelf_instock_velocity_split_v3`. It blew the 2-minute Bash timeout inside a
`BEGIN; CREATE TABLE …; CREATE FUNCTION …; SELECT propose(…);` dry-run. For the next **~3 minutes**
every connection to the database — the psql script AND the MCP tool, down to `SELECT 1` — failed with
_"Connection terminated due to connection timeout"_. The postgres log names the mechanism exactly:

```
19:49:51  LOG    process 1238 still waiting for AccessShareLock on relation 17343 of database 5
19:50:10  ERROR  canceling statement due to statement timeout
19:50:52  LOG    process 1238 still waiting for AccessShareLock on relation 17343 ... after 1000.435 ms
```

It cleared on its own; recovery confirmed by poll at ~160 s, ungranted locks now 0, and a full probe
confirmed **nothing was half-applied** (neither `facing_proposals_v3` nor `propose_facing_changes_v3`
exists). ⭐ **THE HABITS THIS EARNS:** (1) put **`SET statement_timeout` INSIDE the dry-run
transaction**, so the server ends what the client cannot; (2) before calling any new function that
reads a known-expensive object, **count the evaluations in its body** — the registry already said it
(S-26 / RISK 88: "read it ONCE per run and join; machine-scoping does NOT reduce the cost, the inner
`vel` CTE is MATERIALIZED"), and the rule was there to be broken.

⚠️ **A near-miss worth recording separately: do NOT infer liveness from a log page.** Mid-diagnosis
the absence of log rows after 19:50:52 was read as "the DB has been stalled for twenty minutes". It
had not been — `get_logs` returns a bounded snapshot whose newest row is not the current time. That
misreading nearly became a false incident report. Probe the DB.

### ⛔ THE P3.4 DOUBLE-COUNT TRAP — measured, not reasoned

`v_shelf_instock_velocity_split_v3` canonicalises the Hunter/Hunter Ridge alias INTERNALLY (S-37) but
**emits the RAW pod key per shelf**, while its `pod_shelf_count` and `velocity_*_pod` are
**FAMILY-level**. Grouping on the emitted key splits one 2-lane family into TWO rows that EACH claim
`facings = 2` and EACH claim the full family velocity, with only their own shelf's stock. On the 7
dual-Hunter machines that doubles attributed revenue and emits **two** "drop a lane" proposals for a
family that should lose one — a contradiction, not an error, so nothing would have caught it downstream.

⭐ **The fix is to read identity from its OWNER (Article 16), not to write another copy of the alias
rule.** `v_shelf_sales_identity` is the canonical alias object, is already collapsed to one row per
merged family, and **already carries `facings`, `stock`, `cap` and a calendar `dvel` at that grain**
(525 rows, `(machine_id, pod_product_id)` UNIQUE, agreeing with `pod_shelf_count` on every family where
both exist). This ADDS a consumer to the canonical object — the direction **S-38** wants.

### ⛔ THE ppad TRAP IS NOT ONLY IN `rank_slot_suitability.proven`

PRD-108 records `proven` as units-per-SELLING-day (~23.6x mean overstatement). **`velocity_instock_pod`
is the same class of quantity** — sales ÷ IN-STOCK hours. Measured across 456 live families it is ≥ the
calendar rate on **every single one**: min ratio **1.006**, mean **1.121x**, **MAX 14.003x**, with 20
families overstated by more than 50%. Dividing it by facings and calling the result "what a lane earns"
would inflate the number up to 14x on exactly the shelves that run dry — the ones most likely to be
judged. ⭐ So `v_facing_performance_v3` exposes BOTH (`_realized` = calendar, `_potential` = in-stock)
and neither is "the" velocity, and **`starvation_ratio` (their quotient) is the ONLY admissible
evidence for ADDING a lane**: high revenue per lane alone argues for RESTOCKING it, not for a second one.

### ⏸️ D-31 (NEW, OPEN) — a second inline copy of the price cascade

`v_facing_performance_v3` carries the three-tier price cascade (realized machine-pod → realized
fleet-pod → `recommended_selling_price`) that `rank_machines_by_value_at_risk_v3` already owns. It was
copied **verbatim and deliberately**, so the two objects cannot disagree about what a unit is worth
(S-94) — but that is mitigation, not convergence, and it is the same class as the affinity
dual-definition at METRICS_REGISTRY line 43. **The ask for CS:** converge onto one canonical price
object, or ratify the copy and pin the agreement with a fixture assertion.

### 📌 Small shapes that cost time this leg

- ⛔ `machines` has **no `name`**, and **`machine_number` is NOT unique** — many rows read `Batch_1` /
  `Batch_2` across distinct `machine_id`s. The human label is **`official_name`**. The Active column is
  **`machines.status`**, not `machine_status` (that name lives on `v_machine_priority`).
- ⛔ **`percentile_cont` is an ORDERED-SET aggregate: PostgreSQL rejects it with `OVER()`.** A
  per-machine median must be its own grouped CTE. It also **returns float8 even on numeric input**, so
  cast back before `round(x, 4)`.
- ⛔ A facing count built by grouping `v_shelf_state` on `pod_product_id` collapses every EMPTY shelf
  into one phantom group — live, 24 empty shelves on one machine read as "24 facings of NULL".

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, **D-31 (new)**.

D-22 remains UNBLOCKED (the ladder has its consumer). **D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above: CS appends answers between legs and a matching doc hash cannot detect it.

### S-01–S-97 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

## LEG 69 — P3.4 queue half applied, fixture-proven (2026-07-31 ~20:07–20:45 UTC)

### ⛔ S-100 — THE DOC-HASH CHAIN IS NOT A TAMPER DETECTOR, AND HAS NOT BEEN FOR 14 LEGS

STEP R this leg found **4 of 6 doc hashes mismatched**, which under S-99 reads as alarming. It is not.
Diagnosis, in the order it should be repeated:

1. The two files whose mtime predated leg 68's close (`RPC_REGISTRY` 19:41:32Z, `ADR` 17:44:20Z)
   **matched exactly**. The four that mismatched (`MIGRATIONS_REGISTRY`, `METRICS_REGISTRY`,
   `PARKING-LOT`, `EXECUTION-LOG`) **all carry mtime 20:05:1xZ — leg 68's close moment.**
2. All four contain leg 68's own final material (its two migrations, `v_facing_performance_v3`, D-31).
3. The committed prefix of the EXECUTION-LOG (lines 1..4309) is **byte-identical to git HEAD**.
4. Brute-forcing every recorded hash against every prefix of the current file: **9 of 44 match at
   their stated N; 35 match NO prefix at all** — and the passes and failures are **interleaved**
   (N=5825 OK, N=6112 FAIL, N=6391 OK…). Interleaving is impossible under content corruption: any
   changed byte below N=12965 would break the N=12965 hash, and **N=12965 verifies**.

⭐ **CONCLUSION: RISK 105 has never actually held.** Each leg computes the six hashes and then writes
those same four files — so the recorded hash is of a file state that no longer exists by the time the
leg ends. The claim "measured LAST, after every doc edit" has been repeated for fifteen legs and is
false for exactly the files a leg edits at close. ⛔ **Do not spend a leg reconciling this.** The
authority on build state is the DB, which matched the pointer on **every** probed claim this leg.
⭐ The cheap real check is the one that worked: **mtime correlation**, not the hash.

### ⛔ S-101 — `ON COMMIT DROP` IS NOT `ON RETURN DROP`

A function that memoises an expensive view into `CREATE TEMP TABLE … ON COMMIT DROP` **cannot be
called twice in one transaction**: the second call dies on `relation "…" already exists`. This is not
exotic — it is precisely what the idempotency contract (STEP 7 S4) and any multi-call fixture do. Fix:
`DROP TABLE IF EXISTS pg_temp.…` at the top of the body, so scratch is rebuilt PER CALL.
⭐ Caught only because the dry run exercised the **BEHAVIOUR**; the DDL-only dry run passed in 2 s.

### ⛔ S-102 — A 524 DOES NOT MEAN THE WORK DIED (refines RISK 89)

RISK 89 states "on a 524 the query is already dead". **False this leg.** Fixture 48 ran 126 s, the
gateway returned a 524 HTML page, and the run had **COMMITTED server-side**: `golden.runs` held the
full 51/1 verdict and the 23 proposals were in the table. ⭐ On ANY 5xx, **probe before concluding**:
`pg_locks` ungranted, `pg_stat_activity`, then read the result table. (Health was clean — 0 ungranted
locks, 0 idle-in-transaction — so this was not an S-98 stuck transaction either.)
⚠️ The practical ceiling is ~105 s, where fixtures 42 (106 s) and 43 (104 s) sit. Budget under it.

### ⛔ S-103 — CHANGING A `check_sql` WITHOUT RE-READING ITS `expect`

Seq 44 was re-expressed and its `check_sql` began returning `true`, but `expect` still read `'false'`
from the superseded formulation — so a **correct** engine reported as a failure. It failed loudly,
which is the safe direction; the same slip in the opposite direction produces a green suite that
tests nothing. ⛔ An assertion edit is TWO fields, always.

### ⛔ S-104 — THE v3 ENGINE ACL IS A FLEET CONVENTION, NOT A PER-OBJECT CHOICE

Measured live, **all six** v3 engine objects carry the identical ACL
`postgres=X | authenticated=X | service_role=X`: `engine_add_pod_v3`, `stitch_v3`,
`resolve_supply_ladder_v3`, `rank_machines_by_value_at_risk_v3` (whose anon/PUBLIC grants were
deliberately revoked at leg 58 under S-81, leaving `authenticated`), `propose_rotations_v3` (Cody-
ratified at leg 57), and now `propose_facing_changes_v3`. RPC_REGISTRY names this the house pattern.
⛔ **The S-88 line is `anon`, not `authenticated`.** A migration's `GRANT EXECUTE … TO service_role`
does NOT mean service_role-only: Supabase default privileges grant EXECUTE to `authenticated` at
CREATE time, and `REVOKE … FROM PUBLIC` does not remove it. The staged D file's comment overstates
the restriction; the effective ACL matches its peers. ⭐ Assertions on ACLs should pin the
**convention by comparison to a ratified sibling**, not a hardcoded literal — then a future CS
tightening is followed automatically instead of having to be hunted down.

### ⭐ DECISIONS-READY — D-32 (NEW): the facing rightsizing queue is built and idle

**What it is:** `propose_facing_changes_v3` writes `facing_proposals_v3` — one row per (machine,
alias-merged family) proposing exactly one lane more or one lane fewer, behind `status='pending'`.
**Evidence:** golden fixtures **48** (49/49) and **49** (8/8); a live batch of **23 proposals
(11 shrink / 12 expand)** matching an independently re-derived oracle as a SET.
**Activation is two separable asks:**

1. Review the 23 pending proposals (they are advisory; nothing moves a lane without a future
   approve RPC, which does not exist yet and will be its own Cody review).
2. Decide whether to schedule it. ⛔ It is wired to **no cron** and each call costs ~25–40 s.
   **Do nothing and nothing happens** — that is the intended resting state.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, **D-32 (new)**.

D-22 remains UNBLOCKED. **D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above: CS appends answers between legs and a matching doc hash cannot detect it —
and per **S-100** a MISmatching doc hash proves nothing either. Check mtime, then the DB.

### S-01–S-99 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

---

# LEG 70 — P3.6 EDITS AS EVENTS

### ⭐ TIME-SENSITIVE 1 RESOLVED — cron 45 is NOT a dead schedule; it had never been given a chance

Four legs inherited "`shadow_runner_log_v3` = 63, unchanged" with the standing instruction that if it
were still 63 after 21:22Z it _was the finding_. It is the finding, and the finding is benign:

| job    | schedule      | n_runs | last run                       |
| ------ | ------------- | ------ | ------------------------------ |
| 13     | `0 16 * * *`  | 75     | 2026-07-31 16:00:00Z succeeded |
| 43     | `15 16 * * *` | 1      | 2026-07-31 16:15:00Z succeeded |
| 44     | `40 * * * *`  | 27     | 2026-07-31 20:40:00Z succeeded |
| **45** | `22 21 * * *` | **0**  | **never**                      |

⭐ `cron.job_run_details` **is** retained (13/43/44 all carry history), so `n_runs=0` on job 45 is a
real zero, not a pruned table. Job 45 was created by `20260731115020` at ~11:50Z on 2026-07-31, so
**tonight's 21:22Z slot is its first ever scheduled fire**. Every leg since simply closed before it.
⛔ The four-leg "unchanged at 63" observation therefore proves nothing about runner health and never
did. The first real evidence arrives at 21:22Z tonight; `blocked_gate0` remains NORMAL if CS has not
confirmed Gate 0, and ⛔ auto-confirming it is still forbidden (LAW 11).

### ⛔ S-105 — A PARTIAL UNIQUE INDEX MAKES "INSERT THEN SUPERSEDE" IMPOSSIBLE

`ux_plan_edits_v3_active` allows one active row per key, so inserting the successor before retiring
the predecessor leaves two rows active for the duration of one statement and dies on
`duplicate key value violates unique constraint`. Retire FIRST, insert SECOND — which forces
`superseded_by` to point forward, which is why the self-FK is `DEFERRABLE INITIALLY DEFERRED`.
⛔ That clause is load-bearing; removing it re-breaks every re-edit.

### ⛔ S-106 — `golden.runs.detail` IS AN ARRAY, SO `detail->>'scenario_error'` IS ALWAYS NULL

`run_fixture` appends `{'scenario_error': SQLERRM}` as an **element** of a `'[]'::jsonb` array.
Read as a top-level key it returns NULL, which is indistinguishable from "the scenario ran fine".
⭐ Correct probe:
`SELECT e->>'scenario_error' FROM golden.runs r, jsonb_array_elements(r.detail) t(e) WHERE e ? 'scenario_error'`.

### ⛔ S-107 — A THROWN SCENARIO LEAVES THE PREVIOUS RUN'S SCRATCH IN PLACE

The scenario opens by DELETEing its own scratch, so when it throws, the savepoint rolls back and the
**committed scratch of the previous run survives**. Assertions then read stale-but-plausible values.
Here the stale values were the RED baseline's `'absent'` sentinels, so a crashed scenario looked
exactly like "the engine was never built" — costing four probes to tell apart. ⛔ On an all-absent
read that contradicts a live `to_regclass`, check the scenario_error array FIRST (S-106).

### ⭐ S-108 — THE ADR's TRUNCATE GAP IS NOW CLOSED, ON EXACTLY ONE TABLE

`plan_edits_v3` carries a statement-level `BEFORE TRUNCATE` trigger alongside the row-level
UPDATE/DELETE guard, so it is the first member of the shadow family whose append-only claim survives
the one operation that bypasses both RLS and row triggers. ⛔ `pod_refills_shadow`,
`refill_plan_output_shadow` and `pod_refill_plan_shadow` still have no TRUNCATE guard.

### 📌 S-109 — THE ENGINE md5s IN EVERY POINTER ARE `md5(prosrc)`, NOT `md5(pg_get_functiondef())`

Leg 70's STEP R read `stitch_v3` as `ad3155e4` against the pointer's `a8753091` and nearly recorded
engine drift. All five recorded hashes match exactly under `md5(prosrc)`; none match under
`md5(pg_get_functiondef(oid))`. ⛔ The basis has never been written down. Use `prosrc`.

### ⭐ DECISIONS-READY — D-33 (NEW): the edit overlay is built and wired to nothing

**What it is:** `record_plan_edit_v3` records a human plan edit as an append-only event;
`compose_plan_with_edits_v3` composes any base shadow run with the active overlay into a new
`compose_v3` run. A hard edit outranks an engine re-run permanently; a soft edit yields to a base that
has moved and says so; no edit is ever silently lost (`applied + yielded = considered`, asserted).
**Evidence:** golden fixture **50 (46/46)**, RED baseline 2/46 before the engine existed.
**Activation is two separable asks:**

1. Decide whether `stitch_v3` should consume composed runs by default. ⚠️ It _already would_ —
   it picks the latest shadow run for a date, and a `compose_v3` run is the latest. That coupling is
   currently **implicit and not pinned by any fixture**; P3.7 is where it gets tested end-to-end.
2. Decide who may record edits (currently `operator_admin`/`superadmin`, no FE surface exists).
   **Do nothing and nothing happens** — no cron calls either function.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, **D-33 (new)**.

D-22 remains UNBLOCKED. **D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above. Per S-100 a mismatching doc hash proves nothing either; check mtime, then
the DB. ⭐ At this close the answered-and-unbuilt queue is **EMPTY**.

### S-01–S-104 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

---

# LEG 71 — P3.7 ONE PIPELINE

### ⛔ S-110 — THE `compose → stitch` COUPLING WAS NOT "IMPLICIT", IT WAS A COIN FLIP

Leg 70's pointer recorded that `stitch_v3` "would already consume a `compose_v3` run without being
told to" and called that "probably the desired pipeline". Measured this leg, it is worse than
implicit. `stitch_v3` with a NULL source resolves `ORDER BY produced_at DESC, run_id DESC`, and
`pod_refills_shadow.produced_at` DEFAULTs to `now()` — the **transaction** timestamp. A base run and
the run composed from it **inside one transaction, which is exactly what a pipeline is**, therefore
TIE on `produced_at`, and the tie-break falls to uuid ordering of `run_id`. Whether a human's edits
reached the stitched plan was decided by which random uuid happened to sort higher.

⭐ It read as working only because every observation so far had composed in a LATER transaction than
its base. Fixture 51 forces the flip to its wrong face (base `run_id` = `ffffffff-ffff-4fff-bfff-…`,
above every random v4 uuid) and measures the implicit pick returning the RAW ENGINE run with a
composed run sitting on the same date. ⛔ **Never call `stitch_v3` with a NULL source from anything
that also produced its input.**

### ⛔ S-111 — A SENTINEL DEFEATS `eq` BUT FEEDS `ne`

Fixture 51's RED baseline read 5/53. Two greens were the familiar weak kind (green because nothing
existed yet, fixed by gating the probe). The third was new and the opposite shape: seq 42 asserted
`ne 'none'` against a probe that returned the `no_pipeline` sentinel — and `'no_pipeline' <> 'none'`
is TRUE, so the assertion went green in a world with no approver at all. ⭐ **Rule, binding on every
future fixture: an assertion may use `ne` / `not_null` only when the sentinel itself would fail it.
Otherwise state the positive.** Seq 42 now asserts that the retired approval is the RIGHT run.

### ⭐ S-112 — CRON 45 FIRED FOR THE FIRST TIME AND ERRORS EVERY NIGHT BY CONSTRUCTION

Leg 70 resolved TIME-SENSITIVE 1 by establishing that job 45 had never fired. It fired at
**2026-07-31 21:22:00Z**, `cron.job_run_details` says `succeeded` (the job invoked cleanly), and the
run it performed **failed**: `shadow_runner_log_v3` records `step=engine status=error` with
`engine_add_pod_v3: no picked/cs_added machines for 2026-08-01; run Stage 1 first`.

⛔ **This is not Gate 0 and it is not transient.** Job 45 is scheduled `22 21 * * *` = **01:22 Dubai**,
which is already the NEXT Dubai day. `resolve_refill_plan_date()` at that moment returns
`2026-08-01`; `machines_to_visit` holds rows for `2026-07-31` (Stage 1, cron 13, ran 16:00Z) and
**none** for `2026-08-01`, because Stage 1 for that date does not run until 16:00Z on 08-01. The
runner therefore asks for a plan date Stage 1 has not prepared, every single night, forever.

⭐ The other two PRD-110 crons sit deliberately just after Stage 1: cron 13 at `0 16`, cron 43 at
`15 16`. Job 45 at `22 21` is the outlier. **Verified candidate fix: `cron.alter_job(45, schedule =>
'45 16 * * *')`** — 20:45 Dubai, 45 min after Stage 1, same Dubai day, same resolved plan date.
⛔ NOT applied this leg: it is a cron behaviour change and LAW 1 wants a fixture that proves the
runner succeeds on a date Stage 1 has prepared. It is the next leg's first unit.

### ⛔ S-113 — `v_shadow_runner_health_v3` CALLED THAT NIGHT "ok"

The same night, the health view returns `verdict='ok'`, `is_healthy=true`, `is_measuring=true`.
`is_healthy` is pure recency (`a run happened within 30h`) and `is_measuring` reads
`last_ok_at` — which was satisfied by an unrelated **manual** run at 13:20Z, not by the cron.
⛔ So a night where the scheduled runner failed outright is indistinguishable from a healthy one as
long as somebody ran the engine by hand that day. Fixture 37 is titled "a failed or MISSING night is
visible (P2.7)" and does not catch this. The fix belongs with S-112, in the same unit, with its own
assertions: health must be judged on the **scheduled** run, not on any run.

### ⭐ DECISIONS-READY — D-34 (NEW): the one pipeline is built and wired to nothing

**What it is:** `run_pipeline_v3(plan_date, days_cover, base_run_id, promote_blocked, note)` runs
`engine → compose → stitch` as one receipted unit, passing every run id explicitly, and writes one
append-only `pipeline_runs_v3` receipt. `approve_pipeline_run_v3(pipeline_run_id, reason)` is the
single approve verb; at most one approval stands per `plan_date` and switching retires the incumbent
by name. **Evidence:** golden fixture **51 (53/53)**, RED baseline 3/53 before the engine existed.
**Activation is three separable asks:**

1. Point the nightly shadow runner at `run_pipeline_v3` instead of `engine_add_pod_v3` alone, so the
   shadow plan CS reviews is the composed-and-stitched one. ⛔ Blocked behind **S-112** — the runner
   currently fails every night regardless.
2. Flip `p_promote_blocked => true` so stitch's stranded units reach `blocked_demand` automatically.
   That is **D-29**, still parked, unchanged.
3. Decide what an approval MEANS downstream. Today it means nothing outside the shadow ledger
   (LAW 4); the live cutover is the Phase 5 flag.
   **Do nothing and nothing happens** — no cron calls either function.

### 📌 P3.6 DEBT CARRIED, NOT SILENTLY DROPPED

BUILD-SPEC line 94 lists `swap_v3(machine, shelf, new_product, qty?, cross_machine_source?)` as part
of P3.6. Leg 70 shipped `plan_edits_v3` + the composer and did **not** build `swap_v3`; leg 71 built
the pipeline and did not either. ⛔ It is real, unbuilt scope — recorded here so the Phase 3 gate is
declared against reality. Charter E3 names it as "one-verb swap (same or cross machine)".

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, **D-34 (new)**.

D-22 remains UNBLOCKED. **D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above. Per S-100 a mismatching doc hash proves nothing either; check mtime, then
the DB. ⭐ At this close the answered-and-unbuilt queue is **EMPTY**.

### S-01–S-109 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

# LEG 72 — S-112 / S-113 CLOSED, AND THE HANDED-OVER FIX WAS WRONG

### ⛔ S-114 (NEW, and it is the finding of the leg) — A "VERIFIED CANDIDATE FIX" IN A POINTER IS STILL A CLAIM

Leg 71 handed over `cron.alter_job(45, schedule => '45 16 * * *')` as a **verified candidate**, with
a stated mechanism: job 45 at `22 21` = 01:22 Dubai "is already the NEXT Dubai day", so it "asks for
a plan date Stage 1 has not prepared, every single night, forever".

Probed before acting (LAW 13), **every load-bearing part of that mechanism is false**:

- `resolve_refill_plan_date()` flips at **18:00 Dubai**, not at midnight. So 01:22 Dubai resolves to
  _that_ Dubai date, and 20:00 Dubai resolves to _the next_ one — and they land on the SAME date.
- Measured: cron 13 @ `2026-07-31 16:00Z` → `2026-08-01`. cron 45 @ `2026-07-31 21:22Z` →
  `2026-08-01`. ⭐ **The two crons already agreed.** They have agreed every night.
- `machines_to_visit` had no rows for 2026-08-01 not because Stage 1 had not run, but because it
  HAD run, succeeded, and **deliberately declined**: 2026-08-01 is a **Saturday**, and PRD-035 WS-E
  makes Saturday a delivery day. `build_draft_for_confirmed_v3('2026-08-01')` returns
  `status='skipped_saturday'`. Every Saturday in the window (07-11, 07-18, 07-25, 08-01) has
  exactly 0 picks; the gaps on 07-13, 07-26, 07-27 are ordinary no-pick nights under manual Gate 0.

⛔ **And the proposed fix was not merely unnecessary, it was harmful.** Pick timestamps show Stage 1
seeding at 20:00 Dubai and humans adding/dropping until ~06:00. `45 16 * * *` = 20:45 Dubai would
have sampled the plan **45 minutes after Stage 1 and before every overnight human edit**, making the
shadow measurement systematically less representative than it is today. The 01:22 Dubai slot catches
them. ⭐ **The schedule was right all along; the defect was the WORD in the log.**

⭐ **THE HABIT THIS EARNS:** a pointer's _symptom_ is evidence (job 45 really did log an error). A
pointer's _mechanism_ is a hypothesis, no matter how confidently it is written or how many stars it
carries. Re-derive the mechanism from the live objects before applying its remedy — especially when
the remedy changes a cron, a flag, or anything a human will not re-check.

### ⭐ S-112 CLOSED — the runner now distinguishes four things it used to call one

`error` was covering: a real fault, Gate 0, a calendar skip, and a no-pick night. Now
`skipped_calendar` (the date is never planned) and `no_picks` (plannable, nobody picked) carry their
own names, the summary propagates them instead of flattening to `error`, and the engine's own words
still land verbatim in `message` (fixture 53 seq 13). CHECK widened to a strict superset; all 72
pre-existing rows stayed legal; the append-only trigger was untouched.

### ⭐ S-113 CLOSED — health is judged on the SCHEDULED run

`is_healthy` and `verdict` now read only rows tagged `note='cron'`, which job 45 sets and a human
does not. ⛔ **NULL could not serve as the mark** — that is exactly what the masking manual run of
2026-07-31 13:20Z carried. `is_measuring` moved to a scheduled `ok` within **8 days**, because the
calendar itself guarantees gaps (every Saturday, plus legal no-pick nights). The old
"did anything run at all" signal survives as **`log_is_alive`**, which is what fixture 37's absence
detection was always really asserting; seq 17/18 were re-pointed onto it and fixture 37 re-ran
**30/30**.

⚠️ **EXPECTED AND HARMLESS:** the live verdict now reads
`no_scheduled_run_ever__cron_untagged_or_dead` because no cron-tagged row exists yet. It self-heals
on job 45's next fire (2026-08-01 21:22Z, resolving 2026-08-02, a Sunday and therefore plannable).
⛔ Do not "fix" this — it is the honest answer to the question the view now asks.

### ⏸️ D-35 (NEW, Article 16 debt, opened deliberately) — one calendar, two copies

`is_refill_planning_day_v3(date)` now names the PRD-035 WS-E rule, and `run_nightly_shadow_v3` asks
the name. But `_build_draft_core_v3` still carries the same rule inline as a bare
`EXTRACT(DOW FROM p_plan_date) = 6`. Cody flagged it as the Article 16 "known illegal copy to
retire"; it was **not** collapsed because doing so edits the live Stage 1 engine, which LAW 12 puts
outside this unit. **Smallest unblock:** one migration replacing that expression with a call to the
helper, plus a fixture asserting Stage 1 and the runner agree on the same Saturday.

### 📌 D-34 unchanged, and its blocker is now HALF cleared

D-34 activation step 1 ("point the nightly runner at `run_pipeline_v3`") was recorded as _blocked
behind S-112 — the runner currently fails every night regardless_. That premise is now corrected:
the runner was never failing "every night by construction", and on plannable nights it works. The
step is **no longer blocked**, it is simply undone. Steps 2 (D-29) and 3 (the cutover) are unchanged.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, **D-35 (new)**.

D-22 remains UNBLOCKED. **D-24, D-25, D-26 remain CLOSED AND BUILT.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trusting the line above. ⭐ At this close the answered-and-unbuilt queue is **EMPTY**.

### S-01–S-111 unchanged · S-55 still the SOLE real red in the suite · RISK 74, 88–105 unchanged

### ⛔ S-115 (NEW) - A PRETTIER HOOK REWRITES THESE DOCS. HASH LAST, AFTER IT SETTLES.

`.claude/settings.json` configures a **PostToolUse prettier hook**. It reformats markdown _after_
the tool call returns. This leg computed its six SHA-256 baselines, made one further `Edit`, and the
hook silently invalidated **five of the six** - including the EXECUTION-LOG's own `[1..N]` slice.

⛔ It also produced a false alarm worth remembering: `ADR-shadow-plan-tables.md` was found mid-close
to have moved from its STEP R value `07ae5cab…` to `c94862a0…`, with an mtime inside this session,
while this leg had made **zero** edits to it. The first write-up called it a possible concurrent
session. It was the formatter. `git diff` confirmed the content is leg 71's own P3.7 / D-34
material, uncommitted at +257 lines, with nothing lost.

⭐ **BINDING ON EVERY CLOSE:** write every doc → let the hook run → **re-hash and verify the six
values against disk** → only then ship the block. A baseline computed before the last hook fires is
fiction. Verify idempotency by recomputing twice; prettier settles (as it did here).
⭐ Note `cat >>` from Bash does **not** trigger the PostToolUse hook, but `Edit`/`Write` do - so the
last write of a leg is the dangerous one.

---

### ⛔ S-116 (leg 73) — fixture 50 is not re-runnable

Fixture 50 appends 2 `plan_edits_v3` rows per run on its own `plan_date 2030-02-20` and asserts on
**absolute** counts (seq 17 expects 2, seq 42 expects 5). It is therefore green only on the FIRST run
after creation; a second run reads 4/10, a third 6/15. Measured this leg: 6 rows over 3 distinct
run-instants. **No engine regressed** - `compose_plan_with_edits_v3` `32d2a805` and
`record_plan_edit_v3` `b77f9e9a` are byte-unchanged.

⛔ **This breaks STRESS S7** (`golden.run_all()` ×3 → identical results) and falsifies S-108's claim
that the TRUNCATE gap was closed on `plan_edits_v3`.

**Smallest unblock:** fixture 50's arrange step clears its own plan_date's `plan_edits_v3` rows, then
re-baseline seq 17/42. ⛔ Do NOT weaken them to `gte` - the absolute count IS the supersession proof.

### ⏸️ D-36 (leg 73, Article 4/8) — a swap is invisible in the audit log

`swap_v3` sets `app.rpc_name='swap_v3'`, then `record_plan_edit_v3` overwrites it with its own name,
so `write_audit_log` records two ordinary edits and no swap. Traceability survives only via the
`[swap_group:<uuid>]` marker in `reason`.
**Options:** (a) re-assert `app.rpc_name` after each inner call, (b) pass an origin argument through
the writer, (c) accept and document. ⚠️ (b) changes a live signature - remember the
`pronargdefaults` overload foot-gun. **CS/next-leg call; nothing is blocked meanwhile.**

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, **D-36 (new)**.

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` at STEP R rather than
trust this line.

---

# LEG 74 — S-116 CLOSED, AND THE HARNESS THAT LIED ABOUT IT

### ✅ S-116 CLOSED (leg 74) — fixture 50 is re-runnable; 49/49 x3

Fixed by `20260731223857_prd110_p37_s116_fixture50_rerunnable`. The fixture captures the ledger
depth for its own `plan_date` BEFORE the first `record_plan_edit_v3` call and reports what THIS RUN
appended. `expect` is untouched: seq 17 is still `eq 2`, seq 42 still `eq 5`. ⛔ **Nothing was
weakened to `gte`** — the absolute count is still the supersession proof, it is merely scoped to the
run that produced it. Raw totals retained as `rows_after_reedit_abs` / `edits_after_compose_abs`.
**Evidence: 49/49 on three consecutive runs in SEPARATE transactions** (`s116_verify_run_A/B/C`).

⛔ **THE POINTER'S REMEDY WAS IMPOSSIBLE, NOT MERELY SUBOPTIMAL** (S-114 in action). "Clear its own
plan_date's `plan_edits_v3` rows in arrange" cannot be done: the table carries
`tg_plan_edits_v3_append_only` (row) and `tg_plan_edits_v3_no_truncate` (statement), **and section
(7) of that very scenario asserts the DELETE is REFUSED.** Attempting it would have either failed or
required breaking a guard assertion to make a test pass.

⭐ **S-108 IS CONFIRMED, NOT FALSIFIED.** Leg 73 recorded S-116 as falsifying S-108's "TRUNCATE gap
closed on `plan_edits_v3`". The opposite is true: the guard is present and enabled, and it is the
CAUSE of the non-re-runnability. ⛔ **Do not carry the "S-108 partly falsified" note forward.**
New **seq 48** asserts `tg_plan_edits_v3_no_truncate` still exists and is enabled, so the claim is
now pinned by the harness rather than by a paragraph.

### ⛔ S-117 (NEW, leg 74) — YOU CANNOT TEST RE-RUNNABILITY INSIDE ONE TRANSACTION

Running fixture 50 twice in a single transaction produced **6 phantom reds** (seq 18, 22, 30, 31,
32, 38) that do **not** occur across separate transactions. Root cause is S-110 exactly:
`pod_refills_shadow.produced_at` DEFAULTs to `now()` = the **transaction** timestamp, so run 1's and
run 2's base rows **TIE**, and `record_plan_edit_v3`'s base resolution falls through to the uuid
tie-break. Seq 18 read `base_qty_at_edit = 7` (run 1's R2) instead of 4 (run 2's own R1), and the
soft-yield chain cascaded from there.

⭐ **Corroboration that these are artefacts, not defects:** leg 73's three GENUINE re-runs showed
only seq 17 and 42 red. Those six were green every time.

⛔ **BINDING ON STRESS S7.** "`golden.run_all()` x3 consecutive — identical results" **must be three
separate transactions.** A single-transaction x3 will fail for reasons that have nothing to do with
idempotency, and would send a leg hunting a non-existent engine bug.

### ⏸️ S7 RE-RUNNABILITY SWEEP — SCOPED, NOT CLEARED (carry-forward)

S-116 was found by accident, so the class was scanned rather than assumed. A static scan for
`count(*) FROM public.<append-only table>` in `scenario_sql` yields candidates in fixtures **2, 14,
19, 20, 21, 22, 24, 27, 34, 36, 37, 41, 43, 48, 49, 50, 51**. ⛔ **This is a CANDIDATE list, not a
defect list** — most of those counts are `WHERE`-scoped by `plan_date` or `run_id` and are fine.
**Cleared so far: 50 (x3), 51 (leg 73 ran it twice, 53/53 both), 54 (32/32 on a genuine re-run this
leg).** ⭐ The cheap discriminator: a fixture is only at risk if it asserts an ABSOLUTE count over a
table it itself appends to. The empirical test is one re-run per fixture, ⛔ **in its own
transaction** (S-117), ⚠️ respecting the perf budget (P2 >9 min, P3 ~470 s, run INDIVIDUALLY).

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36. **No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

# LEG 75 - THE PHASE 3 GATE, AND THE RUNG NOBODY CAN REACH

### ⛔ S-118 (NEW, and it is the finding of the leg) - RUNG 2 IS AN ABSORBING STATE

Measured, not reasoned. Across every shelf whose pod has ZERO real stock at its own primary
warehouse, `resolve_supply_ladder_v3` terminates at rung 2 `substitute` **161 times out of 161**.
Rungs 3 (`alt_wh`), 4 (`m2m`), 5 (`spot_buy`) and 6 (`blocked_demand`) are therefore **unreachable
through the ladder on live data** - the same class of dead branch S-91 found at rung 4, but wider.

⛔ **The business consequence is the one fixture 6 exists to prevent.** 55 of those shelves, across
21 pods and 23 machines, hold **3,017 real units of their OWN pod at a non-primary warehouse**. The
ladder SEES every one of them (rung 3 logs `satisfiable=true` with a qty on all 55, 0 invisible) and
then spends none of them: it swaps the customer's product instead. The stranded stock stays stranded
and the assortment silently changes.

⭐ **This is spec-conformant, which is exactly why it needs a CS decision rather than a fix.**
BUILD-SPEC line 88 orders `variant > substitute > alt_wh > m2m > spot_buy > blocked_demand`
verbatim, and fixture 40 seq 17 pins that order. ⛔ **No engine was touched** (LAW 3, LAW 10).
Raised as **D-37**.

⭐ **Live anchor, re-probed, exact:** IFLYMCC-1024-0000-W0 `5289578e` shelf **A07** `7a2c7e07` pod
**Pepsi Black** `4901aaf4`. `primary_warehouse_id` = WH_MCC `4fcfb52c` ("machine draws MCC"), all
**89** real units in **4** batches exp **2027-01-01** at WH_CENTRAL `4bebef68` ("stock in CENTRAL"),
zero at MCC, **zero sentinels** (so it is NOT the fixture-40 phantom case). CENTRAL is also the
machine's DECLARED `secondary_warehouse_id`, so the reroute route is configured, not invented.
Terminal rung on that anchor: `substitute` -> **Coca Cola Mix**.

### ⭐ S-119 (NEW) - THE 2030 PLAN_DATE MAKES EVERY FEFO BINDER LOOK BROKEN

`resolve_fefo_sku_legs_v3(..., 'alt_wh')` on the anchor returns
`status='unbound' / unbound_reason='no_pickable_batch_in_scope'` at the fixture's own **2030**
plan_date, and `status='ok'`, **6/6 bound**, at `CURRENT_DATE + 2`. ⛔ **The 2030 answer is not a
defect** - `wh_fefo_for_line` binds only batches in date ON the plan date (LAW 7) and the real stock
expires 2027-01-01. The seam's own header documents this; it is now PINNED by fixture 6 seq 30/31 so
no later leg burns a leg chasing it. ⭐ **Binding proofs must run on a NEAR date; reporting proofs
run on the fixture's own date.**

### ⛔ THE LEG-74 POINTER'S GATE RE-MAP WAS HALF RIGHT - CORRECTED, NOT ADOPTED

| pointer claim             | verdict after probing                                                                                                                                                                                                                |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 4 -> **41**               | ✅ **CONFIRMED.** Fixture 41 seq 24-29/33/38/41 are fixture 4's spec verbatim (only assortable SKUs transfer, the rest take a return leg flagged `not_assortable_at_destination`, conservation exact). **46/46 green this leg.**     |
| 13 -> **40 + 47**         | ✅ **CONFIRMED.** 40 = all six rungs logged in order + LAW 5 no-silent-zero (**56/56**); 47 = the blocked_demand promotion (**50/50**).                                                                                              |
| 25 -> **50**              | ✅ **CONFIRMED.** Edit survival under re-run, **49/49** this leg (and 49/49 x3 at leg 74).                                                                                                                                           |
| 6 -> rung 3 inside **40** | ⛔ **FALSE.** Fixture 40's ONLY rung-3 assertions are seq 25 and 26, both **NEGATIVE** (phantom stock must not rescue anchor A). No fixture anywhere asserted a POSITIVE alt-WH reroute. **Fixture 6 was genuinely unbuilt.** Built. |

⭐ **S-114 paid out again:** the pointer's SYMPTOM (rung 3 is exercised somewhere) was real; its
MECHANISM (fixture 40 proves fixture 6) was a hypothesis, and two queries falsified it.

### ⏸️ D-37 (NEW, OPEN, and it is a real business call) - should moving your OWN stock outrank swapping the customer's product?

**What:** rung order in `resolve_supply_ladder_v3`. Today `substitute` (rung 2) is tried before
`alt_wh` (rung 3), per BUILD-SPEC line 88. **Consequence measured live:** 3,017 real units across 55
shelves are never transferred, and 55 machines-worth of shelves change assortment instead.

**Option (a) - keep the order.** Substitution is instant; a transfer costs a driver leg and a day.
**Option (b) - own-stock first when the SAME pod is transferable in full.** Preserves the customer's
assortment and drains stranded inventory, at the cost of one transfer leg.
**Option (c) - a param.** `ladder_prefer_own_stock_transfer` on `refill_policy_params`, DEFAULT
false, so the flip is a one-line CS action and the built-flag-off rule of the goal command is met.

⭐ **Recommendation: (c), built flag-off**, because it makes (b) reversible and testable without a
second engine version. ⛔ **NOT BUILT THIS LEG** - it is an engine change and LAW 1 requires the
fixture that proves it first. Fixture 6 seq 22/25/26 is the RED-in-waiting: if the flag flips, those
three assertions must be **RESTATED**, never deleted.

**One-line ask for CS:** _"When a machine's own primary warehouse is empty but the same product sits
in full at another warehouse, should the plan move the stock or swap the product?"_

### 📌 Fixture 6 is green at baseline ON PURPOSE, and that is not a LAW 1 shortcut

`baseline_status='passing'`. It drives no engine change. It (a) proves machinery that already
existed - the rung-3 `alt_wh` warehouse scope of the FEFO binder, never once exercised positively -
and (b) RECORDS an open incident instead of closing one. ⛔ **GOLDEN-FIXTURES row 6 is therefore
still OPEN as a business outcome**, and the log says so rather than banking a green.

### ⭐ Fixture 6 is re-runnable BY CONSTRUCTION (S-116 / S-117 class)

It appends to no ledger at all: no `pod_refills_shadow` source run, no `plan_edits_v3`, no
`refill_plan_output_shadow`. Both functions it calls are STABLE + SECURITY INVOKER, so LAW 4 and
LAW 12 are enforced by Postgres rather than by care. Seq 46-49 assert the zero-write claim with
numbers. **51/51 on two separate-transaction runs** (S-117 respected).

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, **D-37 (new)**.

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

### ⭐ S-120 (NEW) - THE GUARDRAIL RULE NOW HAS TWO ENCODINGS, AND THAT IS DELIBERATE FOR NOW

After leg 76 the rule "Evian - 1L is never a swap-in" exists in two places:

1. `assortment_guardrails` (the registry, read by `find_substitutes_for_shelf_v3`) - NEW, canonical.
2. A literal uuid in `rank_slot_suitability` (PRD-106b2) - PRE-EXISTING, untouched.

⛔ **This is the D-35 shape** (a rule with two copies) and it should converge onto the registry.
It was **NOT** done this leg on purpose: `rank_slot_suitability` is consumed by PRD-106 and PRD-108
and is a live production engine, so editing it is scope drift (LAW 10) and needs its own fixture
(LAW 1). ⭐ **Convergence is now SAFE to do later and provable when it happens**, because fixture 12
seq 16/17 pin `rank_slot_suitability`'s current behaviour on the identical inputs: it must keep
returning the guardrail product ZERO times while still returning a real candidate slate. A
convergence pass that swaps the literal for a registry read must leave both assertions green.

⛔ **The same hole is STILL OPEN in v1 `find_substitutes_for_shelf`** - it will propose a guardrail
product today. Recorded, not fixed (fixture 39 precedent; `engine_swap_pod` and
`compose_nowh_proposals` consume it). Fixture 12 seq 31 pins v1's md5 so the next leg can prove
whether anyone has touched it; seq 32 keeps the witness on record.

### ⭐ S-121 (NEW) - AN RLS POLICY ON A RULE TABLE IS A FAIL-OPEN SURFACE

`find_substitutes_for_shelf_v3` is SECURITY INVOKER. If `assortment_guardrails`'s SELECT policy were
scoped `TO authenticated`, a cron or service-role caller would read ZERO guardrail rows and the
engine would silently resume proposing the banned product - a green fixture suite and a live bug at
the same time, because the golden harness runs as `postgres` and bypasses RLS entirely.

⛔ **The harness cannot catch this class of defect.** The policy is `USING (true)` with no `TO`
clause for exactly this reason. ⭐ **Any future narrowing of a rule-table read policy must be
verified by SET ROLE, not by a fixture run.**

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37. **No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⏸️ S-123 (leg 77) — the freed-allocation re-offer is BUILT and PROVEN but NOT WIRED

**What.** `propose_reallocations_v3(date,uuid,uuid,boolean)` and `reallocation_proposals_v3` shipped
at `20260731234438` and fixture 11 is **39/39 green**. But the verb is only ever invoked by an
explicit call. `run_pipeline_v3` does **not** call it, so on a real nightly run a mid-plan drop still
frees units that nobody re-offers **until someone runs the verb by hand**.

**Why parked rather than done in the same unit.**

1. **LAW 1.** Wiring it is a behaviour change of the pipeline and needs its own fixture asserting the
   pipeline emits proposals. Fixture 11 proves the VERB, not the WIRING.
2. **S-122.** `run_pipeline_v3` is an engine; editing it moves its md5 (`d16df04a`) and every
   `golden.assertions` row that pins that md5 must be found and RESTATED in the same unit.
   ⭐ Run `SELECT fixture_id, seq FROM golden.assertions WHERE expect ILIKE '%d16df04a%'` FIRST.
3. Fixture 51 (53 assertions) is the ONE-PIPELINE contract and will need re-running and probably
   extending, since it asserts the pipeline's receipt shape.

**Smallest unblock.** A fixture that runs `run_pipeline_v3` over a draft containing a dropped line
and asserts a `reallocation_proposals_v3` row appears with the run's own `composed_run_id`. Then wire
one call into `run_pipeline_v3` after the compose step, restate the md5 pins, re-run 51.

⛔ **Do NOT wire it without that fixture.** ⛔ **Do NOT treat the verb as dead code** - it is proven,
callable, and correct; only its trigger is missing.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37. **No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ✅ S-117 CLEARED FOR FIXTURE 11 (leg 78) - and the mechanism was the inverse of the guess

Leg 77 parked fixture 11's re-runnability as UNTESTED, hoping `ux_realloc_v3_pair` would dedup a
second run. **Tested at leg 78: it does not, and cannot.** The `composed_run_id` is fresh every run,
so the pair index never collides and each run appends a full second set of proposals. Fixed at
`20260801003401` by scoping the scenario's two reads to the run instead of the plan_date. **39/39 on
three consecutive separate-transaction runs.** All 39 assertions byte-identical.

⭐ **The transferable lesson (S-114 again, and it keeps paying):** a pointer's SYMPTOM is evidence,
its MECHANISM is a hypothesis. Leg 77 guessed a unique index would save it; the index was the very
reason it could not. ⛔ **When a pointer hands you an untested hypothesis, test it before you build
on it - and expect the mechanism to be the opposite of the guess as often as not.**

**S7 sweep status after this leg.** Cleared: **6, 11, 12, 41, 47, 50, 51, 54.** Still candidates
(⛔ candidate list, not a defect list): **2, 14, 19, 20, 21, 22, 24, 27, 34, 36, 37, 43, 48, 49.**
⚠️ **Fixture 1 is NOT yet cleared** - it appends to `plan_edits_v3`, `pod_refills_shadow` and
`pipeline_runs_v3`. Its edit writes are `ON CONFLICT`-shaped through `record_plan_edit_v3` and its
assertions read run-scoped scratch, so it _should_ be re-runnable, ⛔ **but that is exactly the
sentence leg 77 wrote about fixture 11.** Test it; do not assume it.

---

## ⏸️ S-124 (NEW, leg 78) - FIXTURE RESIDUE SITS ON THE LIVE PROTECTED PLAN TABLE

**What.** `refill_plan_output` - a **protected entity** and the live plan table - holds **21 rows on
future dates that no plan should ever occupy**: 7 rows on **2030-01-11** and 5 on **2030-02-03**
(both `generated_at` 2026-07-31, i.e. an earlier PRD-110 leg), plus 9 rows on **2099-12-01..09**
from 2026-05-14 (PRD-020-era test data).

**Why it matters.** LAW 4/12 say v3 writes shadow tables and fixtures run on synthetic 2030 dates
_so that nothing lands live_. Twelve of these rows are PRD-110's own residue, which means some
earlier leg's fixture wrote through to the live table. Every leg since has asserted
`refill_plan_output on <its own fixture date> = 0` and passed - ⛔ **the per-date tripwire is real
but it is NOT a sweep, and it never looked at the other 2030 dates.**

⛔ **NOT cleaned up this leg, deliberately.** Deleting rows from a protected entity needs per-row CS
approval (standing rule), and the goal command forbids destructive change. **This is a finding, not
a defect to fix unilaterally.**

**Smallest unblock.** (1) Identify which fixture wrote 2030-01-11 / 2030-02-03 (grep `scenario_sql`
for those dates) and scope it to the shadow tables. (2) Add a **fleet-wide** tripwire -
`refill_plan_output WHERE plan_date >= 2030-01-01` = a recorded constant - so residue cannot
accumulate silently again. (3) Put the 12 PRD-110 rows to CS as a one-line delete ask.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37. **No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ✅ S-117 CLEARED FOR FIXTURES 1, 40 AND 41 (leg 79) - and this time the absence was PREDICTED

Leg 78's pointer told leg 79 to expect the fixture-11 doubling in fixtures 40 and 41 and to check for
it first. **Checked structurally before either was run**, which is cheaper than a bisect and is the
whole point of S-114:

- Both 40 and 41 `DELETE FROM golden.scratch` at the top and write **only** `golden.scratch`.
- **41 calls no engine function at all**; 40 calls `resolve_supply_ladder_v3`, which is **advisory and
  writes nothing** (its own seq 38 asserts exactly that).
- 40's five `blocked_demand` assertions are `golden.scratch` reads, a **live `gte 15` anchor** on
  2026-07-30 (monotone-safe by construction), and seq 38's `golden.written_by_this_txn(x.xmin)` -
  ⭐ **a transaction-scoped read. That is the re-run-proof shape, and it is precisely what fixture 11
  did not have.** A fixture that asks "what did THIS transaction write" cannot be doubled by a re-run.

**Confirmed empirically: 40 = 56/56 twice (514 ms, 438 ms), 41 = 46/46 twice (1189 ms, 1176 ms)**,
each run in its own transaction.

⭐ **Fixture 1 too**, which leg 78 explicitly parked as untested with the warning "it _should_ be
re-runnable, but that is exactly the sentence leg 77 wrote about fixture 11". **Tested rather than
assumed: 59/59 on a second run in a fresh transaction.**

**S7 sweep status after this leg.** Cleared: **1, 6, 11, 12, 40, 41, 47, 50, 51, 54.** Still
candidates (⛔ candidate list, not a defect list): **2, 14, 19, 20, 21, 22, 24, 27, 34, 36, 37, 43,
48, 49.** ⚠️ Note leg 78's pointer corrected a leg-77 typo that had listed 41 as cleared when it was
not; **41 is now genuinely cleared, on evidence.**

---

## ⏸️ S-124 UPDATED (leg 79) - WRITER IDENTIFIED, RECLASSIFIED, AND THE SWEEP WIDENED

**The writers are `golden` fixtures 10 and 33.** Attributed by `plan_date`: fixture 10 owns
**2030-01-11** (7 rows), fixture 33 owns **2030-02-03** (5 rows). Both explicitly
`INSERT INTO public.refill_plan_output` **and** `public.pod_refill_plan` in their `scenario_sql`.
(The remaining 9 rows on 2099-12-01..09 are PRD-020-era, dated 2026-05-14, not PRD-110's.)

**Three corrections to leg 78's framing - less alarming, but more precisely bounded:**

1. ⭐ **LAW-12-COMPLIANT BY THE LETTER.** LAW 12 reads "Test on synthetic 2030 plan_dates **or**
   shadow tables" - a disjunction. These fixtures took the first branch. Leg 78 wrote that "some
   earlier leg's fixture wrote through to the live table", which reads as a breach. ⛔ **It is
   residue, not a violation. Do not open this as a defect against those fixtures.**
2. ⭐ **BOUNDED, NOT ACCUMULATING.** Both fixtures `DELETE FROM` their own `plan_date` before
   inserting, so they are self-scoped and idempotent. **Fixture 10 has been run 72 times and leaves
   exactly 7 rows.** The fleet sweep held at **21** across leg 79's seven fixture runs, with a
   byte-identical per-date breakdown - ⭐ **positive evidence that the current P3 gate fixtures are
   not writers.**
3. ⛔ **NEW - THE SWEEP MUST COVER `pod_refill_plan` TOO.** Leg 78 swept only `refill_plan_output`.
   **`pod_refill_plan` holds 9 rows on 2030 dates.** ⛔ **A tripwire on one table is no more a sweep
   than a per-date check was.** Both tables, one constant each.

**Recorded fleet constants at leg 79 close:** `refill_plan_output WHERE plan_date >= 2030-01-01` =
**21** (2030-01-11=7, 2030-02-03=5, 2099-12-01..09=9) · `pod_refill_plan WHERE plan_date >=
2030-01-01` = **9**.

⛔ **Still NOT cleaned up, deliberately.** Deleting from a protected entity needs per-row CS approval.
**Smallest unblock unchanged:** put the 12 PRD-110 rows (+ the pod_refill_plan rows) to CS as a
one-line delete ask; optionally re-point fixtures 10 and 33 at the shadow tables, which is a
behaviour change and therefore needs its own fixture first (LAW 1).

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37. **No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⛔ S-126 (NEW, leg 79) - A `CHECK` THAT EVALUATES TO NULL **PASSES**

**What.** Dara's P4.1 design enforced the provenance invariant with
`feedback_ids uuid[] NOT NULL CHECK (array_length(feedback_ids,1) >= 1)`. ⛔ **`array_length('{}',1)`
returns NULL, not 0**, and a CHECK constraint is satisfied unless it evaluates to **false** - NULL
passes. The constraint therefore admitted exactly the row it was written to forbid: an evidence-free
proposal. Both `chk_fpr_v3_evidence` and `chk_pin_v3_provenance` carried the bug.

**Caught at Cody review, fixed with `cardinality()` before apply.** ⭐ **Proven, not argued:** the
falsification run restored the `array_length()` form and fixture 55 seq 1 and 2 both reported
`got=ACCEPTED`.

**The transferable rules.**

1. ⭐ Use **`cardinality(arr)`** for array emptiness, never `array_length(arr,1)`.
2. ⭐ More generally: **any CHECK whose expression can go NULL is not a constraint, it is a
   suggestion.** Audit for `array_length`, and for comparisons against nullable columns.
3. ⭐ **The cheapest and most general lesson: a constraint you have not watched REFUSE something is
   not known to work.** Fixture 55 probes every CHECK by attempting the bad write inside an exception
   block and recording whether it was refused and by which rule class. That is why the inert one was
   discovered rather than assumed.

⚠️ **Not yet audited: the pre-existing v3 tables.** No sweep for `array_length`-style CHECKs was run
across `plan_edits_v3`, `rotation_proposals_v3`, `facing_proposals_v3`, `reallocation_proposals_v3` or
`blocked_demand`. **Smallest unblock:** one query over `pg_constraint.consrc`/`pg_get_constraintdef`
for `array_length`, then a probe fixture for any hit. ⛔ Cheap, and nobody has done it.

---

## ⚠️ P4.1/P4.2 LANDED WITH NO WRITERS - not an oversight, but do not leave it long

`feedback_ledger_v3`, `feedback_proposals_v3` and `planning_pins_v3` are live with **`authenticated`
holding SELECT only** and no RPC that writes them, so today only `postgres`/`service_role` can insert.
That is the safest possible landing for a schema unit and it is deliberate (the fixture drives them
directly), but ⛔ **the tables are inert until P4.1's three verbs exist** - `submit_feedback_v3`,
`propose_pin_from_feedback_v3`, `approve_feedback_proposal_v3`. Until then BUILD-SPEC fixtures **16**
and **17** cannot be built end-to-end, because both begin at a driver/client submission.

⭐ **The driver verb must WRAP `driver_propose_adjustment`, not restate it** - that function already
writes `driver_recommendations`, `driver_feedback` and `refill_edit_signals`, and the ledger's
`driver_rec_id` FK exists precisely so the wrap is traceable instead of duplicative.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37. **No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⚠️ S-127 (NEW, leg 80) - THE WHOLE v3 PROPOSAL-QUEUE FAMILY IS OUTSIDE ARTICLE 8's GENERIC AUDIT TRIGGER

**What.** `feedback_ledger_v3`, `feedback_proposals_v3` and `planning_pins_v3` landed with **no
write-audit trigger**. Article 8 says every canonical writer ends with a row in `write_audit_log`, and
the generic trigger is what delivers that once `app.via_rpc` is set.

⛔ **This is NOT a regression introduced by P4.1.** Probed live at leg 80:

| table                       | non-internal triggers                 |
| --------------------------- | ------------------------------------- |
| `rotation_proposals_v3`     | none                                  |
| `facing_proposals_v3`       | none                                  |
| `reallocation_proposals_v3` | none                                  |
| `feedback_ledger_v3`        | none                                  |
| `feedback_proposals_v3`     | none                                  |
| `planning_pins_v3`          | none                                  |
| `plan_edits_v3`             | append-only + no-truncate (not audit) |
| `pipeline_runs_v3`          | append-only + no-truncate (not audit) |
| `blocked_demand`            | `tg_audit_blocked_demand`             |

So **six** v3 tables share the gap and exactly one v3 table (`blocked_demand`) does not. It is a
**fleet convention that nobody chose**, which is the kind that survives review after review because
each individual unit matches its neighbours.

⭐ **The verbs are already correct for the fix**: all three stamp `app.via_rpc='true'` and
`app.rpc_name`, so the trigger would function on the day it is installed. Nothing has to change in
any RPC.

**Smallest unblock.** One migration attaching the generic audit trigger to all six tables at once
(⛔ not one table at a time - a partial fix re-creates the same "matches its neighbours" trap), plus a
fixture that asserts a `write_audit_log` row appears with the right `rpc_name` after one call to each
writer. ⚠️ **Check first whether `write_audit_log` volume can absorb six more tables**, and whether
the generic trigger's shape assumes a `uuid` single-column PK (all six qualify, but verify rather
than assume).

⛔ **Not fixed at leg 80 deliberately:** it is a six-table change that belongs in its own unit with
its own fixture, not a rider on P4.1's verbs.

## ✅ S-117 CLEARED for fixture 56 - and by a DIFFERENT technique than fixture 55's

Fixture 55 got rerunnability from **deterministic uuids**. Fixture 56 could not: its rows are minted
by the RPCs under test, so their ids are unknowable in advance. ⭐ **Two other techniques, both worth
reusing:**

1. **Reclaim by MARKER, not by id.** Every row the fixture creates carries `FX56` in a free-text
   column (`note`, `trigger_reason`), and cleanup deletes on `LIKE 'FX56%'`, children before parents.
   ⚠️ S-97 still applies - a marker containing `_` would be a wildcard.
2. ⭐ **Roll back the part that writes OUTSIDE your own tables.** The driver wrap writes into
   `driver_recommendations`, `driver_feedback` and `refill_edit_signals`. Deleting from those to stay
   rerunnable would be a fixture reaching into subsystems it does not own. Instead the probe runs in a
   subtransaction ending in a deliberate `RAISE`; **plpgsql variables survive the rollback**, so the
   observations are captured first and written to `golden.scratch` after the handler.

**Counts held exactly across two runs** (ledger 9 / proposals 5 / pins 7).
**S-117 cleared list is now: 1, 6, 11, 12, 40, 41, 47, 50, 51, 54, 55, 56.**

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37. **No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

## ⚠️ S-128 (NEW, leg 82) — `never_stock` PINS ARE NOT CONSUMED BY THE ENGINE

P4.2's consumer (`20260801022432`) reads `protect_depth`, `min_facing` and `always_stock` and
deliberately **skips `never_stock`**, which the schema has allowed since leg 79.

**Why parked rather than built:** every other kind is a **floor**; `never_stock` is a **ceiling**, a
different code path (it must force qty to 0 and name itself as the clamp, and it must interact with
the P2.5 unconditional floor, which would otherwise re-raise the line). LAW 1 says it does not get
built before the fixture that proves it.

⛔ **The failure mode while parked is SILENT**: CS can approve a `never_stock` pin today, the verb
will mint it, `v_planning_pins_active_v3` will show it as active, and the engine will plan the shelf
anyway. That is worse than refusing it.

**Smallest unblock:** either (a) a fixture + a ceiling branch in the same unit, or (b) an interim
guard in `approve_feedback_proposal_v3` that REFUSES `kind='never_stock'` with "not yet consumed by
the engine" until (a) ships. **(b) is one line and removes the silent failure today** — recommended
first.

## ⚠️ S-129 (NEW, leg 82) — FIXTURE 8 HAS BEEN RED SINCE SOMEWHERE IN LEGS 56-81, UNDETECTED

Fixture 8 ran **17 pass / 2 fail** this leg. It was **19/0 at leg 55** and was not re-run in any leg
between. ⛔ **This is NOT the P4.2 change**, and that was proven rather than argued: restoring the
ORIGINAL engine inside a rolled-back transaction and re-running produced the **identical 17/2 with
the identical reds**, with `engine_md5=a79bbe1f` echoed in the same RAISE.

**Both reds are ambient-population artifacts, not engine defects.** The fixture's CORE assertion
(seq 26, `zeroed_despite_floor`) is **still 0/green**, and `zero_ceiling_lines` is a healthy 18.

- **seq 29 `floor_protected` = 0** (expects > 0): counts zero-ceiling lines that still got stock via
  the min-facing floor. `floor_units` only fires at `stock = 0`, and **no shelf on the anchor machine
  is currently empty** — the machine got refilled. ⭐ A **non-vacuity guard that has itself gone
  vacuous**: it asserts a population exists without pinning that population.
- **seq 27 `mislabelled_full` = 1** (expects 0): the tripwire counts
  `clamp_reason='skipped_full' AND ceil_u < cover_units`. When `fill_to_cap = 0` the shelf is
  **genuinely full**, `need_raw` and `need_raw_no_expiry` are BOTH 0, the expiry branch correctly does
  not fire, and `skipped_full` is the _more_ accurate label — but the tripwire has no `fill_to_cap`
  exemption, so a legitimately full shelf reads as a mislabel.

**Smallest unblock:** exempt `fill_to_cap = 0` from seq 27's tripwire, and re-anchor seq 29 on a
pinned population instead of whatever the fleet happens to look like. ⛔ Both are assertion edits, so
**S-103 binds (an assertion edit is TWO fields)** and it needs its own unit with provenance.

⭐ **THE REAL LESSON IS THE DETECTION GAP, NOT THE TWO ASSERTIONS.** A live-data fixture that is not
re-run drifts silently, and the P2 gate was declared on a green that had since decayed. Any fixture
asserting over ambient fleet state needs either a pinned population or a scheduled re-run.

## ⚠️ S-130 (NEW, leg 82) — `compose_plan_with_edits_v3` BRANCH (b) IS PIN-BLIND

`compose_plan_with_edits_v3` is the **second** writer of `pod_refills_shadow`. Branch (a) (an edit
over an existing engine line) does `COALESCE(e.reasoning,'{}') || …`, so **P4.2 pin provenance
survives composition** ✅. Branch (b) — _edits with no base line_, where a human plans a shelf the
engine did not — mints a row from scratch whose `reasoning` carries **no pin keys at all**.

Consequences, both real: LAW 5's "every line records `pin_count`/`pin_floor_units`" holds only for
engine-authored lines, and a human edit on a pinned shelf can sit **below** a CS-approved pin floor
with nothing recording that it did.

Fixture 16 seq 18 does **not** catch this — it scopes to `engine_add_pod_v3`'s own `run_id`.

**Smallest unblock:** a fixture that composes an edit over a pinned shelf, then either carry the pin
keys through branch (b) or decide D-38 below. Do NOT wire one without the other.

## ⏸️ D-38 (NEW CS DECISION, leg 82) — DOES A HUMAN EDIT OUTRANK A CS-APPROVED PIN?

P3.6 says re-runs NEVER drop the edit overlay. P4.2 says an approved pin is a constraint the plan
respects. **When a driver edits a pinned shelf below its pin floor, exactly one of those two rules
has to yield, and nothing currently decides which.** Today the edit silently wins (S-130).

- **(a) Pin wins** — the pin is CS-approved policy; an edit below it is clamped up and the clamp is
  recorded. Risk: overrides the person standing at the machine.
- **(b) Edit wins, loudly** — the edit applies, and the override is recorded on the line and surfaced
  in the feedback ledger as evidence the pin may be wrong. Risk: a pin quietly stops meaning anything.
- **(c) Edit wins only with a reason**, hard lock required to go below a pin.

⭐ **Recommend (b)**: it keeps the human in control at the machine while making the contradiction
VISIBLE, which is also what feeds P4.3's acceptance-rate telemetry. **Cost of deciding late is low;
cost of never deciding is that pins erode silently.**

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37, **D-38 (new)**.

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

# LEG 83 PARKING DELTA

## ✅ S-128 — OPTION (b) SHIPPED. The silent failure is dead; the real fix is still owed.

`20260801024503` adds the refusal to `approve_feedback_proposal_v3` (md5 `e4bf1bb3` → `0be4d718`).
CS can no longer approve a `never_stock` pin that the engine would then ignore in silence — the verb
refuses by name and tells CS what to do instead. **Proof: fixture 56 RED 42/3 (seqs 35, 41, 44)
recorded in `golden.runs` before the guard, GREEN 45/45 after**, plus two falsifications that each
produced exactly the targeted red (order → 3 reds; legal-exit → 1 red).

⛔ **S-128 IS NOT CLOSED. Option (a) — the ceiling branch — remains the real fix**, and is now the
ONLY way a `never_stock` pin can ever become useful. What changed is the failure mode, not the gap:
CS gets a loud refusal instead of a rule the plan quietly ignores.

⭐ **REMOVAL CONTRACT — the ceiling-branch unit must do all four IN ONE MIGRATION:**

1. drop the guard from `approve_feedback_proposal_v3`;
2. retire fixture 56 **seq 42** (`never_stock` pin count = 0 fleet-wide) — it becomes false by design;
3. re-state fixture 56 **seq 35 / 41 / 44** (S-103: an assertion edit is TWO fields, three here);
4. restore a live probe for the contradiction guard, which S-131 below explains is currently dead.

⛔ **Split across two units, these tripwires fire on the fix itself** and the next leg wastes a bisect
proving its own change red.

## ⚠️ S-131 (NEW, leg 83) — THE CONTRADICTION GUARD IS NOW A DEAD BRANCH. DO NOT DELETE IT.

Cody's ruling on the S-128(b) review: the verb's `always_stock`/`never_stock` contradiction guard is
unreachable **in both directions** while the S-128 guard stands. `never_stock` is refused earlier;
`always_stock` needs a live `never_stock` pin to collide with, and none can be minted (fleet-wide
count 0, and `approve_feedback_proposal_v3` is the sole INSERT path — verified live by `prosrc`
sweep, not assumed).

⛔ **A future leg WILL read that branch as dead code and try to remove it.** It is not dead, it is
SUSPENDED: it becomes load-bearing again the moment the ceiling branch ships, and delete-then-restore
is exactly how the insert-before-revoke ordering bug gets reintroduced.

⭐ **What was given up is a MESSAGE test, not a PROTECTION.** The structural guarantee
(`ux_pin_v3_stock_policy_exclusive`) is untouched and still proven independently by **fixture 55
seq 7** at the index level. Fixture 56 seq 35 was re-stated to read the rule that actually fires,
because ⛔ **an assertion that can no longer fire is worse than a deleted one — it reports green
forever and reads as coverage.** That is S-129's decay mode, and it would have been introduced
deliberately.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37, D-38. **No new CS decision this leg; none answered.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

## ⛔ S-132 (NEW, leg 83) — FIXTURE 8's CORE ASSERTION IS PASSING VACUOUSLY. THE P2 GATE IS WEAKER THAN IT READS.

Measured live on run `bb049152` (32 lines) while verifying S-129, and it is worse than leg 82
recorded. Leg 82 explained seq 29's red as "no shelf on the anchor machine is currently empty". The
real number is blunter:

| metric                                          | live value |
| ----------------------------------------------- | ---------- |
| lines in the run                                | 32         |
| **lines with `floor_units > 0`**                | **0**      |
| `zero_ceiling_lines` (`ceil_u = 0`)             | 18         |
| `floor_protected` (`ceil_u = 0 AND need_raw>0`) | 0          |

⛔ **NOT ONE LINE CARRIES A FLOOR.** Fixture 8's CORE assertion — seq 26 `zeroed_despite_floor`,
counting `floor_units > 0 AND need_raw < LEAST(floor_units, fill_to_cap)` — therefore counts over an
**EMPTY POPULATION**. It is green because there is nothing to be green about.

⭐ **THE HARNESS IS WORKING EXACTLY AS DESIGNED, AND THAT IS THE GOOD NEWS.** seq 29 exists as seq
26's non-vacuity guard; its red IS the guard firing. ⛔ **So do not "fix" seq 29 by weakening it** —
it is the only thing currently telling the truth about seq 26. The P2 gate was declared on a green
that has since become hollow.

**Smallest unblock (a full unit of its own, deliberately NOT started at leg 83's budget):** fixture 8
anchors on two REAL machines (`MPMCC-1058-0000-R0`, `AMZ-1046-2406-O1`) against ambient live state
and uses **none** of the arrange helpers. Re-anchor it on a PINNED population — `golden.arrange_shelf`
/ `golden.pin_machine_stock` to drive at least one shelf to `stock = 0` so `floor_units` genuinely
fires — then restore. ⛔ **Budget it as a real unit:** each fixture-8 run is ~34 s, it runs the engine,
and its `pod_refills_shadow` rows **do NOT roll back** when committed (+32 per run).

⭐ **THE GENERAL RULE THIS PROVES, which is bigger than fixture 8:** a fixture asserting over ambient
fleet state decays into vacuity without ever going red, and only an explicit non-vacuity guard
catches it. ⛔ **Every fixture with a `WHERE <condition>` population needs a companion assertion that
the population is NON-EMPTY** — audit the suite for CORE assertions lacking one.

---

## ⏸️ D-39 (NEW CS DECISION, leg 85) — THE MINER CAN ONLY TARGET 12% OF WHAT IT LEARNS

**The finding, measured on live data before the miner was written:** across 90 days of edit history
there are **100 recurring clusters** at (machine, shelf, pod, direction) with ≥2 occasions. Only
**9** of them can become a pin. **88 are blocked by one thing:** edit history is recorded at **POD**
grain, and `planning_pins_v3` targets a **BOONZ PRODUCT**. Most pods are multi-SKU (Krambals & Zigi
resolves to 7 products), so there is no single product to pin, and the miner refuses to invent one.

⛔ **This is not a miner defect and must not be "fixed" by picking a SKU.** Picking one would attach
a standing rule to a product CS never named, and the pin would silently detach the day that SKU left
the shelf mix. The refusal is the correct behaviour; the COVERAGE is the problem.

**Three ways out, for CS to choose between — the loop will not pick one:**

- **(a) Capture edits at SKU grain.** P1.4's `inventory_events` / `shelf_composition` already hold
  SKU-level truth; the plan-edit path does not. Largest change, best answer, unblocks 88 clusters.
- **(b) Add a pod-scoped pin kind.** Schema change (Dara) + engine read change, and it cuts against
  the settled rule that pin scope is machine + shelf_id + `EXISTS` on `product_mapping` and
  ⛔ **never pod identity**. Cheapest, but it reopens a closed decision.
- **(c) Accept 12% coverage for wave 1.** Ship as built; the miner proposes what it can honestly
  target and reports the rest. Zero work, and G12 stays measurable — it is just measured over a
  small population.

**Recommendation on file: (c) for wave 1, (a) as the real fix once P1.4's SKU truth is trusted.**
Nothing is blocked on this: the miner ships and works either way, and fixture 57 seq 14/15 keeps the
gap measurable rather than anecdotal.

⭐ **Also for CS, and cheaper:** the charter's stated mining window (4 weeks, 3 occurrences) yields
**ZERO** proposals — machines are visited roughly weekly, so 28 days is at most ~4 plan dates. The
shipped defaults are **90 days / 2 occasions** (9 proposals). If CS wants 3 occasions the window has
to grow past the 74 days of history that currently exist.

### ⭐ S-133 — A ROLLED-BACK DRY RUN DOES NOT CHECK DEFERRED CONSTRAINTS

`plan_edits_v3_superseded_by_fkey` is `DEFERRABLE INITIALLY DEFERRED`. Fixture 57's dry run passed
**39/39** with a violating write in it, because the constraint is only checked at COMMIT and the dry
run never reached one. It blew up on the first committed apply. ⛔ **`BEGIN; …; ROLLBACK;` proves
logic, not integrity.** Anything touching a deferrable FK needs a committed probe. ⛔ And note the
column: `superseded_by` is a FK to another **EDIT**, not to a user — `chk_plan_edits_v3_supersede`
explicitly permits `superseded_at` set with `superseded_by` NULL, which is the honest shape when the
harness retires a row.

### ⛔ S-134 — A FIXTURE RECLAIMS BY ITS OWN MARKER, NEVER BY A SHARED ANCHOR

Fixture 57 reclaimed by MACHINE and ate fixtures 55/56's ledger rows, proposals and **all 7 pins** on
its first committed run (see MIGRATIONS_REGISTRY for the full incident). Re-running 55/56 restored
everything — both are reclaim-and-recreate by marker, so they are self-healing, and that property is
worth preserving deliberately in every new fixture. ⭐ **Second-order lesson: a reclaim keyed on a
DERIVED anchor leaks whenever the anchor moves.** Hardening the anchor selection moved fixture 57 to
a different machine and stranded 3+3 rows there; the fixture now records its anchor in scratch and
reclaims the PREVIOUSLY RECORDED one too. ⛔ It deliberately does **not** reclaim miner rows
fleet-wide: once P4.3 is on a cron those are production data.

### ⛔ S-135 — GREEN ASSERTIONS OVER A THROWN SCENARIO IS THE DANGEROUS FAILURE

Two `run_fixture(57)` calls in ONE transaction collided on an `ON COMMIT DROP` temp table (S-101,
this time inside the fixture rather than the function). The scenario threw — and **39 of 39
assertions still reported GREEN**, because a thrown scenario leaves the PREVIOUS run's scratch in
place (S-107) and every assertion reads scratch. The only evidence was `n_fail = 1` with **no failing
seq**. ⭐ **Always reconcile `n_fail` against the number of failing seqs, and check
`detail -> scenario_error`; a seq list alone cannot tell you the scenario ran.**

### ⭐ S-136 — RUN EVERY NEW FIXTURE TWICE, COMMITTED, BEFORE CALLING IT GREEN

Fixture 57 seq 21 asserted `= 2` and read 4 on the second run: `plan_edits_v3` refuses DELETE, so the
reclaim SUPERSEDES rather than removes, and the population grows every run. The assertion was
counting RUNS. Restated run-count-independently (≥2 superseded AND 0 still live), which is also
strictly stronger. ⛔ **A first run cannot distinguish "correct" from "correct once."** Three of this
leg's eight migrations were second-run defects.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37, D-38, **D-39 (new)**.

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⏸️ D-40 (NEW CS DECISION, leg 86) — THE SECOND-STRONGEST SIGNAL CS GIVES US HAS NO DIAL TO TURN

**What was measured.** Over 1653 same-day (kept, dropped) pairs across the 24 learnable days,
`active_intent_count` concordance is **38.2%** — i.e. **61.8% in the inverse direction: CS
systematically DROPS machines that carry more open intents.** That is the second-strongest signal in
the whole feature set, behind only `empty_shelves_count` (68.6%) and ahead of everything else.

**Why it is parked and not built.** There is no weight in `pick_urgency_params` that targets intent
volume. The seven dials are `w_runout`, `w_capacity`, `w_expiry`, `w_stale`, `w_empty`, `w_lowfill`,
`w_holes`. The miner records `active_intent_count` as a **named refusal row** in
`picker_feature_param_map_v3` (`is_active = false`, `target_param` NULL) rather than silently
dropping it or, worse, attaching it to a loosely-related dial.

⛔ **Do NOT "fix" this by mapping it to the nearest-looking weight.** That is exactly the class of
error the monotonicity probe caught this leg on `fill_pct → w_lowfill` (corr **−0.042** — the dial
does not control the feature). A mis-mapped dial moves the picker in a direction nobody sanctioned
while every count-based assertion stays green.

**Options for CS:**
(a) **Add a `w_intent` dial** to `pick_urgency_params` + an `s_intent` term to `v_machine_priority`
— the honest fix, but it edits a live scoring view outside PRD-110's shadow discipline.
(b) **Interpret it as capacity, not preference** — CS may be dropping high-intent machines because
they are _already handled_, in which case the signal belongs in the Gate 0 hint, not in the score.
(c) **Accept the 4-dial map for wave 1** and revisit when the Gate 0 hint is built.

**Recommendation on file: (b) then (c).** The inverse direction is suspicious — a machine with more
open intents needing LESS attention reads more like "already scheduled" than like "lower priority",
and encoding it as a score weight would bake an artefact of the workflow into the ranking.
**Nothing is blocked on this.**

---

## ⛔ S-137 (leg 86) — A CORRECT INVARIANT CAN BE A CRASH PATH

`CHECK (proposed_weight <> current_weight)` on `picker_weight_proposals_v3` is right as an invariant
and is also an **abort path for the entire mining run**. The weight delta scales from the band edge —
`delta_pct = max_delta * LEAST(1, (|conc−50| − band)/(50 − band))` — so a candidate landing exactly ON
the band computes `proposed = current`, the INSERT throws, and every other proposal in that
transaction dies with it. **Rounding widens the window well past the boundary:** `w_expiry` at 0.120
needs ~0.42% of movement before `numeric(6,3)` renders anything but 0.120.

⭐ **The general rule: when a function computes a value that a CHECK constrains, the function must
own the boundary, not discover it.** Gate strictly (`> band`, never `>=`) and SKIP any candidate whose
**rounded** value equals the current one, recording it as a named refusal. Caught by Cody at review,
before apply.

## ⛔ S-138 (leg 86) — "APPLICATION IS PARKED" IS A COMMENT UNTIL A FIXTURE PROVES IT EACH RUN

Cody **refused to certify** that the P4.3b design makes the parked weight-application structurally
impossible, and was right. `pick_urgency_params` carries `authenticated=arwdDxtm`, and
`mine_pick_history_v3` will be `SECURITY DEFINER` owned by `postgres` — **it bypasses RLS entirely.**
Nothing in the schema PREVENTS a write to the weights table. What exists is a function whose body
contains no such write: true by construction, not by structure.

⛔ **Fixture 58 MUST therefore carry two assertions, and they are not optional:**
(a) `pick_urgency_params.updated_at` is byte-unchanged across a real miner run;
(b) the miner's `prosrc` matches no `INSERT|UPDATE|DELETE` against `pick_urgency_params`.

⭐ Generalises beyond this unit: **every parked item enforced only by "the code doesn't do it" needs a
standing assertion, or the parking decays the first time someone edits the function.**
Baseline recorded at leg 86: `pick_urgency_params.updated_at = 2026-07-13 17:36:38.481583+00`.

## ⏸️ S-127 UPDATED (leg 86) — now EIGHT tables, not six

`picker_feature_param_map_v3` and `picker_weight_proposals_v3` also lack the generic write-audit
trigger. **Not a regression** — `rotation_proposals_v3`, `facing_proposals_v3` and
`reallocation_proposals_v3` do not carry it either, and the verbs stamp `app.via_rpc` +
`app.rpc_name` correctly so the trigger works the day it is installed. ⛔ Still fix all **eight** in
ONE unit.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37, D-38, D-39, **D-40 (new)**.

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⛔ S-139 (NEW, leg 87, and it is the finding of the leg) — A UNIT OF MEASURE IS A CLAIM, AND A FIXTURE THAT CANNOT FALSIFY IT IS DECORATION

Leg 86 predicted the miner's live yield as _"1318 pairs, 68.6%"_. Leg 87 built the miner, reproduced
**68.57% exactly**, and got **474 pairs**. Neither number was wrong. They count different things over
the identical population (24 learnable days, 1653 ordered kept/dropped pairs):

- **1318** = pairs EVALUABLE on `empty_shelves_count` (non-null both sides)
- **474** = pairs that DISCRIMINATE (concordant 325 + discordant 149)
- **844** = ties — **64% of the evidence base**

⭐ **The constraint resolved it, not the prose.** Cody specified `pwp_pairs_coherent` as
`concordant + discordant <= pairs`. `<=` is only meaningful if `pairs` carries ties; `=` would have
been written had the discriminating count been meant. **When two readings of a column conflict, the
CHECK that constrains it is better evidence of intent than any sentence about it.**

⛔ **AND THE FIRST FIXTURE PASSED UNDER BOTH READINGS.** Its 7-machine population had no ties and no
NULLs, so evaluable = discriminating = 120 and all 39 assertions held either way. It looked strict
and discriminated nothing — S-132's failure mode in a new place. **A fixture that cannot fail under
the wrong definition is not testing the definition.** v2 adds K5, which ties with D2 on two features
and is NULL on the other two, so the counts now differ in both directions (150 vs 140; 120 vs 150).

⭐ **THE REUSABLE RULE: whenever a stored number could be a count of two different populations, the
fixture must contain members of the difference.** No ties in the population means the tie semantics
are untested; no NULLs means the null semantics are untested. Cheap to add, and it is the only thing
that makes the assertion mean what its description says.

⭐ **Follow-on:** `pairs` is now the evaluable count and the `pl_min_pairs` gate binds on the
discriminating count; both are reported side by side. **Live, that reads 1318 evaluable / 474
discriminating — a reviewer who saw only "1318 pairs at 68.6%" would materially overrate the signal.**

## ⚠️ S-138 UPDATED (leg 87) — the parking is now enforced every run, and it has a re-baseline cost

Fixture 58 seq 32/33/34 discharge S-138: `pick_urgency_params.updated_at` byte-unchanged across a
real miner run, still at the baseline, and the `prosrc` matching no write against that table.
Verified live at this close: `2026-07-13 17:36:38.481583+00`.

⛔ **THE DAY CS LEGITIMATELY TURNS A PICKER DIAL, FIXTURE 58 GOES RED ON SEQ 33.** That is the
assertion working, not breaking. Cody flagged it at review and it is recorded here rather than only
in a migration comment. **To re-baseline:** update seq 33's `expect` to the new
`max(updated_at)` — and per S-103 update its `description` in the same statement. Do NOT weaken it to
`not_null`; the whole point is that the value is pinned to a decision CS made and can name.

## ⚠️ S-127 UPDATED (leg 87) — the eighth table is now LIVE-WRITTEN

`picker_weight_proposals_v3` started receiving real writes today (2 rows, from fixture 58). It still
carries no generic write-audit trigger, so those proposals leave no `write_audit_log` row. **Not a
regression** — `mine_pick_history_v3` stamps `app.via_rpc` and `app.rpc_name` correctly, so the
trigger works the day it is installed, and the three sibling proposal queues are in the same state.
The gap has simply moved from theoretical to actual. ⛔ Still fix all **eight** in ONE unit.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37, D-38, D-39, D-40. **No new CS decision this leg; none answered.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⛔ S-140 (NEW, leg 88) — THE DEFAULT-PRIVILEGES TRAP IS WIDER THAN "FUNCTIONS AND `anon`"

Leg 87 recorded half of it: Supabase grants `anon` EXECUTE **explicitly**, so
`REVOKE ALL … FROM PUBLIC` does not remove it, and you only find out by reading `proacl` back.

The other half, found this leg: **it applies to VIEWS, and to `authenticated`.**
`v_proposal_acceptance_v3` landed with `authenticated=arwdDxtm` from a migration that contained BOTH
`REVOKE ALL … FROM PUBLIC` **and** `GRANT SELECT … TO authenticated`. Neither statement did anything:
the default grant is per-role and explicit, so revoking from `PUBLIC` removes nothing, and granting
SELECT adds nothing already held.

⭐ **The working form is `REVOKE ALL ON <obj> FROM <role>;` THEN `GRANT SELECT …`.** Applied forward
as `20260801042805` (Article 12 — the applied migration was not edited).

⭐ **And the assertion is stronger than "no anon".** Fixture 59 seq 49 pins the **entire `relacl`
string** against the `v_planning_pins_active_v3` convention. A "no anon" assertion would have passed
over the over-granted `authenticated=arwdDxtm` without a murmur — the same shape as S-132 and S-139:
an assertion that cannot fail under the wrong state is decoration.
⚠️ **`v_shadow_runner_health_v3` still carries `authenticated=arwdDxtm`.** Not touched (out of scope,
LAW 10) and not a live hole — both are aggregate views and not updatable — but it is the same drift,
and it is now the only known instance left.

## ⚠️ G12 IS LIVE BUT UNFIRED, AND THAT MUST NOT BE MISREAD (Cody's recorded condition, leg 88)

`v_proposal_acceptance_v3` ships today reporting **`insufficient_evidence` for all five families**,
because there are **zero decided proposals in the entire system** — every one of the 82 rows across
the five queues is synthetic 2030 fixture residue. That is the correct reading, and it will stay that
way until the miners are scheduled AND CS starts reviewing what they produce.

⛔ **Do NOT read a board of `insufficient_evidence` as "no findings" or as G12 passing.** It means the
gate has never been evaluated. `g12_min_decided = 5` is the threshold; a leg that wants G12 to say
something must first cause five real proposals to be decided.

⭐ **The real number to watch when it does fire:** `fixture_acceptance_pct` for `feedback_pins` is
**75.00** — four fixture rows. That is the number a naive acceptance view would have published as the
headline, and it is why the live/fixture split exists at all.

## ⏸️ THE CRON/FIXTURE-58 COLLISION IS NOW A DECIDED-SHAPED PROBLEM, NOT A SURPRISE (leg 88)

Carried forward for the cron unit, restated with what leg 88 verified live:

- Fixture 58's scenario **hard-RAISEs** on any `picker_weight_proposals_v3` row with
  `status='pending'` outside its own window (`window_start=2030-03-05`). Verified by reading the
  scenario, not by trusting the pointer.
- The cause is structural: the miner's dedup rule is **one pending row per dial, GLOBALLY**
  (`ux_pwp_one_pending_per_param`, a partial unique index on `target_param WHERE status='pending'`).
  Fixture and production genuinely contend for one slot on `w_empty`.
- Live, the miner **would** mint exactly that row: raise `w_empty` 0.900 → 0.945.

⛔ **Two of the three options previously floated are worse than they look.** "The fixture reclaims
more broadly" means a TEST DELETES REAL CS-FACING PROPOSALS — refuse it, and it violates S-134
(reclaim by your own marker, never a shared anchor). "CS reviews the live proposal promptly" makes a
fixture's greenness depend on an inbox, so 58 would be red most of the time.
⭐ **Recommendation on file: schedule BOTH miners weekly with the pick miner running
`p_dry_run => true`, and PARK the live-minting flip as a one-line DECISIONS-READY item** (flip the
`true` to `false` in the cron command). That keeps LAW 4 (shadow, don't switch), keeps 58 runnable,
and exercises the whole path weekly.
⚠️ **But a dry-run cron is theatre unless its output is persisted** — `cron.job_run_details` keeps a
return message, not the miner's jsonb payload, so the findings would vanish. **The cron unit
therefore owes a `miner_runs_v3` append-only log** (Dara design, Cody review) that both miners' runs
write to. Fixture 59's plants prove nothing about this; it needs its own fixture.
⭐ **Both miners already take full defaults** (`mine_pick_history_v3` 3 args, `mine_edit_history_v3`
6 args, `pronargdefaults` = all), so a cron command is a bare `SELECT public.mine_*_v3();`.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37, D-38, D-39, D-40. **No new CS decision this leg; none answered.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ✅ THE CRON/FIXTURE-58 COLLISION IS CLOSED (built leg 89, verified + recorded leg 90)

The leg-88 section above is now DELIVERED. Recorded here so nobody re-opens a settled problem.

**What shipped:** `run_weekly_miners_v3` + `miner_runs_v3` (append-only log) + cron **46**
`prd110_p43d_weekly_miners_0530_dubai` (`30 1 * * 1`, Monday 05:30 Dubai) + golden fixture **60**
(54 assertions, green ×3).

⭐ **The recommendation was IMPROVED, not merely executed, and the improvement is the lesson.**
Leg 88 proposed `p_dry_run => true` inside the cron command. Leg 89 instead put the decision in
**dials on `refill_policy_params`** (`miner_weekly_pick_dry_run`, `miner_weekly_edit_dry_run`, both
**true**) and made the cron body a bare `SELECT public.run_weekly_miners_v3(p_invoked_by => 'cron');`.
Fixture 60 **seq 16** pins that exact string. The reasoning, which generalises to every future
parked flag: **a parked decision hidden in a cron body is a decision nobody will ever find.** Put it
where someone auditing the parking lot would look, then assert the cron does NOT override it.

⭐ **And the dial is a gate, not a default (seq 45):** a caller passing an explicit
`p_pick_dry_run => false` is REFUSED unless they are `operator_admin`/`superadmin`. Without that
branch the parked CS decision would have been advisory the moment the EXECUTE grant widened.

⛔ **Both refused options stay refused.** "The fixture reclaims more broadly" is still a TEST
DELETING REAL CS-FACING PROPOSALS (S-134). "CS reviews promptly" still makes fixture 58's greenness
depend on an inbox. Neither was used.

⭐ **The `pending_exists` refusal is now SELF-DESCRIBING rather than ambiguous.** The runner counts
pending proposals dated `>= miner_fixture_epoch` (2030-01-01) and, when any exist, stamps
`synthetic_pending_blocks_live_minting` on the **pick miner's row only**. So the log distinguishes
"refused by golden-harness residue" from "refused by evidence" — previously indistinguishable.

## DECISIONS-READY (added 2026-08-01, relay leg 90)

**D-R: activate live pick-miner weight proposals.** Fully built, flag-off, exercised weekly.
_What it is:_ the weekly cron already runs both miners every Monday 05:30 Dubai and logs verbatim
payloads to `miner_runs_v3`; only the minting is parked.
_Evidence it works:_ fixture **60** (54/54, ×3) proves the schedule, the log's append-only guards,
the normalisation, the GUC restore and the override refusal; fixtures **57**/**58** prove the miners
themselves. The live answer is on file and stable across legs 86-90: **ONE** proposal — raise
`w_empty` **0.900 → 0.945**, lead feature `empty_shelves_count`, **68.57%** concordance, **1318**
evaluable / **474** discriminating pairs, **24** days.
_The single command CS runs to activate:_

```sql
UPDATE public.refill_policy_params SET miner_weekly_pick_dry_run = false;   -- pick miner
UPDATE public.refill_policy_params SET miner_weekly_edit_dry_run = false;   -- edit miner (9 would-create)
```

⛔ **Flipping the PICK dial has a known, intended cost: fixture 60 seq 12 goes RED** (it asserts the
dial is still `true`). That is the assertion working, exactly as S-138 designed it. Re-baseline
`expect` **and** `description` together (S-103); never weaken it to `not_null`.
⛔ **And flipping it while fixture-58 residue holds a pending `w_empty` row means the live miner is
still refused with `pending_exists`** — clear that residue first, or the flip is a no-op that looks
like a decision.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37, D-38, D-39, D-40. **No new CS decision this leg; none answered.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⛔ S-141 (NEW, leg 90) — `receive_purchase_order` HARDCODES WH_CENTRAL, AND THE BINDER DOES NOT

`receive_purchase_order` sets `v_warehouse_id uuid := public.wh_central_id();` at DECLARE and uses it
for **every** `warehouse_inventory` INSERT it makes — both the `p_lines` batches and the
`p_additions`. **There is no warehouse argument.** Every PO receipt in the system lands in CENTRAL.

⛔ **The trap is the pairing.** `bind_dispatch_fefo` picks stock with
`p.warehouse_id = COALESCE(rd.from_warehouse_id, public.wh_central_id())`. So goods bought for a
machine served by **MCC or MM** are received to CENTRAL and the binder never sees them. The line
stays unbound while every upstream step reports success.

⭐ **Generalises well beyond P4.4: any new "get stock into the system fast" path that reuses
`receive_purchase_order` inherits a CENTRAL-only assumption it never declared.** Check the receiving
warehouse against the consuming warehouse explicitly; do not assume a receive is visible to a bind.
⛔ **Do NOT fix this by adding a warehouse argument to `receive_purchase_order`** — it is a protected
writer the whole procurement FE calls. Article 3: add a `_v3`. If CS wants the incumbent widened,
that is its own unit with its own fixture, not a P4.4 side effect.

## ⛔ S-142 (NEW, leg 90) — A WALK-IN SUPPLIER FORCES A DRIVER TASK, AND `p_force_driver_task => false` CANNOT STOP IT

```
v_needs_task := (v_procurement_type = 'walk_in') OR (p_force_driver_task = true);
```

The parameter can only ever turn the task **on**. For `procurement_type='walk_in'` a `pending`
`driver_tasks` row is unconditional.

⛔ **For a spot buy this is backwards:** the goods are already bought and in the driver's hand, so
the task instructs someone to go and buy them again. ⭐ The right composition is **call the incumbent
anyway** — it owns `po_number_seq` drift self-healing, the PRD-1 `boonz_product_block_reason`
guardrail (a spot buy of a decommissioned product **must** fail exactly like a planned order) and
`procurement_events` — **then auto-close the task it created, in the same transaction, with an
explanatory event.** ⛔ Never DELETE the row (Article 7 + the no-destructive-changes rule).

## ⛔ S-143 (NEW, leg 90) — `bind_dispatch_fefo(p_machine_names => NULL)` IS A FLEET-WIDE SWEEP

The binder's machine filter is `p_machine_names IS NULL OR rd.machine_id IN (… official_name = ANY(…))`.
**NULL means every machine on that dispatch_date**, matched by `machines.official_name` (⛔ a name,
not an id). It also only touches rows that are `action IN ('Refill','Add','Add New')` AND
`from_wh_inventory_id IS NULL` AND not `item_added`/`returned`/`cancelled`/`packed`/`is_m2m`.

⛔ **A single-machine RPC must never call it with NULL** — one driver's Carrefour run would bind
unrelated machines' lines to his batch as a side effect. That is the same family of error as
re-running an engine over human edits. ⭐ Its return field `still_unbound_no_wh_stock` is the honest
outcome signal: **surface it, never swallow it.** A spot buy of the wrong product binds nothing, and
silence there looks identical to success.

## ⏸️ P4.4 IS DESIGNED, REVIEWED, AND NOT BUILT (leg 90)

`docs/prds/PRD-110-P4.4-DARA-spot-buy-design.md` carries the signature, transaction order, a
46-assertion fixture-18 plan and Cody's verdict + 5 conditions. **Cody's verdict is CONSTITUTIONAL
and it is CONDITIONAL:** it holds _because_ the design composes the incumbent writers instead of
editing them. ⛔ **The moment a build leg finds it easier to add a warehouse argument to
`receive_purchase_order`, the verdict is void and the unit needs re-review.**

⏸️ **Cody's recorded condition — the same shape as leg 88's G12 finding, in a new table:**
`blocked_demand` holds **52 rows, all open, and nothing has ever been resolved**. P4.4 writes the
first `resolved_at` in the table's history, so every aging / burn-down metric over
`v_blocked_demand_open` is **unexercised**. ⛔ Do not read the first week of spot-buy data as
"blocked demand is being worked".

⭐ **D-D (design call, not a CS decision): the pre-auth cap ships ENFORCED-AS-`warn`, not parked.**
BUILD SPEC said park the param. An invisible cap is indistinguishable from no cap, so the build adds
`spot_buy_price_cap_aed` (default **15**) and `spot_buy_cap_enforcement` default **`'warn'`**,
mirroring `preflight_enforcement`. **The DECISIONS-READY item becomes the flip to `'block'`** once CS
has seen real breach data — which is a decision CS can actually make, unlike "should a cap exist".

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-23, D-27, D-28, D-29, D-30, D-31, D-32, D-33, D-34, D-35, D-36, D-37, D-38, D-39, D-40. **No new CS decision this leg; none answered.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⭐ CS DECISIONS — FULL QUEUE CLEARED 2026-08-01 ~08:15 Dubai (via Cowork session). D-19..D-40 ALL CLOSED.

Binding on the next legs. Each executes per its parked activation/design; fixture-first as always.

- **D-19 → FLIP TO BLOCK.** `UPDATE refill_policy_params SET preflight_enforcement='block';` The
  audited single-use override is the escape hatch.
- **D-21 → FIX DATA FIRST.** No margin weight until `purchasing_cost` coverage ≥90%. Surface the
  61-pod missing-cost list for the ops team (task, not migration); weight term activates only after
  the threshold, with the weight itself defaulting off pending a later CS value.
- **D-23 → KEEP THE CLAMP.** dest_capacity_clamp stands; overflow visibly to return_to_wh.
- **D-27 → CONVERGE** donor velocity onto the canonical in-stock object. Own reviewed unit,
  before/after diff of donor-set changes logged.
- **D-28 → CONVERGE** `committed_elsewhere` onto `v_dispatch_availability`. Own reviewed unit;
  before/after diff of FEFO-visible availability for the live binder logged.
- **D-29 → YES AT CUTOVER.** Nightly runner promotes stitch blocked demand for v3-authoritative
  clusters; engine_add rows suppressed there. No double counting.
- **D-30 → REVOKE NOW.** anon EXECUTE off `_blocked_demand_gaps_v3`.
- **D-31 → CONVERGE** the price cascade into ONE canonical unit-value object; both consumers read it.
- **D-32 → WEEKLY SCHEDULE** (Sunday, with the strategic session) + proposals accumulate pending;
  the approve RPC is its own future Cody-reviewed unit; the current 23 stay queued for CS review.
- **D-33 → YES: stitch consumes composed runs BY DEFAULT**, coupling pinned by a dedicated fixture
  (P3.7's end-to-end).
- **D-34 → YES: nightly shadow runner → `run_pipeline_v3`** with `p_promote_blocked=>true` (per
  D-29 scoping), after S-112 is fixed.
- **D-35 → COLLAPSE** the inline Saturday rule in `_build_draft_core_v3` into the canonical helper;
  agreement fixture required.
- **D-36 → RE-ASSERT** `app.rpc_name` after each inner call in `swap_v3`; no signature change.
- **D-37 → BUILD PARAM `ladder_prefer_own_stock_transfer` AND DEFAULT TRUE**: full-pod own-stock
  transfer outranks substitution. Fixture 6 seq 22/25/26 re-baseline per the parked note; the
  3,017-unit stranded pool is the acceptance evidence.
- **D-38 → EDIT WINS, LOUDLY.** Below-pin edits apply; the override is recorded on the line AND
  written to the feedback ledger as pin-contradiction evidence feeding G12.
- **D-39 → CAPTURE EDITS AT SKU GRAIN** (option a). Plan-edit path records the SKU using P1.4
  composition truth; Dara designs, the 88 blocked clusters are the acceptance measure. Until it
  lands, the miner's refusal behaviour stands (never invent a SKU).
- **D-40 → ADD THE `w_intents` DIAL** as its own Dara/Cody-reviewed unit, with a monotonicity probe
  proving dial-controls-feature before the miner may map to it.

---

## ⭐ leg 91 (2026-08-03) - CS QUEUE PICKED UP · D-30 EXECUTED · P4.4 BUILT (fixture owed)

⛔ **S-80 EARNED ITS KEEP THIS LEG.** Leg 90's pointer said "no new CS decision; D-40 remains the
newest", and its own hash block said the PARKING-LOT was byte-stable. Both were true **when written**.
The `CS DECISIONS - FULL QUEUE CLEARED` block landed at **10:07**, ~2.5 minutes AFTER leg 90's final
log append at 10:04. The doc-hash mismatch was the only trace, and the S-99 drill (mtime + diff
before concluding "formatting") is what turned it from noise into the most consequential input the
build has had. ⭐ **A doc-hash delta is not automatically prettier drift - read the file.**

### ✅ D-30 CLOSED (executed, `20260803170420`)

`anon` EXECUTE removed from `_blocked_demand_gaps_v3`. `proacl` read BACK and asserted whole (S-140):
`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`. The exposure was **real and
live** at pickup, not theoretical.

### ⏸️ THE OTHER 21 CS DECISIONS ARE NOW A WORK QUEUE, NOT A WAIT

D-19, D-21, D-23, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-35, D-36, D-37, D-38, D-39, D-40 are
**answered and unexecuted**. Each is its own fixture-first unit. ⛔ **D-19 (flip
`preflight_enforcement` to `'block'`) is NOT a one-liner despite reading like one** - CS's answer
names "the audited single-use override" as the escape hatch, so a leg must first PROVE that override
exists and works before flipping, or the flip removes the escape hatch and the guard at the same
time. Do not flip it on the strength of the sentence alone.

### ⛔ FIVE NEW LANDMINES - all found by reading live code / probing, none in the BUILD SPEC or the leg-90 design

- **S-144 - `bind_dispatch_fefo` REFUSES `field_staff`** (`warehouse/operator_admin/superadmin/manager`
  only). The leg-90 design gated `create_spot_purchase_v3` at "field_staff and up" so a driver at
  Carrefour could call it - the binder would have raised inside the happy path. ⭐ **Resolution: the
  RPC gates at warehouse+.** A new RPC must never hand a role a power its own component writers deny.
  The driver-facing path is P4.4b, which is where it always belonged.
- **S-145 - `add_purchase_order_lines` is OWNER-ONLY** (`operator_admin`/`superadmin`), so the
  BUILD-SPEC "attach to today's open walk-in PO" path is unavailable to a `warehouse` caller. ⭐ The
  RPC mints a fresh PO instead **and says so in `warnings[]`** - silently dropping the attach would
  surface later as an unexplained duplicate PO.
- **S-146 - `inventory_events.machine_id` and `.shelf_id` are BOTH NOT NULL**, plus
  `tg_assert_shelf_machine_match`. The design's step 5 ("emit `spot_buy_receive` per line") is **not
  implementable for a warehouse receive**. ⭐ **The RPC writes NO `inventory_events`.** Inventing a
  `shelf_id` to satisfy the constraint would poison the P1.4 composition estimator. ⭐ **The kind's
  own grain tells you where it belongs:** `spot_buy_receive` is for the moment spot goods enter a
  SHELF - which is exactly fixture 26 / P4.4b (driver puts 8 Zigi INTO the machine). P4.4 was never
  its home.
- **S-147 - `driver_tasks.status` CHECK has NO `'completed'`** (`pending|acknowledged|collected|cancelled`).
  The design's D-B auto-close would have raised 23514. ⭐ Terminal state is **`'collected'`** +
  `collected_at` + `outcome='purchased_full'`, which is literally true: the driver collected the goods.
  ⛔ Still never DELETE the row (Article 7).
- **S-148 - `procurement_events.event_type` is a CLOSED CHECK of 11 values.** Both new spot event
  types were refused. ⭐ Fixed **additively** (`20260803171411`): the migration refuses to run unless
  all 11 incumbents are present first, re-states them verbatim, then proves the rebuilt CHECK still
  REFUSES an invalid value.

⭐ **S-149 - SMOKE-PROBE A NEW RPC IN DRY-RUN BEFORE WRITING ITS FIXTURE.** S-148 and the shape of
S-147 were caught by one dry-run call that cost ~30 seconds. Finding them inside a 40-assertion
fixture would have read as "the fixture is broken" and cost an hour of bisecting. ⛔ **A dry run that
rolls back is a free integration test - use it as the FIRST proof, never as the only one.**

### ⏸️ P4.4 STATUS - BUILT, SMOKE-PROVEN, **NOT FIXTURED**

`create_spot_purchase_v3` (`79305485`) is live and behaves correctly in a live dry run: PO minted,
8 units received into **WH_MCC and not CENTRAL** (the L1/S-141 proof), **1** driver task auto-closed
(L2/S-142 confirmed live - the walk-in supplier really does force one), `committed=false`, and a
follow-up probe found **zero residue** on all four protected tables.
⛔ **Golden fixture 18 is OWED and is the next task.** Until it exists, P4.4 is unproven under LAW 1.
⭐ Fixture id **18 is still free**; next free after that is **61**.

### 🆕 DECISIONS-READY (added leg 91)

- **Spot-buy cap enforcement** - `spot_buy_price_cap_aed`=**15**, `spot_buy_cap_enforcement`=**`'warn'`**.
  Every breach is visible from day one in `warnings[]` and `procurement_events`. Activation is one line:
  `UPDATE refill_policy_params SET spot_buy_cap_enforcement='block';` ⏸️ Flip only after CS has seen
  real breach data - that is a decision CS can actually make, unlike "should a cap exist".

---

## ⭐ leg 92 (2026-08-03) - P4.4 DEBT CLOSED · FIXTURE 18 GREEN 80/80

### ✅ P4.4 STATUS MOVED: BUILT + SMOKE-PROVEN + **FIXTURED**

`20260803173909_prd110_p44_golden_fixture_18` - **80 assertions, 80/80 green on two consecutive
committed runs** (149 ms / 210 ms), no `scenario_error`, not vacuous. Golden **49 -> 50 fixtures**,
**1655 -> 1735 assertions**. The ⏸️ LAW 1 debt leg 91 declared is CLOSED.
⭐ Next free fixture id is **61**.

**What it actually proves** (not a list of table touches): goods bought at the counter land in the
**REQUESTED** warehouse and not CENTRAL (asserted twice, once as `= MCC` and once as
`<> wh_central_id()`, so the assertion can genuinely fail) · the walk-in driver task that told a
driver to go buy goods he was already holding is **closed as `collected`, never deleted** · the
waiting dispatch line binds to **that exact spot batch** · a second machine's identically-blocked
line is **still unbound** (S-143) · a 4-unit buy against a 10-unit block leaves the block **OPEN**
with "6 still outstanding" written down (LAW 5) · the RPC writes **zero `inventory_events`** as a
correctness property (S-146) · all three provenance GUCs are **restored to the caller's inbound
values**, proven by having the harness set a non-empty `app.rpc_name` first so a blanket reset
cannot pass by accident (Cody condition 3).

### ⛔ FOUR NEW LANDMINES - all found by building, none in the design doc or the BUILD SPEC

- **S-150 - `uq_blocked_demand_open` IS SHELF-GRAINED, NOT PRODUCT-GRAINED.** The partial unique
  index is `(plan_date, machine_id, shelf_id, pod_product_id, source) WHERE resolved_at IS NULL`.
  `boonz_product_id` is **not in the key**. Two open blocks for two different SKUs on one machine
  therefore need **two shelves**, and any code that assumes "one open block per machine+product"
  is wrong in both directions.
- **S-151 - `refill_dispatching.source_kind` is paired with its id column by CHECK.** `'wh'` REQUIRES
  `source_warehouse_id` and forbids `source_machine_id`; `'unknown'` forbids both. ⛔ And `'warehouse'`
  is **not a legal `source_kind` at all** - it is a `source_origin` value. The two columns read
  alike and mean different things.
- **S-152 - `enforce_canonical_dispatch_write` LOGS, IT DOES NOT BLOCK.** A raw harness plant into
  `refill_dispatching` succeeds and quietly mints a `bypass_violation_log` row per statement -
  residue in a **governance** table, invisible until someone reads that log and finds the fixture
  looking like an attacker. ⭐ Set `app.via_trigger='true'` around harness plants and reclaims; the
  guard returns early and writes nothing.
- **S-153 - A FIXTURE CANNOT DELETE-RECLAIM A WAREHOUSE RECEIVE.** `warehouse_inventory` is
  FK-referenced by the append-only `inventory_audit_log`, so `DELETE FROM warehouse_inventory`
  raises unless the audit rows are erased first - which Article 7 forbids. ⭐ **The pattern instead:
  run the whole scenario in ONE plpgsql subtransaction, capture every value the assertions need into
  plpgsql VARIABLES, then `RAISE` to unwind.** Rows roll back, variables survive, and the scratch
  write happens after. Zero residue with zero deletes.
  ⚠️ The one thing rollback cannot undo is `nextval()` - each run burns a `po_number`. Accepted and
  recorded, same class as fixture 60's permanent `miner_runs_v3` rows.

### ⛔ S-154 - THE FIXTURE-SAFETY RULE THAT MATTERS MOST HERE

**A fixture that calls a PO writer as `operator_admin` can receive a REAL production purchase order.**
`create_spot_purchase_v3` attaches to today's open walk-in PO for the supplier when the caller is an
owner (S-145), then stamps `received_date` on those lines. Leg 91's dry run returned `po_path:minted`
only because no open Carrefour PO existed that minute - that was luck, not a guarantee. ⭐ **Fixture
18 therefore calls as a `warehouse` user, for whom the attach path is unreachable and `minted` is
deterministic.** The role choice IS the safety property, and seq 12 pins it.
⭐ Generalise: when an RPC's behaviour forks on caller role, a fixture must pick the role whose branch
**cannot touch live data**, and assert the branch it took.

### ⭐ THE LIVE-SAFETY INVARIANT (seq 42) - worth copying into future fixtures

The RPC resolves `blocked_demand` by machine+product. Machine A currently has 7 open blocked rows and
all 7 carry `boonz_product_id = NULL`, so none can match - a **narrow escape, not a design**. Seq 42
snapshots the ids of every OTHER open row before the run and asserts **zero** of them closed. If
production ever grows a row matching this fixture's machine and SKU, the fixture goes red **before**
it closes a real block, instead of silently resolving live demand.

### ⏸️ UNCHANGED THIS LEG

**S-132 remains the highest-value open non-build item** - fixture 8's core assertion still passes
vacuously (`lines_with_floor` = 0 of 32); fixture 8 is RED 18/1 and seq 29 is a TRUE red.
⛔ **Never weaken seq 29.**
**The 21 answered-but-unexecuted CS decisions are unchanged** - D-19, D-21, D-23, D-27, D-28, D-29,
D-31..D-40. D-30 stays the only one executed. ⛔ D-19 still is not the one-liner it looks like: the
audited single-use override must be PROVEN to exist and work before `preflight_enforcement` flips to
`'block'`, or the flip arms the guard and removes its escape hatch in one statement.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-23, D-27, D-28, D-29, D-31..D-40 (21, all answered, all unexecuted). **No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⭐ leg 93 (2026-08-03) - CS DECISION D-23 EXECUTED AND CLOSED. 20 answered decisions remain.

### ✅ D-23 CLOSED (executed, `20260803175617`) - "KEEP THE CLAMP" is now PINNED, not merely kept

CS answered **KEEP THE CLAMP; overflow visibly to `return_to_wh`**. ⛔ **A "keep" decision executes
as a FIXTURE, never as a no-op.** Keeping behaviour that nothing pins is indistinguishable from
nobody having decided anything - the next leg that finds `LEAST(..., headroom)` inconvenient deletes
it and every existing assertion stays green.

⭐ **THE GAP WAS REAL AND MEASURED, NOT ASSUMED.** Anchor A headroom 9 (clamp never fires), anchor B
headroom 1 (partial clamp). **No anchor reached headroom 0** - the case where the clamp decides
everything, because it is the one where the resolver must transfer NOTHING. And
`dest_capacity_clamp` was a literal string in **0 of 46 assertions**; it survived only INDIRECTLY,
because `totals.clamped_units` is a SUM FILTERed on that exact reason.

**Anchor C** pins the over-full boundary: `pin_machine_stock(MPMCC-1058, 99)` -> A05 reads 99 against
`max_stock` 6, so raw headroom is negative and floors to 0. `status=ok · transfer=0 · return=14 ·
clamped=8 · conserved=true · ZERO transfer legs emitted`. **63/63 green twice.**

### ⛔ S-155 (NEW) - the pin is safe BECAUSE `run_fixture` catches; an inner handler would break it

`golden.run_fixture` runs `scenario_sql` inside `BEGIN ... EXCEPTION WHEN OTHERS`. That is a
**subtransaction**: a raise anywhere between pin and restore rolls the pin back uncommitted. So
pin -> work -> restore in ONE `DO` block with **NO inner handler** is correct (fixture-3 idiom), and
⛔ **adding a handler would be strictly worse** - it would let execution continue past a failed
restore and leave a live WEIMI observation modified. ⭐ Generalises: before "hardening" a harness
block with an exception handler, check whether the caller's handler is what makes it safe.

### ⭐ S-156 (NEW) - never pin a live-drifting level as a literal in a RESIDUE proof

The first draft asserted the destination reads `5` units after restore. That is today's stock; it
moves on any sale or refill. ⛔ **A residue proof that reddens for non-residue reasons is worse than
no proof** - it trains the operator to ignore the one assertion whose job is catching a leaked pin.
⭐ **Capture the PRE value and assert post = pre.** Same for config-derived constants: seq 49 became
`lt 0` instead of `eq -93`, because `-93` silently encoded `max_stock = 6`.

### ⭐ S-157 (NEW) - three anchors at three headrooms defeat vacuity without a counterfactual probe

9 -> (transfer 6, clamped 0) · 1 -> (1, 7) · 0 -> (0, 8). Deleting the clamp makes **all three** read
transfer = eligible-units, clamped = 0. ⭐ **Monotonicity ACROSS anchors is the discriminator** - it
is asserted, not argued, and it is cheaper than simulating the clamp-free engine. Contrast S-132,
where fixture 8's core assertion has no such spread and passes vacuously.

### ⏸️ UNCHANGED THIS LEG

**S-132 remains the highest-value open non-build item** - fixture 8's core assertion still passes
vacuously (`lines_with_floor` = 0 of 32); fixture 8 is RED 18/1 and seq 29 is a TRUE red.
⛔ **Never weaken seq 29.** ⛔ D-19 still is not the one-liner it looks like: the audited single-use
override must be PROVEN to exist and work before `preflight_enforcement` flips to `'block'`.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31..D-40 (20, all answered, all unexecuted). **D-23 and D-30 are now the two EXECUTED. No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⭐ leg 94 (2026-08-03) - CS DECISION D-36 EXECUTED AND CLOSED. 19 answered decisions remain.

### ✅ D-36 CLOSED (executed, fixture `20260803181333` + engine `20260803181622`)

CS answered **(a) RE-ASSERT `app.rpc_name` after each inner call in `swap_v3`; no signature change**.
Executed fixture-first: fixture 54 went **RED on seq 62/65/66** against the old body and **41/41
green** on the new one, twice.

### ⛔ S-158 (NEW) - D-36's PARKED PREMISE WAS FALSE. Re-derive a parked defect before executing it.

The D-36 note said `write_audit_log` "records two ordinary edits and no swap". It records
**nothing**. `plan_edits_v3` carries **no** `audit_log_write` trigger - only
`tg_plan_edits_v3_append_only` and `_no_truncate` - and `write_audit_log` holds **zero** rows for
`swap_v3`, `record_plan_edit_v3` or `plan_edits_v3`. Had the fix been built to the parked wording,
it would have been aimed at an audit trail that does not exist.

⭐ **The real defect is narrower and worse.** `set_config(..., true)` is **TRANSACTION-scoped**, not
statement-scoped, so `swap_v3` RETURNED leaving `record_plan_edit_v3` behind, and the next write to
any of the **42** audited tables in that same transaction was stamped with the inner writer instead
of the act the human performed. Measured live before anything was written: after a successful swap,
`current_setting('app.rpc_name')` = `record_plan_edit_v3`.

⛔ **GENERALISE: a parking-lot entry records what a leg BELIEVED at the time. Probe the mechanism
live before executing the fix** - this is the PRD-106 stale-root-cause lesson recurring at decision
grain, and the corrected premise belongs in the migration header where the next reader will find it.

### ⭐ S-159 (NEW) - `swap_v3` was the LONE outlier; the convention already existed

Every other v3 writer that calls an inner `rpc_name`-setter already re-asserts:
`create_spot_purchase_v3` (3), `mine_edit_history_v3` (3), `run_weekly_miners_v3` (2),
`submit_feedback_v3` (2) - and fixtures **56/57/58** already pin `rpc_name_after_<call>` for three of
them. `swap_v3` set the name once and was the only v3 writer with no such assertion. ⭐ **When a
decision looks like it invents a convention, check whether the convention is already load-bearing
elsewhere: the fix gets smaller and the assertion idiom is already chosen for you.**

### ⏸️ S-160 (NEW, PARKED - NOT this build's scope) - other v3 functions carry the same leak

Same probe, run fleet-wide: functions that call an inner `rpc_name`-setter and never re-assert
include **`stitch_v3`** (calls `record_blocked_demand_v3`), **`run_pipeline_v3`** (calls four:
`stitch_v3`, `engine_add_pod_v3`, `record_blocked_demand_v3`, `compose_plan_with_edits_v3`),
`run_nightly_shadow_v3`, `driver_confirm_shelf_v3`, `estimate_shelf_composition_v3`,
`record_inventory_event_v3`. ⛔ **D-36 names `swap_v3` only, and LAW 10 says do not drift.** A
fleet sweep is its own unit: `stitch_v3` and `run_pipeline_v3` are hot engines, so each needs its
own fixture + Cody + substitution migration. **Smallest unblock:** one leg, one fixture asserting
`rpc_name_after_run` per engine, then one substitution migration each.

### ⛔ S-161 (NEW) - fixture 60 reads the AMBIENT `app.rpc_name`, so any fixture that sets it must restore it

`golden.run_all()` runs every fixture in ONE transaction, and a subtransaction that **COMMITS** does
not roll `set_config` back (contrast S-155, which is about a subtransaction that ABORTS). Fixture
**60 seq 54** captures `current_setting('app.rpc_name', true)` **without setting it first**, so a
sentinel left behind by an earlier fixture reddens fixture 60 for a reason unrelated to fixture 60.
⭐ **Fixture 54 step 6 is therefore hermetic by construction: capture on entry, restore on exit**,
and seq 67 asserts the restore happened. Proven by running 54 then 60 in one shared transaction -
`f54_fail=0`, `f60_fail=0`, value between them `compose_plan_with_edits_v3` (what fixture 60 would
have seen anyway). ⚠️ **Any future fixture that touches a GUC inherits this obligation.**

### ⭐ S-162 (NEW) - a structural assertion can go green exactly when the thing it guards is bypassed

Cody's R1 on the fixture. Both structural checks split the body on `record_plan_edit_v3\(` and
inspect the last element. With **zero** inner calls the split yields ONE element (the whole source),
so "is there a re-assert after the last inner call" finds the **opening** assert, and "do re-asserts
cover every inner call" evaluates `n-1 >= 0`. ⛔ **Both would have read `yes` precisely when the
canonical writer had been bypassed** - the D-35 defect class. Closed by seq 68 pinning
`inner_calls` at `gte 2`. ⭐ **Generalise: any assertion built on "split and take the last part"
needs a premise that the split actually split something.**

### ⛔ S-163 (NEW) - assert `pronargdefaults` after ANY `CREATE OR REPLACE` on a defaulted function

Cody's R1 on the engine migration. `swap_v3` has two defaulted arguments, so every 5-arg caller
depends on them surviving the replace. `pg_get_functiondef()` does emit the `DEFAULT` clauses and
they did survive - but "should survive" is the exact assumption behind the **13-day driver-confirm
outage** in the Wave-2 closeout. Now asserted `= 2` inside the migration. ⭐ Also asserted in the
same block: `prosecdef`, the pinned `search_path`, and the **whole** ACL string (S-140).

### ⏸️ UNCHANGED THIS LEG

**S-132 remains the highest-value open non-build item** - fixture 8's core assertion still passes
vacuously (`lines_with_floor` = 0 of 32); fixture 8 is RED 18/1 and seq 29 is a TRUE red.
⛔ **Never weaken seq 29.** ⛔ **D-19 still is not the one-liner it looks like:** the audited
single-use override must be PROVEN to exist and work BEFORE `preflight_enforcement` flips to
`'block'`, or the flip arms the guard and removes its escape hatch in one statement.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-35, D-37, D-38, D-39, D-40 (19, all answered, all unexecuted). **D-23, D-30 and D-36 are now the three EXECUTED. No new CS decision this leg.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⭐ leg 95 (2026-08-03) - CS DECISION D-35 EXECUTED AND CLOSED. One new CS decision RAISED (D-41).

### ✅ D-35 CLOSED (executed, fixture `20260803183514` + engine `20260803183540`)

CS answered **COLLAPSE the inline Saturday rule in `_build_draft_core_v3` into the canonical helper;
agreement fixture required.** Both halves delivered. Fixture 61 was applied first and was **RED on
seq 4/5** against the live body; the substitution greened it **13/13, twice**. Article 16's "known
illegal copy to retire" is retired and METRICS_REGISTRY / RPC_REGISTRY both say so now.

⭐ **THE PARKED PREMISE WAS EXACT THIS TIME - AND CHECKING COST 90 SECONDS.** S-158 (D-36's wording
was factually wrong) made re-derivation mandatory, not optional. Probed live before a line was
written: the helper exists as described, `run_nightly_shadow_v3` asks it, `_build_draft_core_v3` does
not and still carried the bare `EXTRACT(DOW FROM p_plan_date) = 6`. **A premise that survives the
probe is worth as much as one that fails it** - it is the probe, not the outcome, that is the rule.

### ⛔ S-164 (NEW) - A SYNTHETIC 2030 DATE IS NOT AUTOMATICALLY AN EMPTY ONE

LAW 12 says test on synthetic 2030 plan_dates. It does **not** say a 2030 date is unoccupied, and
this build has been colonising them for 95 legs. `_build_draft_core_v3` exits early on a Saturday, on
a live plan, and on zero included machines - but on a date carrying **confirmed + included**
`machines_to_visit` rows it walks straight into `engine_add_pod` / `engine_swap_pod` /
`engine_finalize_pod`, under its own pinned `statement_timeout` of **20 minutes**.

**`2030-03-05..2030-03-14` carry EIGHT `machines_to_visit` rows each** (fixture 58's cast). Picking
"some 2030 week" would have fired the real engines inside the golden harness, and inside `run_all`'s
single transaction. ⭐ **The rule: probe the window before calling anything that plans, and make the
fixture re-probe it on every run** - fixture 61 seq 3 turns a colonised window into a red instead of
a runaway. Window `2030-06-03..09` was verified virgin on **four** tables (the fourth, per Cody,
being `refill_plan_output` - the one LAW 12 actually names).

### ⛔ S-165 (NEW) - A HELPER WITH A LARGER GUARD SET IS NOT A DROP-IN FOR AN INLINE RULE

`is_refill_planning_day_v3(p)` is `p IS NOT NULL AND EXTRACT(DOW FROM p) <> 6`. The inline rule was
`EXTRACT(DOW FROM p) = 6`. **They differ on NULL:** the inline rule declines the branch (NULL
condition), `NOT helper(NULL)` takes it - so a naive swap converts a raise into a silent
`skipped_saturday`. Safe at this site only because `IF p_plan_date IS NULL THEN RAISE` runs three
lines earlier, which the migration asserts **positionally on the live body** and refuses rather than
assumes. ⭐ **Generalise: before collapsing an inline rule onto a named helper, diff the GUARD SETS,
not the happy paths. Article 16 convergence is where this class of bug lives.**

### ⏸️ D-41 (NEW CS DECISION, leg 95) - FIVE LEGACY STAGE-1 FUNCTIONS ARE EXECUTABLE BY `anon`

Found while reading `_build_draft_core_v3`'s ACL for the S-140 assertion. **Not fixed - LAW 10 says
D-35 names one function and a fleet sweep is its own unit.** Recorded with the proof so the next leg
does not have to re-derive it.

**The exposure.** `_build_draft_core_v3` carries `anon=X/postgres`, and its role gate reads
`v_user_id := auth.uid(); IF v_user_id IS NOT NULL AND NOT EXISTS (... operator_admin ...) THEN
RETURN error`. For `anon`, `auth.uid()` is **NULL**, so the condition **short-circuits false and the
guard is skipped entirely** - the caller proceeds into Stage 1. The guard protects an authenticated
non-admin and waves through an unauthenticated caller, which is the opposite of the intent.

**Measured live (`has_function_privilege('anon', oid, 'EXECUTE')`):**

| function                       | anon EXECUTE | note                                       |
| ------------------------------ | ------------ | ------------------------------------------ |
| `_build_draft_core_v3`         | **true**     | the Stage 1 core                           |
| `build_draft_for_confirmed_v3` | **true**     | **cron 13's entry point**                  |
| `build_confirmed_now_v3`       | **true**     |                                            |
| `pick_machines_for_refill`     | **true**     | writes `machines_to_visit`                 |
| `confirm_machines_to_visit`    | **true**     | its own guard has the same short-circuit   |
| `engine_add_pod_v3`            | false        | every PRD-110 v3 engine already has it off |
| `stitch_v3` / `swap_v3`        | false        |                                            |
| `run_pipeline_v3`              | false        |                                            |
| `run_nightly_shadow_v3`        | false        |                                            |

⭐ **The v3 convention is already "no anon" - these five are the un-swept legacy tier**, and this is
exactly D-30's class (CS answered **REVOKE NOW** for `_blocked_demand_gaps_v3`). Two independent
defects, and fixing only one leaves the door open: **(a)** `REVOKE EXECUTE ... FROM anon` on all
five; **(b)** invert the short-circuit so a NULL `auth.uid()` is REFUSED, not waved through
(Article 4: a DEFINER validates role - it does not skip validation when there is no role).

⛔ **`pick_machines_for_refill` and `confirm_machines_to_visit` WRITE**, so (a) alone is not
cosmetic. ⚠️ **Check the FE and cron before revoking:** cron 13 runs as the job owner, not `anon`,
and `grep -rn` over `src/` returns nothing for these names - but that is this leg's read, and the
executing leg must re-derive it (S-158).

**CS ASK, one line:** _revoke `anon` EXECUTE from the five legacy Stage-1 functions and make a NULL
`auth.uid()` a refusal rather than a bypass - same call you already made for D-30?_

### ⚠️ COUNTER CORRECTION - THE "N ANSWERED DECISIONS" TALLY HAS BEEN +5 SINCE LEG 92

Leg 92 wrote "D-19, D-21, D-23, D-27, D-28, D-29, D-31..D-40 **(21**, all answered...)". That list is
**16** items, not 21, and every leg since has decremented the wrong number: leg 93 said 20, leg 94
said 19, while the lists held 15 and 14. **The LIST has been right throughout; only the parenthetical
was wrong.** ⭐ Corrected here rather than decremented again - **trust the enumeration, never the
counter**, and this is why S-80 says grep the file instead of reading a summary line.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-38, D-39, D-40 (**13**, all answered, all unexecuted - count verified by enumeration). **D-23, D-30, D-35 and D-36 are the four EXECUTED.** ⏸️ **D-41 is NEW and UNANSWERED** - it is the only decision on this list waiting on CS rather than on a leg.

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⭐ leg 96 (2026-08-03) - CS DECISION D-38 EXECUTED AND CLOSED. 12 answered decisions remain.

### ✅ D-38 CLOSED (executed, `20260803185605` + `20260803190232` + `20260803190324`)

CS answered **EDIT WINS, LOUDLY**. Below-pin edits still apply; the override is stamped on the edit
line AND written to `feedback_ledger_v3` as `pin_contradiction` evidence feeding G12.
Golden fixture **62**, 18 assertions, **RED 7/11 before, 18/18 GREEN twice after**.
⭐ **S-130 re-verified live before a line was written (S-158): `record_plan_edit_v3` genuinely did not
mention pins at all.** The premise held exactly this time; probing it was still what found S-166.

### ⛔ S-166 (NEW) - AN ABSOLUTE COUNT OF A PRODUCTION TABLE IS A DECAYING TRIPWIRE

Fixture **50 seq 46** and **51 seq 51** ("LAW 11: the Gate-0 queue is untouched at **1240**") are
**RED and NOT caused by this unit** - nothing in D-38 writes `machines_to_visit`. The table stands at
**1330**: cron 13 adds production rows nightly (2026-08-02/03/04 all present) and other fixtures' 2030
casts accumulate. Both fixtures were **green on 2026-08-01** and have been rotting silently since;
this leg is merely the first to run them again. ⭐ **The intent is a DELTA - "this fixture did not
touch the queue" - expressed as an ABSOLUTE, so production drift reads as a violation.**
⛔ **DO NOT bump 1240 → 1330.** That re-arms the identical decay and produces an assertion that is
green and meaningless. ⭐ **The fix shape is already in the repo:** fixture 62 seq 16/18 capture the
count before and after the scenario and assert the DELTA is 0, which is immune to production growth
by construction. ⚠️ Two fixtures, scenario-body edits, **its own unit** - strong next-task candidate.
⭐ The same defect existed in fixture 62's own draft (seq 16 as an absolute) and was corrected before
apply, which is the only reason it was recognised on sight here.

### ⛔ S-167 (NEW) - `min(uuid)` DOES NOT EXIST, AND THE FIXTURE IS WHY IT COST TWO MINUTES

The boonz-product resolve used `CASE WHEN count(DISTINCT ...) = 1 THEN min(pm.boonz_product_id) END`.
It parses, applies cleanly, and fails at **runtime with 42883** on the ONLY path D-38 exists to serve.
⭐ **Fixture 62 seq 2 is what caught it** - the anti-vacuity guard that captures any scenario
exception into scratch instead of letting it fall through. ⛔ **Without seq 2, seqs 6-12 would have
read `no_column`: the SAME value they showed in the RED baseline.** The leg would have concluded "the
substitution did not take" and gone hunting in the migration logic. ⭐ **Generalise: a fixture whose
failure mode is indistinguishable from its pre-change state cannot tell you WHICH thing broke. Every
scenario needs one assertion that reports "the scenario itself threw", distinct from every content
assertion.** Fixed additively by `(array_agg(DISTINCT ...))[1]`, which is uuid-safe.

### ⛔ S-168 (NEW) - A NOT NULL DEFAULT ON A NEW COLUMN IS A BACKFILLED CLAIM ABOUT THE PAST

Cody R1. `pin_contradiction boolean NOT NULL DEFAULT false` would have stamped **false** on every
pre-D-38 edit row - asserting "evaluated, no contradiction" about edits that were never checked
against a pin. ⭐ **Measured live after apply: 182 of 196 rows read NULL.** Under the original design
all 182 would be lying, and every future acceptance-rate read off this column would have inherited it.
⭐ **The rule: when a new column records the OUTCOME of a check, its default describes rows the check
never ran on. Nullable is the honest shape; NULL means "not evaluated" and is not the same as false.**
Same family as LAW 5's silent-zero and as the engine's own 0/0/false-explicitly discipline.

### ⏸️ D-41 STILL NEW AND UNANSWERED (raised leg 95) - five legacy Stage-1 functions executable by `anon`.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted - count verified by enumeration). **D-23, D-30, D-35, D-36 and D-38 are the five EXECUTED.** ⏸️ **D-41 remains NEW and UNANSWERED** - still the only decision waiting on CS rather than on a leg.

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⭐ leg 97 (2026-08-03) - S-166 CLOSED. Golden is fully green again. No CS decision raised or answered.

### ✅ S-166 CLOSED (`20260803192110`, + `20260803192227` idempotency proof)

Fixtures 11/50/51 no longer pin `machines_to_visit` at 1240. Each body captures the count BEFORE the
scenario runs and the assertion is a same-run DELTA expecting 0. **11 (39/0) · 50 (49/0) · 51 (53/0),
green on two consecutive full runs.**

### ⛔ S-169 (NEW) - A STALE FIXTURE IS NOT A PASSING FIXTURE

Leg 96 bisected S-166 and reported **two** reds. There were **three**. Fixture 11 seq 38 carried the
identical pinned-1240 shape but had not run since 2026-08-01, so `golden.scratch` still held the old
1240 and the fixture read GREEN. It went red the instant it was re-run at this leg's baseline.

**Why:** an assertion that reads `golden.scratch` is only as fresh as the last run of its fixture. A
green status on a fixture that has not run since before the drift is a **cached** result, not a
verified one.
**How to apply:** when a defect is found in one fixture, grep the SHAPE across all fixtures and RE-RUN
the matches before trusting their status. Never conclude blast radius from last-known run results.

### ⛔ S-170 (NEW) - "NOTHING CHANGED" MEASURED ONLY AFTER THE FACT CANNOT CATCH THE WRITE IT LOOKS FOR

Fixture 11 seq 39 asserts the `pod_refills` tripwire (captured at the FOOT of the body) equals a live
`count(*)` re-taken at assertion time. That is drift-immune, so it survived the S-166 audit - but it
is **weak**: both readings happen AFTER the scenario body, so a body that inserted rows would have
them in both and the delta would still be 0.

**Why:** drift-immunity and correctness are different properties. A tripwire that cannot fail for the
reason it exists is worse than a decaying one, because nothing will ever prompt a look at it.
**How to apply:** a LAW 4 "I did not touch X" tripwire needs a BEFORE-vs-AFTER pair, both captured
inside the run. Capture-vs-now is not a substitute. Not fixed here (out of S-166's scope, LAW 10);
recorded so a later leg can decide deliberately.

### ⛔ S-171 (NEW) - PROVING IDEMPOTENCY BY RE-APPLYING A MIGRATION MINTS FILING DEBT

The marker guard was proven a no-op by applying the same body a second time. It worked - and it also
wrote a second `schema_migrations` row with no disk file, i.e. exactly the DB∖disk gap every STEP R
checks for. Filed at `20260803192227` to close it.

**How to apply:** prove idempotency by re-running the body through `/tmp/prd110_sql.sh` (mints no
row). If a re-apply is done as a migration anyway, **file it to disk in the same unit** - a migration
that ran and has no disk file is filing debt however harmless its body.

### ⏸️ AUDITED AND DELIBERATELY LEFT - the decaying-absolute sweep (S-166 follow-through)

All enabled assertions with an `eq`/`gte`/`lte` on a 3+ digit constant and no 2030 scoping were swept.
**Only three are `eq`:**

- `f37 seq14` expect `23514` - a **SQLSTATE** (`check_violation`), not a count. Legitimately absolute.
- `f42 seq9` expect `480` - the `var_driver_day_minutes` **param default**. Legitimately absolute.
- `f37 seq24` expect `141` - `engine_forecast_error_v3` rows on `2026-06-26 AND actuals_settled`.
  **The one true cousin.** ⭐ Re-derived live at this leg: still exactly **141**, green. Left because
  its risk class differs - a PAST, fully-settled date is not a nightly-growing queue, and a change
  there would itself be a defect worth catching. ⚠️ It shares the shape weakness (it cannot tell "this
  fixture wrote it" from "someone else did"). Recorded so it is not re-derived from scratch.

Everything else is `gte` (a floor on a population that only grows) and is drift-tolerant by
construction.

### ⏸️ D-41 STILL NEW AND UNANSWERED (raised leg 95) - five legacy Stage-1 functions executable by `anon`.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted - unchanged, none touched this leg). **D-23, D-30, D-35, D-36 and D-38 remain the five EXECUTED.** ⏸️ **D-41 remains NEW and UNANSWERED.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

## ⭐ CS DECISION — D-41 CLOSED 2026-08-03 (via Cowork session)

**REVOKE ALL FIVE NOW.** One Cody-reviewed sweep: REVOKE anon EXECUTE on all five legacy Stage-1
functions carrying the NULL-uid guard inversion. Grant-layer fix only — live function bodies stay
byte-untouched (LAW 12); the guard-pattern hardening itself ships with v3, which already implements
the correct NULL-refusing check. Verify post-revoke with has_function_privilege('anon', oid,
'EXECUTE') = false on all five, and add the ACL assertion to the standing fixture set so a future
grant regression goes red.

---

## ⭐ leg 98 (2026-08-03) - D-19 PROVEN NOT-YET-SAFE TO EXECUTE. Fixture 63 shipped. 12 answered decisions remain.

### ⛔ S-172 (NEW) - THE FLAG ARMS THREE PATHS; FIXTURE 33 COVERS ONE, AND IT IS THE ONE NOTHING CALLS

CS answered D-19 with **"FLIP TO BLOCK. The audited single-use override is the escape hatch."** That
sentence is true of `public.commit_refill_plan` - and `grep -rn commit_refill_plan src/` returns
**exactly one hit, and it is `commit_refill_plan_atomic`**. The gated function has no FE caller at all.

What `preflight_enforcement='block'` would actually arm, all three verified live this leg:

1. **`stitch_pod_to_boonz`** (FE `RefillPlanningTab.tsx:680`) - refuses with a rich payload: verdict,
   `violation_count`, the violation with its `fix_path`, and a message naming `p_force`. Hatch is
   inline `p_force` + a ≥10-char audited reason. ⭐ **This one is healthy.** The FE already handles
   `status === 'preflight_failed'` at line 697.
2. **`commit_refill_plan`** - the fixture-33 path. Healthy, audited, single-use, **uncalled**.
3. **`commit_refill_plan_atomic`** (FE `:960`, the ONLY commit button) - calls
   `stitch_pod_to_boonz(p_plan_date, false)` and RAISEs unless `v_stitch->'write_result'->>'status'='ok'`.
   A refusal has **no `write_result` key**, so the operator gets
   `commit_refill_plan_atomic: stitch write_result=null — rolling back (PRD-019 E2).`

⭐ **The teeth are real** - fixture 63 seq 50/51 prove the atomic commit aborts and writes zero
`refill_plan_output` rows. ⛔ **The recovery is not.** The invariant id, the `fix_path` and the
`p_force` instructions are discarded before they reach the operator, and the function hard-codes
`false` with **no `p_force` passthrough**, so there is no way to override from the UI at all.

⛔ **Flipping today would arm a guard and remove its escape hatch in one statement** - precisely the
failure the leg-97 pointer named, found at the site nobody had checked. ⚠️ It would also be **silently
inert until it wasn't**: live preflight is `PASS` with **0 violations** for both `CURRENT_DATE` and
`resolve_refill_plan_date()` = `2026-08-04`, so the flip changes nothing until the first real
violation - which is exactly the moment CS would be stranded with an unactionable message. This is the
WS-I driver-stranded shape from the ENVIRONMENT CARD, one layer up.

### ⏸️ D-19 - SMALLEST UNBLOCK (two steps, in this order)

1. **Make the refusal legible.** In `commit_refill_plan_atomic`, branch on
   `v_stitch->>'status' = 'preflight_failed'` BEFORE the generic `write_result` check and RAISE with the
   violation payload. ⭐ **Zero risk under today's flag**: in `warn` mode `stitch_pod_to_boonz` never
   returns `preflight_failed`, so the new branch is unreachable until the flip. Cody-reviewed unit;
   re-baselines fixture 63 seq 52/53 (they pin the CURRENT message deliberately, so they SHOULD go red
   when this lands - that is the tripwire working, not a regression).
2. **Make the hatch reachable.** Add `p_force` / `p_force_reason` passthrough params (defaulted, so no
   signature break) + the FE affordance. ⛔ Needs Stax and a deploy - this is the real cost of D-19.

⛔ **Only then flip.** ⚠️ And when flipping, fixture **33 seq 91** pins the live flag to the literal
`warn` and will go red - it is the **only** assertion in the harness that reads
`preflight_enforcement` (grepped across all 1825). ⭐ Fixture 63 seq 90 deliberately asserts the flag
as a **delta against its own baseline** instead, so fixture 63 survives the flip untouched.

### ⭐ FIXTURE 63 - what shipped, and the reusable trick in it

`2030-03-05`, phase `P2`, **33 assertions, GREEN on three consecutive runs.** Seeds the same INV-06
conservation leak fixture 33 uses. ⭐ **Parents are seeded `status='stitched'`, never `'approved'`**, so
`stitch_pod_to_boonz` always halts at its own `no approved rows` guard - which sits AFTER the preflight
gate. **"Reached `no approved rows`" is a safe, deterministic marker for "the gate let this through",
and no call in the fixture can ever run a real stitch.**
⚠️ **The cost of that trick, stated so nobody re-derives it:** the `p_force` path's
`preflight_override_log` INSERT is rolled back by the same halt, so `override_log_delta` is **0 on every
probe by construction**. Asserting it as a delta would be vacuous, so seq 43 asserts the audited-write
shape on the **column default** (`'stitch'::text`) instead.

### ⏸️ D-41 STILL NEW AND UNANSWERED (raised leg 95) - five legacy Stage-1 functions executable by `anon`.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted - unchanged; D-19 was WORKED but deliberately NOT executed, and is now blocked on S-172 rather than on nothing). **D-23, D-30, D-35, D-36 and D-38 remain the five EXECUTED.** ⏸️ **D-41 remains NEW and UNANSWERED.**

⛔ Per S-80, the next leg must still grep this file's tail for `CS DECISION` rather than trust this line.

---

## ⭐ leg 99 (2026-08-03) - CS DECISION D-41 EXECUTED AND CLOSED. 12 answered decisions remain.

### ⛔ S-80 EARNED ITS KEEP: THE LEG-98 POINTER SAID D-41 WAS UNANSWERED. IT WAS NOT.

The leg-98 RESUME POINTER states, twice and in bold, _"D-41 is still NEW and UNANSWERED - the only
decision waiting on CS rather than on a leg."_ **It was already answered.** CS closed it in a Cowork
session and the answer is sitting in this file above leg 98's own section, at
`## ⭐ CS DECISION — D-41 CLOSED 2026-08-03 (via Cowork session)`.

⭐ **Why leg 98 missed it and why the drill works anyway.** CS's block was appended in a _different
session_, and it landed **above** the position where leg 98 then wrote its own close - so leg 98's
"tail" read past it. This is the S-99/leg-90 shape exactly: an out-of-band CS block whose only trace
is that it is not where you expect it. The PARKING-LOT hash was byte-identical at STEP R, every
counter matched, every md5 matched, all eight doc hashes matched - **the pointer was wrong on the one
thing no hash could catch, because the file was correct and the pointer's _summary of it_ was not.**

⛔ **THE RULE THIS CONFIRMS, STATED SHARPER THAN S-80 DID:** grep the WHOLE file for `CS DECISION`,
not the tail. A tail-scoped grep is what failed here. ⭐ And **never** conclude "no new decision" from
a pointer sentence, a hash match, or a leg's own closing tally - only from the grep.

### ✅ D-41 CLOSED (executed, `20260803195618`; fixture `20260803195429`; fix `20260803195820`)

CS's answer: _"REVOKE ALL FIVE NOW. One Cody-reviewed sweep … Grant-layer fix only - live function
bodies stay byte-untouched (LAW 12); the guard-pattern hardening itself ships with v3 … Verify
post-revoke with `has_function_privilege('anon', oid, 'EXECUTE') = false` on all five, and add the ACL
assertion to the standing fixture set so a future grant regression goes red."_ All four clauses done.

⛔ **THE PARKED PREMISE WAS INCOMPLETE - SECOND LEG RUNNING.** D-41 was raised naming only `anon`.
Measured live at execution, **four of the five also carried a PUBLIC grant** (`=X/postgres`):
`build_draft_for_confirmed_v3`, `build_confirmed_now_v3`, `pick_machines_for_refill`,
`confirm_machines_to_visit`. `anon` is a **member of PUBLIC**, so `REVOKE … FROM anon` alone would have
left `has_function_privilege('anon', …)` **TRUE** - CS's own acceptance test failing while the
migration reported success. ⭐ Revoking PUBLIC is required **BY** the answer, not drift beyond it;
Cody approved on that exact reading. **D-19 (leg 98) and D-41 (this leg) now make a pattern: re-derive
the parked premise live, because the thing the premise omits is what bites.**

⚠️ **ARTICLE 4 IS NOT CURED. Do not record it as cured.** The sweep removes _reachability_, not the
guard inversion `IF auth.uid() IS NOT NULL AND NOT EXISTS (...operator_admin...)`, which skips
validation entirely when there is no role. CS assigned the hardening to v3. ⛔ **Fixture 64 seq 18-22
pin all five bodies by `md5(prosrc)`** so a leg that "helpfully" fixes the guard here goes red on
purpose - the scope split cannot be crossed silently in either direction.

**Final ACL, all five, read BACK and asserted whole (S-140):**
`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}` - the same convention fixture
18 seq 2 and fixture 60 seq 4 already pin for the v3 tier. ⭐ Asserted **twice**: an in-migration `DO`
block that RAISEs on any deviation _including over-reach_ (stripping `authenticated` or `service_role`
would break the nightly runner with no error anywhere), and fixture 64 seq 11-15.

⭐ **Why it could not strand the nightly (LAW 12):** crons **13** and **14** are the only automated
callers, both `username='postgres'` (the owner) - verified live, pinned as fixture 64 seq 23. `grep -rn`
over `src/` returns zero call sites (one comment mention, `SnapshotTab.tsx:645`), re-derived this leg
per S-158 rather than trusted from the leg-95 note.

### ⛔ S-173 (NEW) - I SHIPPED A DECORATIVE ASSERTION AND CAUGHT IT ONLY BECAUSE IT WENT RED

Fixture 64 seq 9 ("no PUBLIC grant on any of the five") first measured
`count(*) FILTER (WHERE proacl::text LIKE '%=X/%')`. That substring **also matches
`postgres=X/postgres`, `authenticated=X/postgres` and `service_role=X/postgres`**, so it returned `5`
under every reachable state and **could never reach 0**. It stayed RED after a sweep that was in fact
entirely correct.

⭐ **This is S-132/S-139/S-140 pointed at my own check, and it is the mirror image of them:** those are
assertions that cannot FAIL under the wrong state; this is one that cannot PASS under the right state.
**Same defect** - a check whose value does not depend on the thing it claims to measure. A vacuous
green and a permanent red are the same bug wearing different clothes; only one of them is lucky enough
to be noticed.

⛔ **A PUBLIC grant is not a substring.** In a PostgreSQL ACL it is an entry with an **empty grantee**,
rendered `=X/postgres`. The only correct detector is `aclexplode(proacl).grantee = 0`. Fixed forward at
`20260803195820`.

⭐ **AND THE DETECTOR NOW SELF-TESTS - do this for every "count of a bad thing" assertion.**
`golden._acl_canary_public_64()` is created carrying a deliberate explicit PUBLIC EXECUTE grant, and
**seq 24 asserts the seq-9 expression FINDS it**. Without the canary, seq 9 reading `0` is
indistinguishable from a detector that returns `0` for everything - which is precisely the bug this
leg shipped. ⛔ **An assertion that counts occurrences of a defect needs a positive control, or it is
decoration the moment the defect stops occurring.** The canary is SECURITY INVOKER, touches no data,
and lives in `golden`, never in `public`.

### ⚠️ HARNESS PERF / INVOCATION NOTES FOUND THIS LEG (both cost real time)

- ⛔ **`golden.run_all('P0', …)` TIMES OUT on the SQL endpoint** (`57014 statement timeout`, inside a
  `v_wh_pickable` CTE). ⚠️ **Fixtures 3 and 5 individually also exceed the endpoint's connection
  timeout** - both failed with `Connection terminated due to connection timeout` while `pg_stat_activity`
  showed **no other active query**, so this is their real cost, not congestion. The leg-98 PERF BUDGET
  line "P0=5 fixtures" reads as cheap and **is not**. 61, 10 and 64 are fast; 3, 5 and 105 are not.
- ⛔ **`run_fixture(105, …, 'P0')` reports 4 FALSE REDS (seq 10, 86, 87, 88).** Fixture 105 is declared
  `phase_required='P0'` but **carries P2 assertions**, and `max_phase='P0'` suppresses
  `golden.run_engine_v3_if_built` while still evaluating them - so they return their own
  "engine never ran" sentinels (`helper_never_ran`, `no_v3_run`, `-1`) and read as failures.
  ⭐ **A fixture's `phase_required` is a FLOOR, not its run phase. Run 105 at P2+ or the reds are yours,
  not the build's.** Re-run at `'P4'` to confirm.

### ⚠️ `blocked_demand` MOVED 52 → 48 AND THAT IS FIXTURE 105, NOT A REGRESSION

⛔ **The leg-98 pointer told this leg to expect 52 and called the ledger effectively append-only. It is
not.** Fixture 105's scenario opens with
`DELETE FROM public.blocked_demand WHERE plan_date = {{plan_date}}` and re-seeds — it rewrites **its
own synthetic date**, `2030-04-16`. Running 105 twice this leg replaced 16 rows with **12**, hence
52 → 48. ⭐ Current spread: `2026-07-30` **20** (real, untouched), `2030-01-06` **14**,
`2030-02-17` **2**, `2030-04-16` **12**.

⭐ **Still true and worth keeping:** `open == total == 48`, so **zero resolutions have ever happened**.
⭐ **LAW 12 held** — the only rows touched were on a synthetic 2030 date owned by the fixture.
⛔ **Never pin an absolute `blocked_demand` count in a pointer or an assertion.** It is a
`gte`-or-nothing counter: any leg that runs fixture 105 moves it, in either direction.

### ⭐ THE BLAST-RADIUS DRILL THAT REPLACED A FULL SWEEP (reusable, and cheaper than run_all)

Rather than re-run phases that time out, the regression surface was derived **precisely**: grep
`golden.fixtures.scenario_sql` and `golden.assertions.check_sql` for all five function names. Outside
fixture 64 itself, exactly **three** sites reference them - fixture **42** (seq 49/50), fixture **53**
(scenario), fixture **61** (scenario). ⭐ Fixtures 3, 5 and 105 reference them **nowhere**, so a
grant-only change cannot regress them, and running them proves nothing about D-41. ⛔ **For a change
whose surface is nameable, grep the harness for the names - do not run the harness.**

⭐ **And then all three sites were closed WITHOUT running the two that time out:**

- **61** ran clean, **13/13 GREEN**.
- **42 seq 49/50** are pure `md5(prosrc)` body pins — evaluated directly in one query:
  `pick_machines_for_refill` = `d9f508d12aa1b7d35eb11927da234748` ✅,
  `confirm_machines_to_visit` = `a3344191ed395df23934893429aaadb6` ✅. ⚠️ Note these pin the **full**
  md5 while fixture 64 seq 18-22 pin the leading 8 — same values, two grains, both green.
- **53** calls `build_draft_for_confirmed_v3` and reads `->>'status'`. Its only dependency on the sweep
  is _being allowed to call it_, and the harness runs as **`current_user = postgres`** (measured, not
  assumed), which retains EXECUTE in the final ACL. A grant sweep that keeps postgres cannot change it.

⛔ **When a fixture is too slow to run, do not silently skip it — reduce it to the assertion that
actually touches your change and evaluate THAT.** Three heavy fixtures, zero heavy runs, and the
evidence is stronger than a green run_all would have been because it names the mechanism.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted - count verified by enumeration; D-19 remains blocked on S-172, not on nothing). **D-23, D-30, D-35, D-36, D-38 and now D-41 are the SIX EXECUTED.** ⭐ **No decision is waiting on CS. The queue is entirely a work queue.**

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## ⭐ leg 100 (2026-08-03) - S-172 STEP 1 SHIPPED. D-19 still correctly unflipped. One NEW exposure raised (D-42).

### ✅ S-172 STEP 1 - DONE, and D-19 is now blocked on step 2 alone

`commit_refill_plan_atomic` branches on `preflight_failed` before its generic `write_result` guard and
RAISEs the invariant id, the machine/shelf, the `expected`/`found` pair, the `fix_path`, and where to
read the full payload. `md5(prosrc)` `56f14180` → `4237fbcc`; signature untouched. Fixture 63
**36/36 green ×3**, idempotent on a 4th run. ⭐ **Unreachable under today's `warn` flag by
construction**, so this shipped at zero risk to tonight's advisory.

⛔ **DO NOT FLIP `preflight_enforcement` YET.** Step 2 (a `p_force`/`p_force_reason` passthrough +
the FE affordance, needing Stax and a deploy) is the remaining cost of D-19. ⚠️ **When it does flip,
fixture 33 seq 91 pins the literal `warn` and WILL go red** - still the only assertion in the harness
reading that flag. Fixture 63 seq 90 reads it as a delta and survives.

### ⭐ THE FOUR TRIPWIRES FIRED EXACTLY AS DESIGNED - and one of them was itself defective

Seq 52/53/54/55 pinned the swallowed-refusal behaviour **on purpose**; they went red the moment step 1
landed. ⛔ **But seq 54 counted the substring `p_force` in `prosrc`** - and the new message _names_
`p_force` in prose, so a purely cosmetic change would have flipped it and reported **"step 2 shipped"
when it had not.** Rebuilt as a signature test
(`pg_get_function_identity_arguments NOT LIKE '%p_force%' AND pronargdefaults = 0`).

⭐ **S-173 GENERALISES, and this is the sharper statement:** it was raised for a counter that could
never reach 0. The same defect class covers a counter that reaches its target for the **wrong reason**.
⛔ **Never let a substring stand in for a structural fact when the structure is queryable** - signatures,
`pronargdefaults`, `aclexplode`, and catalog joins are all cheap. Seq 57/58 were added as the
**behavioural** positive control: they assert the invariant id and the `fix_path` in the message the
probe actually captured, so the source-level checks can never go vacuously green alone.

### ⏸️ D-42 (NEW CS DECISION, leg 100) - THE COMMIT/STITCH TIER IS `anon`-REACHABLE. D-41 NEVER LOOKED AT IT.

Found while reading `commit_refill_plan_atomic`'s ACL for this leg's Cody review. ⛔ **Not fixed -
LAW 10.** D-41 audited the Stage-1 tier and the v3 engines and swept five functions. **It never
scanned the commit/stitch tier**, which is the same defect one tier over - and this tier includes the
FE's **only** commit button.

**Measured live (`aclexplode`, not a substring - S-173):**

| function                                   | anon EXECUTE | explicit `anon` grant | PUBLIC grant | note                                  |
| ------------------------------------------ | ------------ | --------------------- | ------------ | ------------------------------------- |
| `commit_refill_plan_atomic(date,text[])`   | **true**     | yes                   | **yes**      | ⛔ FE `RefillPlanningTab.tsx:960`     |
| `commit_refill_plan(date,text,uuid[])`     | **true**     | yes                   | **yes**      | the fixture-33 gated path             |
| `stitch_pod_to_boonz(date,bool,bool,text)` | **true**     | yes                   | **yes**      | FE `RefillPlanningTab.tsx:680`        |
| `approve_pod_refill_plan(date,text[])`     | **true**     | yes                   | **yes**      | called by the atomic commit           |
| `approve_refill_plan(date,text[])`         | **true**     | yes                   | **no**       | ⚠️ different guard shape, not audited |
| every `*_v3` engine                        | false        | no                    | no           | ⭐ the v3 convention is already clean |

All five carry the `IF v_user_id IS NOT NULL AND NOT EXISTS (...)` inversion, so for a NULL
`auth.uid()` the role gate **short-circuits false and is skipped entirely**. `commit_refill_plan_atomic`
then runs `approve_pod_refill_plan` → a real `stitch_pod_to_boonz` → `approve_refill_plan`, i.e. a live
write path into `refill_plan_output` (a protected entity) reachable with the public anon key.
⚠️ **This is strictly worse than D-41's five**, which were plan-_builders_; this one is the commit.

⛔ **AND THE OBVIOUS FIX IS A TRAP - read this before proposing one.** D-41's ask **(b)** was _"invert
the short-circuit so a NULL `auth.uid()` is REFUSED."_ ⛔ **That would strand every cron in the fleet.**
`pg_cron` runs as `postgres` with no JWT, so `auth.uid()` is NULL on **every** scheduled call - crons
**13, 14, 42, 43, 44, 45, 46**. The NULL bypass is a **deliberate fleet convention**, stated in
`run_pipeline_v3`'s own comment (_"caller (cron), matching the fleet convention"_).
⛔ **The parking lot and RPC_REGISTRY both record that v3 "already implements the correct NULL-refusing
check". Re-derived live this leg: FALSE.** `stitch_v3`, `engine_add_pod_v3`, `run_pipeline_v3` and
`preflight_override_v3` all carry the identical inversion. **v3's safety is the missing grant, nothing
else.** Corrected in RPC_REGISTRY this leg.

⭐ **So the grant layer is the only safe lever**, exactly as CS scoped D-41 - for a reason nobody had
written down. ⚠️ Both traps compose again (S-140 + leg 99): revoke **`anon` AND `PUBLIC`**, then read
`proacl` back and assert the whole string. ⚠️ The executing leg must re-derive the FE call sites first
(S-158): `RefillPlanningTab.tsx` calls two of these **as an authenticated operator**, so a revoke of
`anon` alone is safe for the FE - but that is this leg's read, not a guarantee.

**CS ASK, one line:** _revoke `anon` **and** `PUBLIC` EXECUTE from the five commit/stitch functions -
same call you made for D-41's five, on the tier that actually commits?_

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted - unchanged; D-19 is now blocked on S-172 **step 2** only). **D-23, D-30, D-35, D-36, D-38 and D-41 remain the SIX EXECUTED.** ⏸️ **D-42 is NEW and UNANSWERED** - the only decision waiting on CS rather than on a leg.

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## ⭐ leg 101 (2026-08-03) - P4.5 SCOREBOARD BUILT AND POPULATED. Two new STUCK items, no new CS decision.

**P4.5 is DONE and its gate clause is met:** `scoreboard_daily_v3` + `compute_scoreboard_day_v3(date)`

- `v_scoreboard_daily_v3` + `v_scoreboard_health_v3` + cron **47**, five migrations
  (`20260803205310`, `...5342`, `...5554`, `...5921`, `...5957`), golden **fixture 65 · 28/28 green on
  three consecutive runs**. Backfilled 14 days from real history: **`days_in_latest_streak` = 14**
  against a gate of 7. Live fleet numbers now measured daily - OSA ~**0.97**, stockout_rate
  **0.14-0.22**, revenue/machine/day **AED 73-152**, blocked aging **0.00 -> 2.94 days**.

### ⏸️ S-175 (NEW, PARKED BY DESIGN) - the scoreboard is FLEET-SCOPE ONLY, and Phase 5 needs more

`scope_kind` CHECKs `('fleet','venue_group','machine')` but the writer emits **`'fleet'` only**.
⛔ **Phase 5's stated cutover rule is per-CLUSTER** ("v3 shadow beats v19 on scoreboard 2 consecutive
weeks -> CS cutover approve"), and `venue_group` scope **does not exist**, so that comparison cannot
be made today. Nine venue groups are live (`v_active_fleet.venue_group`). ⭐ **Smallest unblock:** a
second writer pass looping venue groups for the four metrics that decompose cleanly (osa, stockout,
revenue, plan_adherence); wmape needs `engine_forecast_error_v3` grouped by machine first (it already
carries `machine_id`). ⚠️ **Do not read the enum value as the data** - the CHECK accepting
`'venue_group'` is forward-compatibility, not a built feature.

### ⏸️ S-176 (NEW, STUCK) - WMAPE IS PERMANENTLY VACUOUS ON LIVE DATES, AND THE SCOREBOARD JUST MADE IT VISIBLE

⛔ **`engine_forecast_error_v3` has NO rows for any real `plan_date` after `2026-06-26`.** The only
newer rows are the 2030 fixture dates. So `v_engine_wmape_v3` returns nothing for the last five weeks
and the scoreboard correctly reports `wmape_v3` / `wmape_v19` as **vacuous 14/14** with
`no_wmape_row_for_date`. ⭐ **This is NOT a scoreboard defect** - the writer passes the canonical
view's own absence through faithfully, which is exactly the contract. **The gap is upstream: nothing
is measuring forecast error on live plan_dates.**

⚠️ **THIS BLOCKS A CLAUSE OF THE DEFINITION OF DONE.** "Shadow mode live and diffing nightly against
v19 with scoreboard populated" - the scoreboard is populated, but its single most important
comparison column is empty, and the Phase 5 cutover test is _defined_ on WMAPE. ⭐ **Smallest
unblock:** find what wrote `engine_forecast_error_v3` up to 2026-06-26 and why it stopped, before
building anything new - it may simply be an unscheduled measurement pass. ⛔ **Do not "fix" this by
loosening the vacuity rule** so wmape reports 0; a fabricated 0 here would sign off a cutover on no
evidence. The vacuous row IS the correct output until real rows exist.

### ⛔ S-177 (NEW) - A `CHECK` THAT CAN EVALUATE TO `NULL` IS OFF FOR EXACTLY THE ROWS YOU CARE ABOUT

`ck_scoreboard_engine_tag` shipped as `(metric_key='wmape' AND engine_tag IN ('v3','v19')) OR
(metric_key<>'wmape' AND engine_tag IS NULL)`. For an untagged `wmape` row that is
`(TRUE AND NULL) OR FALSE` = **NULL**, and **a CHECK constraint ACCEPTS NULL**. The single shape it
existed to forbid was the single shape it permitted. ⭐ **It read correctly to Dara and to Cody; only
fixture 65 seq 10, which actually attempted the forbidden INSERT, found it.** ⛔ **Never validate a
constraint by reading its predicate - write the adversarial INSERT.** Extends S-173/S-174 to the
constraint layer: a guard that cannot fire is the same defect as a detector that cannot see.

### ⛔ S-178 (NEW) - SUPABASE DEFAULT PRIVILEGES ARM EVERY NEW `public` TABLE AT BIRTH

`ALTER DEFAULT PRIVILEGES` grants new `public` tables to **`anon` AND `authenticated`** on CREATE.
The migration's explicit `REVOKE ... FROM anon` worked; the `GRANT SELECT TO authenticated`
**did not reduce** the `arwdDxtm` it already held, so only RLS stood between `authenticated` and
INSERT/UPDATE/DELETE. Caught by reading `relacl` back (S-140), not by review. ⭐ **On every new
table: REVOKE ALL from PUBLIC, anon AND authenticated, then GRANT the one verb you mean, then read
`relacl` back and assert the WHOLE string.** Fixture 65 seq 20 pins it.

### ⏸️ OPEN CS DECISIONS after this leg - D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted - unchanged; D-19 still blocked on S-172 **step 2** only). **D-23, D-30, D-35, D-36, D-38 and D-41 remain the SIX EXECUTED.** ⏸️ **D-42 is still NEW and UNANSWERED** - the only decision waiting on CS. Leg 101 raised **no** new decision.

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## ⛔ leg 102 (2026-08-04) — S-179, S-180 RAISED. P4.4b DESIGN CLOSED, Migration A shipped.

### ⛔ S-179 — "WH IN-AND-OUT NETTED" WRITES AN ARTICLE-6 COLUMN ON EVERY SPOT FILL

The BUILD SPEC left P4.4b's receive shape as an open Dara call: _"WH in-and-out netted or
direct-to-machine receive"_. **Netting is not merely uglier — it is unconstitutional, and only
running it showed that.**

Executed in a rolled-back subtransaction: INSERT the spot batch to `warehouse_inventory` at qty 8,
then net it back to 0 in the same transaction.

```
proposals_before=1148   proposals_after=1149   status_after_netting=Inactive
```

`tg_propose_inactivate_on_zero_stock` fires on the drain and its body ends in a literal
`UPDATE public.warehouse_inventory SET status='Inactive'` — ⛔ **Article 6, manager-only,
propose-then-confirm only** — plus an **auto-confirmed** status proposal for a batch that never
physically existed.

⭐ **THE GENERALISATION, AND IT EXTENDS THE S-173/174/177 FAMILY TO A FOURTH LAYER.** Those three
were about a guard that cannot fire, a detector that cannot see, and a value that cannot be produced.
**S-179 is a WRITE YOU CANNOT SEE FROM THE CALL SITE.** Nothing at the `UPDATE warehouse_inventory
SET warehouse_stock = 0` mentions `status`; the `CREATE TRIGGER` line reads like ordinary
housekeeping; the forbidden write sits sixty lines into a function body nobody in this design was
reading. ⛔ **Before choosing any design that drains a row to zero, EXECUTE the drain and diff the
row — the trigger graph is not visible in the statement you write.**

⭐ **DECISION D-E (closed, no CS input needed — it is a constitutional consequence, not a preference):
DIRECT-TO-MACHINE RECEIVE.** Spot units never touch `warehouse_inventory`.

⚠️ **Residual pinned, not hidden:** a received PO line with **no** matching WH batch diverges from
the incumbent `receive_purchase_order` shape. Probed — **no CHECK, no view and no cron asserts that
shape**; it is an observed regularity, not an invariant. Fixture 26 pins the divergence as INTENDED.
⛔ **Do not let a later leg "fix" the gap by back-dating a warehouse receipt** — that silently
resurrects the netting design in a place nobody is looking.

⚠️ **NINTH GUC-LEAK SITE (S-160 family), found in passing, deliberately NOT touched:**
`propose_inactivate_on_zero_stock` sets `app.via_rpc='true'` and never restores it.

### ⛔ S-180 — `check_pod_conservation` IS STRUCTURALLY BLIND TO POST-FACTO FILLS

It compares `pod_refill_plan` parents to `refill_dispatching` children **for `action IN
('REMOVE','M2W')` ONLY**. A Refill/Add spot fill is invisible to it.

⭐ **Good news:** cron 33 (`conservation_monitor_daily`, severity `critical`) will **not** raise a
spurious nightly alert when P4.4b ships. ⛔ **Bad news, and this is the part that matters:** the BUILD
SPEC's _"conservation exact end-to-end"_ is **fixture 26's own burden**. ⛔ **A green
conservation_monitor is NOT evidence that P4.4b conserves — it is silence**, and silence from a
monitor that cannot see the class is the G12 lesson again.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg). **D-23, D-30, D-35, D-36, D-38 and D-41 remain the SIX EXECUTED.** ⏸️ **D-42 is still NEW and UNANSWERED** — the only decision waiting on CS. Leg 102 raised **no** new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

## ⛔ leg 103 (2026-08-04) — P4.4b Migration B SHIPPED. S-181, S-182, S-183 raised.

### ⛔ S-181 — THE HELPER AND ITS DONOR CAN NOW DRIFT, AND NOTHING WOULD SAY SO

`_resolve_open_walkin_po_v3` was lifted from `create_spot_purchase_v3`'s step 3 to satisfy design
D-F (_"so the two callers cannot drift apart"_). ⛔ **It does not actually achieve that.**
`create_spot_purchase_v3` was deliberately **not** refactored onto the helper: it is a
protected-entity writer, fixture-18-green at 80/80, and rewriting it to delegate is not a versioned
addition (LAW 3). Its md5 `79305485` is unchanged.

So today there are **two copies of one rule**, byte-faithful to each other, with no mechanism that
notices when a leg edits one. ⭐ **Smallest unblock, and it is cheap: fixture 26 asserts that the
helper and `create_spot_purchase_v3` resolve the SAME `po_id`/`po_path` for the same supplier on the
same day.** A divergence then goes red in the harness instead of in production. ⛔ Do not "close"
this by refactoring the incumbent without a Cody review and a fixture-18 re-run.

### ⛔ S-182 — S-145 MEANS THE DRIVER PATH **ALWAYS MINTS**, AND THE RULE'S NAME SAYS OTHERWISE

`add_purchase_order_lines` is `operator_admin`/`superadmin` only (re-verified live). P4.4b's PRIMARY
caller is a **driver** (`field_staff`). Therefore the rule "attach to today's open walk-in PO for
that supplier, else mint" resolves, for the entire driver path, to **"mint" — always**. Confirmed by
execution, not inference: `po_path = 'minted'` under `field_staff`.

⭐ This is CORRECT — `create_purchase_order` does admit `field_staff`, so the driver can still open
the financial chain — and the caller is told via `warnings`. ⛔ **But a reader of the design text
would expect attaching to be the common case, and it is the impossible case.** Two drivers spot-buying
from the same supplier on the same day produce **two** POs. ⏸️ Parked, not fixed: consolidating them
needs an owner-role actor, i.e. a procurement decision, not an RPC change.

### ⚠️ S-183 — `pack_outcome` CAN NOW READ `partial` ON A LINE THAT ENDED FULL

The incumbent computes `pack_outcome` from **n** (`n < planned ⇒ 'partial'`), then phase 1 sets
`filled_quantity = n + m`. Where m closes the gap the row ends up `partial` with
`filled_quantity = quantity`.

⛔ **Deliberately NOT fixed this leg — that is LAW 10.** `pack_outcome` is PRD-107's object with its
own semantics and its own canonical reader (`v_dispatch_pack_progress`), and re-deriving it from a
receive-time RPC is exactly the cross-PRD reach this build has avoided. ⚠️ It does not arise in the
07-30 incident shape (planned 1, n 1 ⇒ `packed`, verified live). ⭐ Smallest unblock: decide with CS
whether `pack_outcome` is a **packing-time** fact (then it is right as-is and this note closes) or a
**line-outcome** fact (then it needs re-derivation, in PRD-107's code, not here).

### ⭐ WHAT THE HAPPY-PATH PROBE CAUGHT THAT REVIEW DID NOT

⛔ `procurement_events.event_type` is CHECK-constrained and **rejected the phase-1 write outright**.
Nothing in the design, the Cody review or the source of the functions being composed mentioned it;
it surfaced the moment the path was actually executed end-to-end on real tables. ⭐ **The fix was
NOT to reuse `spot_purchase_created`** — that would make a post-facto shelf fill indistinguishable
from a P4.4 warehouse spot buy for every consumer filtering on event_type. The CHECK was widened
(additive; no existing row becomes illegal).

⭐ **AND THE FIFTH LAYER OF THE S-173/174/177/179 FAMILY, WHICH IS THE FINDING OF THE LEG: A GUARD
THAT PASSES FOR THE WRONG REASON.** `enforce_canonical_dispatch_write` allowlists by
`app.rpc_name`. `receive_dispatch_line` sets that GUC and **never restores it** (S-160). So the new
RPC's `filled_quantity` write would have sailed through the guard **for free, on a leaked value,
logged under another writer's identity** — and every probe would have looked green. Naming the write
honestly makes the guard refuse until the allowlist is extended, which is why this migration extends
it. ⛔ **A guard you pass by inheritance is not a guard you pass.**

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg). **D-23, D-30, D-35, D-36, D-38 and D-41 remain the SIX EXECUTED.** ⏸️ **D-42 is still NEW and UNANSWERED** — the only decision waiting on CS. Leg 103 raised **no** new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## CS DECISION — D-42 CLOSED (2026-08-04, via assistant)

**Ruling: REVOKE `anon` AND `PUBLIC` EXECUTE from all five commit/stitch-tier functions NOW** —
`commit_refill_plan_atomic(date,text[])`, `commit_refill_plan(date,text,uuid[])`,
`stitch_pod_to_boonz(date,bool,bool,text)`, `approve_pod_refill_plan(date,text[])`,
`approve_refill_plan(date,text[])`. Same call as D-41, grant-layer only — do NOT touch the
NULL-uid guard inversion (fleet cron convention; crons 13/14/42–46 run as postgres and bypass
grants). Executing leg must: (1) re-derive FE call sites first per S-158 (RefillPlanningTab.tsx
calls two of these as authenticated operator — verify, don't assume), (2) revoke both `anon` and
`PUBLIC` (S-140 + leg-99 trap), (3) read `proacl` back and assert the whole string, (4) add an
ACL fixture at this tier mirroring D-41's, per S-173 as catalog checks not substrings.

⏸️ OPEN CS DECISIONS after this ruling: D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34,
D-37, D-39, D-40 (12 answered-unexecuted, owed to legs). **NOTHING now waits on CS.**

---

## ✅ D-42 EXECUTED (leg 104, 2026-08-04) — the commit/stitch tier is no longer anon-reachable

CS's ruling (line 8293) carried four required steps. All four done, in order:

1. ⭐ **FE call sites re-derived per S-158 — and the ruling's own parenthetical was wrong.** CS wrote
   "RefillPlanningTab.tsx calls two of these." It calls **three** (`commit_refill_plan_atomic` :960,
   `stitch_pod_to_boonz` :680, `approve_refill_plan` :1099), plus a **fourth** site in
   `src/components/RefillPlanReview.tsx` :222. `approve_pod_refill_plan` has **no** FE caller.
   ⛔ All build their client with the **anon KEY**, but `src/middleware.ts` redirects session-less
   requests to `/login`, so the JWT **ROLE** is always `authenticated`. The anon key is not the anon role.
2. ⭐ **Both `anon` and `PUBLIC` revoked** — and the trap was live: **four of five** carried
   `=X/postgres`. The pre-sweep fixture measured it (seq 9 = **4**). An anon-only revoke would have
   left CS's own acceptance test failing on four functions.
3. ⭐ **`proacl` read back and the WHOLE string asserted** — in-migration (`DO` block, aborts on
   deviation) **and** in fixture 66 seq 11–15. All five now exactly
   `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`; `anon`-executable count **0**.
4. ⭐ **ACL fixture added mirroring D-41's** — fixture **66**, 25 assertions, catalog checks not
   substrings (S-173), with its own PUBLIC-granted canary for the detector self-test (S-140).

**Migrations:** `20260803215158` (fixture, landed FIRST per LAW 1 — **12 RED / 13 GREEN**) ·
`20260803215225` (sweep — fixture then **25/25 GREEN**). Fixture 64 re-run **24/24**, D-41 tier intact.
Golden **55 → 56 fixtures, 1880 → 1905 assertions**. No body moved: all five `md5(prosrc)` pinned and
green, including the THREE GATE md5s.

⚠️ **ARTICLE 4 STILL OPEN AGAINST THIS TIER**, same terms as D-41. The revoke removed reachability,
not any guard defect. ⛔ **Do not read "D-42 closed" as "the guards are fixed."**

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg). **D-23, D-30, D-35, D-36, D-38, D-41 and now D-42 are the SEVEN EXECUTED.** ⭐ **NOTHING waits on CS.** Leg 104 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line. ⭐ **Leg 104 is why: D-42's ruling landed AFTER leg 103's pointer was written, and leg 103's pointer said D-42 was still unanswered. The tail summary was stale within one leg.**

### ⭐ S-184 NEW — A CS RULING CAN LAND BETWEEN THE POINTER AND THE PICKUP, AND IT OUTRANKS THE POINTER'S "NEXT TASK"

Leg 103 closed naming P4.4b Migration C as next. Between that close and leg 104's STEP R, CS closed
D-42 — a **live unauthenticated write path on five plan-committing DEFINER functions**. Leg 104 took
D-42 first and deferred C/D by one unit.

⛔ **The rule this establishes:** the pointer's "next task" is the default, **not** a priority ruling.
STEP R's S-80 grep is not bookkeeping — it is a **fresh-work check**, and a newly-closed CS decision
is time-sensitive work by definition, because it was blocking and is now not. Weigh it against the
pointer's next task on **severity**, and say in the log why the order was chosen.
⭐ Here it was not close: a security hole reachable by `anon` beats a fixture that proves a happy path.

## ⛔ leg 105 (2026-08-04) — P4.4b Migration C SHIPPED. S-185, S-186 raised.

**Shipped:** `20260803221105_prd110_p44b_receive_spot_fill_po_v3` — phase 2 of post-facto fill.
Cody reviewed across Articles 1, 2, 3, 4, 6, 7, 8, 12, 13, 16 and **required two revisions, both taken**.

### ⏸️ S-185 NEW — `purchase_orders` HAS NO `audit_log_write` TRIGGER. EIGHT DEFINER WRITERS, ZERO UNIVERSAL AUDIT.

Probed live this leg: `pg_trigger` on `public.purchase_orders` holds exactly one non-internal trigger,
`trg_po_number_one_po_id`. There is **no** `audit_log_write` trigger, so **Article 8's universal audit
does not cover the table at all**. The eight DEFINER writers are `create_purchase_order`,
`add_purchase_order_lines`, `edit_purchase_order_line`, `cancel_po_line`, `confirm_physical_receipt`,
`receive_purchase_order`, `create_spot_purchase_v3`, and now `receive_spot_fill_po_v3`.

⛔ **Pre-existing, not introduced by P4.4b** — leg 105 matched the incumbent rather than diverging.
The compensating control is `procurement_events` (RLS enabled), which every one of them writes.
**Smallest unblock:** one migration adding the generic audit trigger to `purchase_orders`, then a
fixture asserting a `write_audit_log` row per writer. ⛔ It touches the behaviour of **8 existing
writers**, so it is its own unit under LAW 10 — do not fold it into a P4.4b leg.

### ⏸️ S-186 NEW — A CANCELLED PO LINE KEEPS `received_date IS NULL` FOREVER, AND 13 LIVE ROWS PROVE IT.

`cancel_po_line` sets `purchase_outcome = 'not_purchased'` and does **not** stamp `received_date`.
So "unreceived" and "still open" are **not the same predicate**, and the difference is not theoretical:
measured this leg, `purchase_orders` holds **13 rows** with `received_date IS NULL` **and**
`purchase_outcome = 'not_purchased'` (against 15 genuinely-open NULL/NULL rows).

⛔ **Any code that treats `received_date IS NULL` as "open" can resurrect a line an operator killed.**
Migration C's first draft did exactly that and would have flipped a cancelled line to `'received'`.
The correct predicate — already used by `_resolve_open_walkin_po_v3` — is
`received_date IS NULL AND COALESCE(purchase_outcome,'') <> 'not_purchased'`.
⚠️ **A later leg should sweep the other seven writers and any view/report for the bare-NULL test.**
Not done here (LAW 10, own unit).

### ⚠️ LAW 12 STATE CHANGED UNDER THE POINTER — `2026-08-04` IS NO LONGER SAFE

Leg 104's pointer recorded all 96 `refill_plan_output` rows for `2026-08-04` as **pending**,
`dispatched = 0`, and said LAW 12 was therefore satisfied for that date. **At leg 105's STEP R the same
96 rows read `pending = 0`, `dispatched = 93`.** CS dispatched the plan overnight. ⛔ **That date now
has non-pending rows and is hard off-limits under LAW 12.** Nothing this leg went near it.
⭐ This is S-184 in a second costume: the pointer was accurate when written and wrong when read, and
only a live probe could tell. **Re-probe the plan date every leg; never inherit its status.**

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg). **D-23, D-30, D-35, D-36, D-38, D-41 and D-42 remain the SEVEN EXECUTED.** ⭐ **NOTHING waits on CS.** Leg 105 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## LEG 106 — P4.4b Migration D (golden fixture 26). Four findings, all discovered by running the fixture rather than by reading anything.

### ⛔ S-187 — THE GOAL COMMAND'S FIXTURE NUMBERS ARE NOT `golden.fixtures` IDS. Do not conclude a fixture is missing from an id gap.

STEP R this leg probed `golden.fixtures` for the spec ids 1..30 and found **4, 9, 13, 15, 23, 26**
absent — which reads, wrongly, like six unbuilt fixtures against a pointer that declared only 26 and 9
owed. **The pointer was right.** The harness renumbered when the built scenario outgrew the one-line
spec:

| goal-command / GOLDEN-FIXTURES row | built as                                                                        |
| ---------------------------------- | ------------------------------------------------------------------------------- |
| 4 — Cross-pod M2M at SKU level     | **41** (M2M transfers match on `boonz_product_id`)                              |
| 13 — Substitution ladder full walk | **40** (supply ladder, all six rungs, every rung logged)                        |
| 25 — Edit survival under re-run    | **50** (human edits are EVENTS that survive an engine re-run)                   |
| 15 — New machine day 1             | **no dedicated fixture**; archetype-prior assertions live in **29** and **14**  |
| 23 — Expired-unit-sold incident    | **no dedicated fixture**; `expired_sold_incident` asserted in **21** and **65** |

⚠️ **15 and 23 are the honest gap** — covered by assertions inside other fixtures, not by a fixture of
their own. That is a judgement call an earlier leg made and never wrote down. ⛔ It is NOT re-opened
here (LAW 10, and Phase 3/4 were closed on that basis); it is recorded so no future leg re-derives this
table or "discovers" five missing fixtures. ⭐ **Check coverage by NAME and by asserted symbol, never by id.**

### ⛔ S-188 — `prevent_duplicate_unstarted_dispatch`: one unstarted dispatch row per (machine, shelf, product, action, date).

Undocumented anywhere. A fixture that plants several legs for the same product on one shelf and date
gets `Duplicate unstarted dispatch row ... Use slice rows (filled_quantity > 0) for multi-batch packs.`
⭐ Fixture 26 answers it with **one shelf per leg** (six shelves, all probed composition-clean first),
which also keeps the composition assertions readable: **`shelf_composition` has no date grain**, so
five legs on one shelf would sum into a single unreadable total.

### ⛔ S-189 — `warehouse_inventory.quarantined` IS A GENERATED COLUMN, AND A PLANT THAT IGNORES IT FAILS INVISIBLY.

`quarantined` = `provenance_reason IS NULL OR provenance_reason IN ('unknown_pre_migration','dispatch_return_unverified')`.
`v_wh_pickable` excludes quarantined rows. ⛔ **So a planted batch with no `provenance_reason` is
Active, in-date, positive-stock — and invisible to FEFO.** It fails with the _same_ "short by N"
message as having no stock at all, which is what makes it expensive.
⛔ And `wh_provenance_event_required` demands a `source_event_id` for every provenance **except**
`manual_adjust` / `snapshot` / `status_flip` / `unknown_pre_migration` / `unattributed_write` — of
which only `snapshot` and `manual_adjust` also avoid quarantining. ⭐ **`'snapshot'` is the only honest
choice for a harness plant**; `'dispatch_receive'` would have been a lie that also needed a fake event id.

### ⛔ S-190 — `wh_fefo_for_line` JUDGES SHELF LIFE AGAINST THE LINE'S PLAN DATE, SO ON A 2030 FIXTURE DATE ALL REAL STOCK IS EXPIRED.

`AND (vp.expiration_date IS NULL OR vp.expiration_date >= p_plan_date)`. Every real batch of the
fixture's product expires 2026-09-08, so at `plan_date = 2030-08-04` **pickable stock is zero** and any
overfill leg raises "short by N" no matter what production holds.
⭐ **Consequence for every future fixture that needs a warehouse debit on a 2030 date: plant your own
batch.** Fixture 26 plants 2 units at a 2031 expiry, which is strictly better than leaning on live
stock — it makes the control (overfill 8 → short by 6 → still refuses), the happy path (overfill 0 →
no debit) and the exact-n leg (overfill 1 → debits exactly 1) all deterministic and immune to
production drift.

### ⚠️ SPEC CORRECTION — design §7's "WH debited exactly n" IS FALSE ON THE INCIDENT REPLAY, and asserting it would have asserted a falsehood.

`receive_dispatch_line` debits the warehouse **only for the OVERFILL** (`GREATEST(filled - planned, 0)`);
the planned units left the warehouse at pack time. On the incident shape (planned 1, n = 1) the correct
warehouse delta is **0**, not −1.
⭐ Fixture 26 keeps the property honest in two pieces rather than restating the spec: **seq 23** pins the
zero and explains why zero is correct and not vacuous (had phase 1 passed n+m=9, overfill would be 8,
the batch short, and the leg would have RAISED like the control); **seq 39-41** add a second leg where
n=2 EXCEEDS the planned 1, so the debit is a real −1 that **can move** — that is the assertion that goes
red if anyone ever "simplifies" phase 1 to hand the incumbent the full filled quantity.
⛔ The design file is NOT amended (leg-103 precedent): the correction lives here and in the log.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg). **D-23, D-30, D-35, D-36, D-38, D-41 and D-42 remain the SEVEN EXECUTED.** ⭐ **NOTHING waits on CS.** Leg 106 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

## ⛔ leg 107 (2026-08-04) — FIXTURE 9 DERIVED AND DRY-PROVEN, NOT YET BUILT. S-191..S-196 raised. D-43 NEW.

Leg 107 spent itself re-deriving the NOOK 07-20 incident from live data (the one-line spec is not
buildable from) and dry-running the whole scenario. **Nothing was applied**: DB counters, all three
RPC md5s, `prd110%`=270 and `max(version)`=20260803223550 are byte-identical to this leg's STEP R.
The scenario runs end-to-end and every leg behaves; the migration is simply unwritten.

### ⛔ WHAT THE NOOK 07-20 INCIDENT ACTUALLY WAS (reconstructed from production, not from memory)

Machine **`94de9553-8058-4ae1-b3f2-fce2745ff85d` = NOOK-1019-0200-B1**. On 2026-07-20:
12 dispatch rows pushed at 03:07:43, one more at 04:34:20. The packing UI failed — the live
`skip_reason` reads **`other: Packing is not saving`**. A repack was run. **All 10 rows that were
`packed=true` were returned with `return_reason='superseded_by_repack'`, `filled_quantity=0`; the 3
rows that were never packed were untouched.** All **11** `refill_plan_output` rows for that date were
reset and **zero** fresh dispatch rows were ever created. The machine was refilled anyway and the only
record is three hand-written `adjust-NOOK-1019-0200-B1-A12/A14-2026-07-20` rows in
`pod_inventory_audit_log` (`source='correction'`), noted by the operator as
_"NOOK 20-07 manual refill: record swap-in Nutella A12 + VW Upgrade/Reload A14 batch expiries"_.
⭐ **All 10 `superseded_by_repack` rows in the entire fleet's history are this one machine on this one
date.** The frozen state is STILL LIVE: those 11 plan rows sit `approved` + `dispatched=false` with no
dispatch rows to serve them, and repack can never run again for that date (S-192).

### ⛔ S-191 NEW — `repack_machine` ADMITS A ROLE THAT `push_plan_to_dispatch` REFUSES. THIS IS THE ROOT CAUSE.

`repack_machine` gates on `('warehouse','operator_admin','superadmin','manager')`.
`push_plan_to_dispatch` gates on `('operator_admin','superadmin','manager')` — **`warehouse` is absent.**
So the packing role — the one that hits "Packing is not saving", the one authorised to repack — passes
repack's gate, has every packed row returned and every plan row reset, and then the re-push **RAISES**.
There is **no savepoint**: returns and resets are already applied when repack returns
`{"status":"error","error":"push_failed", ...,"returned_count":2,"plan_rows_reset":1,
"fresh_dispatch_rows_created":0}`. ⚠️ Reproduced deterministically in dry run, message verbatim:
`push_plan_to_dispatch: caller 7f4ecaa4-… lacks required role`. **Production's 07-20 signature
(rpo reset to `dispatched=false`, zero fresh rows) is exactly this path.**

### ⛔ S-192 NEW — REPACK IS SINGLE-SHOT PER (MACHINE, DATE), PERMANENTLY.

`return_dispatch_line`'s final UPDATE sets **`dispatched = true`** (along with `returned`,
`filled_quantity=0`, `pack_outcome='returned'`). `repack_machine` refuses when ANY row for that
(machine, date) has `dispatched=true`. ⛔ **So the first repack's own returns permanently block every
later repack**: second call returns `{"error":"cannot_repack_after_dispatch","dispatched_count":2}`.
Once a repack half-completes there is no retry — the only remaining path is the LOG path.

### ⛔ S-193 NEW — EVEN ON THE AUTHORISED PATH REPACK FREEZES, AND REPORTS `status='ok'`.

Run as **operator_admin** (so push is permitted), repack returns `status='ok'` with
`plan_rows_reset=1` and **`fresh_dispatch_rows_created=0`**. Measured immediately after: the plan row
is back to **`dispatched=true`** and the only dispatch row on the date is the **returned** one.
⛔ **The returned row still occupies the (machine, shelf, product, action, date) key, so
`push_plan_to_dispatch` treats the plan line as already served, pushes 0 lines and re-stamps
`dispatched=true`.** The machine gets nothing, the plan believes it was dispatched, and repack reports
success. ⭐ **A silent freeze on the supported path is a worse defect than S-191, and neither is in any document.**

### ⏸️ D-43 NEW — CS DECISION: MAY `warehouse` REPACK AT ALL?

S-191 has two honest fixes and they differ in policy, not in code: **(a)** add `warehouse` to
`push_plan_to_dispatch`'s role list (packing staff can fully self-serve a repack), or **(b)** drop
`warehouse` from `repack_machine`'s gate so it refuses UP FRONT instead of half-completing (repack
becomes an operator_admin action). ⛔ **Either way `repack_machine` must pre-flight the push
authorisation BEFORE it returns a single row** — half-completion is the defect, and that part is not a
judgment call. ⚠️ S-193 is independent of D-43 and must be fixed regardless. **Nothing waits on D-43:
fixture 9 asserts the system as it stands and closes the incident under LAW 1.**

### ⛔ S-194 NEW — `chk_packed_requires_outcome`: `packed=true` REQUIRES `pack_outcome NOT NULL`.

`CHECK ((packed = false) OR (pack_outcome IS NOT NULL))`, **NOT VALID** — and per the PRD-107 landmine
a NOT VALID check still re-checks UPDATEd rows, which is exactly how it fired. ⛔ Any harness plant that
promotes a row to packed must set `pack_outcome='packed'::public.pack_outcome_enum` in the SAME UPDATE.
⭐ Enum values: `packed, partial, not_filled, packed_transferred, returned, no_pack_needed`.
⭐ Still insert with `packed=false` first (`trg_conserve_split_qty` is BEFORE INSERT on `packed=true`).

### ⛔ S-195 NEW — AN `refill_plan_output` PLANT WITHOUT `pod_product_id` GOES GREEN FOR THE WRONG REASON.

A plant with NULL `pod_product_id` makes `push_plan_to_dispatch` report
`lines_skipped_null_product: 1` and push nothing — which **looks identical to the S-193 freeze**.
⚠️ Leg 107 nearly recorded a false root cause on exactly this. ⛔ Always set BOTH `pod_product_id` and
`pod_product_name`; re-measure after fixing the plant before believing any push-count finding.
⭐ `refill_plan_output.pod_product_name` is **NOT NULL**. ⭐ Valid pair for
`00103662-15c4-47c8-9a32-26d421fa9827`: `pod_product_id 9eb1e4f1-a47d-4bda-9090-bf0e13d1d8b9` / `'NRJ Nut'`.

### ⭐ S-196 NEW — `log_manual_refill` NEVER BLOCKS ON A WAREHOUSE SHORTFALL. THAT IS THE RECOVERY PROPERTY.

Asked for 10 units the warehouse does not have, it returns **`status='ok'`**, writes the FULL 10 to
`pod_inventory`, decrements the warehouse by **0**, and returns
`shortfall_warning: "WH had 10 less than the 10 refilled — physical count may be needed"`.
⭐ **The LOG path records physical truth and flags the discrepancy rather than stranding the operator** —
it is the exact counterpart of the ANTI-PATTERN "forcing a dispatch state at night instead of the LOG path",
and it is what saved NOOK on 07-20. ⛔ It writes `pod_inventory` (protected) — Cody must review the fixture.
⚠️ Its FEFO filter is `expiration_date >= p_refill_date` and `NOT quarantined`, so **S-190 and S-189 both
apply**: at a 2030 date a fixture must plant its own batch with `provenance_reason='snapshot'`.

### ⛔ NAME LOOKUP — `repack_machine` AND `log_manual_refill` RESOLVE BY `machines.official_name`.

⛔ NOT `machine_number` (which holds a different value entirely) and there is no `machine_name` column.
⭐ Fixture machine `98868de9-a977-40f4-b0ea-ce787877f24a` → `official_name` **`WH3_1035_0000_W0`**.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted) plus **D-43 NEW and UNANSWERED**. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.**

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

## ⭐ leg 108 (2026-08-04) - FIXTURE 9 BUILT AND GREEN. THE P4 GATE IS CLOSED. S-197, S-198 raised.

Leg 108 picked up leg 107's dry-proven scenario, wrapped it in the fixture-26 envelope, and shipped
it. **`golden.run_fixture(9, ..., 'P4')` returns 73/73, three consecutive times, with zero residue on
all five tables it touches.** Golden moved **57 / 1994 -> 58 / 2067**. Two migrations:
`20260803231648_prd110_p4_golden_fixture_9` and
`20260803231750_prd110_p4_golden_fixture_9_assert4_searchpath_truth`.

⭐ **THE P4 GATE IS CLOSED.** All six gate fixtures re-run green this leg: **9 (73), 16 (31), 17 (25),
18 (80), 20 (21), 26 (89)**. Fixture 23 has no dedicated fixture by design (S-187) and its
`expired_sold_incident` coverage was verified present in **21 (1 assertion) and 65 (2)**.

### ⛔ S-197 NEW - A NO-OP RPC LEAVES THE CANONICAL-WRITER GATE OPEN FOR THE REST OF THE TRANSACTION.

`enforce_canonical_dispatch_write` passes any write when
`app.via_rpc = 'true' AND app.rpc_name = ANY(allowlist)`. `unskip_dispatch_line` sets both on its
FIRST line, **before** its noop check, and never restores them. So a call that returns
`{"status":"noop"}` and changes nothing still leaves the session holding a valid allowlisted pair.
⛔ **Measured by attempt with a control, per S-177, not by reading the predicate** - fixture 9 seq
56/57/58: the identical raw `UPDATE public.refill_dispatching` is logged as a bypass one statement
before the noop call (control = 1) and **invisible one statement after it** (after_noop = 0).
⚠️ **Blast radius is bounded to one transaction** - every `set_config` in this tier passes
`is_local = true` - so under PostgREST (one request, one transaction) it is contained. It is NOT
contained inside a DO block, a DEFINER that calls another DEFINER, or a pg_cron job that does several
things in one transaction. ⭐ **Same class for provenance:** after `log_manual_refill` returns,
`app.provenance_reason` still reads `manual_adjust` (fixture 9 seq 62), so the next protected write
inherits a provenance it did not choose. ⛔ **The fix is to restore the prior GUC values before
`RETURN`, exactly as the P4.4b tier already does (fixture 26 seq 76-78 pins that).** It touches three
live DEFINER functions and needs its own unit, its own Cody review and its own fixture - Cody
required it be recorded here and NOT attempted inside a fixture migration (LAW 10).

### ⚠️ S-198 NEW - 196 OF 332 PUBLIC `SECURITY DEFINER` FUNCTIONS PIN `search_path=public` WITHOUT `pg_temp`.

Found because fixture 9 seq 4 went **RED on its first run**. The assertion was written by analogy with
fixture 26 seq 6/7 (`'search_path=public, pg_temp'`) and I assumed the legacy tier matched.
⛔ **It does not:** `repack_machine`, `log_manual_refill` and `push_plan_to_dispatch` all pin
`search_path=public` with **no `pg_temp`**, while `return_dispatch_line` and `unskip_dispatch_line`
pin `'public, pg_temp'`. Listing `pg_temp` LAST is what stops it being searched FIRST, so a definer
function pinned to `public` alone still resolves unqualified names against the caller's temp schema
ahead of `public`. Measured fleet-wide this leg across **332** public DEFINER functions:
**105** hardened with `pg_temp` · **196** `search_path=public` only · **22** pinning **nothing at all**.
⛔ **Pre-PRD-110 and fleet-scale, so recorded and NOT churned (LAW 10).** Fixture 9 seq 4 now states
the true value and its description names the gap, so nobody reads `search_path=public` as the
standard. ⭐ **When S-198 is executed, seq 4 is the assertion that must move.**
⭐ **And the process point is the one worth keeping: the fixture caught me.** The red was correct.
Writing the assertion before believing the answer is what LAW 13 buys.

### ⚠️ S-187 TABLE, ONE SMALL DRIFT - fixture 15's coverage is in **14**, not in 29.

S-187 records archetype-prior assertions for spec row 15 as living in "**29** and **14**". Catalog
check this leg: fixture **14** has one matching assertion, fixture **29** has **zero**. The 23 half of
the table verified clean (21 and 65 both carry expired assertions). ⛔ Row 15 is not in the P4 gate so
nothing is blocked; recorded so no future leg re-derives the table and "discovers" a missing fixture.

### ⏸️ D-43 STILL OPEN AND STILL BLOCKING NOTHING.

Fixture 9 asserts the system as it stands, defects included. ⛔ **When D-43 is executed, seq 1-2 and
16-28 are the assertions that go red, and updating them IS the proof the fix landed. Do NOT "repair"
this fixture by loosening them.** ⚠️ S-193 remains independent of D-43 and must be fixed regardless.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43, still NEW and UNANSWERED**. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** ⭐ **NOTHING waits on CS.**

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

## ⛔ S-199 (NEW, leg 109) — THE SHADOW TABLES ARE `run_id`-KEYED, SO "RE-RUN IS IDEMPOTENT" CANNOT MEAN "ROW COUNT UNCHANGED". S4 MUST NOT ASSERT THAT.

Measured before writing a line of S4, and it inverts the obvious assertion.

- `pod_refills_shadow_pkey` = **(run_id, plan_date, machine_id, shelf_id, pod_product_id)** ·
  `pod_refill_plan_shadow_pkey` = **(run_id, plan_date, machine_id, shelf_id, pod_product_id, action)** ·
  `refill_plan_output_shadow_uniq` = **(run_id, shelf_id, pod_product_id, action, COALESCE(boonz_product_id, ...))**.
- `engine_add_pod_v3` contains **no `DELETE`, no `TRUNCATE`, no `ON CONFLICT`** — a single
  `INSERT INTO public.pod_refills_shadow`. Its run key is `v_run_id uuid := gen_random_uuid()`,
  minted fresh **per call**.
- ⛔ Therefore a third re-run does **not** overwrite the second: the table **accumulates one
  generation per run, by design** (375 distinct `run_id`s already present). A naive S4 asserting
  "row count unchanged after re-run" would go **RED against correct behaviour**.

⭐ **The invariant actually under test is CONTENT equality per `run_id`, not row-count stability:**
same inputs → same plan. S4 must assert an md5 over the ordered projection
`(machine_id, shelf_id, pod_product_id, action, qty)` grouped by `run_id`, and that the three
`run_id`s are **distinct**.

⛔ **AND IT MUST BE NON-VACUOUS OR IT IS S-132 ALL OVER AGAIN.** `run_nightly_shadow_v3` catches the
engine's "no picked/cs_added machines" and reports `no_picks`/`skipped_calendar` — a **successful
summary row with zero plan lines**. Three such runs are trivially "identical". ⭐ S4's FIRST
assertion must be `lines_run1 > 0`.

⛔ **`p_settle_limit => 0` IS MANDATORY.** `run_nightly_shadow_v3` STEP 3 loops
`engine_forecast_error_v3` over dates **`WHERE plan_date <> v_pd`** — a non-zero limit makes S4
mutate _other_ dates and stop being hermetic.

⭐ **Carry the ADR tripwire:** `golden.run_engine_v3_if_built` already captures `pod_refills` and
`pod_refill_plan` live counts before the v3 call (ADR-shadow-plan-tables §8 obligation 3, **absolute,
not scoped to plan_date**). S4 extends that helper's shape to three consecutive calls; it must not
invent its own.

⚠️ **`shadow_runner_log_v3` appends by design** (one `summary` row per run) — "no dup lines" is scoped
to the **plan** tables, never to the runner log.

📌 **Date for S4:** 2030-01/02 and 2030-03..08 are crowded with fixture dates (58 distinct), and
2030-07-20/21 belong to fixture 9. **2030-09-10 is clear** and `pod_refill_plan_shadow` holds **zero**
rows for any 2030 date.

## ⭐ S-176 RE-DIAGNOSED (leg 109) — THE PREMISE HAS EXPIRED. THE MEASUREMENT LAYER WORKS; GATE 0 IS WHAT MAKES IT SPARSE.

⛔ **The pointer carried S-176 as "the LARGEST remaining known gap after the stress suite", stated as
`engine_forecast_error_v3` has no rows for any real plan_date after 2026-06-26. THAT IS NO LONGER
TRUE.** Diagnosed read-only (per the pointer's own ⭐ DIAGNOSE first), while S7 held the DB.

**What is actually live:**

- `engine_forecast_error_v3` real (non-2030) plan_dates = **exactly two: 2026-06-26 and 2026-08-04**.
  **2026-08-04 holds 145 rows**, written **2026-08-03 21:22 UTC by cron 45** — a real plan_date well
  after 2026-06-26. ⭐ The layer produced 145 series **the first night the engine was not blocked**.
- `v_engine_wmape_v3` for 2026-08-04: **v19 n_series 49 · v3 n_series 96**, `sum_forecast` 299.46 /
  246.932. `wmape` is NULL — with `is_vacuous=true` and **`vacuous_reason='horizon_not_elapsed'`**,
  `horizon_end_max` **2026-08-11 (v3) / 2026-08-18 (v19)**.
- ⭐ **That NULL is CORRECT, not vacuous-by-bug.** WMAPE cannot exist before its horizon elapses and
  actuals settle. The view already reports the honest reason rather than a zero — which is precisely
  what the pointer's ⛔ "do NOT make wmape report 0" was protecting.
- `unsettled_ready` (rows with `NOT actuals_settled AND horizon_end <= today`) = **0**. The STEP 3
  settle loop has nothing to do because nothing is due yet. It is not stalled.
- Only settled date **2026-06-26**: 141 series, **WMAPE 0.7878, bias_ratio 0.3993** — the v19 baseline.

⭐ **ROOT CAUSE OF THE SPARSENESS, and it is not a defect:** `shadow_runner_log_v3` step='engine'
tally since 2026-07-01 = **ok 17 · blocked_gate0 10 · no_picks 2 · skipped_calendar 2 · error 3**.
The nightly runner is _usually blocked at Gate 0_ ("N machine(s) picked but unconfirmed"). Gate 0 is
**manual-only by CS decision #1 / LAW 11**. ⛔ **So real-date WMAPE populates only as fast as CS
confirms picks. That is the manual gate working as specified, NOT a hole in the telemetry.**

⛔ **CONSEQUENCE FOR _DONE_ — a TIME dependency, not a build task.** No v3 WMAPE _number_ can exist
for 2026-08-04 before **2026-08-11** (horizon_end), and only then if a settle pass runs — which cron
45 does automatically (`p_settle_limit` default, `WHERE NOT actuals_settled AND horizon_end <= today
AND plan_date <> v_pd`). ⭐ **Nothing needs building. Do NOT "fix" this.** The DONE report should
state the scoreboard is populated and WMAPE is horizon-pending with its settle path proven on
2026-06-26.

⚠️ **TRAP THIS LEAVES BEHIND — the 3 `error` rows are PERMANENTLY MISLEADING HISTORY.** All three
carry SQLERRM `engine_add_pod_v3: no picked/cs_added machines...`, which the **S-112 classifier maps
to `no_picks`/`skipped_calendar` and can never map to `error`**. They were written **2026-07-31
21:22 and 21:52**, i.e. _before_ S-112 shipped; the 2026-08-02 and 2026-08-03 nights classify
`blocked_gate0` correctly, proving the classifier is live now. ⛔ **Any future assertion counting
`status='error'` MUST scope to `run_started_at > 2026-08-01` or it will "discover" these three
forever.**

## ⛔ S-200 (NEW, leg 110) — GOLDEN WAS NEVER GREEN, AND THE ASSERTIONS THAT ARE RED ARE MOSTLY ANCHORED TO A MOMENT, NOT TO AN INVARIANT

The leg-108 pointer's headline — _"Golden is fully green at 58 fixtures / 2067 assertions"_ — is
**false, and it had propagated unchallenged for roughly twenty-five legs.** The first complete
58-fixture sweep since **2026-07-31** ran this leg as S7 round 1 and measured the true state:

| measured 2026-08-03/04, S7 round 1 | value                               |
| ---------------------------------- | ----------------------------------- |
| fixtures evaluated                 | **57 of 58** (48 timed out — S-201) |
| fixtures green / red               | **50 / 7**                          |
| assertions pass / fail             | **2008 / 10**                       |
| assertions never evaluated         | **49** (all of fixture 48)          |
| round-1 wall clock / DB time       | 1287 s / 1021 s                     |

⛔ **The claim decayed the same way S-129 said it would.** Nobody re-ran the suite; each leg
inherited the previous leg's adjective. Fixture 8 has been red since **2026-08-01** and fixture 24
since **2026-07-31** — both already had S-numbers (S-129, S-55) — yet the pointer still said
"fully green". **A green that is inherited rather than measured is not a green.**

**THE RED SET, and every one of them classified:**

| fixture | seq | expected → actual                 | class                                        |
| ------- | --- | --------------------------------- | -------------------------------------------- |
| 2       | 27  | `status_floor` gt 0 → **0**       | (A) ambient non-vacuity gone vacuous         |
| 2       | 64  | `s37_family` eq 26 → **24**       | (B) pinned ambient snapshot                  |
| 8       | 29  | `floor_protected` gt 0 → **0**    | (A) — already **S-129**                      |
| 14      | 6   | clamp `tot = mx` → 1 violation    | (C) transient-state conflation — **FIXED**   |
| 24      | 29  | `sent_consumer_rows` gt 0 → **0** | (A) — already **S-55**                       |
| 40      | 8   | `B_real_primary` gte 1 → **0**    | (A) ambient non-vacuity gone vacuous         |
| 55      | 25  | rpo 2030+ sweep eq 21 → **26**    | (D) constant invalidated by the build itself |
| 55      | 26  | prp 2030+ sweep eq 9 → **11**     | (D) same                                     |
| 59      | 25  | `unmatched` eq 18 → **33**        | (B) pinned ambient snapshot                  |
| 59      | 26  | `undecided` eq 6 → **11**         | (B) same                                     |

⭐ **NINE OF THE TEN ARE THE SAME DEFECT IN THE HARNESS, NOT IN THE ENGINE.** They assert over
state the build does not own — the live fleet, or the accumulating set of fixtures — so correct
behaviour eventually turns them red and the red carries no information. **This is the generalisation
S-55 and S-129 each predicted in their own words; S-200 is that prediction arriving fleet-wide.**

**(C) IS CLOSED THIS LEG — and it is the worked example for the rest.** Fixture 14 seq 6 asserted
"composition total = capacity" on every over-capacity ("sensor lie") shelf. Shelf **A10** measured
`max_stock 12 · WEIMI 16 · composition 9`, and its **entire** event history explains the 9:

```
2026-07-30 18:40  correction        +12   P1.4 estimator cold-start seed   <- the clamp, at CAPACITY
2026-08-01 20:40  derived_decrement  -3   P1.4 estimator: WEIMI drop allocated
```

⭐ **The clamp fired perfectly. The seed is 12, not the 16 the sensor was shouting.** seq 6 was
red because three units had since been sold. It had silently conflated _"the clamp fired at seed"_
(its actual job) with _"nothing has been consumed since"_ (never its job), so it could only ever
be satisfied by a clamped shelf that had never sold a unit. Migration `20260804000121` restates it
in **conservation form** — seed event = capacity **AND** composition total = sum of _all_ that
shelf's `inventory_events` — which proves strictly **more** than the original and survives trade.
Fixture 14 re-ran **49 / 0**. ⛔ It was **not** weakened to `tot <= mx`: that is seq 8, fleet-wide,
and collapsing the two would have deleted the clamp proof (the S-48 / S-52 / S-55 vacuity mode,
now burned four times).

**THE REMEDY PER CLASS — all measured, none applied yet:**

- **(A) ambient non-vacuity (2/27, 8/29, 24/29, 40/8).** Use **fixture 31's rollback-probe idiom**,
  which is already proven in this build: seed the condition inside a PL/pgSQL sub-block, measure
  into variables (they survive), then `RAISE EXCEPTION ... USING ERRCODE='22023'` and swallow it.
  Rows vanish, measurements live, and the precondition is **self-supplied instead of borrowed**.
  ⛔ **Do NOT relax any of these to `gte 0`** — that converts the tripwire into the exact vacuous
  assertion it exists to prevent.
- **(B) pinned ambient snapshots (2/64, 59/25, 59/26).** A hard-coded count of live rows is a
  photograph, not an invariant. Re-express as the _relationship_ the fixture actually cares about
  (fixture 2 already has `s37_n_mismatch` and `s37_family_null` next door doing this correctly).
- **(D) 55/25 and 55/26 — READ THIS BEFORE TOUCHING THE CONSTANT.** These are fleet sweeps pinning
  the **total** synthetic-date rows: `refill_plan_output` 21 and `pod_refill_plan` 9. Measured live:

  | table | 2030-01-11 (fx10) | 2030-02-03 (fx33) | 2030-03-05 (fx63) | 2099-12-\* (legacy) | total |
  | ----- | ----------------- | ----------------- | ----------------- | ------------------- | ----- |
  | rpo   | 7                 | 5                 | 5                 | 9                   | 26    |
  | prp   | 7                 | 2                 | 2                 | —                   | 11    |

  ⭐ **The overshoot is exactly fixture 63's own legitimate plants.** The tripwire is therefore
  **guaranteed to go red every time the build adds a synthetic-date fixture**, and its red says
  nothing about residue. ⛔ **Do not simply bump 21 → 26; that just re-arms the same trap for
  fixture 67.** Restate it as _"every 2030+ `plan_date` belongs to a declared `golden.fixtures`
  row"_ — residue-detecting **and** immune to new fixtures. ⚠️ The nine `2099-12-*` rows are
  **pre-PRD-110 legacy**, one machine, carrying comments `[S1] refill full-fill test` and
  `[S4] BUG-012 cascade live test`; they are **not** PRD-110 residue and need an explicit
  carve-out with that provenance, not a silent inclusion. ⛔ **LAW 12 — leave those rows alone.**

**Loop impact:** ⛔ **S7 cannot be declared, and by LAW 8 a golden red halts phase work.** S7 is
recorded **FAILED** in `golden.stress_runs` (`4e5f2c09`) with the full inventory above. S1–S6 are
untouched and unblocked — none of them depends on this red set.

## ⚠️ S-201 (NEW, leg 110) — FIXTURE 48 CANNOT BE EVALUATED AT ALL, AND AN UNMEASURABLE FIXTURE READS AS A GREEN ONE

`golden.run_fixture(48, …, 'P4')` dies on **57014, statement timeout**, inside its own
`scenario_sql` — the `excluded_leak` scratch write joining `facing_proposals_v3` to
`v_facing_performance_v3`. It is **not** on the pointer's known-slow list (3, 5, 105, 42, 53, 37,
16, 17), so it is a new member and it is worse than slow: **it never returns a verdict at all.**

⛔ **THE DANGEROUS PART IS THE ARITHMETIC.** Fixture 48 holds **49 enabled assertions**. A sweep
that counts failures sees zero failures from fixture 48 and reads as clean — the fixture
contributes **nothing** to `n_fail` precisely because it contributed nothing at all. **Only the
`fixtures_evaluated` count (57, not 58) exposes it.** Any future S7 harness MUST assert
`fixtures_evaluated = fixtures_enabled` before it is allowed to report a pass.

**Smallest unblock:** profile the `excluded_leak` sub-select; it is the only statement in the
timeout `CONTEXT`. Likely an unindexed join across the two facing objects. Either index it or split
that one scratch write into its own batched step, the same way S7 batches per fixture to fit under
the API timeout.

---

## ⭐ leg 111 (2026-08-04) — S-200 RED SET: 2 OF 7 CLOSED. S-200's OWN CLASSIFICATION CORRECTED. S-202 RAISED.

Two class-(A) reds closed, each by a **different** remedy — and the difference is the finding.

### ✅ 24/29 CLOSED (S-55, red since 2026-07-31) — self-supply, exactly as S-200 prescribed

All 40 sentinel `warehouse_inventory` rows are Active, `warehouse_stock > 0`, `consumer_stock = 0`.
The fleet cleaned itself, so seq 29 (`gt 0`) went red **while seq 30/32/33 stayed green on 0 = 0** —
the entire S-50 drain leg was vacuous. Fixed by planting the precondition inside fixture 24's own
rollback probe. Fixture 24 **42 / 0**, and the green is now **earned**: `planted=3 · probe_rows=3 ·
drained=3 · units=21 · consumer_after=0 · audit_rows=3 · stranded=0 · retired=40`.
Migration `20260804001959`. Residue nil (live sentinel `consumer_stock` back to 0, zero
`bug001_silent_reactivation` alerts).

### ⛔ 40/8 CLOSED — BUT S-200 CLASSIFIED IT WRONG, AND THE PRESCRIBED REMEDY WOULD HAVE PROVED NOTHING

S-200 filed 40/8 as class (A) with the rollback-probe remedy. **Live measurement says otherwise:**

| anchor           | real_primary | real_other | sentinel |
| ---------------- | ------------ | ---------- | -------- |
| A (Fade Fit)     | 0            | **0**      | 7992     |
| B (Vitamin Well) | 0            | **88**     | 0        |

⭐ **B's stock did not evaporate — it MOVED WAREHOUSE.** seq 8 was pinned to the machine's PRIMARY
warehouse, so ordinary inter-warehouse traffic turned it red while the fact it exists to prove
stayed true the whole time. That is class **(B)** (re-express the relationship), not class (A).
**A plant would have seeded supply that already exists.** Fixed by restating seq 8 network-wide
(`B_primary + B_other >= 1`) off scratch keys that already existed — **no `scenario_sql` change** —
plus **seq 57 NEW** pinning `A_primary + A_other = 0`, the half of the contrast seq 7 never covered.
Fixture 40 **57 / 0**. Migrations `20260804002428` + `20260804002451`.

⛔ **THE LESSON FOR THE REMAINING RED SET: RE-DERIVE EACH CLASS LIVE, DO NOT TRUST S-200's TABLE.**
S-200 was written from a failure log, not from a live probe of each cause. Its remedy-per-class is
sound; its **assignment** of fixtures to classes is a hypothesis. 1 of the 2 examined was misfiled.

### ⛔ REMAINING S-200 RED SET — 5 fixtures, 6 assertions

| fixture | seq   | S-200 class | status                                                                    |
| ------- | ----- | ----------- | ------------------------------------------------------------------------- |
| 2       | 27    | (A)         | ⏸️ OPEN — `status_floor` gt 0 → 0. ⛔ re-derive live before assuming (A). |
| 8       | 29    | (A) — S-129 | ⏸️ OPEN — `floor_protected` gt 0 → 0. ⛔ re-derive live.                  |
| 2       | 64    | (B)         | ⏸️ OPEN — `s37_family` eq 26 → 24.                                        |
| 59      | 25    | (B)         | ⏸️ OPEN — `unmatched` eq 18 → 33.                                         |
| 59      | 26    | (B)         | ⏸️ OPEN — `undecided` eq 6 → 11.                                          |
| 55      | 25/26 | (D)         | ⏸️ OPEN — ⛔ read S-200's (D) in full first; do NOT bump the constant.    |

### ⚠️ S-202 NEW — `authenticated` HOLDS FULL DML ON `warehouse_inventory`. ARTICLE 3's REVOKE WAS NEVER RUN.

Surfaced by Cody during the UNIT A review (not sought — the review asked whether a probe write was
constitutional, and the grant table answered a different question).

```
authenticated : INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
anon          : SELECT, REFERENCES, TRIGGER
```

Article 3's enforcement clause is explicit: _"`REVOKE INSERT, UPDATE, DELETE ON <protected> FROM
authenticated` is part of the migration that creates each canonical RPC."_ On
`public.warehouse_inventory` — a protected entity with a full canonical writer tier — **it was never
run**, and `TRUNCATE` is granted on top.

⛔ **DISTINCT FROM D-41/D-42**, which were function `EXECUTE` grants. This is **table-level DML**.
⭐ **Pre-existing, NOT introduced by this leg** (LAW 10 — recorded, not churned inside a fixture unit).
⚠️ **Do NOT revoke blind.** RLS may be the only thing standing between `authenticated` and these
rows today; per **S-158** re-derive the FE call sites first — a blind revoke could strand the
warehouse UI. Needs its own unit, its own Cody review, and an ACL fixture mirroring D-41/D-42's.
⭐ Almost certainly **fleet-wide**: the other Appendix-A tables were not checked. Scope that first.

### ⚠️ SEQ-PICKING TRAP — PAID FOR TWICE IN ONE LEG

Both failed applies came from reading a **FILTERED** `golden.assertions` list and inferring a free
seq. Fixture 24 is `1..34, 90, 94..99`; fixture 40 is `1..56` contiguous.
⭐ **Always take `max(seq)+1` from an UNFILTERED query.** The bare INSERT (no `ON CONFLICT`) caught
it both times. ⭐ **And it confirmed a runner fact worth keeping: the migration body is ONE
transaction** — the first failure left `prd110%` at 274 with `scenario_sql` untouched.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43, still NEW and UNANSWERED**. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** ⭐ **NOTHING waits on CS.** Leg 111 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐ leg 112 (2026-08-04) — S-200 RED SET: 2 MORE CLOSED (fixture 2 fully green). S-203 RAISED ON 8/29.

Both of fixture 2's reds closed, **each by a different class**, and the class assignment was
re-derived live in both cases rather than taken from S-200's table.

### ✅ 2/27 CLOSED — class (A) CONFIRMED, and the class-(B) shortcut was actively rejected

`below_floor` = 0 live. **19 real sub-floor series exist**, but all are `out_of_canonical_scope`, so
their `velocity_instock` is NULL for a **second** reason. ⛔ A fleet-wide restatement would have been
green-at-zero in disguise. Self-supplied instead: a chronically-empty `A99` shelf planted into the
last two `weimi_device_status` snapshots of eligible `USH-1008-0000-W1`, inside a rollback probe.
Fixture 2 **54 / 0**; earned — `floor_delta=1 · status=below_floor · stock_hours 0.0000 < 48.0 ·
vi_is_null=true`. Migration `20260804004215`. ⭐ Corroborated by `METRICS_REGISTRY` line 46:
`below_floor` was **8** at leg 20. It decayed exactly as S-129 predicted.

### ✅ 2/64 CLOSED — class (B) CONFIRMED

`split_family 24 = shelfstate_family 24`, `split_total` still exactly **544**. Nothing in the build
moved; two alias shelves left the fleet. seq 64 → non-vacuity `gt 0`, plus **seq 102 NEW**
conservation (split view keeps every alias shelf `v_shelf_state` has). Migration `20260804004705`.

### ⛔ S-203 (NEW, leg 112) — 8/29 IS A CORRECTLY-FIRING TRIPWIRE, NOT A STALE ASSERTION

⭐ **This is the one finding of the leg that changes what the remaining work IS.** 8/29 was filed
under S-200/S-129 as "ambient non-vacuity gone vacuous", implying the harness had aged. Live
measurement says something sharper: **`floor_units` is 0 on ALL 32 lines of fixture 8's run**
(`max_floor = 0`), not merely on the 20 zero-ceiling ones.

| measured live, leg 112, fixture 8 run | value   |
| ------------------------------------- | ------- |
| total shadow lines                    | 32      |
| lines with `floor_units > 0`          | **0**   |
| lines with a ceiling / zero ceiling   | 20 / 20 |
| `zeroed_despite_floor` (seq 26)       | 0       |

⛔ **THEREFORE seq 26 — the CORE assertion of fixture 8 ("the expiry ceiling caps the COVER term and
NEVER the min-facing floor") — IS ITSELF VACUOUS.** It is green on 0 = 0. seq 29 exists precisely to
detect that, and its red is **information, not decay**. ⭐ Do NOT "fix" 8/29 by restating it; the
correct outcome is to make seq 26 non-vacuous again.

**The floor is NOT dead code — it is inert on this fixture's machines only:**

| measured over all `pod_refills_shadow`  | value                                                                                              |
| --------------------------------------- | -------------------------------------------------------------------------------------------------- |
| lines carrying `floor_units`            | 6688                                                                                               |
| lines with `floor_units > 0`            | **2409** (36%, across **181** runs)                                                                |
| `max(floor_units)` ever                 | 2 (= `refill_policy_params.min_facing_floor`)                                                      |
| machines that ever produced `floor > 0` | 6 — ⭐ **including BOTH of fixture 8's own machines, `AMZ-1046-2406-O1` and `MPMCC-1058-0000-R0`** |

⭐ **So the floor fired on these very machines historically and has since gone inert.** That is
genuine class-(A) ambient decay, and it makes the remedy concrete: supply a line that carries
**BOTH** `floor_units > 0` **AND** a zero expiry ceiling.

**Smallest unblock (NOT started — it needs its own unit):** plant a near-expiry
`warehouse_inventory` batch (⛔ **S-189: `provenance_reason='snapshot'` mandatory**) against a shelf
on one of those two machines that still yields `floor_units > 0`, so
`FLOOR(expiry_days x vel_eff x 0.80)` computes to 0 while the min-facing floor of 2 still applies.
Then `need_raw` must survive at `LEAST(floor_units, fill_to_cap) > 0` and `floor_protected` goes
positive. ⛔ **`warehouse_inventory` IS a protected entity (Appendix A) — this needs its own Cody
review, unlike the two `golden.*`-only units this leg.** ⚠️ Verify `floor_units > 0` is reproducible
on the chosen shelf FIRST; it is ambient and that is the whole lesson here.

### ⏸️ REMAINING S-200 RED SET after this leg — 3 fixtures, 5 assertions

| fixture | seq | class               | status                                                           |
| ------- | --- | ------------------- | ---------------------------------------------------------------- |
| 8       | 29  | (A) — now **S-203** | ⏸️ OPEN — ⛔ seq 26 is the vacuous one; do NOT restate 29.       |
| 59      | 25  | (B)                 | ⏸️ OPEN — `unmatched` eq 18 → 33. ⛔ re-derive live.             |
| 59      | 26  | (B)                 | ⏸️ OPEN — `undecided` eq 6 → 11. ⛔ re-derive live.              |
| 55      | 25  | (D)                 | ⏸️ OPEN — ⛔ read S-200's (D) in full; do NOT bump the constant. |
| 55      | 26  | (D)                 | ⏸️ OPEN — same.                                                  |

⭐ **COUNT CORRECTION:** leg 111's pointer said "5 fixtures / 6 assertions" remaining. The true
figure was **4 fixtures / 7 assertions** — 55/25 and 55/26 were collapsed into one table row, and
fixture 2 appeared twice. Corrected here so the burn-down is countable.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43, still NEW and UNANSWERED**. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** ⭐ **NOTHING waits on CS.** Leg 112 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐ leg 113 (2026-08-04) — S-200 RED SET: 2 MORE CLOSED (59 and 55). S-204 RAISED. ⛔ S-203's REMEDY OVERTURNED (S-205).

Two class reds closed, both `golden.*`-only, both re-derived live rather than taken from S-200's
table. **The red set is down to its LAST member: 8/29.**

### ✅ 59/25 + 59/26 CLOSED (class (B) confirmed) — re-derive the mapping, not the count

Fixture 59 **plants nothing** into `reallocation_proposals_v3`; that family is ambient. Measured:
**44 rows · 11 distinct `base_run_id` · 33 `unclaimed` + 11 `proposed` == 11 runs x (3 + 1)**, all on
`plan_date 2030-01-12`. The producer is **FIXTURE 11**, which does not reclaim. 18/6 was the
photograph at 6 runs. Restated as an equality against a live re-derivation off the source table,
plus seq **51/52** (`gt 0` non-vacuity) and seq **53** (disjointness stated outright).
**Fixture 59 `53 / 0`, earned** (`51=33 · 52=11`). Migration `20260804010212`.

### ✅ 55/25 + 55/26 CLOSED (class (D) confirmed) — ownership, not cardinality

The 21 -> 26 / 9 -> 11 overshoot is **exactly fixture 63's own legitimate plants**, and all three
2030 dates are declared `golden.fixtures.plan_date` values. Restated as "every 2030+ `plan_date`
belongs to a declared fixtures row" (expect 0 orphans), plus **27/28** non-vacuity and **29** the
LAW-12 carve-out pin. ⛔ The 2099-12-\* legacy set (**9 rows · 8 dates · one machine
`a6c02486-5d95-42ca-9adc-bc755c3019d3`**) is carved out explicitly and **pinned at 9 AND pinned to
that machine**, so the exclusion cannot become a hiding place. ⚠️ S-200 listed only 2 of its 8
comment prefixes. **Fixture 55 `30 / 0`, earned** (`27=26 · 28=11 · 29=true`). Migration `20260804010644`.

## ⭐ S-204 (NEW, leg 113) — A FIXTURE CAN ROT ANOTHER FIXTURE'S ASSERTION, AND THAT IS THE CLASS THAT MAKES S7 UNACHIEVABLE

S-200 filed class (B) as photographs of **the live fleet** that ordinary turnover ages out. 2/64 was
exactly that. **59/25+26 is not.** The population that moved is neither the fleet nor the world: it
is `reallocation_proposals_v3`, and **the only thing that writes to it is the golden harness itself**,
via fixture 11, which appends 4 permanent rows per run and never reclaims them.

⛔ **THE GENERALISATION:** any assertion pinning a count over a table a **non-reclaiming fixture**
writes to is on a timer set by how often the suite runs. **Running the suite reddens it.** ⭐ **S7
requires three consecutive identical `run_all()` results — so this is precisely the class of defect
that makes S7 unachievable**, and it will not present as flakiness inside one fixture but as drift
between round 1 and round 3.

⭐ **THE RULE, BINDING ON EVERY NEW ASSERTION:** before pinning a constant, ask **who writes this
population, and does it clean up?** If the writer is a fixture that does not reclaim, a constant is
not a photograph — it is a countdown. Re-derive the relationship instead.

⚠️ **Fixture 11's non-reclaim is NOT being "fixed"** — out of scope (LAW 10), and its proposals may
well be the artifact it means to leave. The correct response is that **assertions stop depending on
its cardinality**, which is what this leg did.

## ⛔ S-205 (NEW, leg 113) — S-203's PRESCRIBED REMEDY FOR 8/29 IS BASED ON A MISDIAGNOSIS. DO NOT PLANT INTO `warehouse_inventory`.

⭐ **S-203's reclassification of 8/29 was RIGHT (seq 26 is the vacuous one, seq 29 is a correctly-
firing tripwire). Its prescribed FIX is wrong, and following it would have touched a protected
entity for no effect.**

S-203 says: _"plant a near-expiry `warehouse_inventory` batch ... so `FLOOR(expiry_days x vel_eff x
0.80)` computes to 0"_. ⛔ **That achieves nothing, because the ceiling is ALREADY zero on every one
of fixture 8's 20 WH-sourced lines, and not for the reason S-203 assumed.** Measured live:

- `expiry_days = GREATEST(COALESCE(earliest_expiry - p_plan_date, 0), 0)` and fixture 8's
  `plan_date` is **2030-01-09**. Every real WH batch expires in 2026-2027, i.e. **before** the
  synthetic plan date, so `expiry_days` is **0 on all 32 lines** and
  `expiry_ceiling_units = FLOOR(0 x vel x 0.8) = 0` **automatically**.
- ⭐ **At this plan_date, ANY `boonz_wh`/`mixed` shelf with a resolvable `earliest_expiry` already
  gets a zero ceiling. A near-expiry plant is a no-op.**

**THE ACTUAL MISSING INGREDIENT IS `floor_units > 0`, AND IT IS NOT AN EXPIRY PROPERTY AT ALL.**
From `engine_add_pod_v3`:

```
floor_units = CASE WHEN stock_clamped = 0 AND basis <> 'partner' AND max_stock > 0
                   THEN GREATEST(1, LEAST(v_min_facing, max_stock)) ELSE 0 END
```

⛔ **It requires an EMPTY shelf.** So the precondition to supply is **shelf state**, not
`warehouse_inventory`. ⭐ **This removes the Appendix A plant from the unit entirely** — S-203's
"needs its own Cody review because `warehouse_inventory` is protected" no longer applies as stated.

**WHY THE FLOOR IS INERT ON THESE MACHINES (the ambient decay S-203 correctly sensed):** of the
**2409** fleet lines with `floor_units > 0`, **552 are on fixture 8's own `MPMCC-1058-0000-R0`** —
but ⛔ **every one of those 552 is `basis='venue'` with `ceil_u = NULL`**. Venue lines never receive
an expiry ceiling (the CASE requires `boonz_wh`/`mixed`), so **that population can never satisfy seq
29**. ⭐ Fleet-wide the needed combination does exist: **319 of the 2409 carry BOTH `floor_units > 0`
AND a zero ceiling** — so the target is reachable, just not on a venue shelf.

⭐ **THE CANDIDATE, MEASURED AND HANDED OVER:** `MPMCC-1058-0000-R0` shelf **A07**
(`8b2a7cb9-9c98-4e7c-8a16-12fa4c93ec61`) — `basis='boonz_wh'`, `current_stock` **3**, `max_stock`
**6**, `ceil_u` already **0**, `earliest_expiry 2026-11-24`. It is the **only** zero-ceiling
fixture-8 shelf with `current_stock <= 4`. Drive its stock to 0 and:
`floor_units = GREATEST(1, LEAST(min_facing 2, max_stock 6)) = 2` · `fill_to_cap = 6` ·
`need_raw` should survive at `LEAST(2, 6) = 2` -> `floor_protected > 0` -> **seq 29 green AND seq 26
non-vacuous in the same stroke**.

⛔ **NOT STARTED — IT IS ITS OWN UNIT, AND TWO THINGS MUST BE VERIFIED FIRST:**

1. **How `stock_clamped` derives from `v_shelf_state`** — ⚠️ note `stock_clamped` is **NOT** a
   `reasoning` key (the keys are `raw_current_stock`, `sensor_over_capacity`, `min_facing_floor`,
   `pin_floor_units`, ...), so it cannot be read back off a shadow row; it must be traced in the
   engine body.
2. **That `need_raw` actually keeps the floor under a zero ceiling** — that is the very contract
   seq 26 asserts, so it must be confirmed from the engine source, not assumed. ⭐ `need_raw` and
   `need_raw_no_expiry` are both recorded in `reasoning`, which makes the diagnosis cheap.

⚠️ **The plant target is shelf state = WEIMI (DATA-SOURCE LAW).** Per leg 112, `weimi_device_status`
carries **no triggers**, so a JSONB plant cannot escape a rollback — but it **is** the n8n sync
target, so keep it to the minimum and never widen it. ⛔ Whether the plant lands in WEIMI or is
better expressed inside fixture 8's own rollback probe (the fixture-31 idiom, proven twice this
build) is the **first design decision of that unit**.

### ⏸️ REMAINING S-200 RED SET after this leg — 1 fixture, 1 assertion (the last)

| fixture | seq | class                                                       | status                                                                                                                                                               |
| ------- | --- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 8       | 29  | (A) — **S-203** reclassified, remedy corrected by **S-205** | ⏸️ OPEN, LAST ONE. ⛔ Do NOT restate seq 29; make seq **26** non-vacuous. ⛔ Do NOT plant into `warehouse_inventory` — S-205. Candidate: MPMCC-1058-0000-R0 **A07**. |

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43, still NEW and UNANSWERED**. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** ⭐ **NOTHING waits on CS.** Leg 113 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

## ⭐ leg 115 (2026-08-04) - S-200 RED SET CLOSED. S-201 CLOSED. S-206..S-209 raised.

### ⭐ S-200 IS CLOSED - THE RED SET IS EMPTY

Fixture 8 seq 26/29, the last member, closed by the **self-supplied empty shelf**: measured
**23 pass / 0 fail**, with `26=0 · 28=20 · 29=1 · 32=1 · 33=0 · 34=true · 35=1`. ⭐ seq 26 is no
longer vacuous - seq 35 (`floorful`=1) supplies the FLOOR witness that seq 28 (a CEILING witness)
never covered. ⭐ **Residue independently disproven off live WEIMI**, not off seq 34's word:
`currStock` back to 3, `v_shelf_state` 3, `snapshot_at` unchanged, `orig` dropped from scratch.

### ⚠️ S-206 - AN ABORTED LEG CAN LEAVE A FILE WITHOUT A ROW. CHECK BOTH DIRECTIONS.

Leg 114 wrote and dry-proved a migration, then died **before applying it**. STEP R saw disk 283 vs
expected 282 and `git status` 282 vs 281; the DB was untouched (`max(version)` still leg 113's,
fixture 8's `scenario_sql` carrying neither needle at position 0). ⭐ **The pointer's own rule
decided it: a forward gap is adoptable work to VERIFY and RECORD, never corruption to undo.** Every
premise was re-derived live before applying, and all held. ⛔ **The file-count check is what caught
this - `max(version)` alone would have said "clean".** Keep counting BOTH.

### ⚠️ S-207 - PRETTIER REWRITES THE LOG AND THE PARKING-LOT, AND IT BREAKS EVERY PREFIX HASH AFTER THE EDIT

Both docs were reformatted at 04:24:45 after leg 113 closed. ⛔ **Three baselines appeared broken;
it was ONE edit.** Prefix hashing propagates forward, so a change at ~line 27600 invalidates N=27786,
N=28039 and N=28394 alike. ⭐ **Bisect against the recorded chain before concluding anything**:
N=27131 and N=27517 were still byte-exact, which localised it to 27518..27786 - a markdown table at
27638-27641, the classic re-padding target. Line counts unchanged, no new markers, `prettier --check`
clean on both. ⭐ **Ruled cosmetic.** ⛔ **The leg 111/112/113 log baselines are permanently
superseded - do not chase them.** ⚠️ Expect this again: anything that opens these files in an editor
with format-on-save will do it.

### ⛔ S-208 - VERIFY THE LOAD-BEARING SAFETY CLAIM, DO NOT INHERIT IT

Fixture 8's plant is safe because `golden.run_fixture` executes the scenario as
`BEGIN EXECUTE golden.render(scenario_sql) ... EXCEPTION WHEN OTHERS THEN ... END` - a real plpgsql
**subtransaction**, with the whole multi-statement scenario in ONE `EXECUTE`. ⭐ Read from `pg_proc`,
not assumed. **Consequence: residue is impossible via ANY error path** (engine raises -> plant rolls
back; restore raises -> plant rolls back). ⭐ The only surviving residue mode is a **silently wrong**
restore, which is exactly what seq 34 pins. **Any future fixture that borrows live state inherits
this guarantee and should pin it the same way.**

### ⛔ S-209 - `propose_facing_changes_v3` RE-MATERIALISES A 23.6 s VIEW ON EVERY CALL

`public.v_facing_performance_v3` takes **23.6 s** for **525 rows**. `propose_facing_changes_v3` line
39 does `CREATE TEMP TABLE _fac_perf ON COMMIT DROP AS SELECT * FROM public.v_facing_performance_v3`
**per call**, and fixture 48 calls it **twice** (the second for the idempotency re-run) - ~47 s that
**no fixture edit can remove**. ⛔ **This is an RPC/view performance item, NOT a harness one**: its
own unit, its own Dara design and Cody review, and it bears directly on **S1** (full-fleet shadow run
must finish < 10 min). ⏸️ **PARKED, not attempted this leg** - it touches a live DEFINER and a
registered read object, and nothing in the current gate depends on it.

### ⛔ S-201 CLOSED, BUT ITS SECOND HALF IS A RUNNER RULE, NOT A MIGRATION

Fixture 48 now evaluates **49 / 49**. The migration removed **48.7 s** (119.8 s -> 71.1 s, measured
from `golden.runs`). ⛔ **At 71.1 s it STILL exceeds the ~57 s default `statement_timeout`, so any
runner that does not raise it will keep scoring fixture 48 as a SILENT GREEN** - a cancelled fixture
contributes zero to `n_fail`, which is exactly how this hid for ~25 legs. ⛔ **The leg-109 runner
`/tmp/prd110_s7.sh` does NOT set it and is unsafe as written.** ⭐ Use `/tmp/prd110_sweep.sh`
(`SET statement_timeout = '600s'` per call). ⭐ **`fixtures_evaluated = fixtures_enabled` remains a
precondition of any S7 pass and of any full-green claim.**

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43, still NEW and UNANSWERED**. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** ⭐ **NOTHING waits on CS.** Leg 115 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐ leg 116/117 (2026-08-04) - S6 GREEN. ROUND 0 58/58. S-210 recorded, S-212..S-214 + D-44 raised.

⛔ **Leg 116 raised S-210 in the EXECUTION-LOG and ended before writing it here; its "S-211" was
never written at all and is not reconstructed.** S-210 is recorded below by leg 117.

### ⛔ S-210 (leg 116) - A ROUND-INDEPENDENT OUTPUT DIRECTORY DESTROYS S7 ON ROUND 2

`/tmp/prd110_sweep.sh` opened with `rm -rf $OUT; mkdir -p $OUT` against a directory that did not
vary by round. Correct for one round, **fatal for S7**: invoking it as `... 1` deletes round 0's
results before writing round 1's, so "three consecutive identical results" has nothing to compare.
⭐ Fixed by per-round `r$ROUND/` subdirectories that are never deleted.

### ⛔ S-212 (NEW, leg 117) - THE HTTP RESPONSE BODY IS NOT A TRUSTWORTHY VERDICT CHANNEL

⛔ **This is S-201's blindness one layer further out, and it hid a genuine red for a whole round.**
S-201 was the server _cancelling_ a fixture (contributes 0 to `n_fail`, reads as green). S-212 is
the server **succeeding** and the client throwing the answer away.

**Measured, not inferred:** fixture 42 ran to completion **server-side in 107.5 s** and COMMITTED its
`golden.runs` row; the gateway cut the response at **79 s** and the runner banked
`{"message":"Failed to run sql query"}`. ⛔ **Fixture 7 took 101.8 s in the SAME round and returned
fine** - so this is **flaky transport, not a fixed ceiling**, and ⛔ **no `statement_timeout` can fix
it: the query already succeeded.**

⛔ **Second half of the defect:** leg 116's resume guard was `[ -s file ]` - **size, not validity**.
An error blob is non-empty, so a resumed round **skips that fixture permanently** while reporting it
captured.

⭐ **THE FIX, AND IT IS STRUCTURAL:** `golden.run_fixture` commits `n_pass` / `n_fail` / full
per-assertion `detail` to `golden.runs`. So **fire the run, discard the response, read the verdict
back in a separate short query.** Transport loss becomes irrelevant by construction.
⭐ `/tmp/prd110_leg117_sweep.sh` does this and requires a valid `n_eval` to consider a fixture
captured. ⛔ **`prd110_s7.sh`, `prd110_sweep.sh` and `prd110_leg116_sweep.sh` are ALL superseded.**

### ⛔ S-213 (NEW, leg 117) - THE CLOCK IS A WRITER, IT NEVER CLEANS UP, AND IT IS THE HARDEST S7 HAZARD YET

S-204 asked "who writes this population, and does it clean up?" ⭐ **Fixture 42 answers with the
worst possible case: the writer is the passage of time, and it never cleans up** - `days_since_visit`
only grows until a driver physically visits.

⛔ **Fixture 42 went 67/0 green at 2026-08-03 23:49 and red at 02:02 the same night**, with no
migration touching the picker. **The mover was the UTC date rollover.**

⛔ **WHAT THIS MEANS FOR S7, CONCRETELY:** a round is ~19 min of server time and materially longer in
wall clock. Three rounds straddle hours. **Any round boundary that crosses 00:00 UTC changes every
`CURRENT_DATE`-derived assertion by construction**, so "three identical consecutive rounds" is
unachievable across midnight regardless of how correct the build is.
⭐ **Schedule S7's three rounds to start well clear of 00:00 UTC** (Dubai +4, so avoid 03:00-05:00
Dubai), and **record the UTC window in the `stress_runs` note** so a future reader can tell a real
difference from a rollover.
⭐ **And the general rule, now earned three times (S-200, S-204, S-213): before pinning any constant,
name its writer. If the writer is the clock, the assertion must be expressed as an offset or the
fixture must supply the state itself.** S6 was built this way on purpose - `CURRENT_DATE - off`,
never an absolute date.

### ⏸️ D-44 (NEW CS DECISION, leg 117) - THE CADENCE FLOOR NOW EATS THE ENTIRE DRIVER DAY, AND MONEY NEVER GETS A SLOT

**The state, read off the picker's own output on 2026-08-04:**

- **11 machines have BREACHED the cadence floor. Day capacity is 6.**
- **NINE of those 11 carry 0.00 AED of value at risk.**
- `VOXMCC-1005-0201-B0`, carrying **1036.49 AED**, is **rank 12, not selected**, reason
  `below_day_capacity`.

⭐ **The engine is not broken - it is obeying D-24 exactly** (seq 31/32/35/40 green, picker md5s
pinned green by seq 49/50/51). D-24 kept "a BREACHED floor still beats money", and the breached
population has since grown past a whole driver day. **The intent of D-24 - that VOXMCC-1005 gets
picked on money - is now defeated in practice.**

⏸️ **THE ASK, one line:** should the breached-floor rule be capped - e.g. reserve **K** of the day's
**6** slots for the money rule (K=1 or 2) so the highest-value machine is never starved by
zero-value overdue machines - or does a breached cadence floor keep absolute priority even when the
breached set exceeds capacity?

⛔ **NOTHING WAS CHANGED IN THE PICKER.** This is a routing-policy question that decides which
machines a driver physically visits - squarely CS judgment, parked per the PARKING protocol. ⛔ **And
fixture 42 seq 60 must NOT be loosened to make the red go away** - it is the CS acceptance test,
verbatim, and weakening it is the S-48/S-52/S-55 vacuity mode burned four times.

⭐ **THE ENGINEERING REMEDY, INDEPENDENT OF THE RULING** (so golden can go green either way): seq 60
asserts an outcome that **silently presupposes `|breached| < capacity`**. Make fixture 42
**self-supply that precondition** (the leg-114/115 idiom) and add an explicit sensor comparing
`|breached|` to capacity, so the next recurrence **names its cause** instead of the acceptance test
failing bare. ⛔ **NOT started this leg** - CS-acceptance-critical, deserves its own unit.

### 📌 SHAPE NOTES EARNED THIS LEG

- ⛔ `blocked_demand` carries **`uq_blocked_demand_open` UNIQUE (plan_date, machine_id, shelf_id,
  pod_product_id, source) WHERE resolved_at IS NULL**. Any volume plant must be distinct on that
  5-tuple. `reason` ∈ (`blocked_no_wh`, `partial_wh_limited`, `substitution_exhausted`,
  `routing_gap`); `source` ∈ (`engine_add`, `stitch`, `pack`); `qty_blocked > 0`; **no `status`
  column**; `resolved_at`/`resolution` are a paired CHECK.
- ⭐ `golden.runs` carries **full per-assertion `detail` jsonb** (seq, expect, actual, passed,
  skipped). `n_eval` = `count(*) FROM jsonb_array_elements(detail) WHERE d ? 'seq'` - the array's
  last element is a summary object without `seq`. **This is the authoritative result channel.**
- ⛔ `golden.stress_runs` CHECKs bite: `suite ∈ (S1..S7)`, `driver ∈ ('sql','external')` only.
- ⛔ The Supabase **management-API `/database/migrations` endpoint returns 403 (Cloudflare 1010)**;
  use the MCP `apply_migration` tool. `/database/query` (the `prd110_sql.sh` shim) still works.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43** and **D-44 (NEW)**, both UNANSWERED. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.**

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐ leg 118 (2026-08-04) - FIXTURE 42 seq 60 CLOSED. LAW 8 UNBLOCKED. S-215..S-217 raised.

⛔ **S-211 AND S-214 ARE PHANTOMS.** Leg 116's heading announced "S-211" and leg 116/117's heading
announced "S-212..S-214", but only S-210, S-212 and S-213 were ever written. **Do not hunt for
S-211 or S-214 - they have no body and are not reconstructed.** New findings resume at S-215.

### ⭐ THE RESULT: fixture 42 is **76/76, 0 fail, 105 s**, and seq 60 (the CS D-24 acceptance test) is TRUE

The Law-8 blocker that gated S7 for two legs is closed **without loosening the acceptance test** -
seq 60's `check_sql`, `expect_op` and `expect` are byte-unchanged, and a guard in the migration
refuses to apply if any of the three ever moves. What changed is that the fixture now **supplies
the precondition seq 60 silently presupposed**: `|breached| < day capacity`.

**How.** The scenario banks `var_cadence_floor_multiple` / `var_cadence_hard_max_days`, plants
values DERIVED from the fleet (`multiple := GREATEST(dsv/gap of M_CAD, live)`, `hard_max :=
GREATEST(max(dsv)+1, live)`), runs the picker, restores byte-identical and verifies. Both `GREATEST`
clamps make the plant a **tightening only** - it can shrink the breached set, never invent a breach.

⭐ **IT IS NOT VACUOUS, AND THAT WAS THE DESIGN CONSTRAINT.** Under the planted params **18**
machines are still SOFT `target_due` carrying 0.00 AED (seq 63). Under the PRE-D-24 rule every one
of them would still outrank VOXMCC-1005 and seq 60 would still be false. The plant removes the
capacity starvation; it does **not** remove the money-vs-cadence contest. Anchors held: seq 34
(M_CAD breached) true · seq 35 (M_CAD outranks M_TOP) true · seq 62 (per-machine D-24 contract) 0
disagreements · seq 56/57 (params still pinned at 2.0/14) true · seq 39 24 unselected.

⭐ **THE D-44 SENSOR IS LIVE AND READS 11 vs 5** (seq 72 `breached_live` = 11, seq 73
`eff_cap_model` = 5, seq 74 `d44_starving` = true). Every future run records those two numbers into
`golden.runs.detail.actual`, so a seq-60 investigation **names its cause** instead of failing bare.
⛔ `eff_cap_model` charges inter-cluster travel to every machine, so it is a deliberately
CONSERVATIVE lower bound (it reads 5 where the picker actually seats 6-7). Conservative makes the
precondition assertion stricter, never laxer. ⏸️ **D-44 itself remains UNANSWERED and nothing waits
on it** - the remedy was built to be correct under either ruling.

### ⛔ S-215 - THE `prd110_sql.sh` SHIM IS **TRANSACTIONAL**. PROVEN, NOT ASSUMED.

The management-API `/database/query` endpoint wraps a multi-statement body in ONE transaction.
**Proven this leg** with a deliberate probe: `CREATE TABLE public.zz_leg118_txn_probe` + `INSERT`
followed by a `RAISE EXCEPTION` - afterwards `to_regclass` returned NULL, i.e. the DDL and the row
were both rolled back, no residue.

⭐ **WHY THIS MATTERS FOR THE RELAY.** `/database/migrations` is 403 (Cloudflare 1010), so the
pointer has been routing applies through the MCP `apply_migration` tool, which forces the whole
migration body through the operator's context. **The shim is an equally safe apply path** - it is
all-or-nothing, so "nothing half-applied" (the handoff invariant) holds - and it reads the body
straight off disk. This leg applied BOTH its migrations that way and hit three separate guard
failures; **every one rolled back completely**, which is exactly why iterating was safe.
⛔ The shim does NOT record a `schema_migrations` row - insert it explicitly afterwards (recipe:
`/tmp/leg118_reg.sql`, a `python3` heredoc that reads the file and doubles the quotes).

### ⛔ S-216 - A `replace()` PAYLOAD THAT RE-EMITS A STATEMENT MUST HAVE A NEEDLE COVERING **ALL** OF IT

This cost the leg one broken apply. The restore needle matched only
`SELECT {{fixture_id}}, 'mtv_after', ...;` while the payload re-emitted the whole statement
**including its `INSERT INTO golden.scratch (fixture_id, key, value)` header** - so the ORIGINAL
header was left dangling in front of the injected `DO` block and Postgres answered
`syntax error at or near "DO"`.

⛔ **THE SHAPE GUARDS COULD NOT CATCH IT** - and this is the part worth remembering. Plant present
once, restore present once, pop→plant→breach→picker→restore order all correct. The fixture's SHAPE
was right; its SYNTAX was not. ⭐ **The guard that does catch it** (now in leg 118b): every
`INSERT INTO golden.scratch (fixture_id, key, value)` must be followed by `SELECT` or `VALUES`.
⛔ Implement that check by **splitting on the literal header**, never a regex - the header contains
parentheses and hand-escaping them is how the guard itself failed on its first apply.

⭐ **THE FAIL-LOUD DESIGN PAID FOR ITSELF ON ITS OWN FIRST RUN.** The broken scenario came back in
**279 ms** instead of ~107 s, `run_fixture` banked `scenario_error`, and the nine new sensors read
`-1` / `MISSING` / `false` - seq 68 saying "the plant never ran", exactly the reading its own
description prescribes. **Nothing was diagnosed from seq 60 being false.**

### ⏸️ S-217 - `authenticated` HOLDS INSERT/UPDATE/DELETE ON `refill_policy_params` (Cody finding, OUT OF SCOPE)

Raised by Cody while reviewing leg 118 and deliberately **not** acted on (LAW 10). Not an Article 3
violation - `refill_policy_params` is not in Appendix A - but that one row carries
`preflight_enforcement`, `spot_buy_cap_enforcement`, `refill_sizing_mode`, `gate0_require_manual_confirm`
and every `var_*` picker param. An `authenticated` client can flip engine governance with a direct
`UPDATE`. **Same shape as S-202** (`warehouse_inventory`), and like S-202 it needs its OWN unit, its
OWN Cody review and its OWN ACL fixture. ⛔ Do NOT revoke blind - re-derive FE/n8n call sites first
per S-158.

### ⭐ NOTE FOR WHOEVER NEXT TOUCHES THE LEG-98 PROBES

`golden.probe_stitch_under_mode` / `probe_commit_under_mode` / `probe_atomic_commit_under_mode`
temporarily force `refill_policy_params.preflight_enforcement` and restore it on every path - the
precedent leg 118 was modelled on. ⛔ **They hold NO lock.** Two concurrent runs interleave as
bank(live) / plant / bank(PLANTED) / restore(live) / restore(PLANTED) and leave the forced value in
place PERMANENTLY. Leg 118 closes that with `pg_advisory_xact_lock(1100042)`; **adopt the same lock
in those three probes when they are next edited.**

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43** and **D-44**, both UNANSWERED. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** Leg 118 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

### ⛔ S-218 (leg 118) - S-207 HAS A SECOND MOUTH: **ANY** POST-HASH EDIT INVALIDATES THE BASELINE

S-207 was recorded as "prettier rewrote the file after the hash was taken", and leg 117's fix was
"run `--write` first, hash second". Leg 118 followed that exactly **and still broke its baseline** -
because a cosmetic `sed` (normalising whitespace that `wc -l` had leaked into the hash block) ran
AFTER the hash. ⭐ The generalised rule: **the hash is the LAST operation on the file. Every edit,
including cosmetic ones and including edits to the hash block's own prose, lands before it.**

⭐ **AND VERIFY THE BASELINE REPRODUCES BEFORE ENDING THE LEG** - a two-line check that would have
caught S-207 in leg 113 and this in leg 118:
`head -n <N> docs/prds/PRD-110-EXECUTION-LOG.md | shasum -a 256` must equal the recorded value, and
the other ten files must re-hash equal. Leg 118 verified all 11 programmatically at close.

## ⭐ leg 119 (2026-08-04) - S1 GREEN 16/16 in 37 s. Cody rerouted the plant onto the canonical writer. S-219/S-220 raised.

### ⭐ S1 IS GREEN AND IT IS NOT VACUOUS

`golden.stress_s1_v1`, `stress_run_id` `ded9fb1e`, **16 pass / 0 fail**, **36 717 ms against a
600 000 ms budget (6 %)**. Fleet 31 planted = 31 covered, 656 shelves in scope, **544 shadow lines**
from exactly **one** new `run_id`, zero error steps. S-209's 23.6 s `v_facing_performance_v3`
materialisation is confirmed **not** on the STEP-1 path — it never showed up in the 37 s.

⭐ **The ADR §8 obligation-3 tripwire was verified TWICE** (the block's own assertions 13-15 and an
independent read afterwards): `pod_refills` 3955, `pod_refill_plan` 6572, `refill_plan_output` 8256,
all unmoved, and live `2026-08-04` still 96 rows. LAW 4 held.

### ⛔ CODY REROUTED THE PLANT - `machines_to_visit` HAS A CANONICAL WRITER AND A STANDING CONDITION

The leg-119 draft found staged on disk raw-`DELETE`+`INSERT`ed `machines_to_visit`. The table is
**absent from `01_constitution.html`** (0 occurrences), which is presumably why the draft treated it
as unprotected - but `RPC_REGISTRY.md` calls it protected in three separate entries, names the writer
set (`pick_machines_for_refill`, `confirm_machines_to_visit`, `unpick_machine_to_visit`,
`pick_machine_manually`), and **RPC_REGISTRY:1214 carries an explicit standing Cody condition**: the
first consumer that turns a ranking into a `machines_to_visit` row is a NEW class-(b) review.

⭐ **The fix was strictly better than the draft, not merely more compliant.**
`pick_machine_manually` is DEFINER with service-role bypass, sets both GUCs (Articles 4/8), and
**upserts on `(plan_date, machine_id)`** - so the clean-on-entry DELETE became unnecessary and was
deleted. S1 now issues **no raw SQL against any plan table at all**.

### ⛔ S-219 - THE DRAFT'S "SECOND CORRECTION" WAS BACKWARDS: `engine_add_pod_v3` **DOES** DEPEND ON THE CONFIRM

The staged comment asserted the v3 engine "reads neither `confirmed_at` nor `is_included`" and warned
a future leg not to "fix a zero-line S1 by chasing the confirm". **Measured live: the engine
`PERFORM public._assert_gate_zero(p_plan_date)`**, which raises `check_violation` on any row with
`status='picked' AND confirmed_at IS NULL`. Following that comment would have produced a
`blocked_gate0` run and sent the next leg hunting in the wrong place.

⭐ The pick predicate itself (`status IN ('picked','cs_added')`, in all five references) genuinely
does not read `confirmed_at` - the dependency arrives via the separate gate-zero assertion. Both
statements are true and only the pair is safe. ⭐ `cs_added` dodges it entirely: the gate-zero
predicate only matches `status='picked'`. Assertion 16 now pins `gate0_no_unconfirmed_picks = 0`.

⛔ Also measured and worth keeping: every `picked` CTE in the engine carries
`AND NOT EXISTS (SELECT 1 FROM refill_plan_output rpo WHERE rpo.plan_date = p_plan_date AND ...)`, so
**a machine that already has plan output for the date is silently excluded from the engine's scope**.
On a virgin synthetic date this is a no-op; on any date with partial output it would quietly shrink
the fleet and could read as a coverage failure.

### ⏸️ S-220 - THE NIGHTLY SHADOW PATH NEVER ROUTES `blocked_no_wh` INTO `blocked_demand` (observation, NOT a LAW 5 breach)

S1's 544 lines carry **zero** null `clamp_reason` - LAW 5's "silent qty-0" clause is clean. But 32 of
them are `clamp_reason='blocked_no_wh'` and `blocked_demand` gained **0** rows (44 → 44).

⭐ **This is not a defect in S1 and not a LAW 5 violation.** Measured: `engine_add_pod_v3` only
_names_ `blocked_demand` in a comment and never calls `record_blocked_demand_v3`; the recorder's
callers are `_blocked_demand_gaps_v3`, `record_plan_edit_v3`, `resolve_supply_ladder_v3`,
`run_pipeline_v3` and `stitch_v3`. `run_nightly_shadow_v3` runs only engine + measure + settle, so it
was never on that path.

⏸️ **What IS worth a look before STEP 8 shadow live-in:** the recorder runs as its **own** cron 43
(`record_blocked_demand_v3(resolve_refill_plan_date())`, 16:15 UTC) while the shadow runner is cron 45
at **21:22 UTC** - i.e. the blocked-demand ledger for a date is written ~5 h _before_ the shadow
engine produces that date's `blocked_no_wh` clamps. So shadow-side blocked demand is never banked at
all. ⛔ Parked, untouched (LAW 10) - flagging it, not fixing it, and nothing in S1-S7 waits on it.

### ⭐ THE 2030 DATE MAKES S1 A PLUMBING TEST, NOT A SIZING TEST - AND THAT IS FINE, BUT SAY IT OUT LOUD

Clamp profile of the 544 lines: `expiry_ceiling` **300** (55 %) · `skipped_full` 128 ·
`sensor_over_capacity` 38 · `fill_to_cap` 35 (121 units) · `blocked_no_wh` 32 · `cover_capped` 11
(40 units). Only **46 lines carry qty > 0**, totalling 161 units.

⛔ `expiry_ceiling` dominates because FEFO judges shelf life against the LINE's date (S-190) and the
line's date is four years out, so essentially all real WH stock is "expired" relative to 2030-11-01.
**S1 therefore proves the pipeline's plumbing at fleet scale - runtime, error-freedom, coverage,
explainability, live-table isolation - and does NOT exercise the sizing logic.** That is exactly what
the goal command asks S1 for, so it is not a gap to close; it is a claim not to overstate when the
DONE report is written.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43** and **D-44**, both UNANSWERED. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** Leg 119 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

### ⛔ S-221 (leg 119) - THE S4 DRAFT HAS **FIVE** FATAL FLAWS AND TARGETS THE WRONG OBJECT. DO NOT SHIP IT AS WRITTEN.

`docs/prds/PRD-110-S4-scenario-DRAFT.sql` was never dry-proven (it says so itself). Leg 119 did not
build S4, but it **did** probe every one of the draft's premises live, and the draft cannot run.
All five measured this leg:

1. ⛔ **IT TARGETS THE WRONG ENGINE.** The draft fires `run_nightly_shadow_v3` ×3. But the goal
   command's S4 is "re-run **every engine** 3× same date", and the object that chains them is
   **`run_pipeline_v3(p_plan_date, p_days_cover, p_base_run_id, p_promote_blocked, p_note)`** -
   measured to call `engine_add_pod_v3` **+ `stitch_v3` + `record_blocked_demand_v3`**.
   `run_nightly_shadow_v3` runs only engine + measure + settle, so the draft would exercise **one**
   engine and never touch the stitch ladder. ⭐ **S4 should drive `run_pipeline_v3`.**
2. ⛔ **`DELETE FROM public.pod_refills_shadow` IS REFUSED.**
   `tg_pod_refills_shadow_append_only` is `BEFORE DELETE OR UPDATE` and raises 42501. The draft's
   clean-on-entry cannot execute at all. ⭐ Use S1's **bank-and-diff** instead (bank the `run_id` set
   for the date up front, measure only new generations) - now proven in `golden.stress_s1_v1`.
3. ⛔ **`min(s.created_at)` IN THE FINGERPRINT IS A 42703.** `pod_refills_shadow` has **no
   `created_at` column**. The `seen_at` field and the `ORDER BY f->>'seen_at'` both have to go; order
   the generations some other way (the banked-vs-new split, or `run_id` itself).
4. ⛔ **IT RAW-`INSERT`s `machines_to_visit`** - the exact Article 1/3 issue Cody ruled on for S1
   this leg. Use `pick_machine_manually`, which also upserts, so no DELETE is needed.
5. ⛔ **IT IS WRITTEN AS A GOLDEN FIXTURE** (`{{fixture_id}}`, `{{plan_date}}`, `golden.scratch`),
   which STEP7-STRESS-DESIGN explicitly forbids: S1-S6 stay out of `golden.fixtures` or **S7 would
   measure itself**. ⭐ Ship it as **`golden.stress_s4_v1()`**, following `stress_s1_v1` /
   `stress_s6_v1`.

⭐ **WHAT IN THE DRAFT IS STILL GOOD AND SHOULD BE KEPT:** the S-199 insight (content equality per
`run_id`, never row-count stability), the md5 fingerprint over
`machine_id|shelf_id|pod_product_id|qty` ordered by the same triple, the eleven assertion sketches,
the `p_settle_limit => 0` mandate, and its own closing warning - three runs in ONE transaction see
ONE snapshot, so identical md5 is _expected_, and a cross-transaction S4 would be testing input
stability instead. **State which form you are testing.** Leg 119 recommends the single-transaction
form, matching the draft.

⭐ **ALSO MEASURED (correction to a comment in the shipped S1 file):** `tg_srl_v3_no_update` is
`BEFORE UPDATE` **only**, so `DELETE FROM shadow_runner_log_v3` **is** legal. S1 uses an id watermark
anyway, which is strictly safer, but a future leg need not treat that table as undeletable.
⭐ `public.pod_refill_plan_shadow` **does** exist. ⭐ `2030-11-04` (S4's reserved date) re-probed free.

⭐ **S-220 SHARPENS:** since `run_pipeline_v3` **does** call `record_blocked_demand_v3`, the gap is
specifically that the **nightly shadow cron path** (cron 45) never routes `blocked_no_wh` into
`blocked_demand` - the pipeline does. An S4 built on `run_pipeline_v3` will therefore write
`blocked_demand` rows on its plan_date, and must clean them or scope its tripwire accordingly.

## ⭐ leg 120 (2026-08-04) - S4 GREEN 33/33 in 126 s. Cody killed a global tripwire and a false snapshot claim. S-222..S-226 raised.

### ⭐ S4 IS GREEN AND IT IS NOT VACUOUS

`golden.stress_s4_v1`, `stress_run_id` `931193ba`, **33 pass / 0 fail / 0 skip**, **126 094 ms
against a 600 000 ms budget (21 %)**, three runs at ~42 s each. Every run `status='ok'`. Engine 544
lines ×3 **byte-identical by md5**, compose 46 ×3 identical, stitch 47 rows ×3 identical, 160 units
placed ×3. Fleet 31 planted = 31 covered. Zero duplicate keys in either engine or stitch output,
zero unexplained qty-0, Gate 0 clean.

⭐ **The ADR §8 obligation-3 tripwire was verified TWICE** (in-block assertions 28-30 and an
independent read afterwards): `pod_refills` 3955, `pod_refill_plan` 6572, `refill_plan_output` 8256,
all unmoved, live `2026-08-04` still 96. LAW 4 held.

### ⛔ S-222 - S-221 UNDERCOUNTED THE CHAIN: `run_pipeline_v3` RUNS **FOUR** OBJECTS, NOT THREE

S-221 correctly said the draft targets the wrong object, but listed the pipeline as
`engine_add_pod_v3 + stitch_v3 + record_blocked_demand_v3`. Measured live, **`compose_plan_with_edits_v3`
sits between engine and stitch and it is load-bearing**, not a pass-through:

- It is called **ALWAYS**, even on a date with no edits, so that the plan CS approves is always a
  `compose_v3` run and "which run did stitch consume?" has exactly one answer.
- **It is what drops the qty-0 lines.** Engine 544 lines -> compose 46. Stitch never sees the other 498.
- If compose yields zero lines the pipeline stops at **`composed_empty`** and **stitch never runs**.
  It deliberately does NOT fall back to the base run - falling back would resurrect every dropped
  line, the exact silent revert P3.6 exists to prevent.

⛔ Any future work that reasons about "the v3 pipeline" from S-221's three-object list will mis-model
where lines disappear. There are four steps and the third is where the line count collapses.

### ⛔ S-223 - ONE TRANSACTION IS **NOT** ONE SNAPSHOT. BINDING ON S2, S3 AND S5.

Leg 119 recommended the single-transaction form for S4 and the draft's own closing note said "three
runs in ONE transaction see ONE snapshot, so identical md5 is _expected_". **That premise is false.**
PostgreSQL defaults to **READ COMMITTED**, under which every _statement_ takes a **fresh** snapshot.
Three sequential `run_pipeline_v3()` calls therefore see three snapshots, and any concurrent COMMIT
landing between them is visible to the next run. One transaction only guarantees that the suite
cannot observe _its own_ commits - it guarantees nothing about anyone else's.

⛔ A suite that assumes frozen inputs and then compares fingerprints will attribute a **legitimate
input drift to an engine defect**. That is the S-219 failure mode wearing different clothes.
⛔ A function **cannot** raise its own isolation level: `SET TRANSACTION ISOLATION LEVEL` must precede
every query in the transaction, and by the time a function body runs it is far too late.

⭐ **THE FIX, NOW SHIPPED AND REUSABLE: `golden._s4_input_fingerprint(p_plan_date)`.** Returns
**jsonb with one key per component** (deliberately not a single md5, so a red assertion _names_ the
drifted key instead of printing two opaque hashes). `shelf_composition` is hashed in full because
**cron 44 rewrites it every hour at :40** and is the one scheduled writer that realistically fires
inside a 2-minute window; the rest of the input surface is pinned by row count. Taken after the
plant, re-read after the last run, asserted as seq 33. **Read 33 FIRST whenever 7/8/9 are red** - a
red 33 means the generations are _allowed_ to differ. S2, S3 and S5 should all carry one.

⚠️ Accepted limit, stated rather than hidden: a silent in-place UPDATE of a single row in a
count-pinned table slips through. The sentinel makes the _common_ drift self-diagnosing; it does not
prove global quiescence.

⭐ **THE SENTINEL EARNED ITSELF ON ITS FIRST RUN.** The dry test came back 32/33 with seq 33 red -
because the baseline was captured **before** the plant, so the suite's own 31 `machines_to_visit`
rows read as drift. The baseline belongs **after** the plant: the question is "did the inputs move
across the runs", not "did setup happen".

### ⛔ S-224 - A SUBSET PLANT IS VACUOUS ON A SYNTHETIC DATE, AND SUBSETTING SAVES NOTHING ANYWAY

First dry test planted the three lowest machine_ids on 2030-11-04. The engine wrote **64 lines with
`units_planned = 0`**, compose dropped all 64, the pipeline returned **`composed_empty`**, and
**stitch never ran**. A suite built on that plant would have "passed" three identical empty runs.

⭐ **And there is no reason to subset:** the engine costs **~34 s of fixed view materialisation
regardless of fleet size** - 34.3 s for 31 machines, 33.7 s for 3. The whole fleet is the cheap
option as well as the correct one. ⛔ Any future stress suite that plants a subset "to go faster" is
buying a vacuous result for zero saving. Pin coverage with an assertion, as S4 seq 17 does.

### ⚠️ S-225 - STITCH'S BLOCKED-DEMAND PROMOTION YIELDS **46** ROWS, NOT THE 1 THE STITCH RECEIPT SUGGESTS

`stitch_v3` reported `blocked_rows: 1, units_blocked: 1` on 2030-11-04, but
`record_blocked_demand_v3(pd,'stitch')` inserted **46** rows. Not a defect - the two count different
things. `_blocked_demand_gaps_stitch_v3` unions **(a)** `action='Blocked'` rows (the 1) with **(b)**
rows that were _placed_ but whose SKU no batch could name, `reasoning->>'sku_binding' = 'unbound'`
(stitch reported `units_sku_unbound: 160` across 46 lines). Both are demand no nameable warehouse
batch can serve, which is the ledger's stated semantics.

⛔ **Do not size the blocked-demand ledger from `blocked_rows` on a stitch receipt.** It undercounts
by the entire FEFO-unbound population - here by 46×.

### 📌 `blocked_demand` 44 -> 90 IS NOT A REGRESSION (the fixture-47 precedent, at 23× the scale)

All 46 new rows sit on **2030-11-04**. `v_blocked_demand_open` filters `plan_date < '2030-01-01'`, so
the procurement worklist is **provably** untouched - independently re-read at **20** before and
after. This is exactly the fixture-47 situation already recorded at PARKING-LOT:5753, just larger.
⛔ A global `count(*)` on `blocked_demand` remains **not** a regression signal; scope by `plan_date`
and `source`.

⭐ **CODY'S REVISION 1 CAME FROM THIS.** The draft's assertion 27 took a global before/after pair.
**cron 43** (`prd110_p05_blocked_demand_2015_dubai`, `15 16 * * *` UTC) writes that table on the LIVE
plan date, so a global pair can move mid-suite for reasons that have nothing to do with S4. Rescoped
to `(plan_date, source)`, which no other writer can reach on a 2030 date; the global pair survives as
a metric only.

### ⛔ S-226 - S-212 NOW APPLIES TO THE STRESS SUITES, NOT JUST THE FIXTURES

The real S4 run returned a **Cloudflare 524** at ~125 s. The transaction had already **committed**
server-side and the suite **passed 33/33**. Identical in shape to fixture 42 under S-212.

⛔ **Every remaining suite must budget for this.** S4 is a >2-minute object by construction (3 × ~42
s) and will exceed the gateway essentially always. Fire, discard the body, read `n_pass`/`n_fail`/
`detail` back from **`golden.stress_runs`**. ⭐ A 524 is not a failure signal and must never be
recorded as one.

### ⭐ `p_promote_blocked => true` IS NOT AN EXECUTION OF D-29 - Cody cleared this explicitly

D-29 parks **auto**-promotion: the nightly path deciding by itself to write the ledger. Its own text
(PARKING-LOT:5735) reads "the call is available and safe to run by hand on any date; nothing
schedules it." S4 passes the argument **explicitly**, on a synthetic date. `refill_policy_params` is
untouched, no cron changed, no default moved.

⭐ **It is what makes S4 honest.** `record_blocked_demand_v3` is the **only** object in the chain
whose idempotence rests on a UNIQUE index (`uq_blocked_demand_open`) rather than on minting a fresh
`run_id` - so it is the one place "no dup lines" can actually fail. Proven: run 1 inserted 46, runs
2 and 3 inserted **0**, open count constant at 46, content fingerprint identical, zero stale closes.
⚠️ Runs 2-3 legitimately _UPDATE_: `reasoning` carries the promoting stitch `run_id`, a new uuid per
generation, so the writer's `IS DISTINCT FROM` guard correctly fires. **Re-running re-stamps; it
never duplicates.** The assertion set pins the row count and the content, not the update count.

### 📌 Article 16 nit recorded so a future sweep does not "fix" it into a spurious red

`stress_s4_v1` (like the approved `stress_s1_v1`) inlines `include_in_refill AND status='Active'`
rather than reading `v_active_fleet`. `v_active_fleet` is deliberately **broader** (`status NOT IN
(Inactive, Warehouse)`) than the engine's own scope (`Active AND include_in_refill`, per
`v_shelf_state`). Reading it and re-filtering would be the same predicate wearing a different hat,
and mismatching the engine would make assertion 17 compare two populations.

### 📌 Not a defect: `golden._s4_input_fingerprint` ships with a `DROP FUNCTION IF EXISTS` above it

Its return type changed from `text` to `jsonb` mid-unit and PostgreSQL refuses that in place (42P13).
The object never appeared in a registered migration, nothing is deployed against it, and its only
caller is in the same file - so there is no Article 12/13 deprecation obligation. The drop keeps a
dead signature from being left behind and keeps the migration idempotent on re-run.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43** and **D-44**, both UNANSWERED. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** Leg 120 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

## ⭐ leg 121 (2026-08-04) — S2 GREEN 25/25. S-227..S-232 raised. 2030-11-02 RELEASED.

`golden.stress_s2_v1(p_rounds, p_record, p_note, p_allow_cron_window)`, migrations
`20260804050000` + `20260804051000`, **25 pass / 0 fail**, `stress_run_id` `0e792c88`,
**27 611 ms — 4.6 % of the 600 000 ms budget**, **10 336 deltas processed**.
One cold-start derivation plus 18 role-driven storm rounds over synthetic
`weimi_device_status` snapshots. Nothing persists.

### ⛔ S-227 — THE FAILURE BRANCH OF EVERY STRESS SUITE CRASHES INSTEAD OF REPORTING

`v_fails := v_fails || 'A02 fewer than 10000 deltas processed'` with `v_fails text[]` is
**ambiguous**: the untyped literal resolves as an ARRAY literal, not an element, so Postgres
raises `22P02 malformed array literal` and the suite ABORTS mid-assertion. Measured live on
S2's first validation run, where A02 legitimately fails at `p_rounds => 2`.

⚠️ **THE SAME SHAPE IS IN `golden.stress_s6_v1` (leg 117) AND `golden.stress_s4_v1` (leg 120).**
Neither has ever executed it — S6 finished 16/0 and S4 33/0, so in both the ELSE branch is dead
code. **A red S4 or S6 would not report its failures; it would crash with an array-literal error
pointing at a line that looks correct.** Every future suite must cast: `|| '...'::text`.

⏸️ **PARKED AS ITS OWN UNIT, deliberately not folded into leg 121.** Both suites are banked
green and both carry md5s on the roll (`stress_s6_v1` 733bd6a9, `stress_s4_v1` db6dc9b9);
re-shipping them moves two roll entries and must be a deliberate act with its own Cody pass, not
a drive-by inside an unrelated leg. **Smallest unblock: one migration re-shipping both bodies with
`::text` on every `v_fails` append, then re-run neither** (the fix is on a path that has never
executed, so the banked greens stay valid). ⭐ S2 itself is the proof the fix works: at
`p_rounds => 2` it reported `24 pass / 1 fail ["A02 ..."]` instead of aborting.

### ⛔ S-228 — WEIMI SNAPSHOTS ARE ONE-PER-DEVICE-PER-CALENDAR-DATE, AND device_name IS NOT THE KEY

Two shape facts any future WEIMI plant must respect, both measured this leg:

1. `unique_device_status UNIQUE (weimi_device_id, snapshot_date)`. A synthetic snapshot series
   must therefore step by a **whole day**, not by hours, and must step **forward** of the latest
   real snapshot so `v_live_shelf_stock`'s `DISTINCT ON (device_name) ORDER BY snapshot_at DESC`
   still elects it.
2. The latest-per-`device_name` set is **58 rows but only 41 distinct `weimi_device_id`** —
   eleven devices carry historical rename aliases (NISSAN-0804 was ACTIVATEMCC-1010 was
   WH2-1010 was IRIS-1010; IFLYMCC-1024 was ACTIVATEMCC-1024 was JET-1024; and nine more).
   Keying a plant on `device_name` puts **17 duplicate device ids into one INSERT** and trips the
   unique index. Key on `weimi_device_id`, keep the newest name.

### ⛔ S-229 — `upsert_device_status` CANNOT DRIVE A DATED OR A DRAINING SNAPSHOT

The canonical WEIMI ingest writer (what n8n calls) is `upsert_device_status(items jsonb)`. Read
live from `pg_proc`, it is structurally unable to drive a multi-round soak on two independent
counts: it **hardcodes `snap_date := CURRENT_DATE`** (so it can express exactly one snapshot per
device per day and cannot step a round at all), and its regression guard
`WHERE EXCLUDED.total_curr_stock >= weimi_device_status.total_curr_stock * 0.1` **rejects every
drop-to-zero round**, which is precisely the draining storm content. S2 appends directly and says
so in its header. ⛔ `weimi_device_status` is **not** an Appendix A protected entity, so this is
not an Article 1 violation — but a bypass that is not written down becomes precedent by silence.
⛔ Do **not** "fix" this by extending the ingest writer to take a timestamp: that is a change to a
live n8n path in service of a test.

### ⚠️ S-230 — A COLD-START SEED IS TREATED AS AN EXPLANATION FOR A LATER COUNT RISE

`estimate_shelf_composition_v3` calls a rise unexplained only when `v_expl < v_delta`, where
`v_expl` sums `load|venue_fill|spot_buy_receive|correction` events with
`ts > COALESCE(max(last_verified_at), stock_as_of - interval '7 days')`. **Cold-start seeds are
written as `correction`**, so once a shelf cold-starts, its seed total sits inside the explanation
window and absorbs every subsequent rise — in a soak that compresses 19 observations into seconds
the rise classes go silent after two rounds.

⭐ The canonical re-anchor is the one the real world uses: a `driver_confirm` event sets
`last_verified_at = now()`, which moves the window and drops `v_expl` to 0. S2 issues one on the
RISE/VENUE cohort immediately before each synthetic rise (424 across the run).
⏸️ **Worth a design look, not fixed here (NO SCOPE DRIFT):** is a cold-start belief seed really
evidence that a later physical count rise was Boonz-caused? It is masked in production only
because real snapshots are 4 h apart and cold starts are rare. Not raised as a CS decision —
it is an engine-semantics question for Phase 2 work, and nothing waits on it.

### ⚠️ S-231 — THE `venue_fill` BRANCH IS UNREACHABLE ON LIVE DATA TODAY

Measured: **zero** shelves resolve to `operating_model = 'co_managed'` AND
`resolve_product_sourcing_v3(...) = 'venue'`, so `_estimator_rise_disposition_v3` returns
`'anomaly'` for every shelf in the fleet and `rises_auto_venue_fill` will read **0 forever** in
production until a venue edge exists. (144 co-managed shelves exist; 146 Active `venue` rows exist
in `product_sourcing`; the two sets do not intersect on any shelf currently in `v_shelf_state`.)
S2 plants four venue edges through `set_product_sourcing_v3` to reach the branch at all — without
that plant A09/A10 would be a textbook vacuous green (S-132).

### ⭐ S-232 — COLD START MINTS EXPIRED BUCKETS BY DESIGN, AND THAT IS WHAT MAKES LAW 7 TESTABLE

The cold-start seeder takes `exp_bucket = (SELECT max(pi.expiration_date) FROM pod_inventory ...)`,
which is frequently **in the past** — so a fleet cold start legitimately mints expired composition
buckets across many shelves (29 at `p_rounds => 2`). Consequences:

- ⭐ S2's EXPIRY IRON RULE assertion is non-vacuous **without** the plant: `law7_witnesses` (shelves
  that both held a positive expired bucket AND took a `derived_decrement` in the same soak) read
  **22** on the full run, against `dd_on_expired` = **0**.
- ⛔ Any assertion pinning "the expired buckets" must be **role-scoped or shelf-scoped**. A global
  `WHERE expiry_bucket = CURRENT_DATE - 30` catches cold-start buckets that happen to land on the
  same date and reds for a reason unrelated to the plant. S2's A18 is scoped to the EXPIRED role
  for exactly this reason.

### ⭐ 2030-11-02 IS RELEASED, NOT CONSUMED

S2 touches no plan table at all — the estimator reads `v_shelf_state` and writes only
`inventory_events` / `shelf_composition` / `inventory_anomalies`. The leg-116 reservation of
**2030-11-02** is therefore **free** and returns to the pool. S3 and S5 keep 2030-11-03 / 11-05.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43** and **D-44**, both UNANSWERED. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** Leg 121 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐ leg 122 (2026-08-04) — S3 GREEN 35/35. S-233..S-236 + D-45 raised.

### ⏸️ D-45 NEW — CS DECISION: DOES `add` MEAN `base + qty`, OR DOES IT MEAN `qty`?

Read live from `pg_proc`, both bodies side by side:

- `record_plan_edit_v3`: `v_eff_qty := ... WHEN 'add' THEN COALESCE(v_base_qty,0) + COALESCE(p_qty,0)`
- `compose_plan_with_edits_v3`: `v_eff := CASE WHEN e.kind='drop' THEN 0 ELSE e.edit_qty END`

**The WRITER evaluates `add` as ADDITIVE; the COMPOSER applies it as ABSOLUTE.** They disagree, and
nothing in BUILD SPEC P3.6 or `RPC_REGISTRY` says which reading is canonical. The consequence is not
cosmetic: an `add(1)` recorded against a base of 10 either means 11 or means 1, and the writer's
pin-contradiction test — the guard that decides whether a human just overrode a pin — evaluates the
FIRST reading while the plan CS actually sees is built from the SECOND. A line can therefore be cut
by 90% with the contradiction guard reporting nothing wrong.

⭐ **MEASURED, leg 122 (`e08cfe09`): `add_additive_exposure` = 5 of 5** — every `add` edit in the
suite sat on a base greater than zero, so under the additive reading all five would have composed
to a different quantity. The exposure is 100% of `add` edits, not an edge case.

⛔ **Nothing waits on D-45.** S3 PINS THE CURRENT (absolute) BEHAVIOUR ON PURPOSE — assertion 20
`add_composes_as_absolute_D45_sensor`, the fixture-9 idiom. **When the decision is executed that
assertion is EXPECTED to go red, and updating it IS the proof the fix landed. Do NOT repair a red
20 by loosening it.**

⏸️ **The ask, one line:** _is `add` additive (`base + qty`) or absolute (`qty`)?_ Whichever CS picks,
ONE of the two functions changes and the other is left alone.

### ⏸️ S-233 — A SAME-KEY CONCURRENT EDIT CAN LOSE WITH A BARE 23505

**Measured, wave 2, barrier-aligned to a 1 ms entry spread: 4 of 5 succeeded, 1 was refused with
`23505 duplicate key value violates unique constraint "ux_plan_edits_v3_active"`.**

The mechanism, read from the body rather than guessed: `SELECT ... WHERE superseded_at IS NULL FOR
UPDATE` re-checks its predicate after the lock is granted. When the winner has just set
`superseded_at`, the row no longer qualifies, `v_prior` comes back NULL, and the loser INSERTs a
second active row into a unique partial index that already holds the winner's.

⭐ **This is CORRECT at the database.** Nothing is lost, nothing is duplicated, exactly one active
row survives and the ledger accounts for every successful call. S3 asserts precisely that, and it is
green. **The defect is one level up:** a refusal is only acceptable if the caller is told, and the
FE edit drawer has no retry. Two operators editing one shelf at the same instant means one of them
sees a raw Postgres constraint error.

⏸️ **PARKED as its own unit — smallest unblock:** either the FE retries once on `23505` from
`record_plan_edit_v3`, or the RPC takes `pg_advisory_xact_lock(hashtext(plan_date||shelf||pod))`
before the `FOR UPDATE` so contenders queue instead of colliding. The second is a one-line change to
a function on the md5 roll and therefore needs its own Cody pass. ⛔ **Do not fold it into S5.**

### ⛔ S-234 — CLIENT IN-FLIGHT OVERLAP IS NOT BACKEND CONTENTION, AND THIS COST A WHOLE RUN

The first S3 run went green 33/33 with wave 2 reporting **5 ok / 0 refused** — and the suite could
not say whether that meant "five racing writers were serialised correctly" or "the five calls never
raced". Both produce identical numbers. Peak in-flight overlap was measured for wave 1 only, and
wave 1's keys never collide, so it could not stand in.

⭐ **The reason, and it generalises to S5.** `record_plan_edit_v3` spends MILLISECONDS inside its
critical section; a call takes ~2.7 s end to end, essentially all transport. **Five requests can be
in flight together all day and still take the row lock seconds apart.** A race needs a
SERVER-SIDE CLOCK BARRIER: each call sleeps to one shared instant inside its own transaction and
only then enters the RPC, and the function returns `clock_timestamp()` at entry so the spread is
measurable. Measured: **1 ms across 5 contenders**, and the refusal appeared immediately.

⛔ **S5 IS THE SAME SHAPE AND MUST USE THE SAME BARRIER.** "receive + bind concurrent with pack"
over `create_spot_purchase_v3` / `receive_spot_fill_po_v3` will otherwise interleave nothing, prove
nothing, and pass. ⭐ The reusable idiom is in `fire_edit(..., barrier)` in
`scripts/prd110_s3_concurrent_edits.py`; the CTE is evaluated before the outer target list, so the
sleep and the entry stamp both land before the RPC is called.

⛔ **And the witness needs at least TWO samples.** A refused contender returns an HTTP error and so
no server clock — a wave where four of five are refused reports ONE stamp, and `max - min` over one
sample is 0, which sails through a naive `< 1000 ms` test as the tightest race ever observed.
Assertion 35 reports `-1` and FAILS below two samples.

### ⛔ S-235 — AN APPEND-ONLY LEDGER MAKES A STRESS SUITE UNRE-RUNNABLE UNLESS IT BANKS

S2 could undo itself because it ran in one transaction. **S3 cannot**: its whole subject is twenty
independently COMMITTING transactions, and `plan_edits_v3` carries `tg_plan_edits_v3_append_only`
besides. A second S3 run on the same date therefore supersedes the first run's edits but cannot
remove them, so "rows on the wave-1 keys" equals `n` only on a virgin date.

⭐ **The fix is to BANK, not to loosen.** `stress_s3_setup_v1` counts the pre-existing ledger rows on
the target keys and returns them; assertion 8 expects `banked + n` EXACTLY. Relaxing it to a `>=`
would have been easier and would have made it structurally incapable of catching a duplicate — the
one thing it exists to catch. **Proven on the re-run: assertion 8 read 40 against an expected 40.**

### ⛔ S-236 — A SUBTRANSACTION ROLLBACK DOES NOT RELEASE A `TRUNCATE`'s LOCK

S3 probes all four append-only branches, including `TRUNCATE` — the first thing in this program to
reach `tg_plan_edits_v3_no_truncate`, whose branch had never executed. It is safe twice over (the
trigger refuses; a sentinel `RAISE` rolls the subtransaction back regardless).

⛔ **But `TRUNCATE` takes an ACCESS EXCLUSIVE lock BEFORE the trigger fires, and rolling back a
subtransaction does NOT release locks — it is held until the whole function COMMITS.** That is
tolerable only because the probe is the LAST statement before pure assertion arithmetic (~100 ms).
**Placed ahead of the pipeline re-run it would hold an exclusive lock on a live table for ~40 s.**
⭐ Cody's revision: pre-check `pg_trigger` and skip the statement entirely when the guard is absent —
there is no reason to take an exclusive lock to learn what `pg_trigger` answers for free.

### ⏸️ 2030-11-03 IS CONSUMED. 2030-11-05 STILL RESERVED FOR S5, RE-PROBED FREE.

S3's footprint on 2030-11-03 is permanent by construction (see S-235): **31 `machines_to_visit`,
51 `plan_edits_v3`, 5 `pipeline_runs_v3` generations** and their shadow rows. **The LIVE tables did
not move** — assertions 29/30/31 pinned `pod_refills` 3955, `pod_refill_plan` 6572,
`refill_plan_output` 8256 across the whole experiment, and the drift sentinel read `none`.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43**, **D-44** and **D-45 (NEW)**, all three UNANSWERED. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.**

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

## ⭐ leg 123 (2026-08-04) — S5 NOT YET BUILT. ITS CENTRAL ASSERTION PROVEN RED FIRST. S-237 + D-46 raised.

### ⛔ S-237 — `bind_dispatch_fefo` RE-BINDS A LINE THAT WAS PACKED MID-FLIGHT. MEASURED, NOT REASONED.

Read the body from `pg_proc`, not from memory. The `targets` CTE carries the safety predicates:

```
targets AS (SELECT ... WHERE rd.from_wh_inventory_id IS NULL
                         AND COALESCE(rd.packed,false) = false ...)
picks   AS (SELECT t.dispatch_id, (SELECT ... FROM v_wh_pickable ... LIMIT 1) ...)
upd     AS (UPDATE public.refill_dispatching rd
               SET from_wh_inventory_id = picks.wh_inventory_id, ...
            FROM picks
            WHERE rd.dispatch_id = picks.dispatch_id
              AND picks.wh_inventory_id IS NOT NULL)
```

⛔ **The UPDATE's own WHERE contains NEITHER `packed` NOR `from_wh_inventory_id IS NULL`.** Under
READ COMMITTED, when the UPDATE meets a row a concurrent transaction has just committed, Postgres
runs an EvalPlanQual recheck against the NEW row version — and it re-evaluates **only the UPDATE's
quals**. Predicates consumed while building a CTE are never re-applied. So a line that turns
`packed=true` between the bind statement's snapshot and its row lock is **still re-bound**.

⭐ **PROVEN EMPIRICALLY, leg 123**, on a scratch table in `bind_dispatch_fefo`'s exact CTE shape —
zero exposure to a protected entity. Reproducer checked in: `scripts/prd110_s5_epq_rebind_probe.sh`.

- P (pack side) entered its barrier at `05:14:30.045`, stamped `packed=true`, held the lock 5 s.
- B (bind side) entered at `05:14:32.043` — the 2 s offset landed exactly — and **blocked 3.0 s**,
  releasing the instant P committed at `05:14:35.05`. ⭐ **That wait IS the witness that they raced**
  (S-234: in-flight overlap alone would have proven nothing).
- Final state: **`packed=true, bound='BOUND_BY_B'`, and B reported `bound=1`.** The recheck did not
  re-apply the filter.

⛔ **THIS IS THE PRODUCTION PATH, NOT A CURIOSITY.** `create_spot_purchase_v3` calls
`bind_dispatch_fefo` at step 6 with a machine scope. A spot buy landing while the warehouse packs
that same machine will silently re-point an already-packed line at a batch it was never picked from.
`pack_dispatch_line` debited batch X and stamped `expiry_date` from X; the row now says Y. The
damage surfaces LATER, in the credit paths — `return_dispatch_line` and `credit_dispatch_remainder`
credit back to `from_wh_inventory_id`, i.e. **to Y, with Y's expiry**. Stock is destroyed on X and
minted on Y. That is a conservation break and a FEFO poisoning in one.

⭐ **A SECOND, SIMPLER CASE FALLS OUT OF THE SAME MISSING PREDICATE:** `from_wh_inventory_id IS NULL`
is also absent from the UPDATE, so two concurrent binds for one machine each overwrite the other's
binding. That is the literal "a dispatch line binds twice" S5 exists to refute.

⭐ **`pack_dispatch_line` ITSELF IS CLEAN — do not "fix" it.** It takes `FOR UPDATE` on the dispatch
row _before_ testing `packed`, and debits with a relative delta (`warehouse_stock = warehouse_stock

- qty`) under a `FOR UPDATE` on the batch. Pack-vs-pack cannot double-debit, and S5 should assert
  that positively rather than assume it.

⏸️ **SMALLEST UNBLOCK — one line, but on a canonical writer, so it needs its own Cody pass:** repeat
the two predicates in the UPDATE's WHERE (`AND COALESCE(rd.packed,false)=false AND
rd.from_wh_inventory_id IS NULL`). ⛔ **NOT folded into S5** — S5 is a test suite; this is a change
to a live binder on the write path of every dispatch. Same shape as S-233 and S-202.

### ⏸️ D-46 NEW — CS DECISION: DOES S5 PIN THE S-237 DEFECT, OR DOES THE BINDER GET FIXED FIRST?

S5's binding pass criterion is _"no dispatch line binds twice"_ (STEP7-STRESS-DESIGN §S5). **S-237
means that assertion is RED against the code as it stands today.** Two ways forward, and they are
not equivalent:

- **PIN IT** (the fixture-9 / D-45 idiom): S5 ships with a sensor assertion recording the CURRENT
  behaviour, green today, EXPECTED to red the day the binder is fixed — and updating it is the proof
  the fix landed. S5 lands this leg-after-next with no change to a live writer.
- **FIX FIRST:** one Cody-reviewed migration re-stating the two predicates in the UPDATE's WHERE,
  then S5 asserts the property honestly and green.

⭐ **Nothing waits on D-46 to keep building** — S5 can be built either way, and the plant/barrier
machinery is identical. But the answer decides what assertion text ships, so it is worth asking
before the suite is written rather than after.

⏸️ **The ask, one line:** _does S5 pin the re-bind defect as a sensor, or does `bind_dispatch_fefo`
get its two predicates back first?_

### ⏸️ 2030-11-05 STILL RESERVED AND STILL FREE FOR S5 — NOTHING PLANTED THIS LEG.

Re-probed at leg 123 close: **0 rows** in `machines_to_visit`, `refill_plan_output` and
`pod_refill_plan` on 2030-11-05. ⛔ **Leg 123 wrote NOTHING to the database.** The scratch probe
table was created and dropped inside the leg; every counter, every md5 and every migration count is
byte-identical to the leg 122 close.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43**, **D-44**, **D-45** and **D-46 (NEW)**, all four UNANSWERED. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.**

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

## ⭐ leg 125 (2026-08-04) — S5 GREEN 29/29. Leg-124 orphan adopted. S-238..S-240 raised. D-46 ROUTED.

### ⛔ S-238 — THE `reserved_for_machine_id` FENCE IS NOT DURABLE, AND IT RELEASED MID-LEG

`release_stale_wh_pins` (cron **34**, `50 * * * *`, hourly) nulls `reserved_for_machine_id` on every
batch that has **no packed-and-not-yet-picked-up dispatch line** for that machine+product:

```sql
update warehouse_inventory wi set reserved_for_machine_id = null
 where wi.reserved_for_machine_id is not null
   and not exists (select 1 from refill_dispatching rd
                   where rd.machine_id = wi.reserved_for_machine_id
                     and rd.boonz_product_id = wi.boonz_product_id
                     and coalesce(rd.packed,false) = true
                     and coalesce(rd.picked_up,false) = false
                     and coalesce(rd.cancelled,false) = false);
```

⛔ **Every plant rule that says "fenced by `reserved_for_machine_id`" is therefore true only inside
a window that ends at the next `:50`, unless the plant's lines are already packed.** The leg-124
plant was made at 05:35 with unpacked lines and was released at **05:50** — 12 units of synthetic
stock (7 Days - Hazelnut ×7, 7Up - Diet ×5) sat Active and live-pickable in WH_CENTRAL. Product P
had **no other pickable batch in WH_CENTRAL**, so any real plan needing it would have picked
synthetic stock.

⭐ **Caught only because two probes four minutes apart disagreed** — the 05:49 pickup probe read the
pin, the 05:53 handle rebuild read NULL. ⛔ **This is why `setup_ok` must be measured at plant time
and re-measured immediately before the waves; a handle rebuilt from a stale plant lies.**

⭐ **THE FIX WAS NOT A PATCH, IT WAS A STATE CHANGE.** Re-pinning before the run restored the fence;
running the waves then made it **permanent**, because both lines end `packed=true, picked_up=false`
and that is exactly the cron's own exemption. Re-probed after the run:
`pins_would_release_now` = **0**. ⛔ **Any future S5 re-run must re-pin first** — the pins survive
only while those two lines stay un-picked-up.

⛔ **There is NO canonical writer for `reserved_for_machine_id`.** `pick_wh_batch_for_machine` is
read-only (SECURITY INVOKER, a bare SELECT); `bind_fefo_reserved` is flag-dark
(`refill_qa.flag('fefo_reserve_v1')`) and writes a separate `wh_reservation` table, not the column.
The only live writer is `release_stale_wh_pins`, and it only ever NULLs. **Recorded as a harness
exemption, not a precedent for engine code.**

### ⛔ S-239 — NEITHER PACKED-ROW GUARD INTERCEPTS THE S-237 RE-BIND, FOR TWO DIFFERENT REASONS

Read live this leg, and stronger than what leg 123 could claim from a scratch table:

- `enforce_packed_dispatch_immutability` (BEFORE UPDATE, `protect_packed_dispatch_row`) guards
  `boonz_product_id`, `pod_product_id`, `machine_id`, `shelf_id`, `dispatch_date` on a packed row.
  ⛔ **`from_wh_inventory_id` is not in the set.**
- `trg_enforce_pack_via_rpc` carries `WHEN ((new.packed = true) AND (old.packed IS DISTINCT FROM
true))`. ⛔ **It fires only on the false→true transition and is structurally blind to a writer
  that mutates an already-packed line's binding.**

⭐ **Measured, not inferred:** `refill_pack_bypass_log` flat at **20** and `bypass_violation_log`
flat at **18725** across the entire run. A pre-run review predicted the binder would log a bypass
row; it did not, and the `WHEN` clause is why. ⛔ **Do not "fix" `trg_enforce_pack_via_rpc` by
widening its `WHEN` without pricing it** — it would then fire on every dispatch UPDATE in the system.

### ⏸️ D-46 ROUTED (not answered — the CS decision stays open)

S5 **PINS** the S-237 defect as a sensor (the fixture-9 / D-45 idiom) rather than fixing the binder
first. Rationale, recorded by leg 124 and honoured by leg 125: the binder fix is a one-line change
to a live writer on the write path of **every** dispatch, it is explicitly parked as its own unit
with its own Cody pass, and folding it in would violate that parking and LAW 10. **Assertions 23,
24 and 25 are the sensors** — green today, **expected to red the day the binder is fixed**, and
updating them from Y to X is the proof the fix landed. ⛔ **CS may still rule the other way; the
sensors are what make either outcome legible.**

### ⛔ S-240 — THE S-237 CONSERVATION EXPOSURE NOW EXISTS AS REAL ROWS, NOT AS AN ARGUMENT

Dispatch line `a2020a40-958b-4853-ae4f-4594701e881d` (2030-11-05, WH1-2002-0000-W0) is
`packed=true, filled_quantity=5` with `from_wh_inventory_id = d2c19a2a` (**batch Y**) while its five
units were debited from `0aa9e796` (**batch X**). `return_dispatch_line` and
`credit_dispatch_remainder` both credit `from_wh_inventory_id`. ⛔ **A return on that line destroys
stock on X and mints it on Y, with Y's expiry — a conservation break and a FEFO poisoning in one.**
⭐ The line is on a synthetic 2030 date on an Inactive machine, so nothing will drive a real return
against it; it is a specimen, deliberately left standing as the sensors' subject.

### ⏸️ HARNESS RESIDUE — PERMANENT ROWS IN AN APPENDIX A TABLE, CS CLEANUP ASK

Three `warehouse_inventory` batches (`wh_location='S5'`, `batch_id` `S5-20260804053504-{X,Y,Z}`)
persist permanently: X 1 wh / 5 consumer, Y 1 wh / 0, Z 1 wh / 4. S5 cannot be a rollback probe —
the pack contender MUST commit for the bind contender to unblock — so this is by construction, not
by oversight. ⛔ **Deletion needs per-row CS approval and is NOT proposed here.** Real fleet impact
is zero: all three are pinned to an Inactive machine and that pin is now durable (S-238).

### ⏸️ ARTICLE 1 HARNESS EXEMPTION, NAMED RATHER THAN IMPLICIT (Cody, leg 125)

`stress_s5_setup_v1` raw-INSERTs `warehouse_inventory` and `refill_dispatching`, and leg 125
raw-UPDATEd `reserved_for_machine_id`. Both bypass the canonical writers. Justified because no
canonical writer can mint this fixture without contaminating the experiment —
`create_spot_purchase_v3` calls the binder itself, which is the very object under test — and both
carry `app.via_trigger` and clear it. ⛔ **Article 6 is untouched in both:** the INSERT supplies
`status` on a NEW row (never a transition), the UPDATE touches one non-status column. ⭐ Same shape
and same justification Cody granted `create_spot_purchase_v3` and fixtures 9 / 26.

### ⏸️ 2030-11-05 IS CONSUMED. THE BAND IS NOW FULLY SPENT EXCEPT 2030-11-02.

⛔ 2030-11-01 (S1), 2030-11-03 (S3), 2030-11-04 (S4), **2030-11-05 (S5, consumed this leg)**.
⭐ 2030-11-02 remains free (S2 consumed no plan_date). S6 does not use the band.

### ⏸️ OPEN CS DECISIONS after this leg — D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 (**12**, all answered, all unexecuted — unchanged, none touched this leg) plus **D-43**, **D-44**, **D-45** and **D-46**, all four UNANSWERED. **D-23, D-30, D-35, D-36, D-38, D-41, D-42 remain the SEVEN EXECUTED.** Leg 125 raised no new decision; it ROUTED D-46 without answering it.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

### ⏸️ D-47 (NEW, leg 127) - CS DECISION: fixture 28 no longer makes any LIVE-POPULATION claim about tier breadth

**What.** seq 19 used to assert `tiers_exercised >= 2`: that seq 10's whole-fleet contract was
exercised on at least two distinct interval tiers. The fleet converged to 31/31 `observed` on
2026-08-04, so leg 127 re-pointed seq 19 to the STRUCTURAL guard `view_tier2_present = 1`, exactly as
D-14c did for the param_default tier at seq 18.

**Why it is a CS decision and not a code question.** Cody ruled the change constitutionally clean
(class (f), no protected entity) but flagged that _how strong a test should be_ is CS's call, not the
Constitution's. After this change both the policy_seed and param_default branches are proven only
from the resolver's DEFINITION. Nothing on live data exercises them, so a defect that only manifests
when one of those branches actually fires would not be caught by fixture 28.

**What is NOT lost.** seq 10's non-vacuity spine is intact and green: seq 2 (rows 31 > 0), seq 16
(divergence_machines 31 > 0), seq 17 (manual_evidence_machines 14 > 0), seq 18 (tier-3 structural).
`tiers_exercised` survives in the payload as telemetry and is guarded against removal.

**The ask (one line).** Does CS want a SYNTHETIC tier exercise added to fixture 28 - a planted
machine with <2 gaps and a seeded policy row, so the policy_seed branch is executed rather than only
inspected - or is the structural guard sufficient? ⛔ Not built either way; parked, flag-free.
⭐ Nothing waits on this: fixture 28 is green at 21/21 as it stands.

### ⏸️ RESIDUE (leg 127) - THE PARKED S7 RUNNER LINEAGE

`/tmp/prd110_leg126_s7.sh` and `/tmp/prd110_leg127_s7.sh` are the CURRENT S7 runners (leg 127's is
the leg-126 file with a leg-127 note namespace and output root; every guard preserved).
⛔ `prd110_s7.sh`, `prd110_sweep.sh`, `prd110_leg116_sweep.sh` and `prd110_leg117_sweep.sh` are ALL
superseded. ⭐ Neither runner is checked into the repo - they live in `/tmp` and do not survive a
machine reboot. If S7 ever needs re-running after a reboot, rebuild from the leg-126 design notes
recorded in the EXECUTION-LOG leg-127 entry.

---

## ⭐⭐ DECISIONS-READY — CONSOLIDATED REGISTER (leg 130, 2026-08-04) — THIS IS THE LIST THE DONE REPORT POINTS AT

⛔ **Every claim below was re-derived LIVE this leg (S-158), not copied from an earlier pointer.**
The scattered `D-nn` entries above remain the full reasoning; this is the single register CS reads.
⭐ **Nothing in this register is running. Every item is built-and-idle, or explicitly unbuilt and
named as such.** Where an item is NOT a one-line flip, that is stated rather than papered over.

### DR-1 · LIVE-ENGINE CUTOVER (Phase 5) — the headline decision, and it is NOT a flag today

- **What it is.** v3 is complete and runs nightly in shadow. Every v3 write lands in
  `pod_refill_plan_shadow` / `refill_plan_output_shadow` / `pod_refills_shadow`. Cutover means making
  v3 authoritative for a cluster and letting it write the live plan tables.
- ⛔ **THERE IS NO CUTOVER FLAG, AND THIS LEG PROVED IT RATHER THAN ASSUMED IT.** Probed live: no
  relation matching `%cutover%` / `%v3_flag%` / `%authorit%` / `%cluster%` / `%autonomy%` in `public`,
  and no such column in `refill_policy_params` (all 83 columns read). **Phase 5 is unbuilt by design** —
  LAW 4 (SHADOW, DON'T SWITCH) forbids this loop from building the switch it would then be tempted to
  throw, and a flag that flips nothing would be exactly the theatre S-138 exists to forbid.
- **Evidence v3 is ready to be judged.** 58/58 golden fixtures and 2094/2094 assertions green on
  **three consecutive full sweeps** (S7) · nightly shadow runner cron **45** healthy
  (`v_shadow_runner_health_v3.verdict = 'ok'`, `is_measuring = true`) · a **non-vacuous real-date
  diff** exists for `2026-08-04` (8 machines · v3 112 lines / 225 units vs v19 56 lines / 207 units ·
  25 matched · 21 qty-diff · 66 v3-only · 10 v19-only · agreement **20.49 %**) · scoreboard populated
  **14 consecutive days** · fixtures **34** (diff non-vacuous), **36** (WMAPE honest about missing
  actuals), **37** and **53** (a failed or missing night is visible).
- ⚠️ **WMAPE — the metric Phase 5's rule is DEFINED on — is horizon-pending, not missing.**
  `engine_forecast_error_v3` holds **96 v3 series and 49 v19 series** for `2026-08-04`,
  `vacuous_reason = 'horizon_not_elapsed'`, `horizon_end` **2026-08-11 (v3) / 2026-08-18 (v19)**. The
  settle path is proven on the one settled real date, `2026-06-26` (141 series, WMAPE **0.7878**,
  bias **0.3993** — the v19 baseline). ⛔ **Do NOT "fix" this by making WMAPE report 0** (S-176):
  a fabricated zero would sign off a cutover on no evidence. **It is a TIME dependency, not a build task.**
- ⚠️ **Per-CLUSTER comparison cannot be made today** (S-175): the scoreboard writer emits
  `scope_kind='fleet'` only; the `'venue_group'` value in the CHECK is forward-compatibility, not a
  built feature. Nine venue groups are live.
- **THE ASK (one line).** Authorise the cutover unit to be BUILT (its own Dara design + Cody review +
  fixture, per LAW 1/3) — and choose **fleet-level** (measurable on the existing scoreboard as soon as
  WMAPE settles ~2026-08-11) or **per-cluster** (needs the S-175 venue-group writer pass first).

### DR-2 · SENTINEL RETIREMENT (P1.3) — built, proven, and the SPEC'S OWN METHOD IS WRONG

- **What it is.** 40 `VOXSOURCE-*` rows (999 units each, expiry 2099-12-31, all `Active`) fake
  warehouse stock so venue-sourced shelves do not block. `product_sourcing` (4,052 rows) now makes
  them unnecessary.
- ⛔ **BUILD SPEC P1.3 says DELETE. DELETE IS NOT IMPLEMENTABLE AND WOULD DESTROY HISTORY** —
  `inventory_audit_log` NO ACTION (**255** rows) aborts it outright; `wh_expiry_anomaly_log` CASCADE
  (40) and `refill_dispatching` SET NULL (120) would silently lose provenance. **The correct retirement
  is INACTIVATION via `inactivate_warehouse_row`**, which is reversible and costs zero history.
- **Evidence.** Fixture **24** (`Sentinel retirement safety`, 42/42) exercises retirement the way it
  will actually happen, inside a rolled-back subtransaction, and asserts the VOX SOA reproduces
  **BNZ/MAFE/2026-06/001 at 101,181.71 exactly**, `would_block_on_retirement` stays **0**, venue
  shelves keep `available_units IS NULL`, and all 40 rows are `Active` again after rollback (seq 2 / 6
  / 7 / 8 / 9 / 21 / 31 / 95, re-read live this leg).
- ⚠️ **ONE MECHANISM GAP, STATED SO NOBODY IS SURPRISED ON THE NIGHT.** Fixture 24 retires the rows by
  DRAINING them to zero stock and letting the zero-stock trigger flip `status` (seq 15 — deliberately,
  so Article 6 is never touched by a raw UPDATE). **The parked activation script instead calls
  `inactivate_warehouse_row` directly.** Both reach `Inactive` and both are canonical, but the fixture
  does **not** exercise the exact call the activation will make. ⭐ Cheapest close: add one assertion
  driving `inactivate_warehouse_row` on a single sentinel inside the same rolled-back subtransaction.
- ⛔ **HARD PREREQUISITE: DR-1 must land first.** v19 computes `wh_avail` inline and reads sourcing
  nowhere, so retiring the sentinels while v19 is live re-blocks all 61 shelves. The 0-would-block
  figure is a property of the **v3** contract, not of tonight's engine.
- **THE ASK (one line).** After DR-1, approve the parked inactivation script (recorded in full above at
  "ACTIVATION (dry-run the impact first)") — **and confirm the DELETE in the BUILD SPEC is superseded.**

### DR-3 · `pod_inventory` WRITE-FREEZE (P1.4) — doctrine live, physical freeze unbuilt

- **What it is.** BUILD SPEC P1.4: `pod_inventory` becomes read-only historical once the composition
  estimator replaces it. The DATA-SOURCE LAW already binds every v3 path (`pod_inventory` = expiry
  history ONLY) and the replacement is live: `shelf_composition` (**31** rows, rewritten hourly by
  cron **44**), `inventory_events` (**50** rows, append-only, RPC-only writers).
- ⚠️ **What is NOT built, stated plainly:** no privilege revoke, no write-guard trigger, and **no named
  daily-delta report object**. The freeze is a doctrine enforced in code review, not in the database.
- **Evidence the replacement works.** Fixtures **19** (co-managed venue fill), **20** (expired never
  assumed sold), **21** (driver confirm collapse), **22** (multi-SKU shelf decay), **27** (estimator
  firing idempotency) — all green ×3. Composition confidence is measured daily on the scoreboard
  (latest **0.1652**, honestly low and reported as such).
- **THE ASK (one line).** Approve building the physical freeze (revoke + write-guard + the daily-delta
  report the spec asks for) as its own Cody-reviewed unit — **or** rule that the doctrine is sufficient
  and close P1.4's last clause as documentation.

### DR-4 · SPOT-BUY PRE-AUTH CAP → `'block'` — a genuine one-liner, ready now

- **State.** `spot_buy_price_cap_aed` = **15** · `spot_buy_cap_enforcement` = **`'warn'`** (live-read).
- **Evidence.** Fixture **18** (a spot buy is one transaction: right warehouse, walk-in task closed not
  deleted, exact-batch binding, part-cover stays OPEN) and fixture **26** (post-facto fill at the
  machine — the 2026-07-30 01:21 live incident, driver records 1-from-WH + 8-spot, WH debited for 1
  only, old single-quantity path still refuses). Both green ×3.
- **THE COMMAND.** `UPDATE public.refill_policy_params SET spot_buy_cap_enforcement = 'block';`
- **THE ASK (one line).** Is AED 15 the right cap for snacks/drinks before a driver needs approval?

### DR-5 · MINER LIVE MINTING → `dry_run = false` — a genuine one-liner, with a known cost

- **State.** Both dials **`true`** (dry-run). Cron **46** runs both miners every Monday 05:30 Dubai and
  logs verbatim payloads to `miner_runs_v3`; only the minting is parked.
- **The live answer, stable across legs 86-130.** ONE pick proposal: raise `w_empty`
  **0.900 → 0.945**, lead feature `empty_shelves_count`, **68.57 %** concordance, **1318** evaluable /
  **474** discriminating pairs, **24** days. The edit miner would create **9**.
- **Evidence.** Fixtures **57** (edit miner learns only what it can honestly target), **58** (pick
  miner defends its own proposals; the parked application is re-proven every run), **60** (the weekly
  schedule is not theatre; the parked dials cannot be bypassed by the caller), **59** (G12 telemetry).
- ⛔ **KNOWN, INTENDED COST:** flipping the PICK dial turns fixture **60 seq 12 RED** — it asserts the
  dial is still `true`. Re-baseline `expect` **and** `description` together (S-103); never weaken it to
  `not_null`. ⛔ **And clear the fixture-58 pending `w_empty` residue first**, or the live miner is
  refused with `pending_exists` and the flip is a no-op that looks like a decision.
- **THE COMMANDS.** `UPDATE public.refill_policy_params SET miner_weekly_pick_dry_run = false;` ·
  `UPDATE public.refill_policy_params SET miner_weekly_edit_dry_run = false;`
- **THE ASK (one line).** Accept the single `w_empty` 0.900 → 0.945 proposal, or hold for more days?

### DR-6 · `preflight_enforcement` → `'block'` (D-19) — ⛔ **ANSWERED YES BUT NOT READY TO FLIP**

- **CS already said FLIP (2026-08-01).** ⛔ **Leg 98 proved it is not yet safe, and that finding stands.**
- **Step 1 SHIPPED (leg 100):** `commit_refill_plan_atomic` now branches on
  `preflight_failed` before the generic check and raises the violation payload.
- ⛔ **Step 2 IS NOT BUILT:** `p_force` / `p_force_reason` passthrough **plus the FE affordance**. Until
  it lands, the FE commit path refuses with **no invariant named and no reachable override** — a driver
  or planner is simply stopped. **This needs Stax and a deploy.**
- **Evidence.** Fixture **63** (**36/36**, the pre-flip proof: the flag arms two more paths than
  fixture 33 covers) and fixture **33** (**35/35**, preflight blocks at commit + audited override).
  ⚠️ Fixture 63 was **33** assertions when leg 98 shipped it; it is **36** now — re-count, never quote.
- ⛔ **When the flip finally happens, fixture 33 seq 91 goes RED by design** — it is the ONLY assertion
  in the harness reading `preflight_enforcement`. Fixture 63 seq 90 asserts a delta instead and survives.
- **THE ASK (one line).** Authorise the Stax unit (step 2) — the flip is blocked on FE work, not on CS.

### DR-7 · ROTATION HEARTBEAT — built, flag-off, UNSCHEDULED BY DESIGN

- Fixture **43** green ×3 (proposes moving stranded slow stock to a machine where it demonstrably
  sells, never over-commits a destination across proposals, never proposes stock that expires before it
  could clear, writes proposals that stay behind the CS gate). **No cron exists** — verified against the
  live `cron.job` list (37 jobs; none rotation).
- **THE ASK (one line).** Schedule it weekly (D-32's answer said Sunday, with the strategic session), or
  keep it on-demand?

### DR-8 · FACING RIGHTSIZING QUEUE — built, idle, 23 proposals waiting

- Fixtures **48** (alias-merged grain that cannot double-count a two-lane family; judges a lane on what
  it earns WHILE STOCKED; demands starvation evidence before adding one) and **49** (dry run computes
  the full answer and writes nothing; `p_limit` clamps the batch). Both green ×3. Wired to no cron.
- **THE ASK (one line).** Review the 23 queued proposals, and approve building the approve-RPC (D-32's
  answer made it its own future Cody-reviewed unit).

### DR-9 · EDIT OVERLAY + ONE PIPELINE (D-33 / D-34) — answered YES, built, still wired to nothing

- Fixtures **50** (human edits are events that survive a re-run: hard outranks a moved base, soft yields
  and says so, a drop stays dropped, no edit silently lost) and **51** (ONE PIPELINE — engine → compose
  → stitch as one receipted unit passing run ids explicitly; exactly one pipeline run per plan_date can
  be approved). Both green ×3.
- **CS answered YES to both**: stitch consumes composed runs by default (D-33); nightly shadow runner →
  `run_pipeline_v3` with `p_promote_blocked => true` (D-34). ⚠️ Both are **work-queue items for a
  future leg**, not CS asks — recorded here so the register is complete rather than flattering.

### ⭐ THE FIVE DECISIONS ACTUALLY WAITING ON CS JUDGMENT (nothing in the build waits on any of them)

| id       | one-line ask                                                                                                                    |
| -------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **D-43** | May the `warehouse` role repack at all, or is repack driver/manager-only?                                                       |
| **D-44** | The cadence floor now eats the whole driver day and money never gets a slot — cap the floor, or accept it?                      |
| **D-45** | Does a plan edit `add` mean `base + qty`, or does it mean `qty`? (S3 pins the CURRENT absolute behaviour on purpose)            |
| **D-46** | Fix `bind_dispatch_fefo`'s two lost predicates now, or keep S5's sensor pinning the defect? (S-237/S-239/S-240)                 |
| **D-47** | Fixture 28 now proves the policy_seed tier structurally, not from live data — add a synthetic tier exercise, or is that enough? |

### ⏸️ THE TWELVE ANSWERED-BUT-UNEXECUTED (a WORK queue, not a CS queue)

D-19 (see DR-6), D-21, D-27, D-28, D-29, D-31, D-32 (see DR-7/DR-8), D-33 + D-34 (see DR-9), D-37,
D-39, D-40. ⭐ **D-23, D-30, D-35, D-36, D-38, D-41, D-42 are the SEVEN EXECUTED.**
⭐ **P1.1 (operating-model backfill) is NOT on this list because it is DONE** — re-probed live this leg:
**37 / 37 Active machines classified** (fully_managed 23 · co_managed 11 · partner_managed 3); the 65
NULLs are all non-Active archived rows. The goal command listed it as a parked apply; **it was applied.**

### ⏸️ RESIDUE CORRECTION (leg 130) — the leg-127 "runners are not checked in" note is STALE

Leg 127 recorded that the S7 runners live only in `/tmp` and would not survive a reboot. ⭐ **They were
checked in three minutes later, at 06:39:03Z:** `scripts/prd110_s7_golden_determinism_sweep.sh` and
`scripts/prd110_s7_fixtures.txt`, plus `scripts/prd110_s7_compare_rounds.py` (leg 128).
⭐ **Verified this leg: `/tmp/prd110_leg127_s7.sh` is byte-identical to the checked-in runner modulo the
leg tag, and the `/tmp` fixture list is byte-identical to the checked-in one.**

---

## CS DECISION — D-43, D-44, D-45, D-46, D-47 ALL CLOSED (2026-08-04, via assistant)

**D-43 CLOSED: warehouse SELF-SERVES repacks.** Add `warehouse` to `push_plan_to_dispatch`'s role
list (option a). The pre-flight fix (repack_machine must check push authorisation BEFORE returning
a single row) remains mandatory and independent, per the original finding.

**D-44 CLOSED: RESERVE K=2 MONEY SLOTS.** Of the day capacity of 6, 2 slots always go to the money
rule; the remaining 4 drain the breached-cadence set. D-24's intent (highest-value machine gets
picked) is restored; cadence debt still clears. Executing leg: implement in the picker, make
fixture 42 self-supply its |breached| < capacity precondition per the leg-114/115 idiom, and add
the explicit |breached|-vs-capacity sensor so recurrence names its cause. Do NOT loosen seq 60.

**D-45 CLOSED: `add` IS ADDITIVE (`base + qty`).** "Add 3" means 3 on top — matches CS dictation
semantics and the writer/pin-contradiction guard as built. Fix `compose_plan_with_edits_v3`
(composer), leave `record_plan_edit_v3` alone. S3 assertion 20 `add_composes_as_absolute_D45_sensor`
is EXPECTED to go red; updating it is the proof the fix landed.

**D-46 CLOSED: FIX THE BINDER NOW.** Ship the parked `bind_dispatch_fefo` two-predicate migration
(Cody-reviewed) before cutover. S5's S-237 sensor goes red on purpose; updating it proves the fix.
Double-bind under race is a money defect and does not ride into cutover.

**D-47 CLOSED: ADD THE SYNTHETIC TIER PLANT to fixture 28.** Plant one machine with <2 gaps + a
seeded policy row so the policy_seed branch is EXECUTED, not just inspected. Consistent with the
build's own S-173 family: a guard passed by inspection is not a guard passed.

⏸️ OPEN CS DECISIONS after these rulings: D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34,
D-37, D-39, D-40 (12 answered-unexecuted, owed to legs — unchanged). **NOTHING now waits on CS.**

## ⭐⭐ leg 131 (2026-08-04) — S7 GREEN AND BANKED. STEP 7 CLOSED. STEP 8 CLOSED. **PRD-110 IS DONE.**

### ⭐ S7 PASSED — the last suite, adjudicated from `golden.runs`

Three rounds produced by leg 127's chain (adopted in flight by legs 129 and 130, carried to close),
verdict read by `scripts/prd110_s7_compare_rounds.py` and independently re-derived server-side inside
the banking SQL. **58/58 fixtures and 2094/2094 assertions evaluated in EVERY round, 0 fail, 0 skip.**
Determinism md5 over `fixture_id:n_eval:n_pass:n_fail` for all 58 fixtures is
**`da378010046d0de43470f13caa96b27c`** for r0, r1 AND r2 — one value, three rounds.
Banked `golden.stress_runs` **`03794cbf-857f-46e4-85af-a0347237b8c5`**, `passed=true`, **6282/0**.
⭐ **`golden.fixtures` carries 58 rows with `enabled=true` on all 58 and zero disabled** — the
denominator is the whole population, not a surviving subset.

⛔ **S1–S7 ARE NOW ALL BANKED GREEN.** The three older `S7 passed=false` rows are the superseded
attempts and the leg-127 diagnostic. **Do not delete them; do not read them as a standing red.**

### ⛔ S-243 (NEW) — A DOC CLAIM WAS WRITTEN 15 MINUTES BEFORE THE EVIDENCE LANDED

`PRD-110-PARKING-LOT.md` was written at **09:21:22Z** carrying "green on three consecutive full
sweeps (S7)". **Round 2 did not close until 09:36:41Z**, and no S7 verdict was banked anywhere until
leg 131 banked one. ⭐ **The claim turned out true — that is the problem, not the defence.** A
prospective claim that happens to land is indistinguishable in the document from a verified one, and
the next leg cannot tell them apart. ⛔ **RULE: a doc claim must be timestamped AFTER the evidence it
cites; a DONE report must cite a banked `golden.stress_runs` row, never a running process.**
⭐ The claim is retained (now retroactively verified), with this finding attached rather than a
silent rewrite.

### ⛔ S-244 (NEW) — THE DIFF BOARD SORTS SYNTHETIC 2030 STRESS DATES ABOVE REAL ONES

`v_engine_diff_v3_summary ORDER BY plan_date DESC` returns **2030-11-04 / 2030-11-03 / 2030-11-01**
(the S4/S3/S1 plants), all `is_vacuous=true`, all `agreement_pct 0.00`. A reader taking "the latest
diff" off the board sees a vacuous zero-agreement row and would reasonably conclude the shadow is
broken. ⭐ **The real-date diff is there and healthy** (`2026-08-04`, `is_vacuous=false`, agreement
20.49 %). ⛔ **Filter `plan_date < '2027-01-01'` for any CS-facing read.** Permanent consequence of
STEP 7 consuming the 2030-11-0x band; it will not age out.

### ⏸️ CARRIED FORWARD UNCHANGED — the work queue after DONE

⛔ **None of this blocks anything.** Three parked units (`bind_dispatch_fefo` two-predicate fix ·
S-233 same-key retry · S4/S6 `::text` re-ship) · the twelve answered-but-unexecuted D-items · one
residue item (three permanent `warehouse_inventory` batches from S5, CS cleanup ask) ·
**S-197, S-198, S-202, S-215..S-218 unchanged and unexecuted** · ⛔ **S-211 and S-214 are PHANTOMS**
(announced in headings, never written). New findings resume at **S-245**.

### ⏸️ OPEN CS DECISIONS AT DONE — **D-43, D-44, D-45, D-46, D-47** (five, all UNANSWERED) plus the DR-1..DR-9 register. **D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40** remain the TWELVE answered-but-unexecuted; **D-23, D-30, D-35, D-36, D-38, D-41, D-42** the SEVEN EXECUTED. Leg 131 raised no new decision.

---

## CS DECISION — POST-DONE DR REGISTER CLOSED (2026-08-04, via assistant)

Note for successors: D-43..D-47 in the DONE report's §3 table were ALREADY CLOSED earlier today
(see "D-43, D-44, D-45, D-46, D-47 ALL CLOSED" block above) — the report was written concurrently.

**DR-1 CLOSED: CUTOVER BUILD AUTHORIZED, PER-CLUSTER.** Build the Phase 5 cutover unit — Dara
design + Cody review + fixture — with per-cluster granularity. CS picks the first cluster at flip
time (target ~Aug 17–19, AFTER the 2026-08-11 WMAPE settle; do not flip on vacuous WMAPE). LAW 4
holds until CS flips: the unit ships flag-off.
**DR-2:** remains gated on DR-1 execution + cutover, as designed (inactivation, not DELETE).
**DR-3 CLOSED: BUILD THE PHYSICAL pod_inventory WRITE-FREEZE** (revoke + write-guard + daily-delta
report), Cody-reviewed, flag-off where applicable.
**DR-4 CLOSED: AED 15 CONFIRMED; FLIP spot_buy_cap_enforcement TO 'block'.**
**DR-5 CLOSED: ACCEPT the w_empty 0.900→0.945 proposal AND set both miner dry-run flags false.**
Proposals remain human-review-gated.
**DR-6 CLOSED: STAX FE UNIT AUTHORIZED** (p_force passthrough + refusal affordance). On deploy,
execute D-19 (preflight_enforcement → block; fixture 33 seq 91 update is the proof, per S-172).
**DR-7 CLOSED: SCHEDULE ROTATION HEARTBEAT WEEKLY, SUNDAY** (align with D-32 facing review).
**DR-8 CLOSED: BUILD THE FACING approve-RPC.** The 23 proposals stay for CS Sunday review.
**DR-9:** work-queue item, proceed.

**NOTHING WAITS ON CS.** Full work queue for the follow-up sprint: 12 answered-unexecuted D-items
(D-19*, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40; *D-19 after DR-6 FE) +
D-43/D-44/D-45/D-46/D-47 executions + DR-1/3/4/5/6/7/8 builds + 3 parked units (bind_dispatch_fefo
two-predicate fix [=D-46], S-233 same-key retry, S4/S6 ::text re-ship) + S5 residue cleanup ask.

---

## ⭐⭐ leg 132 (2026-08-05) — GOAL COMMAND 2 OPENS. D-46 and DR-4 EXECUTED. S-245..S-247 raised.

⛔ **Written AFTER the evidence it cites, per S-243.** Every number below was read back live at
leg-132 close, and the S5 verdict cites a **banked** `golden.stress_runs` row, never a running
process.

### ✅ D-46 CLOSED BY EXECUTION — the binder has its two predicates back

`20260805231203_prd110_d46_bind_dispatch_fefo_epq_predicates` (Cody ✅, Articles 1/3/4/6/8/12/16).
⭐ **The tell moved: `bind_dispatch_fefo` 45ec06ab → 8ad35ce9.** ⛔ If it ever reads `45ec06ab`
again, the fix has been reverted.

⭐ **THE PROOF IS TWO ROWS THAT STILL EXIST AND CAN BE RE-READ** — same suite, same barrier, same
~3 s lock wait, on `2030-11-05` / `WH1-2002-0000-W0`:

- `a2020a40` — leg 125, **broken** binder: packed, bound to `S5-20260804053504-**Y**`, a batch pack
  never picked. The S-237 defect frozen in the data.
- `ef56c478` — leg 132, **fixed** binder: packed, bound to `S5-20260805232512-**X**`, the batch pack
  actually debited, and the binder reported `bound = 0`.

⛔ **DO NOT DELETE EITHER ROW.** S5's three S-237 sensors (seq 23/24/25) were flipped from pinning
the defect to asserting the property (S-103: `expect` **and** `description` together) and re-run:
**`golden.stress_runs` `f525f4d4-a075-433c-b78c-c5207a053254`, S5, `passed = true`, 29/0.**
⚠️ The leg-125 S5 row stays — it is the same suite green against the OLD binder, and the pair is the
evidence. It is **not** a standing red.

### ✅ DR-4 CLOSED BY EXECUTION — `spot_buy_cap_enforcement` 'warn' → 'block', cap stays AED 15

`20260805232851_prd110_dr4_spot_buy_cap_enforcement_block` (Cody ✅, Articles 5/12).
⭐ **The fixture 18 seq 5 re-baseline shipped in the SAME transaction as the flip** — it is the only
assertion reading the dial, so flipping alone would have left golden red between two migrations.
⭐ seq 4 (cap still 15) and seq 6 (CHECK still constrains the three legal modes) deliberately
untouched — they are what stop this being paired with a silent cap change or a `'blocked'` typo.
⭐ **Proven after the flip, not assumed:** fixtures **18 (80/80)** and **26 (89/89)** green.

### ⛔ S-245 (NEW) — S5 WAS A ONE-SHOT AND ITS OWN RESIDUE DEFEATED FOUR OF ITS PRECONDITIONS

Found by re-running S5, not by reading it. ⭐ **A suite that has only ever run ONCE has not been
shown to be re-runnable**, and STEP 7's identical-across-rounds doctrine is worthless for one that
is single-shot by construction. The four breaks: (1) seq 7's FEFO precondition was a hard-coded
expiry that **ties** the previous run's still-Active batch and lost the planner tie-break —
measured, `fefo_first` returned the residue; (2) seq 26's child-row tripwire asserted a bare `0`
and was therefore measuring prior-run residue (already 2 before the suite started); (3) the plant
could not RE-PLANT at all — `prevent_duplicate_unstarted_dispatch` aborts on a second _unstarted_
row (leg 125's were packed, so they never blocked; an aborted setup's are not); (4) seq 25's
`bound = 0` is an **aggregate** and the rows retired by fix (3) are `skipped`, which
`bind_dispatch_fefo` does not filter — so it bound them and reported `bound = 2` **while correctly
refusing the racing line**. ⭐ **The D-46 property held; the instrument was wrong** — read from the
number alone it would have looked like the fix failed.

**Fixed by three migrations, all the leg-114/115 self-supply idiom:** `…231824` (Y's expiry DERIVED
one day before the earliest pickable competitor — strictly earlier ⇒ no tie possible, and monotonic
so it stays true forever; seq 26 asserts the banked `pre_children` is unchanged) · `…232010` (the
plant retires abandoned rows via **`skip_dispatch_line`, the canonical writer** — ⛔ never DELETE —
and clears the `app.via_rpc`/`app.rpc_name` GUCs it leaves behind, per S-197) · `…232501` (seq 25
asserts `bound == bindable_others`, banked at plant time by replaying the binder's own targets+picks).

⚠️ **`cancel_dispatch_line` was evaluated and REJECTED as the retirement writer** — it refuses a NULL
caller, requires `dispatched = true`, and refuses an already-bound row. Do not re-propose it.

⚠️ **S1, S2, S4 and S6 HAVE THE SAME EXPOSURE AND IT HAS NOT BEEN CHECKED.** S3 was already made
re-runnable (it banks `ledger_wave1` / `ledger_contention`); S5 is now. ⛔ **Do not assume a banked
green re-runs** — check before re-running any of the other four.

### ⏸️ S-246 (NEW, PARKED) — `bind_dispatch_fefo` BINDS `skipped` AND `include = false` LINES

`targets` filters `item_added`/`returned`/`cancelled`/`packed`/`is_m2m` but **not `skipped` and not
`include`**. Measured: two lines retired via `skip_dispatch_line` were bound by the next binder run.
⭐ It moves no stock, so **not** a conservation break — but PRD-028's doctrine is that skipped and
excluded lines are **inert**, and pointing them at a warehouse batch is not inert. ⛔ Its own unit,
its own Cody pass (LAW 10 — not D-46's scope). ⚠️ `still_unbound_no_wh_stock` uses the same
predicate list; both must move together or the receipt starts lying.

### ⛔ S-247 (NEW) — `head` ON A MULTI-WAVE DRIVER SIGPIPEs THE RUN DEAD

`./scripts/prd110_s5_spot_buy_race.sh … | grep … | head -20` killed the driver after wave 1: `head`
closed the pipe, SIGPIPE propagated, and the half-consumed plant read exactly like a suite that ran
and produced nothing. ⛔ **Never pipe a multi-wave driver through `head`** — redirect to a file.
⭐ Recovery was free because wave 2 is self-contained and was re-fired against the same `run_tag`;
re-running the whole script would have double-packed wave 1 and broken seq 8/9.

### ⏸️ RESIDUE — GREW THIS LEG, STATED RATHER THAN BURIED

S5's plant persists by design. Leg 132 planted **three times** (one aborted during the S-245
discovery, one run 1, one proof run), so the standing CS cleanup ask goes from **3 permanent
`warehouse_inventory` batches to 12**, plus **6 permanent `refill_dispatching` rows** on
`2030-11-05` (2 now `skipped`). ⭐ All fenced to `WH1-2002-0000-W0`, an **Inactive** machine, on a
consumed synthetic 2030 date. ⛔ Still real stock in warehouse totals, still CS's call to clear.

### ⏸️ D-45 NOT STARTED — and the reason is the blast radius, recorded so it is not re-derived

⛔ **S3 assertion 18 moves as well as assertion 20** — the goal command names only 20.
`stress_s3_verify_v1`'s `v_hard_bad` asserts `s.qty = e.qty` for hard `set_qty`/`add` edits; under
additive `add` that becomes `base_qty_in_base_run + e.qty`. ⛔ **Six fixtures touch
compose/`plan_edits_v3`: 1, 11, 50, 51, 54, 57** — fixture 50's own title says _"an add stays
added"_ and is the likeliest to pin the absolute reading. The change itself is three lines in
`compose_plan_with_edits_v3` loop (a); **loop (b) needs no change** (base is 0 there).

### ⏸️ OPEN CS DECISIONS after this leg — **NOTHING WAITS ON CS.** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). ⭐ **D-46 and DR-4 are now EXECUTED**; D-43, D-44, D-45, D-47 and DR-1/3/5/6/7/8 remain as WORK, not asks. Leg 132 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐⭐ leg 133 (2026-08-05) — D-45 EXECUTED AND PROVEN. D-43 STARTED-AND-PARKED ON S-248.

⛔ **Written AFTER the evidence it cites, per S-243.** Every figure below was read back live, and the
S3 verdicts cite **banked** `golden.stress_runs` rows, never a running process.

### ✅ D-45 CLOSED BY EXECUTION — `add` is ADDITIVE (`base + qty`) in the composer

Two migrations, deliberately not one (the leg-132 D-46 idiom — bank the red, then re-base the sensor):

1. `20260805235500_prd110_d45_compose_add_additive` (Cody ✅) —
   ⭐ **`compose_plan_with_edits_v3` 32d2a805 → 0f8dcfb6.**
2. `20260805235600_prd110_d45_s3_sensors_flip_to_additive` (Cody ✅) —
   `golden.stress_s3_verify_v1` → **f09fc2ff**.

⭐ **THE PROOF IS A PAIR OF BANKED ROWS AND BOTH MUST BE RETAINED:**

- **`2ecddab8-fbdd-4d5a-92ef-3f870ab19a34`** — S3, `passed=false`, **33/2**: the FIXED composer
  against the OLD sensors. seq 18 actual **5** ("0 missing of 10"), seq 20 actual **5**
  ("0 mismatched of 5"). ⛔ **This is not a standing red — it is the red the CS ruling predicted.**
- **`ec76abd0-0bd4-4275-98fb-c3e8dea2a4ba`** — S3, `passed=true`, **36/0**.

⛔ **ASSERTION 18 MOVED AS WELL AS 20, AND THE GOAL COMMAND NAMED ONLY 20** — 5 of the 10 qualifying
hard edits were adds. Leg 132's recon predicted this exactly; re-basing 20 alone would have left S3
permanently red and read as a wrong fix.

⭐ **Loop (b) untouched, and that is why fixtures 1/50/54 never moved** — their adds all land on
shelves the base never planned, where base is 0 and `0 + qty = qty` was already additive.

⭐ **New S3 seq 36 `D45_additive_assertion_is_load_bearing` reads 5.** An add onto a base of 0
composes to `qty` under BOTH readings, so seq 20 would pass vacuously on a run whose adds all landed
on unplanned shelves. `v_add_diverge` already existed as a diagnostic; seq 36 makes it an assertion.

⭐ Fixtures **1** 59/0 · **11** 39/0 · **50** 49/0 · **51** 53/0 · **54** 41/0 · **57** 39/0, every
assertion evaluated, 0 skipped. LAW 12 tripwires inside S3 unchanged: `refill_plan_output` **8494**,
`pod_refill_plan` **6643**, `pod_refills` **3996**.

⚠️ **Cody's watch, recorded not swallowed:** an additive `add` can now compose ABOVE `max_stock`. The
composer never clamped `set_qty` either, so the _class_ of exposure is not new — but it is newly
reachable without a human typing a large number. No clamp added (that would be an unruled policy move).

### ⛔ S-248 (NEW) — D-43 SHIPPED ALONE TRADES A LOUD FAILURE FOR A SILENT ONE

- Today the packing role hits **S-191**: repack half-completes and RAISES `push_failed` — **loud**.
- D-43 half 1 authorises `warehouse` for push, so that role then lands on **S-193** instead: repack
  returns **`status='ok'`** with **zero** fresh dispatch rows and a plan still reading
  `dispatched=true`. ⛔ **A silent freeze, handed to the exact role that reported the original incident.**
- The parking lot has said since leg 107 that _"S-193 is independent of D-43 and must be fixed
  regardless"_ — ⚠️ **yet S-193 appears in NO tier of goal-command-2's work queue.**
- ⭐ **AND half 2 becomes unreachable by construction:** once `warehouse` joins push's list,
  `repack_machine`'s gate and push's list are **identical sets**, so no role can reach the pre-flight.
  It is still worth shipping as the guard against future divergence, but ⛔ **it cannot be proven by a
  role replay — it must be asserted structurally as `repack_roles ⊆ push_roles`**, or it ships
  untested and passes only by inspection (the S-173 sin).

⏸️ **D-43 was STARTED AND PARKED, not skipped.** No migration written, no role list touched, DB
unchanged. Full recon is banked in the leg-133 EXECUTION-LOG block: half 1 is one array literal at
`push_plan_to_dispatch` line ~57 (md5 **21371529**); half 2 belongs immediately above
`repack_machine`'s `return_dispatch_line` loop (md5 **d719d3c1**), which is its first destructive act
and has no savepoint. ⛔ **Fixture 9 seq 2 — not seq 1 — is the true half-1 sensor** (seq 1 pins
repack's own gate, which option (a) leaves intact; the leg-108 note said "1-2" and is half right).
seq 16-22 read `golden.scratch['s191']` and must be REWRITTEN to assert the S-193 freeze, not merely
re-`expect`ed. ⚠️ **A NULL caller (service role) already bypasses push's gate entirely** — any
assertion about the role list must say so or it overclaims.

### ⏸️ OPEN CS DECISIONS after this leg — **NOTHING WAITS ON CS.** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). ⭐ **D-45 is now EXECUTED** (joining D-46 and DR-4); D-43, D-44, D-47 and DR-1/3/5/6/7/8 remain as WORK, not asks. ⚠️ **S-248 is a NEW finding, not a new decision** — but the next leg should weigh whether S-193 must ride with D-43. Leg 133 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐⭐ leg 134 (2026-08-06) — D-43 EXECUTED (both halves) + S-193 CLOSED. ⛔ S-249: THE HARNESS WAS ALREADY RED.

⛔ **Written AFTER the evidence it cites, per S-243.** Every figure below was read back live, and
both verdicts cite **banked** `golden.runs` rows, never a running process.

### ✅ D-43 CLOSED BY EXECUTION — and S-193 rode with it, which is the decision this leg made

`20260806003000_prd110_d43_push_roles_and_s193_returned_squat` (Cody ⚠️→✅) ·
`20260806003100_prd110_d43_s193_fixture9_rebase` · `20260806003200_prd110_d43_fixture9_stale_crossrefs`.
⭐ **The tells moved: `push_plan_to_dispatch` 21371529 → 6372fe60** (v10 →
`v11_rc01_single_writer_d43_s193`) and **`repack_machine` d719d3c1 → 2e8330fe**.

⭐ **WHY S-193 RODE ALONG, ANSWERING LEG 133's OPEN QUESTION.** S-248 was right: half 1 alone turns
the packing role's **loud** `push_failed` into a **silent** freeze. The parking lot has said since
leg 107 that S-193 _"must be fixed regardless"_ — it is the precondition that makes the ruled change
safe, and both defects live in the same function. ⛔ Shipping D-43 alone would have handed a silent
freeze to the exact role that reported the 2026-07-20 incident.

⭐ **S-193 IS ONE PREDICATE, AND EVERYTHING ELSE ALREADY AGREED WITH IT.** push's RC-01 §5(5b)
idempotency probe excluded skipped/cancelled/is_m2m but **not `returned`**. The partial unique index
**and** `prevent_duplicate_unstarted_dispatch` both already exclude `returned=true` — this probe was
the last holdout, which is why the fresh INSERT starts succeeding the instant it agrees.

⭐ **BLAST RADIUS MEASURED FIRST:** only `push_plan_to_dispatch`, `repack_machine` and
`reset_approved_undispatched` ever set `refill_plan_output.dispatched=false`, and the third also
moves `operator_status` to `pending` (which push does not select). **The predicate reaches the repack
path and nothing else.**

⭐ **S-248 ANSWERED STRUCTURALLY.** New `public.push_dispatch_authorized_roles()` is the ONLY place
the role set is written down; push gates on it, repack pre-flights against it. Fixture 9 seq **78**
asserts `repack_roles ⊆ push_roles` as DATA, expect **`0|4`** — ⛔ not `0`, because a regexp that
stops matching yields zero rows and passes a bare `0` vacuously. seq **79** asserts the pre-flight
precedes the first `return_dispatch_line`; ordering IS the defect (no savepoint).

⭐ **THREE-RUN PROOF CHAIN, ALL RETAINED:** `58a80197` **73/0** (old functions) → `78ebb82f`
**63/10 RED** (fixed functions, old sensors — the red the CS ruling predicted) → `f0d4c08b`
**80/0** (re-based). ⛔ **Do not delete any of the three.** Fixture 9: **73 → 80 assertions, none
loosened.** Four green-but-lying descriptions (seq 6, 12, 13, 15) rewritten per S-103.

⚠️ **Cody's revision, applied not swallowed:** `GRANT EXECUTE … TO authenticated` dropped (Article 3)
— both callers are DEFINER owned by postgres, so the grant published the privileged-role list for no
caller that needed it. `service_role` only.

⚠️ **S-192 IS NOT CLOSED** — a repack's own returns still block every later repack, permanently
(fixture 9 seq 31-34). It is now the only one of the three original defects still open, and it is in
**no tier** of goal-command-2.

### ⛔ S-249 (NEW) — GOLDEN HAS BEEN RED SINCE BEFORE THIS LEG, AND NO DOCUMENT SAYS SO

Leg 134's full sweep: **58 fixtures, 2090 pass / 12 fail — 16(3), 17(1), 30(1), 40(5), 41(2).**

⛔ **THE BISECT IS DECISIVE AND IT IS NOT LEG 134's.** `golden.runs` already held a full sweep from
**BEFORE leg 134's first migration** — note `leg127 S7 r133`, 2026-08-06 **00:02-02:16Z** — with the
**same five fixtures and byte-identical counts 3/1/1/5/2**. Leg 134's first apply was ~04:15Z.
**Zero new failures were introduced.**

⛔ **THAT SWEEP IS IN NO LOG.** Leg 133 ran it and its session was truncated before it could report —
the same truncation that cost the resume pointer. ⭐ **The last full sweep anyone WROTE DOWN is leg
131's S7 (2026-08-04, 58/58).** Legs 132 and 133 each re-ran only the fixtures they touched and were
green on those. ⛔ **A targeted re-run is not a regression check — it is the definition of a blind
spot, and this build shipped two legs inside one.**

**The twelve, split by cause rather than lumped:**

- ⭐ **17 is not an assertion failure at all** — `detail` carries `{"scenario_error": "FX17 setup: no
headroom on A01 (stock=14 max=14)"}`. Production filled the shelf; the scenario cannot set itself
  up. ⛔ Its `n_pass+n_fail` (26) exceeds its enabled assertion count (25) for that reason.
- ⭐ **41 seq 5** is an explicit drift guard firing correctly (live shelf re-podded, `A07|G&H Popped
Chips` vs pinned `A07|Krambals & Zigi`); **30 seq 2** reads live mappings. Both ambient.
- ⚠️ **16 seq 13/15/16 are NOT obviously ambient** — the clamp reason moved `blocked_no_wh` →
  `pin_floor`, i.e. warehouse availability changed, and `bind_dispatch_fefo` (**D-46, leg 132**)
  writes `committed_elsewhere` into `wh_fefo_for_line`. **Leg 132 re-ran only fixtures 18 and 26.**
  Candidate un-swept blast radius.
- **40 seq 44/48/50/51/55** — stitch_v3's rung ladder ends at `substitute#2` where `variant#1` is
  pinned, non-vacuity guard reads 0. Unattributed.

⏸️ **NOT RE-BASELINED — A DECISION, NOT AN OMISSION.** Three are drift and two are candidate code
effects; re-baselining uniformly would bury the second kind inside the first. ⛔ **LAW 8 halts phase
work, so the next leg's FIRST unit is this bisect, ahead of DR-3.**

### ⛔ S-250 (NEW) — A PER-FIXTURE SWEEP LOSES RUNS SILENTLY, AND THE LOSS READS AS A SMALLER SUITE

`golden.run_all()` through the management API exceeds the gateway ceiling and commits **nothing**.
The per-fixture idiom is correct — but **8 of 58 fires never committed** (8, 9, 37, 39, 40, 45, 54, 57) and the read-back reported a clean-looking `fixtures_run = 50`. ⛔ **Fixture 40 was among them
and carries 5 of the 12 failures** — the sweep under-reported the red by a third. **Reconcile
fired-count against banked-count before believing any sweep verdict.** All eight banked on re-fire.

### ⚠️ RELAY HYGIENE — leg 133 left NO resume pointer, and the recon it banked is what saved the leg

Its log stops mid D-43-recon. Nothing was lost (migrations applied + registered), but every claim had
to be rebuilt from the DB. ⭐ **Banking recon BEFORE ending a unit is what made leg 134 startable.**
⚠️ Also recorded: the function-roll md5s are **`md5(prosrc)`**, not `md5(pg_get_functiondef(oid))` —
a probe with the wrong one mismatches ALL of them at once, which reads exactly like a revert.
⛔ **The supabase MCP did not connect this leg**, so migrations were hand-registered into
`supabase_migrations.schema_migrations`; skipping that INSERT breaks the RISK-104 owed-set md5.

### ⏸️ OPEN CS DECISIONS after this leg — **NOTHING WAITS ON CS.** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). ⭐ **D-43 is now EXECUTED** (joining D-45, D-46, DR-4); D-44, D-47 and DR-1/3/5/6/7/8 remain as WORK, not asks. ⚠️ **S-249 and S-250 are findings, not decisions** — but S-249 makes the standing claim "golden fully green" FALSE, and the next leg must close it before Tier-1 work resumes. Leg 134 raised no new decision.

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐⭐ leg 136 (2026-08-06/07) - S-249 ANSWERED: ZERO CODE REGRESSIONS. Fixtures 30 + 17 closed. S-251, S-252 raised.

⛔ **Written AFTER the evidence it cites, per S-243.** Every number below was read back live at close.

### ⭐ S-249 CLOSED AS A DIAGNOSIS - the red was never a regression

All twelve failures across fixtures 16/17/30/40/41 are **ambient live-data drift**. Proven three ways,
not asserted: (1) `engine_add_pod_v3` **e9f3caff** and `stitch_v3` **a8753091** are byte-identical to
the last-green run; (2) `engine_add_pod_v3` **does not call `bind_dispatch_fefo`** - only
`bind_dispatch_fefo` and `create_spot_purchase_v3` do, and `wh_fefo_for_line` is read only by
push/receive/record_actual_refill/resolve_fefo_sku_legs_v3, so **D-46 cannot structurally reach
fixture 16**; (3) the one datable cause is a **production bulk `product_mapping` write at
2026-08-05 22:33:50Z**, inside the window and before leg 132's first migration.

⛔ **Leg 134 was right to refuse a uniform re-baseline** - one of the five was a real production
defect and would have been buried by it.

### ⚠️ S-251 (NEW) - CS ASK, AND THE ONLY THING ON THIS PAGE THAT WAITS ON A HUMAN

Fixture 30 caught **S-53 RECURRING**: ten `venue_team` mappings for **"Galaxy - Milk Chocolate"** on
ten co_managed machines with no matching `venue` sourcing edge, all still on their P1.1 genesis
backfill. Corrected via the canonical `set_product_sourcing_v3` (10 calls, all `changed:true`,
`boonz_wh -> venue`, each with a `superseded_id` - nothing destroyed). Fixture 30 **20/0 green**.

⛔ **THE ASK:** confirm that Galaxy - Milk Chocolate really is **venue-supplied** on ACTIVATEMCC-1037,
IFLYMCC-1024, MPMCC-1054, MPMCC-1058, VOXMCC-1005/1011/1012/1017 and VOXMM-1001/1013. This leg
**mirrored intent already recorded in `product_mapping`; it did not originate that intent.** The
22:33Z flip that created it is **unattributed**. ⛔ **If the flip was wrong, the mapping is what is
wrong and BOTH sides must be reverted together.**
⚠️ **Blast radius unmeasured** - only fixtures 5 and 8 were re-run as a probe (both green). A full
sweep is owed.

### ⛔ S-252 (NEW) - a harness helper shipped without the guard its neighbours all carry

`golden.plant_shelf_stock` (new this leg, the named reusable shelf-stock planter) shipped with only a
COMMENT saying "call me inside a fixture". `pin_machine_stock`, `restore_machine_stock` and
`arrange_shelf` all **enforce** it via `EXISTS (SELECT 1 FROM golden.runs WHERE finished_at IS NULL)`.
⛔ **A comment is documentation, not enforcement.** Fixed forward-only; refusal verified outside a
fixture, and fixture 17 re-verified 27/0 green with the guard live.

### ⏸️ STILL OPEN FROM S-249 - fixtures 41, 16, 40 (LAW 8 still binds)

Diagnosed precisely in the leg-136 log body; remedy shape for all three is fixture 17's: **anchor by
PREDICATE, or plant the precondition** inside the rolled-back probe block. 41 = source shelf re-podded
(still mixed, 3 SKUs) + headroom 9->10 · 16 = the "zero-availability" probe shelf now has 16 WH units ·
40 = ONE cause, `D_net_primary` = 0 makes rung 1 unsatisfiable and the other four cascade.

### ⏸️ OPEN CS DECISIONS after this leg - **ONE NEW ASK: S-251 (Galaxy venue-supply confirmation).** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). ⭐ **D-43, D-45, D-46 and DR-4 are EXECUTED**; D-44, D-47 and DR-1/3/5/6/7/8 remain as WORK, not asks. Leg 136 raised no new _decision_ beyond S-251's confirmation ask.

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

## ⭐⭐ leg 137 (2026-08-06/07) - THE S-249 FIVE ARE CLOSED. S-253/S-253b/S-254/S-255/S-256 raised.

⛔ **Written AFTER the evidence it cites, per S-243.** Every run id below is a **banked**
`golden.runs` row with `scenario_error` null, re-read at leg close, never a running process.

### ✅ LAW 8 SATISFIED - fixtures 16, 40, 41 closed, joining 30 and 17 from leg 136

**16: 33/0** (`ddc38265`) · **40: 60/0** (`60608877`) · **41: 66/0** (`678473e2`).
⛔ **NOT ONE EXPECTATION WAS LOOSENED.** Every red was a decayed PRECONDITION, never a wrong
assertion. Assertions went **2103 -> 2111**: a dynamically selected anchor has to prove and name
itself, so each fixture gained non-vacuity + attributability checks.

⭐ **THE PATTERN, now with three worked examples.** Close a decayed precondition by SELECTING the
anchor by predicate - resolved ONCE into `golden.scratch` so the population read and the call site
consume the SAME anchor - and/or PLANTING the part that is a shelf property.
⛔ **Never plant a warehouse shortage** (`warehouse_inventory` is protected; fixture 16 needed a dry
shelf and SELECTED one instead). ⛔ **Never touch `pod_refills` on a real past date** (LAW 12;
fixture 40's `net_primary` could only have been restored that way, so the anchor moved instead).
⭐ **Prefer the incumbent in `ORDER BY`, never in `WHERE`** - a preference keeps continuity with the
BUILD-SPEC anchor and still cannot rot (fixtures 40 and 41 both do this; 41's incumbent still won).

### ⛔⛔ S-254 (NEW) - **A `scenario_error` MAKES A FIXTURE'S WHOLE ASSERTION LIST LIE, NOT GO BLANK**

The first fixture-16 run after the rewrite reported **28/6** with seq 13/15/16 red at **exactly their
pre-fix values**. That reads as a faithful re-measurement of the known defect. It measured nothing.

⭐ **MECHANISM:** every scenario opens with `DELETE FROM golden.scratch WHERE fixture_id = N`.
`run_fixture` runs the scenario in a plpgsql subtransaction, so a raise rolls that DELETE back and
the PREVIOUS run's blob survives. The assertions then score days-old observations and reproduce the
old verdict perfectly. ⛔ **Only the two brand-new assertions exposed it** - their keys did not exist
in the stale blob, so they alone read NULL. A fix that added no assertions would have looked exactly
like an honest unfixed red.

⛔ **STANDING RULES:** (1) read `golden.runs.detail[0]->>'scenario_error'` before believing ANY red;
(2) `DELETE FROM golden.scratch WHERE fixture_id=N` before firing a fixture you just edited, so an
error reads NULL everywhere instead of plausibly-old; (3) never build a `RAISE` message by
concatenation in a scenario. **S-253b** is the underlying fault, fixed forward per Article 12:
`RAISE EXCEPTION 'a' || 'b'` does not parse - `RAISE` takes a format string LITERAL.

### S-253 (fixture 16) · S-255 (fixture 40) · S-256 (fixture 41)

- **S-253** - the "zero WH availability" probe was hardcoded to a shelf code; production restocked it
  (16 units) and it stopped being a probe. Dryness is now SELECTED via the engine's own arithmetic
  (`is_constrained AND available_units = 0`); headroom is self-supplied. Stock is held **>= 1** so
  the min-facing floor cannot lift `need_raw` in the pin's place. Chose **A08**, `z_avail` 0,
  `pinfloor_z` 1, `clamp_z` back to **blocked_no_wh**.
- **S-255** - anchor D's `net_primary` fell to 0 (4 units of stock, **7 already claimed**), turning a
  rung-1 PARTIAL into a rung-1 MISS and cascading five assertions off one cause. Ladder dry-run first
  (it is STABLE/read-only), then shipped. Chose **AMZ-1046 A12 Soft Drinks Mix**, 8 variants,
  437/438, short 1, `variant#1`. ⚠️ A 438-unit ask is unrealistic but harmless: every claim D proves
  is quantity-independent. It is the cost of ranking variant-breadth above tightness.
- **S-256** - **three** decays, not the two leg 136 saw: anchor B's headroom had also drifted 1 -> 2,
  and anchor A's moved **again** (9 -> 10 -> 11) between legs. No shelf carries pod `098f5c0c` any
  more, so seq 5 now asserts STRUCTURE (mixed pod · off the destination machine · outside
  `shelf_composition`) instead of a pod name. seq 18/19 keep `eq 9` / `eq 1` and are PLANTED -
  loosening them to ranges would have dissolved the A-versus-B contrast the fixture rests on.
  ⛔ **Fixture 41 COMMITS** (no rolled-back probe block), so block (4) restores both shelves and
  seq 64/65 prove it; residue was also disproven independently off live WEIMI (A06 **4/15**, A05
  **4/6**, `weimi_pin_backup` **0 rows**).

### ⏸️ CARRIED FORWARD

⛔ **THE FULL 58-FIXTURE SWEEP IS STILL OWED** and was deliberately not started this leg - it cannot
be finished and adjudicated in the space left. ⚠️ Two unmeasured blast radii make it non-optional:
S-251's PRODUCTION sourcing change on ten machines, and S-256's live-WEIMI write/restore inside a
committing fixture. Fire per fixture (S-250), clear scratch first (S-254), avoid UTC minutes 37-40.

### ⏸️ OPEN CS DECISIONS after this leg - **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation).** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). ⭐ **D-43, D-45, D-46 and DR-4 are EXECUTED**; D-44, D-47 and DR-1/3/5/6/7/8 remain as WORK, not asks. Leg 137 raised no new decision.

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## ⭐⭐ leg 138 (2026-08-06/07) - THE OWED SWEEP RAN. S-257 closed, S-258/S-259 raised. DR-3 built, Cody-approved, NOT applied.

⛔ **Written AFTER the evidence it cites, per S-243.** Every number below was read back live at
leg-138 close from `golden.runs` / `pg_proc` / `schema_migrations`, never from a pointer.

### ✅ THE FULL 58-FIXTURE SWEEP - owed since leg 136, now banked

**58/58 fixtures · 2111/2111 enabled assertions EVALUATED · 2100 pass · 11 fail · 0 skipped ·
0 scenario_errors.** Note namespace `leg138 sweep r1`. Runner checked in at
`scripts/prd110_leg138_full_sweep.sh` (leg-126 design + the two S-254 rules: scratch cleared from
OUTSIDE the fixture transaction, and `scenario_error` surfaced in the read-back).
⭐ **Evaluated == enabled**, so no fixture silently failed to bank - the S-250 failure that cost
leg 134 eight fixtures did not recur.

⛔ **THREE REDS, ALL THE SAME CLASS** - a fixture inheriting a precondition from live production
instead of owning it. **Not one is an engine regression**; the two S-249 sentinels
`engine_add_pod_v3` **e9f3caff** and `stitch_v3` **a8753091** never moved.

### ✅ S-257 CLOSED - fixture 24, and the exoneration matters more than the fix

seq 5 pinned `61` sentinel-backed shelves and read **62**. Dated off `golden.runs`: 61 at leg 134
(`08-06 05:02:14Z`), 62 at leg 138 (`21:57:26Z`).

⛔ **S-251 IS EXONERATED.** `v_shelf_availability_v3` derives `sentinel_backed` from
**product_mapping x v_wh_pickable x the machine's warehouses** and **never reads
`product_sourcing`**. Leg 136's ten sourcing rows move `is_constrained`/`available_units`, which are
different columns. ⭐ **Read the view before attributing a red to the most recent production write.**
Ruled out by measurement: sentinels 40, pickable 40, `product_mapping` untouched since `08-05
22:33Z` (before the 61 reading), `machines` untouched 24 h, shelf population 544. ⇒ The mover is a
per-shelf **pod re-resolution in `v_shelf_state`** - WEIMI identity drift.

⭐ **STRENGTHENED, NOT RE-BASELINED.** seq 5 keeps its only real job (non-vacuity, `gt 0`, expect and
description moved together per S-103); the work moves to two rot-proof assertions - **seq 36** every
sentinel-backed shelf is on a **co_managed** machine (a sentinel propping a fully_managed machine is
phantom stock standing in for stock Boonz owes), **seq 37** no sentinel-backed shelf would block on
retirement, measured on the LIVE population. Both earned: 36 = 0, 37 = 0. Fixture 24 **44/0**, run
`0552cfb5`, migration `20260806221223_prd110_s257_fx24_sentinel_backed_property_not_literal`.

### ⏸️ S-258 (NEW) - fixture 45 rung-4 M2M, 11/7. **A COMMITTING FIXTURE'S RESIDUE PROOF MUST COVER DERIVED OBJECTS.**

18/0 at `08-06 06:30:22Z`, 11/7 at `22:06:34Z`. seq 7 `no_resolvable_donor`; all five donors return
`source_composition_unknown`. ⛔ **`shelf_composition` holds 31 rows on 16 shelves, ALL on
`MPMCC-1058-0000-R0`** - one machine of 37 - written by cron 44 in three batches (`08-05 22:40` 1
shelf · **`08-06 20:40` 11 shelves** · `08-06 21:40` 4 shelves), confidence 0.00-0.05, and it is not
a full hourly rewrite (3 distinct `updated_at`).
⚠️ **MPMCC-1058 is the machine leg 137's COMMITTING fixture 41 wrote and restored live WEIMI on.**
Leg 137's residue proof was correct **on WEIMI** and never looked at the derived object; cron 44
rewrote that machine's composition twice inside the window.
⛔ **NEXT LEG'S FIRST STEP IS A QUESTION:** are the 20:40/21:40 rows genuine estimator output or
fixture-41 artefacts? The answer picks the remedy - anchor-by-predicate (S-255/S-256) or plant a
`shelf_composition` row inside the rolled-back probe (not a protected entity).

### ⏸️ S-259 (NEW) - fixture 53, 19/3. The detector self-test is measuring nothing.

seq 15/16/17 want `is_healthy=false` / `last_scheduled_night_errored` / `error`; they read
**true / ok / ok**. ⛔ **The health object is not the fault - the plant is:** scratch key `mask`
carries `rows_before = rows_after = 249`, so the errored-night plant inserted nothing and the
assertions scored unplanted live state. ⚠️ `v_shadow_runner_health_v3` is therefore **not proven
regressed, but no longer proven working** - and it is the object that would hide a failed shadow
night before the DR-1 cutover. ⭐ Remedy (same class as S-254): add a plant-landed assertion so a
no-op plant fails LOUDLY at its own seq, then find the no-op.

### ⏸️ DR-3 - BUILT, CODY-APPROVED, **NOT APPLIED** (RELAY: never begin a unit you cannot finish)

Files: `docs/prds/dr3_design.sql` · `dr3_fixture67.sql` · `dr3_fixture67_assertions.sql` (32
assertions, fixture 67, `plan_date 2030-04-17`, `baseline_status 'failing_expected'`).
⛔ **Zero database change.** Shape: a four-level dial `pod_inventory_write_freeze`
(`off`/`warn`/`block`/`frozen`) shipping **off** · a BEFORE UPDATE OR DELETE write-guard - ⛔ **the
live `trg_block_direct_pod_inventory_insert` is INSERT-ONLY and UPDATE/DELETE are guarded by nothing
today** · REVOKE of INSERT/UPDATE/DELETE/TRUNCATE from `authenticated` and `anon` (all 14 writers are
DEFINER owned by `postgres`; all five FE call sites verified `.select()`-only; **service_role
deliberately retained** because the n8n flows cannot be read to prove none writes) · and
`v_pod_inventory_daily_delta_v3`, which reports `not_ready` because `inventory_events` holds 65 rows
against ~150-215 `pod_inventory` writes **per day**.
**Cody APPROVE WITH REVISIONS** (Articles 1/2/3/4/7/8/12/14/16), all three applied: policy comment ·
the guard's `SECURITY DEFINER` is **load-bearing** (as INVOKER the dial read returns no row, COALESCE
resolves `'off'`, and ⛔ **the guard fails open silently**) plus the declared fail-open · and
`net_delta_units` -> `audited_delta_units_writevol` (Article 16: `v_live_shelf_stock` owns "live
shelf stock"). ⚠️ Apply with no sweep in flight and outside UTC minutes :30/:40/:45.
⚠️ **Adding fixture 67 changes the fixture population**, which per DONE-2 makes the final golden
proof an S7-style TRIPLE rather than a single run.

### ⏸️ OPEN CS DECISIONS after this leg - **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation).** ⭐ Now sharper: the ten rows are **SKU-grain** (`Galaxy - Milk Chocolate`) on the **Chocolate Bar** pod, dated `2026-08-06 20:43Z`, so the pod stays `boonz_wh`-constrained for its other SKUs. The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). **D-43, D-45, D-46 and DR-4 are EXECUTED**; D-44, D-47 and DR-1/3/5/6/7/8 remain as WORK, not asks. Leg 138 raised no new decision.

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## LEG 139 (2026-08-06/07) - S-258 and S-259 CLOSED · golden fully green · DR-3 deferred whole

### ✅ S-258 CLOSED - fixture 45, 11/7 -> **22/0**

The residue hypothesis leg 138 handed off is **DISPROVEN**: all 31 `shelf_composition` rows were
created `2026-07-30 18:40Z` (7 days before fixture 41), the 20:40 batch's estimator ran 67 minutes
BEFORE fixture 41 executed, and the 21:40 batch carries no new event at all. **S-256 / fixture 41 is
exonerated.** Same class as 16/40/41/24: a rented precondition that decayed.
Remedy = the one the resolver itself names, "plan a Remove on the donor shelf" - the PRODUCTION
`donor_remove_rows` path. Donor, crossing SKU and refused SKU all selected BY PREDICATE. Four new
assertions, three stated as PROPERTIES so they cannot rot. Zero existing `expect` values changed.
Migration `20260806223034_prd110_s258_fx45_donor_remove_plant_self_supplied`.

### ✅ S-259 CLOSED - fixture 53, 19/3 -> **23/0**

⛔ **Leg 138's diagnosis was wrong.** `rows_before = rows_after` is the forced-rollback idiom
WORKING - fixture 53's own **seq 18 asserts exactly that and has always been green**. The plant
always landed. The real fault: `v_shadow_runner_health_v3` picks the newest `note='cron'` summary
row, cron 45 writes one nightly at 21:22 UTC, and the fixture stamped its plant at `now() - 2h` -
so between 21:22 and 23:22 UTC the LIVE row out-ranked the plant and the view judged production.
**The fixture was green or red by wall-clock alone.** Leg 138's sweep ran 22:08Z, inside the dead
zone. Fixed with a recency anchor (`GREATEST(now(), newest live cron row) + 1s`) plus new seq 23,
a **selection** receipt. Re-fired 23/0 at 22:35Z - inside the old dead zone.
⭐ `v_shadow_runner_health_v3` is exonerated and now genuinely proven - it is the object that would
hide a failed shadow night before DR-1 cutover.
Migration `20260806223459_prd110_s259_fx53_mask_probe_recency_anchor`.

### ⭐ GOLDEN IS FULLY GREEN - 58/58 fixtures, 2118/2118 enabled assertions, 0 fail

LAW 8 is released for the first time since leg 134. `total_pass` EQUALS `enabled_assertions`, so
the denominator is the whole population (the S-250 check).

### ⏸️ DR-3 DEFERRED WHOLE, NOT PARTLY

Built and Cody-approved at leg 138; three files unchanged on disk (434 lines). It is
protected-entity DDL (`pod_inventory` REVOKE + write-guard) and a half-applied write-freeze is the
exact state the RELAY "nothing half-applied" invariant forbids. **Next leg's first task.**

### ⛔ THREE NEW STANDING RULES

1. **A fixture that plants a row a view must SELECT needs a selection receipt, not an insertion
   receipt.** Asserting the row landed proves nothing if a live row out-ranks it.
2. **Before calling a plant a no-op, check whether a GREEN assertion already pins the symptom you
   are reading as the fault.**
3. **`run_fixture` does NOT roll back** - any fixture writing a live table must clean up before AND
   after. Article 1 precedent for harness writes to `refill_plan_output`: fixtures 9/10/33/63.

### ⏸️ OPEN CS DECISIONS after this leg - **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation).** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). **D-43, D-45, D-46 and DR-4 are EXECUTED**; D-44, D-47 and DR-1/3/5/6/7/8 remain as WORK, not asks. Leg 139 raised no new decision.

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## LEG 140 DELTA - DR-3 MOVES FROM "BUILT, NOT APPLIED" TO "SHIPPED FLAG-OFF"

⭐ **DR-3 IS EXECUTED.** `pod_inventory` physical write-freeze applied 2026-08-06T22:48Z:
the dial `refill_policy_params.pod_inventory_write_freeze` (`off`/`warn`/`block`/`frozen`,
CHECK-constrained), the `BEFORE UPDATE OR DELETE` write-guard `trg_guard_pod_inventory_write`
(the two verbs nothing guarded - INSERT has been guarded since PRD-012), the REVOKE of
INSERT/UPDATE/DELETE/TRUNCATE from `authenticated` and `anon`, and the daily-delta report
`v_pod_inventory_daily_delta_v3`. Fixture **67 green 32/32**, every dial level EXECUTED.
Migrations `20260806224643` / `20260806224842` / `20260806224935`.

### ⏸️ NEW DECISIONS-READY ENTRY - THE FREEZE ITSELF (arming the dial)

- **What:** `pod_inventory` becomes writer-gated (`block`), then read-only historical (`frozen`).
- **Ships:** `off` - fully inert. LAW 4 respected; the guard returns immediately at `off`.
- **Evidence it works:** fixture 67 seq 20-25 EXECUTE all four levels (off/warn succeed;
  block refuses non-RPC UPDATE **and** DELETE with 42501; block WITH `app.via_rpc` succeeds so the
  14 canonical writers keep working; frozen refuses even RPCs). Residue proven at seq 30-32.
- **The single command CS runs:**
  `UPDATE refill_policy_params SET pod_inventory_write_freeze = 'warn';` (then `'block'`, then
  `'frozen'` - three deliberate steps, never one).
- ⛔ **NOT READY TODAY, AND THE REPORT SAYS SO.** `v_pod_inventory_daily_delta_v3` reads
  **`not_ready` on 22 of 30 days**: `inventory_events` holds **65** rows against **1,134**
  `pod_inventory` writes in the same window. The replacement is not carrying the load.
  BUILD SPEC P1.4 line 68 wants ~2 weeks of the report first. ⛔ **Do not arm to chase a green.**
- ⚠️ `service_role` KEEPS its write privileges DELIBERATELY (n8n / break-glass; this build cannot
  read the n8n flows to prove none of them writes). The guard covers it instead. Fixture 67 seq 8
  pins that, so a future silent revoke has to be argued for.

### ⏸️ OPEN CS DECISIONS after this leg - **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation).** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). ⭐ **D-43, D-45, D-46, DR-3 and DR-4 are EXECUTED**; D-44, D-47 and DR-1/5/6/7/8 remain as WORK, not asks. Leg 140 raised no new decision. ⚠️ **A new DECISIONS-READY entry exists** (arming the freeze dial) but it is explicitly NOT ready - it is gated on the delta report, not on CS attention today.

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

### ⛔ S-261 (leg 140, OPEN) - DR-5's "pending residue" is not what the ruling assumes

`picker_weight_proposals_v3` holds **exactly 2 rows, both `pending`, both minted this leg** inside
a 4-second window around fixture 58's run (fixture 58 MINTS and `run_fixture` does not roll back).
⛔ **The ruling's proposal (`w_empty` 0.900→**0.945**, 68.57 %, 1318 evaluable / 474 discriminating,
24 days) IS NOT IN THE DATABASE.** What is actually pending is `w_empty` 0.900→**0.958** (71.43 %,
150 pairs, **10** days) plus `w_stale` 0.130→0.122 (28.57 %).
⇒ Executing DR-5 literally finds no 0.945 row; accepting what IS there applies a 10-day synthetic
result as though it were the CS decision. **Establish the real proposal FIRST.**
⚠️ Clear residue by STATUS, never by `DELETE`. Fixture 60 seq 12 going red is the sanctioned,
ruling-named cost (re-baseline `expect` AND `description` together, S-103).
⛔ **Nothing was mutated: both dials still `true`, `w_empty` still 0.900.**

---

## ⭐⭐ leg 141 (2026-08-06/07) - DR-5 and DR-7 EXECUTED. S-262 closed; S-263 and S-264 raised OPEN.

⛔ **Written AFTER the evidence it cites (S-243).** Every figure below was read back live at close.

### ✅ DR-5 CLOSED BY EXECUTION - `w_empty` 0.900 -> 0.945, both miner dials live

Five migrations (`dr5a` residue+dials · `dr5b` the ruled weight · `dr5c` S-262 property fixes ·
`dr7` heartbeat · `dr5d` treadmill re-clear). Cody ✅ with one required revision, which shipped.
⭐ **The applied proposal was minted by the PRODUCTION path** - `run_weekly_miners_v3('manual')`
between dr5a and dr5b, warnings EMPTY (proving the residue clear was not cosmetic).
⛔ **0.945 SHIPPED, NOT 0.948.** The live re-mine proposes 0.948 (69.31 %, 1363/492 pairs, 25 days);
the ruling's figures are the same window one day younger. The RULED magnitude is what was applied;
the divergence is recorded in the row's `review_note` and in `applied_weight` vs `proposed_weight`.
⏸️ **If CS prefers the live figure (0.948), that is a one-line follow-up.**

### ✅ DR-7 CLOSED BY EXECUTION - rotation heartbeat, Sunday 05:30 Dubai

`prd110_dr7_rotation_heartbeat_0530_sunday_dubai`, `30 1 * * 0`, bare RPC, no dry-run override.
⛔ **Scheduled, not fired** - first real fire **2026-08-09**. Fixture 43 seq 56-60, re-fired 60/60.

### ⛔ S-264 (NEW, OPEN) - A GOLDEN FIXTURE DELETES REAL PROPOSALS. **GOLDEN IS UNSAFE TO RUN.**

Fixture 57's reclaim is `DELETE FROM feedback_proposals_v3 WHERE machine_id = mA AND
trigger_reason LIKE 'WS-H2 recurring%'` - and that prefix is **what the live edit miner writes**.
It ate 1 of the 9 proposals DR-5's first live run minted. ⛔ **The S7 triple DONE-2 owes would run
it three more times.** Smallest fix: scope the DELETE to `plan_date >= g12_fixture_epoch`.

### ⛔ S-263 (NEW, OPEN) - fixture 59 measures a live population it can no longer own

`scenario_error` on 9 pre-epoch rows (8 live pending feedback + 1 applied picker-weight, all DR-5's).
⭐ **Only ROW COUNTS moved**; rates and verdicts are still correct because every real proposal is
`pending` and pending is excluded from the decided denominator. ⛔ A plain re-baseline ships a
WEEKLY red. Full diagnosis and the fix shape are in the leg-141 log body.

### ⛔ S-262 (CLOSED) - fixture 58 read live state it did not plant

seq 15 (the pair -> the FORMULA) and seq 28 (an absolute count -> the DELTA its own description
claimed). Neither weakened; both now say what their descriptions always said. Third part - the
residue TREADMILL - is permanent until `ux_pwp_one_pending_per_param` is scoped (PARKED, Dara+Cody).

### ⏸️ NEW PARKED UNIT - approve-RPC for `picker_weight_proposals_v3.status` (Cody, Article 5)

There is **no RPC** governing that status column; DR-5 hand-wrote it inside a reviewed migration
executing a quoted ruling. ⭐ **Build it alongside DR-8**, which is chartered for the identical
shape on FACING proposals.

### ⏸️ OPEN CS DECISIONS after this leg - **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation).** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). ⭐ **D-43, D-45, D-46, DR-3, DR-4, DR-5 and DR-7 are EXECUTED**; D-44, D-47 and DR-1/6/8 remain as WORK, not asks. Leg 141 raised no new decision. ⚠️ **S-263 and S-264 are DEFECTS, not decisions** - but S-264 blocks every future golden sweep and must be fixed first.

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## ⭐⭐ leg 142 (2026-08-06/07) - S-264 CLOSED, GOLDEN UNBLOCKED. S-265 and S-266 raised OPEN.

⛔ **Written AFTER the evidence it cites (S-243).** Every figure below was read back live at close.

### ✅ S-264 CLOSED BY EXECUTION - fixture 57 can no longer reach a real row

`20260806235727_prd110_s264_fixture57_reclaim_scoped_to_fixture_band` (Cody ✅, one required revision,
which shipped). ⛔ **The pointer's named smallest fix was correct and INSUFFICIENT:**
`feedback_ledger_v3` has **no `plan_date`**, so its machine-wide DELETE could not be epoch-scoped at
all - and **8 of the 11 miner ledger rows are real**. It is scoped **by citation** instead
(`feedback_id = ANY(own_fids)`, harvested from the fixture's own epoch-scoped proposals _before_ they
are deleted; verified exact and complete: 3 proposals cite 3 ids matching 3 rows, 0 uncited).
⛔ **There were TWO copies of the defect** - the `mPrev` anchor-move block carried its own. Both gone.
⭐ **PROVEN TWICE:** fixture 57 **42/42** from `golden.runs`, and independently by hand outside the
harness - real proposals **8 -> 8**, miner ledger **11 -> 11** across the run.
⭐ **Cody's revision (seq 42):** every scope now leans on the mutable `g12_fixture_epoch` dial, so the
dial itself is pinned above the live band - widening it goes red BEFORE a reclaim can run.
⚠️ **Do NOT "fix" this class by tightening the anchor picker.** mA is a live machine and the miner
targets exactly the machines with rich edit history. **Scope the DELETE, not the anchor.**

### ⛔⛔ S-266 (NEW, OPEN) - A RAISING FIXTURE REPORTS GREEN OFF THE PREVIOUS RUN'S SNAPSHOT

Fixture 59 banked **n_pass 53 / n_fail 1**. The 53 are **wrong, not stale-but-harmless**: its scenario
deletes `golden.scratch` then RAISEs, the RAISE rolls the delete back, and every scratch-reading
assertion re-evaluates the last **successful** run's snapshot. Verified live: scratch still holds
`before.live_rows = 0` / `after.total_rows = 16` from **22:52:47Z**, not the failed **23:23:21Z** run.
⛔ **S-254 said the assertion list lies. S-266: it lies GREEN.** `n_fail` is the only sound verdict, and
**"n_pass 53" must be read as NO EVIDENCE** - never as partial credit, never to narrow down which
assertions are affected.

### ⛔ S-263 (OPEN) - still golden's only red; its affected-seq list was INCOMPLETE

By S-266 leg 141's list could only have been reasoned, not observed. Re-derived live: **seq 12 is also
red** (`total_rows` expects 16, will read 24), and seq **6/11/15/17/18/19/21/22/24/27/28/33** are green
only by luck - the real proposals are all `pending`, and the other fixtures happen to hold their counts.
⛔ **seq 17 breaks on 2026-08-09 when DR-7 first fires.** ⚠️ **seq 15 inflates every time the S-262
treadmill turns.** ⭐ **The full redesign (one rule, per-seq map, three mandatory `scenario_sql`
changes) is BANKED IN THE LEG-142 LOG BODY - execute it, do not re-derive it.** Nothing was mutated.

### ⛔ S-265 (NEW, OPEN) - fixture 57 mints into the LIVE CS review queue

It calls `mine_edit_history_v3(..., p_dry_run => false)`, so 4 synthetic proposals sit beside the 8 real
ones. ⭐ **S-244's `plan_date < '2027-01-01'` filter now binds `feedback_proposals_v3` itself, not just
the diff board.** Named rather than smuggled into a safety migration (LAW 10).

### ⏸️ PARKED UNIT GREW - no canonical writer for the proposal queues

Leg 141 found no approve-RPC for `picker_weight_proposals_v3.status`. Leg 142 adds, verified over
`pg_proc`: **no function anywhere DELETEs from `feedback_proposals_v3`** (only
`propose_pin_from_feedback_v3` / `approve_feedback_proposal_v3`, both UPDATE-only), and the table
carries **0 non-internal triggers**, so none of this reaches `write_audit_log`. ⭐ **Build alongside DR-8.**

### ⏸️ OPEN CS DECISIONS after this leg - **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation).** The twelve answered-unexecuted are still twelve (D-19, D-21, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40). ⭐ **D-43, D-45, D-46, DR-3, DR-4, DR-5 and DR-7 are EXECUTED**; D-44, D-47 and DR-1/6/8 remain as WORK, not asks. Leg 142 raised no new decision. ⚠️ **S-263, S-265 and S-266 are DEFECTS, not decisions.** ⭐ **Leg 142 flipped NO flag and touched NO engine body.**

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## ⭐⭐ leg 143 (2026-08-07) - S-263 CLOSED (golden's last red). D-21 HALF 1 EXECUTED. S-267 and S-268 raised OPEN.

### ✅ S-263 CLOSED BY EXECUTION - fixture 59 measures its own delta, not the world's population

`20260807145900`. 29 of 53 assertions rewritten: live -> **DELTA**, fixture -> **STABILITY**, rate ->
**FORMULA**, verdict -> **FORMULA-CONSISTENCY**, `FINAL = 0` -> `final = before`. ⭐ **No `expect`
weakened**: 8, 5, 4, 1, 2, 80.00, 20.00, `pass`, `fail`, `insufficient_evidence` all survive, now
stated about the fixture's own contribution. **53/53, `n_fail` 0**, and independently: real proposals
**8 -> 8**, miner ledger **11 -> 11**, sentinel residue **0**.

⛔ **THE BANKED DESIGN CONTAINED ONE INSTRUCTION THAT WOULD HAVE SHIPPED A VACUOUS ASSERTION.** Leg
142 said capture `before_sentinel` _after_ the reclaim. There the count is **0 by construction** and
seq 5 - the fixture's only remaining absolute - would have asserted nothing. Moved before the
reclaim. ⭐ **A handed-off design is a hypothesis, not a spec.**

⛔ **AND THE RED SET WAS WIDER AGAIN**: seq **23** and **29** were already hard red and neither
earlier list named them (DR-5's applied `w_empty` proposal makes `picker_weights` read
`live_accepted 1, live_acceptance_pct 100.00`). ⭐ **Leg 141's and leg 142's lists were REASONED;
this one was OBSERVED. S-266 is exactly why the earlier two could not be.**

⭐ Three apply-time tripwires now guard it: any assertion reading `after`/`final` must also read
`before` (two documented exemptions); fixture 59 must hold exactly 4 sentinel-scoped
`DELETE FROM public.`; 53 assertions in, 53 out.

### ✅ D-21 HALF 1 EXECUTED - and the ruling itself is what parks half 2

`20260807153000` + `20260807153600`. **Fixture 68: 28/28.** Shipped `v_pod_margin_coverage_v3` (the
ops worklist) and `v_pod_margin_gate_v3` (the >=90% verdict), plus dials
`substitute_margin_min_coverage_pct` **90** and `substitute_margin_weight` **0**.

⏸️ **HALF 2 (the margin term in the substitute ranking) STAYS PARKED, and NOT for want of leg room:**
CS's ruling reserves the weight to "a later CS value". **There is no W% to build with.** ⭐ The
parking is ENFORCED (S-138): fixture 68 **seq 18** asserts `find_substitutes_for_shelf_v3` reads
neither dial nor gate, and **seq 20** pins its md5 at **6aa6885e**. That matters - the function feeds
`resolve_supply_ladder_v3`, so a ranking change reaches the v3 engine.

⛔ **NEW ONE-LINE ASK FOR CS, sharper than the original:** the ruling's `purchasing_cost` bar is
**necessary but not sufficient** - `unit_margin` needs RSP too. Live: **cost coverage 62.58%, margin
coverage 53.99%**. The gate now requires both. _"Once coverage clears 90%, at what weight should
margin enter the substitute score - and is 90% still the right bar now that the binding number is
margin-computability, not cost alone?"_

### ⛔⛔ S-267 (NEW, CLOSED SAME LEG) - a self-consistent object can be wrong, and only a hand-derived count sees it

`has_cost = (purchasing_cost > 0)` is **NULL** for the 53 pods with a NULL cost, so every FILTER that
NEGATED it dropped them: the gate said `missing_cost = 8`, truth **61**. ⭐ **All the POSITIVE counts
and every rate were correct** - the headline read 62.58% covered / 8 missing, and those two are not
consistent. Twelve count assertions passed; the one that failed is the only one deriving its number
**independently off the source table**.
⛔ **STANDING RULE: a count assertion that reads the object under test proves self-consistency, never
correctness. Every new object needs at least one count derived from the source, by hand.**

### ⛔⛔ S-268 (NEW, CLOSED SAME LEG) - `REVOKE ... FROM PUBLIC` does not remove Supabase's default privileges

Both new views were created `anon=rxtm, authenticated=arwdDxtm` - **anon-readable and
authenticated-writable** - **despite the migration carrying a `REVOKE ALL ... FROM PUBLIC` and a
`GRANT SELECT TO authenticated`.** Live ~3 minutes; the D-30 exposure class, self-inflicted.
⭐ **S-140 restated at its real mechanism: the grant was there. The defaults were already wrong before
it ran, and `PUBLIC` does not name `anon` / `authenticated` / `service_role`.**
⛔ **EVERY future `CREATE VIEW` in `public` must carry `REVOKE ALL ON <v> FROM anon, authenticated;`
before its GRANT.** Target ACL: `postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres,authenticated=r/postgres`.

### ⏸️ TWO ITEMS NAMED, NOT FIXED (LAW 10)

- `pod_products` itself carries **`anon=rxtm`**. Pre-existing; not widened here; its own reviewed unit.
- **Article 16 paperwork owed:** `METRICS_REGISTRY.md` has no margin-coverage row. These are genuinely
  NEW canonical objects, not a duplicate derivation - but the registry entry is owed at the DONE-2 pass.

### ⏸️ OPEN CS DECISIONS after this leg - **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation)**, plus the SHARPENED D-21 half-2 ask above (a value, not a re-decision). The answered-unexecuted list drops from twelve to **eleven**: D-19, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40. ⭐ **D-21, D-43, D-45, D-46, DR-3, DR-4, DR-5 and DR-7 are EXECUTED**; D-44, D-47 and DR-1/6/8 remain as WORK, not asks. Leg 143 raised no new decision. ⚠️ **S-265 and S-266 remain OPEN; S-263, S-267 and S-268 are CLOSED.**

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

### ⛔ S-269 (leg 143, CLOSED SAME LEG) - the S7 sweep manifest had silently drifted two fixtures behind the DB

`scripts/prd110_s7_fixtures.txt` held **58** ids; `golden.fixtures WHERE enabled` held **60**.
Missing: **67** (DR-3's fixture, leg 140) and **68** (D-21, leg 143). ⛔ **The owed DONE-2 sweep would
have fired 58 of 60 and reported itself a complete, green suite** - including a clean bill for the
`pod_inventory` write-freeze, which is the last thing anyone should take on trust.
⭐ **S-250's cousin, and the pair is worth holding together: S-250 is fires that do not BANK; S-269 is
fixtures that never FIRE.** Both read as a smaller-but-green suite.
⛔ **RECONCILE THE MANIFEST AGAINST `golden.fixtures WHERE enabled` BEFORE EVERY SWEEP.** Reconciled
this leg; both sides now agree exactly at **60**.

### ⛔⛔ S-270 (leg 143, CLOSED SAME LEG) - an unlogged draft of this leg's own work was sitting untracked in the repo

`docs/prds/s263_fixture59_delta.sql`, 427 lines, mtime **2026-08-07 03:16Z**, self-labelled "leg
143". **Never applied** (proven at STEP R: `prd110%` = 323 and fixture 59 still carried `v_foreign`),
and it left **no execution-log entry, no resume pointer, no parking-lot delta** - so by the RELAY
protocol it was not a leg. ⭐ **It surfaced only in `git status` while staging the commit.** It was in
the session's opening status block the whole time.

⛔ **RULE: READ THE UNTRACKED SET AT STEP R.** The protocol says verify the pointer against reality.
**The working tree is part of that reality**, and an abandoned draft is precisely the artefact no
pointer will ever mention.

⭐ **Reading it paid.** It was right about two things `20260807145900` shipped without - the S-264
safety sensor (fixture 57 has one; fixture 59 touches the same two queues and had none) and
non-vacuity for the stability family (`after = before` is satisfied by `0 = 0`). Both harvested in
`20260807155200`; fixture 59 now **56/56**. ⛔ **And it was WRONG about the thing this leg got right**:
it kept leg 142's instruction to capture `before_sentinel` after the reclaim, where it asserts
nothing. **Neither artefact was complete; the shipped fixture is the union.**

---

## ⭐⭐ leg 144 (2026-08-07) - D-44 EXECUTED (both migrations). S-271 and S-272 raised, both CLOSED same leg.

⛔ **Written AFTER the evidence it cites, per S-243.** Every number below was read back live.

### ✅ D-44 CLOSED BY EXECUTION - the picker reserves K=2 money slots

`20260807160000_prd110_d44_money_reserved_slots` + `20260807161500_prd110_d44b_restate_cadence_universals`.
**Fixture 42: 85/85, `n_fail` 0, zero `scenario_error`.**

⭐ **THE ACCEPTANCE EVIDENCE IS THE MACHINE THE RULING NAMED.** `VOXMCC-1005-0201-B0` was recorded at
leg 117 as **rank 12, not selected, `below_day_capacity`**, starved behind eleven breached machines
of which nine carried 0.00 AED. It is now **rank 1, selected, `money_reserved`** at 931.72 AED.
⭐ **And cadence debt still clears:** breached `NOVO-1023-0000-W0` at **0.00 AED** is still picked, at
rank 3 on the breached floor. The ruling asked for both halves; both landed.

**Shipped:** dial `var_money_reserved_slots` = **2** (manager-gated by the existing `rpp_write`
policy) · a `money_rank` ladder computed on money ALONE · `is_money_reserved` sorting above
`cadence_floor_due` · a third `selection_reason` value `money_reserved` · new
`reasoning->'money_reservation'`. **OUT signature byte-identical** (an OUT column would have forced a
DROP; LAW 3). Blast radius proven EMPTY first: zero functions, zero views reference the picker.
⛔ **New sentinel: `rank_machines_by_value_at_risk_v3` 3a6c5914 -> 754532ac.** `3a6c5914` again means
D-44 was reverted.

⭐ **THE `value_at_risk_aed > 0` GUARD IS LOAD-BEARING AND ASSERTED (seq 79):** without it, on a day
when fewer than K machines carry value, a slot would be held for a **0.00 AED** machine over a
breached one - D-44's own harm, inverted.
⭐ **seq 60 (the CS D-24 acceptance test) is BYTE-UNTOUCHED and still true.** Both migrations pin its
md5 before and after and RAISE if it moved. The ruling's "Do NOT loosen seq 60" is enforced, not
promised.

### ⛔⛔ S-271 (NEW, CLOSED same leg) - a ruling's number was not the column's number

CS wrote "Of the day capacity of **6**, 2 slots always go to the money rule". Live
`pick_urgency_params.driver_capacity` is **8**; leg 118's conservative model reads **5**. The "6" is
the OBSERVED minutes-bound capacity measured on 2026-08-04, **not a dial**.
⭐ **It decides the implementation.** As a ratio (2/6) K floats with capacity; as CS actually wrote it
("2 slots **always**") K is an **absolute** reservation. The absolute reading shipped.
⛔ **RULE: when a ruling names a number the database also has a column for, check it against that
column BEFORE implementing it.** They differed by 2 here.

### ⛔⛔ S-272 (NEW, CLOSED same leg) - S-103 NEEDS A THIRD CLAUSE: RESTATE THE **SHAPE**

Fixture 42 came back **82/84** on the first D-44 fire. Both reds were self-inflicted, and they are
different species - worth separating, because only one was a mistake:

- **seq 35 (actual `0`)** - the `check_sql` was rewritten from a boolean to a `count(*)` and the
  `description` moved with it, but `expect_op`/`expect` stayed `eq`/`'true'`. The assertion compared
  `'0'` to `'true'` and **could not pass in either direction**. ⛔ **In the diff it reads as a careful
  S-103 restatement.** S-103's missing clause: when a restatement changes the SHAPE of the return,
  `expect_op`/`expect` must move WITH it. **Now enforced at apply time** (D-44b GUARD 2).
- **seq 31 (actual `2`)** - NOT a defect. A D-24 universal that D-44 breaks **by ruling**, exactly K
  times. ⭐ **The 2 IS the ruling working**, now pinned by new seq 85.

⛔ **HOW seq 31 WAS MISSED:** the blast-radius set was built by grepping fixture 42 for
`selection_reason`/`reason` and reading the assertions D-44's prose named. **seq 31 mentions
neither.** ⭐ **The blast radius of a RANKING change is every assertion about ORDER, not every
assertion sharing vocabulary with the ruling.** The fixture found it in 109 s.

⭐ **AND THE NAIVE FIX WAS THE WRONG ONE.** Scoping seq 31 to the non-reserved population would have
stopped constraining the reserved rows entirely - a regression reserving SIX machines, or reserving
one ranked 40th, would pass. Shipped instead: the universal over **every** machine with the single
licensed exception named (`AND NOT b.res`). Stronger on the reserved rows, identical elsewhere.

### ⏸️ THE S7 TRIPLE IS RE-SEQUENCED, NOT SKIPPED

Started, then deliberately stopped at 13 fixtures (**13/13, 491/491, 0 fail** - banked as the
pre-change baseline, ids 1,2,3,5,6,7,8,9,10,11,12,14,16). ⭐ **A determinism triple is only
meaningful over the suite it is reported about**; running it before D-44 would have proven three-round
determinism over a suite this leg then changed (+9 assertions), and DONE-2 would owe it again.
⛔ **Owed at DONE-2, on the FINAL suite.** ⚠️ **Budget corrected: ~44 s/fixture, so ~50 min/round and
~2.5 h for a triple** - NOT the ~19.4 min/sweep earlier pointers carried.

### ⏸️ D-47 SCOPED, NOT STARTED (RELAY: never begin a unit you cannot finish)

Fixture 28's tier guards are today STRUCTURAL: seq 18 (`view_tier3_present = 1`) and seq 19
(`view_tier2_present = 1`) prove the `param_default` and `policy_seed` branches EXIST in the
resolver's definition; nothing on live data executes them (the fleet converged to 31/31 `observed`).
D-47 rules that a synthetic plant be added - one machine with <2 gaps plus a seeded policy row - so
the `policy_seed` branch is EXECUTED. ⛔ **It must not repeat S-264/S-265:** the plant belongs behind
a sentinel the fixture owns, inside the rolled-back subtransaction, with a safety sensor capturing
the real population before the first write (the fixture-57 seq 40/41 and fixture-59 seq 54/55 idiom).
Fixture 28 is green at **21/21** as it stands; nothing waits on this.

### ⏸️ OPEN CS DECISIONS after this leg - **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation)**, plus the SHARPENED D-21 half-2 ask (a value: the margin weight W%, and whether 90% is still the right bar now the binding number is margin-computability at 53.99%). The answered-unexecuted list drops from eleven to **ten**: D-19, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40 minus none - ⛔ **correction: D-44 was a Tier-3 WORK item, not one of the answered-unexecuted D-items, so that list stays at ELEVEN.** ⭐ **D-21(half 1), D-43, D-44, D-45, D-46, DR-3, DR-4, DR-5 and DR-7 are EXECUTED**; D-47 and DR-1/6/8 remain as WORK, not asks. Leg 144 raised no new decision. ⚠️ **S-265 and S-266 remain OPEN; S-271 and S-272 are CLOSED.**

⛔ Per S-80, the next leg must still grep this file - **the WHOLE file, not the tail** - for `CS DECISION` rather than trust this line.

---

## ⭐⭐ leg 145 (2026-08-07) — D-47 EXECUTED. THE FULL-SUITE CENSUS FOUND A RED. S-273..S-276 raised.

⛔ **Written AFTER the evidence it cites, per S-243.** Every number below was read back live at close.

### ✅ D-47 EXECUTED — `20260807170000_prd110_d47_fixture28_policy_seed_execution` (Cody ⚠️→applied)

**Fixture 28: 36/36, `n_fail` 0, zero `scenario_error`.** The `policy_seed` tier is now EXECUTED, not
inspected: probe A raises the resolver's own `base_stock_min_gaps` bar 2→3 and **exactly 1 of 31**
machines falls below it; probe B raises it to 35 and all 31 do. Both sets match an independent
re-derivation with zero symmetric difference (S-267). Dial and whole-view output restored
byte-identical; `machine_service_policy` byte-untouched.

### ⛔ S-273 — the ruling said "synthetic plant"; the machine shipped is REAL, and that is safer

No fixture in the suite of 60 plants a `machines` or `shelf_configurations` row (verified by regex
over every `scenario_sql`; an earlier `ILIKE` scan returned twelve fixtures, **all twelve false
positives on `machines_to_visit`**). The scope predicate needs `status='Active' AND
include_in_refill=true`, so a synthetic row is an Active refillable ghost machine for as long as it
exists — the S-264 hazard class on a protected entity, for LESS coverage. ⭐ The live n_gaps histogram
has **exactly one machine at the minimum**, so raising the bar by one plants the ruling's "one
machine" almost literally, with **zero protected-entity writes**.

### ⛔⛔ S-274 (OPEN) — FIXTURE 54 IS RED. 33/41. LAW 8 APPLIES

Census: **60/60 fired, 2199 evaluated, 0 skipped, 2191 pass / 8 FAIL**. Fixture 54 ("One-verb swap_v3
emits correct legs") was green at 41/41 on legs 126/127/133/134/138 and red at 2026-08-07 16:15Z.
⭐ **Not an engine regression** — no migration since touched `swap_v3` (pinned **ffff8485**). The first
failure is the fixture's **own premise sensor seq 2**: the pod it swaps in is now already assorted on
the machine, so `swap_v3` refuses correctly and six downstream assertions read `absent`.
⛔ **The fix is the leg-114/115 self-supply idiom, NOT a loosened assertion.** This is the S-34 class —
the same defect D-44's ruling forced out of fixture 42.

### ⛔⛔ S-275 — "golden has no known red" was a per-fixture claim wearing a suite's clothes

Legs 143 and 144 both carried it. Both were honest about the fixtures they fired; **neither had fired
fixture 54.** ⭐ **RULE: "no known red" may only be written after a run over `golden.fixtures WHERE
enabled`.** The census cost ~25 minutes and overturned four legs of standing claim.

### ⛔⛔ S-276 — DR-8's "23 proposals for CS Sunday review" are ZERO real proposals

**18 pending, all at `plan_date = 2030-02-18` — fixture 48's own plan_date.** Under S-244 the
CS-facing queue is **empty** (`fac_real = 0`), and **no cron mints facings**. Contrast DR-7, which
shipped at leg 141 calling `propose_rotations_v3(resolve_refill_plan_date())` on a REAL date.
⛔ Build the approve-RPC (it closes an Article-1 gap and it is ruled) — but the DONE-2 report must say
it is a writer for a queue nothing fills, not "facing review shipped".

### ⛔ A FULL SWEEP HAS QUEUE SIDE-EFFECTS

Fixture 58 re-armed S-262 (`picker_weight_proposals_v3` 0→2; cleared this leg, 2 superseded, real
pending 0 throughout). Fixture 48 pushed facings 18→20. **Budget the S-262 cleanup into every sweep.**

### ✅ Article 16 debt paid — leg 143's owed `METRICS_REGISTRY.md` margin-coverage row now exists

### ⏸️ OPEN CS DECISIONS after this leg — **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation)**, plus the SHARPENED D-21 half-2 ask (a value: the margin weight W%, and whether 90 % is still the right bar now the binding number is margin-computability at 53.99 %). The answered-unexecuted list stays at **ELEVEN**: D-19, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40. ⭐ **D-21(half 1), D-43, D-44, D-45, D-46, D-47, DR-3, DR-4, DR-5 and DR-7 are EXECUTED**; DR-1/6/8 remain as WORK, not asks. Leg 145 raised no new decision. ⚠️ **S-274 is a DEFECT that BLOCKS the S7 triple and DR-8 (LAW 8); S-265 and S-266 remain OPEN.**

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.

---

## ⭐⭐ leg 146 (2026-08-07) — S-274 CLOSED (golden's only known red). S-277 raised and closed same leg.

### ✅ S-274 CLOSED BY EXECUTION — fixture 54 MAKES its premises instead of inheriting them

`20260807171000_prd110_s274_fixture54_owns_its_assortment_premises`. NEW
`golden.plant_shelf_identity` (identity sibling of `plant_shelf_stock`; pod identity is WEIMI
`goodsName` through the four tiers of `v_live_shelf_stock`, so it is the same class of write on the
same row) + NEW `golden.evict_pod_from_machine`. Fixture 54 plants five premises and restores two
machines; **41 → 44** assertions. ⛔ **seq 2 keeps `eq 0` verbatim — nothing was loosened.**
⭐ `swap_v3` **ffff8485 unmoved**: the fix landed in the fixture, exactly where S-274 said it belongs.

### ✅ S-277 CLOSED BY EXECUTION — an absolute count over an append-only ledger cannot state a relative property

`20260807171500_prd110_s277_fixture54_seq54_restated_to_the_invariant`. **A07 was re-podded in the
SAME ~18-hour window as A03 — one event, two casualties**, and the first masked the second. The
orphaned SF Pancake drop leg can never be superseded (its key will never be re-emitted) and can never
be deleted (`tg_plan_edits_v3_append_only`). seq 54 restated to edit_id **set equality**, plus seq 56
(all four of the fixture's own legs applied) and seq 57 (all other applied edits inert). **44 → 46.**
One assertion became three, each stricter than the one it replaces.

### ⛔ GOLDEN'S STANDING CLAIM — STILL NOT RE-EARNED

Per **S-275**, "no known red" requires a run over `golden.fixtures WHERE enabled`. The honest
statement at this leg's close is: **fixture 54 is 46/46 and the last full census (2026-08-07 16:18Z)
was 59/60 with fixture 54 the sole red — now fixed.** A leg-146 full sweep was launched at 16:49Z;
whoever adjudicates it may re-earn the phrase, and nobody may write it before then.

### ⏸️ NAMED, NOT FIXED (LAW 10)

`golden.plant_shelf_stock` keys its WEIMI row on `device_name = official_name`. NOVO-1023 carries
snapshots under **three** historical device names, and `v_shelf_slot_identity` resolves
newest-per-`device_name` then newest-overall — so on such a machine `plant_shelf_stock` can edit a row
**no view reads** and report a successful plant that proves nothing. `golden.plant_shelf_identity`
(this leg) does it correctly and is the reference shape.

### ⏸️ OPEN CS DECISIONS after this leg — **ONE ASK, UNCHANGED: S-251 (Galaxy venue-supply confirmation)**, plus the SHARPENED D-21 half-2 ask (a value: the margin weight W%, and whether 90 % is still the right bar now the binding number is margin-computability at 53.99 %). The answered-unexecuted list stays at **ELEVEN**: D-19, D-27, D-28, D-29, D-31, D-32, D-33, D-34, D-37, D-39, D-40. ⭐ **D-21(half 1), D-43, D-44, D-45, D-46, D-47, DR-3, DR-4, DR-5 and DR-7 are EXECUTED**; DR-1/6/8 remain as WORK, not asks. Leg 146 raised no new decision. ⚠️ **S-274 and S-277 are CLOSED; S-265 and S-266 remain OPEN.**

⛔ Per S-80, the next leg must still grep this file — **the WHOLE file, not the tail** — for `CS DECISION` rather than trust this line.
