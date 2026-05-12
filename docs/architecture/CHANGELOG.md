# Architecture Changelog

A running log of every architecture-level edit. Newest first. Each entry: what changed, why, what was applied where, and how to roll back. The Supabase `migrations` table is the system of record for SQL; this file is the human-readable companion that maps migrations to Constitution articles and explains intent.

Format:

```
## YYYY-MM-DD — short title
**Phase / Article:** A.X / Constitution Article N
**Applied to:** prod | repo | both
**Migration name:** <name in Supabase migrations table, if any>
**Summary:** one paragraph on what / why
**Rollback:** SQL or steps to undo
```

---

## 2026-05-11 — Bugfix: return_dispatch_line + receive_dispatch_line (3 bugs)
**Phase / Article:** B.3 bugfix / Constitution Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `fix_return_receive_dispatch_remove_and_phantom`

**Summary:** Three bugs causing inventory drift, discovered during Ritz/Loacker decommission and NISSAN daily-roll audit.

**BUG 1 (REMOVE returns 0):** `return_dispatch_line` used `COALESCE(filled_quantity, quantity)` — for REMOVE rows `filled_quantity=0` (not NULL), so COALESCE returned 0. Fix: REMOVE branch now uses `ABS(quantity)` directly, credits WH, and archives `pod_inventory`.

**BUG 2 (phantom WH credits):** When `consumer_stock=0` for all matching rows (already released by a prior daily-roll return), the fallback ELSE branch found any WH row and blindly added `+quantity` — creating phantom stock. 218 phantom units across 48 WH rows accumulated over May 4–10 from NISSAN daily-roll cycles. Fix: removed the fallback ELSE branch for Refill/Add/Add New. If no consumer reservation exists, there is nothing to return.

**BUG 3 (receive skips REMOVE):** `receive_dispatch_line` only handled `action IN ('Refill','Add New','Add')`. REMOVE was excluded, so the FE confirmation flow for REMOVE rows had no working RPC. Fix: added `ELSIF action = 'Remove'` branch that credits WH with `p_filled_quantity` and archives `pod_inventory`.

**Rollback:** `CREATE OR REPLACE` both functions with the pre-patch source (retrievable from `write_audit_log` payload or the session transcript at `a0446bad`).

---

## 2026-05-11 — Phase F day 2: pitstop tables, Stage 2a, Stage 2c, Gates 1 & 2
**Phase / Article:** F-Stage 2 + Gates / Constitution Articles 1, 2, 4, 5, 8, 9, 12
**Applied to:** prod
**Migrations:** `phaseF_stage2_pitstop_tables_v2`, `phaseF_stage2a_engine_add_pod_v3_max_stock_from_weimi`, `phaseF_stage2c_engine_finalize_pod`, `phaseF_gate_rpcs_approve_and_confirm` (+ a v1 / v2 of stage2a that failed on PK collision via v_live_shelf_stock fanout; v3 corrected by switching to pod_inventory at shelf grain).

**Summary:** Five new pieces and the full Stage 1 → 2a → 2c → Gate 1 → Gate 2 chain is now end-to-end functional.

**Pitstop tables:** `pod_refills` (Stage 2a output, PK plan_date+machine_id+shelf_id+pod_product_id), `pod_swaps` (Stage 2b output, uuid PK with pair-linked pod_product_id_out/in; pod_in NULL = M2W return), `pod_refill_plan` (Stage 2c consolidated final, status FSM `draft → approved → stitched | superseded` with approved_at/approved_by/stitched_at). All three RLS-read-all + audit trigger + no direct-write policies.

**Helper views:** `v_warehouse_pod_rollup` (SUM warehouse_stock across boonz variants per pod_product → total_stock, active_batches, earliest_active_expiry — Layer A + Layer B read this; Layer C does NOT). `v_shelf_max_stock` (per-slot max_stock derived from `v_live_shelf_stock`, normalizing shelf_code "A01" ↔ slot_name "A1" via regex). Stage 2 needs the weimi-derived max because `shelf_configurations.max_capacity` is mostly NULL.

