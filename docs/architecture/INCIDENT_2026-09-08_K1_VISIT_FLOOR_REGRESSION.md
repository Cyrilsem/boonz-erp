# Incident — 2026-09-08/09 — K1 visit-aware floor refused ~80 warehouse lines

**Severity:** S1 (live production blocker, no data loss — every affected line was refused, not corrupted)
**Introduced by:** PRD-119 D4 correction, `20260908071626_prd119_d4_correction_k1_visit_aware_floor.sql`
**Status:** Resolved. Guard fixed and live, fleet data cleaned, nightly detection added.
**Owner:** CS. Fix: assistant. Constitutional review: Cody.

---

## 1. TL;DR

The D4 correction replaced `approve_refill_plan`'s K1 short-dated guard with a visit-aware floor:
`expiry_date <= plan_date + GREATEST(7, days_to_next_planned_visit + 3)`. `days_to_next_planned_visit`
read the machine's nearest future `machines_to_visit` row with `status IN ('picked','cs_added')`, with
no upper bound on how far out that row could be.

`machines_to_visit` turned out to carry 64 `status='picked'` rows dated in **2030** — not typos, but
the residue of exploratory calls against `pick_machines_for_refill` (which has no upper bound on its
own `p_plan_date` argument) using far-future dates specifically to avoid colliding with real near-term
routing. For the 12 machines carrying one of these rows, `days_to_next_planned_visit` computed to
~1,500 days, the floor became ~1,500 days, and every Refill/Add New line on those machines was refused
regardless of how far out its real expiry was. Hit live 2026-09-09: ~80 lines refused.

## 2. Fix (three parts, all live)

1. **`20260908191503`** — capped the guard: `GREATEST(7, LEAST(COALESCE(next_visit_days + 3, 7), 21))`,
   and the next-visit lookup now ignores any `machines_to_visit` row more than 60 days past `plan_date`.
   Two independent defenses — the 60-day filter excludes a 2030 row from the calculation outright; the
   21-day cap protects even if a bad row somehow passes the filter. The `COALESCE(...,7)` is load-bearing:
   nesting a bare `GREATEST(7, LEAST(x+3, 21))` would have silently broken the "no visit known → 7-day
   floor" case, because `LEAST(NULL, 21)` evaluates to `21`, not `NULL` (Postgres `LEAST`/`GREATEST`
   ignore NULL operands rather than propagating them).
2. **64 poisoned rows unpicked fleet-wide** via the canonical `unpick_machine_to_visit` RPC (never a
   direct UPDATE) — confirmed 0 `status='picked'` rows remain past 30 days.
3. **`20260908191820`** — `check_far_future_picked_visits()`, nightly at 20:20 UTC, alerts if any
   `picked` row is ever more than 30 days ahead again.

## 3. Verification

- Reproduced live before the fix: 17 real lines on 2026-09-08's pending plan, across 4 machines, were
  being wrongly refused by the unbounded formula. All 17 confirmed to pass under the capped formula
  before it was applied; confirmed 0 still wrongly refused immediately after.
- Fixture (rolled back, real machine `ACTIVATE-2005-0000-W0`, synthetic `2099-06-01` rows, a poisoned
  `2030-01-04` pick row inserted alongside): a normal Refill/Add New line at expiry+10d approved cleanly
  (`status: 'ok'`) with the 2030 row present — proving the guard is robust independent of the cleanup.
  Companion checks: dairy at expiry+4d still refused (7-day minimum intact); a legitimate visit 40 days
  out correctly caps the floor at 21 (a line at expiry+25d passes, since 25 > 21 — exactly the case the
  old unbounded formula would have wrongly refused at 25 ≤ 43).
- Cleanup verified via `unpick_machine_to_visit`'s own return values (all 64 calls returned
  `dropped: 1`, none zero/null) and a follow-up count query (0 `picked` rows > 30 days out).
- Nightly assertion verified clean against the real post-cleanup fleet, and fires correctly against a
  synthetic far-future row.

## 4. Root cause — not fixed here, flagged for CS

`pick_machines_for_refill(p_plan_date, ...)` validates `p_plan_date < CURRENT_DATE - 7` (no more than
7 days in the past) but has **no upper bound**. It will INSERT real `status='picked'` rows for any
future date, including 2030, with no dry-run isolation from production data. The bad rows' signature
(12 machines, created 2026-07-30 through 2026-08-14, `add_source` `'picker'`/`'operator'`, several
clustered on identical sequential dates — e.g. `FX58-K1/K2/K4/K5` picked identically across 10
consecutive days in March 2030) is consistent with someone testing or demoing the picker against
arbitrary future dates, not a data-entry typo.

**Recommended follow-up (not done in this incident fix — changes the automated picker's own behavior
and deserves its own review):** reject `p_plan_date > CURRENT_DATE + 30` (or similar) in
`pick_machines_for_refill` itself, so this class of row can't be created again by any caller.

## 5. Cody

**Verdict:** ✅ Approve
**Articles checked:** 1, 4, 5, 12, 16
**Findings:**

- Article 1 ✅ — `approve_refill_plan` remains the sole approval gate; no new write path. Cleanup used
  the canonical `unpick_machine_to_visit`, never a direct UPDATE on `machines_to_visit`.
- Article 12 ✅ — both migrations are forward-only, md5-guarded `replace()` patches; item C's unbound
  check, the K1 NULL-expiry exemption, and the 48h absolute floor are byte-identical to the prior live
  function.
- Article 16 ✅ — the nightly assertion reads no new metric, just guards the existing canonical guard's
  own input table for a known-recurring data-quality defect.
- Root cause gap (§4) is a real, separate Article-5-adjacent concern (an RPC's own state-machine input
  has no bound) — correctly scoped OUT of this incident fix and flagged rather than silently left
  undocumented.

## 6. Registries updated

`MIGRATIONS_REGISTRY.md` (3 new rows), `RPC_REGISTRY.md` (`check_far_future_picked_visits` entry),
this incident file. `docs/prds/PRD-119-CLOSEOUT-FOLLOWUP-REPORT.md`'s D4 CORRECTION section not
re-opened — this is a regression IN that correction, filed as its own incident per this repo's
existing `INCIDENT_*` convention (see `INCIDENT_2026-04-26_NON_CANONICAL_WRITES.md`).
