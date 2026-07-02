# PRD-021 — Wire dissolve_batch under Phase F (expiry-opt consumption path)

**Status:** DRAFT — awaiting CS approval. **Cody review REQUIRED at build time** (modifies engine_add_pod, a canonical writer to pod_refill_plan, and the Phase-F branch of reconcile_intent_progress → Article 15 amendment, per Cody's cleanup verdict).
**Supabase:** eizcexopcuoycuosittm. **Repo placement:** docs/prds/ in boonz-erp (next in PRD series — verify 021 is free).
**Origin:** Boonz Brain cleanup run 2026-06-10, Part 1 verification.

---

## 1. Problem

`expiry-opt` writes `strategic_intents` of type `dissolve_batch`, promising the at-risk WH batch will drain through normal refills. **Verified against live DB: nothing consumes them.**

- `engine_swap_pod` Pass-1 reads `strategic_machine_tags` + `strategic_intents` — decommission flow only.
- Live engines never tag `linked_intent_id` on REFILL draft lines.
- The Phase-F branch of `reconcile_intent_progress` credits `decommission` intents only.
- `orchestrate_refill_plan` (the Phase-D consumer) is orphaned — 0 live references.

Net effect: at-risk batches sit until expiry → write-offs. The cleanup STOP-banner on expiry-opt is the stopgap; this PRD is the fix.

## 2. Verified facts (Part 1, 2026-06-10 — re-verify at build start)

- F1. All 5 strategic RPCs exist (`propose_decommission_plan`, `propose_batch_dissolution_plan`, `flag_intent_threats`, `orchestrate_refill_plan`, `engine_swap_pod`).
- F2. `dissolve_batch` intents carry `wh_inventory_id`-level targeting + `target_qty` + `target_completion_date` (= expiration − safety buffer).
- F3. Batch-level WH picking exists downstream of pod planning: Stage 3 stitch resolves boonz_product + warehouse; packing applies FEFO `ASC NULLS LAST` to choose `expiry_date`.

## 3. Requirements

- R1 **Demand pull.** While a `dissolve_batch` intent is active, ENGINE ADD treats the intent's boonz_product as boosted demand on machines that stock it: fill toward shelf capacity (existing R7 60% cap and WH-scarcity throttle still bind; no new caps invented).
- R2 **Batch preference.** WH pick for that product prefers the at-risk `wh_inventory_id` first (FEFO tie-break → intent batch wins), at whichever layer batch selection actually occurs (see Q1).
- R3 **Attribution.** Draft lines whose units draw from the intent batch get `linked_intent_id` so progress is traceable, mirroring the decommission pattern.
- R4 **Crediting.** `reconcile_intent_progress` Phase-F branch extended: credit `applied_units` on dissolve_batch from confirmed dispatch/refill lines carrying `linked_intent_id`.
- R5 **Safety.** Never place units that would land expired or inside minimum shelf life at visit date; respect `max_residual_units`; intent auto-completes at target_qty − residual or expires at `target_completion_date` (then flag for write-off in the weekly upstream session — do not silently extend).
- R6 **Skill unblock.** On ship: remove the STOP banner from `strategic/expiry-opt`, rewrite its pipeline section to the real path (intent → ADD demand pull + batch-preferred pick → linked_intent_id → reconcile credit), update INDEX.md last_verified.
- R7 **Visibility.** Dissolve progress (target / applied / remaining / days-to-expiry) readable in the weekly upstream session (extend the existing intent-progress query or view — no new dashboard).

## 4. Candidate design (Cody + Dara to confirm insertion points)

- D1. `engine_add_pod`: after baseline demand calc, JOIN active `dissolve_batch` intents on boonz_product (via product_mapping) for in-scope machines; raise draft qty toward cap; tag `linked_intent_id` on the boosted portion.
- D2. Batch preference at the layer F3 confirms owns batch choice — stitch WH-redistribution or packing FEFO. Implement as ORDER BY (is_intent_batch DESC, expiry ASC NULLS LAST). One layer only; do not duplicate the preference in two places.
- D3. `reconcile_intent_progress`: add `WHEN intent_type='dissolve_batch'` mirroring the decommission crediting, sourced from dispatch lines with `linked_intent_id` + confirmed status.
- D4. No schema change expected. If a column is missing (e.g. `linked_intent_id` on the relevant line table), STOP → Dara design → Cody review → migration, before any function edit.

## 5. Open design questions (answer before build, in order)

- Q1. Where does batch (`wh_inventory_id`) selection actually bind — stitch or packing? (`pg_get_functiondef` both; the answer places D2.)
- Q2. Does `pod_refill_plan` / `refill_plan_output` already carry `linked_intent_id`, or only the decommission path's tables?
- Q3. Cap interaction: if R7 60% cap truncates a boosted line, does the truncated qty still credit correctly at reconcile (credit actual, never planned)?
- Q4. Multiple active dissolve intents on the same product: priority by earliest expiry — confirm no double-crediting.

## 6. Constraints (all in force)

Cody review BEFORE any canonical-writer/view/trigger change; verbatim function bodies before/after; service-role bypass pattern; RPC-only writes + allow-list; one statement per execute_sql; verify writes in rolled-back tx; never guess catalog gaps; update RPC_REGISTRY.md + CHANGELOG.md + this PRD's status; boonz-master-3 untouched (its routing text updates, if any, ship as a separate doc change after Cody sign-off).

## 7. Acceptance

- A1. Seed test: create a dissolve_batch intent on a real at-risk batch (or staged copy) → next engine run shows boosted REFILL drafts with `linked_intent_id` on in-scope machines.
- A2. Pick test: stitched/packed lines for that product draw from the intent batch first.
- A3. Reconcile test: after confirmed dispatch, `applied_units` increments by actual confirmed qty; intent completes at threshold.
- A4. Expiry test: intent past `target_completion_date` → flagged, not extended; no expired units ever planned.
- A5. Regression: decommission crediting unchanged (before/after counts on an active decommission intent).

## 8. Out of scope

Write-off automation; new dashboards; any expiry logic change for non-intent products; ERP-skill cutover; PRD-018 BUG-D.

---

## /goal invocation (run after CS approves this PRD)

```
/goal Execute docs/prds/PRD-021-expiry-opt-phase-f.md on Supabase eizcexopcuoycuosittm. Wire dissolve_batch intent consumption under Phase F. Echo this PRD's build order and WAIT for explicit green light — clarifying answers are NOT approval.
ORDER: (1) re-verify §2 facts + answer §5 Q1–Q4 read-only via pg_get_functiondef/catalog queries, report findings, HALT; (2) on my go: Dara design for any schema gap (D4) else skip; (3) Cody review of proposed engine_add_pod + reconcile_intent_progress diffs (verbatim bodies) BEFORE applying; (4) apply per §4, one statement per execute_sql, verify in rolled-back tx; (5) acceptance §7 A1–A5; (6) unblock expiry-opt skill per R6, update INDEX.md, RPC_REGISTRY.md, CHANGELOG.md, PRD status.
CONSTRAINTS: §6 all in force. Credit actual confirmed qty only, never planned. If live state contradicts §2 or any §5 answer contradicts §4 → STOP and report, do not improvise. boonz-master-3 untouched. DONE: diff summary mapped to ORDER steps + acceptance results, then STOP.
```
