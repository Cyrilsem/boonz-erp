# stitch_pod_to_boonz v19 rollback record (captured 2026-06-12, pre-v20)

- Live signature: `stitch_pod_to_boonz(p_plan_date date DEFAULT CURRENT_DATE+1, p_dry_run boolean DEFAULT true)`
- `pg_get_functiondef` md5: `16fb196b820c97a31b8cfccfdff84614`
- length: 32,354 chars
- engine_version string: `v19_driver_overlay_shelfguard`

Rollback path: redeploy the v19 body. The verbatim body is the one shipped by migration
`20260608124000_refillv2_stitch_driver_overlay_shelfguard.sql` (repo) and verified live
on 2026-06-12 with the md5 above. To roll back v20, re-apply that file's
`CREATE OR REPLACE FUNCTION` after confirming its md5 matches this fingerprint.

v20 diff surface (the ONLY allowed deltas, PRD-024 section 1):

1. `pull_raw`: `pm.mix_weight AS split_pct` -> `pm.split_pct AS split_pct`
2. `pull_norm`: `ELSE COALESCE(pnp.split_pct,0)` -> `ELSE COALESCE(pnp.split_pct,0)/NULLIF(total_split,0)`
3. `remove_phys_map`: `pm.mix_weight AS split_pct` -> `pm.split_pct AS split_pct`
4. `remove_phys_split`: `ELSE COALESCE(n.split_pct,0)` -> `ELSE COALESCE(n.split_pct,0)/NULLIF(total_split,0)`
5. deviation CTE `m_raw`: `pm.mix_weight AS split_pct` -> `pm.split_pct AS split_pct`
6. deviation CTE `n`: `ELSE COALESCE(np.split_pct,0)` -> `ELSE COALESCE(np.split_pct,0)/NULLIF(total_split,0)`
7. procurement CTE `pm_per_row`: reads `pm.split_pct` (drops the `COALESCE(NULLIF(pm.mix_weight,0),0.20)` heuristic),
   adds `prp.shelf_id` to the select list, and a new `pm_norm` CTE windows
   total_split/variant_n per (plan_date, machine_id, shelf_id, pod_product_id);
   `demand` consumes the normalized share.
8. dispatch comment copy: `remainder by mix_weight` -> `remainder by split_pct`
9. `engine_version`: `v19_driver_overlay_shelfguard` -> `v20_split_pct_normalize`
