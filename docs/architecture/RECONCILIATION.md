# RECONCILIATION — Cody conditions B1–B5 + CS S1/S2 → where closed

**Batch 1 · Project `eizcexopcuoycuosittm` · 2026-07-18 · DARA (finalized, NOT applied)**
Fast map for Cody's re-review. File names are in `/home/claude/boonz/batch1/final/`.

| # | Condition (short) | Closed how | Where (file · anchor) | Status |
| --- | --- | --- | --- | --- |
| **B1(a)** | ONE reconciled availability interface push binds; canonical name + RC-01-shaped return (`wh_inventory_id`, `expiration_date`, running/coverage) | Single fn `public.wh_fefo_for_line(...)` returns `wh_inventory_id, warehouse_id, expiration_date, running_pickable, net_running, covers_line, is_satisfiable`. No second signature. push binds it. | `20260718090001_rc08a…` A-4 · `20260718090002_rc01…` (III) pin block | ✅ closed |
| **B1(b)** | coverage/oversubscription nets outstanding WH-origin commitments by REUSING `v_dispatch_availability.reserved_by_earlier` (no fork) | `committed_elsewhere` uses the **identical** commitment CASE pulled live from `v_dispatch_availability` (WH-origin, unpacked, unpicked, not cancelled/skipped, `pack_outcome<>'not_filled'`, Refill/Add New); for a fresh pin the view's (all−same machine) net = other machines' live claims. push pins only when `is_satisfiable`. Two machines can't both pin one batch beyond stock. | `20260718090001_rc08a…` A-4 `committed` CTE + header note; `APPLY_ORDER.md §3e` cross-machine prediction | ✅ closed |
| **B1(c)** | explicit warehouse param so cold lines route to WH_CENTRAL, not the machine default; preserve push's current source-WH routing | `wh_fefo_for_line(..., p_warehouse_ids uuid[])`. push resolves per line: `cold → wh_central_id()`, else `v_primary_warehouse_id` (verified current push uses machine `primary_warehouse_id`; ambient stays primary-only). RE-ADDS the cold→central routing that dropped-Step-3 used to supply. VOX cold check in `APPLY_ORDER §3f`. | `20260718090002_rc01…` (III) `v_line_wh_id`; `20260718090001…` A-0 `wh_central_id()` | ✅ closed |
| **B2** | Article-16 registry rows for `wh_available`/`wh_available_qty`/`wh_fefo_for_line`; "builds ON `v_wh_pickable`", "consumes not duplicates `v_dispatch_availability`" | Three registry rows drafted with exactly those notes; to append to `docs/architecture/METRICS_REGISTRY.md`. | `METRICS_REGISTRY_edit.md` | ✅ closed (doc ready to append) |
| **B3** | `approve_refill_plan` owned by RC-01 only; RC-08 literal migration must NOT touch it; 8 sites, not 9 | RC-01 rewrites approve (drops Step-3 + its WH_CENTRAL literal). RC-08-B's de-magic `IN`-list EXCLUDES approve, hits exactly 6; receive/return (2) full-rewritten = 8 total. B-6 asserts `=6`; B-7 asserts `0` literals remain. `APPLY_ORDER §1d/§3c`. | `20260718090002_rc01…` (II); `20260718090003_rc08b…` B-6, B-7 | ✅ closed |
| **B4** | partial unique index IF NOT EXISTS, non-concurrent inline OK, header must say APPLY OFF-PEAK + mandatory pre-build 0-collision re-verify | Off-peak banner + embedded MANDATORY pre-check query in the file header; index is `IF NOT EXISTS`, non-concurrent. DARA re-ran 2026-07-18: **0 collisions / max mult 0**. | `20260718090002_rc01…` header + (I); `APPLY_ORDER §1b` | ✅ closed |
| **B5** | atomicity: RC-08 Migration A + RC-01 in one window; push's pin must not switch off inline logic until `wh_fefo_for_line` exists | W1 = A → RC-01 (A first), same off-peak window; `APPLY_ORDER §0` states it; RC-01 header states the dependency; `§1c` gates on the signature existing. push has no inline pin fallback left — it binds the fn, which A guarantees exists. | `APPLY_ORDER §0/§1c/§2`; `20260718090002_rc01…` header | ✅ closed |
| **S1** | never silently drop a refill line the route WH can't fill; stitch cutover WARN-ONLY (delta + procurement-gap + on-spot-accrual, qty unchanged); unfulfillable → substitute path; SEPARATE later CS-gated migration | Phase-2 file emits `stitch_route_fill_gap` (published_qty UNCHANGED, procurement_gap_qty + on_spot_accrual_qty + `substitute_candidate` flag). Batch-1 minimum = keep line + flag for swap engine (verified stitch has no existing substitute hook; auto-injection scoped as **RC-08-C follow-up**). File is separate, CS-gated, hard-guarded out of W1. | `20260718093000_rc08_consumer_cutover_stitch_warnonly.sql`; `APPLY_ORDER §0 W2/§5` | ✅ Batch-1 safe minimum closed; auto-substitution = follow-up RC-08-C (scoped, not over-reached) |
| **S2** | keep FE-direct push caller (RefillPlanReview.tsx:226) + repack_machine's push call; rely on idempotency index; explicit design choice; note Stax to verify FE payload dependency | RC-01 keeps all push entrypoints; idempotency = partial index (belt) + fixed preserve §5a/§5b (suspenders, incl. packed-twin). Stated as the explicit design choice in the RC-01 header. FE payload-dependency check for RefillPlanReview flagged as a Stax/FE task (below). | `20260718090002_rc01…` header (S2 block) | ✅ closed (+ 1 Stax FE note) |

