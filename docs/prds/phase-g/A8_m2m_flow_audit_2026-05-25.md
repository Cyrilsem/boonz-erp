# Phase G P4 A.8 — M2M flow audit

**Date:** 2026-05-25
**Scope:** Document every code path that creates or mutates `refill_dispatching.is_m2m` and identify integrity gaps. Read-only — no fixes shipped in this audit.

## TL;DR

There are **two distinct M2M flows** in production, only one of which is a constitutional canonical writer. The second flow is a direct-UPDATE path that flips `is_m2m=true` outside any RPC and breaks Article 3.

1. **Canonical M2M (swap_between_machines):** Remove + Add New pair, populates `m2m_transfer_id` and `m2m_partner_id`. Zero rows of this shape live in prod.
2. **Anonymous truck-transfer M2M:** Plain `Refill` rows flipped to `is_m2m=true` by direct UPDATE post-`push_plan_to_dispatch`. All 8 live `is_m2m=true` rows in prod are this shape, none have a `transfer_id`, none were emitted by `swap_between_machines`. **Article 3 violation.**

## Findings

### F-1 — Canonical writer: `swap_between_machines`

`SECURITY DEFINER`, validates caller role (`operator_admin/superadmin/manager`), validates source pod stock, writes two `refill_dispatching` rows per transfer item:

- Source: `action='Remove'`, `is_m2m=true`, `m2m_transfer_id=<v_transfer_id>`, `m2m_partner_id=<add_id>`.
- Dest: `action='Add New'`, `is_m2m=true`, same `m2m_transfer_id`, `m2m_partner_id=<remove_id>`.

Both rows ship `packed=true, dispatched=false, picked_up=false`. The function explicitly does **not** touch `pod_inventory` — that happens at driver confirmation via `receive_dispatch_line`.

**Live state:** 0 rows match the swap_between_machines shape (`m2m_transfer_id IS NOT NULL`). The canonical M2M flow is implemented but unused in current prod traffic.

### F-2 — Acknowledger: `acknowledge_m2m_transfer`

`SECURITY DEFINER`, sets `wh_approved_at = now()` and `wh_approved_by = auth.uid()` for all rows in a given `m2m_transfer_id`. Role-gated to `warehouse/operator_admin/superadmin/manager`.

**Live state:** 0 acknowledged rows out of 8 `is_m2m=true` rows in prod, because none of those rows have a `m2m_transfer_id`, so `acknowledge_m2m_transfer` cannot reach them. The acknowledger is **dead code against live data** until F-3 is reconciled.

### F-3 — Anonymous flip: `is_m2m=false → true` via direct UPDATE

The 8 live `is_m2m=true` rows in prod were:

1. **INSERTED** at `2026-05-19 19:54:00.440Z` by `push_plan_to_dispatch` with `is_m2m=false, source_kind='unknown', source_origin='warehouse', from_warehouse_id=<WH_CENTRAL>`.
2. **UPDATED** at `2026-05-19 20:04:05.259Z` — same timestamp for all 8 rows — flipping `is_m2m=false → true, source_kind='unknown' → 'truck_transfer', source_origin='warehouse' → 'internal_transfer', from_warehouse_id=<WH_CENTRAL> → NULL, source_machine_id=NULL → <some machine>`.

The `write_audit_log` row for that UPDATE has `actor_role=NULL` and `rpc_name=NULL`. That means the UPDATE did not flow through a `SECURITY DEFINER` RPC that set `app.via_rpc` / `app.rpc_name`. Either:

- A direct `UPDATE` from a privileged client (Supabase Studio, n8n with service key, or a manual SQL execution).
- An RPC that mutates `refill_dispatching` but does **not** set the GUCs (and so is invisible to the audit trigger as a canonical writer).

Either way, this is **Article 3** (direct table write from non-canonical path) and **Article 4** (RPC must set `app.via_rpc` and `app.rpc_name`) violation.

### F-4 — Mutation trigger: `audit_m2m_dispatch_changes`

Trigger function attached to `refill_dispatching` (`trg_audit_m2m_dispatch`). Read-only against M2M state (audit, not mutation). Not investigated in depth — flagging that the trigger exists so the next pass can confirm it doesn't silently flip `is_m2m` on UPDATE.

### F-5 — FE consumers (no writers, read-only)

