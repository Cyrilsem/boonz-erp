# boonz-master-3 SKILL.md — proposed additions (2026-05-19 retrospective)

Three sections to merge into `/var/folders/.../boonz-master-3/SKILL.md`. Each block is labeled with the insertion point. Apply via skill-creator or hand-merge.

---

## Block 1 — Append to the "⛔ Hard rules" section (after rule 5)

````markdown
6. **Cody is mandatory for canonical-writer changes.** Before any
   `CREATE OR REPLACE FUNCTION` that writes to an Appendix A entity
   (machines, shelf_configurations, planogram, sim_cards, slots,
   slot_lifecycle, pod_inventory, pod_inventory_audit_log,
   warehouse_inventory, daily_sales, sales_lines, sales_aggregated,
   settlements, refill_plan_output, dispatch_plan, dispatch_lines,
   write_audit_log) or to `pod_refill_plan` / `refill_dispatching`,
   invoke the `cody` skill and record its verdict in the task list.
   No exceptions for "same signature" patches. The v4→v5→v6→v7 engine
   cascade on 2026-05-19 happened because this rule wasn't enforced.

7. **Engine and stitch outputs must pass invariant checks.** After
   every `engine_add_pod`, `engine_swap_pod`, `engine_finalize_pod`,
   `stitch_pod_to_boonz` call, run the post-run invariant battery:
   - For every REFILL row: `current_stock + qty ≤ max_capacity`
   - For every STAR / DOUBLE DOWN / KEEP / KEEP GROWING row with
     WH-sourced origin **and `qty > 0`**:
     `current_stock + qty ≤ CEIL(velocity_30d × days_cover × signal_boost)`
     where `signal_boost ∈ {2.0 for STAR, 1.5 for DOUBLE DOWN, 1.0
otherwise}` (engine_add_pod v8, 2026-05-19). Rows with `qty = 0`
     are vacuously valid even when the shelf is already over target —
     a zero refill is the correct response to that state.
   - For every row where `wh_avail = 0` and `source_origin = 'warehouse'`,
     an entry must exist in `procurement_gaps` for the same product
   - Sum of REMOVE / M2W qty per `(plan_date, machine, shelf)` must
     equal the pod_refill_plan parent qty (no fan-out inflation)
   - For every Pass 2 autonomous swap row in `pod_swaps` with
     `reason IN ('rotate_out','wind_down')` and `(reasoning->>'pass') = '2'`:
     at swap time, `current_stock ≥ CEIL(velocity_30d × p_days_cover)`.
     If `current_stock < target_stock`, the engine should have skipped
     the swap (engine_swap_pod v8, 2026-05-19). The `skipped_swaps[]`
     array in the engine_swap_pod return value should account for it.
   - For every `refill_dispatching` row created via push_plan_to_dispatch
     (i.e., parent `refill_plan_output` row has its `dispatch_id` set):
     `refill_dispatching.source_origin = refill_plan_output.source_origin`
     AND `refill_dispatching.from_machine_id = refill_plan_output.from_machine_id`
     (push_plan_to_dispatch v3, 2026-05-19). Stitch v11's disagreement
     check covers the engine→stitch leg; this covers the stitch→dispatch
     leg.
     If any invariant fails, halt and surface — do not ship the row.

8. **Post-Gate-2 dispatch coverage check.** After every
   `stitch_pod_to_boonz(p_dry_run := false)` call, run:
   ```sql
   SELECT machine_name
   FROM refill_plan_output rpo
   WHERE plan_date = $1 AND operator_status = 'approved'
   EXCEPT
   SELECT m.official_name FROM refill_dispatching rd
   JOIN machines m ON m.machine_id = rd.machine_id
   WHERE rd.dispatch_date = $1;
   ```
````

If the result is non-empty, the plan is NOT shipped. Surface the
missing machines and find the bridge break before reporting "Plan
pushed. Drivers will see it." This was the OMDBB/OMDCW/VOXMM
failure on 2026-05-19.

9. **No raw UPDATE / INSERT / DELETE on `pod_refill_plan`,
   `refill_plan_output`, or `refill_dispatching` from inside this
   conductor.** Every state change goes through an RPC. If the
   operation you want has no RPC, build the RPC before doing the
   operation. Source_origin markers, action-label changes,
   routing-label changes — all need RPCs. Direct raw SQL writes are a
   stop-ship even when Cody hasn't seen them. (The 2026-05-19 session
   ran ~70 direct UPDATEs on `refill_plan_output` — that is the
   pattern this rule prevents.)

10. **In-session function rewrites are not free.** A second
    `CREATE OR REPLACE` on the same function within 24 hours requires
    explicit CS green light AND a Cody review covering the diff
    between versions. The 2026-05-19 v4→v5→v6→v7 cascade on
    `engine_add_pod` is the failure mode this rule exists to prevent —
    each version was the assistant patching the previous version's
    symptom rather than addressing the contract.

11. **`approve_refill_plan` is the canonical writer for the
    plan→dispatch bridge.** When `operator_status` flips
    `pending → approved` on a `refill_plan_output` row, the dispatch
    rows for that machine must be created in the same transaction.
    If the conductor commits Gate 2 and the FE later flips approvals,
    the trigger / RPC chain must guarantee dispatch coverage. Do not
    rely on a separate `push_plan_to_dispatch` step — that's a
    bypass of Article 1.

