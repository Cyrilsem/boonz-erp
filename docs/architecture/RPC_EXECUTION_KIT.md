# RPC Execution Kit (refill daily flow)

**Purpose (PRD-019 Phase B / AC-B1..B4):** the conductor boots with this. Every write RPC in the daily refill flow, with its exact signature, the gate it trips, how it behaves under the service (chat) context, and its one must-know gotcha. No session should re-discover any of this from `pg_proc`.

**Last validated:** 2026-06-16 (signatures fetched via `pg_get_functiondef` against `eizcexopcuoycuosittm`). If a call errors on arity or type, re-validate that one signature and bump this date.

**Service-context auth (applies to all DEFINER writers below unless noted):** the chat engine runs as the `service_role`, where `auth.uid()` is NULL. Every writer's role check is written `IF auth.uid() IS NOT NULL AND NOT EXISTS(... operator_admin ...) THEN RAISE` — so a NULL uid (service) BYPASSES the role gate. The FE runs as `authenticated` (operator_admin) and passes the same gate. Plan dates: always use `resolve_refill_plan_date()`, never `CURRENT_DATE + 1` (UTC bug).

---

## 0. Single-writer lock (PRD-019 D1 — acquire FIRST)

| RPC             | Signature                                                                      | Gate / behaviour                                                                                                                                                                                                       | Gotcha                                                                                                                                                                               |
| --------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| acquire         | `acquire_refill_plan_lock(p_plan_date date, p_context text)` -> jsonb          | Claims the plan_date for one writer context (`'commit'`, `'chat_engine'`). Re-entrant for the same context; steals locks older than 15 min; rejects a second live context. Sets session GUC `app.refill_lock_context`. | The chat engine and the FE Commit MUST each acquire before running any engine. Holding the lock is what lets your own engine calls pass the D1b guard.                               |
| release         | `release_refill_plan_lock(p_plan_date date)` -> jsonb                          | Releases the lock (DELETE) and clears the GUC.                                                                                                                                                                         | Always release in a `finally` so a crash does not strand the date (the 15-min steal is the backstop).                                                                                |
| force release   | `force_release_refill_plan_lock(p_plan_date date, p_reason text)` -> jsonb     | Clears a wedged lock regardless of holder. operator_admin/superadmin only; reason >= 10 chars; audited.                                                                                                                | Use only when a lock is stuck and the 15-min TTL has not elapsed.                                                                                                                    |
| commit (atomic) | `commit_refill_plan_atomic(p_plan_date date, p_machine_names text[])` -> jsonb | The canonical commit: ONE transaction does approve_pod -> scoped finalize -> stitch -> approve_refill + invariants; rolls back on any failure. Returns verified `{output_rows, dispatch_rows, machines, lines_built}`. | Replaces the multi-step saga. Acquire the lock first; release in `finally`. The engines now refuse PER-MACHINE, so a fresh machine commits on a date with other dispatched machines. |

The engines (`engine_add_pod` / `engine_swap_pod` / `engine_finalize_pod`) REFUSE (PRD-019 D1b) to run for a plan_date that already has `approved` `refill_plan_output` rows, or while the lock is held by a different context. To rebuild an approved plan, reset first (see §4).

---

## 1. Stage 1 — pick / confirm the machine set

