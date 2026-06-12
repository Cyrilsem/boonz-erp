# /goal — PRD-028 Metrics Registry execution

Execute PRD-028 (docs/prds/PRD-028-metrics-registry-article16.md). Driver: docs/architecture/METRICS_REGISTRY.md. Branch: feat/prd-028-metrics-registry.

RULE BEING ESTABLISHED (Article 16): one canonical DB object per business metric; every consumer reads it; never re-derive inline.

ALREADY CANONICAL (do not rebuild): v_machine_priority (priority tier/score — picker v9.2 + get_machine_health consume it), get_payment_default_summary (reconciliation), resolve_refill_plan_date() (plan dates — NEVER CURRENT_DATE), v_live_shelf_stock (shelf stock).

WORKSTREAMS IN ORDER (each: Dara-style design note → Cody constitutional check → migration via supabase MCP → verify consumers → surgical commit):

WS1 P0 expiry: designate v_machine_expiry_summary canonical; rewire v_machine_health_signals.expired_skus_* to consume it; align get_machine_expiry_detail + get_machine_slots_with_expiry on latest-Active-batch-per-shelf. AC: v_machine_priority.expired_skus_now == get_machine_health().expired_units for ALL machines (live repro of the bug: OMDBB-1020 shows 1 vs 0).

WS2 P1 velocity: create thin v_machine_velocity (7d/30d/daily from sales_history, Success only); get_machine_health + v_machine_health_signals consume. AC: no inline SUM(qty)/7 outside it.

WS3 P1 availability: create v_wh_pickable (Active, NOT quarantined, expiry>=today OR NULL); verify/redefine v_dispatch_availability (available = pickable − unpacked+unpicked CURRENT-date commitments); wire packing FE WH/Committed/Available badges. AC: Sunblast Apple WH_CENTRAL renders 5|0|5.

WS4 P1 banners: wire /app/performance (ribbon AND dark bar), /refill/consumers, /consumers_vox to ONE get_payment_default_summary call, identical scope (decide venue_group vs explicit machine list; today they drift 3 refs/84 AED). Show refunds + cash as own fields. AC: 3 pages equal to the cent; table deltas sum to banner gap.

WS5 P2 scope: v_active_fleet view; report RPCs consume. AC: no per-RPC fleet WHERE drift.

WS6 ratify: Article 16 into docs/architecture/01_constitution.html; add inline-metric block rule to cody skill playbook; update CHANGELOG.md + RPC_REGISTRY.md + METRICS_REGISTRY.md statuses per WS.

CONSTRAINTS: no metric value changes undocumented (record before/after per WS); all CREATE OR REPLACE through Cody review; NEVER git add -A (working tree has ~96 unrelated dirty files) — stage files explicitly; tsc --noEmit + npm run build before any FE commit; nothing pushed to main without CS green light.
