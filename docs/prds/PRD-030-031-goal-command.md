# /goal — PRD-030 Partial Pack + PRD-031 Refill Execution Accuracy

Paste into Claude Code in the `boonz-erp` repo. Two separate /goal runs. Do PRD-030 first (unblocks daily ops), then PRD-031. Read `docs/architecture/01_constitution.html`, `RPC_REGISTRY.md`, `MIGRATIONS_REGISTRY.md` before either.

Governance for both: Dara designs, Cody reviews every SECURITY DEFINER fn and protected DDL, Stax does FE. No `boonz-master-3`. No raw writes to protected tables (refill_dispatching, product_mapping, refill_plan_output, warehouse_inventory, pod_inventory) — canonical RPC only. No inventory move without per-row diff + CS sign-off; archive never delete. Forward-only migrations, no \_v2. Apply nothing to prod without CS sign-off — stage, STOP at each apply. No em dashes.

---

## RUN 1

/goal Implement PRD-030 per docs/prds/PRD-030-partial-pack-no-dark-stage.md. Objective: a warehouse-confirmed machine is packed even when some lines have no stock; unfillable lines travel as "not filled" and never block pickup or dispatch. No more dark stage.

STATE (verified live 2026-06-14, do not re-diagnose): pack_dispatch_line raises "WH row % has only % units, cannot pick %" on zero stock, so an OOS line has no pack path except skip_dispatch_line. A machine is ready only when every included line is packed, so one unpacked OOS line keeps it partially packed; the driver app gates pickup/dispatch on packed, so the machine goes dark. Today 4 lines (2403 + 2401 Pepsi Black, Coke Regular) forced manual skip + add_dispatch_row to free the bags. refill_dispatching already has filled_quantity, packed, skipped/skip_reason, driver_outcome.

BUILD ORDER:

1. Dara state model: define "resolved for packing" = packed OR skipped OR include=false OR not_filled. Add an auditable not_filled marker (prefer a pack_outcome enum packed/partial/not_filled + filled_quantity), distinct from skip. not_filled keeps planned quantity, filled_quantity 0. Cody review.
2. pack_dispatch_line (canonical writer, Cody mandatory): allow a confirmed partial or zero pick (p_not_filled flag or pick_qty < quantity) without raising; set pack_outcome + filled_quantity; never debit WH for missing units; keep the BUG-006 from_wh_inventory_id guard for units actually picked.
3. New canonical confirm_machine_packed(machine_name, dispatch_date, packed_by, reason): flips machine to packed when every included line is resolved; returns per-line summary. Pickup/dispatch gate keys off machine-packed, not full fill.
4. Stax FE: packing screen Mark not filled + partial + Confirm packing complete (calls confirm_machine_packed); driver app shows ready machines and renders not_filled lines as "Not filled (planned N, packed 0)", never blocking; fleet view of not-filled lines for the day.
5. Battery: machine with one zero-stock line packs fully and dispatches; WH never debited for not_filled; partial picks pack available + mark remainder; not-filled demand reportable. Registries + CHANGELOG per change.

DONE WHEN: battery green, Cody sign-off recorded, registries updated, FE on Vercel, each step committed separately. Start with step 1; show me the state-model design and Cody verdict before applying.

---

## RUN 2

/goal Implement PRD-031 per docs/prds/PRD-031-refill-execution-accuracy.md. Objective: pod intent survives to the dispatched SKU; no silent quantity leak between pod_refill_plan and refill_plan_output. Depends on PRD-024 / goal_mixweight (split normalization) landing first or together.

STATE (verified live 2026-06-14, do not re-diagnose): 2026-06-14 plan dispatched 278 of 661 units of shelf gap across 5 machines (~42%). pod_refill_plan was mostly full (AMZ-1029 A14 Red Bull pod 6, A13 Coke 21, A07 Choc 9). Loss is downstream. AMZ-1029 A14 Red Bull: pod 6, dispatched 1, WH had 66 Red Bull Diet — stitch fanned ~80% to Red Bull Regular (not on the shelf) and dropped it. product_mapping for pod Red Bull has ~80 active rows (~40 Diet, ~40 Regular), heavily duplicated. slot_lifecycle velocity was fresh and non-zero; refill_plan_output.sold_7d=0 is an unwired display field, not the cause. Engine uses velocity x p_days_cover=10 (not fill-to-cap), so slow movers under-fill at pod level. Stitch dry-run reported 0 deviations while ~40% leaked: the deviation check does not compare dispatched SKU vs pod intent. SEPARATE machine-scope leak (Snack Bar): stitch unions machine-scoped + global mapping (per-SKU dedup with ORDER BY pm.machine_id=a.machine_id over ROW_NUMBER partitioned by boonz_product_id, predicate pm.machine_id IS NULL OR =a.machine_id), so global SKUs leak onto curated machines. AMZ-1057 curated Delice+KitKat was dispatched Delice+KitKat+McVities Dark+Milk+Oreo. Per-machine curation never takes; every Amazon Snack Bar looks the same.

BUILD ORDER:

1. WS-1 product_mapping integrity (Dara, Cody): read-only audit of (pod, boonz, machine-scope) with row count > 1, show CS; dedup to one canonical row via canonical writer, archive not delete, per-row diff + CS sign-off; add UNIQUE constraint. Verify Red Bull collapses to 2 rows.
2. WS-2 stitch off-shelf redistribution (Dara, Cody): distribute pod qty only across SKUs present on the target shelf/planogram; redistribute remainder, never drop to an absent SKU; conservation = dispatched SKU sum equals pod intent minus reported WH shortfall. Layer on PRD-024 normalization.
   2b. WS-2b machine-scoped mapping is authoritative (Dara, Cody): in both stitch mapping CTEs, change scoped-vs-global from per-SKU dedup to set-level precedence. If any active machine-scoped row exists for (pod_product, machine), use ONLY scoped rows and gate global rows with NOT EXISTS on a scoped row for the same (pod_product_id, machine_id); fall back to global only when no scoped mapping exists. Verify on Amazon Snack Bar: a curated Delice+KitKat machine no longer receives global McVities/Oreo. Same CTEs as WS-2, after PRD-024 normalization.
3. WS-4 accuracy gate: at stitch dry-run and post-commit, flag/block when dispatched SKU total per shelf is materially below pod intent (other than reported WH shortfall) or plan fill is below a sane fraction of gap. Surface intent vs dispatched vs gap per shelf in the refill FE (Stax). Replaces the insufficient 0-deviations check.
4. WS-3 engine fill target: get CS decision (fill-to-capacity vs raise p_days_cover vs hybrid); align function, conductor, and skill docs; document and stop the drift.
5. WS-5 reserve shared SKU at stitch so a SKU cannot read covered for 5 machines then pack dry (ties to BUG-006 reservation). WS-6 populate refill_plan_output.sold_7d from slot_lifecycle velocity or drop the column.
6. Battery: Red Bull pod 6 with WH 66 dispatches 6; mapping <=1 active row per key; curated Snack Bar machine (Delice+KitKat) dispatches only Delice+KitKat, no global McVities/Oreo, while an uncurated machine still gets global; conservation holds on a verification set; gate flags a synthetic leak and stays green on a correct plan.

DONE WHEN: battery green, Cody sign-off per fn/DDL, registries + CHANGELOG updated, FE on Vercel, steps committed separately. Do NOT regenerate any live/dispatched plan; validate on a non-live date. Start with WS-1 step 1 (read-only audit) and show me the duplicate report before any write.
