# PRD-138: Drift close-out: VOX era migrations to git, era-aware repurpose eligibility

Status: DRAFT 2026-10-03, re-issued 2026-10-17 for the PRD-141 loop (WS-A now covers 7 prod-only migrations, see PRD-141 Block A)
Owner: CS
Builds on: PRD-075 WS-A (repurpose grace), PRD-073 (eligibility drift monitor), PRD-121 (build parity)
Window rule: WS-B touches `v_live_shelf_stock` / `v_shelf_sales_identity`, which feed
`auto_generate_refill_plan` and `compute_refill_decision`. Apply only inside the 22:00 to 06:00
Dubai window and before the next plan generation.
Hard rules: no em dashes. Every migration committed to main in the same run. Cody review on WS-B.
Fleet-diff proof in a rolled-back txn before apply. No new overloads.
CS answers to the open questions (17 Oct): min_sales 10 and min_days 3 stand. thin_history grades are shown in P1 with a badge, not held back.

## Why

The daily drift check has been RED on two signals:

1. **Prod-only migrations.** Four VOX era migrations applied 2026-09-28 via MCP have no file in
   `supabase/migrations/`. Git cannot rebuild prod's VOX reporting layer (`vox_sites` table, RLS
   policy, `vox_machine_eras`, `get_vox_sites`, and patched bodies of the three VOX report RPCs).
2. **Two trading machines invisible to P1.** `VOXDFC-1001-0100-V0` and `VOXDFC-2006-0200-B0` are
   Active, Online today, Live, and selling (17 and 57 successful sales in the last 7 days on 17 Oct),
   but `is_eligible_machine` is false on every shelf, so they are absent from
   `v_shelf_sales_identity` and every P1 surface until **2026-10-28**.

## Correction to the drift reports of 01 to 03 Oct

Those reports said the VOX backfill "stamped `repurposed_at` on machines that were never
repurposed" and called it the writer to fix. **That diagnosis was wrong.** Verified:

- None of the four VOX migrations writes `repurposed_at`. They only read it.
- Both machines were genuinely relocated on 28 Sep: `VOXMM-1001-0100-V0` (Mercato) to
  `VOXDFC-1001-0100-V0`, and `LLFP-2006-0000-C0` (event cabinet) to `VOXDFC-2006-0200-B0`, both now
  at Dubai Festival City. `repurposed_at` and `previous_location` are correct history and
  `chk_repurpose_consistency` rightly protects them.
- The hiding is by design: PRD-075 WS-A made eligibility
  `repurposed_at IS NULL OR repurposed_at < now() - repurpose_grace_days` (30). The grace exists
  so old-identity sales do not pollute a relocated machine's velocity. It does that by hiding the
  machine entirely for 30 days, which is too blunt for a machine that starts trading on day 1.

So signal 2 does not depend on signal 1. The fix is the eligibility rule, not the label or the
row. **Do not NULL `repurposed_at`.**

## Workstreams

### WS-A: Commit the four VOX migrations (no DB change)

Write each file under the exact applied version and name, body copied verbatim from
`supabase_migrations.schema_migrations.statements`:

| file | statements | chars |
|---|---|---|
| `20260928082000_vox_site_eras_dfc_20260928.sql` | 1 | 4,339 |
| `20260928082130_vox_machine_eras_exclude_pre_vox_20260928.sql` | 1 | 1,168 |
| `20260928102943_vox_sites_registry_dropdown_20260928.sql` | 1 | 3,728 |
| `20260928103012_vox_reports_null_pods_registry_sites_only_20260928.sql` | 1 | 814 |

Extraction (read-only), one row per file:

```sql
SELECT version, name, array_to_string(statements, E'\n') AS body,
       md5(array_to_string(statements, E'\n')) AS body_md5
FROM supabase_migrations.schema_migrations
WHERE version IN ('20260928082000','20260928082130','20260928102943','20260928103012')
ORDER BY version;
```

Write `body` to the file byte for byte (no reformatting, keep the trailing newline rule
consistent with the repo). Do not re-run them: they are already applied, and three of them are
anchor-patch DO blocks that would raise `anchor missing` on a second run by design.

