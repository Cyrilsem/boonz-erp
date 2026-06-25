# PRD-058 — Tunable P1/P2 Priority Weights + Dead-Stock Dial

Status: APPLIED to prod 2026-06-24 (migration `prd058_tunable_priority_weights`); MERGED to main via PR #5 (merge `f6195be`) 2026-06-25; prod deploy pending Vercel + record-prod-deploy. T1 golden md5 `6bb5b9cbd44aa0f10f0519f7f6579dcb` byte-identical; seed=defaults; single-row guard live. Dara ✅ Cody ✅.
Owner: CS · Author: Cowork conductor · Date: 2026-06-24
Scope: backend (one canonical view) + one config table. No FE logic change required.

## Problem

P1/P2 machine classification (shown on Stock Snapshot as "P1 restock / P2 maintain"
and consumed by the daily picker) is decided in ONE place: the view
`public.v_machine_priority`. It is consumed by both `get_machine_health()` (cards)
and `pick_machines_for_refill` (v8 picker). Confirmed: the picker references
`v_machine_priority` directly.

Today both the `p_tier` thresholds and the additive `p_score` are hard-coded SQL.
Two consequences CS wants fixed:

1. **Dead stock is not dialable.** Expired SKUs hard-force P1 (+20 score) and dead
   slots push P2 (+10), with no knob to raise or lower their influence. CS wants to
   be able to prioritize OR deprioritize dead stock at will.
2. **No control over the balance** CS actually cares about: stock availability
   (fill / runway / empty shelves), velocity (units_7d), and time since last refill
   (days_since_visit). The inputs exist in `v_machine_health_signals`; only the
   weights are frozen in the view body.

Note (separate, out of scope here): the expiry signal feeding this view counts only
Active `pod_inventory` batches and includes NULL-shelf orphan batches for products no
longer on the planogram — that is a data-hygiene/display issue tracked separately, not
a P1/P2 scoring change.

## Goal

Make P1/P2 tier thresholds and the priority score **config-driven** via a single
params row, so CS can retune (especially the dead-stock dial) with a one-row UPDATE,
no migration, and have the cards + picker respond immediately. Behavior must be
byte-identical to today when params hold the current baked-in defaults.

## Design

### A. New config table `refill_priority_params` (Dara to finalize)

Single-row (`id smallint PK default 1`, CHECK id=1) of tunable numerics. Starter set,
named to map 1:1 onto the current view math so the golden test can prove equivalence:

- Availability: `w_empty_base`, `w_empty_step`, `w_empty_cap`, `w_runway_lt2`,
  `w_runway_strong_lt4`, `w_runway_lt3`, `w_runway_lt5_vel30`, `w_fill_lt40_vel20`,
  `w_fill_lt50_vel20`, `w_fill_lt60_vel50`, `w_under25_step`, `w_under25_cap`
- Velocity: `w_high_velocity` (units_7d>=50)
- Recency: `w_stale_21`, `w_stale_14`, `w_stale_10`
- Dead stock (the dial): `w_expired_now`, `w_dead_slot_30`, `w_dead_slot_15`,
  `dead_stock_forces_p1 boolean`, `p1_expired_min_skus`, `p2_dead_slot_pct`,
  `p2_stale_days`
- Tier thresholds: `p1_runway_crit`, `p1_strong_units`, `p1_strong_runway`,
  `p1_fill_pct`, `p1_fill_units`, `p1_under25_count`, `p1_under25_units`
- `w_intent`, plus `updated_at`, `updated_by`

Seed the row with EXACTLY the values currently baked into `v_machine_priority`.

### B. Rewrite `v_machine_priority`

`CROSS JOIN refill_priority_params p` and replace every literal in the `p_tier` CASE
and the `p_score` sum with the corresponding `p.<weight>`. `reasons_arr` logic
unchanged. The `dead_stock_forces_p1` flag gates whether `expired_skus_now >=
p1_expired_min_skus` is allowed into the P1 branch (set false to deprioritize dead
stock out of P1; raise `w_expired_now` to prioritize it in ranking).

### C. No code change to consumers

`get_machine_health()` and `pick_machines_for_refill` are untouched — they read the
view as-is.

## Governance

`v_machine_priority` is a canonical Metrics Registry object (Article 16). This is a
canonical-writer change → Dara designs the table + view diff, Cody reviews
(Hard Rule 6) before apply. Forward-only migration. swaps_enabled stays false;
engine_add_pod / engine_swap_pod untouched.

## Acceptance tests

- T1 GOLDEN: with the seeded default row, `SELECT machine_id, p_tier, p_score,
reasons_arr FROM v_machine_priority` is byte-identical to a snapshot taken before
  the change (full fleet). This proves zero behavioral drift on deploy.
- T2 DIAL DOWN: set `dead_stock_forces_p1=false` + `w_expired_now=0`; machines whose
  ONLY P1 reason was `expired_now` drop out of P1; no other machine changes tier.
- T3 DIAL UP: raise `w_expired_now`; affected machines' `p_score` rises by exactly
  the delta, tier unchanged unless a threshold is crossed.
- T4 REBALANCE: bump `w_high_velocity` / `w_stale_*` / availability weights; verify
  `p_score` deltas equal the param deltas (arithmetic check).
- T5 picker parity: `pick_machines_for_refill` for a test date returns the same set
  under default params as before (depends on T1).
- T6 single-row guard: cannot insert a second params row.

## Rollback

`refill_priority_params` is data; reset the row to seeded defaults to restore current
behavior instantly. View can be reverted to the prior `CREATE OR REPLACE` body.

## Out of scope

Expiry data hygiene (NULL-shelf orphan batches, Inactive-stock visibility, per-slot
drawer Exp Qty) — separate ticket.
