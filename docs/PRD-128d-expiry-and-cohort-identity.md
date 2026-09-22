# PRD-128d — Expiry identity and cohort-by-operating-model

**Owner:** CS
**Written:** reconstructed 2026-09-22 from migration comments and commit `d634366` (see
"A note on this document" at the bottom)
**Status:** shipped, live

---

## 1. Problem

Two independent defects surfaced on Machine Health at the same time and were fixed in the same
change, so they share one PRD number with a `d` suffix rather than a new PRD.

**Expiry identity.** `get_machine_slots_with_expiry` resolved `nearest_expiry_*` per physical
shelf, with no filter tying the result back to the lane's own `pod_product_id`. A shelf carrying
stale `v_machine_expiry_batches` rows from a since-replaced product surfaced that old product's
expiry instead of the current lane's. Live example: `AMZ-1038-3001-O1` A10 holds "Hunter Cans"
but reported nearest expiry "Zigi - Sea Salted" (a product no longer in that lane, with its own
stale batch rows still sitting on the same physical shelf); A11 holds "Krambals" but reported
"Nutella - Biscuit T3".

**Cohort identity.** `machine_cohort()` tested `service_model = 'partner_filled'` before
`operating_model = 'co_managed'`, so a co_managed machine that a partner venue fills
(`VOXMCC-1012-0100-V0`, `VOXMCC-1017-0200-V0`, `VOXMM-1001-0100-V0`) misfiled as `'partner'` when
it is a VOX-owned location. Confirmed live before the fix: `machine_cohort('co_managed',
'partner_filled') = 'partner'`.

## 2. Fixes

### 01. Expiry identity

