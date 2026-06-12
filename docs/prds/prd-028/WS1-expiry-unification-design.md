# PRD-028 WS1 - Expiry unification design note (Dara)

**Date:** 2026-06-12 · **Status:** Proposed, pending Cody review · **Driver:** METRICS_REGISTRY.md row "Machine expiry counts"

## Problem (live, measured 2026-06-12)

Two live sources of "machine expiry counts" disagree on 5 machines today:

| Machine             | signals.expired_skus_now (tier) | summary.expired_units (badge) | Cause                                                                   |
| ------------------- | ------------------------------- | ----------------------------- | ----------------------------------------------------------------------- |
| ALJLT-1015-0200-O1  | 1                               | 0                             | Active expired row outside summary's 30d snapshot window                |
| AMZ-1038-3001-O1    | 0                               | 16                            | summary has NO status filter: counts Inactive rows                      |
| MC-2004-0100-O1     | 1                               | 0                             | window                                                                  |
| NISSAN-0804-0000-L0 | 1                               | 0                             | window                                                                  |
| OMDBB-1020-0P00-O1  | 1                               | 0                             | the PRD's named repro; Active batch snapshot 2026-05-13, exp 2026-06-11 |

Root structural divergences:

1. `v_machine_health_signals.expiry_state`: `status='Active' AND current_stock>0`, **no snapshot resolution at all** (counts every Active row ever written).
2. `v_machine_expiry_summary`: latest snapshot **per machine** (not per shelf), **30-day lookback window** (rows age out silently: the badge goes to 0 while stock is still on the machine), **no status filter** (Inactive/Removed rows leak in).
3. `get_machine_expiry_detail`: same rule as old summary but `CURRENT_DATE` (UTC).
4. `get_machine_slots_with_expiry`: per-machine latest snapshot, 30d window, Dubai date.

Data shape that forces the design: 1,230 Active stock rows; 301 have NULL shelf_id (legacy); 128 of 443 shelves carry Active rows across multiple snapshot dates; 536 Active rows are older than 30 days across 30 machines.

## Design

One batch-resolution rule in one row-grain view; everything else aggregates it.

### 1. `v_machine_expiry_batches` (NEW, row grain - the resolution rule)

- Base set: `pod_inventory` WHERE `status='Active' AND current_stock>0`.
- Resolution key: `(machine_id, shelf_id)`; legacy NULL-shelf rows resolve per `(machine_id, boonz_product_id)`.
- Keep only rows at `max(snapshot_date)` per key (registry rule: "latest Active batch per shelf"). Multiple batches written at that same latest date are all kept.
- **No lookback window.** Active status is the operational truth; a window silently zeroes badges (the ALJLT/MC/NISSAN/OMDBB class). Stale Active rows are a reconciliation problem (BUG-007 family, out of scope here) and must stay visible, not hidden.
- Includes rows with NULL expiration_date (consumers filter).

### 2. `v_machine_expiry_summary` (REPLACE - the canonical metric, machine grain)

- Aggregates `v_machine_expiry_batches` WHERE expiration_date IS NOT NULL.
- Keeps existing columns in order (CREATE OR REPLACE constraint): machine_id, earliest_expiry, days_to_earliest, expired_units, expiring_7d_units, expiring_30d_units, total_tracked_units.
- Appends SKU-grain columns so signals can consume: expired_skus_now, expiring_skus_3d, expiring_skus_7d, expiring_skus_30d.
- "Today" = Dubai operational date `(now() AT TIME ZONE 'Asia/Dubai')::date`, not CURRENT_DATE (UTC). Same disease class as the plan-date bug that produced resolve_refill_plan_date. get_machine_slots_with_expiry already uses Dubai. Effect: between 00:00 and 04:00 Gulf time, UTC-based counts lagged a day; now consistent.
- Boundary semantics (unchanged from both old sources, they already agreed): expired = `exp <= today`; Xd bucket = `today < exp <= today + X`.

### 3. `v_machine_health_signals` (REPLACE - only the expiry_state CTE changes)

expiry_state becomes a LEFT JOIN to `v_machine_expiry_summary` (skus columns, COALESCE 0). Column list/order/names unchanged; `v_machine_priority` and `add_machine_to_plan` are unaffected structurally.

### 4. `get_machine_expiry_detail` (REPLACE body)

Same signature and return shape; aggregates `v_machine_expiry_batches` by product; Dubai date.

### 5. `get_machine_slots_with_expiry` (REPLACE body)

