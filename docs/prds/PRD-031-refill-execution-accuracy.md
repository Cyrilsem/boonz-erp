# PRD-031: Refill Execution Accuracy — pod intent must survive to the shelf

**Date:** 2026-06-14
Status: Closed 2026-07-02 (PRD-071 sweep). Reason: overtaken by PRD-044/PRD-049/PRD-053 execution-accuracy work. Reopen by deleting this line.
**Severity:** Critical. The 2026-06-14 chat-built plan dispatched roughly 42 percent of shelf capacity. Drivers are re-doing the engine's job by hand on every machine.
**Owner:** Dara (data + mapping integrity), Cody (review), Stax (FE deviation surfacing), assistant orchestrates.
**Related:** PRD-024 (stitch split normalization, approved, awaiting execution) and goal_mixweight_canonical_and_vml_recon (canonical mix_weight). This PRD depends on both and adds the integrity, leakage, and validation legs they do not cover.

---

## 1. What happened (2026-06-14, machines AMZ-1029 / 1038 / 1057 / 1068 / NOOK-1019)

CS reported quantities did not reflect what the machines could hold; the driver reviewed each machine and added product by hand. Investigation of the live plan:

- Across the 5 machines, `refill_plan_output` totalled 278 dispatched units against 661 units of real shelf gap (max_stock minus current_stock). About 42 percent fill.
- The pod-level plan (`pod_refill_plan`) was mostly healthy: for AMZ-1029, A07 Chocolate Bar 9 = full gap, A13 Coca Cola 21 = full, A14 Red Bull 6 = full, A15 Al Ain 12 = full. Quantity is mostly lost downstream, between pod intent and dispatched SKU.
- `refill_plan_output.sold_7d` was 0 on 100 percent of rows, which first looked like a dead-velocity bug. It is not: `slot_lifecycle.velocity_7d/30d` (the source the engine actually reads) was fresh and non-zero (evaluated 2026-06-13 22:15). `sold_7d` in the output table is a display field that is never populated. Cosmetic, but it actively misleads diagnosis.

## 2. Root causes (evidence-based)

### A. Stitch leaks quantity to SKUs that are not on the shelf

`stitch_pod_to_boonz` fans each pod quantity across every `product_mapping` row for that pod by split weight, then writes per-SKU lines. Two compounding faults:

1. Split source and normalization (already scoped in PRD-024 / goal_mixweight): the fan-out reads the wrong column and does not self-normalize, so distribution is wrong.
2. Off-shelf leakage (new here): units allocated to a mapped SKU that is not physically on the target shelf are dropped, not redistributed to the variants that are present. Net result is severe deflation.

Live proof, AMZ-1029 A14 Red Bull: pod intent 6, dispatched 1, warehouse held 66 units of Red Bull Diet. Not a stock problem. The pod product Red Bull maps to both Red Bull Diet and Red Bull Regular; stitch sent roughly 80 percent to Regular, which is not on A14, and those units evaporated. Same mechanism cut Vitamin Well Care 3 to 1 and Loacker 3 to 2.

### B. product_mapping has massive duplicate rows

The Red Bull pod product has about 80 active mapping rows (roughly 40 to Diet, 40 to Regular), duplicated many times over with inconsistent split values. Duplicates blow up the windowed split total and corrupt any normalization. This is a data-integrity defect, not just a formula bug, and it is not addressed by PRD-024. (Consistent with the earlier machine_mapping duplicate finding.)

### C. Engine targets days-of-cover, not capacity

The deployed `engine_add_pod` sets quantity from velocity times `p_days_cover` (10), capped by gap, not fill-to-capacity. Slow movers come in well under shelf capacity even when empty (AMZ-1029 Loacker pod 3 of 12, Sunbites 5 of 10, Krambals 0 of 3). For the actual visit cadence this leaves shelves visibly under-filled, which is exactly what the driver corrects by hand. This contradicts the fill-to-capacity behavior assumed in the conductor and in skill docs; the live function and the intended behavior have drifted.

### D. No accuracy gate caught any of it

The chat conductor ran its post-commit battery (cap, runway, fan-out conservation, coverage) and the stitch dry-run reported 0 deviations, yet about 40 percent of intended quantity was missing. The deviation check compares the wrong things: it does not compare dispatched SKU totals against pod intent per shelf, and nothing compares planned fill against shelf gap. A large, silent quantity leak passes as clean.

### E. Packing reservation gap (already documented in today's audit)

Stitch checks warehouse coverage per line without reserving, so shared SKUs (cola, water) read covered at dispatch then run dry when packed across all bags. This produced an additional 44-unit packing shortfall today. It compounds A but is a separate defect.

### F. Machine-scoped mapping is not authoritative; the global default leaks in

When a pod product has both machine-scoped mapping rows and a global default, stitch does not let the scoped set replace the global set. It pulls both and resolves scoped-over-global only per individual SKU (the `pull_raw` and the second mapping CTE both use `ORDER BY (pm.machine_id = a.machine_id) DESC` inside a `ROW_NUMBER()` partitioned by boonz_product_id, with predicate `pm.machine_id IS NULL OR pm.machine_id = a.machine_id`). The result is the union of scoped and global SKUs, not the curated scoped set.

