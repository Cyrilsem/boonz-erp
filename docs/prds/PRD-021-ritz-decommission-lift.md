# PRD-021 — Lift Ritz Cracker decommission (close intent ba1ef467)

**Owner:** Claude Code · **Created:** 2026-06-10 · Supabase `eizcexopcuoycuosittm`
**Format:** small canonical-writer-bypass + one RPC call. Cody required (touches `abandon_intent`).

## Context

CS (2026-06-10) lifted the Ritz Cracker permanent-decommission rule — Ritz is selling well at Amazon and resumes as an active SKU. Loacker Quadratini decommission **stands**. The Union Coop walk-in receipt (PO-2026-MQ7MQIHO) had its Ritz + Hummus WH batches zeroed by an `apply_inventory_correction` today and were already restored to Active (Ritz 12 @2027-02-01 wh_inventory `84093e97-0d8a-4449-b21a-32a13df697f1`; Hummus 11 @2027-01-25). The only remaining piece: the strategic `decommission` intent on Ritz is still **queued** and the swap engine will keep trying to phase Ritz out until it is closed.

## Target

- **strategic_intent** `ba1ef467-0252-4541-90b5-0e9342754569` (intent_type `decommission`, scope_boonz_product_id `2e20605a-e4fe-4407-a4ce-60b194e69d34` = Ritz Cracker - Regular, status `queued`) → close via the canonical writer `abandon_intent(p_intent_id, p_reason)`.

## Problem

`abandon_intent` raises `requires authenticated operator role` when called by the service-role connection (auth.uid() IS NULL). Same class as the bypasses already added this session to `update_dispatch_comment`, `adjust_pod_inventory`, `set_dispatch_include`.

## Fix (Cody-gated, verbatim body otherwise)

Add the standard service-role bypass to `abandon_intent`'s role guard:

```
IF auth.uid() IS NOT NULL AND NOT <existing operator-role check> THEN
  RAISE EXCEPTION 'abandon_intent: requires authenticated operator role';
END IF;
```

i.e. only enforce the operator-role check when there IS an authenticated user; service-role (auth.uid() IS NULL) passes. Do NOT change any other logic. Migration name `prd021_abandon_intent_service_role_bypass`; add local migration file; route through Cody before apply.

## Execute

1. Apply the bypass migration (after Cody ✓).
2. `SELECT abandon_intent('ba1ef467-0252-4541-90b5-0e9342754569', 'CS 2026-06-10: lifting Ritz Cracker decommission — selling well at Amazon, resuming as active SKU. Supersedes the 2026-05-10 permanent-decommission rule for Ritz only; Loacker Quadratini decommission stands.');`
3. Verify: `strategic_intents.status` for `ba1ef467` is now `abandoned`/closed with `closed_at` set; confirm no other active `decommission` intent on `2e20605a`.

## Guardrails

Cody before the canonical-writer change; verbatim body apart from the one-line bypass; no other intent rows touched; Loacker Quadratini intents (d3e5b9d1, ef8e3cc5) untouched. Verify in a rolled-back tx first. Update RPC_REGISTRY.md + CHANGELOG.md + MIGRATIONS_REGISTRY.md + this PRD status. Memory `project_decommission_ritz_loacker` already updated.

## DONE — executed 2026-06-10 (Supabase `eizcexopcuoycuosittm`)

- [x] `abandon_intent` bypass shipped (Cody ✅ Articles 1,4,5,8,12; migration `prd021_abandon_intent_service_role_bypass` applied to prod + local file `supabase/migrations/20260610130000_prd021_abandon_intent_service_role_bypass.sql`). Body verbatim apart from the one-line guard (`IS NULL OR` to `IS NOT NULL AND`); verified in a rolled-back tx before commit.
- [x] Intent `ba1ef467` is now **abandoned** (`closed_at` 2026-06-10 11:41Z, `closure_reason` = CS lift note; `closed_by` NULL under service-role). Zero active (`queued`/`in_progress`/`blocked`) decommission intents remain on Ritz `2e20605a`. Loacker Quadratini decommission `9e117317` left `queued` (untouched).
- [x] Registries + PRD status updated (RPC_REGISTRY.md, CHANGELOG.md, MIGRATIONS_REGISTRY.md, this file).
