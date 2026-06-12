# PRD-028 WS2 - Machine velocity rollup design note (Dara)

**Date:** 2026-06-12 · **Status:** Proposed, pending Cody review · **Driver:** METRICS_REGISTRY.md row "Machine velocity"

## Current implementations (3 found, measured 2026-06-12)

1. `get_machine_health.with_velocity`: `SUM(sh.qty)/7` over `now() - 7 days`, `delivery_status IN ('Success','Successful')`. Rolling anchor.
2. `v_machine_health_signals.sales_recent.units_last_7d`: `SUM(qty)` over `CURRENT_DATE - 7 days`, **no status filter**. UTC-midnight anchor. Feeds `v_machine_priority` thresholds (5/20/30/50/70) and runway_days.
3. FE Stock Snapshot cards: display `get_machine_health.daily_velocity` (no recompute). `get_sales_by_machine(lookback_days)` is a variable-lookback SALES REPORT (revenue/qty totals), not this metric - out of scope.
4. `flag_intent_threats` v7/v60: product-grain scoped velocity (decommission threats) - registry says slot/product grain stays; out of scope.

## Design

### `v_machine_velocity` (NEW, canonical machine-grain velocity)

```sql
SELECT machine_id,
       units_7d,            -- SUM(qty), Success only, transaction_date >= now() - 7d
       units_30d,           -- same, 30d
       daily_velocity_7d,   -- units_7d / 7.0 (full precision; consumers round)
       daily_velocity_30d   -- units_30d / 30.0
FROM sales_history ...
```

Decisions:

- **Success filter everywhere** (`delivery_status IN ('Success','Successful')`). Live check: all rows in the last 30 days are 'Successful', so this is a no-op today but correct going forward.
- **Rolling `now() - interval` anchor** (not CURRENT_DATE midnight): matches get_machine_health exactly (AC: its daily_velocity == canonical, zero drift), and UTC-midnight anchors are the same disease class as the plan-date bug.
- Machines with no sales in 30d have no row; consumers COALESCE 0.

### Rewires

- `get_machine_health.with_velocity.daily_velocity` -> scalar subselect on the view (formula identical: values unchanged). Function also gains `SET search_path = public, pg_temp` (same Cody Article 4 revision as WS1; it is SECURITY DEFINER without it).
- `v_machine_health_signals.sales_recent` -> LEFT JOIN the view, `units_last_7d = COALESCE(units_7d, 0)`. Outer expressions untouched.
- `daily_revenue` in get_machine_health is a REVENUE metric (60d), not velocity - untouched, candidate for its own registry row later.

## Before/after

- get_machine_health.daily_velocity: **identical** for all machines (same formula, same filter, same anchor).
- signals.units_last_7d gains the Success filter (no-op today) and moves CURRENT_DATE -> now() anchor. Live diff at 2026-06-12 10:4x Gulf: 9 machines shift by 1-2 units (OMDBB-1020 42->40, HUAWEI-2003 46->44, NISSAN-0804 41->40, AMZ-1057 50->49, NOVO-1023 26->25, AMZ-1029 202->201, ADDMIND-1007 32->31, AMZ-1038 250->249, MC-2004 60->59). One threshold crossing: AMZ-1057 50->49 drops the `units_last_7d >= 50` high_velocity reason (+8 p_score) at this instant - boundary artifact that moves hourly with sales; not a regression.
- runway_days: same value (cur_stock / (units_last_7d/7)), only the units source changes.

## AC

No machine-level `SUM(qty)/7` over sales_history outside `v_machine_velocity` (verified via pg_proc scan post-apply; `flag_intent_threats` v7/7.0 is product-grain, exempt per registry). get_machine_health.daily_velocity identical to `v_machine_velocity.daily_velocity_7d` for all machines.

## Execution record (2026-06-12)

- Cody verdict: ⚠️ approve with revisions (add `SET search_path = public, pg_temp` to `get_machine_health`) - applied. Articles checked: 2, 4, 12, 14, 15.
- Applied to prod as `prd028_ws2_velocity_canonical` (registered version `20260612065444`; repo file matches).
- AC verified live post-apply: 0 machines where `get_machine_health.daily_velocity <> round(v_machine_velocity.daily_velocity_7d, 1)`; 0 no-sales machines with nonzero velocity; 0 machines where `v_machine_health_signals.units_last_7d <> COALESCE(units_7d, 0)`; pg_proc scan confirms the old inline `SUM(qty)/NULLIF(7,0)` is gone from get_machine_health.
