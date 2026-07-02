# /goal — PRD-023 VOX Dashboard Commercial Fixes (<2500 chars)

Paste into Claude Code in the boonz-erp repo.

---

/goal Implement PRD-023 per `docs/prds/PRD-023-vox-dashboard-commercial-fixes.md`. Objective: the Commercial tab's green ribbon, cards and CSV all tell one story; machine counts are real; MAFE gets a Commercial tab in the VOX dashboard plus an SKU-level CSV for machine P&L.

STATE (verified 2026-06-11, do not re-diagnose): ribbon = get_vox_consumer_report (stale on period change + gross of refunds, Δ exactly 115.00 vs commercial for 06Feb-30Apr), cards = get_vox_commercial_report. Machine aggs group by historic machine_mapping so renamed machines duplicate (ACTIVATE-2005 also as MPMCC-2005). 11 Active VOX machines (2 Mercato + 9 Mirdif). VOX-sourced SKUs (Aquafina etc.) legitimately have COGS 0 — never backfill.

RULES: Backend Constitution. Read-only changes only — NO writers, no DELETEs, no direct table writes. The ONLY new DB object is read-only `get_vox_commercial_txn_lines(p_pods, p_date_from, p_date_to)` (Cody review, register in RPC_REGISTRY). Patches to the two report RPCs also go through Cody. Keep get_vox_consumer_report as ONE function with a defaulted new param (no overload, PGRST203). Server-side filtering, no fetch-then-filter. No em dashes in copy.

BUILD ORDER:

1. Backend migration set (Cody -> apply): (a) commercial RPC machine aggs by machine_id + official_name; (b) consumer RPC: refund netting (mirror RefundedBulk join), machine_id grouping, num_machines = distinct machine_id, add p_machine uuid DEFAULT NULL, fix NULL total_captured; (c) new lines RPC: one row per sales_history line, ALL lines (Boonz + VOX sourced), unit_cogs from vox_product_mapping (0 for VOX-sourced), supply_source col, same filters as commercial RPC; (d) GRANT EXECUTE on the three RPCs to the VOX dashboard role. Verify vs PRD reference numbers before FE work.
2. ERP Commercial tab: delete the consumer-report fetch; bind ribbon to waterfall fields (AC1 map); period/pods in fetch deps.
3. CSV button -> menu: "Transactions (current view)" (existing) + "Line detail (SKU level)" via new RPC, VOX*Commercial_Lines*{from}\_{to}.csv, UTF-8 BOM.
4. Products page: machine dropdown (All + active VOX machines by site, official_name), p_machine server-side. Machine labels everywhere from official_name.
5. VOX dashboard: mount Commercial tab behind VOX role, p_pods pinned server-side to Mercato+Mirdif.

DONE WHEN: all 6 ACs pass incl. parity harness (ribbon == cards for 3 windows; line CSV sums == waterfall: 36,940.00 / COGS 1,878.02 for 06Feb-30Apr; ACTIVATE-2005 appears once; VOX role cannot reach other venues), typecheck + build clean, registries/CHANGELOG updated, committed on feat/prd-023-vox-commercial.

Start with step 1. Show me the migration draft and Cody's verdict before applying.
