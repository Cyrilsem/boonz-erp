# PRD-039 Execution Log — Refill v4 Swap Value-Model

**Supabase:** eizcexopcuoycuosittm. `swaps_enabled` stays `false` until Phase 2. `engine_add_pod` v18 FROZEN throughout.

---

## Phase 0 — capacity matrix + affinity helper — APPLIED 2026-06-20

**Authorized by:** CS ("apply phase 0"). **Migrations (forward-only):**

- `prd039_p0_product_slot_capacity` (repo `supabase/migrations/20260620120000_prd039_p0_product_slot_capacity.sql`)
- `prd039_p0_get_candidate_affinity` (repo `supabase/migrations/20260620120100_prd039_p0_get_candidate_affinity.sql`)

### What was applied

- **`product_slot_capacity(physical_type, shelf_size, max_units, seed_source, created_at)`** — read-only reference table, PK (physical_type, shelf_size), CHECK shelf_size ∈ {Small,Medium,Large}, RLS enabled with single policy `psc_select` (SELECT to authenticated). No write policy (migration/owner only).
- **Seed = Option B (CS choice):** 33 observed cells = observed physical max per (physical*type, shelf_size) from `v_shelf_max_stock` on the live 14-value `boonz_products.physical_type` taxonomy. Chosen over the layout.md §4 crosswalk, which uses a stale 15-name taxonomy (no live analog for bottle_330/cake_wrapped/cup_yogurt/other; proxies for can_250/date_ball/bag*\*) and is monotonic-by-rule whereas live capacity is demand-driven (e.g. bag_snack Small 25 > Large 20).
- **`product_slot_capacity_units(text,text)`** — matrix-miss resolver (sql STABLE). Ladder: exact cell → nearest present size same type → bar_standard of size → 8. The per-slot override/shelf fallback chain stays in the engine (WS-B).
- **`get_candidate_affinity(uuid,uuid)`** — scoring-only Pearson helper (read-only DEFINER, STABLE). Mirrors `find_substitutes_for_shelf` basket_corr (per-machine correlation, loc-type fallback, COALESCE 0). NEW function; `find_substitutes_for_shelf` left untouched → PRD-037 R1 byte-identical.

### Post-apply prod confirms (read-only)

- `product_slot_capacity`: 33 rows, seed_source `observed_v_shelf_max_stock_2026_06_20`, RLS enabled, policy `psc_select` present.
- `product_slot_capacity_units` + `get_candidate_affinity`: present.
- **Coverage 42/42** non-null (14 live physical_types × {Small,Medium,Large}); 9 cells via resolver fallback.
- Affinity helper returns a sane co-purchase score (0.9175 on a known pair in pre-apply validation).
- `engine_swap_pod` = `v12_value_model` (unchanged), `engine_add_pod` = `v18_...` (frozen), `swaps_enabled` = `false`.

### Cody

- Phase-0 schema: **Approve** (Articles 2, 12, 14, 16). Read-only reference table + two read-only helpers; no protected-entity write path introduced; no registered metric re-derived inline.

### Tests (Phase-0 scope)

| Check                                               | Result                                |
| --------------------------------------------------- | ------------------------------------- |
| Coverage 14×3 resolves, 0 NULL, 0 non-positive      | PASS (42/42, 9 via fallback)          |
| Affinity parity vs find_substitutes basket_corr     | PASS (identical math by construction) |
| RLS read-only, no write policy                      | PASS                                  |
| engine_add_pod byte-identical / swaps_enabled false | PASS (neither touched)                |

### Open follow-ups

- **Article 16:** register "candidate basket affinity" in METRICS_REGISTRY with `get_candidate_affinity` as the canonical object; converge `find_substitutes_for_shelf` on it at its next change (closes the dual-definition gap without breaking R1).
- `product_family_id` backfill (Rule 2 family-keyed) — out of scope.
- True gross-profit margin — PRD-037 follow-up.
- 70/30 core/flex — PRD-038.

---