Live proof, Snack Bar on the Amazon fleet. Curated per machine: AMZ-1029 and AMZ-1057 = Delice + KitKat only; AMZ-1068 = McVities Dark/Milk/Oreo. Global default = Delice, KitKat, McVities Dark, McVities Milk, Oreo, plus McVities Regular and Reese at 0. Because global leaks in, AMZ-1057 (curated Delice + KitKat) was dispatched 2026-06-14 with Delice + KitKat + McVities Dark + McVities Milk + Oreo. Every Amazon Snack Bar ends up with the global SKU set, so the per-machine curation never takes and every machine looks the same. This is compounded by the split_pct vs mix_weight disagreement on those scoped rows (1029 split 50/50 but mix 1.0/1.0; 1057 split 50/50 but mix 0.15/0.4, owned by PRD-024) and by the duplicate rows in WS-1.

## 3. Scope

In scope: make pod intent survive to the dispatched SKU (mapping integrity + off-shelf redistribution), align the engine fill target with operational reality, add a real accuracy gate, fix the cosmetic sold_7d wiring, and reserve shared-SKU stock at stitch.

Out of scope: the split-normalization formula itself (PRD-024 / goal_mixweight own it; this PRD assumes they land first or alongside).

## 4. Workstreams

### WS-1 product_mapping integrity (Dara, Cody)

Read-only audit first: list every (pod_product_id, boonz_product_id, machine scope) with a row count above 1 and show CS. Then dedup to one canonical row per (pod, boonz, machine-scope) via a canonical writer, archive never delete, per-row diff with CS sign-off. Add a UNIQUE constraint so duplicates cannot reappear. Expect Red Bull, and likely others, to collapse from dozens of rows to 2.

### WS-2 stitch off-shelf redistribution (Dara, Cody)

Stitch must distribute a pod quantity only across SKUs actually present on the target shelf (or its planogram), and redistribute, not drop, any remainder. No unit allocated to a mapped-but-absent SKU may silently vanish. Conservation law: sum of dispatched SKU quantity for a shelf equals pod intent, minus only genuine warehouse shortfall (which must be reported, not hidden). Layer on top of the PRD-024 normalization.

### WS-2b machine-scoped mapping is authoritative (Dara, Cody)

In both stitch mapping CTEs, change the resolution from per-SKU scoped-over-global to set-level precedence: if any active machine-scoped mapping row exists for a (pod_product, machine), use only the machine-scoped rows for that pod+machine and ignore the global rows entirely; fall back to the global set only when no scoped mapping exists. Concretely, gate the global rows with a NOT EXISTS on a scoped row for the same (pod_product_id, machine_id), instead of unioning then deduping per boonz_product_id. This makes a curated per-machine SKU list (for example Snack Bar = KitKat + Oreo on one machine, McVities on another) actually take effect. Verify on the Amazon Snack Bar set that a curated machine no longer receives global-only SKUs. Sequence this with WS-2 (both edit the same CTEs) and after PRD-024 normalization so the weights are correct once the set is right.

### WS-3 engine fill target (Dara, Cody, CS decision)

Decide the target rule with CS: fill-to-capacity for selling shelves (driver expectation), or raise `p_days_cover` to match the real visit interval, or a hybrid (cover-based floor, capacity ceiling). Whatever is chosen, the skill docs, the conductor, and the function must agree. Document the decision and stop drift.

### WS-4 accuracy gate (assistant + Stax)

Add a hard gate that runs at stitch dry-run and post-commit and blocks or flags when:

1. Dispatched SKU total per shelf is materially below pod intent (configurable tolerance) for any reason other than reported warehouse shortfall.
2. Planned fill across the plan is below a sane fraction of total shelf gap.

Surface a per-shelf intent vs dispatched vs gap report in the refill FE so a human sees the leak before pushing to drivers. The existing 0-deviations check is necessary but not sufficient; this replaces it as the accuracy guard.

### WS-5 reserve shared SKU at stitch (Dara, Cody)

Stitch must reserve warehouse stock as it allocates across machines so a shared SKU cannot read covered for five machines and pack dry. Ties into the BUG-006 reservation model already in pack_dispatch_line.

### WS-6 fix sold_7d wiring (Dara)

Populate `refill_plan_output.sold_7d` from the same `slot_lifecycle` velocity the engine uses, or drop the column. A silently zero metric on every row is a diagnostic hazard.

## 5. Acceptance

1. Red Bull on AMZ-1029-equivalent: pod intent 6 with 66 in warehouse dispatches 6 to Red Bull Diet, not 1. No off-shelf leakage on any multi-SKU pod.
2. product_mapping has at most one active row per (pod, boonz, machine-scope); UNIQUE constraint live; Red Bull collapsed to 2 rows.
   2b. A curated machine-scoped mapping is exclusive: a machine whose Snack Bar mapping is Delice + KitKat dispatches only Delice + KitKat (no global McVities or Oreo). Machines with no scoped mapping still fall back to global.
3. For a verification set of shelves, dispatched SKU total equals pod intent minus only reported warehouse shortfall (conservation holds).
4. The accuracy gate flags a synthetic leak (force a pod-to-dispatch drop) and stays green on a correct plan.
5. Engine fill target agreed with CS and consistent across function, conductor, and skill docs.
6. sold_7d reflects real velocity or is removed.
7. Constitution holds throughout: canonical writers, via RPC only, forward-only migrations, registries updated, Cody verdict on every fn and DDL.

## 6. Sequencing

PRD-024 / goal_mixweight (split normalization) first or together, then WS-1 (dedup) and WS-2 (redistribution), then WS-4 (gate) so the fix is provable, then WS-3, WS-5, WS-6. Do not regenerate any live or dispatched plan; this is forward code plus a one-time mapping cleanup, validated on a non-live date before fleet use.
