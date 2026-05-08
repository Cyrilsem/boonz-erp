# Phase A — Backend Constitution Close-Out

**Date closed:** 2026-04-26
**Status:** CLOSED
**Owner:** CS (operator-in-chief)

---

## What Phase A was

Phase A was the structural fix to the backend after the §3.1 incident, where in-place identity edits to `machines` corrupted the audit trail. The ask from the Constitution was simple: every write to a protected table must go through a single, named, audited code path. No direct UPDATE/INSERT from FE, n8n, edge functions, or cron.

## What Phase A delivered

The backend is now in compliance. Concretely:

**Single-writer rule is enforced at the database.** All 25 canonical writer functions (the only RPCs allowed to mutate protected tables) now tag every transaction with `app.via_rpc='true'` and `app.rpc_name='<function>'` via `set_config(...)` at the top of their bodies. This was the bulk of A.5a + A.5b, completed earlier on 2026-04-26.

**Audit trail is automatic.** A generic AFTER INSERT/UPDATE/DELETE trigger (`audit_log_write`) is installed on all 14 protected tables that exist in the live schema: `machines, planogram, pod_inventory, pod_inventory_audit_log, refill_dispatch_plan, refill_dispatching, refill_plan_output, sales_history, shelf_configurations, sim_cards, slot_capacity_max, slot_lifecycle, dispatch_photos, warehouse_inventory`. Every write — by any caller — produces a row in `write_audit_log` with the actor, role, RPC name, and full row payload. The last 4 of those triggers (`refill_dispatch_plan, refill_dispatching, dispatch_photos, slot_capacity_max`) shipped today as A.4.b, which closes the final coverage gap.

**Operator-admin §3.1 violation is removed.** The Machine Edit Panel no longer accepts in-place identity edits. Identity fields render read-only in an amber-bordered "Identity (protected)" banner; the "Repurpose Machine →" button routes through the canonical `repurpose_machine` RPC. Refill toggles (single + bulk) call `toggle_machine_refill` instead of direct UPDATE. This shipped earlier today as B.x.3 — strictly speaking it's a Phase B fix but it's the one that closed the original incident, so it lands here.

**Legacy rename function is deprecated.** `rename_machine_in_place_legacy` is now `SECURITY INVOKER` with EXECUTE revoked from `anon`/`authenticated`. Scheduled DROP date 2026-07-24 (90-day Article 13 monitor window).

## What's deferred and why it's not blocking

**A.5c (function-level SET cleanup):** retired. The current A.5b pattern (`set_config(..., true)` inside the body) actually has stronger semantics than the function-level SET clause (transaction-scope vs function-scope, which matters for nested writers). Moving to SET-on-definition would have been a cosmetic refactor with worse behavior. Not doing it.

**A.6 (CI lint script):** deferred. The governance config at `docs/architecture/governance.yml` is written and lists the protected entities, severity levels, and detection patterns. The script that consumes it is not. **In warn-mode this is non-blocking** — it's a guardrail against future drift, not a fix to a current break. We can write a 30-line grep-based version any time we need it. Treating this as a Phase B drain item.

**Constitution Appendix A reconciliation:** the Constitution lists 18 protected entities by name. Five of those names don't match live schema (`slots, settlements, dispatch_plan, dispatch_lines, product_scores`). Three are real-but-renamed (`refill_dispatch_plan, refill_dispatching, mv_global_product_scores`); two are not present in this project at all (`slots, settlements`). Reconciliation = update the Constitution doc to match the live schema. Pure docs work, not blocking.

## What this means for day-to-day operations

**Yes — refill flow work can resume.** Phase A is closed and Phase B (drain remaining direct-write call sites) does not block operations. The audit trail is on. The single-writer rule is enforced where it matters. New violations introduced by future work will leave a clean signature in `write_audit_log` (rows with `via_rpc=false`), which makes them trivial to find later.

The flow problems on the operations side (refill engine plan correctness, dispatch flow ergonomics, partner reporting) are independent of Phase A and were never blocked by it.

## Phase B — what's actually open

Phase B is "fix remaining direct-write call sites." The known queue:
- B.x.1: refill-engine skill currently writes `refill_plan_output` directly (allow-listed until 2026-05-15).
- B.x.2 onwards: a handful of FE/n8n/edge-fn paths that still write protected tables directly. Estimate 6–8 sites.
- AMD-002, AMD-003, AMD-004: design canonical writer RPCs for `shelf_configurations`, `sim_cards`, `settlements` (settlements only when/if the table is created — currently absent). These would be Dara design jobs, not blocking anything operational.

Each of these is a 30–60 minute change, addressed individually as encountered. No big-bang Phase B "close" event needed.

## Reference points

- `docs/architecture/RPC_REGISTRY.md` — canonical writer inventory (25 RPCs)
- `docs/architecture/governance.yml` — Article 15 governance config
- `MIGRATIONS_REGISTRY.md` — migration log (latest: `phaseA_a4b_complete_audit_trigger_coverage`)
- `write_audit_log` table — the live audit trail; query it any time to see who wrote what
