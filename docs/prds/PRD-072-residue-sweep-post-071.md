# PRD-072: Post-071 residue sweep

Status: Draft, direction approved by CS 2026-07-03. Run via `PRD-072-goal-command.md` in Claude Code.
Owner: CS. Mode: AUTO with hard gates, single run, small scope. Follows PRD-071 (board GREEN @ 7c73b6d).

## Why

PRD-071 left six deliberate residues: the Cursor formatter keeps re-dirtying the tree (60 files right now), two kept branches carry unique code needing a ship/archive call (020 Performance tab + tracker access; 033 weimi API), one divergent branch needs -D (053, coverage proven), two merged salvage branches need pruning, and the push success toast reads a jsonb as a number ("0 lines"). CS decisions: cherry-pick-ship 020 (minus the superseded packing commit), archive-only the 033 weimi files, allow -D on 053 with proof re-recorded, prettier pass to kill the gremlin, fix the toast.

## Precondition (CS, manual)

Close Cursor (and any editor with format-on-save) on this repo before the run. If the tree re-dirties mid-run after a restore, STOP and highlight; do not fight the formatter.

## Non-goals

No engine or RPC changes. Engines stay md5 byte-identical, swaps_enabled false, no migrations expected. No wiring of the weimi API routes. No packing-page changes (PRD-044/047/049 superseded the 020 packing commit).

## Workstreams

### WS-A: Formatter gremlin kill

1. `git restore .` on main (PRD-071 proved these diffs carry no content; re-verify with a normalized-content spot check on 5 files first).
2. Run the repo's own formatter (prettier via package.json script if present, else npx prettier --write on src/ and docs/ per repo config) once, deliberately.
3. Commit as `chore(format): deliberate prettier pass to end formatter drift (prd-072)`. Gate: after commit, tree clean and a second prettier run produces zero changes.

### WS-B: PRD-020 cherry-pick ship

1. Branch `feat/prd-072-perf-tab-tracker` from main. Cherry-pick from feat/prd-020-packing-partial: 455931f, ec20217 (Performance tab v2/v3), 138f7c8, a2c99c6 (tracker in-app access). EXCLUDE b390fb7 (packing partial, superseded).
2. Resolve conflicts favoring current main structure; the get_product_performance RPC migrations are already on main, drop duplicate migration files from the picks if they conflict.
3. Gates: `npm run build` green; the products page renders the new columns in a local check; no changes outside src/app products/tracker/layout/sidebar + registries.
4. Merge to main, push. Then delete feat/prd-020-packing-partial local + remote (now fully covered).

### WS-C: PRD-033 weimi archive

1. Branch `archive/weimi-api-2026-06` from main. Copy exactly 3 paths from feat/prd-033-operator-flexibility: `src/app/api/weimi/apply-capacity/route.ts`, `src/app/api/weimi/apply-status/route.ts`, `src/lib/weimi.ts`. Commit with a README note: archived, not wired, n8n flow is the live path.
2. Push the archive branch. Do NOT merge to main.
3. Verify nothing else on 033 is unique (PRD-071 already proved this; re-run the coverage diff as a gate). Then delete feat/prd-033-operator-flexibility local + remote.

### WS-D: Branch pruning

1. feat/prd-053-stitch-conservation: re-verify coverage (both ahead commits' content present on main by normalized diff), record proof in the log, then `git branch -D` locally and delete the remote. This is the one sanctioned -D, per CS.
2. Delete chore/prd-071-wip-salvage and docs/prd-071-salvage local + remote (both merged to main, verify merged first, -d only).

### WS-E: Toast fix

`src/components/.../RefillPlanReview.tsx` (locate exact path): the push_plan_to_dispatch v7 result is jsonb, not a number. Parse the jsonb (lines/count field per v7's return shape; read the function body to confirm the key) and show the real line count in the success toast. Gate: build green, and the rendered string is correct for a sample jsonb payload in a unit-style check.

### WS-F: M2M live-path verification (read-only)

If a plan was pushed via FE since 2026-07-03: read refill_dispatching for that plan date and verify every internal_transfer leg has is_m2m=true and a shared m2m_transfer_id per transfer, WH delta 0. If no push happened yet, emit the exact SQL checklist for CS to run after the next push, into the execution log. No writes either way.

### WS-G: Close

Regenerate monitor (python3 boonz_build_refresh.py from BOONZ BRAIN parent). Banner GREEN; branch list should show only main + archive/weimi-api-2026-06 locally. Write PRD-072-EXECUTION-LOG.md throughout; commit and push everything; main == origin/main.

## Acceptance

- Tree stays clean after a prettier re-run (gremlin dead, assuming Cursor stays closed or is configured to match).
- Performance tab + tracker access live on main, build green; packing commit not merged.
- Weimi code preserved on a pushed archive branch; 020/033/053/salvage branches gone.
- Toast shows real line count. Monitor GREEN. Open PRD set unchanged: 061, 062, 064, 066, 067, 069.

## Rollback

WS-A/B/E are plain commits on main, revertable. WS-C/D branch deletions are recoverable from origin reflog ~90 days; the weimi archive branch is pushed before any delete.
