# PRD-035 — Apply & Confirm Runbook

Paste-and-tick at apply time. Supabase `eizcexopcuoycuosittm`. Apply order: **A → C → B → D → E**.

**Replay pattern (validate without touching prod):** wrap the migration body + the VALIDATE block in a transaction and roll back:

```
BEGIN;
\i supabase/migrations/<file>.sql      -- or paste the migration's CREATE OR REPLACE here
-- <VALIDATE block for this phase>
ROLLBACK;                               -- replay only; nothing persists
```

When every box ticks, **apply for real**: run the migration (`supabase migration up` / commit), then re-run the read-only VALIDATE queries outside a transaction to confirm on prod.

> Note: Phase A's replay must test v24's NATIVE fallback, so it first **undoes yesterday's per-machine mapping workaround inside the same transaction** (re-activate the HUAWEI Healthy Cola / Hunter flavors and drop the JET Red Bull→Diet row). Because it's all inside `BEGIN…ROLLBACK`, the workaround is restored on rollback — prod is untouched.

---

## Phase A — stitch v24 flavor-aware fallback (rolled-back replay)

```
BEGIN;
-- 1) apply the migration
\i supabase/migrations/20260618093000_prd035_a_stitch_wh_aware_variant_fallback.sql

-- 2) undo yesterday's workaround so we exercise v24's NATIVE sibling fallback
UPDATE product_mapping SET status='Active'
 WHERE pod_product_id='35511de9-2980-4177-880c-7c1a9a625499'      -- Healthy Cola - Mix
   AND machine_id='9db7a821-d312-43b0-8e83-9642abfbfb0b'
   AND boonz_product_id IN ('07487368-7d4d-4b44-8e28-318677464f8f','e2e27132-6e27-4997-b8bb-2197b938fd1f'); -- Cola, Mix Berries
UPDATE product_mapping SET status='Active'
 WHERE pod_product_id='168aeb7e-fc0c-441b-94df-6d8cc185945d'      -- Hunter
   AND machine_id='9db7a821-d312-43b0-8e83-9642abfbfb0b'
   AND boonz_product_id <> '85a0a6ca-a7d7-463d-87c5-1dcc6a46b77c'; -- everything except Sea Salted
DELETE FROM product_mapping WHERE mapping_id='1128acfb-03fc-4487-b125-9349e3900d4f'; -- JET Red Bull->Diet machine row

-- 3) reopen the 3 hero shelves so stitch will re-resolve them
SELECT public.reset_approved_undispatched('2026-06-18',
  ARRAY['9db7a821-d312-43b0-8e83-9642abfbfb0b','a75f6648-9228-4638-937a-fab13348d5dd']::uuid[],'A-replay');
SELECT public.reopen_stitched_rows('2026-06-18',
  ARRAY['9db7a821-d312-43b0-8e83-9642abfbfb0b','a75f6648-9228-4638-937a-fab13348d5dd']::uuid[],NULL,'A-replay');

-- 4) dry-run stitch and inspect the heroes + substitution alerts
WITH s AS (SELECT public.stitch_pod_to_boonz('2026-06-18', true) AS j)
SELECT j->>'engine_version' AS version,
       (SELECT count(*) FROM jsonb_array_elements(j->'diagnostics') d
         WHERE d->>'machine_name' IN ('JET-1016-0000-O1','HUAWEI-2003-0000-B1')
           AND d->>'pod_product_name' IN ('Red Bull','Healthy Cola - Mix','Hunter')
           AND (d->>'quantity')::int > 0) AS heroes_filled,        -- expect 3+ (>0 each)
       jsonb_array_length(COALESCE(j->'substitution_alerts','[]'::jsonb)) AS sub_alerts, -- expect >=1
       (SELECT count(*) FROM jsonb_array_elements(j->'diagnostics') d
         WHERE d->>'stitch_result' LIKE 'resolved%' AND (d->>'quantity')::int=0
           AND d->>'comment' IS NULL) AS silent_zeros               -- expect 0
FROM s;
ROLLBACK;
```

- [ ] `version` = `v24_wh_aware_variant_fallback`
- [ ] `heroes_filled` ≥ 3 (Red Bull / Healthy Cola / Hunter each >0 via correct-or-sibling SKU)
- [ ] `sub_alerts` ≥ 1 and each substituted line carries a `[SIBLING-FALLBACK]` comment
- [ ] `silent_zeros` = 0
- [ ] other machines' lines unchanged vs v23 (spot-check a few non-hero shelves in `diagnostics`)

---

## Phase C — get_refill_session_readiness (read-only, safe to apply directly)

```
\i supabase/migrations/20260618094000_prd035_c_refill_session_readiness.sql
-- AC1-3: verdicts populate and known cases land correctly
SELECT verdict, count(*) FROM public.get_refill_session_readiness('2026-06-18') GROUP BY verdict ORDER BY 2 DESC;
SELECT pod_product_name, verdict, reason FROM public.get_refill_session_readiness('2026-06-18')
 WHERE pod_product_name ILIKE ANY (ARRAY['%barkthins%','%al ain%','%rice & corn%']);
-- AC4: zero writes (read-only)
SELECT proname, prosecdef AS is_definer, provolatile FROM pg_proc WHERE proname='get_refill_session_readiness';
```

