# PRD-030: Partial Pack — eliminate the dark-stage block on out-of-stock lines

**Date:** 2026-06-14
Status: Closed 2026-07-02 (PRD-071 sweep). Reason: superseded by PRD-044 packing confirm/skip/partial (shipped 2026-06-21) and the PRD-049 packing phases. Reopen by deleting this line.
**Severity:** Critical (operational). A single unfillable line freezes a whole machine: it never reaches packed, so the driver cannot pick up or dispatch, and the bag sits idle.
**Owner:** Dara (state model) to Cody (constitutional review of every SECURITY DEFINER fn + DDL) to Stax (packing FE + driver app), assistant orchestrates.
**Related:** Builds on EOD auto-release (`release_stale_unpacked_dispatches`) and the packing-confirm gate in stitch v17.

---

## 1. Problem

When a product that was planned for refill has no valid warehouse stock at pack time, the packer cannot complete that line and the machine drops into a dark state.

Confirmed in the live function:

`pack_dispatch_line(p_dispatch_id, p_picks, p_packed_by)` requires each pick to carry a `from_wh_inventory_id` and raises `WH row % has only % units, cannot pick %` when `warehouse_stock < pick_qty`. So a zero-stock line has no legal pack path. The only escape today is `skip_dispatch_line`, which records the line as SKIPPED.

The machine is treated as ready only when every included line is packed. An out-of-stock line that is neither packed nor skipped leaves the machine partially packed. The driver app gates pickup and dispatch on packed/dispatched, so the machine goes dark: products are physically ready to go but the system will not release them.

Today (2026-06-14) this hit 4 lines across two machines (2403 Pepsi Black + Coke Regular, 2401 Pepsi Black + Coke Regular) and forced manual `skip_dispatch_line` plus `add_dispatch_row` substitutions just to free the bags. That workaround is not available to a warehouse packer in the field.

## 2. Principle (CS directive)

If the warehouse confirms packing is done, the machine is packed. Lines that could not be filled are shown as not filled and travel with the machine; they never block pickup or dispatch.

Not filled is a first-class, expected outcome, distinct from skipped (operator chose to drop) and cancelled (line voided). It means planned, attempted, no stock.

## 3. Scope

In scope: line-level not-filled state, a machine-level confirm-packing action that completes on packed-or-resolved, packing FE, driver app visibility, reporting of unfilled demand.

Out of scope: why the warehouse was short (that is procurement and the stitch reservation gap in PRD-031). This PRD makes the shortage non-blocking and visible, not zero.

## 4. Data model (Dara, Cody-reviewed)

`refill_dispatching` already carries `filled_quantity`, `packed`, `skipped`/`skip_reason`, `driver_outcome`/`driver_outcome_qty`. Reuse, do not proliferate state.

1. Define a line as resolved for packing when `packed = true` OR `skipped = true` OR `include = false` OR it is explicitly marked not-filled.
2. Add a not-filled marker that is auditable and not confused with skip. Preferred: a dedicated `pack_outcome` enum on the line (`packed`, `partial`, `not_filled`) set by the packing RPC, plus `filled_quantity` (0 for not_filled, < quantity for partial). Dara to choose between a new column and reusing `driver_outcome`; do not overload skip.
3. A line marked `not_filled` keeps its planned `quantity` for demand and procurement reporting; `filled_quantity = 0`.

## 5. RPCs (Cody-reviewed, forward migrations, no \_v2)

1. `pack_dispatch_line` (amend): allow a confirmed zero/partial pick. A pick of 0 with an explicit `p_not_filled := true` (or a partial `pick_qty < quantity`) sets `pack_outcome` and `filled_quantity` without raising, and never debits the warehouse for the missing units. Keep the BUG-006 `from_wh_inventory_id` guard for any units actually picked.
2. New canonical `confirm_machine_packed(p_machine_name, p_dispatch_date, p_packed_by, p_reason)`: marks the machine packed when every included line is resolved (packed, partial, not_filled, or skipped). It does not invent picks; it requires that every unresolved line first be packed or marked not_filled, then flips the machine to packed and lets the dispatch/pickup gate open. Returns a per-line summary (packed, partial, not_filled).
3. The driver pickup/dispatch gate keys off machine-packed, not off every line being fully filled.

