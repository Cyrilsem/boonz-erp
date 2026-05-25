---
id: PRD-002
title: Per-line PO edit lock, Cancel/Not-Received action with comment, and add-new-product expiry fix
status: Done
severity: P1
reported: 2026-05-25
source: CS — needs WH manager to edit unreceived lines on partial-receive POs; admin-only lock on received lines; cancel-with-comment action; broken add-product expiry field
routing: [Dara, Cody, Stax]
protected_entities: [purchase_orders, po_additions]
done_summary:
  commit: 7a18eba
  shipped_at: 2026-05-25
  migration: phaseF_proc_edit_po_line_received_lock (applied to prod; file supabase/migrations/20260525130000_phaseF_proc_edit_po_line_received_lock.sql)
  changes:
    - Backend — edit_purchase_order_line now refuses non-superadmin edits on received lines (received_qty > 0 OR purchase_outcome='received') with a clear raise. Adds lock_level ('received' | 'unreceived') to procurement_events.payload, write_audit_log.payload, and return jsonb. No signature change. Cody approved against Articles 1, 4, 5, 8, 12.
    - FE — new shared component src/app/(field)/components/CancelPOLineDrawer.tsx — 10-char-minimum free-text reason, calls cancel_po_line RPC.
    - FE — /field/orders PO drawer (mobile) now renders a per-line action cell with a lock chip on received lines (non-superadmin), Cancel button on unreceived lines, line-through plus "Not received" badge on cancelled lines. Stops de-duplicating by product name so per-line po_line_id is stable for actions.
    - FE — /app/procurement PO drawer (desktop) mirrors the same per-line action column. Imports the field CancelPOLineDrawer for parity. Adds userRole fetch on mount.
    - FE — /field/receiving/[poId] add-item modal refactored to addBatches `{qty, expiry}[]` with a "+ Add another expiry batch" affordance. Each batch becomes one po_additions row on save. Save blocked iff every batch has empty expiry (mixed allowed; some products legitimately have no expiry).
  files:
    - supabase/migrations/20260525130000_phaseF_proc_edit_po_line_received_lock.sql
    - src/app/(field)/components/CancelPOLineDrawer.tsx
    - src/app/(field)/field/orders/page.tsx
    - src/app/(app)/app/procurement/page.tsx
    - src/app/(field)/field/receiving/[poId]/page.tsx
    - docs/architecture/RPC_REGISTRY.md
    - docs/architecture/CHANGELOG.md
  verification:
    tsc: pass
    build: pass
    cody_review_backend: pass (Articles 1, 4, 5, 8, 12)
    deploy: pass (pushed 7a18eba to main; Vercel auto-deploy triggered)
    smoke_test: pass (CS confirmed in production 2026-05-25 - per-line lock + Cancel + multi-batch add working as expected)
    followup_commits:
      - ad067d4 fix(procurement) - EditPOLineDrawer disables qty/price/expiry inputs and shows lock chip on received lines for non-superadmin callers; locked lines filtered out of save loop. Caught by CS smoke - the backend was rejecting but the UI was letting users type.
      - a631474 feat(receiving) - partial-receive banner on /field/receiving/[poId] points users at "+ Add item not on PO" + "Confirm receipt" when some lines were received in a prior session. The button and submit path were already functional; banner makes the affordance discoverable.
  open_question_deferred:
    text: Should operator_admin also override received-line edits, or superadmin-only?
    shipped_as: superadmin-only (as drafted in PRD)
    how_to_flip: forward migration changing the guard to `v_caller_role NOT IN ('superadmin','operator_admin')`
---

# PRD-002 (procurement) — Per-line edit lock, Cancel-with-comment, Add-new-product expiry

## Problem

Three related procurement gaps surface when a PO is partially received:

1. **Partial-receive editing is too coarse.** Today the WH manager and operator admins can edit _any_ line on a PO via the `edit_purchase_order_line` RPC shipped in PRD-001-procurement — including lines that have already been received. That's the wrong privilege boundary. Once a line is committed to inventory, editing it silently drifts WH stock vs PO. Only a superadmin should override that. Conversely, lines that are still **pending receipt** on the same PO (e.g. supplier delivered 30 of 50 today, the rest tomorrow) should be freely editable by the WH manager so she can correct qty / price / expiry before tomorrow's receive run.

