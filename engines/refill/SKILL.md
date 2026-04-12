# Boonz Refill Brain — Skill Entry Point

**Version:** Phase 1 (Engine 1 in development)
**Stack:** Python · Supabase (eizcexopcuoycuosittm, ap-south-1)
**Last updated:** 2026-04-12

## What this skill does

The refill brain reads live machine state, applies operator guardrails,
and produces a per-slot refill plan (quantity + swap decisions).
This skill file is the entry point for any Claude session working on
refill engine code.

## Always read first

Before writing any engine code, read these files in order:

1. `engines/refill/knowledge/refill_formula.md` — the canonical formula
2. `engines/refill/knowledge/machine_modes.md` — mode parameters
3. `engines/refill/knowledge/db_views.md` — available data sources
4. `engines/refill/guardrails/portfolio_strategy.md` — operator intent layer
5. `engines/refill/guardrails/refill_rules.md` — vitrine minimums + signal rules
6. `engines/refill/guardrails/layout.md` — slot facing rules

## Engine dependency order (Phase 1)

Engine 1 (portfolio) → Engine B (quantity) → Engine C (swap) → Engine D (decider)
Do not implement a downstream engine before its upstream dependency exists.

## Critical rules

- max_stock from v_live_shelf_stock IS the slot capacity ceiling. Do not hardcode.
- target_qty and max_stock are distinct values — always log both separately.
- Never blindly fill to max_stock. Always apply the velocity formula first.
- All Supabase queries: .limit(10000) on any query returning >100 rows.
- Credentials: always from .env, never hardcoded.
- delivery_status filter: WHERE delivery_status IN ('Success','Successful')

## Supabase key views

| View                       | Purpose                                                    |
| -------------------------- | ---------------------------------------------------------- |
| v_live_shelf_stock         | Live slot state — current_stock, max_stock, pod_product_id |
| v_sales_history_attributed | Transaction history for velocity calculation               |
| v_pod_inventory_latest     | Latest pod inventory snapshot                              |

## Guardrail files (engines/refill/guardrails/)

portfolio_strategy.md · refill_rules.md · layout.md · coexistence.md ·
travel-scope.md · seasonality_global.md · source_of_supply.md ·
vitrine_machines.md · refill_overrides.md
