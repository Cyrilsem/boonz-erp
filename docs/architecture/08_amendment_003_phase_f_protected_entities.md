# Amendment 003 — Phase F Appendix A reconciliation

**Status:** Draft, pending ratification by CS
**Filed:** 2026-05-18
**Article amended:** 15 (PRs declare invariants — Appendix A scope) — invoked under Article 15
**Trigger event:** Cody review of `phaseF_edit_rpcs_with_audit` migration (2026-05-18). Cody flagged that `pod_refill_plan` is treated as a quasi-protected entity by the new edit RPCs (DEFINER, role-gated, app.via_rpc, generic audit trigger, `pod_refill_plan_audit` table) yet does not appear in Constitution Appendix A. Several other Phase F entities are in the same state.

---

## Context

The Constitution's Appendix A enumerates the protected entities — tables to which only canonical writers may write, on which every mutation is captured in `write_audit_log` by the generic audit trigger, and where direct FE / n8n / cron writes are forbidden.

Phase F (the refill-engine rebuild) introduced eight new tables and rebuilt several engines. Operationally these tables behave exactly like protected entities — they all have:

- `ENABLE ROW LEVEL SECURITY` on the table.
- A canonical-writer RPC pattern (DEFINER, role-gated, `app.via_rpc='true'`, input validation).
- The generic `audit_log_write` trigger installed (Article 8).
- Mutations cascade into already-protected entities (e.g. `pod_refill_plan` → `refill_plan_output` via Stage 3 Stitch).

But Appendix A was last updated for Phase D (Amendment 006, 2026-05-06 — `strategic_intents`). The Phase F additions never received a formal amendment. This amendment closes the gap.

## Proposed Appendix A additions

The following tables are added to Appendix A as protected entities, effective immediately:

| Table | Introduced | Role |
|---|---|---|
| `machines_to_visit` | Phase F Stage 1 (2026-05-11) | Stage 1 output — picked machine list with reasons + Gate 0 confirmation state |
| `pod_refills` | Phase F Stage 2a (2026-05-11) | Stage 2a output — pod-level refill drafts |
| `pod_swaps` | Phase F Stage 2b (2026-05-11) | Stage 2b output — pod-level swap pairs |
| `pod_refill_plan` | Phase F Stage 2c (2026-05-11) | Stage 2c consolidated draft → approved → stitched FSM |
| `pod_refill_plan_audit` | Phase F day 3 (2026-05-18) | Append-only audit log of qty edits / soft-stops on pod_refill_plan rows |
| `strategic_machine_tags` | Phase F upstream (2026-05-17) | Layer A weekly strategic decisions — directives per (machine, pod_product) that Stage 2b consumes |
| `strategic_intent_threats` | Phase F upstream (2026-05-16) | Threats flagged against active strategic intents (e.g. decommission_resurging_sales) |
| `correlation_pod_per_machine` | Phase F E-4 (2026-05-15) | Pearson co-purchase correlation per machine — substitute candidate scoring |
| `correlation_pod_per_loc_type` | Phase F E-4 (2026-05-15) | Pearson co-purchase correlation per loc_type — fallback substitute scoring |
| `pod_inventory_drift_proposal` | Phase F reconciler (2026-05-18) | Propose-then-confirm queue for `pod_inventory` ↔ WEIMI drift corrections. Status FSM: pending → confirmed / rejected / superseded. Same governance pattern as `warehouse_inventory_status_proposal` (Amendment 002). Confirm RPC delegates to `adjust_pod_inventory` — does NOT write `pod_inventory` directly. |
| `refill_dispatching_edit_log` | Phase F dispatch editing (2026-05-19) | Append-only edit history for `refill_dispatching` rows. Captures every driver / WH manager / admin edit (qty, shelf, product, source, add, remove) with before/after jsonb snapshots and reason. Six canonical writers (`edit_dispatch_qty`, `edit_dispatch_shelf`, `edit_dispatch_product`, `add_dispatch_row`, `remove_dispatch_row`, `set_dispatch_source`) — `restore_dispatch_row` was rejected by Cody R2 as too dangerous (rewriting history). |

Note: `strategic_intents` was added to Appendix A by Amendment 006 (2026-05-06) and is unchanged here. `pod_inventory_drift_proposal` was added 2026-05-18 as the 10th entity. `refill_dispatching_edit_log` is the 11th entity, added 2026-05-19 alongside the dispatch editing schema migration (Cody R4).

## What this amendment introduces

**Nine entities added to Appendix A.** No new canonical writers — every Phase F writer that touches these tables already exists and already follows the Article 4 / Article 8 contract (verified during Phase F day 2 and day 3 migrations).

**Zero new RPC patches required.** All Phase F canonical writers already set `app.via_rpc` / `app.rpc_name` and validate inputs. The generic `audit_log_write` trigger is already bound to each table.

