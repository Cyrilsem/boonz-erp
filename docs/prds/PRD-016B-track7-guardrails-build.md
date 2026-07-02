# PRD-016B — Build spec: Track 7 guardrails (Migration 2 + Guardrails 1 & 2)

**Owner:** Claude Code (fresh session)
**Companion to:** `PRD-016-return-transfer-guardrails.md` (design + RCA + Cody verdict)
**Created:** 2026-05-31 by the refill-log-fix session
**Goal:** finish the return/transfer guardrails whose design + infrastructure are already shipped.
Make guardrail 3 _functional_, then ship guardrails 1 & 2.

---

## Why (one paragraph)

Three 19-21 May incidents (IFLY M2M Barebells → WH instead of AMZ; OMDCW Hunter Truffle returned
as Hunter Sea Salt; MCC phantom WH rows) share one root cause: the Remove/return path credits and
auto-creates `warehouse_inventory` rows with under-validated variant, destination, and lineage.
RCA + evidence are in PRD-016. The containment substrate (PRD-003 provenance/quarantine) plus the
guardrail-3 DDL are already live. What remains is wiring + two small guardrails.

## What is ALREADY DONE (do not redo)

- **Guardrail-3 DDL** applied as migration `phaseF_prd016_quarantine_unverified_return`:
  - enum value `dispatch_return_unverified` added to `wh_provenance_reason_enum`.
  - generated column `warehouse_inventory.quarantined` now also quarantines that value.
  - index `idx_wh_inv_quarantined` + view `v_wh_inventory_provenance` + **materialized view
    `mv_wh_inventory_provenance`** (with indexes `mv_wh_provenance_pk`, `mv_wh_provenance_quarantined`)
    were dropped and recreated as part of that migration (they depend on the column).
- Verified: 973 wh rows, 870 quarantined (pre-existing NULL/pre-migration), 0 rows carry
  `dispatch_return_unverified` yet (because Migration 2 below is not done).

## HARD CONSTRAINTS / lessons from this session (read before editing)

1. **Cody is mandatory** before every `CREATE OR REPLACE` on a canonical writer
   (`return_dispatch_line`, `receive_dispatch_line`) and before any new trigger on
   `refill_dispatching`. Invoke the `cody` skill, record the verdict.
2. **Reproduce full function bodies verbatim.** Pull with
   `SELECT pg_get_functiondef('public.return_dispatch_line(...)'::regprocedure)`, change ONLY the
   target lines, re-apply. Do NOT hand-rewrite. (This session found 3 latent bugs in
   `adjust_pod_inventory` precisely because small functions hide surprises — expect the same.)
3. **Service-role bypass pattern**: role gates should be `IF auth.uid() IS NOT NULL AND (NOT role-ok)`
   so cron/service_role/MCP can call them. The engine writers + `log_retroactive_refill_visit` +
   the now-patched `adjust_pod_inventory` all follow this.
4. **`pod_inventory_audit_log` CHECKs**: `operation ∈ (insert,update,delete)` lowercase;
   `source ∈ (seed,sale,refill,manual_edit,weimi_sync,correction,cleanup)`. (Latent-bug source.)
5. **`refill_dispatching` triggers already live**: `block_orphan_internal_transfer` (rejects
   source_origin=internal_transfer w/o m2m_transfer_id unless writer is swap_between_machines /
   repair_orphan_internal_transfer), `enforce_canonical_dispatch_write` (allow-list, currently
   RAISE WARNING not EXCEPTION), `tg_audit_refill_dispatching` (Article 8 audit). New writers should
   be added to the enforce_canonical_dispatch_write allow-list.
6. **In-session rewrite rule**: a 2nd `CREATE OR REPLACE` on the same function within 24h needs CS
   green light + Cody diff review.

---

## TASK 1 — Guardrail 3 Migration 2 (makes containment functional)

**Files/functions:** `return_dispatch_line`, `receive_dispatch_line` (canonical writers, ~10KB / ~13KB).

**Change:** Both functions stamp a trusted provenance once near the top
(`PERFORM set_config('app.provenance_reason','dispatch_return'|'dispatch_receive',true)`). In the
**create-new-batch ELSE branch only** — the `IF FOUND ... ELSE INSERT INTO warehouse_inventory
(... batch_id = format('REMOVE-RETURN-%s'|... ) ...)` path that fires when no existing Active
`(boonz_product_id, warehouse_id, expiration_date)` row matches — insert this line immediately
BEFORE that `INSERT INTO warehouse_inventory`:

```sql
PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
```

(For `receive_dispatch_line`, same idea on its create-new-WH-row ELSE branch.) The merge-into-
existing-batch path keeps the trusted value. Net: a return that lands on a real received batch is
trusted; a return that invents a brand-new batch lands `quarantined=true` and on the needs-review
screen (`v_wh_inventory_provenance` / mv). This closes the Bug C class going forward.

**Migration name:** `phaseF_prd016_unverified_return_provenance`
**Cody:** Articles 1, 4, 6 (status untouched), 8, 12. Separate review from the DDL.
**Verify:** simulate a return for a product with no matching WH batch (dry, in a transaction you
roll back) → the new wh row must have `provenance_reason='dispatch_return_unverified'` and
`quarantined=true`. Confirm a return that matches an existing batch still stamps `dispatch_return`.

