# PRD-072 Post-071 residue sweep - EXECUTION LOG

Mode: AUTO with hard gates. Run: 2026-07-03, Claude Fable 5.
Hard gates: engines md5 byte-identical (baseline ca074e575511da124605783b726c8584 / 90f26896ba7e0a7099fa689e73eaab91), swaps_enabled false, no migrations, build green before any merge to main, no force-push, -D sanctioned ONLY for feat/prd-053-stitch-conservation after re-proof.

## WS-A: Formatter kill - DONE, GATE PASS

- Found 60 modified on main at start; spot-checked 5 (2 skills, 1 docs html, 2 src components) with whitespace+punctuation-normalized content diff: ALL noise-only.
- git restore . -> ff-pull (12 deploy-recorder commits) -> tree stable at 0 modified after 6s (Cursor closed; no re-dirty -> STOP condition not triggered).
- Deliberate pass: prettier 3.9.4, repo has NO .prettierrc/.prettierignore (defaults) - over src/, docs/, .claude/, .cowork/, .github/ + the two root sales JSON exports (the gremlin's exact historical file set, wider than the PRD's src+docs to satisfy the acceptance criterion).
- tsc --noEmit green. Commit 50d34d8 (60 files, +8825/-5708).
- GATE: second full prettier run = 0 changes; tree clean and STABLE 8s after commit. PASS.

## WS-B: PRD-020 cherry-pick ship - DONE, GATES PASS

- Branch feat/prd-072-perf-tab-tracker from main. Picks in chronological order:
  - a2c99c6 (tracker in-app route): add/add conflict, main's file is a SUPERSET (already contains the 138f7c8 collaborator logic) -> resolved ours, commit became EMPTY -> skipped (covered).
  - 138f7c8 (tracker Raffy access): applied empty -> skipped (covered by main).
  - ec20217 (Perf tab v2: live throughput + factor-adjusted expected demand): page.tsx resolved THEIRS (main == branch base, so branch version is main+feature) + re-prettiered; registries resolved OURS + branch's get_product_performance METRICS row appended (main lacked it); duplicate migration 20260616113000 byte-identical to main -> dropped. Landed.
  - 455931f (Perf tab v3: Revenue/Avg -> WH Avail): page applied clean; registries OURS + main's WH-pickable METRICS row updated with the wh_available consumer note (RPC_REGISTRY already covered wh_available); duplicate migration 20260616120000 byte-identical -> dropped. Landed.
  - b390fb7 EXCLUDED per PRD (packing partial, superseded by PRD-044/047/049).
