# RC-06 — engine_swap_pod version-agnostic dead-tag filters

**Date:** 2026-07-18 · **Project:** eizcexopcuoycuosittm · **Status:** fix prepared, NOT applied (read-only session)

## Re-verification (2026-07-18, live prod)

- Live `engine_swap_pod` (single overload, oid 119248) still carries both stale filters — **not** fixed since the 2026-07-16 audit. Live body captured verbatim to `live_engine_swap_pod.sql`; transcription verified byte-perfect against server-side `md5(pg_get_functiondef(oid)) = ce685e14b6164257fb52301cdf5c8e7a` (35237 chars / 35239 bytes, two multi-byte em-dashes).
- Live `engine_add_pod` writes `tagged_by = 'engine_add_pod_v18'` (normal mode) / `'engine_add_pod_v19_base_stock'` (base_stock mode). Its own cleanup DELETE uses an explicit IN-list that currently includes v15–v19_base_stock, so add's own cleanup is not broken (but is version-pinned — flagged, not changed; out of RC-06 scope).
- **`engine_finalize_pod` and `build_draft_for_confirmed` are clean**: zero occurrences of `tagged_by` or any `engine_add_pod_vNN` literal in their live bodies (regexp scan of `pg_proc.prosrc`). No fix needed there — one correction to the audit note, which said the tags live in `strategic_machine_tags`; the dead tags actually live in **`pod_swaps.reasoning`** (`strategic_machine_tags.reasoning` carries no `tagged_by` key at all — 4 rows, all null).
- Repo migration `supabase/migrations/20260712155753_p0_fix12_engine_swap_weimi_identity_scoped_drift.sql` carries the same stale filter at lines 94 and 235. The prod-only `20260713180426_wave2_engine_swap_pod_rewire` is confirmed absent from the repo, but a pulled copy exists at `batch0/migrations/20260713180426_wave2_engine_swap_pod_rewire.sql` — it carries the same stale filter at **lines 97 and 238** and is the direct source of the live body (`rank_slot_suitability_wave2` Pass 2a). The fix migration was therefore built from the verified live body, not from any repo file.

## Diff hunks (complete — the ONLY changes)

```diff
--- live engine_swap_pod (prod, 2026-07-18)
+++ 20260718034118_rc06_engine_swap_pod_version_agnostic_tags.sql
@@ -93,7 +93,7 @@
 
   DELETE FROM public.pod_swaps
    WHERE plan_date = p_plan_date
-     AND NOT (pod_product_id_in IS NULL AND reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16'));
+     AND NOT (pod_product_id_in IS NULL AND reasoning->>'tagged_by' LIKE 'engine_add_pod%');
   IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
@@ -235,7 +235,7 @@
         ON sls.machine_id = ps.machine_id AND sls.shelf_id = ps.shelf_id
      WHERE ps.plan_date = p_plan_date
        AND ps.pod_product_id_in IS NULL
-       AND ps.reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16')
+       AND ps.reasoning->>'tagged_by' LIKE 'engine_add_pod%'
        AND ps.reason IN ('dead','rotate_out')
```

Everything else — SECURITY DEFINER, `SET search_path TO 'public'`, `#variable_conflict use_column`, all logic, formatting, comments — is byte-identical to the live body (verified with `diff`: exactly these 2 hunks).

Marker choice: `reasoning->>'tagged_by' LIKE 'engine_add_pod%'`. Audit of the live add body found no cleaner stable key — `tagged_by` is the only ownership marker add writes into dead-tag reasoning, and the `engine_add_pod` prefix is stable across v15→v19. This survives all future version bumps.

## Data counts (pod_swaps, live 2026-07-18)

`select reasoning->>'tagged_by', pod_product_id_in is null, reason, count(*), min(plan_date), max(plan_date) from pod_swaps group by 1,2,3;`

| tagged_by | in IS NULL | reason | count | plan dates |
|---|---|---|---|---|
| (null, legacy pre-v15) | false | dead | 175 | 05-12 → 06-09 |
| (null) | true | m2w | 51 | 05-12 → 06-12 |
| (null) | false | rotate_out | 41 | 05-12 → 06-09 |
| (null) | false | wind_down | 41 | 05-12 → 06-09 |
| engine_add_pod_v16 | false | dead | 30 | 06-11 → 06-14 |
| **engine_add_pod_v19_base_stock** | **true** | **dead** | **12** | **07-01 → 07-07** |
| engine_add_pod_v15 | false | dead | 7 | 06-10 |
| engine_add_pod_v16 | true | dead | 7 | 06-13 → 06-14 |

Read of the evidence:

