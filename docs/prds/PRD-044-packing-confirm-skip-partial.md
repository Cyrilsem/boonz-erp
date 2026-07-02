# PRD-044 - Packing confirm must accept skip / not-filled / partial

**Status:** ✅ Shipped 2026-06-21 (backend P0+P1 + P2 FE two-button confirm SHIPPED to prod, deploy `37ce14d`). swaps_enabled untouched (false).
**Owner:** CS (cyrilsem@gmail.com)

## EXECUTION LOG (2026-06-21)

- **P0** `prd044_p0_packing_confirm_state` APPLIED: `refill_dispatching.not_filled_reason`, `dispatch_pack_confirmation.final` (default true), `v_machine_pack_status` re-exposed with `pack_final` + `pack_state` (open/in_progress/completed). The `pack_outcome_enum` {packed,partial,not_filled} + resolved/partial/not_filled counters pre-existed. Cody Art 2/12/14.
- **P1** `prd044_p1_confirm_two_mode` APPLIED: new 5-arg `confirm_machine_packed(...,p_final)` two-mode (Save=false never blocks → in_progress + {resolved_n,remaining_n}; Finish=true blocks on unresolved → completed); 4-arg form delegates to Finish (no drop). `pack_dispatch_line` records `not_filled_reason` from the picks payload. Cody Art 1/4/5/8/12.
- **Tests (BEGIN..ROLLBACK, synthetic 2026-12-01, ACTIVATE-2005):** T3 partial filled=3 ✓; T4 not_filled+reason ✓; T5 Finish blocked / Save saved ✓; T12 Save→skip→Finish completed ✓; T7 idempotent ✓; T2/T10/T11 covered; T6 repack gate + T8 audit preserved.
- **P2 FE SHIPPED 2026-06-21** (deploy commit `37ce14d`, boonz-erp.vercel.app): two-button bottom bar — **Save & come back** (`confirm_machine_packed(...,p_final:=false)`, enabled ≥1 resolved → in_progress, lossless resume via re-fetch + editingAfterSave) and **Finish** (`p_final:=true`, gated resolved==total → completed). Pick 0+reason→not_filled and partial picks already flowed through `pack_dispatch_line`. 44px targets, aria-labels, focus-visible. Build green; prod deploy success. (Full shelf-grouped resume UI is part of PRD-047 B3, deferred.)
  **Created:** 2026-06-21
  **Severity:** HIGH. Blocks refill-day completion: operators cannot confirm a machine unless every line is fully packed, so skipped, not-filled, and partially-picked lines force a manual workaround on /refill. Operators also need to confirm progress, leave, and come back to finish.

## 0. Problem (observed 2026-06-21)

On `/field/packing/<machine>`, "Confirm packing (N packed, M skipped)" does not apply when any line is skipped or Not Filled, and partial picks (Pick Qty < Req Qty) cannot be committed. CS had to open `/refill` and hand-mark rows as refilled/packed. This is illogical and slow on refill day.

## 1. Root cause (decided diagnosis)

`confirm_machine_packed` treats only `packed = true` lines as resolved. Skipped (`skipped=true`) and not-filled (pick 0 / no stock) lines are neither packed nor counted as resolved, so the machine never reaches a confirmable state, and `pack_dispatch_line` does not record a pick quantity lower than planned as a valid terminal state. The FE button posts an all-or-nothing payload.

## 2. The change (decided, no options)

Define a line as **resolved** when it is in exactly one terminal state:

- `packed` (pick_qty >= 1, up to planned),
- `skipped` (operator skip with reason),
- `not_filled` (pick_qty = 0 because no pickable stock or "not needed"; records reason).

Rules:

1. `pack_dispatch_line` accepts `pick_qty` in `[0 .. planned]`. `pick_qty = 0` with a reason sets state `not_filled` (NOT an error). `0 < pick_qty < planned` sets `packed` with `packed_qty = pick_qty` and flags `partial = true`.
2. Add/normalize a `not_filled` terminal state on `refill_dispatching` (boolean `not_filled` + `not_filled_reason`, or reuse `skipped` with a distinct reason taxonomy; **decided: dedicated `not_filled` flag** so reporting separates "no stock" from operator "skip").
3. Partial and not-filled deltas (planned - packed_qty) release their warehouse commitment immediately (ties to PRD-045).
4. **Two confirm modes (decided).** `confirm_machine_packed(..., p_final boolean DEFAULT true)`:
   - **Save & come back (`p_final=false`)**: commit + dispatch every line resolved SO FAR (packed / partial / skipped / not_filled), lock those, and leave the machine OPEN. Allowed at ANY point, even at 0% or partial. Sets machine pack status `in_progress`. Returns `{saved:true, resolved_n, remaining_n}`. The operator can leave and resume later. NO requirement that all lines be resolved.
   - **Finish (`p_final=true`)**: requires every non-cancelled line resolved (packed OR skipped OR not_filled); writes `packed_at`, `packed_by`, sets status `completed`; returns `{confirmed:true, packed_n, partial_n, skipped_n, not_filled_n}`. NEVER requires 100% packed, only 100% resolved.
5. **Resume is lossless.** Reopening an `in_progress` machine shows already-resolved lines locked (packed protected) and the remaining lines editable; done work is never re-entered. Save/resume may repeat any number of times before Finish. Track state via `v_machine_pack_status` (`in_progress` vs `completed`).
6. **Saved lines dispatch immediately.** Lines resolved during a Save go to the driver right away, so a half-packed machine still hands off what was done without waiting for Finish.
7. `protect_packed_dispatch_row` blocks edits to packed/saved lines; partial/not-filled remain editable until Finish.
8. FE: two buttons. Primary **Finish** (enabled only when `resolved == total`, cancelled excluded) and secondary **Save & come back** (enabled whenever `>= 1` line is resolved). Show the running breakdown. Remove the need to visit `/refill`.

## 3. Testing rules (all must pass; BEGIN..ROLLBACK where DB)

| #   | Test                                      | Expected                                                                                  |
| --- | ----------------------------------------- | ----------------------------------------------------------------------------------------- |
| T1  | all lines packed full                     | confirm ok; packed_n = lines; partial_n = 0                                               |
| T2  | mix packed + 1 skipped                    | confirm ok; skipped_n = 1; skipped line not sent to driver                                |
| T3  | partial pick (3 of 5)                     | confirm ok; packed_qty = 3; partial flagged; 2 units released to WH                       |
| T4  | not-filled (pick 0 + reason)              | confirm ok; state not_filled; packed_qty 0; reason stored                                 |
| T5  | one line unresolved + Finish              | Finish BLOCKED, names the line; Save (p_final=false) still SUCCEEDS                       |
| T6  | re-open packed machine (`repack_machine`) | allowed only per existing gate; packed rows protected                                     |
| T7  | idempotency                               | re-confirm/re-save is a no-op, not a double-write                                         |
| T8  | audit                                     | every state change writes `write_audit_log` via the canonical RPC                         |
| T9  | FE                                        | Finish enabled at resolved==total; Save enabled at >=1 resolved; /refill no longer needed |
| T10 | Save at partial (3 of 10 lines resolved)  | status `in_progress`; the 3 dispatch now; 7 remain editable; no error                     |
| T11 | resume after Save                         | reopened machine shows 3 locked + 7 editable; no done work re-entered                     |
| T12 | Save then Finish later                    | second call with all resolved closes the machine; saved lines not double-dispatched       |

## 4. Phasing / gates

- **P0** Dara: add `not_filled` + `not_filled_reason` columns and a machine pack-status field (`in_progress` / `completed`, exposed via `v_machine_pack_status`); forward migration. Cody review (Articles 1,4,5,8,12).
- **P1** Rewrite `pack_dispatch_line` + `confirm_machine_packed` with the `p_final` two-mode contract (Save & come back vs Finish). Forward CREATE OR REPLACE. Cody verdict. Run T1-T12 in BEGIN..ROLLBACK on a replay machine. STOP only on a failing test.
- **P2** Stax: FE wires two buttons (Finish / Save & come back) and lossless resume; T9-T12. Deploy.
- No change to picker/engine. Pairs with PRD-045 (commitment release) and PRD-047 (FE).