## Follow-up tickets (explicitly scoped OUT of Batch 1, per "don't over-reach")

- **RC-08-C** — stitch auto-injects a substitute (via `rank_slot_suitability`) in-cycle
  when route fill = 0. Additive only (original line kept). Larger than Batch-1; PHASE-2+.
- **RC-08-B2** — give `receive_purchase_order` an explicit `p_warehouse_id` param and make
  `set_machine_warehouse`'s default primary explicit/required (vs. `wh_central_id()` default).
  Signature change → Stax coordination.
- **Stax / FE (S2)** — verify `RefillPlanReview.tsx:226` does not depend on push's return
  payload shape (push now returns `rpc_version='v10_rc01_single_writer'` + `dispatching_rows_present`
  from approve). DB-side unchanged contract; FE task only.

## Fidelity notes for Cody (so re-review is fast)

1. **`committed_elsewhere` mirrors the view without a warehouse filter** — same as the
   shipped `v_dispatch_availability` (which nets by product+date across machines, pairing it
   with a route-scoped `wh_stock_now`). This is faithful reuse and **conservative** (can only
   reduce availability → never oversubscribe). A warehouse-scoped tightening is a possible
   future precision knob, intentionally NOT taken in Batch 1 to honor "reuse, do not re-derive."
2. **Cold routing is a behaviour ADD to push, required by B5** — dropping approve Step-3 would
   otherwise regress cold→central routing (Step-3 supplied it). push now carries it, gated on
   `boonz_products.storage_temp_requirement='cold'` (same predicate approve Step-3 used).
3. **receive/return credit-target change** converts silent-WH_CENTRAL into a machine-derived
   resolution with a RAISE if unresolvable. Blast radius today = 0 (null_primary=0 in the
   active fleet). This is "never silently pick central."
4. **De-magic method (6 sites)** re-creates each function from its LIVE `pg_get_functiondef`
   with one deterministic replacement of the unique literal — safer than hand-transcribing
   large bodies against a lagging repo. B-6/B-7 assert 6-hit and 0-remaining.
