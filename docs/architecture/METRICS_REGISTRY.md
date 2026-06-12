# Metrics Registry — single source of truth for every business parameter

**Status:** Draft for ratification as Constitution Article 16 · **Owner:** CS · **Created:** 2026-06-11

> NOTE 2026-06-12: this file (untracked) disappeared from disk during the PRD-028 WS1 session and was
> restored from the session's read buffer, with the WS1 row updated to LIVE. Content otherwise verbatim.

## The rule (Article 16 draft)

> For every business metric (a number an operator, partner, or engine acts on), there is exactly ONE
> canonical definition object in the database — a view or read-only function. Every consumer (FE page,
> RPC, engine, cron, advisory, skill, export) reads that object. No view, function, or component may
> re-derive a registered metric inline. Changing a metric definition = changing the canonical object,
> nothing else. Cody blocks any PR or migration that computes a registered metric outside its canonical
> object.

Why: in June 2026 alone, three production incidents traced to the same disease — multiple surfaces
computing their own version of one number (machine priority: 3 definitions; payment default: 3
formulas, none correct; expiry: card badge and tier logic disagreed on the same screen). Each unification
killed a bug class permanently.

## Registry

| Metric                                                    | Canonical object                                                                                                                                      | Status                                                           | Known illegal copies to retire                                                                                                                                                                                                        |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Machine priority tier + score (P1/P2/P3)                  | `v_machine_priority`                                                                                                                                  | ✅ LIVE (stock-led v2, 2026-06-11)                               | ~~picker inline~~ retired (v9.2 reads view) · ~~get_machine_health inline~~ retired (2026-06-11) · FE `refillUrgency()` in `refill/page.tsx` line ~625 — still used for in-tier sort only; retire or rename to make non-authoritative |
| Payment default / captured / gap (reconciliation)         | `get_payment_default_summary(from,to,venue_group,machine_ids)`                                                                                        | ✅ LIVE — FE banners NOT wired yet                               | /app/performance ribbon + dark bar client calc · /refill/consumers banner · /consumers_vox banner                                                                                                                                     |
| Plan date (today vs tomorrow)                             | `resolve_refill_plan_date()`                                                                                                                          | ✅ LIVE                                                          | any `CURRENT_DATE`/`CURRENT_DATE+1` used as a plan date (UTC bug). Audit FE + remaining RPCs                                                                                                                                          |
| Live shelf stock                                          | `v_live_shelf_stock`                                                                                                                                  | ✅ LIVE (house rule since 2026-05-19)                            | any pod_inventory-based stock count                                                                                                                                                                                                   |
| Machine expiry counts (expired now / 7d / 30d / earliest) | `v_machine_expiry_summary` (aggregates `v_machine_expiry_batches`, the batch-resolution rule view)                                                    | ✅ LIVE (PRD-028 WS1, 2026-06-12, `prd028_ws1_expiry_canonical`) | ~~signals expired*skus*\*~~ rewired (consume summary) · ~~detail/slots RPC drift~~ realigned on batches view · `v_pod_inventory_expiry_status` / `v_pod_inventory_health` COMMENT-deprecated, drop pending CS approval                |
| Machine velocity (7d/30d, daily)                          | **TO DESIGNATE** (propose `v_machine_health_signals` or a thin `v_machine_velocity`)                                                                  | ⛔ P1 — ≥3 implementations                                       | `get_machine_health` inline `daily_velocity` · slot_lifecycle stored velocities (slot-level: keep, but machine rollup must come from canonical) · FE Stock Snapshot lookback calc                                                     |
| WH pickable stock                                         | **TO CREATE: `v_wh_pickable`** = warehouse_stock WHERE status='Active' AND NOT quarantined AND (expiry ≥ today OR NULL)                               | ⛔ P1                                                            | packing screen "WH:" badge (shows raw total incl. Inactive — Simran bug) · ad-hoc queries                                                                                                                                             |
| Dispatch committed / available                            | **TO DESIGNATE: `v_dispatch_availability`** (verify def; available = pickable − open commitments, commitments = unpacked+unpicked current lines only) | ⛔ P1                                                            | packing FE client calc (the Available=0 bug class; stale-line release shipped 2026-06-11, definition unification pending)                                                                                                             |
| Dead slot %                                               | `v_machine_priority.dead_slot_pct` (inherits signals)                                                                                                 | ⚠️ verify                                                        | `get_machine_health.dead_stock_count` uses a different formula (blended-score HAVING) than signals' dead_slot_pct — reconcile                                                                                                         |
| Refill quantity decision                                  | `compute_refill_decision` + engine v16 fill-to-cap                                                                                                    | ✅ LIVE                                                          | none known                                                                                                                                                                                                                            |
| Machine scope "active fleet"                              | **TO CREATE: `v_active_fleet`** (include_in_refill, status, venue filters)                                                                            | ⛔ P2                                                            | every RPC has its own WHERE (the 3-refs/84-AED scope drift in reconciliation)                                                                                                                                                         |

## Enforcement

1. **Cody checklist addition (class b/c reviews):** "Does this object compute a registered metric inline?
   If yes → block, point to canonical object." Add to cody SKILL.md review playbook.
2. **CI lint (Phase B):** grep migrations + src for signature patterns (`expiration_date <`, `daily_velocity`,
   `captured_amount_value` aggregations, `CURRENT_DATE + 1`) outside canonical objects → fail with pointer here.
3. **This file is the registry.** Adding a metric = adding a row here + the canonical object in the same PR.

## Execution order (each step: Dara design → Cody review → migrate → verify consumers)

1. ~~**P0 expiry**~~ ✅ DONE 2026-06-12 (`prd028_ws1_expiry_canonical`): `v_machine_expiry_summary` canonical
   over new `v_machine_expiry_batches`; signals rewired; detail/slots RPCs realigned; AC green (30 machines,
   0 disagreements; OMDBB-1020 fixed).
2. **P1 velocity** — single machine-level velocity rollup; `get_machine_health` consumes it.
3. **P1 WH pickable + dispatch availability** — create `v_wh_pickable`, verify/designate
   `v_dispatch_availability`, wire packing FE (closes Simran's screen permanently).
4. **P1 FE banner wiring** — get_payment_default_summary into the 3 reconciliation banners (prompt already drafted).
5. **P2 active-fleet scope view** — kill per-RPC WHERE drift.
6. **Ratify Article 16** into 01_constitution.html, update Cody SKILL.md.
