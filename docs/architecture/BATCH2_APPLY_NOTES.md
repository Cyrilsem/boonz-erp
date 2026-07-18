# Batch 2 backend — APPLY NOTES
RC-02 backend (record_actual_refill) + RC-05 (write-context / provenance split-brain)
Prepared 2026-07-18 by DARA against LIVE bodies on `eizcexopcuoycuosittm` (post Batch 0+1, including the 2026-07-18 rewrites). All pre-images are in `rollback/` and were verified **byte-identical** to `pg_get_functiondef()` (md5 match, noted per file).

---

## 1. Apply order (strict)

| # | File | Contents |
|---|------|----------|
| 1 | `rc05_write_context_and_honest_provenance.sql` | constraints (+`unattributed_write`, +`refill_event`), `set_write_context`, provenance/audit triggers, 8 writer fixes |
| 2 | `rc02_record_actual_refill_fix.sql` | `refill_event_lines.discrepancy`/`wh_moves` columns, `record_actual_refill` v2 (**depends on M1**: `set_write_context` + `refill_event` enum value) |
| 3 | `rc02_refill_events_consumer.sql` | `v_refill_events_recent` view (**depends on M2**: exposes new columns) |

Each file is a single `BEGIN`/`COMMIT`. Do not reorder; do not apply M2/M3 without M1.

Rollback = apply `rollback/01..13` (verbatim pre-bodies) then `rollback/14_constraints_and_new_objects.sql` (restores original constraints, drops `set_write_context` / view / new columns). **Rollback caveat**: if any rows carry `provenance_reason IN ('unattributed_write','refill_event')` at rollback time, relabel them first (instructions inside file 14) or the original enum constraint will fail validation.

## 2. Pre-apply verification

```sql
-- (a) live bodies still match the captured pre-images (no drift since 2026-07-18):
SELECT p.proname, md5(pg_get_functiondef(p.oid))
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN
 ('set_warehouse_inventory_provenance','auto_audit_warehouse_inventory',
  'auto_audit_warehouse_inventory_insert','apply_inventory_correction',
  'attempt_inventory_correction','adjust_warehouse_stock','approve_pod_inventory_edit',
  'drain_phantom_consumer_stock','drain_phantom_consumer_stock_batch_run',
  'reactivate_warehouse_row','receive_purchase_order_addition','reject_return',
  'record_actual_refill')
ORDER BY 1;
```
Expected md5s (also in each rollback file header):
`set_warehouse_inventory_provenance=591a5223…`, `auto_audit_warehouse_inventory=a282e4f9…`, `auto_audit_warehouse_inventory_insert=c82fd784…`, `apply_inventory_correction=380dc01f…`, `attempt_inventory_correction=1fadf2fa…`, `adjust_warehouse_stock=b0d2a35a…`, `approve_pod_inventory_edit=30574d90…`, `drain_phantom_consumer_stock=fc359865…`, `drain_phantom_consumer_stock_batch_run=0084f046…`, `reactivate_warehouse_row=1fe04dba…`, `receive_purchase_order_addition=40f10fb3…`, `reject_return=1886d487…`, `record_actual_refill=f2121915…`.
If ANY differ, STOP — re-pull live and re-diff before applying.

```sql
-- (b) constraints are the expected pre-state and validated:
SELECT conname, convalidated, pg_get_constraintdef(oid)
FROM pg_constraint WHERE conrelid='public.warehouse_inventory'::regclass
 AND conname LIKE 'wh_provenance%';
-- (c) set_write_context and v_refill_events_recent must NOT already exist:
SELECT 1 FROM pg_proc WHERE proname='set_write_context';        -- expect 0 rows
SELECT 1 FROM pg_views WHERE viewname='v_refill_events_recent'; -- expect 0 rows
```

## 3. Post-apply verification

### 3.1 Structural
```sql
SELECT pg_get_constraintdef(oid) FROM pg_constraint
 WHERE conname='wh_provenance_reason_enum';   -- contains unattributed_write + refill_event
SELECT pg_get_constraintdef(oid) FROM pg_constraint
 WHERE conname='wh_provenance_event_required';-- unattributed_write in the exempt list
SELECT proname FROM pg_proc WHERE proname='set_write_context';  -- 1 row
SELECT column_name FROM information_schema.columns
 WHERE table_name='refill_event_lines' AND column_name IN ('discrepancy','wh_moves'); -- 2 rows
SELECT count(*) FROM v_refill_events_recent;  -- runs without error
```

