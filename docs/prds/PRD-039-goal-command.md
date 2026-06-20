# Claude Code /goal — PRD-039 Refill v4 Swap Value Model (gated)

Paste into Claude Code in `boonz-erp`. Builds migrations, runs rolled-back replays, STOPS before any prod apply.

```
/goal Build PRD-039 (swap value model). Read docs/prds/PRD-039-refill-v4-swap-value-model.md, PRD-037-refill-v4-swap-engine.md, and engines/refill/guardrails/*.md first. Supabase eizcexopcuoycuosittm. No em dashes. Forward-only migrations, no edit-in-place, no _v2 tables, no deletes (supersede only). engine_add_pod v18 FROZEN. swaps_enabled stays false (never flip in a committed migration; tests force it true only in BEGIN..ROLLBACK). PRD-037 must already be applied (engine_swap_pod v12, coexistence_rules, brand_owner, WS-1 helpers); if not, STOP and tell CS. Apply NOTHING to prod until CS says apply.

PHASE 0 (Dara designs, Cody verdicts, build files only):
- product_slot_capacity(physical_type text, shelf_size text, max_units int), PK(physical_type,shelf_size), RLS read-only. Seed from layout.md s4 OR observed max-per-(physical_type,shelf_size) from live planogram data: present BOTH to CS, let CS pick the seed. Leave a coverage query (14 physical_types x every shelf_size must resolve) + a fallback rule for misses.
- affinity helper: scoring-only Pearson/co-purchase for an arbitrary candidate vs a machine basket, independent of find_substitutes_for_shelf (new read-only DEFINER get_candidate_affinity, OR refactor find_substitutes into a no-shortlist mode). Cody rules which.

PHASE 1 (engine_swap_pod Pass-3 rewrite; forward-only CREATE OR REPLACE on the v12 body):
- WS-A broad universe: candidates = v_wh_pickable (stock > seed min, expiry ok, reserved_for_machine_id null or this machine), NOT on machine, _coexistence_blocks false, _travel_scope_blocks false, not 30-day intro cooldown, not suppressed. DROP find_substitutes as the gate. Pearson (via the new helper) = w3 term only (w_sister 0.5 > w_global 0.3 > w_pearson 0.2).
- WS-B candidate cap: cap(S,cand)=floor(product_slot_capacity[cand.physical_type][shelf.shelf_size]*0.85), override by slot_capacity_max.override_max_stock, fallback shelf_configurations.max_capacity. KEEP uses incumbent cap, same rule.
- WS-C top-N + unique assignment: per machine, top-N candidates per eligible slot by V, assign products to slots maximising total machine V, each product used at most once/machine/cycle (greedy-by-marginal-value; escalate to Hungarian only if replay shows lost value). Honour rate limits (<= p_max_swaps_per_machine, 14-day cooldown). Supersedes the v12 one-line dedup.
- WS-D homogenisation: a product newly introduced into at most K machines/cycle (seed K, tune) and 1 slot/machine; fleet cap <=10 unchanged.

PER PHASE:
1. Reconcile every column name in the PRD test queries against the live schema; fix before running.
2. REPLAY in BEGIN..ROLLBACK, swaps_enabled forced true, on a gate-clean plan_date (no approved refill_plan_output). Scope per-machine if the full-fleet run times out. Run every test in PRD s4, print PASS/FAIL with the actual value. Phase 0+1 must pass: U1 U2 C1 C2 A1 A2 H1 R1.
3. ANY fail: stop, report the failing assertion + output, do not apply, do not continue.
4. ALL pass: STOP, show CS the full table, wait for explicit "apply phase N".
5. On green light: apply, re-run read-only confirms on prod, write docs/prds/PRD-039-EXECUTION-LOG.md, STOP before the next phase.

BLOCKING: Cody must verdict the Phase-0 schema and the Pass-3 body before apply. T12 (ADD byte-identical) and T7 (swaps_enabled=false yields 0 Pass-3 swaps) fail the phase if violated. R1 (all PRD-037 tests T1-T7,T10-T13 still pass) is blocking. No parallel engine_swap_pod_v13; evolve the canonical function.

FINAL REPORT per phase: tests PASS/FAIL, applied y/n + timestamp, prod confirm. Open follow-ups: product_family_id backfill (Rule 2 family-keyed); true gross-profit margin; 70/30 = PRD-038; swaps_enabled OFF until P2.
```
