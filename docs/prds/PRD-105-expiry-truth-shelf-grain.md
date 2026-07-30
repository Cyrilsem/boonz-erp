# PRD-105 — Expiry Truth at Shelf Grain

**Codename:** `expiry-truth` · **Authored:** 2026-07-27 · **Owner:** CS
**Status:** APPLIED to prod 2026-07-28 (read-path only, zero writes) — Cody ✅, acceptance battery green, PROD-SYNC to `main` pending. See `PRD-105-EXECUTION-LOG.md`.
**Trigger:** AMZ-1029-3003-O1 card showed `⚠ 1 expired`; the slot drawer showed `—` on every row.

---

## 0. Why this exists (root cause, verified 2026-07-27 against live prod)

The machine card's expiry KPI and the machine drawer's per-slot expiry are **two separate read paths over `pod_inventory` that share no join key**. The KPI is correct. The drawer is not. Underneath both, the canonical batch view silently discards a third of its input.

**The reported case.** AMZ-1029-3003-O1 (`f1a528fb-15e8-4f20-b4e2-ebb2e6852198`) holds 1 unit of _Activia Mix & Go — Greek Yogurt Honey & Oats_, `expiration_date 2026-07-27`, on shelf `A05`. `v_machine_expiry_summary.expired_units = 1` — right. The drawer's `A05` row renders `expiry_days = NULL` → `—`. Two independent defects hide the same unit.

### Root causes

| RC       | Defect                                                                                                                                                                                                                                                                  | Location                        | Fleet impact (measured)                                                                                                                                                                                                  |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **RC-1** | `product_boonz` collapses a pod product to ONE `boonz_product_id` via `DISTINCT ON (pod_product_name) … ORDER BY … pm.boonz_product_id` — no machine scope (though `product_mapping` is machine-scoped), no `status='Active'` filter, tiebreak = lowest UUID fleet-wide | `get_machine_slots_with_expiry` | Of 626 live stocked slots: **214** show `—` though the shelf has real expiry data, **78** show a date belonging to a different product, **3** show a phantom date                                                        |
| **RC-2** | DB counts `expiration_date <= today` as expired; FE flags red/`EXPIRED` only when `days < 0`                                                                                                                                                                            | `SnapshotTab.tsx:164-178`       | A batch expiring _today_ renders as a calm future date. Exactly the reported case                                                                                                                                        |
| **RC-3** | `v_machine_expiry_batches` dedupes to `max(snapshot_date)` per `(machine_id, shelf_id)`, so sibling variants last touched earlier are dropped **before** the MIN is taken                                                                                               | `v_machine_expiry_batches`      | Discards **285 of 969** expiry rows = **1,083 units** across **28 of 31** machines. Of 461 shelves carrying expiry data, **88 report a wrong earliest date** and **34 report none at all**. This corrupts the KPI itself |
| **RC-4** | Orphan reader only surfaces `shelf_id IS NULL`                                                                                                                                                                                                                          | `get_machine_orphan_expiry`     | **23 rows / 131 units on 4 machines** sit on shelves absent from the live WEIMI aisle — counted in the KPI, invisible in both drawer and orphan panel                                                                    |
| **RC-5** | Expiry coverage gaps                                                                                                                                                                                                                                                    | `pod_inventory` data            | **120** of 626 stocked slots have no expiry row; **107** have `NULL expiration_date`; **266** are stale >14d                                                                                                             |
| **RC-6** | The same wrong `boonz_product_id` is passed to the scorer: `compute_refill_decision(machine_id, shelf_id, pb.boonz_product_id, 10)`                                                                                                                                     | `get_machine_slots_with_expiry` | Final Score / stance / target / refill_qty in the drawer are computed against the wrong variant                                                                                                                          |

**Worked example of RC-1.** `product_mapping` fan-out collapsed to a single arbitrary variant:

| Pod product      | Mappings | Variant the drawer actually reports                           |
| ---------------- | -------- | ------------------------------------------------------------- |
| Chocolate Bar    | 367      | **Oreo Cookie — Regular**                                     |
| Vitamin Well     | 320      | Vitamin Well — Care                                           |
| Soft Drinks Mix  | 250      | **Coca Cola — Zero**                                          |
| Snack Bar        | 207      | McVities Digestive — Mini Dark Chocolate                      |
| Coca Cola Mix    | 120      | **Coca Cola — Zero**                                          |
| Activia Mix & Go | 91       | Greek Yogurt **Rasberry** (`expiration_date IS NULL`) → blank |
| Red Bull         | 84       | Red Bull — **Diet**                                           |