- `src/app/(field)/field/pickup/page.tsx` — selects `is_m2m`, renders M2M badge on the pickup list. Does not write.
- `src/app/(field)/field/packing/[machineId]/page.tsx` — filters `is_m2m` rows out of the WH-debit packing flow (correct: M2M lines must not debit WH). Does not write.

No FE code path writes `is_m2m` directly. Confirmed by `grep -rn 'is_m2m' src/` — all hits are reads/filters/conditional rendering.

### F-6 — Data integrity gap: orphaned M2M rows

All 8 live `is_m2m=true` rows:

- Have `action='Refill'`, not the `Remove + Add New` pair shape.
- Have `m2m_transfer_id IS NULL` (`acknowledge_m2m_transfer` can't reach them).
- Have `m2m_partner_id IS NULL` (no paired sibling).
- Have `from_warehouse_id IS NULL` (the flip wiped the source WH).
- Are already `packed=true, dispatched=true, picked_up=true` — i.e., already executed in the field.

These rows represent **truck-internal redistribution** ("truck transfer") where the field staff redistributes inventory between machines without going back to the warehouse, using rows that were originally normal `Refill` rows from WH. The flip-to-M2M happened mid-flow (10 min after the plan push) to stop the WH from being debited at packing time (the packing FE explicitly excludes `is_m2m` lines from WH debit per F-5).

## Risk assessment

- **No data loss risk:** the truck-transfer flow is functionally correct. The 8 rows did move product field-to-field as intended.
- **Audit integrity risk:** the WH debit was bypassed via a non-canonical UPDATE. Article 3/4 violation. The daily reconciliation view (C.6) cannot bucket these as M2M because they lack `m2m_transfer_id`, so they will appear as "vanished WH stock" once C.6 is rolled into operator review.
- **Acknowledger dead-code risk:** `acknowledge_m2m_transfer` cannot reach these rows; warehouse manager has no UI affordance to "sign off" on the M2M decision because the FE flow that produced them doesn't link to the acknowledger.

## Recommendations (not in scope for this audit)

These belong to a future PRD — captured here so they don't disappear:

1. **Find the writer of the 20:04:05 anonymous flip.** Most likely an n8n workflow or a Vercel cron that lacks `app.via_rpc` GUC setting. Until it is identified, every Phase G C.6 reconciliation will mis-bucket those rows.
2. **Canonicalize the truck-transfer flow.** Either (a) route truck transfers through `swap_between_machines` so they get a `m2m_transfer_id`, or (b) add a sibling RPC `convert_to_truck_transfer(p_dispatch_id, p_reason)` that is the only path that flips `is_m2m=true` on a non-pair row, sets `app.via_rpc/rpc_name`, and generates a `m2m_transfer_id` for the acknowledger to reach.
3. **Backfill `m2m_transfer_id`** for the 8 orphan rows so the acknowledger can sign them off retroactively. Per-row CS approval (the Saturday corrections cadence applies here).
4. **Hard-block direct UPDATEs on `is_m2m`** via a row-level trigger that raises unless `app.via_rpc='true'`. This is **A.7** in the Phase G PRD and is one of the three carve-out items.

## Constitution scorecard for the current M2M surface

| Article                             | Status against M2M                                                            | Notes         |
| ----------------------------------- | ----------------------------------------------------------------------------- | ------------- |
| 1 (single canonical write path)     | ❌ Two paths: `swap_between_machines` (canonical) + anonymous UPDATE (rogue). | F-3           |
| 2 (RLS)                             | ✅ `refill_dispatching` has RLS enabled.                                      |               |
| 3 (no direct writes from non-RPC)   | ❌ The flip path doesn't carry `app.via_rpc`.                                 | F-3           |
| 4 (DEFINER validates and sets GUCs) | ✅ for the two named RPCs. ❌ for the anonymous flip.                         | F-1, F-2, F-3 |
| 7 (audit logs append-only)          | ✅ `write_audit_log` captured the flip even without `app.via_rpc`.            |               |
| 8 (universal audit)                 | ✅ same                                                                       |               |
| 15 (PR declares invariants)         | n/a — historical                                                              |               |

## Outcome

Findings documented. No data fixes in this audit. The anonymous-UPDATE root-cause hunt and the canonicalization of truck-transfer M2M are deferred to a follow-up PRD (sibling of A.7 carve-out).

— Phase G P4 A.8 closes here.
