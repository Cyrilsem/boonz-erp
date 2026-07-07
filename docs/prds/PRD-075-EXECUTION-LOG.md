# PRD-075 Execution Log - Priority chapter close

Run 2026-07-04 late, AUTO mode. Hard gates held: engine_add_pod `ca074e57…`,
engine_swap_pod `90f26896…`, pick_machines_for_refill `48cc1844…` md5 byte-identical
before/after everything. All writes preceded by rolled-back proofs. Build green.

## Fleet-diff proofs (rolled-back transactions, then re-verified live)

**1. Eligibility flip list (WS-A, full fleet):** exactly three machines flip, no others:

| Machine               | before -> after |
| --------------------- | --------------- |
| ACTIVATE-2005-0000-W0 | f -> t          |
| IFLYMCC-1024-0000-W0  | f -> t          |
| MPMCC-1054-0000-M0    | f -> t          |

**2. Tier/urgency invariance (WS-C, full fleet):** 0 diffs over 30 machines - p_tier and
urgency byte-identical before vs after the column exposure. View md5 change EXPECTED and
recorded: `a49cd7d37e1ebf088f36351d54f646ac` -> `97e69fa0049ee90262a35766e537a880`.

**3. Chip-sum check (fleet-wide):** 0 machines where sum(urgency_breakdown pts) differs
from v_machine_priority.urgency (dry and live). Sample AMZ-1038: runout 39.25 + empty
11.25 + capacity 6.08 = 56.58.

## T-tests

| Test                                 | Result                                                                                                                                                                                                       |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| WS-A: 3 machines gain grades         | PASS - ACTIVATE-2005: 21 identities (P3_OK on merit, urg 6.62); IFLYMCC-1024: 12 (P1_RESTOCK, urg 21.53); MPMCC-1054: 11 (P1_RESTOCK, urg 23.76). Both P1s earned by real signals, no longer staleness-only. |
| WS-A: drift monitor zero             | PASS - 0 rows live (monitor refined to should-be-eligible 'Live%' machines; MPMCC-1058 'Pending Setup' legitimately excluded and ungraded: 0 identities).                                                    |
| WS-B: manual refill resets clock     | PASS - rolled-back txn: pod_inventory_audit_log 'manual-refill-%' row for VOXMCC-1005 -> days_since_visit 22d -> 0d inside the txn.                                                                          |
| WS-B: guard still clean              | PASS - check_priority_surface_consistency() 0 diffs (dry + live; get_machine_health inherits by pass-through, no cached copy).                                                                               |
| WS-C: chip sum == urgency fleet-wide | PASS - 0 mismatches; guard v2 (four chip fields, round-normalized) 0 diffs.                                                                                                                                  |

## Shipped

- `prd075_wsa_repurpose_grace_eligibility`: pick_urgency_params.repurpose_grace_days
  (default 30; rollback dial 0) in v_live_shelf_stock eligibility + drift monitor
  refinement. repurposed_at NOT touched (CS ruling: permanent relocation history;
  chk_repurpose_consistency stands).
- `prd075_wsb_manual_refills_count_as_visits`: signals days_since_visit =
  GREATEST(dispatch evidence, latest 'manual-refill-%' audit event). METRICS_REGISTRY
  definition row updated.
- `prd075_wsc_expose_urgency_terms` + `prd075_wsc2_health_breakdown_split_guard_v2`:
  four s_* columns exposed; breakdown split into six real terms (runout carries the
  rounding residual so the sum is exact); guard v2 with chip_runout/capacity/expiry/stale.
- FE: FieldCapturePanel hardening (below) + refill chip colors for the new labels
  (zero new math). _HELD rollback bodies committed for vls + vmp.

## FieldCapturePanel change summary (minimal, no redesign)

1. **Machine-scoped products:** picking a machine loads its live shelves
   (v_live_shelf_stock) and Active mappings; the product dropdown shrinks from all ~300
   to what is actually mapped on that machine, each option showing "(fits N)" free
   capacity. Falls back to the full list if the lookup returns nothing.
2. **Fill-to-cap default:** selecting a product with qty untouched prefills qty with the
   machine's free capacity for that product.
3. **Offline-tolerant submit:** navigator.onLine pre-check + try/catch around the RPC;
   typed lines are NEVER cleared except on confirmed success; failure message says lines
   are kept, retry when back online.

## Notes / minor deviations

- Applied `prd075_wsc2` used a guarded functiondef swap (anchor-checked) rather than the
  file's full literal; the committed file reproduces the identical function on fresh
  environments - both verified equivalent by the live chip-sum/guard checks.
- Guard chip comparisons are round(,2)-normalized text (first dry run surfaced '0' vs
  '0.00' false positives - 84 rows, all formatting).
- Chapter status: PRD-073 carry-forward (repurposed-but-Active x3) CLOSED here via the
  grace window; PRD-074 carry-forward (split the core chip) CLOSED here.

## 2026-07-05 addendum - chat hot-fixes (prod-synced by the PRD-072 re-sweep run)

- prd075b/c/d applied via chat MCP, git-backfilled byte-equivalent 2026-07-05. Final
  v_machine_health_signals body = prd075c: visit = refill_dispatching evidence
  (picked_up OR returned OR dispatched OR packed) OR audit refs 'manual-refill-%' OR
  'adjust-%'. Approved-only plans never count. Drift monitor = sales-truth (prd075d).
- Data fixes (both machines trading while label-blinded):
  - MPMCC-1058-0000-R0: adyen_inventory_in_store 'Pending Setup' -> 'Live' (had 4 empty
    shelves and real P1-level urgency ~68 once graded).
  - NISSAN-0804-0000-L0: adyen_status 'Switched off' -> 'Online today' (selling ~44/wk).
    WATCH: the adyen sync may re-stamp this; if the daily drift check flags NISSAN again,
    fix the sync WRITER, not the row.
- Visit-marker audit row: MPMCC-1058 zero-delta pod_inventory_audit_log row
  audit 27752256, dated 2026-07-01 (CS ruling 2026-07-05) - records the physical visit
  so the canonical clock reflects it.