Soft Drinks Mix and Coca Cola Mix both resolve to Coke Zero, which is why `A12` and `A13` on the reported machine display an identical `99d / 19 units` — one shelf's batch rendered on two rows.

**Worked example of RC-3.** AMZ-1029-3003-O1 `A08`:

| Product                      | Expiry     | snapshot_date | Survives the view? |
| ---------------------------- | ---------- | ------------- | ------------------ |
| McVities Mini Milk Chocolate | 2026-10-29 | 2026-06-10    | **dropped**        |
| McVities Mini Dark Chocolate | 2026-12-11 | 2026-06-10    | **dropped**        |
| Nestle Kit-kat Regular       | 2027-01-31 | 2026-07-24    | kept               |

True shelf MIN is 29 Oct 2026. The view reports 31 Jan 2027 — **94 days of false safety**, in the dangerous direction.

**Why this is P1-critical, not cosmetic.** `v_machine_expiry_summary` feeds `v_machine_health_signals` → `v_machine_priority.s_expiry` (`LEAST(100, (expiry_weight_expired * expired_skus_now + expiry_weight_exp3d * expired_skus_3d) / expiry_norm * 100)`, `w_expiry = 0.20`) → `priority_score` → the P1/P2/P3 picker. RC-3 corrupts that input directly. RC-5 means the signal is blind on roughly a third of the fleet. The single slot fleet-wide that genuinely holds expired stock today is unflagged in the drawer — a 1-of-1 miss rate on the exact thing the KPI exists to surface.

**Also noted, not fixed here:** the card badge reads `app_cache` (60s `unstable_cache` + 2min pg_cron) while the drawer calls the RPC live — up to ~3 min of skew between the two numbers.

---

## 1. Objectives

1. **Re-grain the canonical batch dedupe.** `v_machine_expiry_batches` partitions by `(machine_id, shelf_id, boonz_product_id)` instead of `(machine_id, shelf_id)`. Verified pre-condition: **zero collisions** exist at the finer grain today, so nothing legitimate is dropped and the 285 discarded rows return. _(RC-3)_
2. **Key the drawer's expiry by `shelf_id`, not by product name.** Delete `product_boonz`, `product_expiry`, `prod_nearest_date`, `prod_nearest` from `get_machine_slots_with_expiry`. Replace with a shelf-keyed `MIN(expiration_date)` CTE. Verified pre-condition: `shelf_id` resolves on **626/626** live stocked slots and **0** `pod_inventory` rows have a NULL `shelf_id`. _(RC-1, RC-6)_
3. **`Exp. Qty` = units in the batch(es) defining the MIN**, always — drop the `<= 7 days` window that currently blanks the column for anything further out. _(RC-1)_
4. **Fix the "today" boundary in the FE.** `days < 0` → `days <= 0` in both `expiryDayClass` and `expiryDaysToDate`. _(RC-2)_
5. **Extend the orphan reader** to surface batches whose `shelf_id` is not present in the machine's live WEIMI aisle, not only `shelf_id IS NULL`. _(RC-4)_
6. **Guarantee reconciliation.** For any machine, the drawer's expired units MUST sum to `v_machine_expiry_summary.expired_units`. This becomes a standing invariant test, not a one-off check.
7. **Clear the operational backlog** surfaced by `Boonz_Expiry_Blind_Spots_2026-07-27.xlsx` — 88 shelves / 357 units, 4 of them within 30 days.

## 2. Non-goals

- Fixing `pod_inventory` coverage (RC-5). The 120 slots with no expiry row and 107 with `NULL expiration_date` are a **data-capture** problem, not a read-path problem. Separate goal.
- Removing the `app_cache` staleness skew between card and drawer.
- Re-modelling batch granularity (see §7, Open Question).
- Touching the picker weights. `s_expiry` values will move because the input is corrected; the weights themselves stay.

## 3. Design (Dara, complete)

### 3.1 Change 1 — `v_machine_expiry_batches`