### 3.2 record_actual_refill dry-run test call (SAFE — writes only a dry_run header+lines)
Concrete real fixture verified live 2026-07-18 (re-verify stock before running):
machine `AMZ-1068-2401-O1`, shelf `A06`, product `ca11114e-c4e3-4058-8144-5d42c92f4b8f`
(Smart Gourmet - Classic Hummus and Pretzels, pod stock 5 @ 2027-01-25), primary
warehouse `4bebef68-9e36-4a5c-9c2c-142f8dbdae85` (WH_CENTRAL, has Active stock).

```sql
SELECT public.record_actual_refill(
  'AMZ-1068-2401-O1', CURRENT_DATE,
  jsonb_build_array(
    -- delta refill: expect wh_debit_needed = 3, no discrepancy
    jsonb_build_object('action','refill','boonz_product_id','ca11114e-c4e3-4058-8144-5d42c92f4b8f',
                       'shelf_code','A06','qty',3,'set_mode','delta',
                       'expiration_date','2027-01-25',
                       'warehouse_id','4bebef68-9e36-4a5c-9c2c-142f8dbdae85'),
    -- set-mode refill to 8 with pod at 5: expect pod_delta=3, wh_debit_needed=3 (NOT 8 — the old bug)
    jsonb_build_object('action','refill','boonz_product_id','ca11114e-c4e3-4058-8144-5d42c92f4b8f',
                       'shelf_code','A06','qty',8,'set_mode','set',
                       'expiration_date','2027-01-25',
                       'warehouse_id','4bebef68-9e36-4a5c-9c2c-142f8dbdae85'),
    -- set-mode BELOW current: expect discrepancy.set_below_current, wh_debit_needed=0
    jsonb_build_object('action','refill','boonz_product_id','ca11114e-c4e3-4058-8144-5d42c92f4b8f',
                       'shelf_code','A06','qty',2,'set_mode','set',
                       'expiration_date','2027-01-25',
                       'warehouse_id','4bebef68-9e36-4a5c-9c2c-142f8dbdae85')
  ),
  'cs', NULL, 'batch2 post-apply dry-run verification', true);  -- p_dry_run = true
```
Check the returned `line_details` for the expectations above, then:
```sql
SELECT * FROM v_refill_events_recent
 WHERE event_reason = 'batch2 post-apply dry-run verification';
-- event_status='dry_run', applied=false on all lines, discrepancy populated on line 3 only
-- confirm NO warehouse/pod movement happened:
SELECT count(*) FROM inventory_audit_log WHERE audited_at > now() - interval '10 minutes'
  AND reason LIKE '%batch2 post-apply%';   -- expect 0
```
Only after CS reviews the dry-run should a live (`p_dry_run=false`) smoke test be run, on a line CS confirms physically (recommended: one delta refill of 1 unit, then verify `wh_moves` names a specific Active FEFO row, the row lost exactly 1, `provenance_reason='refill_event'`, `source_event_id=event_id`, no status flips, one `refill_plan_output` row, and `days_since_visit` for the machine resets in `v_machine_health_signals`).

### 3.3 Provenance honesty checks (run ~24–48h after apply)
```sql
-- (a) sentinel should NOT appear from any canonical RPC flow:
SELECT provenance_reason, count(*) FROM warehouse_inventory
 WHERE provenance_reason='unattributed_write' GROUP BY 1;
SELECT reason, count(*) FROM inventory_audit_log
 WHERE audited_at > now() - interval '48 hours'
   AND provenance_reason='unattributed_write' GROUP BY 1;
-- Any hits identify a DIRECT (non-RPC) writer — that is the sentinel doing its
-- job (detection, not breakage). Investigate adjusted_by/auth context; the
-- known candidates are the sporadic service-role direct writes previously
-- logged as 'service_role_write_unattributed' (12 rows in the 30d window,
-- last seen 2026-07-08).

-- (b) double-log gone: an adjust_warehouse_stock stock change now produces
-- EXACTLY ONE audit row (the detailed one), zero trigger rows:
SELECT reason, count(*) FROM inventory_audit_log
 WHERE audited_at > now() - interval '48 hours'
   AND reason IN ('authenticated_write_no_reason_set','authenticated_insert_no_reason_set')
 GROUP BY 1;  -- expect ~0 from adjust_warehouse_stock flows (was 71+288/30d)

-- (c) inline edits now honest:
SELECT provenance_reason, source_event_id IS NOT NULL AS has_event, count(*)
FROM inventory_audit_log
WHERE audited_at > now() - interval '48 hours'
  AND reason LIKE 'inventory correction by %'
GROUP BY 1,2;  -- expect manual_adjust / has_event=true (attempt_id threaded)
```