**Stage 2a `engine_add_pod(plan_date, days_cover=14)`:** Signal-aware sizing. STAR/DOUBLE DOWN fill-to-max; KEEP GROWING/KEEP use velocity_30d × days_cover; RAMPING/WATCH use velocity × 7 capped at half-max; WIND DOWN/ROTATE OUT/DEAD skipped (Stage 2b's territory). All qty capped by (max-current) and WH pod rollup. Smoke test 2026-05-12: 124 REFILL rows in 417ms. Default fallback `v_default_max=10` when neither config nor weimi has a value.

**Stage 2c `engine_finalize_pod(plan_date)`:** Reads pod_refills + pod_swaps, writes pod_refill_plan(status='draft'). R4: swap-touched shelves invalidate refills on the same shelf (anti-join via swap_shelves CTE). Emits four action types: REFILL, REMOVE, ADD_NEW, M2W. R7 60% shelf cap surfaced as diagnostic only at Stage 2c. Idempotent — supersedes prior drafts. Smoke test: 124 draft rows (Stage 2b empty so 0 swaps merged in).

**Gate RPCs:** `approve_pod_refill_plan(plan_date, machine_names[] DEFAULT NULL)` (Gate 1 — draft → approved, optional partial scope), `reject_pod_refill_rows(plan_date, machine_names, reason)` (Gate 1 reject — draft → superseded with reason captured in reasoning jsonb), `confirm_stitched_plan(plan_date)` (Gate 2 — approved → stitched, called by Stage 3 after refill_plan_output is written).

**End-to-end test:** Stage 1 (24 picked) → Stage 2a (124 refills) → Stage 2c (124 drafts) → Gate 1 partial (1 machine) → Gate 1 fleet (remaining 123) → Gate 2 confirm → 124 stitched. Full chain works. **Gaps remaining for tomorrow:** Stage 2b (engine_swap_pod — pod-level swap/substitute logic with intent-driven Pass 1 + autonomous Pass 2 ported from current propose_swap_plan) and Stage 3 Stitch (boonz mapping + WH SKU split adjustment + deviation/procurement alerts).

**Rollback (additive, safe to drop):**
```sql
DROP FUNCTION IF EXISTS public.confirm_stitched_plan(date);
DROP FUNCTION IF EXISTS public.reject_pod_refill_rows(date, text[], text);
DROP FUNCTION IF EXISTS public.approve_pod_refill_plan(date, text[]);
DROP FUNCTION IF EXISTS public.engine_finalize_pod(date);
DROP FUNCTION IF EXISTS public.engine_add_pod(date, integer);
DROP VIEW IF EXISTS public.v_shelf_max_stock;
DROP VIEW IF EXISTS public.v_warehouse_pod_rollup;
DROP TABLE IF EXISTS public.pod_refill_plan;
DROP TABLE IF EXISTS public.pod_swaps;
DROP TABLE IF EXISTS public.pod_refills;
```

---

## 2026-05-11 — Phase F-Stage 1: machine picker (`pick_machines_for_refill` + `machines_to_visit`)
**Phase / Article:** F-Stage 1 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration names:** `phaseF_stage1_machine_picker`, `phaseF_stage1_machine_picker_v3_drop_and_recreate`, `phaseF_stage1_machine_picker_v4_intent_count_fix`

**Summary:** First migration of Phase F — the 3-layer engine rebuild (Layer A strategic upstream pod_product, Layer B refill engine pod_product with Stages 1 + 2a/2b/2c, Layer C boonz stitching, with two CS approval gates between layers — full spec in `BOONZ BRAIN/REFILL_BRAIN_REDESIGN.md`). Stage 1 is the smallest additive piece: a pure-read machine picker that decides *which* machines to visit on a given date and outputs a callable pitstop table. **New table `machines_to_visit`** (PK plan_date+machine_id, status FSM picked/superseded, FK to machines, audit trigger `audit_log_write('machine_id')`, RLS read-all, no direct write policies so only DEFINER reaches it). **New RPC `pick_machines_for_refill(p_plan_date)`** — DEFINER, role-gated on `operator_admin`, sets `app.via_rpc`. Reads `machines` + `slot_lifecycle` + `refill_dispatching` history + `strategic_intents` (active = queued/in_progress) + `v_live_shelf_stock`. Five pick reasons: **health** (≥30% slots in DEAD/WIND DOWN/ROTATE OUT), **stale** (≥7d since last picked_up dispatch), **empty** (≥20% shelves at 0 stock), **intent** (≥1 active strategic_intent touching machine or fleet-wide), **ramping** (relaunched_at or first_sale_at within 30d). Priority score 0..100 = weighted sum (30+20+25+15+10). Sibling expansion via `venue_group` (fallback `building_id`) at lower thresholds — once one machine in a cluster is picked, siblings get pulled in at half thresholds. Idempotent: re-running supersedes prior pick for same date. **Smoke test (plan_date 2026-05-12):** 24 machines picked across 8 route clusters (ADDMIND, GRIT, INDEPENDENT, NOVO, OHMYDESK, VML, VOX, WPP). Reasons distribution: health (15), stale (15), ramping (7), sibling (1 — OMDCW-1021 added as sibling of OMDBB-1020). VML-1003/1004 correctly excluded (no real signals, just a stale 'intent' false-flag that the v4 fix removed). **v4 fix** corrected a `COUNT(*)` vs `COUNT(si.intent_id)` LEFT-JOIN bug that made every machine flag "intent"; same shape bug fixed in `slot_health` and `empty_state` defensively. **Known nit (#17):** sibling-only picks get pri_score=0 because sibling pass doesn't re-score — deferred to Stage 1 v5.

**Rollback:**
```sql
-- v1 rollback (additive; safe to drop without touching production data):
DROP FUNCTION IF EXISTS public.pick_machines_for_refill(date);
DROP TABLE  IF EXISTS public.machines_to_visit;
```

---

## 2026-05-10 — Phase E-1: evaluate-lifecycle v13.1 (STAR signal + relaunched_at + null-location fallback)
**Phase / Article:** E-1 / Constitution Article 9
**Applied to:** prod
**Edge function:** `evaluate-lifecycle` versions 21 → 22 (`v13` → `v13.1`)

**Summary:** Five-line surgical patch to the lifecycle scoring edge function, no business-logic surface added. (1) New `STAR` signal class above `DOUBLE DOWN`: fires when `score ≥ 9 AND fleetVelRatio ≥ 5`, where `fleetVelRatio = slot.v30 / fleet_avg_v30_for_this_pod_product`. Captures saturated leaders that growth-only signals miss because trend reads flat at the ceiling. (2) `machines` SELECT now pulls `relaunched_at`; `isRampingMachine()` reads it before `first_sale_at`. NISSAN-0804 (relaunched 2026-05-10) immediately flips its 16 slots from stale `DEAD` to `RAMPING`. (3) Null-location-type machines no longer silently dropped from scoring — `effectiveLocationType()` returns `'office'` fallback; `UNNORMALIZED_LOCATION` data-quality flag still fires. (4) `v13.1` patch: dark-machine filter whitelists ramping machines so newly-relaunched zero-sales slots actually pass through scoring instead of keeping stale signals. (5) Per-slot `getSignalV2(score, trend, fleetVelRatio)` call wires the new param; product-level signal still uses default `1.0` (STAR doesn't apply to global product aggregates by definition). Verified post-deploy: ALJLT-1015-0200 has 16 scored slots (was 0), NISSAN-0804 has 16/16 RAMPING. STAR threshold of 5× missed Aquafina at VOXMCC-1009 (actual ratio 2.87× — fleet avg of 4.65/d is pulled up by the strong VOX slots themselves; needs CS decision on whether to lower threshold or move to leave-one-out / median-based metric).

**Rollback:** redeploy v12 source (preserved at `evaluate-lifecycle` version 20 via Supabase function version history) — `mcp__supabase__deploy_edge_function` with the v12 file body restores prior behaviour.

---

## 2026-05-10 — Phase E-1: Lifecycle data fixes + relaunched_at infrastructure
**Phase / Article:** E-1 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseE1_lifecycle_data_fixes`

**Summary:** First migration of Phase E (rebuild). Closes three lifecycle-engine audit findings: (1) Adds `machines.relaunched_at` column — overrides `first_sale_at` as the RAMPING grace anchor when a machine is physically relocated to a new venue. (2) Adds canonical writer `set_machine_relaunched_at(p_machine_id, p_relaunched_at, p_reason)` — DEFINER, role-gated, validates non-future timestamp + Active machine status. (3) Inline data fixes: `ALJLT-1015-0200-O1` location_type set to 'coworking' (was NULL, which made `evaluate-lifecycle` line 594 silently exclude the machine — now visible to scoring on next cron tick); `IRIS-1010-0000-O0` flipped to `status='Inactive'`/`include_in_refill=false` (defunct, last sale 42d ago); `NISSAN-0804-0000-L0` has `relaunched_at=now()` set via the new canonical writer (CS relaunching at new venue). Cody-reviewed with one revision: NISSAN write routes through `set_machine_relaunched_at` RPC instead of direct UPDATE (Article 1 — single canonical writer for the new column, plus install-time smoke test of the RPC). E-1 audit also produced a complete signal-logic spec at `BOONZ BRAIN/E1_lifecycle_fix_spec.md` covering STAR signal class, RAMPING for relaunched machines, and null-location-type fallback — those land via the next `evaluate-lifecycle` edge function patch (E-1.x via Stax).

**Companion work pending:** edge function `evaluate-lifecycle` v13 — adds STAR signal class (`score ≥ 9 AND fleet_velocity_ratio ≥ 5`), reads `relaunched_at` as ramp anchor, doesn't silently drop machines with NULL `location_type` (emits data quality flag, scores with 'office' fallback). Stax→Cody→deploy.

**Rollback:**
```sql
-- Revert data fixes (manual, requires CS approval per row):
UPDATE machines SET status='Active', include_in_refill=true WHERE official_name='IRIS-1010-0000-O0';
UPDATE machines SET location_type=NULL WHERE official_name='ALJLT-1015-0200-O1';
UPDATE machines SET relaunched_at=NULL WHERE official_name='NISSAN-0804-0000-L0';
-- Drop function and column:
DROP FUNCTION IF EXISTS public.set_machine_relaunched_at(uuid, timestamptz, text);
ALTER TABLE public.machines DROP COLUMN IF EXISTS relaunched_at;
```

---

## 2026-05-10 — Phase D-3e: R5 cooldowns + R7 shelf cap + 8pm Dubai cron
**Phase / Article:** D-3e / Constitution Articles 1, 4, 5, 8, 11, 12
**Applied to:** prod
**Migration name:** `phaseD3e_r5_r7_and_cron`

**Summary:** Three additions per CS spec. **R5 cooldowns** in `propose_swap_plan`: 14-day no-repeat-removal on (machine, product) — pre-checks `refill_plan_output` for approved 'Remove' on same (machine_name, boonz_product_name) in the last 14 days, skips if found. 30-day no-re-introduction on substitute candidates — Pearson and category-fallback queries both filter out candidates whose product was Removed from this machine in the last 30 days. New return field `skipped_r5_cooldown`. **R7 60% shelf cap** in `engine_finalize`: per machine, count distinct SWAP-touched shelves (M2W's `reasoning.shelf_code_origin` included). Slot count from `slot_lifecycle.archived=false` per machine. Cap = floor(60% × slot_count). Excess SWAP drafts overruled worst-score-first. R3 and R5 remain warnings per CS confirmation. R7 is a fail-safe — today's per-machine cap is still 2, so R7 doesn't trigger; engages only if `p_max_swaps_per_machine` is bumped beyond ~9–19. **pg_cron** at 16:00 UTC daily (= 8pm Dubai) running `orchestrate_refill_plan(CURRENT_DATE+1)`. Job name `orchestrate-refill-plan-8pm-dubai`. Idempotent re-creation (unschedule first if exists). Smoke test for 2026-05-11: 156 ADD + 42 SWAP (19 M2W + 23 pairs) → 215 finalized → 409 published rows across 21 machines in 2.1s.

**Rollback:**
```sql
-- Restore D-3d propose_swap_plan + engine_finalize (without R5/R7).
-- Unschedule cron:
SELECT cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'orchestrate-refill-plan-8pm-dubai'));
```

---

## 2026-05-10 — Phase D-3d: MACHINE_TO_WAREHOUSE return path
**Phase / Article:** D-3d / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseD3d_machine_to_warehouse_return`

**Summary:** Phase C-1 set up the `machine_to_warehouse` proposal type but never wired it. SWAP today reported skipped_no_substitute=112+ per run — products dying on shelf with no plan. D-3d wires SWAP to emit MACHINE_TO_WAREHOUSE drafts when no viable substitute exists (Pearson + category fallback both fail OR substitute lacks WH stock). M2W draft routes to `machine.primary_warehouse_id` with qty = `pod_inventory.current_stock` (physical pull instruction). Pass 1 M2W carries `linked_intent_id` for decommission credit; Pass 2 (autonomous) does not. Phase C-2's `uq_dpd_active_per_slot_action` index already engineered M2W dedup via `COALESCE(shelf_code, '__M2W__')` sentinel. Same migration extends `reconcile_intent_progress` decommission filter to credit `MACHINE_TO_WAREHOUSE` alongside `REMOVE` (both reduce deployed stock); `dissolve_batch` correctly excludes M2W (M2W feeds WH, opposite of dissolve goal). `engine_publish_to_refill_plan` upgraded to map M2W → 'Remove' refill_plan_output row (driver pulls; "to WH" destination implicit), with shelf_code resolved from `reasoning.shelf_code_origin` and comment annotated `[pull to warehouse]`. **Smoke test:** 19 M2W drafts emitted, 19 published as 'Remove [pull to warehouse]' rows, skipped_no_substitute dropped from 112 to 0. Cody approved without revisions; two operational notes for CS — M2W qty can be > 1 (physical units) vs SWAP REMOVE qty=1 (slot signal); Pearson-no-WH-stock now flows to M2W instead of skip.

**Rollback:**
```sql
-- Restore D-3c propose_swap_plan / reconcile / publish bodies (no M2W path).
-- See phaseD3c migration source for prior versions.
```

---

## 2026-05-10 — Phase D-3c: Wire ENGINE ADD to dissolve_batch intents
**Phase / Article:** D-3c / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseD3c_wire_add_to_dissolve_batch`

**Summary:** D-3 wired SWAP to decommission intents but deferred ADD wiring for dissolve_batch. Today the Vitamin Well Care intent (5 units to drain by 2026-05-24) sat at 0/5 in the queue — nothing routed from EXPIRY OPT to ADD. D-3c closes the loop. `propose_add_plan` now checks each refill candidate for an active dissolve_batch intent matching the boonz_product (oldest active intent if multiple); when found, the REFILL draft is tagged with `linked_intent_id` so reconcile credits the dissolve goal. WH-batch FEFO routing remains the warehouse manager's call at pick time. `reconcile_intent_progress` upgraded to intent-type-conditional action filter: `decommission` credits REMOVE only (D-3b behavior), `dissolve_batch` credits REFILL only (D-3c new). Future additive types (`introduce`, `rotate_in`) add their own clause. Cursor JOIN to strategic_intents lets the type/action match happen in SQL rather than per-row plpgsql. Cody approved without revisions. **Smoke test:** Vitamin Well Care moved queued 0/5 → completed 7/5 in one orchestrator run. `intent_linked_drafts=6` reported by ADD; one REFILL of qty=7 saturated the threshold and auto-completed (mixed-batch overshoot is the documented v1 limitation).

**Limitation (documented):** REFILL crediting toward dissolve_batch is approximate. The draft doesn't carry `source_batch_id`; if WH has both the at-risk batch and a fresh batch, FEFO behavior at the warehouse depends on operator discipline. Crediting full refill qty regardless of which batch the units came from overstates progress in mixed-batch scenarios. Step 5c tightens this to true batch-stock decrement once `refill_plan_output.source_batch_id` lands.

**Rollback:**
```sql
-- Restore D-3b/D-3a propose_add_plan body (no linked_intent_id tagging) and reconcile body (REMOVE-only filter).
-- See migration phaseD3b_reconcile_action_filter_and_intent_recompute for the prior reconcile source.
```

---

## 2026-05-10 — Phase D-5b: engine_publish_to_refill_plan
**Phase / Article:** D-5b / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseD5b_engine_publish_to_refill_plan`

**Summary:** Closes the biggest gap between the optimizer brain and operators. Before D-5b, `orchestrate_refill_plan` ran ADD → SWAP → FINALIZE → RECONCILE but FINALIZE just flipped draft status; nothing crossed to `refill_plan_output`, the operator-facing table. New `engine_publish_to_refill_plan(plan_date)` reads finalized drafts and hands them to `write_refill_plan` (the canonical refill_plan_output writer) with title-cased action mapping (REFILL→Refill, REMOVE→Remove, ADD_NEW→Add New) — critical because field-packing FE keys on title case (CS memory). Resolves machine_id → official_name via `machines`, boonz_product_id → name via `boonz_products`. For ADD_NEW drafts (no pod_product_id), looks up global default pod via `product_mapping`. PUBLISH is a thin adapter — `write_refill_plan` remains the sole canonical writer for refill_plan_output (Article 1). Counts skipped rows by reason (`skipped_m2w` for unsupported MACHINE_TO_WAREHOUSE action, `skipped_no_machine`, `skipped_no_product`). Modified `orchestrate_refill_plan` to add PUBLISH as 4th stage between FINALIZE and RECONCILE: ADD → SWAP → FINALIZE → PUBLISH → RECONCILE. **Smoke test:** 667 rows published across 21 machines in 1.8s, three intent-driven swap pairs surfaced correctly with intent UUIDs in comment field, all actions in title case (Refill 437 / Add New 115 / Remove 115). Reconcile cutover from "finalized draft" proxy to "applied refill_plan_output row" deferred to D-5c (requires linked_intent_id column on refill_plan_output, separate Dara migration).

**Idempotency note:** `write_refill_plan` does a scoped DELETE of pending rows for affected machines before re-INSERT. Re-running orchestrate_refill_plan during a review window replaces unreviewed pending rows for those machines. Approved rows are untouched. Documented in function COMMENT.

**Rollback:**
```sql
-- Restore the prior orchestrate_refill_plan body (ADD → SWAP → FINALIZE → RECONCILE, no PUBLISH stage).
-- See migration phaseD0a_reconcile_and_lifecycle for the prior source.
DROP FUNCTION IF EXISTS public.engine_publish_to_refill_plan(date);
```

---

## 2026-05-10 — Phase D-3b: reconcile_intent_progress action filter + intent recompute
**Phase / Article:** D-3b / Constitution Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `phaseD3b_reconcile_action_filter_and_intent_recompute`

**Summary:** D-3a unmasked a latent bug in `reconcile_intent_progress`: SWAP pairs link `linked_intent_id` on BOTH the REMOVE draft (qty=1) AND the paired ADD_NEW draft (qty up to 8), and reconcile was summing both — so each swap pair credited 9 units against a decommission intent instead of 1. After the D-3a smoke test, Leibniz Zoo Cocoa read 12/7 'completed' (truth: 4/7 in_progress) and Sabahoo Chocolate 9/4 'completed' (truth: 1/4 in_progress). D-3b adds `AND d.action = 'REMOVE'` to the reconcile cursor — only the decommission side credits applied_units, ADD_NEW remains in the events array as audit but doesn't count. Inline comment flags that future additive intent types (`introduce`, `rotate_in`) will need a CASE-per-intent_type filter when they land. Same migration includes a one-time DO block that recomputes `applied_units` for any active decommission/dissolve_batch intent currently 'completed' from REMOVE-event qty only, flips status back to 'queued' or 'in_progress' depending on whether any REMOVE events exist, and clears `closed_at` / `closure_reason`. Idempotent — guarded by `recomputed_applied < acceptable AND status = 'completed'`. Audit captured via `app.via_rpc='true'` and distinct `app.rpc_name='phaseD3b_intent_recompute_data_fix'` so the `write_audit_log` row explains why each touched intent flipped. Post-apply verification: Leibniz Zoo Cocoa now in_progress 4/7, Sabahoo Chocolate in_progress 1/4, both `closed_at` NULL.

**Rollback:**
```sql
-- Restore D-3a/D-0a reconcile body (without action filter):
-- See D-0a entry for the original CREATE OR REPLACE source.
-- The data fix cannot be cleanly rolled back — once applied, the
-- bogus 'completed' state is gone. To undo, manually re-flip:
-- UPDATE strategic_intents SET status='completed', closed_at=now(), ...
-- but only with operator approval; the previous state was incorrect anyway.
```

---

## 2026-05-10 — Phase D-3a: propose_swap_plan calibration + guardrails
**Phase / Article:** D-3a / Constitution Articles 1, 4, 12
**Applied to:** prod
**Migration name:** `phaseD3a_swap_calibration_and_guardrails`

**Summary:** D-3 smoke test produced `intent_driven_swaps=0` despite three active intents in the queue. Root cause: default `p_min_substitute_score=30.0` was set blind, before live correlation data. Observed in-category Pearson distribution across 166 active products: median top score = 28.18, p25 = 19.01, floor = 10.0. At threshold 30 only 47/166 products could find a substitute; at 10, 93 can. 71 products have NO Pearson signal at all (single-machine SKUs, no co-purchase basket). D-3a recalibrates default to 10.0 AND adds a category-anchored fallback: when `get_similar_products` returns nothing, pick the highest-velocity in-category SKU (slot_lifecycle.velocity_30d aggregated, deterministic UUID tiebreaker) with WH stock ≥ 4 and non-expired buffer. CS-flagged guardrails added to BOTH Pearson and fallback paths: (1) substitute must not have an Active pod_inventory row on the target machine — verified against FSM where Active+stock=0 means "slot allocated, awaiting refill" not "removed"; (2) substitute must not itself be in an active decommission intent. Both passes (strategic and autonomous) get the same treatment so intent-driven and autonomous swaps share filtering. Post-apply smoke test: `intent_driven_swaps=3, autonomous_swaps=36, pearson_substitutes=19, fallback_substitutes=20, skipped_no_substitute=133` (down from 224 with 30.0 threshold). Function comment updated.

**Rollback:**
```sql
-- Restore D-3 propose_swap_plan body (default p_min_substitute_score=30.0,
-- no category fallback, no on-machine guard, no decommission-target guard).
-- Source in migration 20260506_phaseD3_wire_addswap_to_intents.sql.
```

---

## 2026-05-10 — Phase D-3: Wire ENGINE ADD/SWAP to read strategic_intents
**Phase / Article:** D-3 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseD3_wire_addswap_to_intents`

**Summary:** Closes the strategic-intent loop. `propose_swap_plan` now runs a two-pass design: Pass 1 walks active `decommission` intents whose target_completion_date >= plan_date, joins to pod_inventory rows for products in scope, and emits SWAP REMOVE+ADD_NEW pairs with `linked_intent_id` set so reconcile can credit progress when the operator approves+applies the row. Pass 2 retains the original autonomous slot-signal logic for ROTATE_OUT/DEAD/WIND_DOWN slots not addressed in Pass 1. Per-machine cap (default 2) shared across both passes — strategic intents take priority. Cody's required revision applied during draft: shelf_code resolution now goes via `pod_inventory.shelf_id → shelf_configurations` instead of an unsafe `'A01'` fallback that would have placed SWAP REMOVE rows on the wrong shelf. New skip counter `skipped_no_shelf` for traceability. `propose_add_plan` integration with dissolve_batch intents deferred to D-3c (its WH-source-selection logic doesn't yet pick specific batches; intent-aware routing is premature). NB: D-3a immediately followed because the 30.0 threshold default produced zero intent-driven swaps despite live intents.

**Rollback:**
```sql
-- Restore the prior single-pass propose_swap_plan body (autonomous-only).
-- See migration phaseC_c5_decompose_addswap for the prior source.
```

---

## 2026-05-08 — Phase B.3: Lifecycle scoring redesign (Global rank-percentile + Local spectrum + EMA + signalV2)
**Phase / Article:** B.3 / Constitution Articles 9, 12, 13, 14, 15
**Applied to:** prod
**Migration name:** `phaseB_b3_lifecycle_scoring_redesign`

**Summary:** Splits the lifecycle scoring engine into two distinct formulas — `product_lifecycle_global.score` is now rank-percentile across all stocked products by per-machine-average velocity, and `slot_lifecycle.score` is now a ratio-spectrum centered on each product's own per-machine global average (5.0 = at avg, 10.0 = 2× avg). Both scores are EMA-blended with prior value (α=0.67 → recent ≈ 2× historical, satisfying CS's "compound upward/downward" intuition). Signal logic shifts to `getSignalV2` — DOUBLE DOWN and KEEP GROWING now require BOTH score AND trend to clear thresholds (hard-gate), eliminating the case where high-volume-but-flat products were branded DOUBLE DOWN. RAMPING flag bubbles from slot to product level via new `product_lifecycle_global.ramping_machine_count` column. **First post-deploy verification:** Aquafina (92.27 u/day total, 7 machines, 13.18/machine avg) now ranks #1 with score_raw=10.00. Evian Sparkling (0.27 u/day, 2 machines, 0.135/machine avg) now ranks #36 with score_raw=5.39 — exactly the per-machine apples-to-apples ranking CS asked for. Edge fn `evaluate-lifecycle/index.ts` deployed v12 with phase reorder (per-product totals computed BEFORE per-slot scoring so each slot can read its product's per-machine avg as the spectrum anchor). Six new observability columns added across `product_lifecycle_global` and `slot_lifecycle` for audit (per_machine_avg_v30, global_rank, score_raw, ramping_machine_count, local_score_raw, spectrum_ratio, product_avg_v30_at_score_time). New view `v_product_lifecycle_global_enriched` (SECURITY INVOKER) joins product+family+ramping markers for the Global matrix FE consumer. `lifecycle_score_history.score_kind` enum tags new rows as 'v2_split_global_local' for forward-compat traceability.

**Behavior changes (Article 15 disclosure):**
1. `product_lifecycle_global.score` formula changed from velocity-weighted-average-of-cohort-relative-scores to rank-percentile of per_machine_avg_v30 across all products with machine_count > 0. Top product = 10, bottom = 0, evenly distributed by rank.
2. `slot_lifecycle.score` formula changed from cohort-baseline-relative to product-portfolio-spectrum (5.0 = at product's per-machine avg, 10.0 = 2× avg, 0.0 = zero). Spectrum ratio capped at 2× before scoring.
3. Both scores now EMA-blended with prior value: `new_score = 0.67 × computed_today + 0.33 × prior`. New rows bootstrap with prior=computed (no memory yet, converges over ~3 cron ticks).
4. `getSignalV2` replaces `getSignal`. Hard-gate: DOUBLE DOWN requires score≥8 AND trend≥7; KEEP GROWING requires score≥6 AND trend≥7; KEEP requires score≥4 AND trend≥4 (or score≥4 AND trend<4 → WIND DOWN). Eliminates the score=4.5 dead-band orphan from B.1.1.

**Article 9 status (extends prior known-debt note from B.1, B.1.1, B.1.2):** `evaluate-lifecycle` continues to do business logic + direct writes inline. B.3 adds three new logic blocks to that footprint: (a) per-product aggregation phase (Phase 3b/3c) before per-slot scoring, (b) rank-percentile computation across the product universe (Phase 3c), (c) EMA blend on both score paths (Phases 3d + 4), (d) RAMPING bubble counting per product (Phase 3b). Same Phase B follow-up to wrap evaluate-lifecycle in a `compute_and_apply_lifecycle()` SECURITY DEFINER RPC absorbs all of these. Tracked under Task 21.

**Deploy checklist (operational note from Cody review):**
- Migration applied first (additive columns only, no data backfill — new columns NULL on existing rows).
- Edge fn v12 deployed second.
- `trigger_lifecycle_eval()` invoked manually post-deploy to populate new columns within ~30s. Verified: 77 products updated, Aquafina ranked #1 as expected.
- One-time score-shock: every product/slot's score shifted from old formula to new. EMA smooths the second tick onward. Subsequent cron runs converge each score to its new equilibrium over ~3 ticks.

**Code locality note (extends B.1.1 note):** Phase reorder logic, rank-percentile, EMA, RAMPING bubble all live in Deno (`evaluate-lifecycle/index.ts`). Update site for any future signal/score formula tweaks: same file, search for `getSignalV2`, `productGlobalRawScore`, `ema`, `ramping_machine_set`.

**Rollback:**
```sql
-- Revert evaluate-lifecycle to v11 first (blob in Edge Function dashboard).
-- Then drop the additive columns:
DROP VIEW IF EXISTS public.v_product_lifecycle_global_enriched;
DROP INDEX IF EXISTS public.idx_slot_lifecycle_product_score;
DROP INDEX IF EXISTS public.idx_product_lifecycle_global_rank;
ALTER TABLE public.lifecycle_score_history DROP COLUMN IF EXISTS score_kind;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS product_avg_v30_at_score_time;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS spectrum_ratio;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS local_score_raw;
ALTER TABLE public.product_lifecycle_global DROP COLUMN IF EXISTS ramping_machine_count;
ALTER TABLE public.product_lifecycle_global DROP COLUMN IF EXISTS score_raw;
ALTER TABLE public.product_lifecycle_global DROP COLUMN IF EXISTS global_rank;
ALTER TABLE public.product_lifecycle_global DROP COLUMN IF EXISTS per_machine_avg_v30;
-- Existing score values are EMA-blended with new formula; reverting fully requires retrigger after rollback.
```

---

## 2026-05-08 — Phase B.1.2: All-time first-sale view fix for ramping detection
**Phase / Article:** B.1.2 / Constitution Articles 2, 9, 12
**Applied to:** prod
**Migration name:** `phaseB_b1_2_machine_first_sale_view`

**Summary:** B.1.1 derived per-machine first-sale-date from the same 62-day sales window already loaded for velocity computation. That window-min is **not** the same as all-time first-sale: a mature machine with a quiet patch in the window (e.g., WAVEMAKER-1006 and WPP-1002, both first-sold 2025-09-26 but with no sales between Mar 6 and Apr 14, 2026) reported a within-window first-sale of 2026-04-14 — falsely flagging them RAMPING after B.1.1 deploy. B.1.2 adds a dedicated read-only view `v_machine_first_sale` (`SELECT machine_id, MIN(transaction_date), MAX(transaction_date), COUNT(*) FROM sales_history WHERE delivery_status='Successful' GROUP BY machine_id`), declared `SECURITY INVOKER` so caller RLS applies. Edge fn `evaluate-lifecycle/index.ts` now reads from this view to populate `firstSaleByMachine`, replacing the window-min derivation. The fallback to `machines.created_at` for never-sold machines is preserved. Verified post-deploy: WAVEMAKER (224d) and WPP (224d) correctly classify as mature and receive normal signals; six genuinely-young machines (ACTIVATE-2005 15d, ACTIVATEMCC-1037 6d, IFLYMCC-1024 5d, MPMCC-1054 6d, MPMCC-1058 8d, NOVO-1023 13d) correctly remain RAMPING.

**Article 9 status:** Same pre-existing debt — edge fn does business logic + direct writes. Tracked under the same Phase B follow-up.

**Rollback:**
```sql
-- Revert evaluate-lifecycle/index.ts to v10 (B.1.1 derivation from sales window).
-- Then drop the view:
DROP VIEW IF EXISTS public.v_machine_first_sale;
```

---

## 2026-05-08 — Phase B.1.1: Machine ramping + signal band fix
**Phase / Article:** B.1.1 / Constitution Articles 1, 3, 9, 15
**Applied to:** prod (edge fn) + repo (FE — pending Vercel deploy)
**Migration name:** none — code-only patch

**Summary:** Two related fixes to `evaluate-lifecycle/index.ts` after CS observed newly-deployed VOX machines (MPMCC-1058, MPMCC-1054, ACTIVATEMCC-1037, ACTIVATE-2005) being categorized as DEAD/ROTATE OUT despite being only 6–14 days post-first-sale. **Fix 1: Machine ramping protection.** New constant `MACHINE_RAMP_DAYS=30`. New helper `isRampingMachine()` derives per-machine first-sale-date from the existing 62-day sales window with `machines.created_at` as fallback (preserves the distinction between truly-young machines and long-dark mature machines — the latter continue to flag MACHINE_DARK, not RAMPING). When a machine is within its ramp window, its slot signals override to a new `RAMPING` value regardless of computed score/trend. New DQ flag type `MACHINE_RAMPING` surfaces affected machines (severity=info; days-since-first-sale or days-since-creation logged in message). The `lifecycle_data_quality_flags` resolve-stale list expanded to include `MACHINE_RAMPING`. **Fix 2: Score-band gap closure.** Previous `getSignal` had three orphan bands that fell through to DEAD by accident: (a) `score≥4.5 && score<8.5 && trend<3.5`, (b) `score≥4.5 && score<8.5 && trend>6.5`, (c) `score≥6.5 && trend≤5`. Simplified band logic so any `score≥4.5` floors to KEEP regardless of trend; only DOUBLE DOWN and KEEP GROWING still require trend confirmation (>5). This was the proximate cause of MPMCC-1058's slots being flagged DEAD at the cap-induced score=4.5. **FE:** added `RAMPING: "#3b82f6"` (blue) to `SIGNAL_COLORS`; added `RAMPING` to `sigOrder` legend list; matrix points now render in distinct blue with proper tooltip badging via existing `getSignalColor` plumbing. **Verification:** triggered `trigger_lifecycle_eval()` post-deploy, confirmed MPMCC-1058 / MPMCC-1054 / ACTIVATEMCC-1037 / ACTIVATE-2005 now show signal=RAMPING for all slots, mature machines (NOVO-1023, OMDCW-1021) unaffected.

**Article 9 status:** Same pre-existing debt as B.1 — edge fn does business logic + direct writes inline. No new debt entry; the B.1 known-debt note already covers the additional logic. Still tracked under the same Phase B follow-up to wrap evaluate-lifecycle in a `compute_and_apply_lifecycle()` SECURITY DEFINER RPC.

**Behavior changes (Article 15 disclosure):**
- `score≥4.5 && score<8.5 && trend<3.5` was DEAD → now KEEP.
- `score≥4.5 && score<8.5 && trend>6.5` was DEAD → now KEEP.
- `score≥6.5 && trend≤5` was DEAD → now KEEP (or KEEP GROWING if trend>5, unchanged).
- All slots at machines within 30-day ramp window now signal=RAMPING regardless of computed score/trend.

**Rollback:**
```ts
// Revert evaluate-lifecycle/index.ts:
// 1. Remove MACHINE_RAMP_DAYS, isRampingMachine helper, firstSaleByMachine map.
// 2. Revert getSignal to the pre-B.1.1 trend-band-gated version.
// 3. Remove RAMPING override at the slotUpdates push site.
// 4. Remove MACHINE_RAMPING from the resolve-stale list and from the dqFlags emit loop.
// 5. Remove RAMPING from FE SIGNAL_COLORS and sigOrder.
```
Existing slot_lifecycle.signal values containing "RAMPING" will be overwritten on the next cron tick after rollback. No DDL involved.

---

## 2026-05-07 — Phase B.1: Lifecycle reality anchor (snapshot-driven, ledger PK)
**Phase / Article:** B.1 / Constitution Articles 1, 2, 3, 7, 9, 12, 14
**Applied to:** prod
**Migration name:** `phaseB_b1_lifecycle_reality_anchor`

**Summary:** Repoints the lifecycle scoring engine off `planogram` (frozen seed since April 2026, no FE writer) onto `weimi_aisle_snapshots` (refreshed every ~6h by the WEIMI integration) for the runtime "what product is in this slot" question. Planogram retains its single legitimate runtime job: deployment-time seeding by `new-machine-onboarding`. To preserve product-level score history when slots rotate, `slot_lifecycle` is converted from a (machine, shelf) snapshot to a (machine, shelf, product) ledger: three new columns (`is_current` boolean default true, `rotated_in_at` timestamptz default now(), `rotated_out_at` timestamptz nullable), constraint rotation from `UNIQUE (machine_id, shelf_id)` to `UNIQUE (machine_id, shelf_id, pod_product_id)`, and a partial unique index `uq_slot_lifecycle_current_per_slot` on `(machine_id, shelf_id) WHERE is_current=true AND archived=false` to enforce the "exactly one current product per live slot" invariant. Two indexes added to `lifecycle_score_history` for per-slot-per-product history queries. Pre-flight DO-block aborts cleanly if existing data violates the new invariant. The companion `evaluate-lifecycle/index.ts` diff replaces the planogram read with a snapshot + shelf_configurations read, normalizes WEIMI's "A1"/"A15" slot codes to padded "A01"/"A15" shelf codes (with TS-side resolver `padShelf` and `normalizeName` for product-name matching trim+lowercase+collapse-whitespace), detects rotations by comparing the new dominant product per (machine, shelf) to the existing `is_current=true` row and flipping the prior row to `is_current=false, rotated_out_at=now()`, and upserts new scores with the new ledger conflict key. New DQ flag types `UNRESOLVED_SHELF_ID` and `UNRESOLVED_POD_PRODUCT_NAME` surface unresolvable snapshot rows for ops attention. Lifecycle FE matrix at `src/app/(app)/app/lifecycle/page.tsx` filters to `is_current=true` by default with a "Show rotated-out products" toolbar toggle that overlays prior products as faded points with dashed strokes and rotation timestamps in tooltips. Cleared lockstep release: migration → edge fn deploy → FE deploy → cron tick verification.

**Origin context:** The original B.1 design was justified by an inflated 92% drift number that came from a SQL normalization bug on my end (treating `0-A14` as shelf `A14` rather than `A15` — WEIMI's sales feed uses zero-indexed slot labels, snapshot/shelf_configurations use one-indexed). After correction, real drift is ~9% (mostly recent rotations the snapshot has already caught up with). The schema design survives because keeping rotated-out products visible on the matrix and preserving their score history is independently valuable. Snapshot anchoring eliminates the need for `v_current_slot_assignment`, `v_unresolved_sales_product_names`, and `pod_product_name_normalize` (the sales-anchored design's helpers) — the snapshot already says what's currently in each slot, so no 30-day sales aggregation is required. CS approved Scope B (planogram retired from runtime hot path); refill engine retirement is filed as `phaseB_b2_refill_engine_planogram_retirement`.

**Known debt: evaluate-lifecycle Article 9 conformance.** The edge fn does business logic (velocity / trend / consistency / score / signal / rotation-detection / archive-detection) and direct writes to `slot_lifecycle`, `lifecycle_score_history`, `lifecycle_data_quality_flags`, `product_lifecycle_global`. This violates Article 9 ("Edge functions are HTTP wrappers around RPCs. No business logic. No direct table writes."). It is pre-existing and was not introduced by B.1; B.1 deepens it by adding rotation-detection logic. Tracked as Phase B follow-up: convert evaluate-lifecycle to wrap a SECURITY DEFINER RPC `compute_and_apply_lifecycle()` so writes flow through Article 4 / Article 8 plumbing.

**Code locality note.** Pod product name normalization moved from a planned SQL `pod_product_name_normalize(text)` IMMUTABLE helper into Deno (`evaluate-lifecycle/index.ts:normalizeName`). This is a maintainability tradeoff: future tweaks to the resolver (e.g., adding alias rules, handling new WEIMI conventions) require redeploying the edge fn rather than executing a migration. Update site is `supabase/functions/evaluate-lifecycle/index.ts`.

**Rollback:**
```sql
-- Note: rolling back to (machine_id, shelf_id) UNIQUE will fail if any (machine, shelf)
-- has multiple non-archived rows. The edge fn must be reverted to its pre-B.1 version
-- BEFORE the schema rollback so no further rotation rows are created. Then:
DROP INDEX IF EXISTS public.uq_slot_lifecycle_current_per_slot;
DROP INDEX IF EXISTS public.idx_lifecycle_hist_slot_product_date;
DROP INDEX IF EXISTS public.idx_lifecycle_hist_product_machine_date;
ALTER TABLE public.slot_lifecycle DROP CONSTRAINT IF EXISTS slot_lifecycle_machine_shelf_product_uk;
-- Manually delete is_current=false rows OR consolidate, then:
ALTER TABLE public.slot_lifecycle ADD CONSTRAINT slot_lifecycle_machine_id_shelf_id_key UNIQUE (machine_id, shelf_id);
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS is_current;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS rotated_out_at;
ALTER TABLE public.slot_lifecycle DROP COLUMN IF EXISTS rotated_in_at;
```

---

## 2026-05-06 — Phase D.0a: linked_intent_id + reconcile + abandon + expire + orchestrator
**Phase / Article:** D.0a / Constitution Articles 1, 4, 5, 8, 11, 12
**Applied to:** prod
**Migration name:** `phaseD0a_reconcile_and_lifecycle`

**Summary:** Wired the strategic-intent layer to the tactical pipeline. `daily_plan_drafts.linked_intent_id` (nullable FK to strategic_intents, ON DELETE RESTRICT, indexed via partial index where IS NOT NULL) lets drafts written by ADD/SWAP reference the strategic intent they're helping advance — NULL means autonomous decision (legacy/orthogonal path). Three new DEFINERs: **`reconcile_intent_progress(plan_date)`** is the sole writer of `strategic_intents.progress` jsonb and the queued/in_progress→completed transitions; iterates finalized drafts with linked_intent_id, dedups by draft_id (re-running on the same plan_date is a no-op), appends progress events with full draft trace, auto-completes when applied_units >= target_qty - max_residual_units. **`abandon_intent(intent_id, reason)`** is the operator-only closure path (queued/in_progress/blocked → abandoned) requiring a non-empty reason. **`expire_intents()`** is the cron-callable sweeper (active intents whose target_completion_date is past → expired). Modified `orchestrate_refill_plan` to add reconcile as the 4th stage so the loop closes automatically after every refill cycle: propose_add → propose_swap → engine_finalize → reconcile_intent_progress. **Phase D-0a proxy:** uses `daily_plan_drafts.status='finalized'` as the "approved+applied" signal until Step 5b writes the canonical `refill_plan_output`. The intent FSM, abandon/expire RPCs, and orchestrator stay identical when reconcile shifts to read from `refill_plan_output` directly. **End-to-end smoke test:** linked a synthetic SWAP draft to the Leibniz Zoo Cocoa intent (the operator-created intent from D.0), ran finalize then reconcile, observed the intent transitioned `queued → in_progress` with `applied_units=3` (of `target_qty=7`) and a proper event in the progress jsonb. Re-ran reconcile to confirm idempotency (0 new events via draft_id dedup). Article 8 audit captured the UPDATE with `via_rpc=true, rpc_name='reconcile_intent_progress'`. Cody approved without revisions.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.expire_intents();
DROP FUNCTION IF EXISTS public.abandon_intent(uuid, text);
DROP FUNCTION IF EXISTS public.reconcile_intent_progress(date);
DROP INDEX IF EXISTS public.idx_dpd_linked_intent;
ALTER TABLE public.daily_plan_drafts DROP COLUMN IF EXISTS linked_intent_id;
-- orchestrate_refill_plan stays at the 4-stage version; recreate the 3-stage form if needed.
```

---

## 2026-05-06 — Phase D.0: strategic_intents (programmed action queue)
**Phase / Article:** D.0 / Constitution Articles 1, 2, 5, 7, 8, 12, 14, 15 + Amendment 006
**Applied to:** prod
**Migration name:** `phaseD0_strategic_intents`

**Summary:** First step of Phase D — the strategic intent layer that sits between the strategic engines (PRODUCT OPT, EXPIRY OPT, future MACHINE OPT) and the tactical executors (ADD, SWAP). Multi-cycle action plans live here. **Strategic engines never write to `daily_plan_drafts` directly** — they write intents (e.g. "decommission Vitamin Well from machines A,B,C by Aug 1; target_qty=18"), and ADD/SWAP pull from the queue each cycle, deciding which intents to advance based on today's reality. **Crucial design rule (CS clarified 2026-05-06):** intent progress reflects ONLY what was approved AND applied through the canonical refill pipeline — drafts written, drafts overruled by FINALIZE, and drafts rejected by operator review do NOT progress intents. A future `reconcile_intent_progress` RPC (Phase D-0a) is the sole writer of status/progress changes, driven by what lands in `refill_plan_output`. New protected table with six-value status FSM (queued / in_progress / completed / abandoned / expired / blocked), five type-conditional CHECK constraints (dissolve_batch requires source_wh_inventory_id; routing types disallow it; terminal status requires closure metadata; abandoned requires reason; target completion date must be future), four canonical INSERT writers planned (propose_decommission_plan, propose_batch_dissolution_plan, write_operator_intent, plus reconcile/abandon/expire as UPDATE writers), FORCE RLS, append-only, audit trigger. Six indexes including partial unique to prevent duplicate active intents on (intent_type, scope_boonz_product_id, source_wh_inventory_id). Three negative tests passed (dissolve_batch w/o source rejected by si_dissolve_batch_has_source; decommission w/ source rejected by si_routing_types_no_batch; past target date rejected by si_target_completion_future). **First real intent inserted:** Leibniz Zoo Cocoa decommission for ALJLT-1015 + OMDCW-1021, 7 units target, 21-day window — operator-initiated based on the optimization analysis from earlier in this session. **Amendment 006 to the Constitution:** strategic_intents joins Appendix A protected entities. Cody approved without revisions. **Next:** D-0a wires linked_intent_id on daily_plan_drafts + reconcile_intent_progress + abandon_intent + expire_intents (cron-callable).

**Rollback:**
```sql
DROP TRIGGER IF EXISTS tg_audit_strategic_intents ON public.strategic_intents;
DROP TABLE IF EXISTS public.strategic_intents;
```

---

## 2026-05-06 — Phase C.5: Parallel-engine orchestrator (ADD + SWAP + FINALIZE end-to-end)
**Phase / Article:** C.5 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseC5_orchestrator`, `phaseC5_swap_dedup_fix`

**Summary:** Phase C complete. Three new DEFINER functions cap the parallel-engine architecture: (1) **`propose_add_plan(plan_date, min_qty_threshold, days_cover)`** — ENGINE ADD. INSERT-only writer that iterates v_live_shelf_stock + slot_lifecycle, computes Engine B refill qty (CLAMP(velocity × 21d cover, floor=3 office / 4 entertainment, max_stock)), caps by WH availability with the 7-day expiry buffer, writes REFILL drafts. Phase C-5 prototype omits multi-variant split, machine_modes overrides, field-note application — these are Phase D refinements. (2) **`propose_swap_plan(plan_date, max_swaps_per_machine, min_substitute_score)`** — ENGINE SWAP. INSERT-only writer that iterates slot_lifecycle for ROTATE_OUT / DEAD / WIND_DOWN slots sorted worst-score-first, calls `get_similar_products()` (PRODUCT CORRELATION handshake), emits paired REMOVE + ADD_NEW drafts when a category-matching substitute exists with ≥4 units WH stock. **Cody revision applied:** the function is strictly INSERT-only — pairing is one-way (ADD_NEW.paired_draft_id points to REMOVE only, no bidirectional UPDATE), keeping ENGINE FINALIZE as the lone canonical UPDATE writer of daily_plan_drafts. **Follow-up patch `phaseC5_swap_dedup_fix`** wrapped both legs of a swap pair in one PL/pgSQL BEGIN..EXCEPTION subtransaction so unique_violation on either INSERT (legitimate dedup case when two REMOVE rows pick the same substitute) rolls back the partial pair gracefully. (3) **`orchestrate_refill_plan(plan_date)`** — thin orchestrator that calls ADD → SWAP → FINALIZE in sequence. ADD and SWAP are parallel-independent; FINALIZE handles all conflict resolution. Returns combined jsonb summary. **Does NOT yet call write_refill_plan** — that's a Step 5b enrichment task. **First end-to-end production run on CURRENT_DATE+2 produced:** 135 ADD drafts in 618ms + 37 SWAP pairs (74 drafts) in 1254ms = 209 total drafts; FINALIZE finalized 194 and overruled 15 by R1+R2+R4 (every overrule logged with machine_id, shelf_code, product, qty, reason); 51 R3 multi-variant warnings + 16 R5 net-flow warnings surfaced as guidance. Total 2.2s wall-clock. **Article 8 audit trail captured all 209 INSERTs and 209 status-flip UPDATEs in write_audit_log** with proper via_rpc=true and per-engine rpc_name attribution. The parallel-orthogonal architecture CS specified — ADD and SWAP independent, FINALIZE as conflict referee + sole UPDATE writer — is now real and observable in the data. **Phase D follow-ons:** R3 brand guardrail, R5 14-day cooldown, R7 60% shelf rule, MACHINE_TO_WAREHOUSE emission when no substitute available, `push_expiry_opt_to_drafts` so applied rotation_proposals flow into the draft pipeline, Step 5b enrichment + `write_refill_plan` call (turns finalized drafts into canonical refill_plan_output rows).

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.orchestrate_refill_plan(date);
DROP FUNCTION IF EXISTS public.propose_swap_plan(date, int, numeric);
DROP FUNCTION IF EXISTS public.propose_add_plan(date, int, int);
-- Drafts produced by these runs stay in daily_plan_drafts (FORCE RLS blocks DELETE).
-- They have status='finalized' or 'overruled'; can be filtered out of any future query.
```

---

## 2026-05-06 — Phase C.4: ENGINE FINALIZE (merge + conflict resolution)
**Phase / Article:** C.4 / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseC4_engine_finalize`

**Summary:** Step 4 of Phase C — the merge layer. New DEFINER function `engine_finalize(plan_date, dry_run=false)` reads all `daily_plan_drafts` for a plan_date, runs CS's parallel-engine conflict-resolution rules, and flips draft statuses. **Rule R1+R2+R4 (auto-resolve):** if SWAP touches a shelf, ADD drafts on that shelf are overruled with the documented reason. **Rule R6 (surface as warning):** if EXPIRY_OPT_PUSH targets product P at machine A, ADD drafts for product P at OTHER machines get flagged in the warnings array (not auto-overruled — at-risk push is a directive, not a block). **Rules R3 (multi-variant) and R5 (net-flow):** surfaced as warnings, both drafts proceed. The function returns a structured jsonb with total_drafts / finalized / overruled / resolutions / warnings / duration_ms — full explainability of every decision. **Phase C-4 prototype deliberately does NOT call `write_refill_plan`** — that's Step 5's orchestrator job. This step ships the merge layer cleanly so it can be tested independently. Smoke tests proved the design end-to-end: (1) dry-run on the existing 1-draft fixture returned `total_drafts=1, finalized=1, overruled=0` without modifying rows; (2) injected a synthetic SWAP REMOVE draft on VML-1004 shelf A07 (same shelf as the existing ADD REFILL smoke test), real run correctly returned `total_drafts=2, finalized=1 (SWAP), overruled=1 (ADD)` with full resolution detail in jsonb, and the ADD draft now shows `status='overruled'` with reason "Rule R1+R2+R4: SWAP action on this shelf overrules ADD maintenance refill"; (3) **Article 8 audit trail captured both UPDATEs** in write_audit_log with `via_rpc=true, rpc_name='engine_finalize'`; (4) empty-input edge case returned cleanly with the documented note. Role gate: operator_admin/superadmin/manager OR system context. Granted to authenticated AND service_role for cron callability. Cody approved without revisions.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.engine_finalize(date, boolean);
-- Note: drafts already flipped to finalized/overruled stay that way (FORCE RLS blocks
-- DELETE; status is terminal). Acceptable because the function only changed metadata.
```

---

## 2026-05-06 — Phase C.3: ENGINE PRODUCT CORRELATION v1 (machine basket affinity)
**Phase / Article:** C.3 / Constitution Article 12 (read-only INVOKER, no protected-entity writes)
**Applied to:** prod
**Migration name:** `phaseC3_product_correlation_v1`

**Summary:** Step 3 of Phase C — read-only intelligence layer for ENGINE SWAP and future ENGINE PRODUCT OPT to query product similarity. New view `v_product_basket_affinity` computes Pearson correlation of per-machine `velocity_30d` (sourced from `slot_lifecycle`) for every (A,B) pair where both products are stocked-and-selling on at least 3 shared machines. Combined score is bounded 0-100, with a log-saturated shared-machines factor (saturating at 10 shared machines) and a velocity floor (suppresses noise pairs where both products barely sell). New INVOKER RPC `get_similar_products(boonz_product_id, top_n=5, min_score=10.0)` returns the top-N similar products with score, shared_machines, correlation, and a `source` label that future versions will diversify when sales-co-purchase + LLM-enrichment substrates land. **Substrate 1 (sales co-purchase) confirmed dead** — 2026-05-06 scout showed 100% of WEIMI transactions are single-SKU; revisit only if WEIMI exposes baskets or if temporal-proximity inference (60-second window same-machine) gets built (Phase D experiment). **Substrate 3 (LLM enrichment)** deferred to Phase C-3b — a Claude pass over the catalog tagging products with use_case / customer_persona / time_of_day affinities. v1 substrate is purely machine basket affinity. Smoke test results were strong: **Vitamin Well - Care** top similars are all 4 sister Vitamin Well variants (correlation 1.000 across 19 shared machines, score 71.28), then G&H Popped Chips trio (62.10), then M&M Chocolate Bag (55.88) — exactly the wellness-customer cluster you'd expect. **Rice Cake Dark Chocolate** top similars include the Milk Chocolate variant (54.20) and surprisingly all 6 Krambals variants at correlation 0.953 (51.68) — meaning Krambals is the natural successor whenever Rice Cake gets rotated out of an office machine, an insight no previous primitive could surface. View pair distribution: 6,960 total pairs, 436 strong (≥50), 920 moderate (20-50), 2,574 weak (5-20), 3,030 noise (<5). Cody approved without revisions. **Phase D follow-on:** weight-tuning the score formula once SWAP starts consuming, temporal-proximity basket inference experiment, LLM enrichment substrate.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.get_similar_products(uuid, int, numeric);
DROP VIEW IF EXISTS public.v_product_basket_affinity;
```

---

## 2026-05-06 — Phase C.2: daily_plan_drafts (shared draft surface)
**Phase / Article:** C.2 / Constitution Articles 1, 2, 5, 7, 8, 12, 14, 15 + Amendment 005
**Applied to:** prod
**Migration name:** `phaseC2_daily_plan_drafts`

**Summary:** Step 2 of Phase C — the shared draft surface where ENGINE ADD, ENGINE SWAP, and ENGINE EXPIRY_OPT_PUSH write their independent proposals; ENGINE FINALIZE will consume and merge into the canonical `refill_plan_output`. New protected entity `daily_plan_drafts` with FORCE RLS, append-only posture, and the universal audit trigger pattern (`tg_audit_daily_plan_drafts` calling `audit_log_write('draft_id')`). Status FSM `draft → finalized | overruled` with timestamp + reason CHECKs enforcing terminal-state metadata. **Schema-level engine orthogonality** via `dpd_engine_action_match`: ENGINE ADD can only emit `REFILL` actions, ENGINE SWAP only `REMOVE`/`ADD_NEW`/`MACHINE_TO_WAREHOUSE`, ENGINE EXPIRY_OPT_PUSH only `REFILL`/`ADD_NEW`. This is a hard-rule encoding of CS's parallel-independent engine design — no engine can step out of its lane regardless of bug. Self-FK `paired_draft_id` links the two legs of a SWAP pair (REMOVE + ADD_NEW or REMOVE + MACHINE_TO_WAREHOUSE) so FINALIZE can validate pair completeness before finalizing either leg. FK `ON DELETE` clauses revised per Cody — RESTRICT for FORCE-RLS-protected references (`paired_draft_id`, `linked_proposal_id` to rotation_proposals), SET NULL only for `proposed_by_user` since `user_profiles` allows deletion. **Important nuance for downstream readers:** the `action='REMOVE'` value is a *physical-world operation* (driver pulls product off shelf, returns to WH), not a database deletion — every row in this system is append-only by design. Negative test (`ADD + REMOVE`) correctly rejected by `dpd_engine_action_match`. Positive test (`ADD + REFILL` for VML-1004 Rice Cake) inserted cleanly. **Amendment 005 to the Constitution:** `daily_plan_drafts` joins Appendix A protected entities. Cody approved with FK revisions applied. **Step 4 (`engine_finalize`) and Step 5 (extract `propose_add_plan` / `propose_swap_plan`) will populate this table.**

**Rollback:**
```sql
DROP TRIGGER IF EXISTS tg_audit_daily_plan_drafts ON public.daily_plan_drafts;
DROP TABLE IF EXISTS public.daily_plan_drafts;
-- Note: dropping the table releases the FK constraints automatically.
```

---

## 2026-05-06 — Phase C.1: machine_to_warehouse proposal type
**Phase / Article:** C.1 / Constitution Articles 2, 5, 7, 8, 12, 14
**Applied to:** prod
**Migration name:** `phaseC1_machine_to_warehouse_type`

**Summary:** First atomic step of Phase C — the OVERALL/DAILY split that introduces ENGINE FINALIZE as the only writer to `refill_plan_output`, with ENGINE ADD and ENGINE SWAP producing parallel drafts. C.1 lays the schema foundation for the **2-step swap pattern** (machine → WH → machine, never machine → machine direct). Extends `rotation_proposals` with `target_warehouse_id` column (nullable), makes `target_machine_id` nullable, adds `machine_to_warehouse` to the `proposal_type` CHECK enum, adds new `rp_target_consistency` CHECK enforcing exactly-one-target-type by proposal_type (m2w → target_warehouse_id NOT NULL + target_machine_id NULL; all other types → target_machine_id NOT NULL + target_warehouse_id NULL). Updates `rp_source_consistency` to recognize m2w. Drops+recreates the partial unique index `uq_rp_active_source_target` to include target_warehouse_id (so two pending m2w to the same WH for the same product+source can't collide). Adds `idx_rp_source_machine_pending` to support ENGINE SWAP and ENGINE EXPIRY OPT lookups of "is there already a pending return for this machine?" Existing 21 pending wh_to_machine rows pass all new constraints (backward compatible). Smoke test inserted a real m2w proposal (HUAWEI-2003 returning Rice Cake to WH_CENTRAL) — succeeded. Negative test (m2w with target_machine_id set) correctly rejected by rp_target_consistency. Cody approved with one revision (added Articles satisfied header). **Step 5 will teach `propose_rotation_plan` to emit machine_to_warehouse rows when an underperforming slot is detected.**

**Rollback:**
```sql
-- Forward-only patch would be needed to undo. Direct SQL rollback:
ALTER TABLE public.rotation_proposals DROP CONSTRAINT IF EXISTS rp_target_consistency;
ALTER TABLE public.rotation_proposals DROP CONSTRAINT IF EXISTS rp_source_consistency;
ALTER TABLE public.rotation_proposals DROP CONSTRAINT IF EXISTS rotation_proposals_proposal_type_check;
ALTER TABLE public.rotation_proposals ADD CONSTRAINT rotation_proposals_proposal_type_check
  CHECK (proposal_type IN ('wh_to_machine','machine_to_machine','shelf_substitute'));
-- Note: would orphan the smoke-test m2w row. DELETE blocked by FORCE RLS — would need to drop+recreate policy temporarily.
DROP INDEX IF EXISTS public.idx_rp_source_machine_pending;
DROP INDEX IF EXISTS public.uq_rp_active_source_target;
ALTER TABLE public.rotation_proposals ALTER COLUMN target_machine_id SET NOT NULL;
ALTER TABLE public.rotation_proposals DROP COLUMN IF EXISTS target_warehouse_id;
```

---

## 2026-05-06 — Phase B.2b: Engine 2 canonical writers (4 RPCs) + score function multi-row patch
**Phase / Article:** B.2b / Constitution Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration name:** `phaseB2a_fix_score_function_multi_row`, `phaseB2b_engine2_rpcs`

**Summary:** Engine 2 is now end-to-end live as a read-write engine. Four DEFINER canonical writers for `rotation_proposals`: (1) `propose_rotation_plan(horizon_days, min_fit_score, max_per_source, dry_run)` — main loop iterating `v_warehouse_at_risk` for urgent buckets, scoring every active machine via `score_machine_for_product`, INSERTing top-N as pending proposals (`trigger_reason='expiry_risk'`, `proposal_type='wh_to_machine'` in B.2b; other reasons/types are future expansion). (2) `apply_rotation_proposal(proposal_id, plan_date, notes)` — CS approval; **Phase B prototype flips status only — does NOT create a planned_swaps row, that's Phase C wiring into the refill engine.** (3) `reject_rotation_proposal(proposal_id, reason)` — CS veto, captures reason in notes. (4) `mark_proposals_expired(age_days)` — daily housekeeping. All four set `app.via_rpc='true'` + `app.rpc_name=<name>`, validate inputs (NULL/range/FK), role-gate via `user_profiles`. System-callable functions (propose, mark_expired) bypass role gate when `auth.uid() IS NULL` so cron via `service_role` works; operator-only functions (apply, reject) require authenticated operator role with no bypass. `propose_rotation_plan` handles dedup via the partial unique index `uq_rp_active_source_target` — `unique_violation` is caught and counted as `skipped_dedup`. **Pre-emptive fix:** `phaseB2a_fix_score_function_multi_row` patched `score_machine_for_product` because `v_machine_absorption_capacity` returns multiple rows per (machine, boonz_product) pair when a boonz SKU is the global default for ≥2 pod_products (multi-variant scenario) — `DISTINCT ON (machine_id, boonz_product_id) … ORDER BY pod_product_id NULLS LAST` collapses the ctx CTE to one deterministic row. **First production run produced 21 pending proposals in 21s wall-clock**, 3 dedup-skips, 0 hard-blocks below threshold. Top scores: Vitamin Well Antioxidant→VOXMCC-1009 (82.7), Vitamin Well Care→VOXMCC-1009 (81.2), Vitamin Well Antioxidant→VOXMCC-1011 (81.1). Engine 2 routes the WH_MCC Vitamin Well stack toward the high-throughput VOX entertainment machines that already sell it — exactly the conduit pattern CS specified. **Article 8 verified end-to-end:** 21 audit rows in `write_audit_log` with `via_rpc=true`, `rpc_name='propose_rotation_plan'`, `operation='INSERT'`. Cody approved without revisions. **Phase B.3 follow-up:** pg_cron wiring (04:00 Dubai for propose, 03:00 for mark_expired) is a separate migration with its own Article 11 review.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.mark_proposals_expired(int);
DROP FUNCTION IF EXISTS public.reject_rotation_proposal(uuid, text);
DROP FUNCTION IF EXISTS public.apply_rotation_proposal(uuid, date, text);
DROP FUNCTION IF EXISTS public.propose_rotation_plan(int, numeric, int, boolean);
-- The fix to score_machine_for_product is forward-only; no rollback needed.
-- Pending proposals can be cleared via:
-- DELETE blocked at RLS — would need to drop RLS policies first OR mark them all 'expired' via mark_proposals_expired(0).
```

---

## 2026-05-05 — Phase B.2a: score_machine_for_product (Engine 2 fit scorer)
**Phase / Article:** B.2a / Constitution Article 12 (read-only INVOKER, no protected-entity writes)
**Applied to:** prod
**Migration name:** `phaseB2a_score_machine_for_product`

**Summary:** First Engine 2 RPC. Read-only `SECURITY INVOKER` function returning a `{score, hard_block, breakdown}` jsonb for routing a `boonz_product` to a target machine. 0-100 score combining five weighted components: throughput rank (35%), archetype/slot signal fit (20%), location_type fit using `product_lifecycle_global.best_location_type` / `worst_location_type` (15%), open shelf capacity vs proposed qty (15%), and urgency from projected days-to-sell vs horizon (10%). Hard cutoffs surface as `hard_block` reason: `no_pair_in_view`, `machine_excluded` (include_in_refill=false), `machine_inactive`, and `travel_scope_vox_locked` (the 8 VOX-locked SKUs from `engines/refill/guardrails/travel-scope.md` cannot route to non-VOX venue_groups). Reads `v_machine_absorption_capacity` (Phase A.5 view) — single source of truth, no parallel velocity computation. Cody review verdict ⚠️ Approve with revisions; both revisions applied (COALESCE guard on the throughput formula for the single-machine-fleet edge case where NULLIF would silently null the whole score; TODO comment in the function body marking the hardcoded VOX-locked list as a Phase C refactor target — should become a `travel_scope_locks` config table). Smoke tests: (1) Vitamin Well Upgrade → VOXMCC-1009 returned 69.94 with sensible breakdown (throughput 35 + location 15 + archetype 10 + capacity 7.5 + urgency 2.44); (2) Aquafina → VML returned 0 with `hard_block: travel_scope_vox_locked`; (3) ranking Vitamin Well across the fleet produced VOXMCC-1011 (74.68) > VOXMCC-1009 (69.94) > OMDBB (55.23) > office machines (~50) — top-2 are the highest-throughput VOX entertainment machines that already sell the product, exactly where Engine 2 should route at-risk warehouse stock. Function added to `RPC_REGISTRY.md` under Read-only helpers (now 9 functions). Phase B.2b (`propose_rotation_plan` DEFINER + 3 transition RPCs) is the next migration.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.score_machine_for_product(uuid, uuid, int, int);
```

---

## 2026-05-05 — Constitution Amendment 003 + 004: Appendix A additions
**Phase / Article:** Article 15 amendment
**Applied to:** repo (`01_constitution.html`)
**Migration name:** n/a (constitutive doc edit)

**Summary:** Two protected entities added to Appendix A. **Amendment 003:** `rotation_proposals` — Engine 2 (Rotation Planner) write surface. Append-only via DEFINER RPCs, FORCE ROW LEVEL SECURITY, status FSM (pending → applied | rejected | expired | superseded). Created in migration `phaseB_rotation_proposals_table`. **Amendment 004:** `machine_terminal_history` — created in A.4 with the protected posture but never formally promoted in the appendix; this entry codifies it. CS approved both 2026-05-05. Cody's `SKILL.md` protected entity list also updated to match (lives in the plugin install path outside the BOONZ BRAIN repo, updated through the plugin maintenance channel).

**Rollback:** Edit `01_constitution.html` to revert Appendix A entries. The protected status of these tables in production code (RLS, FORCE, RPCs) is independent of the appendix listing.

---

## 2026-05-05 — Phase B.1: rotation_proposals write surface
**Phase / Article:** B.1 / Constitution Articles 1, 2, 5, 7, 8, 12, 14, 15
**Applied to:** prod
**Migration name:** `phaseB_rotation_proposals_table`

**Summary:** Engine 2 (Rotation Planner) gets its output queue. New table `rotation_proposals` with three proposal types (`wh_to_machine`, `machine_to_machine`, `shelf_substitute`), source/target FKs, snapshot-at-proposal scoring fields (`machine_fit_score`, `projected_days_to_sell`, `scoring_breakdown` jsonb), and a 5-state status FSM (`pending → applied | rejected | expired | superseded`). Five CHECK constraints enforce type-conditional integrity: `rp_source_consistency` (wh/machine source matches type), `rp_shelf_required_for_substitute`, `rp_substitute_changes_product` (target ≠ source for substitutes; = source for routing types), `rp_review_consistency` (applied/rejected require reviewed_at), `rp_applied_has_plan_date`. RLS enabled AND **forced** (per Cody — without FORCE, DEFINERs could DELETE; FORCE makes the table truly append-only). Four policies: select-allow, insert/update/delete-block at WITH CHECK/USING false. Five indexes: `idx_rp_pending_proposed_at` (FE morning brief), `idx_rp_target_machine_pending` (per-machine pane), `uq_rp_active_source_target` (partial unique for dedup, COALESCEs nullable source columns to sentinel UUID), `idx_rp_proposed_at_all` (history), `idx_rp_linked_swap_id` (swap-back lookup). Universal audit trigger `tg_audit_rotation_proposals` calls `audit_log_write('proposal_id')` on every INSERT/UPDATE/DELETE — same pattern as `machine_terminal_history`, `pod_inventory`, `slot_lifecycle`, etc. Cody review verdict ⚠️ Approve with revisions; all three revisions applied (FORCE RLS, audit trigger, articles header). Bodies for the five canonical writers (`propose_rotation_plan` DEFINER, `apply_rotation_proposal` DEFINER, `reject_rotation_proposal` DEFINER, `mark_proposals_expired` DEFINER, `score_machine_for_product` INVOKER) ship in Phase B.2 with separate Cody review. Until those exist, no writes happen — the table sits empty by design.

**Rollback:**
```sql
DROP TRIGGER IF EXISTS tg_audit_rotation_proposals ON public.rotation_proposals;
DROP TABLE IF EXISTS public.rotation_proposals;
```

---

## 2026-05-05 — Manual lifecycle_archetype flips post-A.5 bootstrap
**Phase / Article:** A.5 follow-up / Constitution Article 5 (state machine — manual transition by CS)
**Applied to:** prod
**Migration name:** n/a (direct SQL by CS, per Cody's note that until Phase B's transition RPC ships, manual SQL by CS is the allowed path)

**Summary:** Bootstrap rule used "first attributable sale" as lifetime proxy, which mis-tagged a few mature SKUs as UNCLASSIFIED because their `product_mapping` was repointed recently. CS spot-checked the bootstrap distribution and authorized three manual corrections: **UNCLASSIFIED → ALWAYS_ON** for Pepsi - Regular (124 sales/30d), Perrier - Regular (19 sales/30d), SF Pancake - Chocolate Cream (8 sales/30d). **UNCLASSIFIED → TRIAL** for all SKUs of brands Healthy Cola (6 SKUs), Fade Fit (5 SKUs), Fade Fit Balade (2 SKUs) — these are newer brands CS is actively testing. Final distribution: 147 ALWAYS_ON, 17 TRIAL, 115 UNCLASSIFIED. Brands Nada Protein, Hayatna, Dunkin were also flagged for phase-out by CS but `lifecycle_archetype` is the wrong axis — phase-out belongs in `portfolio_strategy.md §6` alongside 7days, Sabahoo, YoPro, or in a future `boonz_products.phase_out_bias` column. Tracked as a separate followup; left as UNCLASSIFIED for now.

**Rollback:**
```sql
UPDATE public.boonz_products SET lifecycle_archetype = 'UNCLASSIFIED'
 WHERE boonz_product_name IN ('Pepsi - Regular','Perrier - Regular','SF Pancake - Chocolate Cream');
UPDATE public.boonz_products SET lifecycle_archetype = 'UNCLASSIFIED'
 WHERE product_brand IN ('Healthy Cola','Fade Fit','Fade Fit Balade');
```

---

## 2026-05-05 — Optimizer Brain Phase A foundations: lifecycle_archetype + at-risk + absorption views
**Phase / Article:** A.5 / Constitution Articles 2, 6, 12, 14
**Applied to:** prod
**Migration name:** `phaseA_optimizer_foundations`, `phaseA_optimizer_foundations_fix_urgency_bucket`

**Summary:** First migration of the Optimizer Brain build (Engine 2 — Rotation Planner per the Bible). Phase A is read-only intelligence; no new write paths. Three pieces landed: (1) `boonz_products.lifecycle_archetype text NOT NULL DEFAULT 'UNCLASSIFIED'` with CHECK enum (HYPE | ALWAYS_ON | SEASONAL | TRIAL | UNCLASSIFIED) and a partial index excluding the default value. The bootstrap UPDATE auto-tagged the catalog using product lifetime and velocity per CS rule (≥30d in catalog AND velocity > 0 → ALWAYS_ON; <30d → TRIAL; else UNCLASSIFIED) — final distribution 144 ALWAYS_ON / 4 TRIAL / 131 UNCLASSIFIED, with HYPE and SEASONAL reserved for future manual promotion. (2) `v_warehouse_at_risk` view exposes warehouse stock × expiration × full Engine 1 (`product_lifecycle_global`) signal context, with an `urgency_bucket` column (expired / urgent_0_7d / soon_7_30d / medium_30_60d / long_60_90d / safe_90d_plus / no_expiry_set). 171 active rows. (3) `v_machine_absorption_capacity` view exposes per (machine, boonz_product) absorption profile — throughput rank, open shelf capacity, slot-level signal/score/velocity/recommendation pulled directly from `slot_lifecycle` (no parallel computation against `v_sales_history_attributed`), plus catalog-level passthrough. 8,845 rows. GRANT SELECT to `authenticated` only (Cody revision dropped `anon`). Audit attribution via `SET LOCAL app.via_rpc / app.rpc_name` so the bootstrap UPDATE is traceable. Cody review: ⚠️ Approve with revisions — all four revisions applied (anon dropped, SET LOCAL added, article header added, SSOT comment corrected). **Followup migration `phaseA_optimizer_foundations_fix_urgency_bucket` applied immediately:** the original CASE used `INTERVAL '7'` etc. without unit, which Postgres parses as 7 *seconds*. All 171 rows had landed in `safe_90d_plus`. Patched to integer arithmetic (`CURRENT_DATE + 7`); post-fix distribution reflects real expiry pressure (1 urgent_0_7d, 8 soon_7_30d, 13 medium_30_60d, 19 long_60_90d, 130 safe_90d_plus). **Phase B (next):** archetype-transition RPC + `score_machine_for_product` SECURITY DEFINER + `propose_rotation_plan` RPC + `rotation_proposals` write table. Until Phase B ships, mutations to `boonz_products.lifecycle_archetype` happen via direct SQL by CS only.

**Rollback:**
```sql
DROP VIEW IF EXISTS public.v_machine_absorption_capacity;
DROP VIEW IF EXISTS public.v_warehouse_at_risk;
DROP INDEX IF EXISTS public.idx_boonz_products_archetype_active;
ALTER TABLE public.boonz_products DROP COLUMN IF EXISTS lifecycle_archetype;
```

---

## 2026-05-05 — Repurposed-machine attribution: `machine_terminal_history` + attributed view + per-machine RPC
**Phase / Article:** A.4 / Constitution Articles 1, 2, 4, 7, 8, 12, 14
**Applied to:** prod
**Migration name:** `phaseA_a4_machine_terminal_history`, `phaseA_a4b_attributed_view_dedupe`, `phaseA_a4c_per_machine_performance_rpc`, `phaseA_a4d_vox_commercial_report_via_attributed_view`, `phaseA_a4e_vox_consumer_report_join_by_machine_id`, `phaseA_a4f_consumer_report_adyen_pending_flag`, `phaseA_a4g_vox_commercial_filter_by_machine_id`

**Summary:** New versioned-history table `machine_terminal_history` (terminal-id × machine-id × date-range) with EXCLUDE-overlap constraint, RLS, and the generic A.3 audit trigger installed. Backfilled with 9 known terminal-to-machine windows: ACTIVATE-2005 chain (LLFP_2005 Feb 13-14 → MPMCC-2005-0000-W0 Apr 23-27 → ACTIVATE-2005-0000-W0 Apr 28+), MPMCC-1054/1058 ← ACTIVATEMCC-1054/1058 Apr 28 rebrands, IFLYMCC-1024 install, ALHQ-1016 stable. New canonical writer `register_terminal_move(text, uuid, date, text, text, text)` is the only path to add new windows; validates inputs + FK + role (operator_admin or superadmin). New view `v_adyen_transactions_attributed` (with `security_invoker = true`) joins Adyen rows through the history table to expose `attributed_machine_name`, `attributed_machine_id`, `attributed_venue_group`, `attribution_source` per row. Dedupe patch (`a4b`) restricts the machines join to `status='Active'` so stale Inactive terminal claims don't double-count. New read-only RPC `get_per_machine_performance(p_date_from, p_date_to, p_venue_group, p_machine_names)` returns a JSON array per attributed-machine combining WEIMI sales (via `v_sales_history_attributed`) with Adyen settled+refunded captures, including refund-netted `adyen_net_cash_aed`. Existing `get_vox_commercial_report` patched (`a4d`) to read Adyen via the new view and split SettledBulk vs RefundedBulk so partial refunds net out of captured. **Net effect:** repurposed machines now appear as separate rows in any per-machine report (e.g. ACTIVATE-2005 has 5 days at 1,087 AED under MPMCC-2005-0000-W0 and 7 days at 1,456.85 AED under ACTIVATE-2005-0000-W0 in the Feb 1 → May 4 window, instead of 12 days collapsed into one row). Validated by Cody (⚠️ Approve with revisions — all revisions applied: real ALHQ uuid, btree_gist extension, input/role validation, security_invoker on the view, audit trigger installed, terminology corrected from "append-only audit" to "versioned history"). FE wiring of `/app/performance` Sites & Machines tab patched separately (`src/app/(app)/app/performance/page.tsx` — `machineData` keys by `sales_history.machine_mapping` instead of `machine_id`). Pending: register_terminal_move callsite from a future "Rename machine" UI, wire `get_per_machine_performance` if/when the Sites & Machines tab needs Adyen-net-cash beside revenue.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.get_per_machine_performance(date, date, text, text[]);
DROP FUNCTION IF EXISTS public.register_terminal_move(text, uuid, date, text, text, text);
DROP VIEW    IF EXISTS public.v_adyen_transactions_attributed;
DROP TRIGGER IF EXISTS trg_mth_audit ON public.machine_terminal_history;
DROP POLICY  IF EXISTS mth_authenticated_read ON public.machine_terminal_history;
DROP POLICY  IF EXISTS mth_service_all       ON public.machine_terminal_history;
DROP TABLE   IF EXISTS public.machine_terminal_history;
-- restore the prior get_vox_commercial_report from migration history.
```

---

## 2026-05-04 — Orphan dispatching cleanup RPC
**Phase / Article:** Operational hardening / Articles 1, 4, 8, 12
**Applied to:** prod
**Migration name:** `cleanup_orphan_dispatching_rpc`

**Summary:** New canonical-writer RPC `cleanup_orphan_dispatching(date, text[])` to delete orphaned `refill_dispatching` rows that have no matching plan row in `refill_plan_output`. This gap was surfaced operationally when `write_refill_plan` (RPC B) rewrote plan rows for 4 machines (MC-2004, MINDSHARE, WAVEMAKER, WPP) — the old plan's dispatching rows were left behind because `write_refill_plan` only touches the plan table. The RPC validates caller role (operator_admin, superadmin, manager), requires non-NULL `p_dispatch_date`, and JOINs through `machines` + `shelf_configurations` to match dispatching rows back to plan rows by `(plan_date, machine_id, shelf_id, action)`. Only deletes rows where `packed=false AND picked_up=false` (Article 12 — never touch packed/picked-up rows). Returns `{status, dispatch_date, machines_scoped, orphan_rows_deleted}`. Designed by Dara, reviewed by Cody (⚠️ Approve with revisions — revisions applied: role validation, NULL guard, JOIN rewrite from subquery to NOT EXISTS). First call deleted 8 orphaned swap dispatching rows across 4 machines for 2026-05-05.

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.cleanup_orphan_dispatching(date, text[]);
```

---

## 2026-05-04 — Warehouse stock reconciliation RPC + bug fixes across 3 inventory RPCs
**Phase / Article:** Operational hardening / Articles 1, 4, 5, 8
**Applied to:** prod
**Migration names:** `inventory_rpc_adjust_warehouse_stock`, `patch_adjust_warehouse_stock_update_expiry`, `fix_adjust_warehouse_stock_wh_name_col`, `fix_adjust_warehouse_stock_generated_col`, `patch_adjust_wh_stock_expiry_unchanged_check`, `fix_log_manual_refill_generated_delta`, `fix_log_manual_refill_audit_constraints`, `fix_transfer_warehouse_stock_generated_delta`

**Summary:** New canonical-writer RPC `adjust_warehouse_stock` for physical count reconciliation of warehouse inventory. Matches existing rows by `wh_inventory_id` or `(warehouse, product, expiry)`, updates stock + consumer_stock + expiration_date + batch_id + status, inserts new rows when no match found. Unchanged-check includes expiry comparison (catches expiry-only corrections like mislabeled dates). Used to reconcile WH_MCC physical counts on 2026-05-04. Also fixed `inventory_audit_log.delta` generated-column bug in all 3 existing inventory RPCs (`adjust_warehouse_stock`, `log_manual_refill`, `transfer_warehouse_stock`) — the `delta` column is GENERATED ALWAYS and cannot be explicitly INSERTed. Fixed `log_manual_refill` pod_inventory_audit_log constraint violations: `operation` must be lowercase ('insert' not 'INSERT'), `source` must be from enum ('refill' not 'manual_refill').

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.adjust_warehouse_stock(uuid, jsonb, date, text);
-- Then CREATE OR REPLACE log_manual_refill and transfer_warehouse_stock with pre-fix bodies
```

---

## 2026-05-04 — Inventory operations: 3 new RPCs (transfer, manual refill, pod adjust)
**Phase / Article:** Operational hardening / Articles 1, 4, 5, 6, 8
**Applied to:** prod
**Migration names:** `inventory_rpc_transfer_warehouse_stock`, `inventory_rpc_log_manual_refill`, `inventory_rpc_adjust_pod_inventory`

**Summary:** Three new canonical-writer RPCs to close inventory management gaps. Designed by Dara, reviewed by Cody (Articles 1, 4, 5, 6, 8 — all pass). These enable the operator to: (1) transfer stock between warehouses (WH_CENTRAL → WH_MCC/WH_MM) with FIFO batch picking and cold-storage validation; (2) retroactively log manual refills that happened outside the system (backlog cleanup), decrementing source warehouse and creating pod_inventory entries; (3) correct pod_inventory via physical count reconciliation with batch-level FIFO support. All three write full audit trails to `inventory_audit_log` and/or `pod_inventory_audit_log`. Article 6 compliance verified: none of the three RPCs touch `warehouse_inventory.status` (the propose_inactivate trigger may fire when source stock hits zero, but that only proposes — manager confirms).

**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.transfer_warehouse_stock(uuid, uuid, jsonb, date, text);
DROP FUNCTION IF EXISTS public.log_manual_refill(text, uuid, date, jsonb, text);
DROP FUNCTION IF EXISTS public.adjust_pod_inventory(text, date, jsonb, text);
```

---

## 2026-05-04 — Refill pipeline hardening: 6 RPC changes (B, E, C, D, F, A)
**Phase / Article:** Operational hardening / Articles 1, 4, 5, 8, 12
**Applied to:** prod
**Migration names:** `refill_b_scoped_write_refill_plan`, `refill_e_loud_approve_refill_plan`, `refill_c_override_refill_quantity`, `refill_d_inject_swap`, `refill_f_seed_shelf_configurations`, `refill_a_multi_machine_generate`

**Summary:** Six coordinated RPC changes designed by Dara, reviewed by Cody (Articles 1, 2, 4, 5, 7, 8, 12, 14 — all pass), to eliminate the need for manual SQL in the refill pipeline. The operator (Claude / boonz-master skill) now works exclusively through RPCs for all plan mutations.

1. **RPC B — `write_refill_plan` scoped delete.** The DELETE now only removes pending rows for machines present in `p_lines` (was: all pending for date). Fixes the "sequential per-machine calls destroy each other" bug. Returns `machines_affected` array.

2. **RPC E — `approve_refill_plan` loud errors.** Pre-approve diagnostics detect missing `shelf_configurations`, unmatched `pod_products`/`boonz_products`, unmatched `machine_name`. Returns structured `alerts` jsonb array with impact descriptions. Dispatch gap detection: warns when `rows_approved > dispatching_rows_written`. Added `AND packed=false` guard to dispatching DELETE (never wipe packed rows).

3. **RPC C — `override_refill_quantity` (NEW).** Operator quantity override for pending REFILL/ADD NEW rows. Multi-variant products: proportional redistribution. Single-variant: direct update. Appends `[QTY OVERRIDE]` comment for audit trail.

4. **RPC D — `inject_swap` (NEW).** Inject a product swap into a live/approved plan. Inserts REMOVE + ADD NEW rows directly as `approved` + creates dispatching rows. Preserves packed dispatching rows. Full input validation: machine, shelf_config, pod_product, boonz_product existence checks with descriptive errors.

5. **RPC F — `seed_shelf_configurations` (NEW).** Auto-seed `shelf_configurations` from `v_live_shelf_stock`. Converts aisle codes (`0-A00`→`A01`, `1-A00`→`B01`). Idempotent via `ON CONFLICT (machine_id, shelf_code) DO NOTHING`. Called automatically by `auto_generate_refill_plan` when a machine has 0 configs.

6. **RPC A — `auto_generate_refill_plan` multi-machine.** New `p_machines text[]` parameter. When provided: bypasses health triage filter + LIMIT 10, processes exactly the listed machines. Auto-calls `seed_shelf_configurations` for machines with 0 configs. Added `AND packed=false` to dispatching DELETE. Old 3-param overload dropped.

**Cody review:** ⚠️ Approve with revisions. All revisions applied: alerts are warnings not blockers (E), packed rows preserved (D/E/A), idempotent ON CONFLICT (F), role validation on all new RPCs (C/D/F). Constitution articles satisfied: 1 (each RPC is canonical for its operation type), 4 (GUCs + role + input validation), 5 (status transitions respected), 8 (audit trigger fires on all targets), 12 (forward-only CREATE OR REPLACE).

**Verification:**
- All 6 functions confirmed: `prosecdef=true`, `has_via_rpc=true`, `has_rpc_name=true`.
- `auto_generate_refill_plan` has exactly one overload (4 params).
- Old 3-param overload dropped cleanly.

**Rollback:**
```sql
-- Reverse in opposite order
DROP FUNCTION IF EXISTS public.auto_generate_refill_plan(text, date, boolean, text[]);
-- Then CREATE OR REPLACE with old 3-param body (archived in this changelog git history)
DROP FUNCTION IF EXISTS public.seed_shelf_configurations(text);
DROP FUNCTION IF EXISTS public.inject_swap(date, text, text, text, text, text, int, text);
DROP FUNCTION IF EXISTS public.override_refill_quantity(date, text, text, int);
-- Then CREATE OR REPLACE approve_refill_plan + write_refill_plan with pre-B/E bodies
```

---

## 2026-05-04 — Refill app issues Phase 1: propose-then-confirm + canonical pickup
**Phase / Article:** Operational fix bundle / Articles 1, 2, 3, 4, 5, 6 (revised), 7, 8, 9, 12
**Applied to:** prod (additive only — no live-flow behavior change today)
**Migration names:** `m1_warehouse_inventory_status_proposal_table`, `m2_confirm_reject_warehouse_status_proposal_rpcs`, `m3_propose_status_change_functions_unbound`, `m4_mark_picked_up_rpc`, `m5_diagnostic_views`

**Summary:** First wave of fixes for the 12 refill-app issues + Issue #13 (orphan dispatch machine names). All migrations today are strictly additive — they introduce new tables, functions, and views, but do NOT alter behavior of any existing pack/receive/dispatch flow. CS guardrail in effect: "do not alter or touch anything in the existing packing and dispatching of today; fix the issues and stress test along the way."

1. **`warehouse_inventory_status_proposal` table (M1)** — Implements the propose-then-confirm pattern for `warehouse_inventory.status` mutations (Article 6 revised, see Amendment 002). Automated flows (triggers / RPCs / cron / n8n) write proposal rows here. The warehouse manager confirms or rejects via canonical RPCs. RLS: read for warehouse + admin roles, INSERT/UPDATE/DELETE blocked from authenticated. Universal audit trigger bound (Article 8).

2. **`confirm_warehouse_status_proposal` + `reject_warehouse_status_proposal` RPCs (M2)** — Canonical write paths for the manager's confirm/reject decision. SECURITY DEFINER, validate role + inputs, set `app.via_rpc`, return JSON. Confirm path atomically flips `warehouse_inventory.status` and marks proposal `confirmed`. Drift detection: if `warehouse_inventory.status` changed since the proposal was filed, marks proposal `superseded` instead of confirming.

3. **`propose_inactivate_on_zero_stock` + `propose_reactivate_on_stock_return` trigger functions (M3)** — Body created today, **NOT BOUND** to `warehouse_inventory`. Binding deferred to tonight's post-dispatch deploy (m3b) so today's pack/receive flow is untouched. Both functions write to the proposal table only; never UPDATE `warehouse_inventory.status` directly. Idempotency guard skips duplicate pending proposals.

4. **`mark_picked_up(uuid[])` RPC (M4)** — Canonical write path for the field-driver pickup flow. Replaces direct `refill_dispatching` UPDATEs from `field/pickup/page.tsx`. Filters to `packed=true AND picked_up=false`; returns counts + skipped IDs for FE feedback. Sits dormant until tonight's FE deploy wires it.

5. **Diagnostic views (M5)** — `v_pending_status_proposals` (manager UI surface), `v_orphan_dispatch_machine_names` (Issue #13: refill_plan_output rows whose machine_name doesn't resolve to `machines.official_name` — currently 4 rows: MPMCC-2005-0000-L0, ACTIVATEMCC-1058-0000-R0, ACTIVATEMCC_1054_0000_M0 (typo), JET-2001-3000-O1), `v_machines_without_shelf_config` (currently 2 rows: IRIS, LLFP — both `include_in_refill=false`, benign).

**Constitution amendment (002):** Article 6 revised. The previous absolute rule ("`warehouse_inventory.status` may only be written by the warehouse manager — no trigger / function / cron / n8n / app may mutate it") is replaced with a propose-then-confirm rule that allows automated flows to PROPOSE status changes via the new proposal table, with manager confirmation as the gate. Silent direct UPDATE of `warehouse_inventory.status` from any trigger / RPC / cron / n8n / FE remains forbidden. See `06_amendment_002_article_6_propose_then_confirm.md`.

**Today-safe verification:**
- `warehouse_inventory` triggers unchanged (no new mutation triggers; lockdown holds).
- `refill_dispatching` triggers unchanged (`enforce_packed_dispatch_immutability`, `tg_audit_refill_dispatching`, `trg_conserve_split_qty`, `trg_prevent_duplicate_unstarted_dispatch` all intact).
- No FE deploy required to apply these migrations. RPCs sit dormant until tonight's FE deploy.

**Rollback:**
```sql
-- M5
DROP VIEW IF EXISTS public.v_machines_without_shelf_config;
DROP VIEW IF EXISTS public.v_orphan_dispatch_machine_names;
DROP VIEW IF EXISTS public.v_pending_status_proposals;
-- M4
DROP FUNCTION IF EXISTS public.mark_picked_up(uuid[]);
-- M3
DROP FUNCTION IF EXISTS public.propose_reactivate_on_stock_return();
DROP FUNCTION IF EXISTS public.propose_inactivate_on_zero_stock();
-- M2
DROP FUNCTION IF EXISTS public.reject_warehouse_status_proposal(uuid, text);
DROP FUNCTION IF EXISTS public.confirm_warehouse_status_proposal(uuid, text);
-- M1
DROP TABLE IF EXISTS public.warehouse_inventory_status_proposal;
```

**Pending tonight (post-dispatch deploy window):** m3b (bind triggers), FE updates to (a) wire `mark_picked_up`, (b) add `picked_up=false` filter in pickup page, (c) surface `v_pending_status_proposals` in the inventory page; conserve_split trigger swap; backfills.

---

## 2026-04-30 — Boonz Master operational intelligence layer
**Phase / Article:** Operational / Articles 1, 2, 3, 4, 5, 8, 12
**Applied to:** prod + repo
**Migration names:** `boonz_master_foundation`, `add_approve_refill_plan_rpc`

**Summary:** Introduced the Boonz Master skill as the single operational interface for the refill system, replacing the need for CS to route between `/refill-engine`, Cody, Stax, and Dara for day-to-day ops. Four changes shipped:

1. **`boonz_context` table** — Active operational brief. One row at a time. Master writes here when CS sets context ("NOVO promo next 2 weeks", "push office to aggressive"). The refill-engine reads this before generating any plan. Holds `context_text` (plain English), `default_scenario` (conservative/standard/aggressive), `scenario_overrides` per venue group, and `machine_modes` per machine.

2. **`planned_swaps` table** — Confirmed next-visit swap orders from operator, CS, or driver (phone call, chat, field note). Brain executes these unconditionally on next run, bypassing lifecycle signal checks. Status lifecycle: pending → applied | cancelled.

3. **`machine_field_notes` table** — Driver feedback loop. Post-dispatch prompt in field app creates a note (add_more, reduce, substitute, remove, general). Brain reads and applies on next plan run, marks as applied after.

4. **`product_mapping.mix_weight` column** — Controls how refill qty splits across variants of the same pod product. Default 1.0 = equal share. "More M&M than Mars" → update M&M weight to 1.5, Mars stays 1.0 → 60/40 split from next run.

5. **`approve_refill_plan(date, text[])` RPC** — New canonical approval gate. Replaces the missing approval step in the refill flow. Flips `operator_status` pending→approved, then writes `refill_dispatching` rows in one atomic call. FE "Approve & Dispatch" button calls this. Roles: operator_admin, superadmin, manager only.

6. **FE changes** — `RefillPlanningTab` plan state lifted to `page.tsx` parent (tab-wipe bug fixed). "Write plan" renamed to "Save draft". "Approve & Dispatch" button added (calls `approve_refill_plan` RPC). Two-step flow: save draft → review → approve.

7. **Boonz Master skill** — New `boonz-master` skill installed. Single ops interface. Interprets plain English instructions, writes to the new tables, invokes refill-engine with context applied. Replaces `/refill-engine` for daily ops.

8. **6am Dubai scheduled run** — `boonz-morning-refill` scheduled task created. Runs at 06:05 Dubai time daily. Reads `boonz_context` + pending swaps + field notes, generates tomorrow's plan for all critical/warning machines, posts morning brief with link to approve.

9. **`refill-engine` v4** — Updated SKILL.md. New CONTEXT CHECK step runs before PRE-FLIGHT: reads `boonz_context`, `planned_swaps`, `machine_field_notes`. Applies scenario mapping, machine_modes, planned swaps, field note adjustments to the plan.

**Rollback:**
```sql
-- boonz_master_foundation
DROP TABLE IF EXISTS public.machine_field_notes;
DROP TABLE IF EXISTS public.planned_swaps;
DROP TABLE IF EXISTS public.boonz_context;
ALTER TABLE public.product_mapping DROP COLUMN IF EXISTS mix_weight;
-- add_approve_refill_plan_rpc
DROP FUNCTION IF EXISTS public.approve_refill_plan(date, text[]);
```
FE rollback: revert `page.tsx` and `RefillPlanningTab.tsx` to previous state via git.

---

## 2026-04-27 (v2) — Supplier consolidation + driver task filtering + not-purchased + audit trail
**Phase / Article:** Post-fix procurement v2 / Articles 1, 4, 6
**Applied to:** prod + repo
**Migration names:** `procurement_supplier_consolidation`, `procurement_outcome_and_audit_schema`, `procurement_rpcs_v2`
**Summary:** (1) Merged Union Coop SUP_014 → SUP_005 (canonical "Union Coop"). Reclassified Arab Sweet + Merich as walk_in. Cleared bogus contact_email='na' on Carrefour. (2) create_purchase_order v2: driver task only for walk_in OR p_force_driver_task=true. FE adds emergency "🚨 pick-up" checkbox for supplier_delivered. Tasks page filters to walk_in + forced only. (3) Not-purchased: purchase_orders.purchase_outcome column. WH toggles lines as not_purchased in receiving page; RPC closes them with received_qty=0. Driver hints (outcome_comment parsed) surfaced in receiving UI — auto-marks not_available lines, shows partial qty. (4) Procurement audit log: procurement_events append-only table + driver_tasks trigger for status transitions. RPCs log po_created / goods_received / line_not_purchased. 10 historical events backfilled.
**Rollback:** Re-activate SUP_014, revert Arab Sweet + Merich procurement_type. p_force_driver_task defaults false — RPC change is backward-compatible. purchase_outcome is additive + nullable.

---

## 2026-04-27 — Procurement flow overhaul: B-1 → B-6 fixes + 2 new canonical writers
**Phase / Article:** Post-A.5 procurement fix / Constitution Articles 1, 3, 4, 6
**Applied to:** prod + repo
**Migration names:** `procurement_supplier_type_column`, `procurement_po_number_sequence`, `create_purchase_order_rpc`, `receive_purchase_order_rpc`, `tighten_warehouse_inventory_rls`
**Summary:** Full procurement flow investigation identified 6 active bugs and 2 feature gaps. Applied in one session: (1) B-1 — added `suppliers.procurement_type` column to replace hardcoded `WALK_IN_SUPPLIER_CODES = ["SUP_005","SUP_011"]` constant in FE; backfilled SUP_005/011/014 as `walk_in`; Union Coop (SUP_014) was silently missing, causing wrong confirm dialog and null email attempts. (2) B-2 — receiving page was inserting extra `purchase_orders` rows for each expiry batch, inflating `line_count` and `total_ordered` in every order view; fixed by moving receipt logic to the `receive_purchase_order` RPC which only UPDATEs the original line and creates separate `warehouse_inventory` rows per batch. (3) B-3 — `warehouse_inventory` was being written directly from the browser client by `field_staff` role; moved to `receive_purchase_order` SECURITY DEFINER RPC and tightened RLS to remove `field_staff` from write policy. (4) B-4 — `po_additions` (field-added items) were shown on the receiving page but never processed by the confirm action; RPC now accepts `p_additions` array and marks each addition received + creates `warehouse_inventory` row. (5) B-5 — `po_number` was generated client-side via max+1 query (race condition); replaced with `po_number_seq` Postgres sequence, assigned inside `create_purchase_order` RPC via `nextval()`. (6) B-6 — orders list now cross-references `driver_tasks` by `po_id` to show "In transit — awaiting WH receipt" when a driver has collected a PO but WH has not yet received it. Two new canonical writers registered in `RPC_REGISTRY.md`: `create_purchase_order` and `receive_purchase_order`.
**Rollback:** To revert the RLS tightening: `DROP POLICY warehouse_write_wh_inventory ON warehouse_inventory; CREATE POLICY warehouse_write_wh_inventory ON warehouse_inventory FOR ALL TO public USING (EXISTS (SELECT 1 FROM user_profiles WHERE id=(SELECT auth.uid()) AND role=ANY(ARRAY['field_staff','warehouse','operator_admin','superadmin','manager'])));`. FE rollback: revert the three modified files to the versions before this session. The RPCs and sequence are additive and safe to leave in place even if FE is rolled back.

---

## 2026-04-26 — A.6.0 incident filed: 4 non-canonical write paths into protected tables
**Phase / Article:** A.6.0 / Constitution Article 1 (canonical write paths) — drift surfaced by A.5b smoke test
**Applied to:** repo (incident report only — no migration applied)
**Migration name:** —
**Summary:** Post-A.5b investigation of one anomalous `via_rpc=false` audit row on `machines` widened into a full sweep that revealed four distinct non-canonical write paths active in prod over the last 24 hours. The largest by volume: `refill_plan_output` saw 180 direct INSERT/DELETE/UPDATE writes (n8n service_role + FE operator_admin), zero of which went through the canonical `write_refill_plan` RPC despite the RPC being correctly patched in A.5b. Three smaller findings: a `machines` repurpose-shape UPDATE done directly against PostgREST (Article 1 violation), a coordinated 4-row `boonz_product_id` remap that was a legitimate data-correction migration but lacked an audit-trail marker row (process gap), and an n8n flow doing pointless `updated_at` heartbeats on `machines`. **A.5b is correct as shipped** — the 24 canonical writers are constitutional. What surfaced is a Phase B FE/n8n migration gap: the canonical writers exist and work but the production traffic doesn't go through them yet. Full evidence, audit_ids, repro queries, and a 10-step remediation sequence (B.x.3 → B.x.1 → B.x.2 → B.x.4 → A.6, with Cody review gates) live in `INCIDENT_2026-04-26_NON_CANONICAL_WRITES.md`. Pulls A.6 (governance YAML in warn mode) priority forward.
**Rollback:** N/A (no migration applied — investigation + sequencing artifact only).

---

## 2026-04-26 — A.5b applied: patch remaining 24 canonical writers + RLS on `refill_dispatch_plan`
**Phase / Article:** A.5b / Constitution Article 1 (canonical path) + Article 2 (RLS) + Article 4 (validation/via_rpc) + Article 8 (universal audit)
**Applied to:** prod
**Migration names:** `phaseA_a5b_part1_of_4_canonical_writers`, `phaseA_a5b_part2_of_4_canonical_writers`, `phaseA_a5b_part3_of_4_canonical_writers`, `phaseA_a5b_part4_of_4_rls_refill_dispatch_plan` (split into 4 because the combined diff exceeds Supabase's per-migration size limit)

**Summary:** Closes the A.5 perimeter. Patches the 24 remaining canonical SECURITY DEFINER writers and closes the one real RLS gap surfaced by Amendment 001.

**Change 1 — 22 plpgsql writers patched (parts 1–3):**
`add_new_machine`, `add_sanity_increment`, `auto_decrement_pod_inventory`, `auto_sanity_check`, `backfill_dispatch_boonz_product_ids`, `load_pod_staging_chunk`, `pack_dispatch_line`, `process_adyen_staging`, `process_weimi_staging`, `push_plan_to_dispatch`, `receive_all_dispatches_for_machine`, `receive_dispatch_line`, `repurpose_machine`, `return_all_dispatches_for_machine`, `return_dispatch_line`, `toggle_machine_refill`, `upsert_aisle_snapshot`, `upsert_pod_snapshot`, `upsert_refill_stock_snapshot`, `upsert_sales_lines`, `write_dispatch_plan`, `write_refill_plan`. Each now starts its `BEGIN` block with `PERFORM set_config('app.via_rpc', 'true', true); PERFORM set_config('app.rpc_name', '<fn>', true);` so the A.4 generic audit trigger captures `via_rpc=true, rpc_name=<fn>` on every protected-entity row. Where missing (13 of 24), folded in `SET search_path TO 'public'` at function level (defensive Article 4 hardening — built-in param, function-level SET is allowed).

**Change 2 — 2 SQL-language writers converted to plpgsql:**
`refresh_product_scores` and `retry_staging_errors` were SQL-language; they couldn't use `PERFORM`, so they were re-authored as plpgsql while preserving exact behaviour. `refresh_product_scores` additionally writes its own explicit `INSERT INTO write_audit_log` row before `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_global_product_scores;` — matview refreshes don't fire AFTER triggers, so the audit row is written manually (mirrors A.5a's `refresh_sales_aggregated`).

**Change 3 — RLS on `refill_dispatch_plan` (part 4):**
`ALTER TABLE refill_dispatch_plan ENABLE ROW LEVEL SECURITY` + `CREATE POLICY refill_dispatch_plan_select FOR SELECT TO authenticated USING (true)`. No INSERT/UPDATE/DELETE policy — default-deny for anon/authenticated. service_role bypasses RLS, which is how canonical RPC writes still reach the table. Closes Amendment 001's only real RLS gap.

**Why PERFORM set_config in body, not function-level SET:**
Cody's review recommended function-level `SET app.via_rpc='true'` (atomic save/restore on entry/exit, no SET LOCAL leak). Supabase rejected that shape with `42501: permission denied to set parameter "app.via_rpc"` because custom GUCs (any param with a dot) must be pre-registered via `ALTER DATABASE/ROLE/SYSTEM SET app.via_rpc=''` to be accepted in a function-level SET clause, and the migration role lacks that grant. Pivot: stay with the A.5a precedent — `PERFORM set_config(...)` at the top of `BEGIN`. **Audited the 4 nested-DEFINER call sites** (`auto_sanity_check→add_sanity_increment`, `receive_all_dispatches_for_machine→receive_dispatch_line`, `return_all_dispatches_for_machine→return_dispatch_line`, `upsert_sales_lines→refresh_sales_aggregated`) and confirmed none write to a protected entity AFTER the inner call returns — they either return immediately or update a non-protected table (`daily_pipeline_runs`). So the SET LOCAL leak from PERFORM does not corrupt the audit trail in any current code path.

**Verification:**
- All 24 functions confirmed `prosecdef=true`, `proconfig` includes `search_path=public`, body contains both `PERFORM set_config` calls.
- Smoke 1: ran `toggle_machine_refill('ADDMIND-1007-0000-W0', !current); toggle_machine_refill(..., current);` — two new `write_audit_log` rows landed with `via_rpc=true, rpc_name='toggle_machine_refill'`.
- Smoke 2: ran `refresh_product_scores();` — one row landed with `table_name='mv_global_product_scores', operation='REFRESH', via_rpc=true, rpc_name='refresh_product_scores', payload={kind: matview_refresh, trigger: manual_or_cron}`.
- Security advisors run post-apply: zero new findings on `refill_dispatch_plan`; no patched function appears in the `function_search_path_mutable` list (the 35 remaining are pre-existing helpers/triggers/read-only RPCs out of A.5b scope).

**Open follow-ups (not blockers):**
- **A.5c**: re-author all 25 A.5a/A.5b writers to function-level `SET app.via_rpc='true'` once `app.via_rpc` is pre-registered at db level (requires a separate `ALTER DATABASE postgres SET app.via_rpc=''` migration as superuser, then rewriting the bodies). This eliminates the SET LOCAL leak entirely and matches Cody's preferred shape.
- **B.x**: tighten `refill_plan_output` RLS — currently allows authenticated INSERT/UPDATE which violates Article 1/3 (sole canonical writer is `write_refill_plan`).
- **A.4.b**: install audit triggers on the 6 deferred protected tables once Amendment 001 lands.
- **Investigate** (RESOLVED → see `INCIDENT_2026-04-26_NON_CANONICAL_WRITES.md`): the `machines` audit row at 2026-04-26 06:06:03 UTC was the visible tip of four distinct non-canonical write paths into protected tables. Most material: zero `write_refill_plan` calls in 24h despite 180 direct INSERT/DELETE/UPDATE writes against `refill_plan_output`. A.5b is correct as shipped — what surfaced is a Phase B FE/n8n migration gap, now sequenced as B.x.1–B.x.4 in the incident doc.

**Rollback:**
```sql
-- Function bodies: pre-A.5b versions are archived in pg_proc history and in
-- /sessions/gracious-compassionate-noether/a5b_rows.json. To roll any one
-- back, CREATE OR REPLACE FUNCTION with the prior body.
-- RLS on refill_dispatch_plan:
ALTER TABLE public.refill_dispatch_plan DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS refill_dispatch_plan_select ON public.refill_dispatch_plan;
```

---

## 2026-04-26 — Data correction: merge Santiveri Cranberries → Cran Berry + Article 7 RLS on inventory_audit_log
**Phase / Article:** Data correction / Constitution Article 7 (audit log append-only), Article 6 (warehouse_inventory.status untouched), Appendix A (boonz_products + product_mapping: intentionally permissive)
**Applied to:** prod
**Migration names:** `data_merge_cranberries_into_cran_berry`, `rls_inventory_audit_log_append_only`
**Summary:** Two `boonz_products` rows represented the same physical SKU — "Santiveri - Cran Berry" (`cd5fd194`) and "Santiveri - Cranberries" (`19c2983f`). Migration 1 removed the duplicate by: (a) deleting 24 redundant `product_mapping` rows and 5 `product_pricing` rows where Cran Berry already had identical entries; (b) remapping `boonz_product_id` FK on `purchase_orders` (1), `weekly_procurement_plan` (10), `refill_dispatching` (25), `warehouse_inventory` (1), `pod_inventory` (3); (c) correcting 4 rows in `inventory_audit_log` (same physical product, data correction not historical falsification); (d) deleting the orphaned `boonz_products` row. Orphan check confirmed 0 remaining references. Migration 2 applied INSERT-only RLS to `inventory_audit_log` per the Article 7 `*_audit_log` wildcard — closing the gap that made the correction migration possible in the first place.
**Rollback:** Re-insert `boonz_products` row `19c2983f`, re-point all FK columns back. No schema changes to reverse for migration 2 (ADD POLICY is forward-only; to revert, DROP POLICies and DISABLE RLS).

---

## 2026-04-26 — A.5a follow-up applied: widen `write_audit_log.operation` CHECK
**Phase / Article:** A.5a.1 / Constitution Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a5a_followup_allow_refresh_op`
**Summary:** End-to-end smoke of A.5a's `refresh_sales_aggregated()` failed with `23514: violates check constraint "write_audit_log_operation_check"` — the column's CHECK was authored in A.3 with the value set `{'INSERT','UPDATE','DELETE'}`. The patched `refresh_sales_aggregated()` records `operation='REFRESH'` for matview refreshes (the only reasonable verb — REFRESH is conceptually an UPDATE on the entire matview but not on any single row). Forward-only fix: dropped the existing CHECK and re-added it with `{'INSERT','UPDATE','DELETE','REFRESH'}`. Pure additive widening — every prior row remains valid; no behavior regression; no RLS change. Cody auto-approve path (constraint-widening, no surface change).
**Verification:** Re-ran `SELECT public.refresh_sales_aggregated();` — succeeded; one row landed in `write_audit_log` with `operation='REFRESH'`, `via_rpc=true`, `rpc_name='refresh_sales_aggregated'`, `payload->>'kind'='matview_refresh'`.
**Rollback:**
```sql
ALTER TABLE public.write_audit_log
  DROP CONSTRAINT write_audit_log_operation_check;
ALTER TABLE public.write_audit_log
  ADD CONSTRAINT write_audit_log_operation_check
  CHECK (operation = ANY (ARRAY['INSERT','UPDATE','DELETE']));
-- Note: cannot roll back if any rows with operation='REFRESH' exist.
-- Inspect first: SELECT count(*) FROM public.write_audit_log WHERE operation='REFRESH';
```

---

## 2026-04-26 — A.5a applied: patch `upsert_daily_sales` + split matview refresh
**Phase / Article:** A.5a / Constitution Article 1 (canonical path) + Article 4 (validation/via_rpc) + Article 8 (universal audit) + Article 9 (heavy work on its own surface) + Article 11 (cron via RPC) + Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a5a_patch_upsert_daily_sales_and_split_matview`
**Summary:** First batch of A.5 — patches the writer that triggered this entire diagnostic session (the n8n `Supabase Upsert1` gateway timeout on 2026-04-25). Three coordinated changes shipped together.

**Change 1 — `upsert_daily_sales(p_items jsonb)` body:**
- Added `PERFORM set_config('app.via_rpc',  'true', true)` at the top of `BEGIN`. `is_local=true` scopes the GUC to the current transaction (no leak across pooled n8n connections).
- Added `PERFORM set_config('app.rpc_name', 'upsert_daily_sales', true)` for the audit-log `rpc_name` field.
- Removed the synchronous `PERFORM refresh_sales_aggregated();` at the end (the line that was causing the gateway timeout).
- Updated COMMENT to record A.5a context.
- All other behavior preserved verbatim: `SECURITY DEFINER`, `search_path=public`, `TimeZone=Asia/Dubai`, `resolve_machine_id` lookup, defensive timestamp parse, total_amount fallback chain, `ON CONFLICT (internal_txn_sn) DO UPDATE` rules, per-item `EXCEPTION WHEN OTHERS` envelope, jsonb summary return shape.

**Change 2 — `refresh_sales_aggregated()` body:**
- Added the same two `set_config` GUC tags so the cron-triggered refresh is audit-traceable.
- Inserted an explicit row into `public.write_audit_log` before the `REFRESH MATERIALIZED VIEW CONCURRENTLY`. This is required by Article 8 because matviews cannot carry AFTER triggers, so the writer must record itself. Required Cody Change 3 in the review.
- Pinned `search_path TO 'public'` (defensive; the previous version inherited the calling session's path).
- Updated COMMENT.

**Change 3 — pg_cron schedule:**
- New cron job `refresh-sales-aggregated-10min` runs `*/10 * * * *` calling `SELECT public.refresh_sales_aggregated();`.
- The `DO $cron$` block first `cron.unschedule`s any prior version of the same job, then `cron.schedule`s — making the migration idempotent / replay-safe.
- Cadence rationale: 10 min keeps `sales_history_aggregated` fresh enough for ops dashboards (refill-engine, partner-performance) which already tolerate hour-old aggregates; cheap enough for a ~15K-row matview with `CONCURRENTLY` refresh.

**Constitutional impact:**
- Article 1 ✅ — `upsert_daily_sales` remains the sole writer for `sales_history`.
- Article 4 ✅ — GUC tags now declared. Input validation via `EXCEPTION WHEN OTHERS` envelope (per-item; preserves partial-success semantics for the n8n batch).
- Article 8 ✅ — every `sales_history` write now lands in `write_audit_log` with `via_rpc=true, rpc_name='upsert_daily_sales'`. Every matview refresh lands with `via_rpc=true, rpc_name='refresh_sales_aggregated'`.
- Article 9 ✅ — heavy work (matview refresh) is now on its own surface (cron), separated from the synchronous writer.
- Article 11 ✅ — cron job calls an RPC, not raw DDL/DML.
- Article 12 ✅ — `CREATE OR REPLACE FUNCTION` is forward-only; cron block is idempotent.

**Phase B note (deferred, not done in A.5a):** `upsert_daily_sales` still has `EXECUTE` granted to `PUBLIC` (`=X/postgres` ACL entry). Phase B will tighten to `service_role` only — n8n already auths as service_role. Don't ship this now (would be an unrelated behavior change).

**Verification:**
- `pg_get_functiondef(upsert_daily_sales)` confirms both `set_config` calls present and `refresh_sales_aggregated()` call removed.
- `pg_get_functiondef(refresh_sales_aggregated)` confirms both `set_config` calls present and the explicit `INSERT INTO public.write_audit_log` line.
- `cron.job` shows `refresh-sales-aggregated-10min` active with schedule `*/10 * * * *`.
- End-to-end smoke (replay-an-existing-row pattern):
  - `SELECT public.upsert_daily_sales('[{...one existing internal_txn_sn replayed...}]'::jsonb)` returned `{"status":"ok","upserted":1,"skipped":0,"total":1}`.
  - `write_audit_log` row appeared: `table=sales_history, op=UPDATE, via_rpc=true, rpc_name='upsert_daily_sales'`.
  - `SELECT public.refresh_sales_aggregated();` succeeded after the follow-up CHECK widening (see A.5a.1 entry above).
  - `write_audit_log` row appeared: `table=sales_history_aggregated, op=REFRESH, via_rpc=true, rpc_name='refresh_sales_aggregated', payload={kind: matview_refresh, trigger: cron}`.
- Bypass-detector still works: pre-existing `machines` audit row from A.4 smoke still shows `via_rpc=false` — proves the index `idx_wal_via_rpc` will surface unpatched canonical paths until A.5b+ closes them.

**Operational impact:**
- The 23:59 n8n flow that fired this whole diagnostic is now safe — the synchronous matview refresh that caused the gateway timeout is gone. Worst case, the n8n upsert returns immediately with the per-item summary, and the matview catches up within ≤10 minutes.
- The matview refresh now happens 144x/day (every 10 min) vs ~3-5x/day previously. The marginal cost is small — `REFRESH MATERIALIZED VIEW CONCURRENTLY` is incremental relative to the previous full refresh.

**Rollback:**
```sql
-- 1. Restore upsert_daily_sales pre-A.5a body (without GUC tags, with inline matview refresh).
--    Body archived in this CHANGELOG file's git history at HEAD~1.
--    Re-apply via CREATE OR REPLACE FUNCTION.

-- 2. Restore refresh_sales_aggregated pre-A.5a body:
CREATE OR REPLACE FUNCTION public.refresh_sales_aggregated()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY sales_history_aggregated;
END;
$$;

-- 3. Drop the cron job:
SELECT cron.unschedule('refresh-sales-aggregated-10min');
```
(Rollback is destructive of the audit-tagging behavior. Prefer forward-fix via a new migration unless a critical regression is observed.)

---

## 2026-04-26 — A.4 applied: install audit triggers on 10 protected tables
**Phase / Article:** A.4 / Constitution Article 1 (canonical write paths) + Article 8 (universal audit) + Article 15 (Appendix A reconciliation flagged)
**Applied to:** prod
**Migration name:** `phaseA_a4_install_audit_triggers`
**Summary:** Installed the generic `audit_log_write(pk_col)` AFTER trigger from A.3 onto every protected table where the Constitution name unambiguously matches a live `public.*` table. The trigger fires on INSERT, UPDATE, and DELETE for all 10 tables and writes one row to `public.write_audit_log` per affected row, capturing `table_name`, `operation`, `row_pk` (extracted via `TG_ARGV[0]`), `actor`, `actor_role`, `via_rpc` (false until A.5 patches the canonical writers), `rpc_name`, `occurred_at`, and a full `old`/`new` jsonb payload. Idempotent (DROP IF EXISTS guards before each CREATE), so the migration is replay-safe. Updated the `audit_log_write()` function COMMENT to record installation date. The 10 tables and their PK columns:

| # | Table | PK column injected | Trigger name |
|---|---|---|---|
| 1 | `machines` | `machine_id` | `tg_audit_machines` |
| 2 | `shelf_configurations` | `shelf_id` | `tg_audit_shelf_configurations` |
| 3 | `planogram` | `planogram_id` | `tg_audit_planogram` |
| 4 | `sim_cards` | `sim_id` | `tg_audit_sim_cards` |
| 5 | `slot_lifecycle` | `slot_lifecycle_id` | `tg_audit_slot_lifecycle` |
| 6 | `pod_inventory` | `pod_inventory_id` | `tg_audit_pod_inventory` |
| 7 | `pod_inventory_audit_log` | `audit_id` | `tg_audit_pod_inventory_audit_log` |
| 8 | `warehouse_inventory` | `wh_inventory_id` | `tg_audit_warehouse_inventory` |
| 9 | `refill_plan_output` | `id` | `tg_audit_refill_plan_output` |
| 10 | `sales_history` | `transaction_id` | `tg_audit_sales_history` |

**Deferred to A.4.b** (pending Article 15 amendment): `sales_history_aggregated` (Constitution called it `sales_aggregated`), `refill_dispatch_plan` (called `dispatch_plan`), `refill_dispatching` (called `dispatch_lines`), `inventory_audit_log` (called `warehouse_inventory_audit_log`). The Constitution names predate the schema as it stands today, so before installing triggers we must amend Appendix A so the protected-entity list and the live schema agree.

**Removed from protected list** (via the Article 15 amendment): `slots` (does not exist in `public`; the rotation lifecycle is captured in `slot_lifecycle` which already has its trigger), and `settlements` (does not exist as a table — settlements are computed views on top of `sales_history`).

**Important pre-A.5 expectation:** Until A.5 patches the canonical writers, every row appearing in `write_audit_log` will have `via_rpc = false`. This is **not** a constitutional violation — it just means the writer didn't yet declare itself via the `app.via_rpc` GUC. A.5 fixes that, and the `idx_wal_via_rpc` partial index (created in A.3) becomes the bypass-traffic detector once the canonical paths are tagged.

**Verification:**
- All 10 triggers exist and are enabled (`pg_trigger.tgenabled = 'O'`); `pg_get_triggerdef` confirms each binds `audit_log_write` with the correct PK arg.
- Synthetic smoke: a no-op self-update on one row of `machines` produced exactly one row in `write_audit_log` with `table_name=machines`, `operation=UPDATE`, correct `row_pk`, `via_rpc=false`, `rpc_name=NULL`, and a full `payload.old` / `payload.new` snapshot. Confirms trigger fires, PK extraction works, and payload capture works end-to-end.

**Rollback:**
```sql
DROP TRIGGER IF EXISTS tg_audit_machines ON public.machines;
DROP TRIGGER IF EXISTS tg_audit_shelf_configurations ON public.shelf_configurations;
DROP TRIGGER IF EXISTS tg_audit_planogram ON public.planogram;
DROP TRIGGER IF EXISTS tg_audit_sim_cards ON public.sim_cards;
DROP TRIGGER IF EXISTS tg_audit_slot_lifecycle ON public.slot_lifecycle;
DROP TRIGGER IF EXISTS tg_audit_pod_inventory ON public.pod_inventory;
DROP TRIGGER IF EXISTS tg_audit_pod_inventory_audit_log ON public.pod_inventory_audit_log;
DROP TRIGGER IF EXISTS tg_audit_warehouse_inventory ON public.warehouse_inventory;
DROP TRIGGER IF EXISTS tg_audit_refill_plan_output ON public.refill_plan_output;
DROP TRIGGER IF EXISTS tg_audit_sales_history ON public.sales_history;
```
(Rollback drops only the triggers; the `audit_log_write` function and `write_audit_log` table from A.3 remain. Existing audit rows are preserved.)

---

## 2026-04-26 — A.3 applied: universal audit ledger
**Phase / Article:** A.3 / Constitution Article 7 (audit append-only) + Article 8 (universal audit) + Article 12 (forward-only)
**Applied to:** prod
**Migration name:** `phaseA_a3_audit_log_infra`
**Summary:** Built the universal write ledger that turns "what happened to my protected tables" from an unanswerable question into a SQL query. Created `public.write_audit_log` (audit_id, table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, occurred_at, payload jsonb). RLS enabled with append-only policies (SELECT/INSERT permissive for `authenticated`; UPDATE/DELETE explicitly blocked). Three supporting indexes: `(table_name, occurred_at DESC)`, `(via_rpc, occurred_at DESC) WHERE via_rpc = false` (the bypass-traffic detector), `(actor, occurred_at DESC)`. Created the generic `public.audit_log_write()` `SECURITY DEFINER` trigger function — reads `app.via_rpc` and `app.rpc_name` session GUCs, captures the PK via `TG_ARGV[0]`, records full row payload as jsonb. EXECUTE revoked from PUBLIC/anon/authenticated (callable only as a trigger). The ledger is empty until A.4 installs the trigger on each protected table.
**Verification:** Verified via Supabase MCP — `pg_class.relrowsecurity = true`. Policies: `wal_insert, wal_no_delete, wal_no_update, wal_select`. Indexes: `idx_wal_actor, idx_wal_table_occurred, idx_wal_via_rpc, write_audit_log_pkey`. Function `audit_log_write` is DEFINER. EXECUTE grants: `{postgres=X/postgres, service_role=X/postgres}` — anon and authenticated have no execute.
**Rollback:**
```sql
DROP FUNCTION IF EXISTS public.audit_log_write();
DROP TABLE IF EXISTS public.write_audit_log;
```
(Note: rollback is destructive of audit data once any rows exist. Prefer forward-fix via a new migration.)

---

## 2026-04-25 — A.2 applied: deprecate `rename_machine_in_place_legacy`
**Phase / Article:** A.2 / Constitution Article 13 (deprecation 90-day process) + Article 1 (one canonical write path)
**Applied to:** prod
**Migration name:** `phaseA_a2_deprecate_rename_machine_legacy`
**Summary:** Closed the side door on the legacy machine-rename path. The function `rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)` was previously `SECURITY DEFINER` and granted EXECUTE to `anon`, `authenticated`, and `service_role`. It is superseded by `repurpose_machine` as the canonical writer for machine identity transitions. Caller scan (code: `src/`, `engines/`, `scripts/`, `n8n/`, `boonz-data-migration/`; DB: `cron.job`, triggers, other DEFINER functions) returned **zero callers** — function is fully dormant. Applied: (1) `ALTER FUNCTION ... SECURITY INVOKER`, (2) `REVOKE EXECUTE FROM PUBLIC, anon, authenticated`, (3) updated function comment to mark deprecated and schedule DROP for 2026-07-24. `service_role` retains EXECUTE for the monitor window as an escape hatch; revoke at end of 90-day period if usage stays at zero.
**Verification:** `pg_proc.prosecdef = false` (was true). `proacl = {postgres=X/postgres,service_role=X/postgres}` (was `{postgres,anon,authenticated,service_role}`). Comment updated.
**Rollback:**
```sql
ALTER FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)
  SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text)
  TO anon, authenticated;
