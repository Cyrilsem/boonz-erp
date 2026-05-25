# PRD-014 — Pod inventory inline-adjust canonical writer + A.4 hard-block trigger flip

**Status:** Draft (filed 2026-05-25 as the deferred-work owner of PRD-013 P3.B / P3.C / P3.E)
**Owner:** TBD
**Source decision:** PRD-013 G4 CS approval to "ship A.3 cron now; defer A.4 trigger to follow-up PRD."
**Related:** [PRD-013 Phase 3 summary](../prd-013/phase_3_summary.md), [PRD-013 source PRD](../inventory/prd_013_pod_inventory_edits_canonical_approval.md), Constitution Article 3.

## 1. Why this PRD exists

PRD-013 P3.A caller audit (committed at `5cf6f66`) surfaced **44 direct UPDATEs to `pod_inventory` in the last 7 days** (41 warehouse + 3 operator), all originating from the five inline qty/location/status handlers in `src/app/(field)/field/inventory/page.tsx` at lines 938, 1029, 1070, 1140, 1236. These were carved out of PRD-013 §4 as an explicit non-goal: "inline qty edits stay on current path."

PRD-013 §A.4 specified a hard-block trigger that would `RAISE EXCEPTION` on any direct UPDATE to `pod_inventory` touching `current_stock`, `estimated_remaining`, `status`, or `removal_reason`. Flipping that trigger today would break the field PWA because the five handlers still write direct. The G4 CS decision was: ship the auto-expire cron (P3.D), defer the trigger to a follow-up PRD that owns migrating the handlers first.

**This PRD is that follow-up.** It closes the pod_inventory Article 3 surface entirely.

## 2. Day-0 baseline (recorded 2026-05-25, the closing day of PRD-013)

```sql
SELECT operation, rpc_name, via_rpc, actor, count(*) writes_7d, max(occurred_at) last_seen
FROM public.write_audit_log
WHERE table_name = 'pod_inventory' AND occurred_at > now() - interval '7 days'
GROUP BY operation, rpc_name, via_rpc, actor
ORDER BY via_rpc ASC, writes_7d DESC;
```

| operation    | rpc_name    | via_rpc | actor                    | writes_7d | last_seen           | classification                                             |
| ------------ | ----------- | ------- | ------------------------ | --------- | ------------------- | ---------------------------------------------------------- |
| UPDATE       | `<null>`    | false   | bf32624e-... (warehouse) | 41        | 2026-05-25 12:58:51 | **Active.** Field PWA inline qty/location/status handlers. |
| UPDATE       | `<null>`    | false   | 82bba4ee-... (operator)  | 3         | 2026-05-25 07:21:10 | **Active.** Same handlers, operator role.                  |
| UPDATE       | `<null>`    | false   | `<null>` (anonymous)     | 3         | 2026-05-19 12:34:27 | Pre-A.5b backfill, stopped 6+ days ago. Not active.        |
| INSERT       | `<null>`    | false   | `<null>` (anonymous)     | 2         | 2026-05-19 14:08:30 | Pre-A.5b backfill, stopped 6+ days ago. Not active.        |
| (all others) | (named RPC) | true    | (various)                | many      | 2026-05-25          | Properly attributed. No action needed.                     |

**Closure metric:** active direct-write count from the two actors above must reach **0 over a 7-consecutive-day window** before the trigger can flip safely.

## 3. Scope

In:

- Design and apply a canonical `inline_adjust_pod_inventory` RPC covering the three inline operations: quantity adjust, location (shelf) change, and status flip.
- Cabinet-safe optimistic-concurrency token (FOR UPDATE + `updated_at` precondition, or similar) to handle two drivers editing the same pod row in the same session.
- Rewire all five FE call sites in `src/app/(field)/field/inventory/page.tsx` to call the new RPC; remove `.from("pod_inventory").update(...)` calls.
- Wait 7 days clean (zero `via_rpc=false` UPDATEs by an active actor against `pod_inventory`).
- Apply the PRD-013 §A.4 hard-block trigger (spec retained in source PRD).
- Section 9 cases 13 and 14 from PRD-013 must PASS post-flip.

Out:

- No changes to sales_lines, Adyen, driver app outside `field/inventory/page.tsx`, VOX sourcing.
- No DELETE path on pod_inventory; archive-only via existing `backfill_archive_pod_inventory_row` per CS sign-off.
- No reopening of PRD-013's unified approve/reject; those stay as the canonical writers for the edit-approval flow.

## 4. Phases (sketch — full design at kickoff)

| Phase | Deliverable                                                                                                                                             | Gate                                                                   |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| 1     | Dara designs `inline_adjust_pod_inventory(p_pod_inventory_id, p_op, p_new_value, p_reason)` + Cody review + apply.                                      | CS sign-off on RPC signature + concurrency model.                      |
| 2     | Stax rewires the 5 FE handlers. Build clean. Headless UAT against live Vercel. Cody Article 3 review.                                                   | CS sign-off on FE diff.                                                |
| 3     | 7-day clean monitoring window. Daily snapshot of the day-0 query above; report any `via_rpc=false` row.                                                 | All 7 days must show zero from the two active actors before flipping.  |
| 4     | Apply the §A.4 hard-block trigger from PRD-013. Run Section 9 cases 13 + 14 (direct UPDATE blocked).                                                    | Tests PASS.                                                            |
| 5     | Article 13 deprecation note + 90-day monitor on `auto_expire_pod_add_proposals` in favor of `auto_expire_pod_inventory_edits` (PRD-013 Cody follow-up). | Monitor window opens 2026-08-23 (90 days post first PRD-013 cron run). |

## 5. Open questions (TBD at kickoff)

- Concurrency model: optimistic via `updated_at` ETag, or pessimistic via `FOR UPDATE`? Driver app caches stale state across sessions; need to surface conflicts gracefully (driver shouldn't re-do a full session because someone else edited one shelf).
- Status-flip dispatch: does inline status flip go through `inline_adjust_pod_inventory(..., p_op='status_flip', ...)` or through a dedicated `archive_pod_inventory_row` aliased to the existing `backfill_archive_pod_inventory_row` helper? Latter has the cleaner audit reason field but is currently gated to superadmin + operator_admin (drivers can't call it).
- Should the trigger be widened to fire on INSERT too once PRD-012's `idx_pod_inv_active_shelf` defense is in the canonical path? (Today INSERTs are caught by PRD-012's separate INSERT trigger; UPDATE trigger is the gap.)

## 6. Definition of done

1. Section 9 cases 13 and 14 PASS (direct UPDATE raises).
2. `write_audit_log` for `pod_inventory` shows zero `via_rpc=false` writes for 7 consecutive days post-flip.
3. The five FE inline call sites grep-clean for `.from("pod_inventory").update`.
4. Phase 3 summary appended with "trigger flip confirmation" entry.
5. Constitution Amendment 004 + 008 (joint elevation of `pod_inventory_edits` to Appendix A) drafted and approved.

## 7. Do NOT

- Change the PRD-013 unified approve/reject RPC behavior.
- Modify `v_pod_inventory_expiry_status`.
- DELETE pod_inventory rows; archive only.
- Skip the 7-day clean window — the trigger flip is the part most likely to break the field PWA if there's a missed caller, and the audit log is the only safety net.
- Use em dashes in PRD prose (project convention).