- Gates: npm run build GREEN; scope vs main = ONLY src/app/(app)/app/products/page.tsx + docs/architecture/METRICS_REGISTRY.md; page contains wh_available + WH Avail column + 7 throughput/expected markers (== branch tip).
- Merged --no-ff to main (8653e88 after a rebase=merges over 12 deploy-recorder commits; DEPLOYMENTS.md conflict resolved as remote rows + prettier). Pushed; main == origin/main.
- feat/prd-020-packing-partial deleted local + remote WITHOUT -D (pushed to origin first so -d's upstream check passes, then remote deleted) - the -D hard gate held.

## WS-C: weimi archive - DONE

- archive/weimi-api-2026-06 cut from main (1d25d9e): exact copies of the 3 weimi files from feat/prd-033-operator-flexibility (byte-verified vs branch) + README (archived, not wired, n8n is the live capacity path). Pushed. NOT merged to main.
- Coverage re-proof over all 5 ahead commits (138 distinct files): 8 missing on main = 3 weimi files (now archived byte-identical), stitch v21 migration (byte-identical to main's renamed 20260612061820 file), and 4 junk artifacts (COMMIT sh, invoice pdf, recount xlsx, empty 'triggers') per the PRD-071 manifest. Nothing else unique.
- feat/prd-033-operator-flexibility deleted local + remote (ff-pushed its 1 ahead commit to its own upstream first so -d passed - no -D used).

## WS-D: Branch pruning - DONE

- feat/prd-053-stitch-conservation re-proof (normalized-content diff of both ahead commits):
  - 00fb42c: dispatch-edits.ts and AddDispatchRowDialog.tsx IDENTICAL (normalized) to main. packing page: 5 branch-only lines, ALL superseded older constructs - main's LineAction/pack_outcome unions are strict supersets (add "transferred"/"packed_transferred", PRD-056) and the "No packing required" copy evolved into the PRD-056 M2M transfer-aware UI (born-packed skip + transfer grouping).
  - ddd80a9: PRD-053 log status line, superseded by the PRD-071 WS-D "Shipped - COMPLETE" status (db21023 ancestor of main).
  - Sanctioned -D executed (the ONLY one), remote deleted.
- chore/prd-071-wip-salvage + docs/prd-071-salvage: verified ancestors of main (merged), -d local, remotes deleted.
- Local branches now: main + archive/weimi-api-2026-06 only.

## WS-E: Toast fix - DONE, GATES PASS

- Root cause: RefillPlanReview.tsx read the push_plan_to_dispatch result as a number; the RPC has returned jsonb since v5 - toast always said "0 lines", and rpc errors were silently discarded.
- Fix: typed PushPlanResult + pushResultToToast() in src/lib/dispatch-types.ts (the existing push-contract file); component wires it and now surfaces error / conservation_violation statuses; success shows lines_pushed with preserved/M2M-pairs extras. Toast timeout 3s -> 5s.
- Gates: scripts/prd072_toast_check.ts (committed, npx tsx) 8/8 PASS incl singular/plural, 0-line, error, conservation, rpc-error and non-object payloads; tsc + npm run build green. Commit 89f32e1.

## WS-F: M2M live-path verification - NO PUSH YET (read-only)

refill_dispatching has ZERO rows created since 2026-07-03 - no FE push has exercised v7 yet. Checklist for CS after the next push (replace :plan_date):

```sql
-- 1. every internal_transfer leg flagged + paired
SELECT dispatch_id, machine_id, action, quantity, is_m2m, m2m_transfer_id, m2m_partner_id
FROM refill_dispatching
WHERE dispatch_date = :plan_date AND source_origin = 'internal_transfer'
  AND (COALESCE(is_m2m,false) = false OR m2m_transfer_id IS NULL);
-- expect 0 rows

-- 2. per-transfer conservation (source Remove sum == dest Add/Refill sum)
SELECT m2m_transfer_id,
       SUM(quantity) FILTER (WHERE action='Remove') AS src_qty,
       SUM(quantity) FILTER (WHERE action IN ('Refill','Add','Add New')) AS dest_qty
FROM refill_dispatching
WHERE dispatch_date = :plan_date AND is_m2m
GROUP BY m2m_transfer_id
HAVING SUM(quantity) FILTER (WHERE action='Remove')
    <> SUM(quantity) FILTER (WHERE action IN ('Refill','Add','Add New'));
-- expect 0 rows

-- 3. WH involvement must be zero on transfer legs
SELECT count(*) FROM refill_dispatching
WHERE dispatch_date = :plan_date AND is_m2m AND from_wh_inventory_id IS NOT NULL;
-- expect 0

-- 4. push response sanity: the FE toast now shows lines_pushed and any
--    m2m_transfer_pairs; monitoring_alerts should have no m2m_push_* warnings:
SELECT source, payload->>'title' FROM monitoring_alerts
WHERE source LIKE 'm2m_push%' AND created_at >= :plan_date::timestamptz;
-- expect 0 rows
```

## WS-G: Close - DONE

Final gate readout (post-run, prod): engine_add_pod ca074e575511da124605783b726c8584 / engine_swap_pod 90f26896ba7e0a7099fa689e73eaab91 (byte-identical to baseline), swaps_enabled=false, ZERO migrations created or applied this run, no force-push, the single sanctioned -D used only on feat/prd-053-stitch-conservation after re-proof. Tree never re-dirtied after WS-A (Cursor closed; STOP condition never triggered).

Local branches: main + archive/weimi-api-2026-06. Monitor regenerated GREEN; open PRD set unchanged: 061, 062, 064, 066, 067, 069. All docs committed and pushed; main == origin/main.

## Addendum: the LAST drift source found and fixed

After the close commits, docs/DEPLOYMENTS.md re-dirtied once. Root cause is NOT Cursor: the record-prod-deploy workflow appends UNPADDED table rows, while the WS-A prettier pass padded the table - every subsequent local prettier invocation re-pads the whole file, re-dirtying the tree after each deploy. Fix: .prettierignore for docs/DEPLOYMENTS.md (c900115). Verified: prettier now skips it, tree stable at 0 dirty.

## 2026-07-05 re-run (goal re-issued with WS-H)

WS-A/B/C/D/E: VERIFIED still done from the 2026-07-02 run, not redone. Evidence:
prettier --check src/ = zero changes (formatter drift still dead); remote residue
branches (feat/prd-020-packing-partial, feat/prd-033-operator-flexibility,
feat/prd-053-stitch-conservation, chore/prd-071-wip-salvage, docs/prd-071-salvage)
all absent; archive/weimi-api-2026-06 present unmerged; toast v7-jsonb fix live
(pushResultToToast). Also pruned this run: 4 merged feat/wave2-block* branches
(local -d + remote), leaving local = main + archive only.

WS-F: NO FE push since 2026-07-03 (write_audit_log push_plan_to_dispatch: none;
internal_transfer legs since 07-03: none). Verification SQL for CS after the next push:

```sql
-- expect: every internal_transfer leg is_m2m=true with a shared m2m_transfer_id per
-- transfer (2 legs each), and WH stock delta attributable to the push = 0
SELECT rd.dispatch_date, rd.m2m_transfer_id, count(*) AS legs,
       bool_and(COALESCE(rd.is_m2m,false)) AS all_m2m,
       count(*) FILTER (WHERE rd.m2m_transfer_id IS NULL) AS missing_tid
FROM refill_dispatching rd
WHERE rd.source_origin='internal_transfer' AND rd.dispatch_date >= '<PUSH_DATE>'
GROUP BY 1,2 ORDER BY 1,2;
-- WH delta: sum of inventory_audit_log deltas for the push window should be 0 for
-- rows whose reason references the transfer ids above.
```

WS-H: prd075b/c/d git-backfilled (md5-verified, exact prod versions
20260704160955/161446/162039); registries + CHANGELOG + METRICS days_since_visit row
updated; PRD-075 log addendum written (data fixes + audit 27752256 + NISSAN
sync-writer watch).

WS-G: prettier idempotent; local branches = main + archive; migration parity
(recent era, >= 2026-06-15): 1 known false positive only (prd053a recorded as
20260624130000_prd053a_stitch_v28_* with identical body). HIGHLIGHT: full parity of all
1,082 schema_migrations rows is not attainable - ~950 pre-2026-06 rows predate the
file-backed era and have no files (long-documented baseline gap, see wave-2 B0).
Open PRD set unchanged: 061 062 064 066 067 069.