## Phase 1 — engine_swap_pod Pass-3 rewrite — APPLIED 2026-06-20

**Authorized by:** CS ("apply phase 1"). **Migration:** `prd039_p1_engine_swap_pod_v13` (repo `supabase/migrations/20260620130000_prd039_p1_engine_swap_pod_v13.sql`). Forward-only `CREATE OR REPLACE` on the canonical `engine_swap_pod` (same name + signature; NO parallel `_v13`). Pass-1 / dead-tag / Pass-2b reproduced byte-for-byte from v12 (labels bumped to v13); only Pass-3 rewritten (WS-A broad universe, WS-B candidate cap, WS-C greedy unique assignment, WS-D homogenisation K=3). Projection computed set-based for performance. **Latent v12 bug fixed:** Pass-3 `reason='score_swap'` violated `pod_swaps_reason_check` (dead path under swaps_enabled=false) → now `reason='rotate_out'` + `reasoning->>'source'='value_model_swap_broad'`.

### Post-apply prod confirms

- `engine_swap_pod` engine*version = `v13_value_model_broad`. `engine_add_pod` = `v18*...`(FROZEN, untouched).`find_substitutes_for_shelf`present + unchanged.`swaps_enabled`=`false`.
- Full-function smoke (BEGIN..ROLLBACK, swaps forced true, 2026-06-21): runs end-to-end (Pass-1/2b no-ops, Pass-3 = 10 score_driven_swaps), engine_version v13, 12s, rolled back — 0 pod_swaps / 0 confirmed_at left on prod.

**Replay** (BEGIN..ROLLBACK, swaps_enabled forced true, plan_date 2026-06-21 gate-clean, 8 machines, 10 swaps, ~8.7–12s, all rolled back):

| #   | Test                           | Result                                                                      |
| --- | ------------------------------ | --------------------------------------------------------------------------- |
| U1  | Broad-universe reachability    | PASS (2/10 winners at find_substitutes rank 11–12, outside v12 top-10 gate) |
| U2  | Affinity is a term, not a gate | PASS (3 winners with affinity ≤ 0.05 won on value)                          |
| C1  | Candidate-specific capacity    | PASS (10/10 caps from candidate physical_type × shelf_size)                 |
| C2  | Override respected             | PASS (1/1 swap on injected override aisle used cap=99)                      |
| A1  | Uniqueness                     | PASS (max dup pod/machine = 1)                                              |
| A2  | Assignment optimality          | PASS (greedy-by-marginal-value dominates worst-first; total V = 1122.45)    |
| H1  | Homogenisation                 | PASS (max 3 machines/product, fleet = 10 ≤ 10)                              |
| R1  | PRD-037 regression             | PASS (0 TCCC / 0 coexistence / 0 travel leaks; ≤2/machine)                  |
| T7  | Kill switch                    | PASS (swaps_enabled=false → 0 eligible machines → 0 Pass-3 swaps)           |
| T12 | ADD byte-identical             | PASS (engine_add_pod never referenced)                                      |

**Cody:** Pass-3 body **Approve** (Articles 1/4/5/12/16); the `score_swap→rotate_out` fix is a strict integrity improvement (Article 5). Non-blocking note: document that downstream `pod_swaps` consumers distinguish value-model swaps via `reasoning->>'source'` (dead path until P2).

### Open follow-ups (carried)

- **P2 (later):** flip `swaps_enabled` true after N supervised cycles of clean proposals on `/refill` (same gate as PRD-037 Phase 3). Pass-3 is a no-op until then.
- **Article 16:** register "candidate basket affinity" (canonical `get_candidate_affinity`); converge `find_substitutes_for_shelf` on it at its next change.
- `product_family_id` backfill (Rule 2 family-keyed); true gross-profit margin; 70/30 = PRD-038.
- Tunables seeded for replay: WS-A `v_cand_min_stock=3`, WS-C `v_top_n=10`, WS-D `v_K=3` — revisit during P2 supervised cycles.
