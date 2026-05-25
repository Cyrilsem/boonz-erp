# Carve-out PRD — B.6 Inventory control-mode soft lock

**Parent:** PRD-Phase-G v2 Section 11 (Phase 4 scope)
**Status:** Carve-out from Phase G P4. Not shipped in 2026-05-25 batch.
**Reason for carve-out:** UX-defining change that depends on B.5 (session viewer) being live for at least two weeks of real-traffic data before we know the right lock granularity.

## Problem

When a warehouse manager opens an inventory-control session via the existing start-session flow and starts editing rows, two other privileged users (operator_admin / superadmin) can edit the same row concurrently from another tab/device. There is no on-screen affordance that warns either user that a session is open against the same `wh_inventory_id`. Result: edit collisions surface only post-hoc in the session viewer.

B.6 proposes a **soft lock** with three properties:

1. When a row is "in scope" of an open session, a yellow chip surfaces on the operator inventory drawer (Edit button stays enabled but warns).
2. When a user clicks Edit on a soft-locked row, a confirm dialog states "user X has session Y open against this row, started Z minutes ago — edit anyway?"
3. The session itself records the conflict as an `inventory_control_attempt` row with `result='other'` and a `concurrent_edit_warning_acknowledged` reason. C.6 reconciliation can then surface conflict density per day.

Note: **soft** lock. The PRD section 11 explicitly avoids a hard lock because two-key warehouse situations exist (manager counts, superadmin overrides simultaneously).

## Why it needs standalone staging

The lock contract depends on three not-yet-validated assumptions:

1. **Session scope is meaningfully narrow.** Today `scope_warehouse_id` is mandatory but `scope_product_ids` is optional. If most live sessions leave `scope_product_ids=NULL` (session = "all of WH_CENTRAL"), then every row in WH_CENTRAL will surface the soft-lock chip during a session — meaning the chip becomes noise and users will tune it out. B.5 viewer needs 2 weeks of real session data to confirm whether scopes are narrow or wide.
2. **Session-open lifetime matters.** If sessions stay open for 4+ hours (e.g., a manager forgot to close at end of count), the lock spans the whole day. Mitigation: a follow-up auto-close cron that closes sessions older than 8 hours. That cron is itself a new write path needing Cody review.
3. **The current concurrent_edit_warning approach is incomplete.** PRD section 9.7 reads "concurrent-edit check: per wh_inventory_id history" — implies the warning is per-row not per-session. Need to validate the warning frequency.

## Proposed solution (sketch, awaiting B.5 telemetry)

UI:

```tsx
{
  rowInOpenSession && (
    <div className="px-3 py-2 bg-yellow-50 border border-yellow-300 rounded">
      ⚠ This row is in scope of an open session ({sessionId.slice(0, 8)}…)
      started {minutesAgo} min ago by {sessionStarter}.
    </div>
  );
}
```

Backend:

```sql
CREATE OR REPLACE VIEW public.v_wh_inventory_open_session_lock AS
SELECT wi.wh_inventory_id, ics.session_id, ics.started_at, ics.started_by
FROM warehouse_inventory wi
JOIN inventory_control_session ics
  ON ics.status = 'open'
 AND ics.scope_warehouse_id = wi.warehouse_id
 AND (ics.scope_product_ids IS NULL OR wi.boonz_product_id = ANY(ics.scope_product_ids));
```

(View-only — no writer needed for the soft-lock itself. The conflict-record write reuses the existing `inventory_control_attempt` flow.)

## Open questions for CS

1. What's the right soft-lock UX: yellow chip only, or chip + confirm dialog on Edit click?
2. Auto-close cron: 8 hours? 4? Or no auto-close (require manual close)?
3. Should `scope_product_ids` become mandatory going forward to keep lock scope narrow? That's a B.5 outcome more than a B.6 design.

## Acceptance gate

- 2 weeks of B.5 telemetry showing typical session scope width and lifetime.
- CS sign-off on lock granularity (per-row vs per-warehouse) given the telemetry.
- One staging dry run with two test users editing the same scope concurrently.

## Estimated ship window

Sprint 2 after Phase G chapter closes. Depends on B.5 being live (this PR ships B.5).
