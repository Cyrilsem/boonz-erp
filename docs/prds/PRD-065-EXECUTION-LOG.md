# PRD-065 Execution Log — field reconciliation + phantom-expired sweep

Date: 2026-06-29 · Branch: `feat/prd-065-field-reconciliation` (off `origin/main`) · No git push (per directive).
Mode: AUTO. Dara design + Cody review per writer. Applied ONLY the two non-protected pieces (A1 guard, B1 view); every pod/warehouse/dispatch writer and the cron are HELD for CS green light.

## Per-object status

| Obj | Object                                                                                              | Designed | Cody verdict                                                                                                                            | Built (file)                                            | State                         |
| --- | --------------------------------------------------------------------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | ----------------------------- |
| A1g | `pod_inventory_edits_qty_required_chk` (NULL/<=0 qty guard)                                         | ✅       | ✅ (pod_inventory_edits not in Appendix A; forward-only NOT VALID)                                                                      | `20260629100000_prd065_a1_edits_qty_guard.sql`          | **APPLIED** + guard test PASS |
| A1r | `set_edit_quantity_and_approve(edit_id, qty, caller_id, note)`                                      | ✅       | ✅                                                                                                                                      | `20260629100100_…set_edit_quantity_and_approve.sql`     | **HELD**                      |
| A2  | `create_field_add_edit(machine, boonz, qty, expiry, caller, reason, [pod], [shelf])`                | ✅       | ✅                                                                                                                                      | `20260629100200_…create_field_add_edit.sql`             | **HELD**                      |
| A3  | `remainder_credited` col + `credit_dispatch_remainder(dispatch, caller)` + receive-close trigger    | ✅       | ⚠️→✅ (verify credit in BEGIN..ROLLBACK + RPC_REGISTRY entry at apply)                                                                  | `20260629100300_…a3_dispatch_remainder_credit.sql`      | **HELD**                      |
| B1  | `v_expired_inventory` (view)                                                                        | ✅       | ✅ (read-only)                                                                                                                          | `20260629100400_prd065_b1_v_expired_inventory.sql`      | **APPLIED**                   |
| B4  | `warehouse_expire_writeoff(wh_inventory_id, reason, caller)`                                        | ✅       | ⚠️→✅ after revision (Article 6: removed `status='Inactive'`; zero-stock fires `tg_propose_inactivate_on_zero_stock` → manager confirm) | `20260629100500_…b4_warehouse_expire_writeoff.sql`      | **HELD** (revised)            |
| B2  | `sweep_expired_inventory(p_dry_run, p_caller)` + `refill_settings.sweep_enabled` flag (default OFF) | ✅       | ✅ (contingent on B4 revision)                                                                                                          | `20260629100600_…b2_sweep_expired_inventory.sql`        | **HELD** + cron HELD          |
| B3  | `driver_confirm_expired_removal(edit_id, caller, note)`                                             | ✅       | ✅                                                                                                                                      | `20260629100700_…b3_driver_confirm_expired_removal.sql` | **HELD**                      |

All writers: SECURITY DEFINER, `search_path` pinned, explicit `caller_id` (COALESCE with auth.uid()), `user_profiles` role gate, GUC quartet (`app.via_rpc/rpc_name/provenance_reason/source_event_id/mutation_reason`), idempotent, reversible (Inactive/0/reason — never DELETE). Each file carries a `-- DOWN:` block.

## Cody crux resolved — B4 / Article 6

`warehouse_inventory.status` is manager-only (propose-then-confirm). B4 originally set `status='Inactive'` (a hard refusal). **Revised:** B4 now zeroes `warehouse_stock + consumer_stock + disposal_reason` only; that fires the existing `tg_propose_inactivate_on_zero_stock` trigger which raises the inactivation proposal for the warehouse manager to confirm. Write-off stays server-callable (unblocks Al Ain + the sweep); the status flip stays manager-confirmed. `adjust_warehouse_stock` writing status is grandfathered as the manager UI path; a sweep-reachable writer is not.

## B2 dry-run report (live, 2026-06-29) — what the sweep WOULD do today

| location  | bucket              | sweep action                                                 | rows | units | age (days) |
| --------- | ------------------- | ------------------------------------------------------------ | ---: | ----: | ---------- |
| machine   | stock_bearing       | queue_pod (pending `expired` edit → driver confirms removal) |    6 |    15 | 1–8        |
| machine   | zero_stock_residual | writeoff_pod (backfill_archive)                              |    0 |     0 | —          |
| warehouse | zero_stock_residual | writeoff_wh (warehouse_expire_writeoff)                      |    0 |     0 | —          |
| warehouse | stock_bearing       | flag_wh (manager via B4)                                     |    0 |     0 | —          |