Acceptance:
1. `md5` of each file's content equals `body_md5`.
2. Tomorrow's drift check reports 0 prod-only migrations post-baseline.
3. Single commit on main, pushed: `chore(migrations): commit VOX era migrations applied via MCP 2026-09-28`.

### WS-B: Era-aware repurpose eligibility (the real fix for signal 2)

**Rule change (Dara).** A repurposed machine leaves grace early once it proves it is trading at
the new identity. In `v_live_shelf_stock`:

```
is_eligible_machine =
  adyen_status = 'Online today'
  AND adyen_inventory_in_store = 'Live'
  AND ( repurposed_at IS NULL
        OR repurposed_at < now() - grace_days
        OR ( repurposed_at <= now() - min_days
             AND successful_sales_since(repurposed_at) >= min_sales ) )
```

New params on `pick_urgency_params`: `repurpose_min_days` (default 3),
`repurpose_min_sales` (default 10). Both machines clear this today.

**Velocity clip (Dara), the part that keeps the grace's original purpose.** In
`v_shelf_sales_identity` (and any consumer Cody finds that computes its own velocity window):

- only count sales with `transaction_date >= COALESCE(repurposed_at, '-infinity')`, so Mercato
  era sales for 1001 and LLFP event sales for 2006 never feed DFC velocity;
- denominator becomes `era_days = LEAST(30, GREATEST(1, days since repurposed_at))` instead of a
  flat 30, so a 5-day-old era is not diluted 6x;
- expose `era_days` and `thin_history = era_days < 14` so P1 surfaces can badge the grade as
  provisional.

**Cody review.** `v_live_shelf_stock` has 17 dependent views and 7 functions reading
`is_eligible_machine` (incl. `v_lane_grain`, `v_machine_priority`, `v_machine_health_signals`,
`compute_refill_decision`, `auto_generate_refill_plan`, `compute_scoreboard_day_v3`). Enumerate
which ones compute their own sales window and apply the same clip there, or document why not.

**Proof (rolled-back txn, before apply).** Full-fleet before/after diff of `is_eligible_machine`
and of every `v_shelf_sales_identity` column:
- only `VOXDFC-1001-0100-V0` and `VOXDFC-2006-0200-B0` flip to eligible;
- `ACTIVATEMOE-2007-0000-B0` (repurposed 30 Aug, relaunched 30 Sep, flags set to Online today / Live by hand on 16 Oct) stays eligible and its velocity window starts at relaunched_at;
- zero diffs on any machine with `repurposed_at` NULL or older than 30 days
  (NISSAN-0804, ACTIVATE-2005, MPMCC-1054, MPMCC-1058, IFLYMCC-1024, LVLUP-1018 unchanged).

Acceptance:
1. `v_machine_eligibility_drift` returns 0 rows.
2. Both machines have nonzero grade counts in `v_machine_priority`, with `thin_history = true`.
3. Next refill plan includes them without hand edits.

Rollback: set `repurpose_min_sales` to 999999 (restores pure 30-day grace, no migration). Prior
view bodies kept as `_HELD` files.

### WS-C: Stop the drift check crying wolf (small)

1. **Monitor label.** `v_machine_eligibility_drift` gains `drift_reason` values
   `in_repurpose_grace` vs `label_not_live`, so the report names the true cause. Update the
   drift routine prompt: a grace row is not label drift.
2. **Parity noise.** In the remote-migration parity step, add a same-version fallback match and
   a documented exception for the 2026-09-12 to 2026-09-15 consolidation window. This retires 63
   known-good rows that are re-cleared by hand every day.
3. **Stale lock.** End the drift run with a sweep that moves any `boonz-erp/.git/index.lock`
   left by its own `git status` (the run cannot delete) into `_to_delete/`.

## Sequence

1. WS-A now (any time, file-only). Commit and push.
2. WS-B tonight in the window: Dara spec, Cody consumer review, fleet-diff proof, apply,
   commit the migration on main in the same run.
3. WS-C with WS-B or the next day.
