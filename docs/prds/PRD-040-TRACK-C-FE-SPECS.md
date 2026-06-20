# PRD-040 Track C — FE Wiring Specs (Stax)

**Status:** Specs only. No FE code is built in this goal. Each spec is implementation-ready for a follow-up Stax session. Backend RPCs/tables referenced are live unless noted.

---

## C1 — PRD-034 Phase C: VOX returns read surface + FE

**Backend today:** `vox_return_log(vox_return_id uuid, dispatch_id uuid, machine_id uuid, boonz_product_id uuid, qty numeric, expiry_date date, source_of_supply text, received_by uuid, received_at timestamptz, reason text)` is live (PRD-034 A). The write path is `receive_dispatch_line` with the VOX no-WH-credit guard (PRD-034 B). **`get_vox_returns` does NOT exist** — build it.

### C1.1 New read RPC `get_vox_returns(p_date_from date, p_date_to date, p_machine_id uuid DEFAULT NULL)`

- **read-only**, `SECURITY INVOKER`, `LANGUAGE sql`, `STABLE`, no writes. (Cody class-c; INVOKER is sufficient — `vox_return_log` RLS already permits the operator read.)
- One row per `vox_return_log` entry joined for display: `machines.official_name`, `boonz_products.boonz_product_name`, `vox_return_id, dispatch_id, qty, expiry_date, source_of_supply, reason, received_at`, `received_by` resolved to `user_profiles` display name.
- Filters: `received_at::date BETWEEN p_date_from AND p_date_to`; optional `machine_id` scope; scoped to VOX venue machines (`machines.venue_group='VOX'`) to match the ledger's intent.
- GRANT EXECUTE to `authenticated, service_role`. Register in `RPC_REGISTRY.md` (read-only helpers).
- **Article 16 note:** does not re-derive a registered metric; it is a raw ledger reader. No inline WH/availability math.

### C1.2 FE — VOX Returns ledger view

- Location: VOX analytics area (next to the commercial/consumer reports), tab "Returns".
- Calls `get_vox_returns` via a new `/api/vox/returns` route (thin pass-through, same pattern as `/api/vox/commercial`). Date-range picker (default last 30d), optional machine filter.
- Table columns: Date, Machine, Product, Qty, Expiry, Source of supply, Reason, Received by. Footer totals: total returned units, distinct SKUs, distinct machines.
- Read-only surface. No mutation from this view (returns are written at receive time, not here).
- Acceptance: ledger totals reconcile with `SELECT sum(qty)` over the same window; VOX no-WH-credit invariant is visible (these returns did not credit WH).

---

## C2 — PRD-033 operator-flexibility FE wiring (RPCs live, FE not wired)

All four RPCs are live and Cody-approved (PRD-033). FE must route through them (Article 3 — no direct table writes). Signatures:

| RPC (live)                                                                                                                             | FE trigger                                                          | UX                                                                                                                                                                                                                               |
| -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reopen_stitched_rows(p_plan_date date, p_machine_ids uuid[], p_shelf_ids uuid[], p_reason text)`                                      | "Re-stitch selected" on the RefillPlanningTab WS-4 panel            | multi-select stitched rows -> confirm dialog with a required reason (>=10 chars) -> call RPC -> re-run `stitch_pod_to_boonz(date,false)` -> refresh. Refuses if any selected row's output is past `pending` (surface the error). |
| `release_wh_quarantine(p_wh_inventory_id uuid, p_reason text, p_verified_by uuid)`                                                     | "Release quarantine" on a quarantined WH batch row (warehouse view) | role-gated button (warehouse/operator_admin); reason >=10; optimistic refresh of `v_wh_pickable`-backed availability. No-op + toast on a non-quarantined row.                                                                    |
| `check_remove_without_replace(p_plan_date date)`                                                                                       | a pre-commit gate banner on the plan review screen                  | call on plan load; if `status='block'`, show the `flagged[]` shelves (REMOVE with paired ADD_NEW resolving to 0 pickable WH) and block the commit button until resolved or overridden.                                           |
| `convert_shelf(p_plan_date, p_machine_id, p_shelf_id, p_old_pod_product_id, p_new_pod_product_id, p_new_qty, p_return_mode, p_reason)` | "Convert shelf" action on a slot                                    | one dialog: pick new product, qty (clamped to post-removal headroom shown live from `v_shelf_capacity`), return mode (wh/return), reason. Replaces the old swap+add+edit dance.                                                  |

- All four: thin route + typed client fn; surface RPC errors verbatim (they carry the guard reasons). No client-side re-derivation of headroom/availability — read `v_shelf_capacity` / `v_wh_pickable` outputs.
- Acceptance: each RPC reachable from FE; protected writes go only through the RPC; the `check_remove_without_replace` gate blocks a constructed bad plan.

---

## C3 — Land `feat/prd-033-operator-flexibility` onto main + registry reconciliation

**Current state:** branch `feat/prd-033-operator-flexibility` carries, unmerged/unpushed, commits NOT on `main`: PRD-033 migrations (A-E) + registries (`cf3cd21`, `07f0944`), prd023i (`9469b95`), prd023j (`0386961`), Performance-tab FE (`1b0c2d4`). The 2026-06-20 prod-sync (`18bd34d`/`120f987`) deliberately did NOT carry PRD-033 / 023i / 023j registry entries to `main`. So `main` has PRD-034..039 but lacks PRD-033/023i/j.

**Plan (no code here; this is the landing procedure):**

1. **Verify prod-applied state** of each branch item (same precheck as the prod-sync): PRD-033 A-E in `schema_migrations`? prd023i/j RPCs live? Performance-tab is a pure FE change (no migration). Confirm before landing migration files.
2. **Rebase or merge** `feat/prd-033-operator-flexibility` onto current `main` (`120f987`+). Expect conflicts only in the 3 registry docs (main now has PRD-034..039 entries the branch lacks; branch has PRD-033/023i/j entries main lacks). Resolve by **union**: keep both sets of entries (append-only docs). Do NOT drop main's PRD-034..039 entries.
3. **FE conflicts:** the 4 `.tsx` files the prod-sync stashed (`prodsync-feat-wt-2026-06-20`) overlap the Performance-tab work — reconcile the stash with the branch FE before merge (the stash holds the working-tree edits made after the branch commits).
4. **Registry reconciliation:** after merge, `CHANGELOG`/`RPC_REGISTRY`/`METRICS_REGISTRY` should contain the full union (PRD-023i/j + 033 + 034..039). Verify no duplicate entries, no dropped entries.
5. **Migration ordering:** PRD-033 migrations are dated 2026-06-17 (before 034..039). On `main` they will sort BEFORE the 034..039 files already committed — fine for a fresh `supabase db push` against an empty DB, and inert against prod (already applied). Confirm filenames match the convention (no minute-75 bug).
6. **Land via PR** to `main`, not a force-carry. C3 is a git/merge exercise + registry union; it ships no new backend behavior (everything is already in prod).
7. **Wire C2 FE** (above) as part of or after this landing, since the PRD-033 RPCs become "documented on main" once the registry union lands.

**Risk:** the registry union is the only real conflict surface. Keep it append-only and verify with a grep that all PRD numbers (023i, 023j, 033, 034, 035, 036, 037, 039) appear exactly once per registry after merge.

---

## Out of scope (Track C)

- No FE code is written in this goal (specs only).
- `swaps_enabled` is not touched (that is Track D).