- **Zero v18/v19 dead tags have ever been resolved** (`in IS NULL = false` count for v18/v19: 0; no v18 rows survive at all). The last resolved dead tags are v15/v16, plan dates 2026-06-10 → 06-14 — the pipeline severed exactly when add moved past v16 (PRD048, 2026-06-22), matching "the engine never swaps anymore".
- The 12 surviving v19 rows (07-01 → 07-07) are unresolved orphans; on every same-plan_date re-run, swap's opening DELETE destroys the fresh v18/v19 tags add just wrote (they fail the `IN ('...v15','...v16')` preserve clause), and any that survive a partial run are invisible to the dead-resolution loop.
- **Currently-unresolved dead tags the new filter would act on: 19** (`pod_product_id_in IS NULL AND tagged_by LIKE 'engine_add_pod%' AND reason IN ('dead','rotate_out')` = 12 × v19_base_stock + 7 × v16). All are on past plan dates; the engines run per plan_date, so these are evidence, not backlog — the fix takes effect on the next `build_draft_for_confirmed` run.

## Expected post-fix behavior

1. `build_draft_for_confirmed` runs add → swap. Add writes dead tags with `tagged_by='engine_add_pod_v18'`/`'engine_add_pod_v19_base_stock'`; swap's opening DELETE now **preserves** them (they match `LIKE 'engine_add_pod%'` with `pod_product_id_in IS NULL`).
2. The dead-resolution loop now **sees** them and resolves each via `rank_slot_suitability` (substitute swap-in) or marks m2w — `dead_tags_resolved` / `dead_tags_m2w` in swap's return jsonb become non-zero again for machines with dead slots.
3. Any future `engine_add_pod_vNN` bump can no longer sever the pipeline.
4. No behavior change to Pass 1 (strategic tags), Pass 2b (driver recs), Pass 3 (broad rotation), guards, caps, or drift handling.

## Verification plan (no engine runs)

1. **Pre-apply guard:** confirm live body unchanged since capture:
   `select md5(pg_get_functiondef(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='engine_swap_pod';` → must be `ce685e14b6164257fb52301cdf5c8e7a`. If not, re-pull and rebase the fix.
2. **Apply** `migrations/20260718034118_rc06_engine_swap_pod_version_agnostic_tags.sql` (via apply_migration, in a write-enabled session).
3. **Post-apply body inspection:**
   ```sql
   select p.proname,
          (select count(*) from regexp_matches(p.prosrc, $$tagged_by' LIKE 'engine_add_pod%'$$, 'g')) as agnostic_clauses,   -- expect 2
          (select count(*) from regexp_matches(p.prosrc, $$'engine_add_pod_v15','engine_add_pod_v16'$$, 'g')) as stale_clauses  -- expect 0
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname='engine_swap_pod';
   ```
   Also confirm attributes intact: `pg_get_functiondef` still shows `SECURITY DEFINER` and `SET search_path TO 'public'`.
4. **Read-only prediction of next-run behavior** (which rows the new loop filter would preserve/resolve, without running anything) — run for the next plan_date after add has drafted, or dateless for the historical view:
   ```sql
   select ps.plan_date, ps.machine_id, ps.reason, ps.reasoning->>'tagged_by' as tagged_by,
          (ps.reasoning->>'tagged_by' like 'engine_add_pod%') as new_filter_match,
          (ps.reasoning->>'tagged_by' in ('engine_add_pod_v15','engine_add_pod_v16')) as old_filter_match
     from pod_swaps ps
    where ps.pod_product_id_in is null and ps.reason in ('dead','rotate_out')
    order by ps.plan_date desc;
   ```
   Expect: every v18/v19 row shows `new_filter_match=true, old_filter_match=false` (as of 2026-07-18: 12 such rows; 19 total new-filter matches incl. 7 legacy v16).
5. **Next scheduled run (observation only):** swap's return jsonb should report `dead_tags_resolved + dead_tags_m2w + dead_tags_deferred_by_cap` equal to the number of dead tags add wrote for that plan_date, and v18/v19 rows for that plan_date should end with `pod_product_id_in` set or `resolved_as='m2w'`.
6. **Rollback if needed:** `migrations/rollback/20260718034118_rc06_rollback.sql` — verbatim pre-fix live body (diff-verified identical to the capture).

## Out of scope (deliberately untouched)

- engine_add_pod candidate-universe / slot_lifecycle issue (93 invisible shelves) — separate gated change.
- engine_add_pod's own version-pinned cleanup IN-list (currently complete through v19_base_stock; will need the same LIKE treatment at the next version bump — noted for the backlog).
- Repo history migrations carrying the stale strings (20260712155753 et al.) — superseded by this migration; history left untouched.