`nearest_expiry_*` now resolves strictly from the lane's own `pod_product_id`, through
`product_mapping`, to every Active `boonz_product_id` it maps to — the same resolution shape
`v_current_price_filled`'s `resolved_mapping` CTE already uses for pricing, except pricing only
needs one representative flavour (`LIMIT 1`) while expiry needs every Active flavour a "mix" pod
product maps to (a "mix" pod product can map to several flavours; the batch physically nearest to
expiring could be any of them) — the same flavour-sum shape as PRD-127's `engine_add_pod` fix, not
a `LIMIT 1` pick. `shelf_min_batch_product` and `shelf_top_boonz` are both removed: the former was
the direct source of the bug, the latter had the identical defect one step removed (an unfiltered
shelf-level "top stock" pick fed to `compute_refill_decision`'s third argument). Verified
`compute_refill_decision`'s `p_boonz_product_id` argument is unused in its own body
(`prosrc ilike '%p_boonz_product_id%'` returns false), so passing it the lane's correctly resolved
product instead of an unfiltered pick changes nothing about that function's output —
`compute_refill_decision` itself is not modified.

### 02. Cohort by operating_model, plus two knock-on changes to `get_machine_health`

Cohort is now decided by `operating_model` alone: `partner_managed` -> `partner`, `co_managed`
-> `vox`, `fully_managed` -> `boonz`, `NULL` -> `unclassified`. `service_model` no longer
participates in the cohort decision at all. `p_service_model` stays in `machine_cohort`'s
signature (unused) so every existing call site (`get_machine_health`, `get_pod_refill_draft`, and
`check_machine_health_integrity`) keeps working unchanged — no overload, no signature break, per
the function-naming-gotcha rule in CLAUDE.md.

Two changes on `get_machine_health()` follow from this: `is_boonz_serviced` now reads
`service_model` directly (true only when `'boonz_filled'`), not
`machine_cohort(...) IN ('boonz','vox')` — the two questions are independent, cohort answers "who
owns this location," `is_boonz_serviced` answers "does Boonz staff need to visit and refill it,"
and a partner_managed-but-boonz_filled machine can be true on the second while displaying under
`'partner'` for the first. And a new `p_include_inactive boolean DEFAULT false` filters the row
set to `status = 'Active'` at source unless true; every existing zero-arg call site keeps working
unchanged via the default, and this is what makes the unclassified group disappear by default
(every unclassified machine had a NULL `operating_model` and was Inactive) without needing
separate unclassified-specific logic.

## 3. Acceptance criteria

| #   | Criterion                                                                                          |
| --- | -------------------------------------------------------------------------------------------------- |
| A1  | `get_machine_slots_with_expiry` keys `nearest_expiry` and lane sales on `pod_product_id`, not name |
| A2  | `machine_cohort` decides by `operating_model` alone                                                |
| A3  | `VOXMCC-1012`, `VOXMCC-1017`, `VOXMM-1001` are `vox`; the three LVLUP machines are `partner`       |

## Verified on 2026-09-22

**A1 — nearest_expiry and lane sales keyed on pod_product_id.** Pulled the live function body
with `SELECT pg_get_functiondef('public.get_machine_slots_with_expiry(text)'::regprocedure);` — it
is byte-for-byte identical to the migration file on disk. The relevant lines:

```sql
lane_boonz AS (
  SELECT ai.slot, ai.shelf_id, ai.machine_id, pm.boonz_product_id
  FROM aisles ai
  JOIN public.product_mapping pm
    ON pm.pod_product_id = ai.canonical_pod_product_id   -- keyed on pod_product_id
   AND pm.status = 'Active'
   AND (pm.machine_id IS NULL OR pm.machine_id = ai.machine_id)
  WHERE ai.shelf_id IS NOT NULL
),
```

`lane_min_exp`/`lane_min_batch` (which produce `nearest_expiry_days`/`nearest_expiry_qty`/
`nearest_expiry_boonz_product_id`) both join off `lane_boonz`, i.e. off the lane's own
`pod_product_id` resolution, never off a shelf-level product name. Lane sales:

```sql
LEFT JOIN lane_sales ls ON ls.machine_id = ai.machine_id AND ls.pod_product_id = ai.canonical_pod_product_id
```

Also keyed on `pod_product_id`. **PASS.**

**A2 — machine_cohort decides by operating_model alone.** Live body via
`SELECT pg_get_functiondef('public.machine_cohort(text,text)'::regprocedure);`:

```sql
CREATE OR REPLACE FUNCTION public.machine_cohort(p_operating_model text, p_service_model text)
RETURNS text LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_operating_model = 'partner_managed' THEN 'partner'
    WHEN p_operating_model = 'co_managed' THEN 'vox'
    WHEN p_operating_model = 'fully_managed' THEN 'boonz'
    ELSE 'unclassified'
  END;
$function$;
```

`p_service_model` is accepted but never referenced in the body. **PASS.**

**A3 — named machines' cohort.**

```sql
SELECT official_name, operating_model, service_model, machine_cohort(operating_model, service_model) AS cohort
FROM machines
WHERE official_name ILIKE 'VOXMCC-1012%' OR official_name ILIKE 'VOXMCC-1017%' OR official_name ILIKE 'VOXMM-1001%'
   OR official_name ILIKE '%LVLUP%'
ORDER BY official_name;
```

| official_name       | operating_model | service_model  | cohort  |
| ------------------- | --------------- | -------------- | ------- |
| LVLUP-1018-0000-G0  | partner_managed | boonz_filled   | partner |
| LVLUP-1048-0000-P0  | partner_managed | boonz_filled   | partner |
| LVLUP-2015-0000-R0  | partner_managed | boonz_filled   | partner |
| VOXMCC-1012-0100-V0 | co_managed      | partner_filled | vox     |
| VOXMCC-1017-0200-V0 | co_managed      | partner_filled | vox     |
| VOXMM-1001-0100-V0  | co_managed      | partner_filled | vox     |

All 6 match exactly. **PASS.**

## A note on this document

No `PRD-128d*.md` file existed anywhere in the repository or its git history before this one.
The change shipped under commit `d634366`, titled "fix: expiry identity and
cohort-by-operating-model on Machine Health" — it does not mention "128d" or "PRD" anywhere in its
subject or body, which is why no doc was ever written or found by a PRD-numbered search. This file
was reconstructed from that commit's message, the two migration files'
(`20260920184854_prd128d_01_expiry_identity.sql`,
`20260920185324_prd128d_02_cohort_by_operating_model.sql`) inline SQL comments, and the
`20260920190000_prd128d_00_rollback.sql` before-snapshot. Separately: those two migration files
were themselves renamed once already, by the repo-wide `96dd95a chore: reconcile
supabase/migrations filenames against applied migration history` commit — their original
commit-time names (`20260920190100_prd128d_01_...`, `20260920190200_prd128d_02_...`, from
`d634366` itself) do not match their current on-disk names, which now match the DB-applied
version exactly. That reconciliation evidently did not extend to the later prd129r and prd130
work, which is why the same drift reappeared and is being fixed again now, separately.
