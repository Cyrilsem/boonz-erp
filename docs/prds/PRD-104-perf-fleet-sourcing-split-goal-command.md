# PRD-104 — Product Performance: Boonz Sourcing vs Partner Sourcing (goal-command for Claude Code)

## Problem (proven 2026-07-20)
The Products → Performance tab fleet filter split machines into "Non-VOX fleet" vs
"VOX cinemas" using a name-prefix test only: `upper(official_name) LIKE 'VOX%'`.
VOX-venue machines are NOT all named `VOX*` — the venue also runs machines named
`ACTIVATE-*`, `ACTIVATEMCC-*`, `IFLYMCC-*`, `MPMCC-*`. Those all fell through to the
"Non-VOX" bucket, skewing it badly:
- Aquafina is sold **only** on VOX-venue machines, yet ranked **#1 under Non-VOX**
  (2,774 units / 6wk) because its top seller `ACTIVATE-2005` (1,299 units) was
  mis-classified as non-VOX.
- The LVL UP gym pilot machines (`LVLUP-*`, venue_group `LVLUP`) were also lumped
  into the Boonz bucket, though they are partner-sourced.

CS wants the two buckets renamed to reflect **who sources the stock** and the
classification corrected so partner venues land in the partner bucket.

## Fix (already applied to production DB on 2026-07-20 — this goal-command records
## it and pushes the repo/FE to match)

### 1. RPC — `get_product_velocity_ledger(p_weeks, p_scope, p_level)`
Scope **values stay** `non_vox` / `vox` (no caller changes). Only the classification
inside the `raw` CTE changes. Partner-sourcing predicate:

```sql
upper(COALESCE(m.venue_group,'')) IN ('VOX','LVLUP','LEVELUP')
OR upper(m.official_name) LIKE ANY (ARRAY[
     '%ACTIVATE%','%IFLY%','%VOX%','%MPMCC%','%LVLUP%','%LEVELUP%'
   ])
```
- `p_scope='vox'`  (Partner Sourcing) → rows where the predicate is TRUE.
- `p_scope='non_vox'` (Boonz Sourcing) → the complement (`NOT (...)`).
- `venue_group` is the canonical field; the name-contains clause is a belt-and-suspenders
  guard for machines whose venue_group is not yet set.
- `CREATE OR REPLACE` — idempotent, safe to re-run.

Migration: `boonz-erp/supabase/migrations/20260720120000_prd087_perf_partner_sourcing_classification.sql`
Applied live via Supabase MCP as `prd087_perf_partner_sourcing_classification` on project
`eizcexopcuoycuosittm` (BOONZ SUPA, ap-south-1).

### 2. FE — `boonz-erp/src/components/performance/ProductPerformanceTab.tsx`
`SCOPES` labels only (values untouched):
- `non_vox` → **"Boonz Sourcing"** (was "Non-VOX fleet")
- `vox` → **"Partner Sourcing (VOX · LVLUP)"** (was "VOX cinemas")

## Not a regression — mixed shelves correctly appear in BOTH buckets
Chocolate Bar, Coca Cola Mix, Soft Drinks Mix still show under Boonz Sourcing. That is
**correct** — unlike Aquafina, these genuinely sell on Boonz-sourced machines too.
Verified 2026-07-20 that the Boonz bucket for each contains **zero** partner machines:
- Chocolate Bar: 822u / 20 Boonz machines here; 204u / 5 VOX machines moved to Partner.
- Coca Cola Mix: 547u / 7 Boonz; 2u / 1 LVLUP machine moved to Partner.
- Soft Drinks Mix: 299u / 10 Boonz; 28u / 3 VOX machines moved to Partner.

## Task for Claude Code
1. Confirm the two files above exist in the working tree with the described changes
   (they were written on 2026-07-20; if a fresh clone, apply the changes from this PRD).
2. Confirm the live function matches — run:
   `SELECT product_name FROM get_product_velocity_ledger(6,'non_vox','pod') ORDER BY avg_per_week DESC LIMIT 3;`
   → must NOT contain Aquafina. And `...('vox'...)` → Aquafina #1. If the DB does not
   match (fresh env), apply the migration via `supabase db push` / MCP `apply_migration`.
3. `npx tsc --noEmit` must pass.
4. Commit both files on `main` and push (triggers Vercel prod deploy for the FE labels):
   `git add boonz-erp/src/components/performance/ProductPerformanceTab.tsx boonz-erp/supabase/migrations/20260720120000_prd087_perf_partner_sourcing_classification.sql`
   `git commit -m "feat(perf): fleet split → Boonz Sourcing vs Partner Sourcing (VOX+LVLUP) [PRD-104]"`
   `git push origin main`
5. Confirm the Vercel deployment goes green and the Performance tab shows the new labels.

## Acceptance
- Performance tab dropdown reads "Boonz Sourcing" and "Partner Sourcing (VOX · LVLUP)".
- Under Boonz Sourcing, Aquafina is absent; top rows are Chocolate Bar / Snack Bar / Al Ain Zero.
- Under Partner Sourcing, Aquafina is #1; the 14 VOX+LVLUP machines are the only ones present.
- `sum(total_units)` for non_vox + vox == all (exact partition; verified 6,687 + 5,557 = 12,244).
- `tsc` clean; Vercel prod deploy green.

This is a read-only reporting RPC (STABLE, SECURITY DEFINER, no writes, no protected-entity
mutation) plus a label rename — low risk. Cody review optional/informational.
