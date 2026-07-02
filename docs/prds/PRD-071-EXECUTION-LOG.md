# PRD-071 Environment Closeout - EXECUTION LOG

Mode: AUTO with hard gates (self-run Dara/Cody, SKIP-and-HIGHLIGHT). Run: 2026-07-02, Claude Fable 5.
Hard gates: engine_add_pod + engine_swap_pod md5 byte-identical before/after; swaps_enabled false; forward-only migrations; BEGIN..ROLLBACK proof before every write; idempotent writers; no -D, no force-push, no deletion of unproven code.

## WS-A: Branch reset - DONE, GATE PASS

Baseline found: checkout on feat/prd-065-field-reconciliation (47c1f01), 300 behind origin/main (f6e2e90 after fetch; main had advanced 11a1153 -> f6e2e90 during run), 74 modified + 11 untracked files.

Classification method (logged for audit):

1. Byte-diff each dirty file vs origin/main: 72 modified files differ, 2 (CHANGELOG.md, MIGRATIONS_REGISTRY.md) already byte-identical to main.
2. Whitespace+punctuation-normalized line-set comparison vs origin/main: every modified file's content already on main EXCEPT PRD-067 doc. Root cause of the 83-dirty-file scare: a prettier/formatter sweep ran across the old worktree (pure reflow: 777+/777- on DEPLOYMENTS.md, `*x*` -> `_x_`, table separator padding, `<!DOCTYPE` -> `<!doctype`). Working tree was format(stale HEAD); main's versions are newer and richer (worktree DEPLOYMENTS.md/RPC_REGISTRY.md were MISSING rows main has).

KEEPERS (committed to chore/prd-071-wip-salvage @ abecf76, cut from origin/main f6e2e90):

- docs/prds/PRD-067-dataintegrity-dup-product-phantom-machines.md - live-verified 2026-06-30 correction (single hunk): 285479a7 is NOT an empty shell (24 residual refs: 6 pod rows, 1 WH, 17 dispatch), blind-delete premise wrong, requires PRD-062-style merge decision. Supersedes main's version (references the overnight run's skip-log).
- 7 new docs: PRD-057-cleanup-rerun-goal-command.md, PRD-069-audit-log-noop-alert-ingest-leak.md, PRD-069-goal-command.md, PRD-070-completion-overnight-goal-command.md, PRD-070-goal-command.md, PRD-071-environment-closeout-one-shot.md, PRD-071-goal-command.md.

DISCARD MANIFEST (verified zero novel content vs origin/main before discard):

- 72 modified files (git restore): 4 skills files, 1 cowork skill, 1 workflow yml, 2 sales JSON exports, 24 docs (architecture/PRDs/SOPs/bibles), 40 src/ files - all formatter-noise-only or stale.
- docs/prds/phase-g/prd_inventory_integrity_phase_g_v2.md "novel" line was prettier escaping (`**_` -> `**\_`) - discarded.
- Untracked stale subsets of files main already tracks in fuller form: PRD-070-EXECUTION-LOG.md, 20260701160000_prd070_d2_pair_internal_transfer_m2m.sql, 20260701160500_prd070_d3_pick_list_m2m_dest_visibility.sql (0 novel lines each).
- BUILD_ORCHESTRATOR.html - generated dashboard, regenerated in WS-F.

Reset: git restore . -> checkout main -> pull --ff-only (11a1153..f6e2e90) -> git branch -d feat/prd-065-field-reconciliation (deleted, was 47c1f01, -d accepted = fully merged).
GATE: git status clean (0 lines), main == origin/main == f6e2e90. PASS.

## WS-B: Auto-wire M2M pairing - DONE, APPLIED (all gates green)

State read (prod, 2026-07-02):

