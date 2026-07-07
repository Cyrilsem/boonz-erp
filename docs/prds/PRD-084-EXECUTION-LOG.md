# PRD-084 Execution Log — Pre-pack drift guard (advisory shipped; block tier parked)

Run 2026-07-07, AUTO. **Phase 1 (advisory) SHIPPED** — read-only, non-protected, additive.
**Phase 2 (block) PARKED** — protected (writes include=false on refill_dispatching).
Engines byte-identical `c22b57e6`. Flag `prepack_guard`: advisory active; block not enabled.

## Shipped (advisory)

- `refill_qa.multi_sku_shelf` allowlist (seeded: AMZ-1029 A12).
- `refill_qa.check_prepack_drift(plan_date, machine_ids?)` — per dispatch line, planned pod
  vs live WEIMI resolution (v_live_shelf_stock JOIN shelf_configurations, slot_name =
  LEFT(shelf_code,1)||(SUBSTR(shelf_code,2)::int)::text, is_phantom=false). Classes
  ok/sku_mismatch/weimi_unresolved/allowed_multi_sku. Add New = intended (ok).

## T-tests

| Test                                            | Result                                                      |
| ----------------------------------------------- | ----------------------------------------------------------- |
| T1 sku_mismatch on Refill planned≠live          | PASS (synthetic + 2 real cases on 2026-07-06: A10, A12)     |
| T2 allowlisted shelf ⇒ allowed_multi_sku        | PASS (allowlisting clears the mismatch)                     |
| T3 unresolved slot ⇒ weimi_unresolved           | class implemented; 0 on 07-06 (WEIMI resolved that day)     |
| T4 Add New ⇒ ok (not flagged)                   | PASS                                                        |
| T6 plan output unchanged                        | PASS (read-only; no plan/dispatch write)                    |
| T5 block mode per-line include=false + override | **PARKED** (Phase 2, protected write to refill_dispatching) |

Real 2026-07-06: 93 ok / 2 sku_mismatch / 0 weimi_unresolved — the checker catches live
drift (the Case-13 pattern) with zero engine change.

## Parked (Phase 2 block — protected)

Setting include=false on sku_mismatch dispatch lines is a write to the protected
refill_dispatching. Requires: advisory→block promotion after an observation window +
per-line override + Cody sign-off. Advisory tier is the safe, shipped half.

## Status: SHIPPED (advisory). Block tier parked (protected).