COMMENT ON FUNCTION public.rename_machine_in_place_legacy(uuid, text, text, text, text, boolean, date, text) IS
  'LEGACY: Older rename-in-place pattern. Same machine_id is preserved across the rename. Use only for backwards-compat with existing field PWA flows. For new identity transitions, use repurpose_machine() which atomically creates a fresh machine_id (canonical pattern as of Round 2).';
```

---

## 2026-04-25 — Architecture repository established
**Phase / Article:** Phase A scaffolding / Article 15 (PRs declare invariants)
**Applied to:** repo
**Migration name:** n/a
**Summary:** Created `boonz-erp/docs/architecture/` and seeded it with the Constitution v1.0, Phase A plan, and A1 before/after dashboard. Added this CHANGELOG, the migrations registry, and the RPC registry. Going forward, every backend change that touches a protected entity must be reflected here in addition to the SQL migration.
**Rollback:** `rm -rf boonz-erp/docs/architecture` (no DB impact).

---

## 2026-04-25 — A1 applied: RLS on `planogram` + `pod_inventory_audit_log`
**Phase / Article:** A.1 / Constitution Article 2 (RLS mandatory) + Article 7 (audit logs append-only)
**Applied to:** prod
**Migration name:** `phaseA_a1_rls_planogram_pia`
**Summary:** Enabled Row Level Security on `public.planogram` (was disabled — meant any authenticated user could mutate planogram with no RLS gate) and on `public.pod_inventory_audit_log` (was disabled — audit log was technically writeable/deletable). Added permissive SELECT/INSERT/UPDATE/DELETE policies for `authenticated` on `planogram` (matches the prior implicit behavior — no behavior change for the FE). On `pod_inventory_audit_log`, added permissive SELECT + INSERT, and explicit UPDATE/DELETE blocks to make the table append-only at the policy layer. `auto_decrement_pod_inventory` (the only function that writes to this log) is `SECURITY DEFINER` and continues to write fine — DEFINER bypasses RLS as the function owner. Zero rows mutated. Zero FE behavior change.
**Verification:** Visited via Supabase MCP: both tables now report `rowsecurity = true`. Policy counts: `planogram` = 4, `pod_inventory_audit_log` = 4.
**Rollback:**
```sql
DROP POLICY IF EXISTS planogram_select ON public.planogram;
DROP POLICY IF EXISTS planogram_insert ON public.planogram;
DROP POLICY IF EXISTS planogram_update ON public.planogram;
DROP POLICY IF EXISTS planogram_delete ON public.planogram;
ALTER TABLE public.planogram DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pial_select ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_insert ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_no_update ON public.pod_inventory_audit_log;
DROP POLICY IF EXISTS pial_no_delete ON public.pod_inventory_audit_log;
ALTER TABLE public.pod_inventory_audit_log DISABLE ROW LEVEL SECURITY;
```

---

## 2026-04-25 — Decision: skip Supabase preview branching for Phase A
**Phase / Article:** Phase A process / Article 12 (forward-only)
**Applied to:** decision log
**Migration name:** n/a
**Summary:** Attempted to create a preview branch via `mcp__supabase__create_branch` to apply A1 in isolation first. Returned `PaymentRequiredException` — branching is Pro-plan-only. Decided to apply Phase A directly to prod instead, with the `before/after` artifact as the visual diff and the rollback SQL as the safety net. This is acceptable for Phase A specifically because every step is metadata-only (no row mutation, no schema-shape change). For Phase B (FE migration touches data writes via new code paths), we will revisit branching or a staging Supabase project.
**Rollback:** n/a (decision-only).

---

## 2026-04-25 — Constitution v1.0 ratified
**Phase / Article:** n/a (constitutive doc)
**Applied to:** repo
**Migration name:** n/a
**Summary:** Authored 15 articles defining canonical write paths, validation, audit, surfaces (edge fns / n8n / cron), schema hygiene, and process. Codified the "make the wrong thing impossible" governance principle. See `01_constitution.html`.
**Rollback:** n/a (deprecating the Constitution requires the amendment process in Article 15 itself).

---
