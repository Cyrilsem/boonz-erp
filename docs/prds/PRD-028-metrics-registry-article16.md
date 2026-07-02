# PRD-028 — Metrics Registry execution + Article 16 ratification

**Status:** Applied (in prod; git sync pending - 6 commits sit on unmerged branch feat/prd-028-metrics-registry, tip 9b0a6c2; docs salvaged by PRD-071 WS-E). Article 16 ratified; canonical objects verified live in prod 2026-07-02 (v_wh_pickable, v_dispatch_availability) · **Owner:** CS · **Created:** 2026-06-11 · **Driver doc:** `docs/architecture/METRICS_REGISTRY.md`

## Problem

Three production incident classes in June 2026 shared one root cause: the same business metric computed
independently by multiple surfaces (machine priority: 3 definitions; payment-default reconciliation: 3
formulas, none netting refunds; expiry: tier logic and card badge disagree on the same screen today).
Unification killed each bug class permanently (v_machine_priority, get_payment_default_summary,
resolve_refill_plan_date). This PRD finishes the job and makes the rule constitutional.

## Goal

Every metric in METRICS_REGISTRY.md has exactly one canonical DB object; all consumers read it;
Article 16 ratified; Cody enforces.

## Workstreams (execution order; each = Dara design → Cody review → migration → consumer verify)

**WS1 (P0) — Expiry unification.**
Designate `v_machine_expiry_summary` canonical. Rewire `v_machine_health_signals.expired_skus_now/_3d/_7d/_30d`
to consume it (NOT recompute). Verify `get_machine_expiry_detail` + `get_machine_slots_with_expiry` use the
same batch-resolution rule (latest Active batch per shelf). AC: for every machine,
`v_machine_priority.expired_skus_now == get_machine_health().expired_units` — zero disagreements.
Known live repro: OMDBB-1020 (tier says expired=1, badge says 0).

**WS2 (P1) — Velocity rollup.**
One machine-level velocity object (proposal: thin `v_machine_velocity` over sales_history; signals +
get_machine_health consume). AC: get_machine_health.daily_velocity == canonical for all machines; no inline
SUM(sh.qty)/7 outside the canonical object.

**WS3 (P1) — WH pickable + dispatch availability.**
Create `v_wh_pickable` (Active, NOT quarantined, expiry ≥ today OR NULL). Verify/redefine
`v_dispatch_availability`: available = pickable − open commitments (unpacked+unpicked, current dispatch_date
only — the stale-line class is already auto-released nightly). Wire packing FE badges (WH / Committed /
Available) to it. AC: Simran's Sunblast case renders WH 5 | Committed 0 | Available 5.

**WS4 (P1) — Reconciliation banner wiring.**
/app/performance (ribbon + dark bar), /refill/consumers, /consumers_vox all render from ONE call to
`get_payment_default_summary` with identical scope (decide: venue_group='VOX' vs explicit machine list —
resolves the 3-refs/84-AED drift). Show refunds + cash as their own fields. AC: three pages equal to the
cent for any period; table row deltas sum to banner gap.

**WS5 (P2) — Active-fleet scope view.**
`v_active_fleet(machine_id, official_name, venue_group, service_track)` with the canonical
include/status filters; report RPCs + pickers consume it. AC: no per-RPC WHERE drift on fleet scope.

**WS6 — Ratify.**
Article 16 text (from METRICS_REGISTRY.md) into 01_constitution.html. Cody SKILL.md review playbook gains:
"computes a registered metric inline → block". CHANGELOG + RPC_REGISTRY updated per WS.

## Constraints

- Canonical writers untouched except where a WS names them; all `CREATE OR REPLACE` through Cody.
- No metric VALUE may change silently: each WS documents before/after for any number that moves
  (expected: expiry badge counts converge; packing Available rises after WS3).
- FE: no `git add -A` (dirty working tree); surgical commits per WS on a `feat/prd-028-metrics-registry` branch.
- `resolve_refill_plan_date()` for any plan-date logic; never CURRENT_DATE.

## Out of scope

Engine/refill quantity logic (already canonical), FEFO write-path expiry checks (point-of-action logic is
legitimate), pod_inventory batch-closing reconcile flow (BUG-007 family — separate PRD).