2. **No "Cancel / Not Received" action with comment.** When a line is not going to arrive at all (supplier short-shipped permanently, item discontinued, walk-in skipped), the WH manager has no way to mark it from the PO list other than going to me (CS) for a direct DB fix. `cancel_po_line` already exists (PRD-001b) but it's not wired into the FE on `/field/orders` or `/app/procurement`. Reason text needs to be captured as a free-form comment.

3. **Adding a new product to an existing PO has no expiry input.** Scenario: a supplier brings Hunter Black Truffle on a delivery for PO-2026-9130, but Hunter wasn't on the original PO. The receiver opens `/field/receiving/[poId]` and uses the "Add item" path. The quantity field appears, but the expiry date input is missing or hidden — so the resulting `po_additions` row lands with `expiry_date = NULL`, which then becomes a NULL-expiry `warehouse_inventory` row on receipt (see [[bug_v_live_shelf_stock_fanout]] / NULL-expiry incidents). Additionally, if the same new product arrives in two batches with different expiry dates (e.g. 12 pcs of 30 Nov + 24 pcs of 15 Dec), the modal can't capture both — it's one expiry per addition.

## Current state

- **`edit_purchase_order_line(po_line_id, new_qty, new_price, new_expiry, reason)`** — PRD-001 canonical writer. Role gate: `warehouse | operator_admin | superadmin | manager`. Coherence guard: `new_qty >= received_qty`. No gate on whether the line has been received — all four roles can edit a received line today.
- **`cancel_po_line(po_line_id, reason)`** — PRD-001b canonical writer. Already gates correctly: blocks if `purchase_outcome='received'` or `received_qty > 0`. Same role set. Not wired into the FE on the PO-list pages.
- **`/field/orders/page.tsx`** — mobile PO list. Read-only. PRD-001 plans to add an Edit drawer; it hasn't shipped yet (still on the Stax queue).
- **`/app/procurement/page.tsx`** — desktop PO drawer. Read-only line detail.
- **`/field/receiving/[poId]/page.tsx`** — receive flow. The add-item modal at `handleAddConfirm` (line 547) inserts into `po_additions` with `expiry_date: addExpiry || null`. The `addExpiry` state exists (line 571 resets it) but the modal UI is either missing the input or hiding it. `po_additions` table already has the `expiry_date date` column — schema is fine; the FE form is broken.
- **`po_additions`** has columns `addition_id, po_id, boonz_product_id, qty, price_per_unit_aed, expiry_date, status, ...`. Insert is one row per (product, expiry batch). Multi-batch additions today require multiple modal interactions; UX doesn't support it.

## Expected behaviour

### Per-line edit lock (matches CS's privilege model)

For each line in the PO drawer / list:

| Line state                                                                                | warehouse          | operator_admin     | manager            | superadmin          | field_staff |
| ----------------------------------------------------------------------------------------- | ------------------ | ------------------ | ------------------ | ------------------- | ----------- |
| Unreceived (`received_qty IS NULL OR =0` AND `purchase_outcome IS NULL OR != 'received'`) | ✅ edit, ✅ cancel | ✅ edit, ✅ cancel | ✅ edit, ✅ cancel | ✅ edit, ✅ cancel  | hidden      |
| Received (`received_qty > 0` OR `purchase_outcome = 'received'`)                          | 🔒 locked          | 🔒 locked          | 🔒 locked          | ✅ edit (no cancel) | hidden      |

