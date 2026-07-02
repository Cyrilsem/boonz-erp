# PRD-023: VOX Dashboard Commercial Fixes

**Status: Shipped 2026-06-11 (prod + main; PRD-071 sweep verified 2026-07-02)** on branch `feat/prd-023-vox-commercial`. Backend (3 read-only RPCs) Cody-approved, applied, and parity-verified: all 6 ACs pass at the DB (commercial waterfall exact 36,940.00/36,389.40; 8 machines / ACTIVATE-2005 once; lines 36,940.00 / COGS 1,878.02; p_machine scope; OhmyDesk venue isolation; total_captured non-NULL). FE: ribbon bound to commercial waterfall + single-fetch on (period,pods); SKU "Line detail" CSV (UTF-8 BOM); Products machine dropdown; VOX dashboard Commercial tab mounted. Decisions: anon dropped (authenticated+service_role only); supply_source kept three-valued (Boonz/VOX/LLFP). Remaining: runtime smoke tests (ribbon tracks 3 consecutive period changes; both CSV exports; dropdown re-scopes) per the verification plan below.

Date: 2026-06-11. Owner: CS. Implements the 5 dashboard items + MAFE Finance (Aswathy) requests. Diagnostics verified live on BOONZ SUPA 2026-06-11 (full diagnostic in BOONZ BRAIN/VOX_Dashboard_Fix_Plan_2026-06-11.md).

## Context

Two surfaces consume VOX commercial data:

- Internal ERP: Commercial tab (cards, waterfall, Transaction Detail table with CSV button).
- VOX-team dashboard: restricted external app for MAFE, currently missing the Commercial tab.

Two RPCs power them: `get_vox_consumer_report` (green PAYMENT DEFAULT ribbon) and `get_vox_commercial_report` (cards, waterfall, Transaction Detail). They disagree by design and the ribbon does not re-fetch on period change.

## Problems (verified)

