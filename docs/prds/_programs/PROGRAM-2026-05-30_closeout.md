# PROGRAM-2026-05-30-loophole-engine — Closeout

**Closed:** 2026-05-30 ~09:00 UTC
**Phases shipped:** A, B, C, D, E (per CS scope; F is calendar-bound to 2026-06-06)
**Source PRD:** [docs/prds/\_programs/PROGRAM-2026-05-30-loophole-engine.md](./PROGRAM-2026-05-30-loophole-engine.md)

## Outcomes mapped to PRD

| Outcome                                                      | Status                                                                  | Evidence                                                                                                        |
| ------------------------------------------------------------ | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| O1 — F1+F2: refill_dispatching writes via canonical RPC only | ✅ Phase 1 WARNING active; cutover to EXCEPTION on 2026-06-06 (Phase F) | A.2 trigger live; C-L-a expanded allow-list to 22 verified writers; Phase D cataloged 13+ FE bypassers for Stax |
| O2 — F3: 335-unit phantom drain                              | ✅                                                                      | `SELECT count(*) FROM v_consumer_stock_leaks` returns 0                                                         |
| O3 — F4: 100% pinned_at_plan_time on new dispatches          | ✅ infrastructure live; verifies on next push                           | A.3 column added; C-a patched push_plan_to_dispatch to FEFO-pin at stitch time; FEFO index installed            |
| O4 — F5: stale-state escalator daily                         | ✅                                                                      | A.5 view + cron_stale_state_escalator at 02:00 UTC daily                                                        |
| O5 — F6: findings_ledger with lifecycle                      | ✅                                                                      | A.1 table + 4 RPCs + auto-heal cron + hourly ingest; 206 alerts backfilled                                      |
| O6 — F7: RLS on 17 exposed tables                            | ✅                                                                      | A.6 batch; 0 RLS-disabled tables remain in public                                                               |
| O7 — Boonz Health Skill                                      | ✅                                                                      | E published at `.claude/skills/boonz-health/SKILL.md`; discoverable                                             |

## Migrations applied to prod (eizcexopcuoycuosittm)

1. `phaseG_health_findings_ledger`
2. `phaseG_health_findings_ledger_hotfix_unique_index` (partial-index ON CONFLICT fix)
3. `phaseG_health_bypass_violation_log`
4. `phaseG_health_pinned_at_plan_time`
5. `phaseG_health_drain_phantom_consumer_stock_rpc`
6. `phaseG_health_stuck_state_escalator`
7. `phaseG_health_rls_policies_batch1`
8. `phaseG_health_drain_phantom_consumer_stock_batch_runner`
9. `phaseG_health_phase_c_engine_pin_and_allowlist`

## CS-authorized decisions made during execution

1. **Phase A.6 RLS scope expansion** — 10 uncovered tables added beyond the PRD F1 matrix; default policy = authenticated SELECT + service_role-only writes.
2. **Phase C-a + L-a** — engine stitch target = push_plan_to_dispatch (not write_refill_plan); allow-list expanded to 22 verified writers.

## Cody-driven revisions caught at review

1. Phase A.1 — partial unique index → non-partial (ON CONFLICT compatibility); add tg_audit_findings_ledger in same migration; strip em-dashes; deterministic uuid mapping for monitoring_alerts.alert_id.
2. Phase A.4 batch runner — NULL role guard (security gap); rpc_name attribution = the actual batch function.
3. Phase C — drop 4 misclassified allow-list entries (record_variant_correction + 3 triggers, none directly INSERT); add FEFO index; verify the second push_plan_to_dispatch overload is dead (it is).

## Pending follow-ups (separate work)

1. **Phase F (2026-06-06)** — flip A.2 trigger from WARNING to EXCEPTION via separate migration after Stax stabilizes the 13+ FE bypassers in Phase D.
2. **Phase D refactor (Stax-owned)** — 13+ FE direct-write call sites need refactor to canonical RPCs. Worksheet: [docs/prds/\_programs/phase_d_audit/PROGRAM-2026-05-30_phase_d_audit.md](./phase_d_audit/PROGRAM-2026-05-30_phase_d_audit.md).
3. **Article 13 deprecation of push_plan_to_dispatch(text, date) overload** — zero callers verified 2026-05-30; safe to SECURITY INVOKER + REVOKE EXECUTE; 90-day monitor; then DROP.
4. **drain_phantom_consumer_stock + batch_runner REVOKE EXECUTE** — both functions can be REVOKEd from authenticated after the F3 backlog is confirmed clean for 30 days.
5. **Phase D bypass_violation_log analysis** — after 24-48h of soak, query `SELECT rpc_name, count(*) FROM bypass_violation_log GROUP BY rpc_name ORDER BY 2 DESC` and surface to Stax for prioritization.
6. **MIGRATIONS_REGISTRY.md + RPC_REGISTRY.md** — add the 9 PROGRAM-2026-05-30 migrations and 6 new canonical RPCs (ack_finding, assign_finding, resolve_finding, ingest_alerts_into_ledger, cron_finding_auto_heal, drain_phantom_consumer_stock, drain_phantom_consumer_stock_batch_run, cron_stale_state_escalator, enforce_canonical_dispatch_write). Deferred to a docs-only commit.

## Acceptance numbers at closeout

```sql
SELECT
  (SELECT count(*) FROM v_consumer_stock_leaks)                                  AS o2_leaks_remaining,         -- 0 ✅
  (SELECT count(*) FROM findings_ledger WHERE source='monitoring_alerts')        AS o5_alerts_in_ledger,        -- 206 ✅
  (SELECT count(*) FROM pg_class
   WHERE relkind='r' AND relnamespace='public'::regnamespace AND relrowsecurity=false) AS o6_rls_disabled,      -- 0 ✅
  (SELECT count(*) FROM cron.job
   WHERE jobname IN ('findings_ledger_auto_heal','findings_ledger_alerts_ingest','stale_dispatch_state_escalator')) AS crons_live;  -- 3 ✅
```

## What Phase F needs

On 2026-06-06 morning, before flipping the trigger:

1. `SELECT rpc_name, count(*) FROM bypass_violation_log WHERE occurred_at > '2026-05-30'::date AND rpc_name IS NULL GROUP BY rpc_name ORDER BY 2 DESC LIMIT 20`
2. If count = 0 (zero null-rpc_name rows), Stax has cleared all FE bypassers — safe to flip.
3. If count > 0, defer the flip migration by N days, continue Stax's refactor.
4. The flip migration is one-liner: change `RAISE WARNING` to `RAISE EXCEPTION` in `enforce_canonical_dispatch_write` (and remove the INSERT into bypass_violation_log, since EXCEPTION pre-empts row commit anyway).
