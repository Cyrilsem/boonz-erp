# Amendment 011 — `po_additions` and `purchase_orders`: Appendix A addition

**Date:** 2026-08-15 (PRD-022)
**Articles invoked:** 15 (declare invariants / Appendix A scope); references Articles 1, 2, 3, 4, 5, 7, 8, 12, 13
**Status:** ⚠️ DRAFT — proposed, not ratified. Requires CS signoff per Appendix C.

## Summary

PRD-022 makes `purchase_orders` and `po_additions` the system of record for what Boonz actually
paid. This amendment proposes adding both to the Appendix A protected-entity list and records the
constitutional posture as shipped, following the pattern of Amendments 003, 009 and 010.

## Proposed Appendix A addition

Add **`purchase_orders`** and **`po_additions`** to the protected entity list.

**Why they belong there.** Appendix A protects the entities whose corruption changes what the
business physically does or what it believes it is owed. These two are the ex-VAT cost spine:
`total_price_aed` on a received line is the number that flows into landed cost, COGS, every partner
settlement, and every margin figure the business steers by. `sales_lines` and `settlements` are
already on the list because they carry the revenue side; these carry the cost side of the same
ledger, and a wrong number here is arguably worse because it is silent — nobody complains about a
purchase price the way they complain about a sale.

The 2026-08-11 Union Coop incident is the concrete case. A pack total typed into a unit-price field
put roughly AED 23.6k of fiction on `po_additions`, and it was found by a human reading a bill, not
by any control. PRD-022 built the detection (`procurement_price_sync_and_flag`) and the closure
(`review_price_flag_v1`); Appendix A membership is what stops the write paths drifting back open
after the fact.

**`procurement_events` is NOT proposed for Appendix A.** It is an append-only ledger with no
consumer that changes behaviour — the same class as `engine_cutover_audit_v3` under Amendment 010
and `monitoring_alerts` under Amendment 009. It is covered by Article 7 (`proc_events_no_update` /
`proc_events_no_delete`, both `USING (false)`, verified live).

## Constitutional posture as shipped

| Article | Posture                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1       | `purchase_orders`: two caller-reachable INSERT writers, `create_purchase_order` and `add_purchase_order_lines`, disjoint by precondition — the standing "two INSERT writers is the ceiling" ruling (PRD-022 D3b) is untouched by this PRD. `_mirror_po_addition_line_v1` is definer-only (`{postgres=X,service_role=X}`). UPDATE writers: `receive_purchase_order`, `edit_purchase_order_line`, `cancel_po_line`, `correct_procurement_unit_price_v1`, `review_price_flag_v1`. `po_additions`: `create_po_addition_v2` (INSERT), `receive_purchase_order` (UPDATE). |
| 2       | RLS enabled on both. Verified live.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 3       | `purchase_orders` ✅ — `authenticated` holds SELECT only; no INSERT/UPDATE/DELETE policy exists. `po_additions` ⚠️ — `field_staff_insert` and `warehouse_update` still grant direct writes. **This is the one open gap, and it is scheduled**: `_HELD_prd022_po_additions_rpc_only.sql` drops both after a one-week clean soak (earliest 2026-08-22). Ratification of this amendment should follow that migration, not precede it.                                                                                                                                  |
| 4       | Every writer is SECURITY DEFINER, pins `search_path`, sets `app.via_rpc` + `app.rpc_name` via `set_write_context`, validates inputs, and validates role against `user_profiles`.                                                                                                                                                                                                                                                                                                                                                                                    |
| 5       | `pricing_status` is a state machine: `free_goods` is writable only by `create_po_addition_v2` and `receive_purchase_order`; `unpriced` is system-assigned by the trigger and refused as an RPC input. A column-level `REVOKE UPDATE` keeps `pricing_status` and `price_flag` out of `authenticated`'s reach on `po_additions` regardless of policy — this was Cody's binding revision, because the RLS policy alone would have left an unaudited flag-clearing path open.                                                                                           |
| 7       | `write_audit_log` and `procurement_events` both block UPDATE and DELETE at the policy layer. Verified live before adding new write sources into them.                                                                                                                                                                                                                                                                                                                                                                                                               |
| 8       | ⛔ **Known gap, pre-existing, not introduced here.** `purchase_orders` has **no `audit_log_write` trigger**, so Article 8 coverage is per-writer and manual. `create_po_addition_v2`, `review_price_flag_v1`, `correct_procurement_unit_price_v1` and `_mirror_po_addition_line_v1` each write their own row; **`receive_purchase_order` does not** — it writes `procurement_events` only. Closing this is the natural next unit and is called out here so it is not rediscovered as new.                                                                           |
| 12      | All six migrations forward-only and idempotent (`add column if not exists`, guarded constraint adds, backfills that filter on the state they write).                                                                                                                                                                                                                                                                                                                                                                                                                |
| 13      | ⛔ **Unenforceable as configured.** `track_functions` is off, so `pg_stat_user_functions.calls` is NULL for every function project-wide — the 90-day zero-call window cannot be measured on any object. The 7-arg `create_po_addition_v2` drop was waived on static evidence and recorded in `deprecated.md`. **Enabling `track_functions` should be a condition of ratifying this amendment**, because Appendix A membership without a working deprecation instrument is a rule with no enforcement.                                                               |
| 14      | No snapshot tables. `v_po_price_flags` is a view. No ADR required.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 16      | `v_po_price_flags` is the canonical object for "which purchase lines have an open price flag". Register it in `METRICS_REGISTRY.md` at ratification.                                                                                                                                                                                                                                                                                                                                                                                                                |

## Ratification conditions

Recommended order, so the amendment describes a state that is actually true when it merges:

1. Apply `_HELD_prd022_po_additions_rpc_only.sql` after the soak — closes the Article 3 gap.
2. Enable `track_functions = 'pl'` — makes Article 13 enforceable.
3. Add an `audit_log_write` trigger to `purchase_orders`, or accept the per-writer posture
   explicitly in the amendment text — closes or formalises the Article 8 gap.
4. Register `v_po_price_flags` in `METRICS_REGISTRY.md`.
5. CS signoff, then merge and update the Appendix A list in `01_constitution.html` and the
   protected-entity list in `.claude/skills/cody/SKILL.md`.

Ratifying before step 1 would put two entities on Appendix A while one of them still accepts direct
`authenticated` writes, which is the posture Article 3 exists to forbid.