- TWO overloads of push_plan_to_dispatch existed: canonical (p_plan_date date, p_machine_name text) v6_prd053_conservation, and a PROD-ONLY relic (p_machine_name text, p_plan_date date) with no git source. Identical param-name sets made every PostgREST/named-notation call fail 42725 "function is not unique" - the FE approve->push (RefillPlanReview.tsx, error unchecked) was silently broken.
- Prod v6 body (prosrc md5 3a1438d7a169b08b4338beec74331c02) matched NO migration file in git - pre-existing PRD-057 drift.
- CRITICAL design pivot: PRD-070's trigger block_orphan_internal_transfer FORBIDS inserting internal_transfer legs with m2m_transfer_id NULL unless rpc in (swap_between_machines, repair_orphan_internal_transfer). The PRD-prescribed "post-insert pairing" is impossible for push-created legs (insert itself raises - a plan containing transfer lines would CRASH the whole push). swap_between_machines requires an authenticated operator (fails under service contexts) and does not set source_origin.
- Dara design (self-run): v7 = live v6 + anchored insertions. internal_transfer plan lines become PRE-PAIRED atomic writes: dest line (Add New/Refill + from_machine_id) creates source Remove leg(s) (FEFO batch split at source, PRD-053 EXPIRY-TO-CONFIRM remainder) + dest leg, all sharing a pre-allocated m2m_transfer_id, crosslinked m2m_partner_id, is_m2m=true, source_kind='m2m', from_warehouse_id NULL, packed=true (swap_between_machines conventions). Source Remove lines defer to the dest push. Unroutable/unmatched/failed lines skip-log to monitoring_alerts (m2m_push_unroutable / m2m_push_no_source_line / m2m_push_pair_failure) and never fail the push. Post-loop: pair_internal_transfer_m2m(p_plan_date, caller) safety net, same txn, idempotent, failure logged not raised; provenance GUCs (rpc_name/via_trigger/mutation_reason) restored after the call (PRD-016B leak lesson). Plus DROP of the legacy overload.
- Cody review (self-run): APPROVE. Articles 1 (single canonical dispatch writer, overload relic removed), 3 (RPC-only writes to protected refill_dispatching), 4 (paired legs atomic same-txn), 6 (zero warehouse_inventory involvement in transfer branch), 8 (via_rpc/rpc_name provenance + restore), 12 (idempotent); Amendments 003, 005. Trigger left UNTOUCHED (guard intact).
- Build integrity: base body fetched base64 (no JSON mangling), md5-verified d3acc78161d3ca44020cf9242317bbfd == prod def, 4 anchored insertions each asserted exactly-once.

BEGIN..ROLLBACK dry-run proof (real plan date 2026-07-02, synthetic approved M2M plan pair NOVO-1023 A10 -> ACTIVATE-2005 A01, Be-Kind Bar Protein - Dark Chocolate, qty 3; aborted via RAISE):

- source push: 0 pushed, 1 deferred, v7 version, safety-net pairing ok
- dest push: 2 pushed (1 src Remove + 1 dest Add New), 1 pair; src leg qty 3 expiry 2026-12-31 (FEFO), packed=true; shared m2m_transfer_id, partners crosslinked -> pair_ok=true
- WH delta = 0; non-transfer rows for the date byte-identical; re-push both machines: 0 new rows, full-date state hash identical (idempotent x2); engines md5 unchanged
- post-rollback verify: both overloads + baseline md5s intact (nothing persisted)

APPLY: mcp apply_migration prd071_wsb_push_v7_prepaired_m2m_drop_legacy_overload -> success. Post-apply verify: single overload only, v7 md5 98c40dc31ac26a76701626ecae89b417 == git file byte-identical (PRD-057 drift CLOSED - the full body is now in git), engines ca074e575511da124605783b726c8584 / 90f26896ba7e0a7099fa689e73eaab91 unchanged, swaps_enabled=false, named-notation call resolves (42725 gone).
File: supabase/migrations/20260702151932_prd071_wsb_push_v7_prepaired_m2m_drop_legacy_overload.sql (renamed to the applied schema_migrations version 20260702151932).

Backfill since 2026-07-02: 0 unpaired internal_transfer legs exist (verified) - nothing to backfill. Legacy unpaired legs are 2026-05-19 (15) and 2026-05-20 (9) only - WS-C territory / PRD-070 known set.

NOTE for FE (not in PRD-071 scope, no FE work): RefillPlanReview.tsx treats the push result as a number and ignores rpc errors; now that the 42725 is gone the push works again, but the toast count will show 0 (result is jsonb). Cosmetic.

