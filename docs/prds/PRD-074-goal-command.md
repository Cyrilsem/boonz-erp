# PRD-074 goal command

GOAL: Execute PRD-074 (docs/prds/PRD-074-priority-single-source-of-truth.md) end to end, AUTO mode. Self-run Dara/Cody/Stax. Apply only green pieces, SKIP-and-HIGHLIGHT gate failures, keep PRD-074-EXECUTION-LOG.md current, never wait on CS.

HARD GATES: engine_add_pod, engine_swap_pod, pick_machines_for_refill md5 byte-identical. v_machine_priority NOT modified (PRD-073 just shipped it; this PRD only fixes consumers). No existing get_machine_health output key removed or renamed until every FE call site is grepped and proven safe (proof in log). BEGIN..ROLLBACK before any DDL. npm run build green before merge. Migrations forward-only.

CANONICAL DEFINITIONS (write to METRICS_REGISTRY): days_since_visit = executed dispatch evidence via v_machine_health_signals (picked_up OR returned OR dispatched+packed). last_plan_date = MAX approved refill_plan_output.plan_date, informational, never a visit. urgency, p_tier, reasons_arr, grades, s_* terms = v_machine_priority only.

WS-1 get_machine_health v3: Remove self-computed visit_data (currently MAX approved plan_date = wrong), own sales_history velocity, own fill where canonical exists. JOIN v_machine_health_signals + v_machine_priority, pass fields through. ADD keys: last_plan_date, days_since_visit (canonical), urgency_breakdown jsonb [{label, pts}] built from the view's s_runout/s_capacity/s_expiry/s_stale/s_empty/s_lowfill times pick_urgency_params weights plus reasons_arr. Keep WEIMI-direct fields only where no canonical view exists; list the remainder in the log. Cody reviews.

WS-2 get_stale_visit_signals v2: thin SELECT over v_machine_health_signals.days_since_visit, threshold = pick_urgency_params.stale_override_days. No private definition, no private threshold.

WS-3 FE (Stax): refill/page.tsx delete the 8 chip formulas (~lines 2200-2310), render urgency_breakdown verbatim; replace hardcoded labelOrder (~693-712) with backend health_sort; cards show BOTH "last visit Nd" (canonical) and "last plan Nd" labeled separately. lifecycle/page.tsx z-scale + family-score aggregation: move to view fields if cheap, else annotate display-only and log as accepted approximation.

WS-4 Deprecate auto_generate_refill_plan (Article 13): rename to deprecated_auto_generate_refill_plan or revoke execute; registry note pointing to the refill brain; do NOT drop.

WS-5 Divergence guard: create check_priority_surface_consistency() returning per-machine diffs between get_machine_health output and the canonical views on shared fields; must return zero diffs for Active machines.

T-TESTS (log tables): T1 zero diffs from check_priority_surface_consistency() fleet-wide. T2 VOXMCC-1005 shows split clocks (last visit vs last plan, values as of run). T3 chip pts sum equals view urgency on 5 sampled machines. T4 SignalsTab stale list equals machines with stale_overdue in reasons_arr. T5 build green + grep gate: no FE file still contains the deleted formula patterns.

CLOSE: registries (RPC/CHANGELOG/METRICS_REGISTRY definitions section), PRD-074 status line, commit and push, main == origin/main. Final report: field-by-field before/after for get_machine_health, the WEIMI-direct remainder list, T-test table, anything skipped and why.