P1. Ribbon staleness: the green ribbon keeps the previous fetch's window when the period filter changes; only manual Refresh updates it.
P2. Ribbon definition drift: ribbon captured is gross of refunds (raw `adyen_transactions.captured_amount_value` + cash); commercial nets RefundedBulk. For 06 Feb - 30 Apr: 36,504.40 vs 36,389.40 and gap 435.60 (1.18%) vs 550.60 (1.49%). Delta is exactly the 115.00 AED refunds.
P3. Machine grouping uses historic `sales_history.machine_mapping` strings: renamed machines duplicate (ACTIVATE-2005-0000-W0 also appears as MPMCC-2005-0000-W0). `num_machines` counted 9 when 8 physical machines sold.
P4. Products aggregate is site-level only; no machine filter (blocks MAFE machine-level P&L).
P5. CSV export is transaction-level only, items concatenated into one string; no SKU-level rows, no per-line COGS (MAFE's "129 combined lines" complaint).
P6. VOX dashboard has no Commercial tab (promised to MAFE on 12 May).
P7. Hygiene: `get_vox_consumer_report.summary.total_captured` returns NULL (adyen_full CTE store_description/creation_date match misses); `pod_location` has both "Center" and "Centre" spellings for Mirdif.

## Non-goals

- VOX-sourced products (e.g. Aquafina, Ice Tea) correctly show Boonz COGS = 0: VOX supplies them and holds the cost on their side; we do not track it. Do NOT treat zero COGS as a missing mapping or backfill costs for these SKUs. The line-level CSV keeps 0; the export includes these lines in full so MAFE overlays their own costs.
- No rewrite of historical machine_mapping values on sales rows (orphan-name rule: historical rows keep old names).
- No change to share percentages, fee formulas, or the waterfall math.
- No new tables. Read-only RPC additions and patches only.

## Scope and acceptance criteria

### AC1. Single source of truth for the Commercial ribbon (P1, P2)

- The Commercial tab makes exactly ONE data fetch per (period, pods) state: `get_vox_commercial_report`.
- Ribbon binds: Total = `waterfall.total_amount`, Captured = `waterfall.captured_amount`, Gap = `waterfall.default_amount`, Default % = `waterfall.default_rate_pct`, matched = `matched_txns`/`txn_count`, discrepancies = count of `transactions[]` with `default_amount > 0`.
- Changing period or pod toggles re-fetches immediately; no value on screen can come from a different window than the cards.
- Acceptance test: for 2026-02-06 to 2026-04-30, Mercato+Mirdif, ribbon shows Total 36,940.00, Captured 36,389.40, Gap 550.60, Default 1.49%, 1592/1592 matched. Ribbon and cards identical for any window.

### AC2. Machine identity, not mapping strings (P3)

- Both RPCs group machine-level aggregates by `m.machine_id`, displaying `m.official_name`.
- `num_machines` = COUNT(DISTINCT machine_id with sales in window).
- Acceptance test: ACTIVATE-2005-0000-W0 appears exactly once for any window spanning 28 Apr; a window of 2026-02-06 to 2026-04-30 reports 8 machines.

### AC3. Products page machine filter (P4)

- `get_vox_consumer_report` gains `p_machine uuid DEFAULT NULL`; when set, all aggregates (products, daily, hourly, dow, etc.) are scoped to that machine.
- FE: dropdown at top of Products page: "All machines" + active VOX machines (label `official_name`, grouped by site). Selection passed server-side; no client-side slicing (feedback_fe_fetch_then_filter_rowcap).
- Acceptance test: selecting VOXMCC-1005 shows only its SKUs; revenue sum equals that machine's row in the machines aggregate.

### AC4. Line-level CSV export (P5)

- New RPC `get_vox_commercial_txn_lines(p_pods text[] DEFAULT ARRAY['Mercato','Mirdif'], p_date_from date, p_date_to date)`:
  - STABLE, SET TimeZone 'Asia/Dubai', same machine scope CTE (venue_group='VOX', status='Active'), joined on machine_id, same line filters as `get_vox_commercial_report` (exclude 'Smart fridge', exclude zero-amount baskets).
  - Returns one row per `sales_history` line: base_txn_sn, psp_reference, transaction_date, site, machine (official_name), pod_product_name, qty, unit_price, line_total, unit_cogs (vox_product_mapping.cost_incl_vat), line_cogs, supply_source ('Boonz' | 'VOX'), txn_captured, txn_default, txn_refunded, txn_status.
  - COMPLETENESS: the export contains EVERY line sold in the window, Boonz-sourced and VOX-sourced alike. Nothing filtered by supply source. VOX-sourced lines carry COGS 0 but full SKU/qty/price/machine detail. `supply_source` derives from the VOX-sourced product marker (venue-sourced = 'venue_team', see reference_source_of_supply_marker, or mapping-cost presence; implementer to confirm the canonical flag).
  - Txn-level money fields are repeated on each line (named txn\_\*); consumers must not SUM them across lines of the same txn.
- FE: the existing CSV button becomes a two-option menu:
  - "Transactions (current view)": serializes the already-loaded `transactions[]` (today's behavior, kept).
  - "Line detail (SKU level)": calls the new RPC for the current period+pods and downloads `VOX_Commercial_Lines_{from}_{to}.csv`, UTF-8 with BOM.
- Acceptance test: for 06 Feb - 30 Apr the line file covers 1,592 txns / 2,448 units; SUM(line_total) = 36,940.00; SUM(line_cogs) = 1,878.02; grouping by machine reproduces the by-machine totals shown in the UI.

### AC5. Commercial tab in the VOX dashboard (P6)

- Same Commercial component mounted in the VOX dashboard, gated by the VOX role.
- `p_pods` pinned server-side for VOX users (Mercato+Mirdif only); they cannot request other venues.
- EXECUTE granted to the VOX dashboard's role for `get_vox_commercial_report` and `get_vox_commercial_txn_lines` in the same migration.
- Ships only after AC1, AC2, AC4 are deployed (MAFE's first look must be clean).

### AC6. Hygiene (P7)

- Fix or remove `summary.total_captured` (NULL today); if kept, derive from the matched set rather than the store_description join.
- Normalize Mirdif `pod_location` spelling, or make site derivation tolerant by definition (it already ILIKEs '%Mirdi%'; normalize the data anyway).

## Constraints

- All backend changes go through Cody review before migration (read-only RPCs still touch protected query surfaces). Register new RPC in RPC_REGISTRY.
- New RPC is read-only; no writer changes anywhere in this PRD.
- Signature change to `get_vox_consumer_report` keeps existing call sites working: defaulted new param on a single function, do NOT create a second overload (PostgREST PGRST203 ambiguity) and do not drop the old signature without checking callers.
- No fetch-then-filter under row caps anywhere (feedback_fe_fetch_then_filter_rowcap).
- No em-dashes in any copy.

## Verification plan

1. SQL parity harness: for 3 windows (Feb-Apr, May, last 7 days) assert ribbon fields == waterfall fields, line-CSV sums == waterfall totals, machine counts == distinct machine_id.
2. FE: change period 3 times in a row without Refresh; ribbon must track every change (regression for P1's "2-3 trials" symptom).
3. Rename regression: window straddling 28 Apr shows ACTIVATE-2005 once with merged totals.
4. VOX-role pen test: attempt `p_pods => ARRAY['OhmyDesk']` from the VOX dashboard context; must be impossible or return empty.

## Rollout order

1. Backend: patch both RPCs (AC1 definitions, AC2, AC3 param, AC6) + new lines RPC (AC4) in one reviewed migration set.
2. FE ERP: ribbon single-fetch (AC1), machine labels (AC2), products dropdown (AC3), CSV menu (AC4).
3. VOX dashboard: mount Commercial tab + grants (AC5).
4. Email MAFE: access + the 9-machine Mirdif list (draft in BOONZ BRAIN/MAFE_Reply_Draft_Aswathy_2026-06-11.md).

## Reference numbers (2026-02-06 to 2026-04-30, Mercato+Mirdif)

total 36,940.00 | captured 36,389.40 | refunds 115.00 | default 550.60 (1.49%) | adyen fees 1,740.44 | net revenue 34,533.96 | boonz 20% 6,906.93 | boonz COGS 1,878.02 | vox net dues 25,749.01 | txns 1,592 | units 2,448 | machines with sales 8
