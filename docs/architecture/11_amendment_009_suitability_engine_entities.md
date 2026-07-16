# Amendment 009 — Suitability Swap Engine: Appendix A additions + monitors

**Status:** Draft, pending ratification by CS
**Filed:** 2026-07-12
**Articles invoked:** 15 (declare invariants / Appendix A scope); references Articles 1, 2, 8, 11

---

## Context

The 2026-07-12 suitability swap engine build (Wave 1 + Wave 2) introduced one new reference
table and one new schema column on a protected entity, plus read-only monitors. This amendment
reconciles Appendix A and records the constitutional posture, per the pattern of Amendment 003.

## Proposed Appendix A addition

| Table              | Introduced                          | Role                                                                                                                                                                                                                                                                                                            |
| ------------------ | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `product_size_fit` | 2026-07-12 (wave1_product_size_fit) | Per-(pod_product, shelf_size) fit + capacity + `min_refill_qty`. Engine-load-bearing: the swap engine's min-quantity gate reads `min_refill_qty`; `rank_slot_suitability` reads `fits`/`cap_typical`. RLS enabled, read policy mirrors `capacity_standard`, no write policies (service_role/owner writes only). |

## Schema change recorded on an existing protected entity

- `shelf_configurations.shelf_size` (text, CHECK Small/Medium/Large or NULL) added + backfilled 2026-07-12
  via `wave1_shelf_size_backfill` under the operator migration path with audit GUCs set
  (`app.via_rpc='true'`, `app.rpc_name='wave1_shelf_size_backfill'`) so `tg_audit_shelf_configurations`
  captured every row. One-time backfill via direct UPDATE is the sanctioned Phase-A migration pattern;
  it is NOT a runtime write path.

## Article 1 follow-up (ongoing maintenance)

`shelf_configurations.shelf_size` must be maintained by a canonical writer going forward — when a shelf
is reconfigured or a machine onboarded, the size must be set through the shelf-config / onboarding RPC,
not ad-hoc UPDATEs. Tracked as an open item; the one-time backfill does not itself require a new RPC.

## New canonical / helper objects

- `rank_slot_suitability(date,uuid,uuid,uuid,int,uuid[])` — READ-ONLY helper, SECURITY INVOKER, STABLE,
  no writes. Registered in RPC_REGISTRY read-only helpers. Consumed by `engine_swap_pod` Pass 2a.
- `engine_swap_pod` — unchanged canonical writer of `pod_swaps` (Appendix A per Amendment 003); Pass 2a
  now consults `rank_slot_suitability`. GUCs, role guard, audit, guards preserved.
- Monitors (read-only views + Article-11-compliant alert crons, calling a single RPC each):
  `v_wh_routing_gaps` + `cron_wh_routing_gap_alert()` (pg_cron `wh_routing_gap_nightly`, 0 3 * * * UTC);
  `v_coexistence_violations` (view only). `monitoring_alerts` is not a protected entity.

## What CS ratifies

1. `product_size_fit` added to Appendix A.
2. `shelf_configurations.shelf_size` recorded; ongoing maintenance routed through a canonical writer (open item).
3. `rank_slot_suitability` filed as a read-only helper; `engine_swap_pod` change is narrow-concern per Amendment 005.
4. The two monitors + the nightly routing cron are Article-11 compliant (cron calls one RPC, no business logic in the cron body).

## Rollback

Documentation-only amendment. The underlying migrations have their own rollback SQL in MIGRATIONS_REGISTRY.