## WS-C: Data anomalies - DONE (all three, committed)

### C1: MINDSHARE-1009 stale Remove legs - CANCELLED

Row snapshots BEFORE (2026-07-02):

- 16604bd2-9fc7-4b2e-9ce1-9db3edd6b343 | MINDSHARE-1009-4500-O1 | Remove qty 3 | 2026-05-20 | internal_transfer | is_m2m=false, m2m_transfer_id=null, source_kind='m2m', source_machine_id=5bca4d76 | packed/picked_up/dispatched=true | comment "Removed from Mindshare -> transferred to WPP"
- 2c43a829-8ac0-498d-b0e4-e55f04ab16e2 | same machine | Remove qty 5 | 2026-05-20 | internal_transfer | same flag shape | comment "Removed from Mindshare -> transferred to AMZ-3003"
  Blockers hit and resolved: cancel_dispatch_line initially failed CHECK m2m_consistency (NOT VALID) - the rows were internally contradictory (source_kind='m2m' with is_m2m=false); 'unknown' then failed source_consistency_chk (source_machine_id non-null). repair_orphan_internal_transfer rejected as the tool (it PAIRS orphans - opposite of the CS-approved cancel - and would trip the same constraint). Resolution: one-txn decompose (PRD-061/062 precedent, no canonical writer covers metadata repair): normalize source_kind='unknown' + source_machine_id=NULL (app.via_trigger + mutation_reason set; bypass logged by design) then CANONICAL cancel_dispatch_line x2 under CS identity (82bba4ee, operator_admin).
  Dry-run (DO+RAISE): both ok, wh_delta=0, pod_delta=0. COMMITTED 2026-07-02 15:28:00Z: both cancelled=true, cancelled_by=CS, reason logged. AFTER: cancelled=true, source_kind='unknown', is_m2m=false, quantities intact (3, 5).

### C3 (applied before C2, so C2 rode the guarded path): approve_m2m_transfer v2

Anomaly class: convert-path (PRD-052 convert_removes_to_m2m_transfer) dest legs created returned=true + past-dated, blocking pick list. Fix at APPROVE path per CS decision; convert untouched.
Guard: explicit counted normalize pass (returned=false on not-yet-received dest legs) before receiving. dispatch_date intentionally NOT normalized: protect_packed_dispatch_row (PRD-028-era) hard-blocks dispatch_date changes on packed rows with no GUC bypass (dry-run proved it), and the historical date is the truthful physical-transfer date; approved legs leave the pick list anyway (item_added). Cody: Articles 1,3,4,6 (WH self-assert kept),8,12; Amendment 003. APPROVE.
File: supabase/migrations/20260702153225_prd071_wsc3_approve_m2m_normalize_returned_on_approve.sql (== applied version 20260702153225). rpc_version v2_prd071_wsc3_normalize_on_approve.

### C2: Transfer 1538f35f-c386-405b-9cb1-dbc1fba94277 - APPROVED

BEFORE snapshot: 14 legs (7 dest Add New @ MINDSHARE-1009 all returned=TRUE, dispatch_date 2026-06-23, item_added=false, unapproved; 7 src Remove @ NOVO-1023, one (ff9afb9e qty 4) already received item_added=true). Sums: source 11 == dest 11. All from_wh_inventory_id NULL.
Dry-run (BEGIN + v2 + DO/RAISE): approved, legs_normalized=7, source_received=6, dest_received=7, wh_delta=0, NOVO pod delta 0 (stock physically left at 06-23 pickup), MINDSHARE pod delta +11 (destination credited - PRD-070 semantics), re-approve -> already_done (idempotent), 0 incomplete legs.
COMMITTED: approve_m2m_transfer('1538f35f...','82bba4ee') -> approved, legs_normalized=7, 6+7 received, wh_delta=0. Post-verify: 0 incomplete legs, both MINDSHARE cancels intact, engines md5 unchanged (ca074e57/90f26896), swaps_enabled=false.

## WS-D: Backlog truth sweep - DONE