### 3.4 Expected provenance per writer (the full stock-writer enumeration)
| Writer (stock-changing) | provenance_reason | source_event_id | Fixed in |
|---|---|---|---|
| receive_purchase_order | po_receive | po_line_id / addition_id | Batch 1 (unchanged) |
| receive_purchase_order_addition | po_receive | addition_id | **M1** |
| pack_dispatch_line | dispatch_pack | dispatch_id | Batch 1 |
| receive_dispatch_line | dispatch_receive / dispatch_return_unverified | dispatch_id | Batch 1 |
| return_dispatch_line | dispatch_return / dispatch_return_unverified | dispatch_id | Batch 1 |
| approve_return | dispatch_return | inherited row event ('' GUC) | Batch 1 (see RC-05b) |
| credit_dispatch_remainder | dispatch_partial_remainder | dispatch_id | Batch 1 |
| transfer_warehouse_stock | wh_transfer | source wh row id | Batch 1 |
| warehouse_expire_writeoff | expiry_writeoff | its own wh row id | Batch 1 (self-pointer-ish; RC-05b candidate) |
| log_manual_refill | manual_adjust | source/new wh row ids | Batch 1 (row-id-as-event; RC-05b candidate) |
| confirm_warehouse_status_proposal | status_flip | proposal_id | Batch 1 |
| adjust_warehouse_stock | manual_adjust | NULL (self-pointer removed) | **M1** |
| apply_inventory_correction | manual_adjust | attempt_id (via attempt_inventory_correction) or NULL | **M1** |
| approve_pod_inventory_edit (return_to_warehouse) | m2m_return | edit_id | **M1** (also fixes enum-violating INSERT literal) |
| drain_phantom_consumer_stock (+batch_run) | manual_adjust | NULL | **M1** |
| reactivate_warehouse_row | manual_adjust | NULL | **M1** |
| reject_return | manual_adjust | NULL | **M1** |
| repair_unbound_dispatch | manual_adjust | NULL | Batch 1 |
| record_actual_refill | refill_event | event_id | **M2** |
| Status-only writers: auto_expire_old_warehouse_stock, inactivate_warehouse_row, sweep_inactivate_stale_zero_stock, release_stale_wh_pins, release_wh_quarantine, propose_* triggers, reject_warehouse_status_proposal | n/a — do not change stock columns; sentinel does not fire; row keeps its stock provenance | | untouched |

### 3.5 Visit clocks (M3b verification — deliberate no-op)
```sql
-- proves applied record_actual_refill events tick days_since_visit through the
-- existing pod_inventory_audit_log 'adjust-%' channel (adjust_pod_inventory):
SELECT pal.reference_id, pal.created_at
FROM pod_inventory_audit_log pal
JOIN machines m ON m.machine_id = pal.machine_id
WHERE m.official_name = '<machine used in live smoke test>'
  AND pal.reference_id LIKE 'adjust-%'
ORDER BY pal.created_at DESC LIMIT 3;
-- then: SELECT days_since_visit FROM v_machine_health_signals s
--        JOIN machines m USING (machine_id) WHERE m.official_name='<same>';  -- expect 0
```
`v_machine_priority` / `v_machine_health_signals` are NOT modified (rationale in M3 header: the `manual_refill_visit` CTE already matches `adjust-%` reference ids; direct wiring would double-count and destabilize the canonical health view).

