# GOAL — PRD-105 Expiry Truth at Shelf Grain

**Codename:** `expiry-truth` · 2026-07-27 · CS · **Mode:** AUTO (Dara design DONE → Cody → apply green, skip+flag blocked)
**Writes:** READ-PATH ONLY, zero row writes · **Cody:** mandatory · **Git:** no push
**Read first:** `boonz-erp/docs/prds/PRD-105-expiry-truth-shelf-grain.md`

## 0. Root cause (verified 2026-07-27)

Card KPI and slot drawer are two read paths over `pod_inventory` sharing no join key. KPI right, drawer wrong; the batch view under both drops a third of its rows.

- **RC-1** `product_boonz` collapses a pod product to ONE arbitrary `boonz_product_id` (`DISTINCT ON (pod_product_name)`, lowest UUID, no machine scope, no `status='Active'`). Of 626 live slots: **214 blank, 78 wrong date, 3 phantom.**
- **RC-3** `v_machine_expiry_batches` dedupes by `max(snapshot_date)` per `(machine_id, shelf_id)`, dropping siblings BEFORE the MIN: **285 of 969 rows / 1,083 units / 28 of 31 machines**; 88 shelves report a wrong earliest date, 34 none. **Corrupts the KPI P1/P2/P3 reads.**
- **RC-2** FE flags red only at `days < 0`, DB counts `<= today`. **RC-4** orphan reader catches only `shelf_id IS NULL`. **RC-6** wrong id also feeds `compute_refill_decision`.

Case: AMZ-1029-3003-O1 A05, Activia Honey & Oats, 1u, exp 2026-07-27 — KPI 1 expired, drawer `—`.

## 1. Objectives

1. `v_machine_expiry_batches`: dedupe by `(machine_id, COALESCE(shelf_id::text,'noshelf'), boonz_product_id)`. Verified 0 collisions at that grain.
2. `get_machine_slots_with_expiry`: DELETE `product_boonz` / `product_expiry` / `prod_nearest_date` / `prod_nearest`. Replace with shelf-keyed CTEs: `MIN(expiration_date)` per `shelf_id` + `SUM(current_stock)` over batches sharing that MIN; join `ON sx.shelf_id = ai.shelf_id`. Verified: shelf_id resolves 626/626 slots.
3. `expiry_qty` = that MIN batch's units, unconditional — drop the `<= 7 days` window. Keep `nearest_expiry_days/_qty` identical (FE compat).
4. FE `SnapshotTab.tsx` L164 + L171: `days < 0` → `days <= 0` (`expiryDayClass`, `expiryDaysToDate`).
5. `get_machine_orphan_expiry`: `shelf_id IS NULL` **OR** `shelf_id` absent from the machine's live `v_live_shelf_stock` aisle.
6. `CREATE INDEX IF NOT EXISTS idx_pod_inventory_active_shelf_expiry ON public.pod_inventory (machine_id, shelf_id, expiration_date) WHERE status='Active' AND current_stock>0;`
7. `compute_refill_decision` loses `pb.boonz_product_id` — pass the shelf's highest-stock one.

## 2. Guardrails (hard)

- **Zero writes.** No INSERT/UPDATE/DELETE on any protected table. If a step seems to need one, STOP and escalate.
- **Cody mandatory** on both views, the function, the index (Appendix A). Record md5 of each replaced body first.
- Migrations named `expiry_truth_*`. PROD-SYNC to `main` is separate.
- Capture before/after `priority_score` for all Active machines. P1/P2/P3 ordering WILL move — intended, but must be auditable, not a surprise at 8pm.
- Do NOT clean the 88 flagged shelves here — read-path only; that sweep is separate.

## 3. Acceptance tests (all must pass)

1. `get_machine_slots_with_expiry('AMZ-1029-3003-O1')` → A05 `expiry_days=0`, `expiry_qty=1`; FE shows `EXPIRED` red.
2. **Reconciliation, all 31 Active machines:** drawer expired units = `v_machine_expiry_summary.expired_units`.
3. `v_machine_expiry_batches WHERE expiration_date IS NOT NULL` rises **684 → 969** rows, +1,083u.
4. Same machine: A08 earliest = **2026-10-29** (was 2027-01-31) qty 9; A12/A13 no longer both show `99d/19u`.
5. Blind-spot query returns 0 rows where true shelf MIN ≠ reported MIN (baseline 88); orphan reader surfaces that machine's C02/C03/D01/E01 ghosts (was 0).
6. A15 (single-variant) identical pre/post; every slot still returns a decision; invariant battery green.

## 4. Deliverables

Migrations `expiry_truth_*` · FE diff `SnapshotTab.tsx` · updated `RPC_REGISTRY` + `CHANGELOG` · `PRD-105-EXECUTION-LOG.md` (md5s, 6 test results, before/after `priority_score`) · PROD-SYNC pending.
