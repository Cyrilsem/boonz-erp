# Amendment 001 — Appendix A Reconciliation

**Status:** Draft, pending ratification
**Filed:** 2026-04-26
**Article amended:** 15 (governance) — invokes the amendment process to update Appendix A of the Constitution
**Trigger event:** A.4 trigger install discovered that 6 of the 16 entities listed in Appendix A do not exist in `public` under those names

---

## Context

Article 8 lists 16 protected entities by name. When A.4 attempted to install audit triggers on each of them, a name-vs-schema audit revealed that the Constitution's Appendix A was authored from an aspirational naming scheme that diverged from the live schema. As a result, A.4 was applied to the 10 unambiguous tables only; the remaining 6 were deferred until this amendment is ratified.

This is exactly the kind of drift Article 15 was designed to handle: the live schema is the reality, the Constitution is the contract, and when they disagree the contract must be updated through the amendment process — not silently mutated.

## Findings

The names in Appendix A vs the live tables in `public.*`:

| Constitution name (Appendix A) | Live table | Action |
|---|---|---|
| `machines` | `machines` ✅ | No change |
| `shelf_configurations` | `shelf_configurations` ✅ | No change |
| `planogram` | `planogram` ✅ | No change |
| `sim_cards` | `sim_cards` ✅ | No change |
| `slot_lifecycle` | `slot_lifecycle` ✅ | No change |
| `pod_inventory` | `pod_inventory` ✅ | No change |
| `pod_inventory_audit_log` | `pod_inventory_audit_log` ✅ | No change |
| `warehouse_inventory` | `warehouse_inventory` ✅ | No change |
| `refill_plan_output` | `refill_plan_output` ✅ | No change |
| `daily_sales` | (does not exist) | **Rename in Appendix A → `sales_history`** |
| `sales_lines` | (does not exist) | **Remove** — was a planned split that never landed; sales remain row-per-transaction in `sales_history` |
| `sales_aggregated` | (does not exist) | **Rename in Appendix A → `sales_history_aggregated`** (matview) |
| `dispatch_plan` | (does not exist) | **Rename in Appendix A → `refill_dispatch_plan`** |
| `dispatch_lines` | (does not exist) | **Rename in Appendix A → `refill_dispatching`** |
| `settlements` | (does not exist) | **Remove** — settlements are computed views on top of `sales_history`; no underlying mutable table exists |
| `slots` | (does not exist) | **Remove** — slot rotation lifecycle is captured in `slot_lifecycle`, which is already protected |
| `warehouse_inventory_audit_log` | (does not exist; live name is `inventory_audit_log`) | **Rename in Appendix A → `inventory_audit_log`** |

## Proposed Appendix A v2

The protected-entity list becomes (15 entries, alphabetised):

```
inventory_audit_log
machines
planogram
pod_inventory
pod_inventory_audit_log
refill_dispatch_plan
refill_dispatching
refill_plan_output
sales_history
sales_history_aggregated
shelf_configurations
sim_cards
slot_lifecycle
warehouse_inventory
write_audit_log     ← NEW (added by A.3, formally listed here)
```

15 entries, all live tables. Materialized views (`sales_history_aggregated`) are protected at the refresh-function level rather than by RLS (matviews don't support RLS) — see Article 9.

## Consequences

**A.4.b** (follow-up migration, name `phaseA_a4b_install_audit_triggers_remainder`) installs the remaining triggers:

| Table | PK column | RLS state | Notes |
|---|---|---|---|
| `inventory_audit_log` | `audit_id` (TBD — verify) | ✅ enabled | Already append-only by convention; trigger doubles the safety net |
| `refill_dispatching` | `id` (TBD — verify) | ✅ enabled | High-volume, watch trigger overhead |
| `refill_dispatch_plan` | `id` (TBD — verify) | ❌ disabled | RLS must be enabled in same migration (see Article 2) |
| `sales_history_aggregated` | n/a | ❌ matview | **No trigger** — covered by refresh-function audit instead |

`sales_history_aggregated` is a special case: it's a materialized view, so it can't carry an AFTER trigger and doesn't need RLS. Its protection is upstream — only `refresh_sales_aggregated()` may write to it, and Article 9 already requires that path to be DEFINER + auditable. A.5 part 1 (patching the matview-refresh path out of `upsert_daily_sales`) will close that loop.

## Process

Article 15 requires:
1. PR opened with the amendment proposal — **this doc is the proposal**.
2. Reviewed by Cody against existing articles — **pending**.
3. Ratified via Constitution edit + entry in CHANGELOG.md.
4. Migration A.4.b applied as the operational expression of the amendment.

## Rollback

If the amendment is rejected, A.4.b does not run, the 10-table A.4 stays in force, and Appendix A is updated only to remove the non-existent `slots` and `settlements` (the minimum truthful change to avoid carrying ghost names).