`latest_snap` + `product_expiry` CTEs replaced by a read of `v_machine_expiry_batches`; everything else verbatim.

### 6. Deprecations (comment only, NO DROP in WS1)

`v_pod_inventory_expiry_status`, `v_pod_inventory_health`: zero consumers found (no dependent views, no functions, no FE references). COMMENT as deprecated, pointer to canonical. Drop proposed separately with CS approval per no-destructive-changes rule.

## Consumers verified

| Object                        | Consumers                                                                  |
| ----------------------------- | -------------------------------------------------------------------------- |
| v_machine_expiry_summary      | get_machine_health (only)                                                  |
| v_machine_health_signals      | v_machine_priority (view), add_machine_to_plan (RPC)                       |
| get_machine_slots_with_expiry | FE src/app/(app)/refill/page.tsx:434                                       |
| get_machine_expiry_detail     | no FE/DB refs found (external/skill callers possible; signature preserved) |

## Before/after (simulated against live data, 2026-06-12)

Full-fleet simulation of the new definition vs both old sources; only these change:

| Machine             | badge units old -> new | tier skus old -> new                                                                    |
| ------------------- | ---------------------- | --------------------------------------------------------------------------------------- |
| ALJLT-1015-0200-O1  | 0 -> 1                 | 1 -> 1                                                                                  |
| AMZ-1038-3001-O1    | 16 -> 0                | 0 -> 0                                                                                  |
| MC-2004-0100-O1     | 0 -> 1                 | 1 -> 1                                                                                  |
| NISSAN-0804-0000-L0 | 0 -> 2                 | 1 -> 1                                                                                  |
| OMDBB-1020-0P00-O1  | 0 -> 2                 | 1 -> 1                                                                                  |
| WH2-2001-3000-O1    | 0 -> 1                 | n/a (warehouse machine, outside signals base; get_machine_health reports it 'excluded') |

Priority side effects: none. Every machine with tier expired flag keeps it; no machine flips P-tier from this change (signals values identical on all fleet machines today).

get_machine_health side effects: the 4 hidden machines gain critical-tier expired badges (correct); AMZ-1038 loses a phantom 16-unit badge (correct).

## AC interpretation

PRD AC says `v_machine_priority.expired_skus_now == get_machine_health().expired_units`. These are different units (SKU count vs unit count); literal numeric equality is not meaningful (1 expired SKU with 2 units = 1 vs 2). Both now derive from the same canonical rows, so the enforced invariant is: **(expired_skus_now > 0) == (expired_units > 0) for every machine, zero disagreements**, and both numbers come from one object. Verified post-migration.

## Risks

- Multi-batch shelf top-ups: if a refill writes a new batch row at a newer snapshot_date while an older batch is physically still on the shelf and still Active, latest-per-shelf drops the older batch from the count. This is the registry's chosen rule (recount supersedes); the reconcile flow (BUG-007 family) owns flipping consumed batches.
- Stale Active rows older than 30d now surface in badges (30 machines have such rows; only 5 carry expired dates that change counts today). This is intended visibility, not regression.

## Execution record (2026-06-12)

- Cody verdict: ⚠️ approve with revisions (add `SET search_path = public, pg_temp` to `get_machine_expiry_detail`) - applied. Articles checked: 2, 4, 12, 13, 14, 15.
- Applied to prod as `prd028_ws1_expiry_canonical` (registered version `20260612063856`; repo file renamed to match).
- AC verified live post-apply: 30 machines compared via `v_machine_priority` JOIN `get_machine_health()`; **0 zero/non-zero disagreements**. Machines with expiry now: ALJLT-1015 (1 sku/1 unit), OMDBB-1020 (1/2), MC-2004 (1/1), NISSAN-0804 (1/2) - all health_tier 'critical'. AMZ-1038 absent (phantom cleared). Matches the simulation exactly.
- pg_proc verified: both RPCs read `v_machine_expiry_batches`; detail fn SECURITY DEFINER + search_path set; slots fn INVOKER unchanged. `get_machine_slots_with_expiry('OMDBB-1020-0P00-O1')` returns rows normally.
- Incident note: the untracked driver docs `docs/architecture/METRICS_REGISTRY.md` and `docs/prds/PRD-028-metrics-registry-article16.md` disappeared from disk mid-session (external to this work; never in git). Both restored verbatim from the session read buffer; METRICS_REGISTRY expiry row updated to LIVE.