Method: fused execution logs + MIGRATIONS_REGISTRY + RPC_REGISTRY + CHANGELOG + origin/main log + read-only prod checks (pg_proc version markers, pg_views/pg_tables existence, trigger list). Decisive prod evidence: engine_swap_pod = v15_slot_profile LIVE (so PRD-037 v12/v14 AND PRD-042 v15 shipped); stitch_pod_to_boonz = v28 (PRD-053); v_wh_pickable / v_dispatch_availability / v_machine_priority / pick_urgency_params / planned_swaps live; pack_dispatch_line, confirm_packed_transferred, convert_removes_to_m2m_transfer, driver_add_flagged_row live; PRD-068 guard triggers live (trg_conserve_split_qty, trg_reassert_conservation, trg_credit_dispatch_remainder); e1b9368 / 318afd4 / 47c1f01 / d25c84b / db21023 / 11a1153 all ancestors of origin/main.

36 status lines rewritten (all anchored replacements, zero failures):

- Shipped: 023, 028-dispatch, 035, 036, 037, 040 (B-track; C-track specs-only), 042, 043, 044, 045, 046, 047, 050, 052, 053 (complete incl FE B/C db21023), 054, 055 (P3 FE still on branch), 056 (VERIFICATION doc), 058, 059, 063, 065, 068, 070.
- Applied (git sync pending): 028-metrics-registry (6 commits were on unmerged branch; docs salvaged WS-E; canonical objects verified live).
- Closed (2026-07-02 sweep, reopen-by-deleting-line): 024, 025, 026, 027, 030, 031, 034, 039 (Phase 0+1 shipped, P2 parked).
- Open with verdicts: 061, 062, 064, 066, 067, 069 (067/069 lines added post-salvage-merge).
- NO-DOC PRDs (nothing to update; noted): 029 (superseded by PRD-028-dispatch doc; original doc salvaged WS-E), 032 (tracker sidebar - doc salvaged WS-E), 033 (doc + EXECUTION-LOG salvaged WS-E), 038, 041, 051 (goal-command salvaged), 057 (doc salvaged WS-E; shipped per memory), 060 (docs salvaged WS-E), 069 (doc arrived via WS-A salvage).
- PRD-048: SHIPPED but had NO doc on main (2111dda ADD-brain base-stock behind flag; 7 prd048 migrations); PRD doc salvaged from branch in WS-E.

Registry fixes: MIGRATIONS_REGISTRY was missing ALL rows for PRD-036 (3), PRD-037 (2), PRD-048 (7), PRD-062 (1), PRD-065 (8), PRD-068 (2) -> 23-row backfill section appended + PRD-071 section (2 rows). RPC_REGISTRY updated: push_plan_to_dispatch v7 (legacy overload dropped - the Article 13 deprecation flag closed), approve_m2m_transfer v2, pair_internal_transfer_m2m auto-invoked note. CHANGELOG: 2026-07-02 PRD-071 entry.

## WS-E: Git salvage and prune - DONE (2 branches KEPT with highlights)

Verification method per branch: list origin/main..branch commits; per commit, file-existence scan on main + content containment (whitespace-insensitive diff; prettier reflow identified and discounted); markers grepped on origin/main; migration content parity vs main variants.

SALVAGED (docs/prd-071-salvage c8a180c, 99 files, 8791 lines - file-level extraction from branch tips to avoid stale-snapshot conflicts):

- 21 docs from feat/prd-052-convert-m2m (e40d06e): PRD-047..060 goal-commands, PRD-048/049/056/057/060 PRD docs, PROD-SYNC-PRD058-059 goal-command.
- 2 from feat/prd-028-metrics-registry (9b0a6c2): PRD-028 goal-command + applied stitch v21 migration (renamed to its applied schema_migrations version 20260612061820 so the runner treats it as applied; historical, superseded by v28).
- 76 from feat/prd-033-operator-flexibility (0386961): PRD-011..033 docs/goal-commands, programs, refill-pipeline + refill-day docs, boonz-master-3 skill docs (memory said this skill was missing!), PRD-029 rollback SQL, tickets, postmortems, mirdif investigations.
  Junk NOT salvaged (manifest): COMMIT_2026-05-26.sh, AKY invoice PDF, inventory-recount xlsx, empty 'triggers' file, sales JSON exports, superseded pre-apply prd062 migration draft (prod parity file already on main).

