# Backlog

- get_machine_health(false) under 5 s (currently 6.2s, PRD-128 acceptance bar reset to 10s 2026-09-22 to unblock closure; this is the follow-up perf pass)
- compute_refill_decision: repoint v_u7d at v_shelf_sales_identity.units_7d instead of re-aggregating v_sales_history_resolved (Article 16 finding, Cody review 2026-09-22, see docs/PRD-129-name-identity.md); also audit whether v_shelf_sales_identity's own sale-resolution CTE should repoint at v_sales_history_resolved now that D-012 exists