## TASK 2 — Guardrail 1: block/flag M2M-as-Remove

**Problem (Bug A):** a cross-machine move was entered as a plain `action='Remove'` with
`is_m2m=false`, no partner, a `[TRUCK-TRANSFER]` comment → it drained to WH instead of reaching the
destination machine. The existing `block_orphan_internal_transfer` only covers
`source_origin='internal_transfer'`; a plain Remove with transfer intent is not covered.

**Change:** new `BEFORE INSERT` trigger function on `refill_dispatching`, e.g.
`flag_remove_with_transfer_intent()`, that detects `NEW.action='Remove'` AND
`NEW.comment ILIKE '%[TRUCK-TRANSFER]%'` (or other transfer-intent markers) AND `NEW.is_m2m=false`
AND `NEW.m2m_partner_id IS NULL`. Action: insert a `monitoring_alerts` row (preferred, non-blocking)
OR `RAISE EXCEPTION` steering to `swap_between_machines`. Recommend **alert, not block**, to avoid
breaking legitimate edge cases — match the existing `enforce_canonical_dispatch_write` "warn first"
posture. Cody decides block-vs-warn.

**Migration name:** `phaseF_prd016_guardrail1_m2m_as_remove`
**Cody:** Articles 1, 4, 8.
**Verify:** insert (in a rolled-back tx) a Remove row with a `[TRUCK-TRANSFER]` comment + is_m2m=false
→ expect the alert/exception. A normal Remove (no transfer comment) → unaffected.

## TASK 3 — Guardrail 2: variant correction on returns

**Problem (Bug B):** returning a multi-variant pod (e.g. "Hunter") defaults the single
`boonz_product_id` to one variant (Hunter Sea Salted) and the return flow has no way to reassign the
variant; "split by variant" errored. `record_variant_correction` (PRD-002) and `variant_action_log`
already exist but are not wired into the return path.

**Change:** in the return RPC path (`return_dispatch_line` and/or the FE return flow), when the
pod_product maps to >1 active `boonz_product_id` in `product_mapping`, require an explicit
boonz-variant selection before crediting WH; route the correction through
`record_variant_correction`. This is RPC-body + **FE (Stax)** — the split-by-variant UI that errored
must call the corrected path. Coordinate with Stax for the FE piece.

**Migration name:** `phaseF_prd016_guardrail2_return_variant_correction`
**Cody:** Articles 1, 4, 8. **Stax:** FE return/split-by-variant screen.
**Verify:** a return of a multi-variant pod without an explicit variant → must prompt/select, not
silently default. Confirm `variant_action_log` records the correction.

---

## DONE CRITERIA — ✅ COMPLETE (2026-05-31)

- [x] Migration 2 applied + Cody ✅ + verified (unverified returns quarantine). `phaseF_prd016_unverified_return_provenance`. Dry test: no-match return → `dispatch_return_unverified`/`quarantined=true`; matching-batch return → `dispatch_return`/`quarantined=false`.
- [x] Guardrail 1 trigger live + Cody ✅ + verified. `phaseF_prd016_guardrail1_m2m_as_remove` (WARN posture). Test: `[TRUCK-TRANSFER]` Remove → 1 alert; normal Remove → 0.
- [x] Guardrail 2 wiring + Cody ✅; FE ticket handed to Stax + verified. `phaseF_prd016_guardrail2_return_variant_correction` (NEW trigger, not a 2nd writer rewrite — respects hard-constraint #6; WARN posture). Test: multivariant-no-correction → 1 alert; with `variant_action_log` row → 0; single-variant → 0. FE → Stax STAX-2026-05-31-01 (must call `record_variant_correction` BEFORE `return_dispatch_line`).
- [x] `RPC_REGISTRY.md` + `CHANGELOG.md` + `MIGRATIONS_REGISTRY.md` updated for each changed writer.
- [x] PRD-016 + PRD-016B status sections updated to ✅.
- [x] Confirmed: no `source_origin` writes (no disagreements introduced); packing/pickup dispatch read joins return rows; WH baseline unchanged (973 rows / 870 quarantined / 0 `dispatch_return_unverified` live). All verification ran in rolled-back transactions (0 leaked rows/alerts).

## FOLLOW-UPS (intentional — recorded so the WARN posture is not forgotten)

1. Escalate Guardrail 1 + Guardrail 2 from WARN to BLOCK once the FE routes truck-transfers through `swap_between_machines` and calls `record_variant_correction` from the return/split-by-variant screen.
2. The receive-of-Remove WH credit (`item_added` flip in `receive_dispatch_line`) carries the same multi-variant ambiguity as Guardrail 2 but is out of PRD-016B scope — logged as a known gap for a future guardrail.

## ROLLBACK

Each task is its own forward migration. To revert Migration 2, re-apply return/receive with the
ELSE-branch `set_config` line removed (rows already quarantined stay quarantined — harmless; WH
manager unquarantines via physical recount → `adjust_warehouse_stock` with explicit provenance).
Guardrails 1 & 2 triggers/wiring: drop the trigger / revert the function via a new forward migration.
