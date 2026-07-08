# PRD-093: Consignment / venue-sourced SKU model

Status: Part A SHIPPED DARK 2026-07-08 (is_consignment/consignment_venue_id columns, additive/inert, diff_vs_golden IDENTICAL); Part B (engine wh_avail-skip gating) PARKED (unvalidatable + pod->boonz mapping). See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews.

## Why

Venue-sourced SKUs (VOX Aquafina / Ice Tea / M&M — the venue supplies them, we don't stock them) get flagged as warehouse shortages because the engine assumes we stock everything. That produces false `blocked_no_wh` / procurement noise and mis-sizes those shelves. Consignment SKUs need their own supply model: no WH draw, no shortage flag.

## Design (Dara designs, Cody reviews)

1. `boonz_products.is_consignment boolean default false` (additive; NULL/false = today's behaviour). Optional `consignment_venue_id` for the supplying venue.
2. In `engine_add_pod` (behind `consignment_v1`): consignment SKUs **skip `wh_avail` gating** (assume venue-supplied), never emit `blocked_no_wh` / `procurement_gaps`; size to shelf cap or a venue policy. Conservation already excludes them from the WH-balance assertion (PRD-077) once tagged.
3. Seed the known VOX consignment SKUs (do NOT flip flag on until CS confirms the seed list).

## Gates

- Column additive; **flag OFF ⇒ `diff_vs_golden` IDENTICAL** even with SKUs tagged (behaviour only changes when `consignment_v1=on`). Flag ON ⇒ capture delta; consignment SKUs no longer show WH-short; conservation green (WH balance excludes them). Cody signs (additive column on a core table).

## T-tests

- T1 flag off (SKUs tagged) ⇒ golden identical.
- T2 flag on ⇒ VOX Aquafina/Ice Tea/M&M shelves never flagged `blocked_no_wh`/procurement.
- T3 flag on ⇒ conservation excludes consignment from WH balance (no false phantom/oversub).
- T4 non-consignment SKUs unchanged.

## CLOSE

CHANGELOG + registry; PRD-093 SHIPPED DARK + EXECUTION-LOG (seed list + on-delta for CS); commit+push. Enable = CS confirms seed list then flips `consignment_v1=on`. Rollback = flag off (column stays, inert).