Coverage verdicts (code):

- prd-049 phases A/B/D + packing: re-implemented on main via d25c84b (ancestor). QA script on main. COVERED.
- prd-053 local pair (00fb42c FE + ddd80a9 docs): FE wired on main (driver_add_flagged_row in dispatch-edits.ts + AddDispatchRowDialog), db21023 ancestor of main. COVERED.
- prd-052 FE (5f758ef): all 12 files contained on main (residuals = prettier reflow only). 77be59e migration byte-identical to main's. e40d06e migration = pre-apply draft of main's prod parity file. COVERED.
- products-performance-table (89da38f) + wip/realign (1b0c2d4): equivalent of main's 267acd9. COVERED.
- 0386961/9469b95 VOX perf (prd023i/j): markers on main (Adyen Fees cols, include_transactions). COVERED. prd033 A-E migrations: 5 on main. COVERED.

HIGHLIGHT - KEPT branches (code NOT on main/prod):

1. feat/prd-020-packing-partial (455931f): products Performance tab v2/v3 FE (live throughput + factor-adjusted expected demand ec20217; Revenue/Avg -> WH Stock Available 455931f) never landed on main - backend RPC migration IS on main (20260616120000_get_product_performance_add_wh_available) but the FE tip isn't. Local-only branch. CS: ship or discard deliberately.
2. feat/prd-033-operator-flexibility (0386961): weimi API code (src/app/api/weimi/apply-capacity, apply-status, src/lib/weimi.ts) exists nowhere on main -> not in any prod deploy. Docs salvaged; code kept. CS: decide weimi's fate.
3. feat/prd-053-stitch-conservation: content FULLY COVERED by main (proof above) but local/remote DIVERGED (remote holds 4 rebased duplicates of local commits; ff-push refused, -d refused, -D forbidden by hard gate). Safe to remove manually: `git branch -D feat/prd-053-stitch-conservation && git push origin --delete feat/prd-053-stitch-conservation`.

DELETED local (-d only, all proofs above): feat/prd-028-metrics-registry, feat/prd-047-v2, feat/prd-049-phase-a, feat/prd-049-phase-b, feat/prd-049-phase-d, prd-049-phase-a-packing, feat/prd-050-pickqty-plan-cap, feat/prd-052-convert-m2m (ff-pushed to its upstream first, no force), feat/products-performance-table, wip/realign-2026-06-16, feat/prd-063-picker-urgency, docs/prod-sync-prd058-059-closeout, feat/prd-058-059-prod-sync. (feat/prd-065 deleted in WS-A.)

REMOTE deletes performed (after pushing both salvage branches to origin): feat/prd-047-v2, feat/prd-028-metrics-registry, feat/prd-049-phase-a, feat/prd-049-phase-b, feat/prd-049-phase-d, prd-049-phase-a-packing, feat/prd-050-pickqty-plan-cap, feat/prd-052-convert-m2m, feat/products-performance-table, wip/realign-2026-06-16, docs/prod-sync-prd058-059-closeout, feat/prd-058-059-prod-sync. (Recoverable from GitHub for ~90 days; salvage branches chore/prd-071-wip-salvage + docs/prd-071-salvage pushed and merged to main.)

Merges to main: 45e13d3 (WS-A wip salvage), 155cb49 (WS-E docs salvage).

boonz_git_cleanup.sh --apply output (final pass):

- Fetch+prune OK. Local main 0 behind / 4 ahead (the PRD-071 salvage merges - pushed in WS-F).
- No local-only branch carries unmerged work. No merged-and-deletable branches left.
- Drift report: 2 untracked migrations + 46 uncommitted files = exactly the PRD-071 work committed in WS-F.

ENVIRONMENT GREMLIN (highlight): an external formatter (Cursor is open on this repo with format-on-save / the PostToolUse prettier hook environment) re-prettifies tracked files after git rewrites them - this is the ORIGIN of the original "83 dirty files" scare (pure reflow noise, zero novel content, proven twice this run). If the noise reappears, `git restore .` is safe; consider closing Cursor during git-heavy runs or committing a repo-wide prettier pass deliberately.

## WS-F: Close and verify
