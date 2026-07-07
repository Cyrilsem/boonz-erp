# PRD-082: Separate planned vs filled quantity

Status: SHIPPED DARK 2026-07-07 (qty_split_v1=off; pack_dispatch_line flag-gated quantity/filled split; Cody PASS; Family A unchanged). Enable/backfill/FE parked. See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Stax + Dara, Cody reviews.

## Why

Audit cause K / field bugs 1/6. `edit_dispatch_qty` commits cleanly but `pack_dispatch_line` then `SET quantity = v_total_picked` and spawns child rows, collapsing planned vs filled onto one column; `edit_dispatch_qty` also hard-blocks `item_added`. PRD-044 added partial/skip outcomes and `filled_quantity`/`pack_outcome`; the residual is that `quantity` (planned) is still stomped by pack.

## Design (Dara designs, Cody reviews, Stax wires)

1. **Reader audit (FR-gate):** enumerate every reader of `refill_dispatching.quantity` (FE, `stitch_pod_to_boonz`, statement-of-account/settlement, dashboards, n8n); classify planned vs packed. Repoint "packed" readers to `filled_quantity`. **Verify settlement output unchanged on a sample period (billing must not move).**
2. **`pack_dispatch_line`:** stop writing `quantity`; write `filled_quantity` + `pack_outcome` only; child rows keep `filled_quantity`; assert `SUM(filled) ≤ quantity`.
3. **`edit_dispatch_qty`:** remove the `item_added` hard block (keep role checks + edit log).
4. **Backfill:** restore planned `quantity = original_quantity` where pack overwrote it and `original_quantity` exists; else flag manual-review.

## Gates

- **Reader repoint MUST land before flipping pack semantics.** Settlement/statement byte-unchanged on a sample. Engines md5 byte-identical. Diff = plan output unchanged. Conservation green (units now reconcile). Cody signs. Flag `qty_split_v1`.

## T-tests

- T1 edit 9→7, pack 7 ⇒ `quantity=7`, `filled=7`.
- T2 pick across 2 batches ⇒ parent `quantity` intact, children filled sum correct.
- T3 edit on `item_added` line ⇒ succeeds.
- T4 partial + not_filled keep `quantity`.
- T5 settlement/statement unchanged on sample.
- T6 conservation green; T7 diff plan unchanged.

## CLOSE

CHANGELOG + registry; PRD-082 SHIPPED + EXECUTION-LOG; commit + push. Rollback = revert both RPCs + flag off (backfill idempotent).
