# PRD-028 WS5 - Active-fleet scope view (Dara)

**Date:** 2026-06-12 · **Status:** Applied · **Driver:** METRICS_REGISTRY.md row "Machine scope active fleet"

## Design

`v_active_fleet(machine_id, official_name, venue_group, service_track, include_in_refill, status, repurposed_at)` = machines WHERE `COALESCE(status,'Active') NOT IN ('Inactive','Warehouse')`. 34 machines live.

Key decision: `repurposed_at IS NULL` and `include_in_refill` are EXPOSED COLUMNS, not baked into the WHERE. Measured why: 4 of 11 VOX machines in the reconciliation scope are repurposed-but-still-Active rows carrying 3,620.75 AED of sales for 06-01..11 - baking the repurposed filter into the view would silently drop 27% of period sales from money reports. Refill/ops consumers add `include_in_refill AND repurposed_at IS NULL`; reconciliation consumers take the base scope. Each extra filter is declared at the consumer, never re-derived.

`service_track`: venue_group='VOX' -> 'vox' else 'main' (same rule as v_machine_priority.svc_track).

## Consumers wired

- `get_payment_default_summary`: venue-scope branch reads `v_active_fleet` (explicit `p_machine_ids` branch unchanged, still bypasses fleet filters). Verified value-identical pre/post: full jsonb equality on 06-01..11 VOX.
- Follow-ups (not wired in WS5, candidates as they next change): `get_vox_commercial_report` (pods-based venue scope), picker fleet scopes (already consume v_machine_priority -> signals base; signals base could consume v_active_fleet + declared filters in a later pass).

## Execution record (2026-06-12)

Cody ✅ (Articles 4, 12, 14; read-only; forward-only; zero value change proven by jsonb equality). Applied as `prd028_ws5_active_fleet` (version `20260612072352`), repo file matches. Data smell logged for CS: 5 machines fleet-wide are status='Active' with repurposed_at set (old identities not archived to Warehouse/Inactive) - reconcile separately.
