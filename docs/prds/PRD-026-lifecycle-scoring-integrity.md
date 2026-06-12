# PRD-026: Lifecycle Scoring Integrity (10k Sales Cap, Velocity Floor, Trend Rule)

**Date:** 2026-06-12
**Status:** Draft, awaiting CS approval (thresholds in §4 need CS sign-off)
**Severity:** High. Stances are visibly wrong (selling slots labeled DEAD / ROTATE OUT / WIND DOWN), and the same corrupted velocities feed ENGINE ADD dead-tagging, i.e. the swap engine can swap out selling shelves.
**Owner:** Stax (edge function) → Cody (slot_lifecycle feeds the engines)
**Component:** edge function `evaluate-lifecycle` v13.1

---

## 1. Problems (all verified live 2026-06-12)

### P1: silent sales truncation, worsening weekly ⛔

The function fetches sales with `.limit(10000)`:

```ts
.from("sales_history").select(...).eq("delivery_status","Successful")
  .gte("transaction_date", now-62d).limit(10000)
```

The 62-day window already holds **10,219** rows. 200+ rows are silently dropped today, more every week, with no ORDER BY, so WHICH rows drop is arbitrary. Affected slots get understated v7/v14/v30 → wrong scores, wrong stances, and false `velocity=0` reads that ENGINE ADD turns into dead-tags → swap engine removes selling products. This is the fetch-then-filter row-cap class of bug (same family as the /app/performance VOX undercount).

### P2: relative scoring condemns good absolute sellers

`spectrum_ratio = slot_v30 / fleet_per_slot_avg_v30(same product)`; `local_score = clip(ratio × 5)`. For high-volume products the bar is enormous:

- IFLYMCC Aquafina, 36 units/30d → ratio 0.11 → **DEAD, SWAP NOW**
- MPMCC-1058 Aquafina, 112 units/30d → ratio 0.34 → **ROTATE OUT**
- VOXMM Aquafina, 174 units/30d → ratio 0.53 → **WIND DOWN**

### P3: trend overrides absolute strength

Rule `score >= 4 AND trend < 4 → WIND DOWN` has no upper guard:

- VOXMCC A06 Pepsi Regular: score **9.36**, ratio 1.87 → WIND DOWN
- ALJLT A09 Barebells: score 8.43 → WIND DOWN

### P4 (note): dark machines keep stale stances frozen

Machines with no sales in 14d are skipped by scoring (except ramping), so their last stances persist indefinitely. Acceptable, but display should mark them stale.

## 2. Fix P1: remove the row cap

Either paginate the PostgREST fetch (`.range()` loop until short page), or better, replace the client-side aggregation with a SQL source: a view/RPC `v_lifecycle_daily_sales(machine_id, pod_product_id, day, qty)` aggregated server-side over 62 days. Server-side aggregation also cuts function runtime and memory. Add a hard assertion: if fetched rows = limit, fail loudly rather than score silently.

## 3. Fix P3: guard the trend rule

```
score >= 8  AND trend < 4  → PLATEAU (display) or KEEP   — never WIND DOWN
score >= 6  AND trend < 4  → WATCH
score >= 4  AND trend < 4  → WIND DOWN (unchanged)
```

## 4. Fix P2: absolute velocity floor before any negative stance

Proposed (CS to confirm thresholds):

- `v30 >= 1.0/day` (30+ units/month): stance can never be worse than WATCH.
- `v30 >= 0.5/day` (15+ units/month): never ROTATE OUT or DEAD.
- DEAD requires literal zero sales 30d (aligns with ENGINE ADD's definition: v7=0 AND v30=0).
  Relative ranking remains for placement decisions (where a product works best); it stops condemning slots that cover their shelf rent.

## 5. Verification

1. Re-run scoring; assert row-fetch count < limit (or pagination loop ran clean).
2. Regression set: the 25 mis-stanced examples from the 2026-06-12 review (BOONZ BRAIN/refill_review_2026-06-12.md §4) all resolve to non-absurd stances (no DEAD/ROTATE OUT above the floor).
3. Diff stance distribution before/after; CS eyeballs the delta (expect large WIND DOWN reduction).
4. Confirm ENGINE ADD dead-tag count on next plan build does not include any shelf with v30 > 0 in raw sales_history.

## 6. Acceptance criteria

- [x] No silent truncation possible. v14 paginates (.range pages of 10,000, ordered transaction_date+transaction_id) and THROWS at the 30-page cap instead of scoring on partial data. Deployed 2026-06-12 (platform version 23); first run fetched 10,223 rows across 2 pages (v13.1 was silently dropping ~220).
- [x] Velocity floor + trend guard live with CS-CONFIRMED thresholds (2026-06-12): v30 >= 0.5/day never ROTATE OUT/DEAD; v30 >= 1.0/day never below WATCH; DEAD requires literal zero 30d sales; score >= 8 + flat trend -> KEEP, score >= 6 -> WATCH.
- [x] Regression set green: fleet-wide floor assertions all zero (the single DEAD-with-sales row is a stale pre-v14 stance on dark ALJLT-1015-0100-B1, documented P4 freeze). Named slots: IFLYMCC Aquafina DEAD->WATCH, MPMCC-1058 ROTATE OUT->WATCH, VOXMM WIND DOWN->WATCH, VOXMCC A06 Pepsi 9.39 ->KEEP, ALJLT A09 Barebells 7.94 ->WATCH. Distribution: WIND DOWN 109->80, DEAD 91->51, WATCH 11->39, KEEP 138->148. One-week zero-report criterion accrues to ~2026-06-19.
