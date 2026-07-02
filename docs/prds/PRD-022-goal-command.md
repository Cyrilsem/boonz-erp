# /goal — PRD-022 Procurement PO Experience v2 (<2500 chars)

Paste into Claude Code in the boonz-erp repo.

---

/goal Implement PRD-022 per `docs/prds/PRD-022-procurement-po-experience.md`. Objective: buying from /app/procurement becomes supplier-centric — click a supplier, a right-side drawer opens with a pre-filled editable basket, issue the PO from there, ordered rows grey out instantly, and open POs are editable in the same drawer.

STATE (do not redo): Procurement Brain v3 deployed (commit 168766e on main). get_procurement_demand v3 (on_order, ctx_multiplier, forecast_demand), get_procurement_demand_pod, supplier_products, demand_context_factors, blocked-product guardrail in create_purchase_order + edit_purchase_order_line, v_procurement_blocked_products, Demand sub-tabs (Pod/Boonz SKU) with supplier grouping live. RLS direct-write drop staged or applied (check migration phasef_proc_po_rls_writes_rpc_only status first).

RULES: Backend Constitution. NO new writers — all writes via create_purchase_order / edit_purchase_order_line / cancel_po_line. The ONLY new DB object is read-only `get_open_po_lines(p_supplier_id uuid DEFAULT NULL)` (class c, Cody fast-path, register in RPC_REGISTRY). Server-side filtering, no fetch-then-filter under PostgREST cap. No em dashes in copy.

BUILD ORDER:

1. D5 reader RPC get_open_po_lines (Dara shape check -> Cody -> apply).
2. D1 ordered-state: grey rows + "On order PO-xxxx" chip driven by on_order + get_open_po_lines; optimistic update on issue; ordered rows unselectable (explicit "order more" bypass).
3. D2 supplier drawer: per-supplier basket pre-filled from suggested_qty, box-snapped qty stepper w/ off-box confirm, price prefill from supplier_products, add-product search scoped to that supplier's Active supplier_products (blocked products never appear), Issue PO -> create_purchase_order atomic, inline per-line errors, localStorage basket persistence.
4. D3 "Open POs" drawer tab: list open lines, edit via edit_purchase_order_line (reason >=10 chars), cancel via cancel_po_line, age>7d chase badge.
5. D4 row-level "+" add-to-basket from Boonz SKU tab; unassigned SKUs route through set-supplier first.

DONE WHEN: all 6 acceptance criteria in the PRD pass (incl. zero direct purchase_orders writes from FE), typecheck + build clean, registries/CHANGELOG updated, committed on feat/prd-022-po-experience.

Start with step 1. Confirm the RPC shape with me before applying.
