# PRD-072 goal command

GOAL: Execute PRD-072 (docs/prds/PRD-072-residue-sweep-post-071.md) end to end, AUTO mode. Apply only green pieces, SKIP-and-HIGHLIGHT gate failures, keep PRD-072-EXECUTION-LOG.md current, never wait on CS.

PRECONDITION: CS has closed Cursor. If the tree re-dirties after any restore or commit during the run, STOP everything and highlight; do not loop against the formatter.

HARD GATES: engines md5 byte-identical, swaps_enabled false, no migrations expected (if one becomes necessary, STOP and highlight). npm run build must be green before any merge to main. Never force-push. The ONLY sanctioned -D is feat/prd-053-stitch-conservation, and only after re-proving coverage.

WS-A formatter kill: On main, spot-check 5 dirty files with normalized-content diff to confirm zero real content, then git restore . Run the repo's configured prettier once, deliberately, over src/ and docs/. Commit chore(format): deliberate prettier pass to end formatter drift (prd-072). Gate: tree clean AND a second prettier run yields zero changes.

WS-B ship 020 keepers: Branch feat/prd-072-perf-tab-tracker from main. Cherry-pick 455931f, ec20217, 138f7c8, a2c99c6 from feat/prd-020-packing-partial. EXCLUDE b390fb7 (packing partial, superseded by PRD-044/047/049). Resolve conflicts favoring main; drop duplicate migration files (get_product_performance RPCs already on main). Gates: build green, changes confined to products/tracker/layout/sidebar + registries. Merge to main, push, then delete feat/prd-020-packing-partial local and remote.

WS-C archive weimi: Branch archive/weimi-api-2026-06 from main. Copy exactly src/app/api/weimi/apply-capacity/route.ts, src/app/api/weimi/apply-status/route.ts, src/lib/weimi.ts from feat/prd-033-operator-flexibility, plus a short README: archived, not wired, n8n is the live capacity path. Push. Do NOT merge to main. Re-run the coverage diff proving nothing else on 033 is unique, then delete feat/prd-033-operator-flexibility local and remote.

WS-D prune: 1) feat/prd-053-stitch-conservation: re-prove both ahead commits' content exists on main (normalized diff), record proof, then -D local and delete remote. 2) chore/prd-071-wip-salvage and docs/prd-071-salvage: verify merged, -d local, delete remote.

WS-E toast fix: Locate RefillPlanReview.tsx. push_plan_to_dispatch v7 returns jsonb; read the v7 function body to confirm the line-count key, parse it, show the real count in the success toast. Gate: build green plus a sample-payload check of the rendered string.

WS-F M2M verify (read-only): If any FE push happened since 2026-07-03, read refill_dispatching for that plan date and verify all internal_transfer legs have is_m2m true and shared m2m_transfer_id per transfer, WH delta 0. If none, write the exact verification SQL into the log for CS to run after the next push. No writes.

WS-G close: Regenerate the monitor (python3 boonz_build_refresh.py from the BOONZ BRAIN parent). Banner GREEN, local branches = main + archive/weimi-api-2026-06 only. Commit and push all docs; main == origin/main. Final report: shipped, skipped and why, confirmation the open PRD set is unchanged (061 062 064 066 067 069).
