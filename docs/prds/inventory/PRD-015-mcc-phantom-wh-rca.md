---
id: PRD-015-inventory
program: PROGRAM-2026-05-25
title: MCC phantom WH rows — RCA + provenance hardening
status: Blocked
blocked_summary: |
  RCA reframed: rows are not phantom, they are legitimate returns from
  AMZ-area machines into the WH_MCC staging room, just unattributed
  (provenance_reason='unknown_pre_migration'). Phase 1 (BEFORE INSERT
  trigger requiring non-NULL provenance) is a behavior-changing trigger
  needing 7-day RAISE-WARNING audit window before flip to RAISE-EXCEPTION,
  same shape as CARVEOUT_A7. Cody approval mandatory.
severity: P1
reported: 2026-05-25
source: PROGRAM-2026-05-25 Phase 2 P1 #4 (semantic name PRD-004-inventory)
routing: [Cody]
---

## RCA — live finding 2026-05-25

The three flagged products at WH_MCC:

| product              | warehouse_stock | batch_id                  | provenance_reason     |
| -------------------- | --------------- | ------------------------- | --------------------- |
| Hunter - Sea Salted  | 2               | REMOVE-RECEIVE-2026-05-13 | unknown_pre_migration |
| Perrier - Regular    | 12              | REMOVE-RECEIVE-2026-05-13 | unknown_pre_migration |
| Hunter - Hot N Sweet | 1               | RETURN-2026-05-10         | unknown_pre_migration |

Pattern: every row's `batch_id` is shaped like `REMOVE-RECEIVE-YYYY-MM-DD`
or `RETURN-YYYY-MM-DD`. `provenance_reason` is `unknown_pre_migration`.
`source_event_id` is NULL.

These rows came from the **return/remove receive flow** — drivers returning
product to the warehouse — but the source event (which dispatch row, which
machine) is lost.

## Hypothesis: not actually phantom

WH_MCC is the MCC staging room for AMZ-area machines (per the multi-warehouse
model documented in [[CARVEOUT_A7]] and [[A8_m2m_flow_audit_2026-05-25]]).
Drivers doing pod returns at AMZ-area machines route to WH_MCC. So
"Hunters at WH_MCC" is expected, not phantom — provided the return event
exists somewhere.

The 21-May report's "never placed there" claim needs validation. Likely
explanations:

1. The returns flow used a pre-migration RPC that didn't set provenance
   (hence `unknown_pre_migration`). The rows are real but unattributed.
2. WH_MCC stock was bulk-loaded as part of the multi-warehouse rollout,
   not from individual returns.
3. The reporter was unaware that MCC is a staging room — they expected
   returns to land at WH_CENTRAL only.

## Proposed action

### Phase 1 — provenance prevention (migration)

Tighten the `set_warehouse_inventory_provenance` trigger (if it exists)
or add a new `BEFORE INSERT` trigger on `warehouse_inventory` requiring
**non-NULL provenance** on INSERT. If `app.provenance_reason` is NULL or
`'unknown_pre_migration'`, raise.

Pre-conditions:

- `app.provenance_reason` must be one of the allowed
  `wh_provenance_reason_enum` values.
- For INSERT specifically, `source_event_id` must also be set (else
  the row is provenance-incomplete).

This stops any new "unknown" rows from being inserted. Existing
`unknown_pre_migration` rows are grandfathered.

### Phase 2 — backfill attribution (separate effort)

For each `unknown_pre_migration` row with a parseable `batch_id`
(e.g. `RETURN-2026-05-10` → look at refill_dispatching for any Remove
or Return on that date that matches the product), attempt to retro-attribute
the source_event_id. Best-effort, per-row CS sign-off if any data is
adjusted.

### Phase 3 — communication

Update the architecture docs (`02_phase_a_plan.html`) to clearly state
that WH_MCC is a staging room for AMZ machines and that returns from
those machines route here, not to WH_CENTRAL.

## Acceptance

- Trigger raises on attempted insert without provenance.
- The three flagged rows remain Active with their unchanged stock (they
  are real returns, not phantoms).
- Architecture doc clarifies the WH_MCC role.

## Out of scope

- The deeper question of whether `unknown_pre_migration` rows should be
  retroactively re-attributed. That's a 2-week backfill effort. Tracked
  as a separate follow-up.

## Linked

- [[CARVEOUT_A7]] — the hard-block-direct-UPDATE PRD; same prevention class.