```sql
CREATE OR REPLACE VIEW public.v_machine_expiry_batches AS
WITH ranked AS (
  SELECT pi.pod_inventory_id, pi.machine_id, pi.shelf_id, pi.boonz_product_id,
         pi.batch_id, pi.expiration_date, pi.current_stock, pi.snapshot_date,
         ROW_NUMBER() OVER (
           PARTITION BY pi.machine_id,
                        COALESCE(pi.shelf_id::text, 'noshelf'),
                        pi.boonz_product_id              -- <<< was: shelf only
           ORDER BY pi.snapshot_date DESC, pi.pod_inventory_id
         ) AS rn
  FROM public.pod_inventory pi
  WHERE pi.status = 'Active' AND pi.current_stock > 0
)
SELECT pod_inventory_id, machine_id, shelf_id, boonz_product_id,
       batch_id, expiration_date, current_stock, snapshot_date
FROM ranked WHERE rn = 1;
```

Rationale: a newer KitKat snapshot carries no information about whether the McVities row on the same shelf is still valid. `snapshot_date` is written per row by `adjust_pod_inventory` / dispatch confirm, never as a whole-shelf replacement, so shelf-grain dedupe was never sound.

### 3.2 Change 2 — `get_machine_slots_with_expiry`

```sql
shelf_expiry AS (
  SELECT b.shelf_id,
         MIN(b.expiration_date) AS min_exp,
         SUM(b.current_stock) FILTER (
           WHERE b.expiration_date <= (SELECT today FROM dubai)) AS expired_qty
  FROM public.v_machine_expiry_batches b
  WHERE b.machine_id = (SELECT machine_id FROM machine)
    AND b.shelf_id IS NOT NULL AND b.expiration_date IS NOT NULL
  GROUP BY b.shelf_id
),
shelf_min_batch AS (
  SELECT se.shelf_id, se.min_exp, se.expired_qty,
         SUM(b.current_stock) AS min_exp_qty
  FROM shelf_expiry se
  JOIN public.v_machine_expiry_batches b
    ON b.shelf_id = se.shelf_id AND b.expiration_date = se.min_exp
  GROUP BY se.shelf_id, se.min_exp, se.expired_qty
)
-- LEFT JOIN shelf_min_batch sx ON sx.shelf_id = ai.shelf_id
-- expiry_days := (sx.min_exp - today)::int
-- expiry_qty  := sx.min_exp_qty                 <<< unconditional, no 7d window
-- nearest_expiry_days / _qty := same values (FE compat; Stax simplifies later)
```

**Dependent call site.** Removing `product_boonz` orphans `compute_refill_decision(ai.machine_id, ai.shelf_id, pb.boonz_product_id, 10)`. Least-change resolution: pass the shelf's highest-stock `boonz_product_id`. This is an RPC-body decision — implementer's call, Cody rules.

### 3.3 Change 3 — `get_machine_orphan_expiry`

Replace `AND b.shelf_id IS NULL` with: `shelf_id IS NULL` **OR** `shelf_id` not present in the machine's live `v_live_shelf_stock` aisle. Keep the existing `boonz_product_id NOT IN live_boonz` exclusion.

### 3.4 Index

```sql
CREATE INDEX IF NOT EXISTS idx_pod_inventory_active_shelf_expiry
  ON public.pod_inventory (machine_id, shelf_id, expiration_date)
  WHERE status = 'Active' AND current_stock > 0;
-- Serves the v_machine_expiry_batches base scan and the per-shelf MIN grouping in
-- get_machine_slots_with_expiry and v_machine_expiry_summary.
```

### 3.5 FE

`boonz-erp/src/app/(app)/refill/SnapshotTab.tsx`

- L164 `expiryDayClass`: `if (days < 0)` → `if (days <= 0)`
- L171 `expiryDaysToDate`: `if (days < 0) return "EXPIRED"` → `if (days <= 0) return "EXPIRED"`

### 3.6 RLS

No change. Both objects are read-only projections over `pod_inventory` (protected, Appendix A) and inherit its policies. `get_machine_slots_with_expiry` is `LANGUAGE sql STABLE` with invoker rights, so RLS still applies. **If anyone later promotes these to materialized views for the `app_cache` path, RLS bypass becomes a live Article 2 question** — out of scope here, flagged deliberately.

### 3.7 Rejected alternatives

