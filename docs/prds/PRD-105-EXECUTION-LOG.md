# PRD-105 — Execution Log (Expiry Truth at Shelf Grain)

**Codename:** `expiry-truth` · **Applied:** 2026-07-28 · **Mode:** AUTO · **Writes:** READ-PATH ONLY (zero row writes)
**Cody:** ✅ Approved (Articles 1, 2, 3, 12, 14, 16) · **Git:** not pushed — PROD-SYNC to `main` pending
**Project:** eizcexopcuoycuosittm

---

## 1. Objects changed (byte-identical rollback md5s)

| Object                                  | Kind            | Old body md5 (rollback)            | New body md5                       | Migration                                           |
| --------------------------------------- | --------------- | ---------------------------------- | ---------------------------------- | --------------------------------------------------- |
| `v_machine_expiry_batches`              | view            | `f2f6397dc4a4fb0e90fbad7ba85f02ab` | `602989220d6c3c92ae2396df6e985665` | `expiry_truth_batches_regrain` (`20260728100001`)   |
| `idx_pod_inventory_active_shelf_expiry` | partial index   | (did not exist)                    | present                            | `expiry_truth_index` (`20260728100002`)             |
| `get_machine_slots_with_expiry(text)`   | fn (sql STABLE) | `f57322b3c770e14c155008a9e10502b4` | `5c28dedbdd6fcd8842b2f48a3df901ba` | `expiry_truth_slots_shelf_keyed` (`20260728100003`) |
| `get_machine_orphan_expiry(text)`       | fn (sql STABLE) | `e5e19b3cef7a2a6fcc504940410c4077` | `9f07a4005c447c7f86bca3c3e6cf12a3` | `expiry_truth_orphan_live_aisle` (`20260728100004`) |
| `SnapshotTab.tsx`                       | FE              | `days < 0` (L165, L172)            | `days <= 0`                        | (not pushed)                                        |

All four migrations applied `{"success":true}`. `npx tsc --noEmit` clean.

Rollback = re-`CREATE OR REPLACE` each object from the pre-change body whose md5 is recorded above; `DROP INDEX IF EXISTS idx_pod_inventory_active_shelf_expiry`. No data to restore (zero writes).

---

## 2. What changed (vs Dara design §3)

- **RC-3 (view re-grain).** Dedupe partition moved from `(machine, COALESCE(shelf::text,'product:'||boonz))` to `(machine, COALESCE(shelf::text,'noshelf'), boonz_product_id)` via `ROW_NUMBER() … ORDER BY snapshot_date DESC, pod_inventory_id`, keep `rn=1`. Precondition verified live: **0 collisions** at the finer grain, so no legitimate row is dropped.
- **RC-1/RC-6 (drawer shelf-keyed).** Removed the name-keyed `product_boonz` / `product_expiry` / `prod_nearest_date` / `prod_nearest` CTEs. Added `shelf_expiry` (`MIN(expiration_date)` per `shelf_id`), `shelf_min_batch` (`SUM(current_stock)` over the batches at that MIN), `shelf_top_boonz` (`DISTINCT ON (shelf_id)` highest-stock `boonz_product_id`). `expiry_days = (min_exp - today)::int`; `expiry_qty = min_exp_qty` **unconditional** (7-day window dropped); `nearest_expiry_days/_qty` mirror them for FE compat. `compute_refill_decision` now receives `shelf_top_boonz.boonz_product_id` — **note that function never reads the parameter** (it derives identity from `v_live_shelf_stock`/`slot_lifecycle`), so scoring is provably unchanged.
- **RC-4 (orphan reader).** `AND b.shelf_id IS NULL` → `AND (b.shelf_id IS NULL OR b.shelf_id NOT IN (live_shelf))`, where `live_shelf` = shelf_ids resolved from `v_live_shelf_stock` via `shelf_configurations` (is_phantom=false, de-padded shelf_code). Existing `boonz_product_id NOT IN live_boonz` exclusion kept per §3.3.
- **RC-2 (FE boundary).** `expiryDayClass` + `expiryDaysToDate`: `days < 0` → `days <= 0` (today renders as `EXPIRED` red). Shared helpers — benefits both the slot drawer and the orphan panel.