- [ ] verdict column populated; counts look sane
- [ ] a quarantined/reserved flavor shows `cant_fill_*` / `can_fill_via_sibling` (not `can_fill`)
- [ ] an unmapped pod shows `cant_fill_unmapped`
- [ ] `is_definer = false`, `provolatile = s` (SECURITY INVOKER, STABLE → no writes)

---

## Phase B — engine_add_pod v18 relative-score fill (rolled-back replay)

```
BEGIN;
\i supabase/migrations/20260618095000_prd035_b_engine_relative_score_band.sql
SELECT public.engine_add_pod('2026-06-18') AS r;   -- idempotent; clears+rebuilds its own staging
-- inspect: fill should scale with relative rank, stance must not drive qty
SELECT m.official_name, (pr.reasoning->>'shelf_code') AS shelf,
       (pr.reasoning->'decision'->>'final_score')::numeric AS score,
       (pr.reasoning->'decision'->>'units_7d')::int AS u7d,
       pr.qty,
       pr.reasoning->'decision'->>'fill_band' AS band     -- new in v18
FROM pod_refills pr JOIN machines m ON m.machine_id=pr.machine_id
WHERE pr.plan_date='2026-06-18'
ORDER BY m.official_name, score DESC NULLS LAST;
ROLLBACK;
```

- [ ] `engine_version` returns v18
- [ ] top-score shelves get full cover; **low-score + empty shelves get the floor/low %**, not full
- [ ] any shelf with `u7d = 0` (and v30 = 0) → qty 0
- [ ] no stance term in the qty (a "DOUBLE DOWN" 0-sales shelf no longer fills high)

---

## Phase D — picker v10 + VOX calendar + Saturday-off (rolled-back replay)

```
BEGIN;
\i supabase/migrations/20260618096000_prd035_d_picker_vox_calendar_saturday.sql
-- Saturday -> no plan
SELECT public.pick_machines_for_refill('2026-06-20') AS sat;   -- 2026-06-20 is a Saturday; expect empty/none
SELECT count(*) AS sat_rows FROM machines_to_visit WHERE plan_date='2026-06-20';   -- expect 0
-- VOX day (Wed) -> all VOX + 2-3 non-VOX
SELECT public.pick_machines_for_refill('2026-06-24') AS wed;   -- next Wednesday
SELECT m.venue_group, count(*) FROM machines_to_visit mtv JOIN machines m ON m.machine_id=mtv.machine_id
 WHERE mtv.plan_date='2026-06-24' AND mtv.status IN ('picked','cs_added') GROUP BY m.venue_group;
ROLLBACK;
```

- [ ] picker function version = v10
- [ ] Saturday (2026-06-20): `sat_rows = 0` (no plan)
- [ ] Wednesday: all VOX venue machines present **+ 2–3 non-VOX** (or non-VOX-focused if VOX well-equipped per E2)
- [ ] picked set clusters by `venue_group` (E1) and pulls co-located P2 sisters (E4)

---

## Phase E — engine_swap_pod v11 score-driven Pass-3 (rolled-back replay)

```
BEGIN;
\i supabase/migrations/20260618097000_prd035_e_engine_score_driven_swap.sql
-- confirm the kill-switch exists and its default
SELECT * FROM refill_settings WHERE key ILIKE '%swaps_enabled%';   -- recommend default false
-- force-enable inside the txn to observe Pass-3 behaviour, then inspect
UPDATE refill_settings SET value='true' WHERE key ILIKE '%swaps_enabled%';
SELECT public.engine_swap_pod('2026-06-18') AS r;
SELECT m.official_name, (ps.reasoning->>'shelf_code') AS shelf,
       ps.reasoning->>'swap_pass' AS pass,
       (ps.reasoning->>'incumbent_score')::numeric AS incumbent,
       (ps.reasoning->>'candidate_score')::numeric AS candidate,
       ps.reasoning->>'relocation_candidate' AS relocate_flag
FROM pod_swaps ps JOIN machines m ON m.machine_id=ps.machine_id
WHERE ps.plan_date='2026-06-18' AND ps.reasoning->>'swap_pass'='3';
ROLLBACK;
```

- [ ] `engine_version` = v11; `swaps_enabled` exists (default OFF per our call)
- [ ] every Pass-3 swap has `candidate − incumbent ≥ 25` **and** `candidate ≥ 50` (B2)
- [ ] dropped incumbent is flagged `relocation_candidate` (B1)
- [ ] with `swaps_enabled=false`, Pass-3 produces no swaps (kill-switch verified — re-run the SELECT after a `SET value='false'`)

---

### After all five tick clean

Apply in order **A → C → B → D → E**, then run today's plan through the normal flow and confirm a refill end-to-end. Open follow-ups: (1) the Art-16 `v_wh_pickable` unification migration (do not half-migrate); (2) leave `swaps_enabled` OFF until Phase E proves itself over a few supervised cycles.