## 4. Decisions & justifications
1. **Sentinel scope**: `unattributed_write` is stamped only on **stock-changing UPDATEs** with no `app.provenance_reason` (and only when the writer did not set the column directly). Metadata-only updates (status flips, pin releases, quarantine) keep the row's stock provenance — that provenance still truthfully describes where the stock came from. This is what keeps the 8 status-only writers out of scope.
2. **Attempt-id threading**: `attempt_inventory_correction` generates `v_attempt_id` before the nested call, so it sets `app.source_event_id = attempt_id`; `apply_inventory_correction` passes any pre-set GUC through `set_write_context`. Direct `apply_inventory_correction` calls carry `source_event_id = NULL` (legal for `manual_adjust`) — no synthetic prefix ids invented.
3. **adjust_warehouse_stock logging path**: kept the **explicit detailed inserts** as canonical and made both generic audit triggers skip `app.rpc_name='adjust_warehouse_stock'`. The trigger row cannot represent consumer_stock/status/location/expiry deltas (it only logs warehouse_stock old/new), so "delete the explicit insert" would lose information; the skip is scoped to exactly this one RPC and the explicit inserts now carry `provenance_reason='manual_adjust'`/`source_event_id=NULL` so no fidelity is lost vs the trigger row.
4. **`set_write_context` clears all five GUCs every call** (NULL→''), so successive RPCs in one transaction cannot leak context into each other. `''` source_event retains today's "leave the row's existing event" semantics because `approve_return` depends on inheriting the dispatch event to satisfy `wh_provenance_event_required` (see RC-05b).
5. **jwt-claims decision (M2)**: forgery removed entirely — safe because the only nested gated RPC (`adjust_warehouse_stock`) is no longer called; `adjust_pod_inventory`'s gate explicitly permits NULL-auth. Actor = `COALESCE(auth.uid(), p_actor)`; non-NULL actors must be inventory managers. Behavior tightening: an **authenticated non-manager** could previously run pod-only writes with `p_actor=NULL` un-gated; now blocked (intended). NULL-auth service path (`p_actor NULL` too) still works, unauthenticated by design until RC-11.
6. **`m2m_return`** chosen for pod-edit warehouse credits (stock physically returning from a machine to a warehouse, evidenced by the approved edit); `manual_adjust` was the alternative but loses the machine-origin signal, and `m2m_return` + `edit_id` satisfies the event-required constraint.
7. **FEFO debit vs driver-declared expiry**: picks come from canonical `wh_fefo_for_line` restricted to the line's warehouse, reordered so rows matching the driver-declared `expiration_date` drain first, then FEFO. Physical truth wins over plan commitments: the driver already took the stock, so debits are capped only by physical Active pickable stock; anything unexplained becomes `wh_shortfall` + alert (never a silent clamp, never a negative row).

## 5. Risks
- **Sentinel surfacing**: any still-unknown direct writer (e.g. a service-role script; 12 unattributed service writes seen in the last 30d, none since 07-08) will now visibly stamp `unattributed_write` instead of inheriting a plausible-looking provenance. This is intended detection, but monitor 3.3(a) daily for the first week.
- **record_actual_refill role tightening** (decision 5) — if any FE surface calls it with an authenticated non-manager session, it now errors. It had 0 consumers, so exposure should be nil; verify before wiring FE.
- **Constraint rewrite** takes an `ACCESS EXCLUSIVE` lock on `warehouse_inventory` briefly (validation scans ~1.6k rows — sub-second). Apply outside the dispatch-pack morning window to be polite.
- **`approve_return` inherit semantics** untouched but now load-bearing-documented; do not "clean up" the `''` behavior without RC-05b.
- **apply_inventory_correction** still auto-reactivates Inactive rows on stock>0 (pre-existing Batch-1 behavior, deliberately untouched here).

## 6. Deliberately deferred (named follow-ups)
1. **Phase-2 provenance INSERT cutover** (`enforce_provenance_on_warehouse_inventory_insert` → RAISE EXCEPTION): PARKED per validate-flow-before-tightening. Flip only after 3.3(a) is clean for a full week of flows (PO receive, dispatch cycle, n8n windows).
2. **RC-05b — event semantics cleanup**: make reason-set writes with empty event GUC *clear* `source_event_id` instead of inheriting; requires `approve_return` to stamp its own event (e.g. the return row's originating dispatch id) and a decision on `log_manual_refill` / `warehouse_expire_writeoff` row-id-as-event stamps.
3. **RC-11 — record_actual_refill service-path authentication**: NULL-auth calls remain permitted with optional `p_actor` attribution; replace with authenticated service identity / signed caller context in Batch 3.
4. **Data cleanup**: (a) the 19 duplicate Active (product, warehouse, expiry) triples exposed by the old oldest-row writes — dedupe/merge is a data migration, not a function fix; (b) historical camouflaged audit rows (~95% of manual edits wearing `dispatch_receive`/`po_receive`) stay as-is — `inventory_audit_log` is append-only; produce an analysis view flagging suspect rows instead of rewriting history.
5. **FE/skill wiring** of `v_refill_events_recent` and of `record_actual_refill` itself (it still has 0 callers) — Stax scope.