| RPC     | Signature                                                                              | Gate                                               | Gotcha                                                                                                                                                 |
| ------- | -------------------------------------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| pick    | `pick_machine_manually(p_plan_date date, p_machine_id uuid, p_reason text)` -> jsonb   | Inserts/sets `machines_to_visit` to `picked`.      | **Auto-confirms the whole plan_date** (sets the date's gate to confirmed). After this, Gate-0 is satisfied for ALL picked machines, not just this one. |
| confirm | `confirm_machines_to_visit(p_plan_date date)` -> jsonb                                 | Flips `picked` -> confirmed for the date (Gate 0). | Idempotent; `pick_machine_manually` already does this, so an explicit confirm is only needed when machines were picked by the cron/other path.         |
| unpick  | `unpick_machine_to_visit(p_plan_date date, p_machine_id uuid, p_reason text)` -> jsonb | Removes a machine from the visit set.              | Will not unpick a machine whose plan is already approved/dispatched.                                                                                   |

`engine_*` trip `_assert_gate_zero(p_plan_date)`: they raise if any machine is `picked` but unconfirmed. Pick (or confirm) before running the engine.

---

## 2. Stage 2 — build the pod plan (engine, service-safe)

| RPC                  | Signature                                                                                                                  | Gate                                                                          | Gotcha                                                                                                                                      |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| add (refill)         | `engine_add_pod(p_plan_date date, p_days_cover integer)` -> jsonb                                                          | Gate 0 + D1b writable guard. DELETEs and rebuilds `pod_refills` for the date. | Destructive rebuild of the working set. v17 `cover_capped`: target = velocity cover, ceiling = capacity.                                    |
| swap                 | `engine_swap_pod(p_plan_date date, p_max_swaps_per_machine integer, p_min_pearson numeric, p_days_cover integer)` -> jsonb | Gate 0 + D1b guard. Rebuilds `pod_swaps`.                                     | Runs AFTER add (consumes the dead-tags add wrote).                                                                                          |
| finalize (plan-wide) | `engine_finalize_pod(p_plan_date date)` -> jsonb                                                                           | D1b guard (plan-wide). Delegates to the 2-arg.                                | Materializes `pod_refills`+`pod_swaps` -> `pod_refill_plan` draft rows.                                                                     |
| finalize (scoped)    | `engine_finalize_pod(p_plan_date date, p_machine_ids uuid[])` -> jsonb                                                     | D1b guard (machine-scoped).                                                   | **Use the scoped form inside Commit** so it cannot un-approve a sibling machine. Preserves an `approved` row when qty+action are unchanged. |

---

## 3. Stage 2 edits — manual row ops (FE + chat)

| RPC         | Signature                                                                                                                                                                                          | Gate                                                    | Gotcha                                                                                                                                                                                                                                                                       |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| add row     | `add_pod_refill_row(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text, p_qty integer, p_reason text, p_conductor_session text)` -> jsonb                  | Refuses if linked `refill_plan_output` is past pending. | **Capacity-clamped (PRD-019 A2):** REFILL/ADD_NEW qty is capped at shelf headroom (`v_shelf_capacity`); returns `clamp_reason='capacity_capped'` + the cap. ADD_NEW also returns `add_new_projection` (per-flavor split). **Read `v_shelf_capacity` before choosing a qty.** |
| edit row    | `edit_pod_refill_row(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text, p_new_qty integer, p_reason text, p_conductor_session text)` -> jsonb             | Same locked-output refusal.                             | Same capacity clamp. `p_new_qty = 0` records an edit_type `stop`.                                                                                                                                                                                                            |
| swap row    | `swap_pod_refill_row(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_old_pod_product_id uuid, p_new_pod_product_id uuid, p_action text, p_reason text, p_conductor_session text)` -> jsonb | Requires an existing draft row.                         | **Requires a pre-existing draft row and carries the OLD qty** to the new product. If there is no row yet, `add_pod_refill_row` first.                                                                                                                                        |
| stop row    | `stop_pod_refill_row(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text, p_reason text)` -> jsonb                                                          | Locked-output refusal.                                  | Zeroes the planned qty (soft stop), keeps the row for audit.                                                                                                                                                                                                                 |
| restore row | `restore_pod_refill_row(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text)` -> void                                                                       | —                                                       | Un-stops / restores a previously removed row. Returns void (no payload).                                                                                                                                                                                                     |

After any engine edit (add/swap rows via the engine), re-run `engine_finalize_pod` for the affected machines before Commit.

---

## 4. Commit tail + reset

| RPC                  | Signature                                                                                     | Gate                                                                                                           | Gotcha                                                                                                   |
| -------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| approve pod          | `approve_pod_refill_plan(p_plan_date date, p_machine_names text[])` -> jsonb                  | Flips `pod_refill_plan` draft -> approved for the named machines.                                              | Machine **names**, not ids. Scope to the committed machines.                                             |
| stitch (dry)         | `stitch_pod_to_boonz(p_plan_date date, true)` -> jsonb                                        | Read-only projection.                                                                                          | Dry-run: returns what WOULD be written; writes nothing. Use to preview line/batch fan-out.               |
| stitch (commit)      | `stitch_pod_to_boonz(p_plan_date date, false)` -> jsonb                                       | Writes `refill_plan_output` via `write_refill_plan`.                                                           | **Leaves `refill_plan_output` at `pending`.** Nothing dispatches until `approve_refill_plan`.            |
| approve refill       | `approve_refill_plan(p_plan_date date, p_machine_names text[])` -> jsonb                      | Flips output `pending` -> `approved`; the `trg_fire_dispatch_on_approval` trigger writes `refill_dispatching`. | **This is the dispatch bridge — always the FINAL step.** Skipping it ends "stitched but not dispatched". |
| commit log           | `commit_refill_plan(p_plan_date date, p_comment text, p_machine_ids uuid[])` -> jsonb         | Appends to `refill_commit_log`.                                                                                | Audit/comment only; does not move stock.                                                                 |
| reset (undispatched) | `reset_approved_undispatched(p_plan_date date, p_machine_ids uuid[], p_reason text)` -> jsonb | Archives approved-but-undispatched output back to a rebuildable state.                                         | Run this BEFORE re-running the engine on an approved date (the D1b guard blocks otherwise).              |
| reset + restitch     | `reset_and_restitch(p_plan_date date, p_machine_ids uuid[], p_reason text)` -> jsonb          | Reset + re-stitch in one.                                                                                      | Scoped to the given machines.                                                                            |

---

## 5. Out-of-band

| RPC                   | Signature                                                                         | Gotcha                                                                                                                                                                                                                                  |
| --------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| receive PO            | `receive_purchase_order(p_po_id text, p_lines jsonb, p_additions jsonb)` -> jsonb | **Hard-requires a non-null batch expiry on every received line.** A null expiry raises.                                                                                                                                                 |
| product_mapping setup | (table writes via the mapping admin path)                                         | `is_global_default` is GENERATED (do not set it). `split_pct` (per machine) MUST sum to 1.0 across a pod product's variants or the stitch inflates the fan-out. Mappings are per-machine with a global fallback (`machine_id IS NULL`). |

---

## 6. Order of operations

**Full route (chat or FE):**

1. `acquire_refill_plan_lock(date, 'chat_engine' | 'commit')`
2. `pick_machine_manually(date, id, reason)` per machine (auto-confirms) — or `confirm_machines_to_visit(date)`
3. `engine_add_pod(date, days_cover)` -> `engine_swap_pod(date, max, min_pearson, days_cover)` -> `engine_finalize_pod(date)`
4. Manual edits (`add/edit/swap/stop_pod_refill_row`); read `v_shelf_capacity` before any fill
5. If engine-level edits were made, re-run `engine_finalize_pod(date)`
6. `approve_pod_refill_plan(date, names)` -> `stitch_pod_to_boonz(date, false)` -> `approve_refill_plan(date, names)`
7. `release_refill_plan_lock(date)`

**Path C (single machine):** as above but `engine_finalize_pod(date, ARRAY[id])` and approve/stitch/approve scoped to that one machine. Never run plan-wide finalize when only one machine is being committed (it can un-approve siblings).

**Post-commit amend:** `reset_approved_undispatched(date, ids, reason)` (or `reset_and_restitch`) FIRST, then re-enter at step 3 for the affected machines. The engines refuse to rebuild an approved date until it is reset (PRD-019 D1b).

**ADD_NEW seed convention (PRD-019 A3):** single-variant -> default fill to headroom. First-time multi-variant placement -> the RPC returns `add_new_projection` (per-flavor split by `split_pct`); confirm the line count before approving rather than blindly filling headroom across every flavor.
