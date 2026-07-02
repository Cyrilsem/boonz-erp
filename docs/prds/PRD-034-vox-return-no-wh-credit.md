# PRD-034: VOX-sourced returns must not credit Boonz warehouse

Status: Closed 2026-07-02 (PRD-071 sweep). Reason: superseded by PRD-054 returns-queue VOX guard (shipped 2026-06-23). Reopen by deleting this line.

Owner: CS
Date: 2026-06-17
Surface: Backend (new table + one canonical-writer guard). Touches protected entity `warehouse_inventory` and `pod_inventory` via `receive_dispatch_line`. Cody review required.
Governance: Dara designs the table, Cody reviews the table and the `receive_dispatch_line` change, implementer applies after CS sign-off. Forward-only. No em dashes. Apply nothing to prod without CS green light.

## Objective

When the warehouse manager approves a driver-confirmed REMOVE whose product is VOX-supplied (`product_mapping.source_of_supply = 'venue_team'`), the system must archive the pod (the units left the machine) and record the return for VOX reconciliation, but must NOT credit `warehouse_inventory`. Boonz never owned that stock, so crediting it inflates Boonz warehouse inventory with phantom units that could then be re-dispatched (double count). Boonz-supplied returns (`source_of_supply = 'boonz'`) keep crediting the warehouse exactly as today.

## Why

The returns-awaiting-approval queue in /app/inventory approves REMOVEs through `wh_approve_remove_receipt` / `wh_approve_remove_receipt_multivariant`, both of which wrap `receive_dispatch_line`. For `action = 'Remove'`, `receive_dispatch_line` credits `warehouse_inventory.warehouse_stock` by the verified quantity (matched to the expiry batch, or inserts a `REMOVE-RECEIVE-<date>` row), then archives the machine's `pod_inventory` rows. None of these functions check `source_of_supply`, and the dispatch row's `source_origin` is `'warehouse'` even on VOX-venue machines, so there is no signal that stops a VOX-supplied return from being booked into Boonz stock. Fleet today: `source_of_supply` is `'boonz'` (7,776 active mapping rows, 236 products) or `'venue_team'` (65 rows, 18 products). The correct VOX flag is `source_of_supply`, not machine venue and not `source_origin`.

## Design

### Phase A. New ledger table `vox_return_log` (Dara, Cody)

Append-only record of every venue_team REMOVE receipt that was deliberately NOT credited to Boonz warehouse. Gives partner reconciliation a queryable surface instead of parsing `write_audit_log`.

```sql
CREATE TABLE IF NOT EXISTS public.vox_return_log (
  vox_return_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispatch_id      uuid NOT NULL,
  machine_id       uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  boonz_product_id uuid REFERENCES public.boonz_products(product_id) ON DELETE SET NULL,
  qty              numeric NOT NULL CHECK (qty >= 0),
  expiry_date      date,
  source_of_supply text NOT NULL,
  received_by      uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  received_at      timestamptz NOT NULL DEFAULT now(),
  reason           text
);
ALTER TABLE public.vox_return_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY vrl_select   ON public.vox_return_log FOR SELECT TO authenticated USING (true);
CREATE POLICY vrl_insert   ON public.vox_return_log FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY vrl_no_update ON public.vox_return_log FOR UPDATE USING (false);
CREATE POLICY vrl_no_delete ON public.vox_return_log FOR DELETE USING (false);
CREATE INDEX idx_vrl_machine_time ON public.vox_return_log (machine_id, received_at DESC);
CREATE INDEX idx_vrl_dispatch     ON public.vox_return_log (dispatch_id);
```

### Phase B. Guard `receive_dispatch_line` (Cody, implementer)

Fetch the LIVE body first (`pg_get_functiondef`), base the migration on it. In the `action = 'Remove'` branch only, before the WH-credit block, resolve supply with a global-default fallback:

```sql
SELECT source_of_supply INTO v_supply FROM public.product_mapping
 WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
   AND (machine_id = v_dispatch.machine_id OR is_global_default)
 ORDER BY (machine_id = v_dispatch.machine_id) DESC, is_global_default ASC LIMIT 1;
```

If `v_supply = 'venue_team'`: set `v_path := 'remove_venue_team_no_wh_credit'`, SKIP the entire WH-credit block (no `warehouse_inventory` write of any kind), INSERT one `vox_return_log` row (dispatch_id, machine_id, boonz_product_id, qty = `p_filled_quantity`, expiry = `v_effective_expiry`, source_of_supply, received_by, reason), then run the existing pod archive + dispatch-received update unchanged. Return `wh_credit_skipped: 'venue_team'` in the result jsonb. Else: existing behavior unchanged byte-for-byte.

Constraints: the change must NOT touch `warehouse_inventory.status` (Article 6), must keep `app.via_rpc`/`app.rpc_name` set (Article 4/8), and must not alter the `Refill`/`Add New` branches. The `item_added = true` guard already prevents double-receive (idempotent).

### Phase C. (Optional, defer) FE surface

A read-only `get_vox_returns(p_date_from, p_date_to, p_machine uuid DEFAULT NULL)` and a small panel/CSV for VOX-return reconciliation. Not required to close the inflation hole; ship Phase A+B first.

## Acceptance criteria

1. Approving a REMOVE whose product resolves to `source_of_supply = 'venue_team'`: `warehouse_inventory` shows ZERO net change (no row credited, none inserted); `pod_inventory` rows for that machine/product are archived (`status='Inactive'`); one `vox_return_log` row is written with the verified qty; result jsonb carries `wh_credit_skipped='venue_team'`.
2. Approving a REMOVE whose product is `source_of_supply = 'boonz'`: warehouse credited exactly as before this PRD (regression: byte-compatible behavior), no `vox_return_log` row.
3. Supply resolution prefers the per-machine mapping row, falls back to the global default; verified against a product that is venue_team on one machine and boonz elsewhere (if any) and a global-only venue_team product.
4. `Refill` and `Add New` receive paths are unchanged (diff shows edits only inside the `Remove` branch + the new DECLARE).
5. `vox_return_log` is append-only (UPDATE/DELETE blocked by policy), RLS enabled.
6. Re-receiving the same dispatch is refused (existing `item_added` guard), so no duplicate `vox_return_log` rows.

## Out of scope

Phasing venue_team products out of machines (decommission), the Refill-direction handling of venue_team (separate concern), and any change to how `source_of_supply` is set on `product_mapping`.
