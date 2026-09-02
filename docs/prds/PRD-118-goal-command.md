/goal Ship PRD-118 in ONE loop — expiry-entry integrity, bind correctness, and the correction doors. Repo: ~/Documents/Boonz Script and Data/BOONZ BRAIN/boonz-erp. Supabase project eizcexopcuoycuosittm.

READ FIRST, IN FULL, IN THIS ORDER: docs/prds/PRD-118-expiry-entry-and-bind-integrity.md, then its ADDENDUM 2 (bottom of the file). Where they disagree, ADDENDUM 2 wins — it carries the verified status ledger dated 2026-09-01, two new items (J, K), and the decoded mechanics for E and H.

NON-NEGOTIABLE RULES
Load `cody` before every migration and get a verdict; load `dara` before any schema change. Canonical RPCs only — never raw INSERT/UPDATE/DELETE on pod_refill_plan, refill_plan_output, refill_dispatching, slot_lifecycle, pod_inventory or warehouse_inventory. Never downgrade an engine version. Every new function is SECURITY DEFINER with an explicit role check and a mandatory reason argument, sets app.via_rpc / app.rpc_name — copy reactivate_warehouse_row as the reference implementation. Do NOT touch plan_date 2026-09-01 or any live/future plan or dispatch rows: migrations and test fixtures only; if a change would alter a live row, stop and report instead. Item I is DONE in code (backend views + packing-page FE, deployed 31 Aug) — do not rework it; ship only its missing METRICS_REGISTRY / CHANGELOG / MIGRATIONS_REGISTRY entries.

WORK THE TIERS IN ORDER

Tier 1 — the bugs that have cost sales or shelf-trust four days running:

- D. Stitch/push must stop sourcing Boonz lines from consignment warehouses (WH_MCC 4fcfb52c…, WH_MM 0aef9ccf… hold only 2099-sentinel rows). Four consecutive runs needed manual re-sourcing to CENTRAL (25/28/30/31 Aug: 7, 16, 11, 5 rows). Dara decides warehouses.is_consignment vs row flag; make every availability read exclude sentinels; nightly assertion that no sentinel row is FEFO-bindable.
- H. Rebuild FEFO binding per ADDENDUM 2 §H: quantity-aware allocation through pick_wh_batch_for_machine with a running per-batch tally, breakdown splits when no batch suffices, the new repin_dispatch_batch door, the nightly over-commit assertion. Also audit why wh_fefo_for_line's is_satisfiable passed a 2-unit batch for a 10-unit line on 01 Sep.
- C. restitch_after_edits / add_pod_refill_row / swap_pod_refill_row must re-bind FEFO for affected machines; Gate-2 refuses fill rows with from_wh_inventory_id NULL AND quantity > 0 (excluding m2m and vox_at_venue), reporting offenders.
- J. Delivery/receive must never merge fresh stock onto an old expiry row (ADDENDUM 2 §J — the 1068 Activia flattening). Pod grain becomes one Active row per machine+shelf+product+expiry; the delivery writer lands units on their own batch date.

Tier 2 — the doors that don't exist:

- B. correct_expiry_v1(p_scope warehouse|pod|dispatch, p_row_id, p_new_expiry, p_reason, p_dry_run default true) — works at zero stock, does the zero-then-reinsert internally for pod scope, refuses past dates or >36 months without override, reason ≥20 chars, old value audited. Plus propagate_expiry_correction(p_wh_inventory_id, p_dry_run default true) listing matching field rows for one audited pass.
- K. The date-less-stock loop (ADDENDUM 2 §K): nightly expiry_unvalidated alert for Active pod rows with NULL expiry older than 3 days; Gate-2 hard guard refusing Refill/Add lines whose batch expiry is NULL or ≤ plan_date + 7 days without an explicit override comment. This encodes CS doctrine: expired or short-dated stock must be impossible to plan onto a shelf.
- G. Fix warehouse_expire_writeoff (separate the CHECK-constrained disposal code from the ≥10-char free-text reason) and add set_wh_quarantine. Then actually write off the queued casualties as fixtures prove the door works: 5 Activia H&O exp 27 Aug (CENTRAL), 1 H&O exp 05 Sep (CENTRAL), and the 4 expired items on WH2-2001 (22 units). Leave the Nescafe batches (exp 04–05 Sep) untouched — CS accepts their expiry; they get written off after they lapse.
- E. Derive source_origin from product_mapping, give add_pod_refill_row/add_dispatch_row explicit p_source_origin, and fix the push preserve-check per ADDENDUM 2 §E-2: it must require include = true so a removed row can never absorb a fresh plan line. Make push re-runnable per machine. Assertion: no dispatch row tagged 'warehouse' for a SKU whose only Active mapping is venue_team.

Tier 3 — judgment guards:

- F. find_substitutes_for_shelf v3 filters: exclude products already on another shelf of the machine unless that lane's runway < 7 days; exclude candidates dead on THIS machine; surface duplicate_on_machine / dead_on_machine / existing_lane_below_50pct in the Gate-1 diff.
- A. Goods receipt: per-line expiry mandatory, no apply-to-all; warn (never block) when ≥2 lines of different products share an identical date; wire check_wh_expiry_anomaly/log_expiry_entry_suspect into receipt time; boonz_products.typical_shelf_life_days with ±25% warning band.

TESTS — no item ships without its fixture
Correct an expiry on a zero-stock batch. Correct an expiry already in the field and confirm propagation lists exactly the right rows. Deliver fresh-dated stock onto a lane holding older stock — assert two rows, two dates (J). Raise a quantity post-stitch — assert it binds (C). Stitch a VOX machine — assert CENTRAL sourcing, sentinels excluded (D). Bind three lines totalling more than the earliest batch — assert no over-commit and correct splits (H). Re-pin a mispinned unpacked row via repin_dispatch_batch. Remove a dispatch row, write a fresh line for the same lane, approve — assert a live row exists (E). Plan a line onto a batch expiring in 3 days — assert Gate-2 refuses it (K). Write off expired stock as waste (G). Quarantine a batch — assert FEFO skips it. Swap into a lane whose product is already on the machine — assert the flag fires (F).

STOP CONDITIONS
Stop and write up (rather than force) any item blocked by a structural constraint, any schema decision that genuinely needs CS, or anything that would touch live plan/dispatch data. Carry on with the remaining tiers.

MORNING REPORT
What shipped per item, the Cody verdict for each migration, fixture results, what stayed open and why, and the exact list of writeoffs executed under G with unit counts.
