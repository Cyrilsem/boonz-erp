# PRD-CLEAN-07 — Config visibility + pragmatic consolidation

Status: DONE (2026-07-11) — v_refill_config live (59 params, all distinct, 3 tables);
dead refill_priority_params + service_priority_params (+ its 0-consumer view)
graveyarded; refill_policy_params / refill_settings folds DEFERRED (readers are
engine_add_pod / engine_swap_pod / assert_weimi_slot_match — live-critical);
capacity split documented in bible v6 §9. Dry cycle re-passed post-change.
Priority: P3 (do last; bounded scope)

## Problem

Five single-row config tables (pick_urgency_params [36 cols],
refill_policy_params, refill_priority_params, refill_settings,
service_priority_params) + three capacity tables (capacity_standard [110 rows],
product_slot_capacity [33], slot_capacity_max [0 — dead, graveyard in PRD-03]).
Nobody can see the full engine configuration in one place.

## Design — pragmatic, not heroic

1. CREATE VIEW v_refill_config AS a long-format union
   (source_table, param, value) across the five tables. Read-only single pane.
2. Physical merge ONLY where cheap: for each of refill_policy_params,
   refill_priority_params, refill_settings, service_priority_params, count
   referencing functions (pg_get_functiondef scan). If a table has ≤3 live
   referencing functions, fold its columns into pick_urgency_params, patch the
   functions, move the old table to graveyard. If >3, leave it and record the
   reader list in DECISIONS.md as deferred debt. pick_urgency_params is the
   permanent home (it is the live-tuned table).
3. Capacity: document the split (capacity_standard = per product-type default,
   product_slot_capacity = per product override) in refill_engine_bible_v6.md;
   no physical change.

## Verification battery

1. SELECT * FROM v_refill_config returns every param exactly once.
2. Full pipeline dry cycle on a NON-LIVE date passes (as PRD-03 §V1).
3. Any folded table: old readers patched, npx next build clean.