## 6. FE (Stax)

1. Packing screen: each line shows planned vs picked, a Mark not filled action for zero-stock lines, and a clear partial state. A Confirm packing complete button calls `confirm_machine_packed` and is enabled once every line is packed or explicitly resolved.
2. Driver app: machine appears as ready once packed; not-filled lines render as Not filled (planned N, packed 0) so the driver knows what is missing and does not wait. Pickup and dispatch are never blocked by not-filled lines.
3. Surface a fleet view of not-filled lines for the day (feeds procurement and the PRD-031 reservation work).

## 7. Acceptance — DONE 2026-06-14 (rolled-back battery green; backend live; FE deployed)

1. [x] A machine with one zero-stock line can be fully packed: packer marks it not filled, confirms, machine flips to packed, driver can pick up and dispatch. No dark state. — Battery: a machine with 2 not_filled lines + 1 packed reaches `v_machine_pack_status.is_pack_complete=true` AND `is_pickup_complete=true`; `confirm_machine_packed` returns `ok`.
2. [x] Not-filled lines visible to packer + driver, never counted as packed; `filled_quantity=0`, planned retained. — packed stays false; planned snapshotted to `original_quantity`; FE renders "Not filled (planned N, packed 0)".
3. [x] Warehouse stock never debited for not-filled units; BUG-006 guard intact. — Battery B2: WH 25->25, consumer 3->3 on a not_filled pack; `from_wh` guard kept for real picks.
4. [x] Partial picks pack available units + mark the remainder not filled in one action. — Battery B3: filled=3, quantity=3 (conserve-safe), original_quantity=5, `pack_outcome='partial'`; `v_not_filled_lines` surfaces the 2-unit partial remainder (`kind='partial_remainder'`).
5. [x] Not-filled demand reportable for the day by machine + SKU. — canonical `v_not_filled_lines` view + `/field/not-filled` fleet page.
6. [x] Constitution holds: single canonical writer per table (`pack_dispatch_line` for lines, `confirm_machine_packed` for the new table), all via RPC, forward-only migrations, registries updated (RPC_REGISTRY, MIGRATIONS_REGISTRY, CHANGELOG, METRICS_REGISTRY). Cody sign-off recorded (design ⚠️ approve-with-revisions, both revisions resolved; each migration class re-checked at apply).

**Backend live (prod):** `pack_outcome_enum` + `refill_dispatching.pack_outcome`; `pack_dispatch_line` (not_filled/partial, conserve-safe via `original_quantity`); `confirm_machine_packed` + `dispatch_pack_confirmation`; `v_machine_pack_status` + `v_not_filled_lines`; `release_stale_unpacked_dispatches` excludes not_filled. 7 migrations.
**FE (deployed):** packing screen Mark-not-filled + Confirm-packing-complete (`confirm_machine_packed`); packing-list/pickup/dispatch readiness now read `v_machine_pack_status` (Article 16, no client count re-derivation); not_filled lines render non-blocking; `/field/not-filled` fleet view. `npm run build` green.
**Note:** the existing packing-screen "skip" still does a direct table update (pre-PRD-030, out of scope); the not_filled path is fully canonical. Edge: a pack-complete machine with ONLY not_filled lines stays in the pickup list with nothing to collect (harmless; "mark done" affordance is a follow-up).

## 8. Rollout

Stage migration, Cody sign-off, apply to prod only on CS go. Validate on one machine with a known zero-stock line before fleet enablement. EOD auto-release semantics unchanged (a packed machine with not-filled lines is complete, not stale).
