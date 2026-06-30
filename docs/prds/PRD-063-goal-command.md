/goal PRD-063: fix main-track P1 shortlisting by rewriting v_machine_priority IN PLACE to the shelf-aware urgency model + identity-based velocity. NO shadow. Picker code untouched (it reads p_tier/p_score from the view). Full spec: boonz-erp/docs/prds/PRD-063-picker-urgency-model.md. MODE AUTO but STOP for CS before applying (canonical Article-16 writer; show the before/after main-P1 diff first).

CONTEXT (live eizcexopcuoycuosittm 2026-06-28): the 6am picker shortlists main P1 via WHERE p_tier='P1_RESTOCK' ORDER BY p_score from v_machine_priority — still OLD machine-level logic. It wastes top slots on empty/dead machines (MC-2004 score 83, ALJLT-1015-0200 60, NOVO-1023) and MISSES real stockouts (ADDMIND-1007, a top seller ~1d from empty, not even listed). NEW model drops the cosmetic/dead ones, adds ADDMIND (hero) + GRIT (overdue 26d), keeps the expiry machines. Replaces the PRD-058 view body.

MODEL (locked; full math in spec): per enabled shelf dvel=sales 30d/facings, dos=stock/dvel, grade A>=.5/d B>=.2 C>0 D=0. urgency=.50*s_runout(gradeWt A1/B.6/C.25 * clamp((H-dos)/H), H=2)+.15*s_capacity(A/B/C only)+.20*s_expiry((2*expired+1*exp≤3d)/6)+.15*s_stale(0@≤7d→100@21d). TIER: P1 if hero(A dos<H AND dsv>1) OR stale(dsv>14) OR expired>=1 OR urgency>=50; P2 if exp≤3d>=3 OR urgency>=25 OR any A/B dos<H; else SKIP. Tiering UNCAPPED; 8 cap stays a SELECTION limit in the picker (main track), VOX parallel. All knobs tunable.

PRE: git pull --rebase main; branch feat/prd-063-picker-urgency. Fetch live view/fn bodies before editing.

BUILD (Dara → Cody → apply; forward-only):
1 pick_urgency_params singleton (id=1 CHECK id=1; RLS SELECT true; writes operator_admin/superadmin/manager): horizon, A/B floors, grade+component weights, expiry norm+override mins, stale grace/full+override day, cooldown, p1/p2 thresholds, driver_capacity. Seed locked defaults.
2 v_shelf_sales_identity resolver: shelf↔sales velocity joined on pod_product_id (sales via product_mapping/vox_product_mapping), name string fallback only. Fixes Hunter≡"Hunter Ridge" reading dead; keeps Pepsi Regular≠Black. Expose resolved + coverage.
3 Rewrite v_machine_priority IN PLACE: shelf velocity from v_live_shelf_stock + v_shelf_sales_identity; components/urgency/overrides; emit p_tier P1_RESTOCK/P2_MAINTAIN/P3_OK + p_score=urgency; KEEP every existing output column; rebuild reasons_arr from new triggers; add urgency/soonest_a_dos/grade counts; CROSS JOIN pick_urgency_params.
4 Cody review (Article 16, Hard Rule 6). STOP and show CS the before/after main-track P1 diff (must drop MC-2004/ALJLT/NOVO, add ADDMIND/GRIT) + name-match coverage BEFORE apply.
5 Apply after CS go-ahead. Ship a rollback migration that restores the prior v_machine_priority body verbatim.
6 Update boonz-master-3 SKILL.md: picker reads urgency-based v_machine_priority; "why is X P1/P2" answer; Step-0 description; pick_urgency_params knobs; dead-stock now in ADD/SWAP.

TEST (all pass; STOP on fail):
T1 view <800ms; new main P1 reproduces locked list on defaults.
T2 coverage matched/enabled shelves >=95%; Hunter resolves; Pepsi Regular≠Black.
T3 picker mechanics unchanged: main P1=view P1 by p_score, cap-8, VOX Wed/Fri gate + sibling + machines_to_visit contract intact.
T4 get_machine_health cards show new P1/P2.
T5 engine_add_pod/engine_swap_pod byte-identical; swaps_enabled false.
T6 single-row param guard.
T7 rollback restores prior view body exactly.

CLOSE: update CHANGELOG.md, MIGRATIONS_REGISTRY.md, METRICS_REGISTRY.md (v_machine_priority now shelf-aware urgency; supersedes PRD-058 body); set PRD-063 status.

HARD SAFETY: canonical Article-16 change — Dara design + Cody review before apply; STOP for CS with the before/after main-P1 diff + coverage. Picker/FE code untouched; engines byte-identical; swaps_enabled false; gate apply on >=95% name-match coverage. Forward-only; one-migration rollback; rebase --autostash; do NOT push to main without my explicit go-ahead.
