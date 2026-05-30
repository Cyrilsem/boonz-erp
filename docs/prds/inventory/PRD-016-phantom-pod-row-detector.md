---
id: PRD-016-inventory
program: PROGRAM-2026-05-25
title: Phantom pod row detector view + daily alert
status: Done
shipped_at: 2026-05-30
done_summary: |
  Migration phaseG_followup_prd016_phantom_pod_alerts applied to prod
  2026-05-30. Cody-approved with revisions: cron-context role guard
  (auth.uid()-aware), simplified UPDATE policy (full UPDATE for managers,
  no column-subset trigger), phantom_pod_alerts kept OUT of Appendix A
  (monitoring telemetry, not core business entity).

  Verified live:
  - cron_phantom_pod_alert RPC: SECURITY DEFINER present
  - phantom_pod_alerts table: present with 3 RLS policies
    (ppa_select / ppa_update / ppa_no_delete USING(false))
  - v_phantom_pod_rows view: present (SECURITY INVOKER), returns 636
    rows on first run — substantial phantom backlog
  - phantom_pod_alert cron: scheduled '15 2 * * *', active=true,
    runs 15 minutes after the daily reconciliation cron

  Articles satisfied: 1, 2, 4 (cron-context guard), 7 (DELETE blocked),
  8 (via_rpc set), 11 (cron via RPC), 12 (forward-only).

  Follow-up: the 636 detected rows need CS triage. First cron run is
  2026-05-31 06:15 Dubai. CS can pre-query the view and dismiss known-
  non-phantom rows before the cron writes them.
severity: P2
reported: 2026-05-25
source: PROGRAM-2026-05-25 Phase 3 P2 #1 (semantic name PRD-005-inventory)
routing: [Dara (view), Cody (cron RPC)]
---

## Problem

Field example: HUAWEI-2003 Krambals Creamy Cheese shows 1 pc in
`pod_inventory` but the machine physically has zero. Phantom rows like
this drive wrong refill plans (engine thinks slot is occupied, won't
refill).

Cause classes:

- Sale reconciliation missed a transaction.
- Receive RPC ran but the physical product was actually empty packaging.
- Pod inventory edited (added) without a real physical event.
- Snapshot/sync mismatch between pod hardware reading and pod_inventory.

## Proposed solution

### Detector view

```sql
CREATE OR REPLACE VIEW public.v_phantom_pod_rows AS
WITH last_activity AS (
  -- Last sales_history transaction per (machine, boonz_product)
  SELECT machine_id, boonz_product_id, MAX(transaction_date) AS last_sale
  FROM sales_history
  WHERE delivery_status IN ('Success','Successful')
  GROUP BY machine_id, boonz_product_id
),
last_pack AS (
  -- Last dispatched refill row per (machine, boonz_product)
  SELECT machine_id, boonz_product_id, MAX(dispatch_date) AS last_pack
  FROM refill_dispatching
  WHERE dispatched = true AND action IN ('Refill','Add New','Add')
  GROUP BY machine_id, boonz_product_id
)
SELECT
  pi.pod_inventory_id, pi.machine_id, pi.shelf_id, pi.boonz_product_id,
  pi.current_stock, pi.snapshot_at, pi.expiration_date,
  m.official_name, bp.boonz_product_name,
  COALESCE(ls.last_sale, lp.last_pack) AS last_activity,
  current_date - COALESCE(ls.last_sale, lp.last_pack)::date AS days_silent
FROM pod_inventory pi
JOIN machines m ON m.machine_id = pi.machine_id
JOIN boonz_products bp ON bp.product_id = pi.boonz_product_id
LEFT JOIN last_activity ls
  ON ls.machine_id = pi.machine_id AND ls.boonz_product_id = pi.boonz_product_id
LEFT JOIN last_pack lp
  ON lp.machine_id = pi.machine_id AND lp.boonz_product_id = pi.boonz_product_id
WHERE pi.status = 'Active' AND COALESCE(pi.current_stock, 0) > 0
  AND COALESCE(ls.last_sale, lp.last_pack) < current_date - interval '14 days';

GRANT SELECT ON public.v_phantom_pod_rows TO authenticated;
```

Threshold: 14 days of no activity (no sale, no refill pack). Adjustable.

### Daily cron alert

`cron_phantom_pod_alert()` SECURITY DEFINER:

- Reads `v_phantom_pod_rows`.
- INSERTs a row into `phantom_pod_alerts` log table (new append-only) per
  detection.
- Returns jsonb summary.

Scheduled at 06:00 Dubai (02:00 UTC), runs after the daily reconciliation
cron from Phase G P3 C.7 (which runs at 06:00 too — sequence: rec at
02:00, phantom at 02:15).

### Append-only log

```sql
CREATE TABLE public.phantom_pod_alerts (
  alert_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  detected_at  timestamptz NOT NULL DEFAULT now(),
  pod_inventory_id uuid NOT NULL,
  machine_id   uuid NOT NULL,
  boonz_product_id uuid NOT NULL,
  current_stock numeric NOT NULL,
  days_silent  int NOT NULL,
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open','dismissed','corrected')),
  resolved_at  timestamptz NULL,
  resolved_by  uuid REFERENCES public.user_profiles(id),
  resolution_note text
);
```

RLS: select for warehouse/operator*admin/superadmin/manager; UPDATE only
to `status / resolved*\*` columns; no DELETE.

## FE

A new admin page `/admin/phantom-pod-alerts` listing open alerts with
"Dismiss" or "Open inventory control session" actions. Out of scope for
this PRD's first cut; backend ships first.

## Acceptance

- View resolves.
- Cron job scheduled.
- Initial smoke: query the view on prod, sanity-check count and a few
  rows manually.

## Linked

- Phase G P3 C.7 daily reconciliation cron — sister hygiene cron.
- [[PRD-001-inventory]] — Inventory control session flow that the FE
  affordance would invoke for correction.
