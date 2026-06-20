# PRD-040 Track C — Execution Log

**Date:** 2026-06-20
**Branch:** `feat/prd-040-track-c` (off `main`, rebased onto `4751fc9` at ship)
**Supabase:** eizcexopcuoycuosittm (ap-south-1)
**Outcome:** SHIPPED to main + prod. CS sign-off "ship C" 2026-06-20.

Scope: build the Track C FE wiring per `PRD-040-TRACK-C-FE-SPECS.md`, fold in CS's
stashed refill FE, and land the PRD-033 / Performance-tab work onto main additively.

## Hard rules honored

- `swaps_enabled` stays `false`; `engine_add_pod` / `engine_swap_pod` byte-identical (never touched).
- FE never writes a protected table directly. Every mutation routes through a live RPC (Article 3). Verified by grep: zero new `.insert/.update/.delete/.upsert` on protected tables across all edited files.
- `get_vox_returns` Cody-verdicted before use (read-only class-c, Approve).
- `stash@{0}` untouched. `stash@{1}` not dropped until ship.
- Forward-only. No em dashes.

## C0 — restored CS's stashed refill FE

Worked in an isolated git worktree (`boonz-erp-track-c`) to avoid disrupting the
concurrent session's dirty main working tree. Restored 4 FE files from `stash@{1}`
plus the untracked `FieldCapturePanel.tsx` (a dependency of refill/page.tsx, not in
the stash). The 3 stashed registry files were NOT taken from the stash — main's
current versions were kept (they carry PRD-034..040). Build green.

- `src/app/(app)/refill/RefillPlanningTab.tsx` (+312, PRD-019c `is_configured`)
- `src/app/(field)/field/packing/[machineId]/page.tsx` (+98, PRD-036 `v_dispatch_pickable`)
- `src/app/(app)/refill/page.tsx` (mounts FieldCapturePanel)
- `src/app/(app)/refill/consumers/client.tsx`
- `src/app/(app)/refill/FieldCapturePanel.tsx` (new, PRD-036 Phase B; writes via `log_manual_refill`)

## C1 — VOX returns surface (PRD-034 Phase C)

- **New RPC applied to prod:** `get_vox_returns(p_date_from date, p_date_to date, p_machine_id uuid DEFAULT NULL)`. Migrations `prd040_c1_get_vox_returns` + `prd040_c1_get_vox_returns_revoke_anon`.
  - `LANGUAGE sql, SECURITY DEFINER, STABLE, SET search_path=public, pg_temp`. One row per `vox_return_log` entry scoped to `machines.venue_group='VOX'`, joined to machine/product/received-by names.
  - **DEFINER (not the spec's INVOKER):** `user_profiles` RLS is own-row-only (`own_profile_select: id = auth.uid()`), so an INVOKER reader would NULL every staff name but the caller's, and VOX returns are received by staff, never the viewing operator. Mirrors the live `get_product_performance` precedent. Cody approved the exception.
  - **Signature is `p_machine_id uuid` (not the goal header's `p_venue text`)** — per the authoritative FE-SPECS doc C1.1.
  - anon EXECUTE revoked (Supabase auto-granted it at CREATE; the RLS-bypassing reader must not be callable pre-auth). Grants end: `authenticated, service_role`.
  - Verified in `pg_proc`: definer ✓, stable ✓, search_path pinned ✓, grants ✓. Smoke call returns 0 rows (no VOX returns logged yet).
- **FE:** `/api/vox/returns` thin service_role route + self-contained `VoxReturnsPanel.tsx` (date range default 30d, machine filter, totals). Mounted as an internal-role-gated "Returns" tab on the MAFE dashboard (`consumers/client.tsx`); hidden on partner (`hideInternalLinks`) mounts.
- Registered in RPC_REGISTRY (read-only helpers).

## C2 — wire 4 live PRD-033 RPCs in FE (no new RPCs, no DB change)

All four reached from FE via existing RPCs (Article 3). Guard reasons surfaced verbatim.

- `check_remove_without_replace(p_plan_date)` → hard pre-commit gate in `commitDraft` (evaluates the final post-edit plan; `status='block'` refuses unless Override ticked; flagged shelves + `pickable_units` shown). `RefillPlanningTab.tsx`.
- `reopen_stitched_rows(...)` → pending-view "Re-stitch machines" control. Machine-level (`shelf_ids=null` = all stitched shelves), reason ≥10, then `stitch_pod_to_boonz(date,false)` + reload. `RefillPlanningTab.tsx`.
- `convert_shelf(...)` → per-draft-row "Convert" modal. Product picker (reuses loaded `pod_products`), qty, return_mode (`wh/m2m/truck_transfer/unknown` — the RPC's real enum, not the spec's `wh/return`), reason; live shelf headroom from `v_shelf_capacity` (no client capacity math; RPC clamps). `RefillPlanningTab.tsx`.
- `release_wh_quarantine(...)` → "Release" action on `QuarantinedInventoryPanel.tsx` rows; reason ≥10; sets `provenance_reason='manual_adjust'` (never `status` — Article 6 safe); noop toast on a non-quarantined row.

## C3 — land PRD-033 / Performance-tab onto main additively

- Cherry-picked `1b0c2d4` (Performance tab FE — `app/products/page.tsx` + 2 `get_product_performance` migrations). Clean apply.
- Brought the 5 `prd033_a..e` migration files (objects all verified live in prod; inert lineage files).
- prd023i/j migration files were already on main (prior prod-sync). phaseF stitch v21 deliberately excluded (main already carries a later stitch via PRD-040 b4 v25).
- Registry union: added PRD-033 + product-performance sections to RPC_REGISTRY and a Track C CHANGELOG entry. Main's PRD-034..040 entries preserved (additions only). No in-scope METRICS change.
- Scope verified CLEAN: none of the branch's out-of-scope work (weimi, products overhaul, `triggers` junk, suppliers/tracker/orders) leaked. Only in-scope files landed.

## Verification

- `npx tsc --noEmit`: exit 0.
- `npm run build`: Compiled successfully (route manifest includes `/api/vox/returns`, `/refill/consumers`, `/app/products`).
- `npm run lint`: 142 problems / 93 errors = the repo baseline exactly; the five new/edited files carry zero lint findings.
- Component tests: none exist in this repo (no test framework, 0 `*.test.*`/`*.spec.*`). build + tsc are the standing verification bar.
- Preview deployed (Vercel, branch alias) and reviewed by CS before ship.

## Ship

- Rebased onto `origin/main` (`4751fc9`; concurrent session had pushed only automated `docs/DEPLOYMENTS.md` deploy-records — zero overlap).
- Fast-forwarded `main` to the branch and pushed. Vercel auto-deploys prod from main.
- `stash@{1}` dropped post-ship.

## Prod state after ship

- One new prod DB object: `get_vox_returns` (read-only, additive, Cody-approved). Everything else is FE.
- `swaps_enabled=false`; `engine_add_pod`/`engine_swap_pod` unchanged; `stitch_pod_to_boonz` v25 (unchanged); the 5 PRD-033 RPCs + `get_product_performance` were already live (this only landed their files + FE + registry entries).
