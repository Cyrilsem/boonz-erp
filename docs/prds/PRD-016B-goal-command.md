# /goal command — Track 7 guardrails build

Paste this into Claude Code (fresh session, repo root) to execute PRD-016B.

---

```
/goal Finish the Track 7 return/transfer guardrails per docs/prds/PRD-016B-track7-guardrails-build.md (design + RCA in docs/prds/PRD-016-return-transfer-guardrails.md). Supabase project eizcexopcuoycuosittm. Three tasks, each its OWN forward migration, each preceded by a mandatory `cody` skill review whose verdict you record:

TASK 1 — make guardrail 3 functional (migration phaseF_prd016_unverified_return_provenance). CREATE OR REPLACE return_dispatch_line AND receive_dispatch_line. In the create-new-batch ELSE branch ONLY (the IF NOT FOUND path that INSERTs a new warehouse_inventory row with batch_id like 'REMOVE-RETURN-%'), insert `PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);` immediately before that INSERT. Keep the existing trusted value ('dispatch_return' / 'dispatch_receive') on the merge-into-existing-batch path. Pull each full body verbatim via SELECT pg_get_functiondef('public.return_dispatch_line(...)'::regprocedure) and change ONLY those lines — do not hand-rewrite.

TASK 2 — guardrail 1 (migration phaseF_prd016_guardrail1_m2m_as_remove). New BEFORE INSERT trigger on refill_dispatching that detects action='Remove' AND comment ILIKE '%[TRUCK-TRANSFER]%' AND is_m2m=false AND m2m_partner_id IS NULL, and writes a monitoring_alerts row steering to swap_between_machines (warn, not block — unless Cody rules block).

TASK 3 — guardrail 2 (migration phaseF_prd016_guardrail2_return_variant_correction). Wire the existing record_variant_correction RPC into the return path so a multi-variant pod_product (>1 active boonz mapping) requires an explicit boonz-variant choice before WH credit; record via variant_action_log. Hand the split-by-variant FE fix to the `stax` skill.

HARD CONSTRAINTS: Cody before every canonical-writer change and the new trigger; reproduce full function bodies verbatim; use the service-role bypass pattern (IF auth.uid() IS NOT NULL AND (NOT role-ok)); pod_inventory_audit_log CHECKs require lowercase operation (insert/update/delete) and source in (seed,sale,refill,manual_edit,weimi_sync,correction,cleanup); respect existing refill_dispatching triggers (block_orphan_internal_transfer, enforce_canonical_dispatch_write, tg_audit_refill_dispatching) and add any new writer to the enforce_canonical_dispatch_write allow-list. DO NOT redo the already-applied guardrail-3 DDL (phaseF_prd016_quarantine_unverified_return). Verify each task per PRD-016B DONE CRITERIA, smoke the packing/pickup read paths after editing the dispatch writers, and update RPC_REGISTRY.md + CHANGELOG.md + the PRD status sections.
```

---

**Pre-flight for the operator:** the guardrail-3 DDL is already live and inert (nothing sets the new
provenance until Task 1 ships). Tasks touch the core dispatch write path, so run when you can smoke
field/packing + field/pickup afterward.
