---
id: PRD-014-inventory
program: PROGRAM-2026-05-25
title: M2M swap routing fix + IFLY Barebells 19-May RCA
status: Blocked
blocked_summary: |
  Three-phase plan. Phase 1 (audit query for orphan M2M rows) needs CS
  review of the result list. Phase 2 (BEFORE INSERT/UPDATE trigger) needs
  Cody approval. Phase 3 (per-row repair of orphan rows incl. IFLY 19-May)
  needs per-row CS sign-off — explicitly gated by program hard rules. RCA
  is complete (orphan half-pair found; same anonymous-flip class as
  Phase G P4 A.8). Daylight CS to execute phases sequentially.
severity: P1
reported: 2026-05-25
source: PROGRAM-2026-05-25 Phase 2 P1 #3 (semantic name PRD-003-inventory)
routing: [Cody, Dara (small CHECK on refill_dispatching shape)]
---

## RCA — IFLY 19-May Barebells

Live state verified 2026-05-25:

Single `refill_dispatching` row for IFLY-1024 Barebells Creamy Crisp on
2026-05-19:

```
official_name        : IFLYMCC-1024-0000-W0
action               : Remove (12u)
from_warehouse_id    : <WH_MCC>
is_m2m               : false   ← BUT
source_origin        : internal_transfer
source_kind          : wh
comment              : "[TRUCK-TRANSFER — do not debit WH]"
m2m_transfer_id      : NULL
m2m_partner_id       : NULL
from_machine_id      : NULL
```

There is NO paired `Add New` row on 19-May for the destination AMZ
machine. The next Barebells Creamy Crisp dispatch rows are all on 2026-05-21,
to different machines (ADDMIND, NISSAN, NOOK, OMDCW, USH, VML), with
`source_origin='warehouse'` (regular refills, not the M2M continuation).

So the 12 units physically left IFLY-1024 on 19-May, the system removed
them from IFLY's pod, but the destination credit was never written.

This is the same anonymous-M2M-flip pattern from the Phase G P4 A.8 audit:
a non-canonical write path produces half a transfer (Remove side only)
with `is_m2m=false` but `source_origin='internal_transfer'` — masquerading
as a truck transfer without going through `swap_between_machines` (which
WOULD have written both halves).

## Where the half-pair likely came from

The Phase G A.8 audit identified that an anonymous direct UPDATE flips
`is_m2m=false → true / source_origin='warehouse' → 'internal_transfer'` ~10
minutes after `push_plan_to_dispatch` insert. The IFLY 19-May row is the
SAME shape (internal_transfer / truck-transfer comment / NULL transfer_id)
but `is_m2m=false`. Either:

- The flip got partway: changed source_origin but never set is_m2m=true.
- A different code path created it directly with `source_origin='internal_transfer'`.

In both cases the same fix applies.

## Proposed fix

### Phase 1 — RCA completion (this PRD)

Run an audit to find every row in the last 14 days where
`source_origin='internal_transfer'` AND `m2m_transfer_id IS NULL` AND a
paired Add New does NOT exist for the same product on the same date.

```sql
WITH suspects AS (
  SELECT rd.dispatch_id, rd.machine_id, rd.boonz_product_id,
         rd.dispatch_date, rd.action, rd.quantity, rd.is_m2m,
         rd.source_origin, rd.source_kind, rd.comment
  FROM refill_dispatching rd
  WHERE rd.source_origin = 'internal_transfer'
    AND rd.m2m_transfer_id IS NULL
    AND rd.dispatch_date >= current_date - interval '14 days'
)
SELECT s.*, NOT EXISTS (
  SELECT 1 FROM refill_dispatching rd2
  WHERE rd2.dispatch_date = s.dispatch_date
    AND rd2.boonz_product_id = s.boonz_product_id
    AND rd2.action = 'Add New'
    AND rd2.machine_id <> s.machine_id
) AS missing_pair
FROM suspects s
ORDER BY s.dispatch_date DESC, missing_pair DESC;
```

CS reviews the list, identifies orphan Removes vs known-paired ones.

### Phase 2 — Prevention (migration)

Add a `BEFORE INSERT OR UPDATE` trigger on `refill_dispatching` that
raises when:

- `source_origin='internal_transfer'` AND `m2m_transfer_id IS NULL`
- The trigger fires only when `app.via_rpc IS DISTINCT FROM 'true'` OR
  when the calling RPC is not in the allow-list (`swap_between_machines`,
  the future `record_cross_brand_substitution` IF it sets internal_transfer).

This forces all M2M-shaped writes through `swap_between_machines`, which
is the canonical writer and always pairs Remove + Add New with a
`m2m_transfer_id`.

Cody review checklist:

- Article 1: hard-enforces single canonical write path. ✓
- Article 3: blocks the anonymous direct-UPDATE flip path. ✓
- Article 12: forward-only migration. ✓
- Edge case: if `swap_between_machines` itself doesn't set
  `app.via_rpc` (verified it does — line 22 of the function). ✓

### Phase 3 — Data fix for the orphan rows (per-row CS sign-off)

For each orphan row identified in Phase 1:

- If the physical product genuinely landed at machine X but the system
  shows no credit → write the missing `Add New` row via a new repair RPC
  (similar to the PRD-011 `repair_unbound_dispatch` pattern, but for M2M
  pair completion). Per-row CS sign-off mandatory.
- If the product never landed (return to WH instead) → reactivate the
  WH row via `reactivate_warehouse_row` with explicit reason.

## Acceptance

- Phase 1 audit query produces the orphan list, CS reviews.
- Phase 2 trigger blocks new orphan inserts in prod.
- Phase 3 repairs the historical orphans (IFLY 19-May among them).

## Linked

- A.8 M2M flow audit (`docs/prds/phase-g/A8_m2m_flow_audit_2026-05-25.md`)
  — shares the anonymous-flip finding.
- `swap_between_machines` RPC — the canonical M2M writer.