Note on the "20 rows from 29 Jun": those 12 pod zero-stock residuals + 8 WH2/MCC rows were already cleared by hand (now `Inactive`), so they are NOT in `Active+expired` anymore and the sweep correctly no-ops on them (idempotency). Today's live expired set is 6 stock-bearing pod rows (15 units) — these would be QUEUED for driver confirmation, not auto-cleared (stock-bearing never auto-clears, per the model). Zero residuals and zero WH expired remain, so an enabled sweep would auto-write-off nothing right now.

## Applied vs held

- **Applied to prod:** A1 guard (constraint, tested), B1 `v_expired_inventory` (view).
- **Built + HELD for CS green light:** A1-repair, A2, A3 (col+RPC+trigger), B4 (revised), B2 (+flag, default OFF), B3.
- **HELD separately:** the pg_cron sweep schedule (enable only after a clean dry-run cycle + CS OK; will call `SELECT public.cron_sweep_expired_inventory();` wrapping `sweep_expired_inventory(false, '<manager-uuid>')`).

## Awaiting your green light

1. Apply the capture writers: **A1-repair, A2, A3** (A3 needs a BEGIN..ROLLBACK credit check vs the NOVO case first — I'll run it on your OK).
2. Apply the sweep writers: **B4 (revised), B2, B3**.
3. After a clean dry-run cycle: flip `refill_settings.sweep_enabled = true` and schedule the **pg_cron** job.
4. RPC_REGISTRY.md / METRICS_REGISTRY.md / CHANGELOG.md / MIGRATIONS_REGISTRY.md entries land at apply/close.

Nothing pod/warehouse/dispatch-mutating has been applied. No git push.

---

## UPDATE 2026-06-29 — CS green-lit the capture + sweep writers; APPLIED

On CS instruction ("apply the capture (A1-repair, A2, A3) — run A3's credit check vs NOVO first and show before/after — then apply the sweep writers (B4, B2, B3) with sweep_enabled OFF and the cron held"):

**A3 NOVO credit check (pinned WH row `62b38d5c`, dispatch `23a0f983` "Dubai Popcorn - Salted", qty 6 / filled 2 / remainder 4):** before warehouse_stock 10, consumer_stock 0 → after warehouse_stock **14** (+4), consumer_stock 0 (nothing reserved to un-reserve). No double-count. (Shown as a pure read; nothing written.)

**APPLIED to prod (all Cody-green, idempotent, reversible):**

- `set_edit_quantity_and_approve` (A1-repair) — `prd065_a1_set_edit_quantity_and_approve`
- `create_field_add_edit` (A2) — `prd065_a2_create_field_add_edit`
- `remainder_credited` column + `credit_dispatch_remainder` + `trg_credit_dispatch_remainder` (A3) — `prd065_a3_dispatch_remainder_credit`
- `warehouse_expire_writeoff` (B4, revised — no status write) — `prd065_b4_warehouse_expire_writeoff`
- `sweep_expired_inventory` + `refill_settings.sweep_enabled='false'` (B2) — `prd065_b2_sweep_expired_inventory`
- `driver_confirm_expired_removal` (B3) — `prd065_b3_driver_confirm_expired_removal`

**Post-apply verification:** all 6 RPCs present; A3 column + trigger present; `sweep_enabled='false'`. Real `sweep_expired_inventory(true, <operator_admin>)` dry-run = 6 stock_bearing pod rows queued (15 units: MINDSHARE Popcorn Butter 1, AMZ-1038 M&M Yellow 2 + Vitamin Well Antioxidant 3, ACTIVATE Vitamin Well Upgrade 4, WPP McVities 3, AMZ-1029 M&M Yellow 2), 0 residual/WH cleared. Live run (`p_dry_run=false`) correctly **refused** (`status: disabled`) while the flag is OFF.

**STILL HELD (await explicit CS OK):**

- Enable the sweep: `UPDATE refill_settings SET setting_value='true' WHERE setting_key='sweep_enabled'`.
- Schedule pg_cron (`cron_sweep_expired_inventory` wrapping `sweep_expired_inventory(false, '<manager-uuid>')`).
- **One-off NOVO fix:** A3's trigger only fires on NEW receives, so the existing NOVO row `23a0f983` (4-unit limbo) is NOT retro-credited. It needs a single `SELECT credit_dispatch_remainder('23a0f983-5a9b-4049-9c61-5f3b377892b1', '<manager-uuid>')` (verified before/after 10→14) — held for CS as a data correction.
- Registry/CHANGELOG entries (RPC_REGISTRY for the 6 RPCs incl. A3 as a new WH writer; METRICS_REGISTRY for `v_expired_inventory`).

No git push.