- **Patch `product_boonz` in place** (add machine scope + `status='Active'` + expand beyond `DISTINCT ON`). Fixes the symptom but keeps identity keyed on a raw name string, downstream of `v_live_shelf_stock`'s four-tier name resolver which already exposes `pod_product_id`. Re-deriving identity from text after a resolver has run is strictly worse than using the FK.
- **Drop the dedupe entirely.** Zero collisions today means it does no useful work — but nothing at schema level enforces one Active row per `(machine, shelf, product)`. Keep it as a cheap guard at the correct grain.

## 4. Guardrails (hard)

- **Cody mandatory** on both view replacements, the function replacement, and the index. `pod_inventory` is Appendix A protected.
- **Read-path only. Zero writes.** No migration in this PRD may INSERT, UPDATE or DELETE any row of `pod_inventory` or any other protected table. If a step appears to need a write, stop and escalate.
- **Byte-identical rollback:** record md5 of every replaced view/function body in the execution log before replacing.
- **No git push.** Apply via Supabase MCP migrations named `expiry_truth_*`; a separate PROD-SYNC to `main` follows.
- **Expect P1/P2/P3 ordering to move** on the next picker run. That is the intended effect. Capture a before/after `priority_score` snapshot for all Active machines so the shift is auditable rather than a surprise at 8pm.
- **Do not clean the 88 flagged shelves as part of this goal.** Correcting the read path is the fix; the operational sweep is a separate DICTATED-path job driven by the delivered workbook.

## 5. Acceptance tests

1. **Reported case resolves.** `get_machine_slots_with_expiry('AMZ-1029-3003-O1')` returns `A05` with `expiry_days = 0` and `expiry_qty = 1`; the FE renders it red as `EXPIRED`.
2. **Reconciliation invariant.** For every Active machine: `SUM(expired units in drawer rows) = v_machine_expiry_summary.expired_units`. Must hold for **all 31** machines, not a sample.
3. **RC-3 recovery.** Row count of `v_machine_expiry_batches WHERE expiration_date IS NOT NULL` rises from **684 to 969**; units from the current total by **+1,083**.
4. **A08 case corrects.** AMZ-1029-3003-O1 `A08` reports earliest expiry **2026-10-29** (was 2027-01-31), qty 9.
5. **No more cross-shelf bleed.** AMZ-1029-3003-O1 `A12` and `A13` no longer report identical `99d / 19u`; each reflects its own shelf.
6. **Blind-spot list empties.** Re-running the §0 comparison query returns **0 rows** where true shelf MIN ≠ reported MIN (baseline: 88).
7. **Orphan reader catches ghosts.** `get_machine_orphan_expiry` surfaces the C02/C03/D01/E01 rows on AMZ-1029-3003-O1 (baseline: 0 rows returned).
8. **No regression on clean shelves.** Diff drawer output for a single-variant shelf (e.g. `A15` Al Ain Water) pre/post → identical.
9. **Scoring intact.** `compute_refill_decision` still returns a non-null decision for every slot; no slot loses its Final Score.
10. **Invariant battery green** — cap, runway, procurement_gaps, source_origin propagation.

## 6. Deliverables

- Migrations `expiry_truth_*`: `v_machine_expiry_batches` vNext, `get_machine_slots_with_expiry` vNext, `get_machine_orphan_expiry` vNext, the partial index.
- FE diff on `SnapshotTab.tsx` (boundary fix) — Stax, reviewed by Cody.
- Updated `RPC_REGISTRY` + `CHANGELOG`.
- **`PRD-105-EXECUTION-LOG.md`**: replaced-body md5s, acceptance-test results, before/after `priority_score` snapshot for all Active machines.
- Closing note: PROD-SYNC to `main` pending.

## 7. Open question (deliberately not answered here)

`adjust_pod_inventory` **merges** a new delivery into the existing row for that product on that shelf. Two physical cases of the same SKU with different expiry dates collapse into one row and **one of those dates is lost**. That is why a unique index on `(machine_id, shelf_id, boonz_product_id) WHERE status='Active' AND current_stock > 0` was _not_ proposed — it would cement a modelling limitation rather than expose it.

The question for a later PRD: **does Boonz want per-batch expiry granularity in `pod_inventory`?** If yes, the merge behaviour changes and the dedupe in §3.1 can be removed entirely. If no, the unique index should be added to make today's convention a real invariant. Either answer is defensible; silently keeping the current ambiguity is not.
