# PRD-084: Pre-pack drift guard (monitor → block)

Status: PARKED 2026-07-07 (prior art verified live; blocked on referee candidate-capture / branch-data — see EXECUTION-LOG).
Owner: CS. Mode: AUTO with hard gates. Dara + Stax, Cody reviews.

## Why

Audit Case 13 / Cause I; 07-Jul log Section A (McVities→AMZ-1038 A01, YoPRO→AMZ-1057 A01, Hunter→AMZ-1068 A09 all dispatched wrong). Root cause: WEIMI non-resolution → stale-planogram fallback. PRD-057 monitors drift; there is no automatic pre-pack gate, so it still relies on a manual sweep.

## Design (Dara designs, Cody reviews, Stax wires)

1. **`check_prepack_drift(plan_date, machine_ids?)`** — per dispatch line: planned pod/boonz SKU vs live WEIMI resolution (`v_live_shelf_stock` JOIN `shelf_configurations`, slot_name = `LEFT(shelf_code,1)||(SUBSTR(shelf_code,2)::int)::text`, `is_phantom=false`). Classify `ok | sku_mismatch | weimi_unresolved | allowed_multi_sku`. An intended engine swap (Add New from a swap) is NOT drift.
2. **`multi_sku_shelf`** allowlist (seed known soft-drink/multi-SKU shelves, e.g. AMZ-1029 A12).
3. **Wire** after stitch / into pack-readiness. Phase 1 advisory (surface + log); phase 2 (`prepack_guard=block`) set `include=false` on `sku_mismatch` lines pending operator override(reason). Per-line only, never whole-machine.

## Gates

- Reuse PRD-057 monitor definitions where possible (don't fork). Engines md5 byte-identical; plan output unchanged (guard acts on dispatch). Advisory before block. Whitelist prevents false positives. Cody signs. Flag `prepack_guard` (advisory|block|off).

## T-tests

- T1 reproduce the 3 log cases ⇒ each `sku_mismatch`.
- T2 soft-drink shelf ⇒ `allowed_multi_sku`.
- T3 unresolved slot ⇒ `weimi_unresolved`.
- T4 intended engine swap ⇒ `ok` (not flagged).
- T5 block mode sets include=false per-line + override; never whole-machine.
- T6 diff = plan output unchanged.

## CLOSE

CHANGELOG + registry; PRD-084 SHIPPED + EXECUTION-LOG; commit + push. Pairs with the AMZ planogram→WEIMI reconcile data task. Rollback = advisory/off.
