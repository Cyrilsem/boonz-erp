# PRD-074: Priority single source of truth (kill the metric duplicates)

Status: SHIPPED 2026-07-04 (both migrations applied, FE refactored, T1-T5 green, guard live; see PRD-074-EXECUTION-LOG.md). Open: split the lumped core chip once v_machine_priority exposes s_runout/s_capacity/s_expiry/s_stale.
Owner: CS. Mode: AUTO with hard gates. Article 16 (Metrics Registry) enforcement for the P1/P2 surface.

## Why

The VOX outage exposed that the same question gets different answers per surface. Audited 2026-07-04 (chat, DB + FE sweep). The P1/P2 pipeline cannot be trusted or tuned while consumers compute their own versions of its inputs.

## Duplication matrix (found, verified)

DB side:

- D1 `get_machine_health` visit_data: last visit = MAX(refill_plan_output.plan_date WHERE operator_status='approved'). WRONG: approve is not a visit. Canonical is `v_machine_health_signals.days_since_visit` (executed dispatch: picked_up OR returned OR dispatched+packed). This is why FE cards said "3d ago" while the picker correctly said 22d during the push outage.
- D2 `get_stale_visit_signals` (consumed by refill SignalsTab): same wrong approved-plan definition, own >10d threshold.
- D3 `get_machine_health` also self-computes velocity from sales_history and stock/fill from WEIMI aggregation, alongside partially reading v_machine_priority. Field-by-field divergence unknown; enumerate in the run.
- D4 `auto_generate_refill_plan`: legacy pre-brain engine, not on any cron, still registered and callable. Deprecation candidate (Article 13).

FE side (agent sweep, file:line verified):

- F1 refill/page.tsx ~2200-2310: EIGHT hardcoded chip formulas rebuild the urgency breakdown (empty x15, near-empty x8, runway 50/35/20/8, velocity x2 cap 30, visit 25/15/5, expired 20+2x, swaps x5, fill 15/8, picked +40). None match v_machine_priority v2 weights. This produced the "urgency: 15 pts" next to "+30/+30/+20" contradiction CS screenshotted.
- F2 refill/page.tsx ~693-712: hardcoded labelOrder rank although backend already returns health_sort.
- F3 lifecycle/page.tsx 683/738/1558 + 216-278: velocity z-scaling and family velocity-weighted score aggregation client-side. Lower risk (display), fix last.

## Design (Dara designs, Cody reviews, Stax wires)

1. Canonical definitions, written to METRICS_REGISTRY:
   - last_visit / days_since_visit = executed dispatch evidence (v_machine_health_signals). THE visit clock.
   - last_plan_date = newest approved plan (rename of the old notion; informational only, never a visit).
   - urgency, p_tier, reasons_arr, grade counts, s_* terms = v_machine_priority only.
2. `get_machine_health` v3: drop visit_data, own velocity, own fill where canonical fields exist; JOIN v_machine_health_signals + v_machine_priority and pass fields through. ADD: last_plan_date (labeled), days_since_visit (canonical), and `urgency_breakdown` jsonb built from the view's terms and pick_urgency_params weights: [{label, pts}] so FE renders chips with zero math. Keep the WEIMI-direct fields only where no canonical view exists; list any such remainder in the log.
3. `get_stale_visit_signals` v2: thin SELECT over v_machine_health_signals with the same >N-days param sourced from pick_urgency_params.stale_override_days (no private threshold).
4. FE (Stax): refill page chips render urgency_breakdown verbatim; delete the 8 formulas. labelRank -> health_sort. Cards show two labeled fields: "last visit Nd" (canonical) and "last plan Nd". Lifecycle F3: move z-scale + family score to view fields if cheap, else explicitly annotate as display-only approximations (CS accepted lower priority).
5. `auto_generate_refill_plan`: Article 13 deprecation. Rename with _deprecated prefix or revoke execute + registry note; do NOT drop (rollback ease).
6. Divergence guard: `check_priority_surface_consistency()` test fn comparing get_machine_health output vs canonical views on shared fields for all Active machines; run it in the T-tests and leave it callable for future audits.

## Gates

Engines + pick_machines_for_refill byte-identical. v_machine_priority NOT modified (PRD-073 just shipped; this PRD only adds consumers). get_machine_health output stays backward compatible: no removed/renamed existing keys without checking every FE call site first (grep proof in log). npm run build green. BEGIN..ROLLBACK for any DDL. VOX venue-team on-the-spot refills produce neither plans nor dispatches; both clocks miss them. OUT OF SCOPE here; noted for a future field-capture PRD.

## T-tests

- T1 For every Active machine: get_machine_health.days_since_visit == v_machine_health_signals.days_since_visit (exact), and urgency/p_tier match v_machine_priority.
- T2 VOXMCC-1005 renders "last visit 22d / last plan 3d" style split (values as of run date).
- T3 Chip sum == view urgency for 5 sampled machines (breakdown honest).
- T4 SignalsTab stale list == machines with stale_overdue in reasons_arr.
- T5 Build green; no FE file matches the deleted formula patterns (grep gate).

## Acceptance

One definition per metric, registered; get_machine_health is a pass-through + breakdown; FE has zero priority math; legacy generator deprecated; consistency checker green; registries + CHANGELOG updated; committed and pushed, main == origin/main.

## Rollback

get_machine_health/get_stale_visit_signals re-apply prior bodies (kept as _HELD files); FE revert commit; deprecation is rename/grant, reversible.