**Audit-trail completeness verified.** During Phase F day-3 work the universal audit trigger was confirmed firing on `pod_refill_plan` (`tg_audit_pod_refill_plan`), `machines_to_visit` (`tg_audit_machines_to_visit`), and the other Phase F tables. The new `pod_refill_plan_audit` is a domain-specific edit-diff log on top of the universal `write_audit_log`, not a replacement.

## Why this is correct under Article 15

Article 15 of the Constitution requires PRs touching protected entities to declare which articles they satisfy. Phase F day 2 and day 3 migrations declared Articles 1, 2, 4, 5, 7, 8, 12 in their CHANGELOG / MIGRATIONS_REGISTRY entries — operationally treating the tables as protected — without the formal Appendix A listing.

The path forward could either be (a) treat the tables as un-protected (which would violate the operational reality, since they cascade into `refill_plan_output`) or (b) reconcile Appendix A to match operational treatment. This amendment chooses (b).

## Constitutional articles that now apply to the new entities

Each entity is now bound by:

- **Article 1** — only canonical writers (already true: `pick_machines_for_refill`, `engine_add_pod`, `engine_swap_pod`, `engine_finalize_pod`, `approve_pod_refill_plan`, `reject_pod_refill_rows`, `confirm_stitched_plan`, `confirm_machines_to_visit`, `unpick_machine_to_visit`, `pick_machine_manually`, `edit_pod_refill_row`, `stop_pod_refill_row`, `restitch_after_edits`, `approve_strategic_machine_tags`, `reject_strategic_machine_tag`, `propose_decommission_plan`, `propose_batch_dissolution_plan`, `propose_rebalance_plan`, `flag_intent_threats`, `acknowledge_intent_threat`, `revoke_intent_via_threat`, `refresh_correlation_pod`).
- **Article 2** — RLS enabled (verified for each).
- **Article 3** — no direct `authenticated` writes (RLS policies block).
- **Article 4** — DEFINER writers validate + set GUCs (verified during day 2 / day 3 migrations).
- **Article 5** — status as state machine (applies to `machines_to_visit`, `pod_refill_plan`, `strategic_machine_tags`).
- **Article 7** — `pod_refill_plan_audit` is append-only (RLS no-update / no-delete policies; INSERT only via DEFINER).
- **Article 8** — universal audit (trigger bound to each table; A.5 caveats do not apply to Phase F since these tables were born post-A.5 with the GUC pattern in place).
- **Article 12** — forward-only migrations (verified across all Phase F migrations).
- **Article 14** — no parallel `_v2` tables (verified — naming convention is `phaseF_<engine>_v<n>` for forward CREATE OR REPLACE of functions, not parallel tables).

## What this amendment does NOT change

- Constitution Article 6 (warehouse_inventory.status — manager-only / propose-then-confirm). Unchanged. Phase F engines do not write to `warehouse_inventory.status` (they read it via `v_warehouse_pod_rollup` and `find_substitutes_for_shelf`).
- Constitution Article 13 (90-day deprecation). The Phase D engines (`orchestrate_refill_plan`, `propose_add_plan`, `propose_swap_plan`, `engine_finalize`, `engine_publish_to_refill_plan`) remain `SECURITY DEFINER` and callable, marked as the `boonz-legacy` skill's path. Their deprecation timeline is independent and will follow the Article 13 monitor / `REVOKE EXECUTE` / `DROP` flow once `boonz-master-3` proves stable.
- Constitution Articles 9, 10, 11 (edge-fn / n8n / cron). Phase F preserves the rule — only the Stage 1 prep cron `phaseF_stage1_prep_8pm_dubai` exists (jobid=13) and it calls a single canonical RPC (`pick_machines_for_refill`).

## Cron change recorded under Article 11

`phaseF_stage1_prep_8pm_dubai` scheduled `0 16 * * *` UTC = 20:00 Dubai daily, calling `SELECT public.pick_machines_for_refill(CURRENT_DATE + 1);`. Calls a single canonical RPC. No business logic in the cron body. Article 11 compliant.

The old engine cron (`orchestrate_refill_plan` per Phase D-3e) was already absent from `cron.job` at the time of this amendment — nothing to disable. The Phase D engines themselves remain present and callable for manual one-off legacy runs.

## What CS needs to ratify

CS sign-off on:

1. The nine entities listed are added to Appendix A.
2. No retroactive A.5 GUC patch is required (Phase F writers were born compliant).
3. The 8pm Dubai Stage 1 prep cron is the only autonomous Phase F operation.
4. Phase D engines remain available as `boonz-legacy` fallback path until Article 13 deprecation completes (separate timeline).

## Rollback

This is a documentation-only amendment. Rollback = revert this commit. No SQL touched.