The UI shows a small padlock chip on locked lines with hover-tooltip "Received — only superadmin can edit." Cancel is forbidden on a received line for everyone (cancel_po_line's existing guard).

### Cancel / Not-Received action

- Visible on every unreceived line for the four edit roles.
- Tap → drawer with the line summary + required comment textarea (min 10 chars, mirrors `cancel_po_line` reason requirement).
- Optional comment box label: "Why is this not received? (supplier short-shipped, item discontinued, etc.)"
- Save → calls `cancel_po_line(p_po_line_id, p_reason=comment)`.
- On success the line shows a strike-through with a "Not received" badge, and the audit history pill on the PO surfaces the event via `get_po_edit_history`.

### Add-new-product expiry fix

In `/field/receiving/[poId]/page.tsx` add-item modal:

1. **Always render an expiry date input** alongside qty and price. Default to empty; allow `null` saves (some products have no expiry). Label: "Expiry date (optional but recommended)".
2. **Support multi-batch additions.** If the same new product arrives across two expiry batches, the modal allows adding a `+ Add another batch` button that appends a `{qty, expiry_date}` row. Each batch becomes one row in `po_additions`. (Mirrors the existing receive-flow batch pattern in `ReceiveBatch[]`.)
3. **Block save** if all batches have NULL or empty expiry (mirrors the `tg_warn_wh_inventory_null_expiry` trigger that already exists at the WH layer).

## Proposed design

### Backend (Dara → Cody)

**Patch `edit_purchase_order_line` — add the received-state role gate.**

The existing role check is:

```sql
IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
  RAISE EXCEPTION 'edit_purchase_order_line: forbidden for role %', v_caller_role;
END IF;
```

Add immediately after the row lock:

```sql
-- PRD-002: received lines are superadmin-only
IF (COALESCE(v_line.received_qty, 0) > 0
    OR v_line.purchase_outcome = 'received')
   AND v_caller_role <> 'superadmin'
THEN
  RAISE EXCEPTION 'edit_purchase_order_line: line is already received; only superadmin can edit (received_qty=%, outcome=%)',
    v_line.received_qty, COALESCE(v_line.purchase_outcome, '(null)');
END IF;
```

Migration name: `phaseF_proc_edit_po_line_received_lock`.

The audit payload should also include a `lock_level` field (`'received'` or `'unreceived'`) so the history pill can show whether the edit happened under the strict path or the normal path.

**No change to `cancel_po_line`** — its existing guards already match the privilege model.

**No schema change to `po_additions`** — `expiry_date` column exists. The bug is purely FE.

### FE (Stax)

**`/field/orders/page.tsx`** (line list, mobile) and **`/app/procurement/page.tsx`** (drawer, desktop):

For each rendered PO line:

```tsx
const isReceived =
  (line.received_qty ?? 0) > 0 || line.purchase_outcome === "received";
const canEditNow = isReceived
  ? userRole === "superadmin"
  : ["warehouse", "operator_admin", "manager", "superadmin"].includes(userRole);
const canCancelNow =
  !isReceived &&
  ["warehouse", "operator_admin", "manager", "superadmin"].includes(userRole);

// Render Edit button conditionally
{
  canEditNow && <EditButton onClick={() => openEditDrawer(line)} />;
}
{
  !canEditNow && isReceived && (
    <span title="Received — only superadmin can edit">🔒</span>
  );
}
{
  canCancelNow && <CancelButton onClick={() => openCancelDrawer(line)} />;
}
```

**New component `CancelPOLineDrawer.tsx`** (sibling to the EditPOLineDrawer planned in PRD-001):

```tsx
function CancelPOLineDrawer({ line, onClose, onConfirmed }) {
  const [reason, setReason] = useState("");
  const disabled = reason.trim().length < 10;
  async function handleConfirm() {
    const supabase = createClient();
    const { error } = await supabase.rpc("cancel_po_line", {
      p_po_line_id: line.po_line_id,
      p_reason: reason.trim(),
    });
    if (error) {
      alert(error.message);
      return;
    }
    onConfirmed();
  }
  return (
    <Drawer onClose={onClose}>
      <h2>Mark as Not Received</h2>
      <p className="text-sm text-neutral-500">
        {line.boonz_product_name} · {line.ordered_qty} ordered
      </p>
      <textarea
        rows={4}
        placeholder="Why is this not received? (supplier short-shipped, item discontinued, etc.)"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        minLength={10}
      />
      <button disabled={disabled} onClick={handleConfirm}>
        Confirm cancel
      </button>
    </Drawer>
  );
}
```

**`/field/receiving/[poId]/page.tsx`** add-item modal — render the expiry input + support multi-batch:

```tsx
// State: each addition is now an array of {qty, expiry} batches per product
const [addBatches, setAddBatches] = useState<{ qty: number; expiry: string }[]>(
  [{ qty: 1, expiry: "" }],
);

// JSX additions:
{
  addBatches.map((b, idx) => (
    <div key={idx} className="flex gap-2 mb-2">
      <input
        type="number"
        min={1}
        value={b.qty}
        onChange={(e) => updateBatch(idx, "qty", +e.target.value)}
        className="w-20"
      />
      <input
        type="date"
        value={b.expiry}
        onChange={(e) => updateBatch(idx, "expiry", e.target.value)}
        className="flex-1"
      />
      {addBatches.length > 1 && (
        <button onClick={() => removeBatch(idx)}>✕</button>
      )}
    </div>
  ));
}
<button onClick={() => setAddBatches([...addBatches, { qty: 1, expiry: "" }])}>
  + Add another expiry batch
</button>;

// On save, insert one po_additions row per batch
for (const b of addBatches) {
  await supabase.from("po_additions").insert({
    po_id: poId,
    boonz_product_id: selectedProduct.product_id,
    qty: b.qty,
    expiry_date: b.expiry || null,
    price_per_unit_aed: addPrice || null,
    added_by: authUser?.id,
    status: "pending_receive",
  });
}
```

**Block save** if every batch has empty expiry — show `alert('At least one batch must have an expiry date. If the product truly has no expiry, contact a manager.')`.

(Note: `po_additions` insert is a direct FE write today. Cody may flag this as an Article 3 concern. Out of scope to refactor into an RPC here unless Cody insists — that's a separate PRD.)

## Scope

In scope:

- `edit_purchase_order_line` patch (one new guard, one new payload field).
- Migration `phaseF_proc_edit_po_line_received_lock`.
- FE: Edit + Cancel actions on `/field/orders` + `/app/procurement` with per-line lock and role gating.
- FE: `CancelPOLineDrawer` component.
- FE: `/field/receiving/[poId]` add-item modal — expiry input + multi-batch.
- CHANGELOG entry citing this PRD.

Out of scope:

- Refactoring `po_additions` direct INSERT to a canonical RPC (Article 3 concern but separate PRD).
- Bulk Cancel — Cancel applies per line; if a whole PO is "not received" the user cancels each line. (Could be a future enhancement.)
- Edit on the receiving page itself — the editing surface is the PO drawer, not the receive flow.
- `user_profiles.home_warehouse_id` — unchanged from PRD-001-inventory's deferral.

## Protected entities touched

`purchase_orders` (UPDATE via existing canonical RPCs). No new protected entity. `po_additions` is mutated directly from FE; that's the existing pattern, not introduced here.

## Acceptance criteria

- [ ] Cody approves the `edit_purchase_order_line` patch against Articles 1, 4, 5, 8.
- [ ] As `warehouse`: open a partial-receive PO. Lines with `received_qty=0` show Edit + Cancel buttons. Lines with `received_qty>0` show a 🔒 with no buttons.
- [ ] As `superadmin`: same PO. Received lines now show Edit (but Cancel is still hidden — `cancel_po_line`'s existing guard rejects received lines for anyone).
- [ ] As `field_staff`: no Edit or Cancel buttons anywhere.
- [ ] Cancel drawer requires ≥10 chars in the comment. Submit calls `cancel_po_line`. Refresh shows the line in strike-through with a "Not received" badge.
- [ ] Edit drawer on an unreceived line works as in PRD-001.
- [ ] Edit drawer attempt on a received line as warehouse: RPC raises `line is already received; only superadmin can edit`. Toast surfaces the error.
- [ ] Edit drawer on a received line as superadmin: succeeds. Audit history pill shows `lock_level: received`.
- [ ] Add-item modal on `/field/receiving/[poId]` renders an expiry date input by default.
- [ ] Multi-batch add: user can add 2 batches with different expiries; both rows land in `po_additions`.
- [ ] Add-item save with all-empty expiry: alert pops, save blocked.
- [ ] Receipt flow then correctly inventories the multi-batch addition: each batch becomes a separate `warehouse_inventory` row with its own expiry.

## Edge cases

- **Race condition: WH manager edits a line just as it's being received.** The `FOR UPDATE` row lock in `edit_purchase_order_line` serialises against `receive_purchase_order`. If the receive happens first, the subsequent edit will hit the new "already received" guard and reject cleanly.
- **Line edited from `received_qty=0` → `5` via a separate path then cancelled.** Same outcome as today: `cancel_po_line` already blocks if `received_qty > 0`.
- **Superadmin edits a received line's expiry.** This is the legitimate "I need to fix the docket expiry on a received line" path. The Al Ain incident lesson ([[feedback_pod_vs_wh_expiry_scope]]) still applies: this edit does NOT cascade into `warehouse_inventory`. The receiving-page banner (PRD-001 Change 4) surfaces the divergence; WH manager corrects the WH row separately via Inventory.
- **Multi-batch add where one batch has no expiry.** The modal allows mixing: e.g. 12 pcs @ 30 Nov + 24 pcs @ (no expiry). Block save only if ALL batches are empty-expiry; allow if at least one has a date.
- **Add-item save by `field_staff` (driver).** Today drivers do add items at receive time per the existing flow. Keep this open. Field role can add via the modal but cannot Edit/Cancel existing PO lines.

## Verification

- [ ] `npx tsc --noEmit`
- [ ] `npm run build`
- [ ] `npm run lint`
- [ ] Manual: as `warehouse@boonz.test`, open a partial-receive PO. Confirm lock icon on received lines, Edit/Cancel on unreceived.
- [ ] Manual: cancel a line with a 10-char reason. Verify in DB: `SELECT purchase_outcome FROM purchase_orders WHERE po_line_id=...` shows `not_purchased`; `SELECT * FROM procurement_events WHERE event_type='line_not_purchased' ORDER BY created_at DESC LIMIT 1` shows the new event with the reason.
- [ ] Manual: as superadmin, edit a received line. Verify audit row has `lock_level: 'received'` in `procurement_events.payload`.
- [ ] Manual: as warehouse, try editing a received line. Expect rejection toast with the exact error string.
- [ ] Manual: add Hunter Black Truffle to PO-2026-9130 with two expiry batches. Verify two `po_additions` rows landed, each with its own `expiry_date`.
- [ ] Manual: complete the receive on the multi-batch addition. Verify two `warehouse_inventory` rows land with the correct expiries.

## Decisions

- **`superadmin` is the unlock role for received lines, not `manager`.** CS explicitly named "super admin and admin user" — interpreting that as `superadmin` only for received-line override. `operator_admin` and `manager` retain access on unreceived lines. If CS wants `operator_admin` to also override received lines, change the guard expression to `v_caller_role NOT IN ('superadmin','operator_admin')`. Flag as an open question.
- **Cancel comment ≥10 chars** matches the existing `cancel_po_line` reason guard. Same audit-quality bar from [[feedback_no_destructive_changes]].
- **Multi-batch additions stored as N rows in `po_additions`, not one row with a jsonb batches array.** Mirrors how PO lines themselves are stored (one row per batch at receive time). Keeps the receive RPC contract unchanged.
- **Block save only if ALL batches have empty expiry.** Some products legitimately have no expiry (e.g. ambient water, durable bars). Forcing every batch to have a date would break receive flows that already work today.
- **`po_additions` direct INSERT not refactored to RPC in this PRD.** Article 3 concern, but `po_additions` is a staging table — its rows don't directly affect `warehouse_inventory` until the receive RPC processes them. Out of scope; flag for future Phase B sweep.
- **`lock_level` in audit payload** lets the history pill differentiate normal edits from superadmin overrides. Future analytics value: count override frequency.

## Open question for CS

Should `operator_admin` (you) also be able to edit _received_ lines, or is it superadmin-only? The PRD as drafted is superadmin-only for received lines. If you want yourself in the override role, say the word and the guard becomes `v_caller_role NOT IN ('superadmin','operator_admin')`.

## Linked PRDs

- [[PRD-001-procurement]] — base writer (`edit_purchase_order_line`) and audit story this builds on.
- [[PRD-001b-procurement]] — `cancel_po_line` RPC reused here.
- [[PRD-001-inventory]] — shipped 2026-05-25, parallel FE pattern (sticky bar, loud failures).

## Linked memory

- [[feedback_pod_vs_wh_expiry_scope]] — superadmin received-line edits do NOT cascade to WH.
- [[feedback_no_destructive_changes]] — audit-quality bar for the cancel comment.
- [[reference_edit_purchase_order_line]] — current RPC contract.
- [[reference_cancel_po_line]] — current RPC contract.

## Rollout plan

1. Dara confirms the patched RPC signature (no signature change — just an added guard).
2. Cody reviews against Articles 1, 4, 5, 8.
3. Apply migration `phaseF_proc_edit_po_line_received_lock`.
4. Update `RPC_REGISTRY.md` (note the new received-state guard in the `edit_purchase_order_line` entry).
5. Stax implements the FE changes (PO list lock + cancel drawer + add-item expiry/multi-batch).
6. Cody reviews the FE diff (Article 3 audit; specifically the unchanged `po_additions` direct insert).
7. Deploy to Vercel.
8. CS smoke-tests both roles in production.
9. Mark PRD `status: Done` with the commit SHA in a `done_summary` block.
