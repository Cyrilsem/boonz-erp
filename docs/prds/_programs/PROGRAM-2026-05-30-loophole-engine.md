---
id: PROGRAM-2026-05-30
title: Loophole Engine — close the 7 findings from the Boonz Flow Audit
status: Ready-for-goal
severity: P0
reported: 2026-05-30
source: Boonz Flow & Data Integrity Audit (28 May 2026). 7 findings, none closed by prior PROGRAM-2026-05-25/26 work. CS instruction: "close these without leaving open-ended questions."
routing: [Dara, Cody, Stax]
external_inputs_already_resolved:
  - Refill update doc moved into repo at docs/refill-updates/2026-05-22-to-28_refill_update.md (was the hard external blocker for PROGRAM-2026-05-26 Phase 1)
---

# Loophole Engine — close the audit findings

This is a **decisions-only PRD**. Every architectural choice is made. The agent does not need to ask CS clarification on shape, only on per-row data when the program rules require it.

The audit verdict was: detection is excellent, governance and closure are absent. This PRD builds the closure layer.

## Outcomes (must all be Done at the end)

1. **F1 + F2 closed**: refill_dispatching no longer accepts writes outside the canonical RPC + edit-log path. 7-day warning window, then HARD BLOCK.
2. **F3 closed**: the 335-unit / 79-row phantom consumer_stock leak (bug006) is drained to zero via a one-shot canonical writer with full audit attribution.
3. **F4 closed**: engine pins from_wh_inventory_id at plan-output time, not stitch-time. WEIMI batch overwrites can no longer break the binding.
4. **F5 closed**: stale-state escalator cron creates findings_ledger entries for any wh_approval or driver_removal state >24h.
5. **F6 closed**: findings_ledger table wraps monitoring_alerts with a lifecycle (open → ack → assigned → resolved → auto_verified_healed). All 204 unacknowledged alerts get triaged into the ledger; the 24 critical ones get owners.
6. **F7 closed**: the 17 RLS-disabled tables get explicit policies, one per table, per the matrix below. No blanket enable.
7. **Boonz Health Skill** published in `.claude/skills/boonz-health/` that runs the governance + reconciliation checks on demand.

## Decisions (no open questions)

### F1 + F2 — RPC bypass + edit log starvation

**Decision A1:** Add a `bypass_violation_log` table. Append-only, captures every direct write to `refill_dispatching` that has `via_rpc != true` OR `rpc_name NOT IN (allow-list)`.

**Decision A2:** Build a BEFORE INSERT/UPDATE trigger `enforce_canonical_dispatch_write` on refill_dispatching. Phase 1 (immediate): RAISE WARNING + insert into bypass_violation_log. Phase 2 (after 2026-06-06, 7 days later): flip to RAISE EXCEPTION.

**Decision A3:** Allow-list (verified against pg_proc 2026-05-30):
```
'write_refill_plan',
'pack_dispatch_line',
'receive_dispatch_line',
'return_dispatch_line',
'swap_between_machines',
'repair_unbound_dispatch',
'repair_orphan_internal_transfer',
'cancel_dispatch_line',
'mark_dispatch_vox_sourced',
'mark_internal_transfer',
'sync_dispatch_expiry_from_pinned_wh' -- trigger writer, NULL rpc_name allowed
```

**Decision A4:** Triggered writes (system-only) are allow-listed by rpc_name='__trigger__' or NULL. The trigger checks for both `via_rpc=true OR (rpc_name IS NULL AND current_setting('app.via_trigger', true) = 'true')`. Defer the GUC plumbing to Stax (one line in each trigger that legitimately writes).

**Decision A5:** Automation refactor list. Grep `n8n/flows/*.json` + `supabase/functions/**/*.ts` + cron.job for direct INSERT/UPDATE/DELETE on refill_dispatching. Each call site refactored to the canonical RPC. Stax owns this in parallel with the warning-window deploy.

### F3 — Phantom consumer_stock drain (335 units / 79 rows)

