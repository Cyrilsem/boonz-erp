# /goal — PRD-109 Pre-Flight Refill Gate

GOAL: Build `preflight_refill_plan(p_plan_date)` — the machine-checked definition of a perfect refill — and gate commit on it. Read PRD-109-preflight-refill-gate.md FIRST; it defines the 12 invariants (INV-01..12) and the growth rule. Supabase eizcexopcuoycuosittm. Dara designs, Cody review MANDATORY before each migration. EXECUTION-LOG at PRD-109-EXECUTION-LOG.md.

WHY: Week of 2026-07-29 — every incident was two truth sources disagreeing, caught downstream by a human: ghost stockout (19 Extra Gum Spearmint in WH while stitch said total_wh_stockout — machine-scoped mapping shadowed global variants), duplicate facings (Barebells/CCZ size-ups on KEEP facings), orphaned swap leg (MC A15 REMOVE nearly shipped after its ADD_NEW not_filled), pack-board stranding. CS is done being the validation layer. Perfect refill becomes a property the system PROVES pre-commit, and the invariant list grows by one every time anything new bites, so no failure repeats.

BUILD ORDER:

1. `preflight_refill_plan(p_plan_date date)` — read-only, STABLE, SECURITY INVOKER. Returns (verdict PASS|FAIL|PASS_WITH_WARNINGS, violations jsonb, warnings jsonb, checked_at, invariant_versions jsonb). Each violation: {invariant_id, machine, shelf_code, pod/boonz names, expected, found, fix_path}. Implement INV-01..12 exactly as specced. Key implementation notes: INV-01 sums v_wh_pickable across ALL variants matched by pod_products→boonz name family, deliberately IGNORING product_mapping scope; INV-02 diffs the scoped vs unscoped variant sets; INV-03 reads slot_lifecycle + v_live_shelf_stock presence with the DOUBLE DOWN exception; dedupe every WH aggregation by wh_inventory_id BEFORE any mapping join (fan-out trap, RPC_REGISTRY.md:372 overload trap also applies: NEW function name, no overloads).
2. Wire the gate: `stitch_pod_to_boonz(p_dry_run=false)` calls preflight and REFUSES on FAIL; add p_force boolean DEFAULT false + p_force_reason (>=10 chars) that logs an audited override row. Dry-run stitch reports the verdict without blocking. (This edits a canonical writer — full Cody class-b review; engine_swap_pod untouched, PRD-094/095 freeze stands.)
3. Advisory + FE surfaces: 8pm advisory task reads preflight and prints the verdict line + top violations (assistant-side, no code); FE Commit button displays verdict and requires typed confirmation on p_force (Stax; deploy with the pending PRD-107 FE bundle).
4. Fixture replay: encode 2026-07-29 as a test fixture — preflight must FAIL citing INV-01 (Extra Gum 19u found), INV-03 (Barebells+CCZ), INV-04 (A15 orphan) with correct fix_paths. Full-fleet runtime < 10s.
5. pgTAP: per invariant one violating + one passing fixture; verdict aggregation; force-path audit row.
6. Registry/changelog/EXECUTION-LOG updates; record the growth rule in the Constitution docs as an Article-15 process note: every refill incident closes with a new/strengthened invariant, version-stamped in invariant_versions.

GUARDRAILS: preflight itself is read-only forever — it may never fix, only report; no raw DML anywhere; forward-only migrations; Cody review before each apply (step 2 especially — canonical writer edit); do not touch engine_swap_pod / rank_slot_suitability / pack RPCs; no function overloads; thresholds/knobs in refill_policy_params if any emerge; Title Case dispatching actions; no em-dashes in client copy.

ACCEPTANCE (all required):

- 07-29 fixture replay FAILs with the three named violations and correct fix paths; a clean synthetic plan PASSes.
- stitch(false) hard-refuses on FAIL; p_force writes an audited override; dry-run reports verdict without blocking.
- Full-fleet preflight < 10s.
- pgTAP green across all 12 invariants (24+ fixtures).
- Cody verdicts in EXECUTION-LOG before each apply; MIGRATIONS_REGISTRY.md + CHANGELOG.md updated; growth rule documented.