---

## 3. Acceptance tests

Live prod, 2026-07-28 (Dubai). Note: the PRD's literal numeric expectations were captured 2026-07-27; live data drifted one day (a unit was consumed, planogram refilled). Robust invariants pass; drifted literals documented.

| #   | Test                                                               | Result                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| --- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Reported case A05 `expiry_days=0, qty=1`, FE `EXPIRED`             | ⚠️ **DRIFTED (not a defect).** The Activia Honey & Oats 1u exp 2026-07-27 was consumed/removed since authoring; machine now holds **0 expired units** (`v_machine_expiry_summary.expired_units=0`, raw expired rows=0). A5 now correctly reports the true earliest = Activia Mix & Go 13d/5u. Mechanism validated by tests 2/4/5. Boundary fix verified against fleet expired stock (see below).                                       |
| 2   | Reconciliation: drawer expired = summary expired, all 31 Active    | ✅ **31/31 reconciled, 0 mismatched** via live RPC (`SUM(expiry_qty) WHERE expiry_days<=0` = `v_machine_expiry_summary.expired_units`).                                                                                                                                                                                                                                                                                                |
| 3   | `v_machine_expiry_batches WHERE expiration_date IS NOT NULL` rises | ✅ **698 → 975 rows, 3499 → 4626 units** (+277 rows / +1127 units). New count = full raw Active-stocked-not-null set (zero drop). PRD snapshot figure was 684→969/+1083; magnitude matches, absolute drifted with data.                                                                                                                                                                                                                |
| 4   | AMZ-1029-3003-O1 A08 earliest 2026-10-29, qty 9                    | ✅ A8 = `expiry_days=93` (2026-10-29 from 07-28), `expiry_qty=9`. Was 2027-01-31 under the old view (94d of false safety).                                                                                                                                                                                                                                                                                                             |
| 5   | A12/A13 no longer identical `99d/19u`                              | ✅ A12 = 144d/13u (Soft Drinks Mix), A13 = 98d/16u (Coca Cola Mix). Cross-shelf Coke-Zero bleed gone.                                                                                                                                                                                                                                                                                                                                  |
| 6   | Blind-spot query = 0 wrong-MIN shelves (baseline 88)               | ✅ **0** shelves where reported MIN ≠ true raw MIN. Pre-apply baseline measured live = 63 (drifted from 88); post-apply = 0.                                                                                                                                                                                                                                                                                                           |
| 7   | Orphan reader surfaces C02/C03/D01/E01 ghosts                      | ⚠️ **DRIFTED + design-bound (see §4).** The off-aisle branch works (6 ghost rows on C02/D01/E01 now enter the candidate set vs 0 before), but all 6 belong to products that are **live elsewhere on the machine today** (`in_live_boonz=true`), so the §3.3-mandated `live_boonz` exclusion suppresses them → panel empty. On 07-27 those products were evidently not live. Fleet-wide the reader returns 0 genuine orphans right now. |
| 8   | Single-variant shelf identical pre/post                            | ✅ **By construction + proven.** For a one-product shelf, shelf-keyed `MIN` = the old product-keyed `MIN`. Blind-spot test (#6=0) proves no shelf's reported MIN regressed vs raw truth.                                                                                                                                                                                                                                               |
| 9   | Every stocked slot returns a non-null decision                     | ✅ **544/544** shelf-bearing slots return a decision fleet-wide; 0 missing.                                                                                                                                                                                                                                                                                                                                                            |
| 10  | Invariant battery (cap/runway/procurement_gaps/source_origin)      | ✅ Unaffected — zero writes; `compute_refill_decision` output is unchanged (its `boonz_product_id` arg is inert). Decision coverage 544/544 stands in as the read-side proof.                                                                                                                                                                                                                                                          |

---

## 4. Flags / open items for CS

1. **Orphan reader vs `live_boonz` (test #7 tension).** PRD §3.3 says _keep_ the `boonz_product_id NOT IN live_boonz` exclusion; test #7 expects the C02/D01/E01 ghosts surfaced. These conflict **when a ghost's product is live elsewhere** — which is exactly today's situation on AMZ-1029-3003-O1 (all 6 off-aisle ghost rows are live-elsewhere products). Implemented §3.3 faithfully (exclusion kept), so those ghost **units (36u)** remain counted in the summary total but shown in neither drawer nor orphan panel — the residual tail of RC-4. **Decision needed:** if CS wants stranded off-aisle units surfaced regardless of live-elsewhere status, drop the `live_boonz` exclusion on the off-aisle branch only (one-line change, needs a fresh Cody pass). Not flipped unilaterally — §3.3 is explicit and Cody approved the exclusion-kept version.
2. **Priority reshuffle is ambient, not PRD-105.** `s_expiry` — the only `v_machine_priority` term this PRD can move — is **byte-identical before→after** (0.00 everywhere except MPMCC-1054 = 16.67, unchanged). The recovered batch rows are far-future dates outside the expired/3d scoring windows, so they don't touch `s_expiry`. The large `p_score` swings observed between the two snapshots (AMZ-1038 62.21→18.85, MC-2004 18.88→35.94, ADDMIND 22.95→2.36, NOOK 24.44→1.93) are **ambient recomputation** from live sales/visit/stock clocks, **not attributable to this change**. Net picker effect of PRD-105 today: zero.
3. **Coverage tail unchanged (RC-5, non-goal).** 120 slots with no expiry row / 107 NULL `expiration_date` are a data-capture problem, explicitly out of scope.
4. **88 flagged shelves NOT cleaned** — read-path only, per guardrail; operational sweep is a separate job.

---

## 5. Before/after priority snapshot (audit)

`s_expiry` identical before/after for all 31 machines → PRD-105 contributed **no** priority movement. Full ambient `p_score` deltas retained below for auditability.

| Machine                     | p_score before | p_score after | s_expiry before | s_expiry after |
| --------------------------- | -------------- | ------------- | --------------- | -------------- |
| AMZ-1038-3001-O1            | 62.21 (P1)     | 18.85 (P2)    | 0.00            | 0.00           |
| MC-2004-0100-O1             | 18.88 (P2)     | 35.94 (P1)    | 0.00            | 0.00           |
| HUAWEI-2003-0000-B1         | 35.84 (P1)     | 35.84 (P1)    | 0.00            | 0.00           |
| MPMCC-1058-0000-R0          | 34.40 (P1)     | 34.66 (P1)    | 0.00            | 0.00           |
| ADDMIND-1007-0000-W0        | 22.95 (P1)     | 2.36 (P3)     | 0.00            | 0.00           |
| NOOK-1019-0200-B1           | 24.44 (P1)     | 1.93 (P3)     | 0.00            | 0.00           |
| ACTIVATEMCC-1037-0000-L0    | 3.58 (P3)      | 14.20 (P1)    | 0.00            | 0.00           |
| AMZ-1029-3003-O1 (reported) | 20.30 (P2)     | 1.92 (P3)     | 0.00            | 0.00           |
| MPMCC-1054-0000-M0          | 5.38 (P3)      | 5.61 (P3)     | 16.67           | 16.67          |

(Remaining 22 machines: `s_expiry` 0.00 before and after; `p_score` drift within ambient band.)

---

## 6. Deliverables status

- [x] Migrations `expiry_truth_*` (4) applied to prod.
- [x] FE diff `SnapshotTab.tsx` (boundary), tsc clean.
- [x] `RPC_REGISTRY.md`, `CHANGELOG.md`, `MIGRATIONS_REGISTRY.md`, `METRICS_REGISTRY.md` (expiry row) updated.
- [x] This execution log (md5s, 10 test results, before/after priority).
- [ ] **PROD-SYNC to `main` pending** (not pushed, per goal).
