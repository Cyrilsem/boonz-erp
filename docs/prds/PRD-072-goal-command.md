# PRD-072 goal command

GOAL: Execute PRD-072 (docs/prds/PRD-072-residue-sweep-post-071.md) end to end, AUTO mode. Apply only green pieces, SKIP-and-HIGHLIGHT gate failures, keep PRD-072-EXECUTION-LOG.md current, never wait on CS.

PRECONDITION: CS has closed Cursor. If the tree re-dirties after any restore or commit, STOP and highlight; do not loop against the formatter.

HARD GATES: engines md5 byte-identical, swaps_enabled false. npm run build green before any merge to main. Never force-push. The ONLY sanctioned -D is feat/prd-053-stitch-conservation, after re-proving coverage.

WS-A formatter kill: On main, spot-check 5 dirty files (normalized diff, zero real content expected), then git restore . Run the repo's prettier once over src/ and docs/. Commit chore(format): deliberate prettier pass (prd-072). Gate: tree clean AND a second prettier run yields zero changes.

WS-B ship 020 keepers: Branch feat/prd-072-perf-tab-tracker from main. Cherry-pick 455931f, ec20217, 138f7c8, a2c99c6 from feat/prd-020-packing-partial. EXCLUDE b390fb7 (superseded by PRD-044/047/049). Conflicts favor main; drop duplicate migration files (perf RPCs already on main). Gates: build green, changes confined to products/tracker/layout/sidebar + registries. Merge to main, push, delete feat/prd-020-packing-partial local and remote.

WS-C archive weimi: Branch archive/weimi-api-2026-06 from main. Copy exactly src/app/api/weimi/apply-capacity/route.ts, apply-status/route.ts, src/lib/weimi.ts from feat/prd-033-operator-flexibility + README (archived, not wired, n8n is live path). Push, do NOT merge. Re-prove nothing else on 033 is unique, then delete feat/prd-033-operator-flexibility local and remote.

WS-D prune: 1) feat/prd-053-stitch-conservation: re-prove both ahead commits exist on main, record proof, -D local, delete remote. 2) chore/prd-071-wip-salvage + docs/prd-071-salvage: verify merged, -d, delete remotes.

WS-E toast fix: RefillPlanReview.tsx treats push_plan_to_dispatch v7 result as number; it is jsonb. Read the v7 body for the line-count key, parse, show real count. Gate: build green + sample-payload render check.

WS-F M2M verify (read-only): If an FE push happened since 2026-07-03, verify in refill_dispatching that all internal_transfer legs carry is_m2m true + shared m2m_transfer_id, WH delta 0. Else write the verification SQL into the log for CS. No writes.

WS-H prod-sync of chat hot-fixes (2026-07-05): three migrations exist ONLY in prod history: prd075b_adjust_refills_count_as_visits, prd075c_dispatched_or_packed_counts_as_visit (both replace v_machine_health_signals; final body = prd075c), prd075d_eligibility_drift_sales_truth (v_machine_eligibility_drift = Active + selling + zero grading rows). Write each as a file in supabase/migrations/ named to match applied versions (read supabase_migrations.schema_migrations; pull live bodies via pg_get_viewdef). Update MIGRATIONS_REGISTRY + CHANGELOG + METRICS_REGISTRY days_since_visit row: visit = refill_dispatching evidence (picked_up OR returned OR dispatched OR packed) OR audit refs 'manual-refill-%' OR 'adjust-%'; approved-only plans never count. Append to PRD-075-EXECUTION-LOG.md: data fixes MPMCC-1058 'Pending Setup'->'Live', NISSAN-0804 'Switched off'->'Online today' (both trading while label-blind; if the adyen sync re-stamps NISSAN, the WRITER needs fixing), and the MPMCC-1058 zero-delta visit_marker audit row (27752256, dated 2026-07-01).

WS-G close: Regenerate the monitor (python3 boonz_build_refresh.py from BOONZ BRAIN parent). Banner GREEN, local branches = main + archive/weimi-api-2026-06 only. Verify remote-migration parity: every schema_migrations row has a matching file. Commit and push; main == origin/main. Final report: shipped, skipped and why, open PRD set unchanged (061 062 064 066 067 069).
