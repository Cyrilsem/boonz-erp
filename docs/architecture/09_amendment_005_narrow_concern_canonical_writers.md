# Amendment 005 — Narrow-concern canonical writers on high-traffic protected entities

**Status:** Draft, pending ratification by CS
**Filed:** 2026-05-19
**Article amended:** 1 (Write paths) — invoked under Article 15
**Trigger event:** Cody review of `phaseF_dispatch_editing_rpcs` migration (2026-05-19). Adding 6 new edit RPCs to `refill_dispatching` brought its writer count to 15, which conflicts with the literal reading of Article 1 ("exactly one canonical write path").

---

## Context

Article 1 of the Backend Constitution states (verbatim):

> "Each protected entity has exactly one canonical write path (an RPC)."

This rule was authored to prevent the pre-Phase-A reality where FE / n8n / cron / random scripts all wrote directly to protected tables, producing the kind of silent corruption that motivated the Constitution in the first place. The intent: every mutation goes through ONE controlled, audited, role-gated path — not through dozens of uncontrolled ad-hoc writes.

The literal reading ("exactly one") has been operationally violated for three protected entities since before Phase A:

| Entity                | Canonical writers (count)                                                                                                                                                                                                                                                                  |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `refill_dispatching`  | 9 pre-Phase-F (`pack_dispatch_line`, `receive_dispatch_line`, `return_dispatch_line`, `swap_between_machines`, `mark_picked_up`, `acknowledge_m2m_transfer`, `defer_dispatch_lines`, `conserve_split_dispatch_quantity` trigger, `write_refill_plan`); +6 new Phase-F edit RPCs = 15 total |
| `pod_inventory`       | `adjust_pod_inventory`, `auto_decrement_pod_inventory`, `receive_dispatch_line`, `return_dispatch_line`, `swap_between_machines`, others = 6+                                                                                                                                              |
| `warehouse_inventory` | `pack_dispatch_line`, `return_dispatch_line`, `swap_between_machines`, `transfer_warehouse_stock`, `adjust_warehouse_stock`, `confirm_warehouse_status_proposal`, `process_weimi_staging`, others = 8+                                                                                     |

The literal violation has always been present. The _spirit_ of Article 1 — that every mutation goes through a DEFINER + role-gated + audited path — has been preserved across all writers on these entities. The gap between the literal rule and the operational reality has been widening, and Cody has been signing off "approve under precedent" without that precedent being formalized.

Amendment 005 closes the gap by codifying the precedent.

---

## Proposed revised Article 1

> **Article 1 (revised, 2026-05-19) — Canonical write paths.**
>
> Each protected entity has a defined set of **canonical writers** (RPCs). All mutations to a protected entity MUST go through a canonical writer. The set may contain one or many writers, but every member MUST:
>
> 1. Be a `SECURITY DEFINER` function in the `public` schema (Article 4 compliance).
> 2. Validate caller role against `user_profiles.role` (no parameter-based authorization).
> 3. Set `app.via_rpc = 'true'` and `app.rpc_name = '<function_name>'` GUCs (Article 8 compliance).
> 4. Validate inputs (NULL guards, FK existence, range/enum checks).
> 5. Have a **narrow concern** — one field-or-state-machine-transition per writer where practical.
> 6. Be listed in `RPC_REGISTRY.md` under the entity's canonical-writers section.
>
> Direct `INSERT/UPDATE/DELETE` on a protected entity from the FE, n8n, cron, edge function, or any non-canonical path **remains forbidden** (Articles 3, 9, 10, 11 unchanged).
>
> An entity is considered "high-traffic" (and may have many writers) when its lifecycle is composed of multiple distinct state transitions that each warrant their own narrow concern — `refill_dispatching`, `pod_inventory`, `warehouse_inventory`, and `refill_plan_output` fall into this category. An entity is "single-purpose" (and should have exactly one writer) when its state is updated in only one logical way — `strategic_intents`, `machines_to_visit`, `pod_refill_plan_audit` fall into this category.

## What this amendment introduces

**No schema changes.** This is a doc-only constitutional amendment.

**No new tables.** No new RPCs. The codified pattern matches the precedent already in production.

**Two updates to derivative docs:**

1. `RPC_REGISTRY.md` gains an "Entity → canonical-writer-set" cross-index, replacing the old implicit single-writer assumption.
2. `Cody`'s skill (`SKILL.md`) gets a new verdict pattern: when reviewing a new writer on a high-traffic entity, Cody confirms the narrow-concern criterion (one field or one FSM transition) rather than blocking on the literal single-writer reading.

## Why this is correct under Article 15

Article 15 of the Constitution requires PRs touching protected entities to declare which articles they satisfy. Amendment 005 doesn't weaken Article 1's actual safety property — every mutation still goes through DEFINER+audit+role-gate. It clarifies that "one canonical write path" was always shorthand for "no uncontrolled paths," not "exactly one function."

The alternative — refusing every new narrow-concern writer to high-traffic entities — would have blocked Phase F day 3 (edit RPCs, Gate 0 RPCs), would block the Phase F dispatch editing migration (the trigger for this amendment), and would force consolidation of dozens of narrow-concern writers into mega-functions that violate single-responsibility. Cody has noted this each time.

## Constitutional articles unaffected

Article 1 changes its surface but not its substance.

Articles 2 (RLS), 3 (no authenticated direct writes), 4 (DEFINER validates), 5 (state machine), 6 (warehouse_inventory.status manager-only), 7 (audit logs append-only), 8 (universal audit), 9-11 (edge fn / n8n / cron via RPC), 12 (forward-only migrations), 13 (deprecation), 14 (no _v2 parallel tables), 15 (PRs declare invariants) — all unchanged.

## What CS needs to ratify

CS sign-off on:

1. The revised Article 1 text above.
2. The classification of `refill_dispatching`, `pod_inventory`, `warehouse_inventory`, `refill_plan_output` as "high-traffic" entities (multiple canonical writers allowed under narrow-concern criterion).
3. The classification of `strategic_intents`, `machines_to_visit`, `pod_refill_plan_audit`, `pod_inventory_drift_proposal`, `refill_dispatching_edit_log`, `strategic_machine_tags`, `strategic_intent_threats`, `correlation_pod_per_machine`, `correlation_pod_per_loc_type`, `pod_refills`, `pod_swaps`, `pod_refill_plan` as "single-purpose" entities (one canonical writer).
4. The updates to `RPC_REGISTRY.md` cross-index and `Cody` SKILL.md verdict pattern.

## Rollback

Documentation-only amendment. Rollback = revert this commit. No SQL touched.