````

---

## Block 2 — Insert after the "Routing table" section, before "Full daily flow"

```markdown
---

## Gate checklists (mandatory before any commit)

The conductor MUST run the checklist below at each gate. CS green-light
is verbatim — silence is not consent.

### Gate 1 — `approve_pod_refill_plan(plan_date)`

Before invoking the RPC, present the draft and confirm:

- [ ] Draft summary shown to CS with row counts per action type
      (REFILL / ADD_NEW / REMOVE / M2W) and per machine.
- [ ] All M2W rows listed with destination — internal_transfer machine
      OR warehouse_id for genuine returns.
- [ ] All ADD_NEW rows listed with rationale: substitute (Pearson? CS
      directive?), new product (Plaay launch class?), VOX-sourced.
- [ ] All rows with `linked_intent_id` listed with intent name and
      target_qty progress.
- [ ] All rows where pod_product is on the VOX-sourced list
      (`reference_vox_sourced_products.md`) flagged for source_origin.
- [ ] `procurement_gaps` array surfaced if non-empty — CS confirms
      whether to issue POs, redistribute truck-side, or accept the
      gap.
- [ ] R7 60% machine cap check: no machine has > 60% of shelves with
      planned action.
- [ ] CS green light is verbatim: "approve", "green light", "Gate 1
      go", or equivalent.

Only after every checkbox: `SELECT approve_pod_refill_plan(plan_date);`

### Gate 2 — `stitch_pod_to_boonz(plan_date, p_dry_run := false)`

Before committing the stitch:

- [ ] Dry-run already executed and the deviations + procurement_alerts
      lists shown to CS.
- [ ] Every internal-transfer row has `source_origin = 'internal_transfer'`
      and `from_machine_id` populated (will be enum column post-Patch B).
- [ ] Every VOX-at-venue row has `source_origin = 'vox_at_venue'`.
- [ ] Stitch comment field reads `[VOX-SOURCED]` or `[TRUCK-TRANSFER
      from <machine>]` where applicable — CS confirms routing labels.
- [ ] No row has `qty > max_capacity` or breaches the runway gate.
- [ ] Deviations reviewed line by line. Each is either accepted (real
      WH shortage) or escalated to procurement.
- [ ] Procurement_alerts reviewed line by line.
- [ ] CS green light is verbatim.

After invoking the stitch:

- [ ] Verify `pod_refill_plan.status` flipped to `'stitched'` for all
      approved rows.
- [ ] Run the dispatch coverage query (Hard rule 8 above). Every
      approved machine has ≥ 1 row in `refill_dispatching`.
- [ ] Report row counts per machine to CS.
- [ ] Report any rows where `available_qty < target_qty` in the
      `v_dispatch_availability` view (post-Patch B view).

Only after every post-commit check: report "Plan shipped. Drivers
visible." Until then, the plan is NOT shipped.
````

---

## Block 3 — Insert at the end of the existing "Failure modes / fallback to boonz-legacy" section

```markdown
---
## Constitutional violations are not "failure modes" — they are stop-ships

Any of the following are stop-ships, not graceful fallbacks. If the
conductor finds itself about to do any of these, halt and ask CS.

- A direct `UPDATE`, `INSERT`, or `DELETE` on an Appendix A entity
from inside this session (other than via a canonical RPC).
- A `CREATE OR REPLACE` on a canonical writer (any RPC listed in
`RPC_REGISTRY.md` under canonical writers) without Cody review.
- A Gate 2 commit without running the dispatch coverage query (Hard
rule 8).
- A `[FROM PO RECEIPT — assumed received]` or equivalent "fix it in
the next migration" comment in a memory file at the same time as
a production commit. If the schema is wrong, fix the schema. Do
not ship the workaround AND the acknowledgment that it's a
workaround.
- Approving rows in `refill_plan_output` (or any operator-state field)
on behalf of CS without explicit per-row authorization. The
2026-05-19 bulk-approve incident is the canonical anti-example.

If any of these come up, stop. Ask CS. Do not ship.
---

## Memory of this protocol's failures

This protocol failed in production on 2026-05-19. The full retrospective
lives in `/Users/cyrilsemaan/Documents/Boonz Script and Data/BOONZ BRAIN/retrospective_2026-05-19_refill_session.md`.
Read it after the first protocol violation in any future session.
```

---

## How to apply

Option 1 — **skill-creator**: invoke `skill-creator` and feed it this file with the instruction "merge into boonz-master-3 SKILL.md at the labeled insertion points."

Option 2 — **hand-merge**: open the SKILL.md at `/var/folders/f6/g7vxcz254wd8p27wh33q01n40000gn/T/claude-hostloop-plugins/7dee33788b20d513/skills/boonz-master-3/SKILL.md` and paste each block at its labeled location.

---

## Diff summary for review

- **5 new Hard rules** (6–11) covering Cody-mandatory, invariants, dispatch coverage, no-raw-UPDATEs, in-session-rewrite gating, and the approve→dispatch bridge as canonical writer.
- **Gate 1 + Gate 2 checklists** (mandatory verbatim CS green light, explicit dispatch coverage verification, source_origin tagging).
- **"Constitutional violations are stop-ships"** subsection — the protocol now blocks today's failure modes by name.
- **Memory reference** to the retrospective so future sessions can read what broke.