**Decision B1:** One-shot canonical writer `drain_phantom_consumer_stock(p_wh_inventory_id uuid, p_units numeric, p_reason text)`. SECURITY DEFINER, role gate (operator_admin/superadmin only — this reduces stock and CS's hard rule normally blocks it; the bug006 evidence over 3 days IS the sign-off).

**Decision B2:** Run the drain on the 79 rows currently flagged by `v_consumer_stock_leaks`. Pre-baked reason: `'bug006_phantom_drain_2026-05-30_audit-finding-F3'`. NO per-row CS sign-off (the audit + 3-day repeat is the sign-off; the drain is toward truth not away from it).

**Decision B3:** Atomicity: each row's drain is its own transaction so a single failure doesn't roll back the whole batch.

### F4 — Plan-time WH pinning

**Decision C1:** Add `pinned_at_plan_time boolean NOT NULL DEFAULT true` to refill_dispatching. Existing rows backfill to `false` (they were stitch-time-pinned at best).

**Decision C2:** Engine patch (PRD-013 dependency): `write_refill_plan` writes `from_wh_inventory_id` AND `expiry_date` at plan-output time by FEFO-picking the best Active batch. If picking fails (no Active batch), log a procurement_gap entry and emit the dispatch row with from_wh_inventory_id=NULL — those become repair_unbound_dispatch candidates.

**Decision C3:** Stitch (engine_publish_to_refill_plan) STOPS overwriting from_wh_inventory_id when pinned_at_plan_time=true. The pin survives WEIMI overwrites.

**Decision C4:** repair_unbound_dispatch stays. The repair is for legacy rows + edge cases where plan-time picking genuinely failed.

### F5 — Stale-state escalator

**Decision D1:** New view `v_stuck_dispatch_states` joins refill_dispatching with state transition timestamps. Surfaces:
- rows where `packed=true` AND `picked_up=false` AND `packed_at < now() - 24h`
- rows where `action='Remove'` AND `returned=false` AND created_at < now() - 24h

**Decision D2:** Daily 6am Dubai cron `cron_stale_state_escalator` inserts each stale row into findings_ledger with severity='critical', source='stale_dispatch_state'. CS gets an email digest (defer the email piece to Stax; the ledger entry is the canonical "this needs attention").

### F6 — Findings ledger with closure lifecycle

**Decision E1:** New table `findings_ledger`:
```
finding_id          uuid PK default gen_random_uuid()
source              text NOT NULL  -- 'monitoring_alerts' | 'bypass_violation_log' | 'stale_dispatch_state' | 'manual'
source_ref          uuid           -- pointer to original row in source table (NULL for manual)
title               text NOT NULL
detail              jsonb NOT NULL DEFAULT '{}'
severity            text NOT NULL CHECK (severity IN ('info','warning','critical'))
status              text NOT NULL DEFAULT 'open' CHECK (status IN ('open','ack','assigned','resolved','auto_verified_healed'))
assigned_to         uuid REFERENCES user_profiles(id)
opened_at           timestamptz NOT NULL DEFAULT now()
ack_at              timestamptz
ack_by              uuid REFERENCES user_profiles(id)
resolved_at         timestamptz
resolved_by         uuid REFERENCES user_profiles(id)
resolution_note     text
last_seen_signal_at timestamptz   -- auto-updated by the detector cron
auto_healed_at      timestamptz   -- set when signal hasn't been seen in N days
```

**Decision E2:** Canonical writers:
- `ack_finding(p_finding_id uuid, p_note text)` — flips open → ack
- `assign_finding(p_finding_id uuid, p_owner_id uuid)` — sets assigned_to + status='assigned'
- `resolve_finding(p_finding_id uuid, p_resolution_note text)` — flips to resolved
- `ingest_alerts_into_ledger()` — system cron, idempotent, dedupes by (source, source_ref)

**Decision E3:** Auto-heal cron `cron_finding_auto_heal` daily: if `last_seen_signal_at < now() - 2 days` AND status IN ('open','ack','assigned'), flip to auto_verified_healed.

**Decision E4:** Initial backfill: ingest all 204 unacknowledged monitoring_alerts into the ledger as status='open'. The 24 critical ones get severity='critical'. CS triages by querying `SELECT * FROM findings_ledger WHERE status='open' AND severity='critical' ORDER BY opened_at`.

### F7 — RLS policies for 17 exposed tables

**Decision F1:** Per-table matrix. For each of the 17 tables, this PRD specifies the policy directly. No CS judgment calls required.

| Table | Read | Write |
|---|---|---|
| `cash_recovery_log` | authenticated | operator_admin, superadmin, manager |
| `commercial_agreements` | operator_admin, superadmin, manager | operator_admin, superadmin |
| `sales_leads` | authenticated | operator_admin, superadmin, manager |
| `sales_lead_activities` | authenticated | authenticated |
| `adyen_staging` | authenticated | service_role only |
| `weimi_staging` | authenticated | service_role only |
| `weimi_aisle_snapshots` | authenticated | service_role only |
| `weimi_device_status` | authenticated | service_role only |
| `monitoring_alerts` | authenticated | authenticated (insert only via DEFINER) |
| `bypass_violation_log` (new) | authenticated | service_role only |
| `findings_ledger` (new) | authenticated | authenticated via canonical RPCs only |
| `product_name_conventions` | authenticated | operator_admin, superadmin |
| `procurement_events` (already append-only RLS — re-verify) | authenticated | (no-op) |
| `inventory_control_attempt` | authenticated | service_role only |
| `refill_dispatching_edit_log` | authenticated | service_role only |
| `variant_action_log` (already RLS — re-verify) | authenticated | (no-op) |
| `write_audit_log` (already RLS — re-verify) | authenticated | (no-op) |

If the actual 17 differ from this list at apply time, halt and ask CS. Otherwise apply per the matrix.

### Boonz Health Skill (deliverable G)

**Decision G1:** Skill location: `.claude/skills/boonz-health/SKILL.md`. Operational on-demand.

**Decision G2:** Skill capabilities:
1. `boonz-health audit` — runs the audit playbook (the same queries the 28-May audit used), prints headline numbers, surfaces deltas vs last run.
2. `boonz-health triage` — opens the findings_ledger worklist, sorts by severity + age, suggests assignments.
3. `boonz-health reconcile` — runs the conservation-law check on dispatch (quantity ≥ filled_quantity ≥ driver_confirmed_qty), flags violations into ledger.
4. `boonz-health close-stale` — runs the auto-heal cron manually for verification.

## Phases (order of execution)

### Phase A — Backend infrastructure (autonomous, no CS-in-loop)

1. Migration `phaseG_health_findings_ledger` — creates findings_ledger table + 4 canonical writers + auto-heal cron.
2. Migration `phaseG_health_bypass_violation_log` — creates bypass_violation_log table + enforce_canonical_dispatch_write trigger in WARNING mode.
3. Migration `phaseG_health_pinned_at_plan_time` — adds boolean column to refill_dispatching with default true, backfills existing as false.
4. Migration `phaseG_health_drain_phantom_consumer_stock_rpc` — creates the drain RPC.
5. Migration `phaseG_health_stuck_state_escalator` — creates v_stuck_dispatch_states view + cron_stale_state_escalator.
6. Migration `phaseG_health_rls_policies_batch1` — applies RLS to the 17 tables per the matrix.

Cody reviews each migration. Apply once approved.

### Phase B — Data-fix execution (CS pre-approved per the audit; no per-row sign-off)

7. Execute `drain_phantom_consumer_stock` on the 79 rows from v_consumer_stock_leaks. Verify count → 0.
8. Execute `ingest_alerts_into_ledger` to backfill the 204 unacknowledged alerts. Verify ledger count = 204.

### Phase C — Engine pinning (PRD-013 territory, needs CS approval before deploy)

9. Patch `write_refill_plan` per Decision C2. Migration `phaseG_health_engine_plan_time_pin`. Cody review then HALT for CS approval before apply (engine is hot path).
10. Patch `engine_publish_to_refill_plan` per Decision C3.

### Phase D — Automation refactor (Stax)

11. Grep n8n + edge functions + cron for direct INSERTs to refill_dispatching. List each. Refactor to canonical RPC. Test in staging. Deploy.

### Phase E — Skill publication

12. Write `.claude/skills/boonz-health/SKILL.md` with the 4 capabilities. Test each on prod data. Commit.

### Phase F — 7-day cutover

13. Watch bypass_violation_log daily for 7 days (2026-05-30 → 2026-06-06). Resolve any legitimate-but-unallowlisted writers by adding them to the allow-list.
14. On 2026-06-06: flip enforce_canonical_dispatch_write from RAISE WARNING to RAISE EXCEPTION. Migration `phaseG_health_bypass_block_flip`.

## Hard rules (binding for the agent)

1. **NEVER raw-SQL a protected table.** Canonical RPC only.
2. **For data fixes that REDUCE stock (Phase B step 7)**: pre-approved per this PRD; cite finding_id and audit doc in the audit row reason. NO per-row prompt.
3. **For data fixes that ADD stock** (none in this PRD; refill update doc handled by PROGRAM-2026-05-26): standard CS sign-off rules apply.
4. **Engine patch (Phase C) requires CS approval before apply.** The engine touches every refill. HALT after Cody review.
5. **RLS policy apply (Phase A step 6)**: if the 17 tables surveyed at apply time differ from this PRD's matrix, halt + ask. Otherwise apply.
6. **All migrations Cody-reviewed.** No shortcuts.
7. **Stax owns automation refactor.** Backend agent doesn't touch n8n/edge fn code without Stax review.

## Acceptance criteria (per outcome)

- O1 F1+F2: `SELECT count(*) FROM bypass_violation_log WHERE occurred_at >= '2026-05-30'` shows real numbers (we expect ~30k/day initially, dropping as automation is refactored). After 2026-06-06: trigger raises EXCEPTION; new direct writes are rejected.
- O2 F3: `SELECT count(*) FROM v_consumer_stock_leaks` returns 0.
- O3 F4: `SELECT count(*) FROM refill_dispatching WHERE pinned_at_plan_time = true AND created_at >= '2026-06-01'` matches total refill dispatch count for that window (i.e., 100% pinned at plan time).
- O4 F5: `findings_ledger` has entries for every dispatch row stuck >24h. Daily cron job 14+ ran successfully.
- O5 F6: 204 alerts in findings_ledger. 24 critical have non-NULL assigned_to within 7 days.
- O6 F7: `SELECT relname FROM pg_class WHERE relrowsecurity=true AND relname IN (<17 tables>)` returns all 17. Each has at least one policy.
- O7 Boonz Health Skill: `.claude/skills/boonz-health/SKILL.md` exists and the 4 commands return non-empty output against prod.

## /goal command (paste into Claude Code)

````
/goal docs/prds/_programs/PROGRAM-2026-05-30-loophole-engine.md

Execute Phases A through E in order. Phase F is a calendar-driven 7-day window
and ships as its own commit on 2026-06-06.

The Refill Update doc is now in repo at
docs/refill-updates/2026-05-22-to-28_refill_update.md. This unblocks
PROGRAM-2026-05-26 Phase 1 data fixes which you can now run in PARALLEL
with this program's Phase A.

Hard rules (restated):
- Canonical RPCs only on protected tables.
- Phase B step 7 (drain phantom consumer_stock 79 rows) is PRE-APPROVED by
  CS via the audit finding F3. Cite finding_id and the audit doc in the
  audit reason. NO per-row prompt. This is the explicit carve-out from the
  no-stock-reduction rule.
- Phase C step 9 (engine plan-time pin) HALTS after Cody review for CS
  approval before apply. Engine is hot path.
- Phase A step 6 RLS apply: if the 17 surveyed tables differ from the PRD
  matrix, halt and ask. Otherwise apply per the matrix.
- All migrations Cody-reviewed. Stax review on any FE diff.
- If a step fails production verification, mark Blocked with the specific
  failing check, write a one-line blocked_summary, continue to the next.
- DO NOT spin on Stop hook diagnostics. If a phase genuinely cannot proceed,
  mark the phase Blocked with the explicit blocker, /goal clear, write a
  status memo, and stop.

End state: all 7 outcomes (O1-O7) satisfied OR marked Blocked-with-reason.
boonz-health skill published. All migrations applied or queued with
explicit Cody verdicts.
````

## Linked PRDs

- [[PROGRAM-2026-05-25-refill-week-fixes]] — earlier program; the F4 fix here finally addresses the root cause those PRDs were repairing reactively
- [[PROGRAM-2026-05-26-refill-data-reconciliation]] — Phase 1 batches now unblocked because the refill doc is in the repo
- [[PRD-013-engine-fefo-investigation]] — F4 finally has a concrete fix

## Linked memory

- [[feedback_no_destructive_changes]] — the F3 drain is the documented carve-out
- [[feedback_pod_vs_wh_expiry_scope]] — F4 fix preserves the pinned WH expiry through WEIMI churn
- [[feedback_verify_pg_proc_not_just_migration_file]] — RLS apply must verify the 17 tables live
- [[bug_consumer_stock_drain_asymmetry]] — bug006 origin context
- [[bug_phantom_dispatch_expiry]] — bug012 origin context (now addressed by F4 fix)
