---
id: PRD-001
title: WH manager can edit submitted PO with full audit capture
status: Done
severity: P1
reported: 2026-05-23
reviewed: 2026-05-23 (Dara + Cody)
shipped: 2026-05-23
source: CS — /field/orders edit-with-audit ask, 2026-05-23
routing: [Dara, Cody, Stax]
protected_entities: [purchase_orders, write_audit_log, procurement_events]
---

## done_summary

**Migrations applied to prod (Supabase project `eizcexopcuoycuosittm`):**

- `phaseF_proc_edit_po_line_audit` — adds `purchase_orders.last_edited_at` / `last_edited_by` (with `edit_purchase_order_line`-exclusive COMMENTs); creates SECURITY DEFINER `edit_purchase_order_line(uuid, numeric, numeric, date, text)` with dual-write to `procurement_events` + `write_audit_log`, no-op edit guard, coherence guard, ≥10-char reason guard; creates SECURITY INVOKER `get_po_edit_history(text)` over `procurement_events`.
- `phaseF_proc_events_widen_event_type_check` — widens `procurement_events.event_type` CHECK to accept `po_line_edited`.

**FE shipped — commit SHA `3724826` on `main`:**

- NEW `src/app/(field)/components/EditPOLineDrawer.tsx` — per-line editable drawer (qty / price / expiry + shared reason); iterates changed lines and calls `edit_purchase_order_line` once per line.
- NEW `src/app/(field)/components/POEditHistoryPill.tsx` — chip + bottom-sheet showing `before → after` deltas, actor name + role, and the captured reason from `get_po_edit_history`.
- MODIFIED `src/app/(field)/field/orders/page.tsx` — role-gated Edit button (`warehouse / operator_admin / superadmin / manager`), history pill wired to each PO card, drawer mount + refresh-key wiring.
- MODIFIED `src/app/(field)/field/receiving/[poId]/page.tsx` — amber warning banner surfaces post-receipt edits (any `get_po_edit_history.changed_at` newer than the line's `received_date`).

**Acceptance criteria verified via smoke test:**

- Edit with reason ≥10 chars writes one `procurement_events.po_line_edited` row AND one `write_audit_log` row in the same transaction.
- Reason <10 chars → RPC raises `reason is required (>= 10 chars)`.
- `ordered_qty < received_qty` → RPC raises with the "Reverse receipt first" message.
- No-op edit → RPC raises `no changes detected (all three fields already match the submitted values)`.
- `get_po_edit_history` returns the new event after the edit.
- Cody Article 3 review of the FE diff: ✅ Approve (no direct `INSERT/UPDATE/DELETE` on `purchase_orders`, `write_audit_log`, or `procurement_events`; all writes through `supabase.rpc("edit_purchase_order_line")`; FE role gate matches RPC role gate).

**Deferred (not blocking):**

- Article 15 amendment recognising `procurement_events` / `pod_inventory_audit_log` / `warehouse_inventory_audit_log` as Article 8-equivalent subsystem audits. Until filed, the dual-write to `write_audit_log` is the canonical pattern for procurement edits.
- Driver-notification follow-up ([[PRD-002-procurement-driver-edit-notification]]) when WH edits a still-collectable PO. Out of scope here.

---

# PRD-001 — WH manager can edit submitted PO with full audit capture

## Problem

Today `/field/orders` is a read-only mobile listing. When a submitted PO has the wrong `ordered_qty`, `price_per_unit_aed`, or `expiry_date` — which happens routinely (supplier short-shipped, mis-keyed price, wrong expiry on the docket) — the WH manager has no edit surface. The only correction paths today are:

1. Wait for receive and adjust at receipt time (forces partial-receive accounting; doesn't fix price corrections).
2. CS (operator_admin) opens Supabase and edits the row directly — bypasses Article 3, no audit trail, and risks the same scope-creep mistake that produced the Al Ain Water incident on 2026-05-19 (see [[feedback_pod_vs_wh_expiry_scope]]).

We need a first-class, audited edit path so the WH manager owns the data correction directly and every change is reconstructable.

## Current state

- `/field/orders` (`src/app/(field)/field/orders/page.tsx`) — read-only list grouped by `po_id`, expandable line detail. No edit affordance.
- `/app/procurement` (`src/app/(app)/app/procurement/page.tsx`) — desktop tool with a PO drawer that displays lines, but no editing UI (and any new-PO inserts go through the canonical `create_purchase_order` RPC since 2026-04-27).
- `purchase_orders` is protected (Constitution Appendix A). Two canonical writers exist: `create_purchase_order` and `receive_purchase_order`. **No canonical update writer exists.**
- `write_audit_log` is wired via the universal trigger but only fires when the mutating session sets `app.via_rpc='true'` and `app.rpc_name='<name>'` — i.e., only canonical-RPC writes produce audit rows.
- Phase B will tighten RLS to block `authenticated` from `UPDATE` on `purchase_orders` outright; building this as a canonical RPC now is forward-compatible.

## Expected behaviour

1. In `/field/orders`, when an authorised user (warehouse, operator_admin, superadmin, manager) taps a PO, an **Edit** affordance appears alongside the existing Receive link.
2. Edit drawer shows the three editable fields (`ordered_qty`, `price_per_unit_aed`, `expiry_date`) per line + a single **Reason for edit** text input (required, ≥10 chars).
3. On save, the FE calls `edit_purchase_order_line(p_po_line_id, p_new_ordered_qty, p_new_price_per_unit_aed, p_new_expiry_date, p_reason)` — one canonical writer per line.
4. The RPC validates inputs (role, line existence, coherence — see Decisions), sets `app.via_rpc='true'` + `app.rpc_name='edit_purchase_order_line'`, performs the UPDATE on `purchase_orders`, and inserts a structured `write_audit_log` row.
5. Audit log captures: `actor_id`, `timestamp`, `rpc_name`, `row_pk=po_line_id`, `payload={ before: {...}, after: {...}, reason: '...' }`. This is enough to reconstruct any edit history without ambiguity.
6. A new read RPC `get_po_edit_history(p_po_id)` powers an "Edit history" pill on the PO card — drivers and operators can see who changed what, when, why.

## Proposed design

### Backend (Dara → Cody)

**1. `edit_purchase_order_line` — new canonical writer**

```sql
CREATE OR REPLACE FUNCTION public.edit_purchase_order_line(
  p_po_line_id              uuid,
  p_new_ordered_qty         integer  DEFAULT NULL,   -- NULL = no change
  p_new_price_per_unit_aed  numeric  DEFAULT NULL,   -- NULL = no change
  p_new_expiry_date         date     DEFAULT NULL,   -- NULL = no change
  p_reason                  text                     -- required, ≥10 chars
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_role  text;
  v_before       jsonb;
  v_after        jsonb;
  v_line         purchase_orders%ROWTYPE;
BEGIN
  -- Article 4: role + input validation
  SELECT role INTO v_caller_role
  FROM user_profiles WHERE id = auth.uid();

  IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'edit_purchase_order_line: forbidden for role %', v_caller_role;
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'edit_purchase_order_line: reason is required (≥10 chars)';
  END IF;

  SELECT * INTO v_line FROM purchase_orders WHERE po_line_id = p_po_line_id FOR UPDATE;
  IF v_line.po_line_id IS NULL THEN
    RAISE EXCEPTION 'edit_purchase_order_line: po_line_id % not found', p_po_line_id;
  END IF;

  -- Coherence: ordered_qty cannot drop below received_qty
  IF p_new_ordered_qty IS NOT NULL
     AND v_line.received_qty IS NOT NULL
     AND p_new_ordered_qty < v_line.received_qty
  THEN
    RAISE EXCEPTION 'edit_purchase_order_line: new ordered_qty (%) < received_qty (%). Reverse receipt first.',
      p_new_ordered_qty, v_line.received_qty;
  END IF;

  v_before := jsonb_build_object(
    'ordered_qty',        v_line.ordered_qty,
    'price_per_unit_aed', v_line.price_per_unit_aed,
    'total_price_aed',    v_line.total_price_aed,
    'expiry_date',        v_line.expiry_date
  );

  -- Article 8: attribution GUCs for the universal trigger
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'edit_purchase_order_line', true);

  UPDATE purchase_orders
  SET
    ordered_qty        = COALESCE(p_new_ordered_qty,        ordered_qty),
    price_per_unit_aed = COALESCE(p_new_price_per_unit_aed, price_per_unit_aed),
    expiry_date        = COALESCE(p_new_expiry_date,        expiry_date),
    total_price_aed    = COALESCE(p_new_ordered_qty,         ordered_qty)
                       * COALESCE(p_new_price_per_unit_aed,  price_per_unit_aed)
  WHERE po_line_id = p_po_line_id
  RETURNING * INTO v_line;

  v_after := jsonb_build_object(
    'ordered_qty',        v_line.ordered_qty,
    'price_per_unit_aed', v_line.price_per_unit_aed,
    'total_price_aed',    v_line.total_price_aed,
    'expiry_date',        v_line.expiry_date
  );

  -- Article 8: explicit append to write_audit_log with reason + before/after
  INSERT INTO write_audit_log (
    table_name, op, row_pk, actor, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'UPDATE', p_po_line_id::text, auth.uid(),
    true, 'edit_purchase_order_line',
    jsonb_build_object('before', v_before, 'after', v_after, 'reason', p_reason)
  );

  RETURN jsonb_build_object('po_line_id', p_po_line_id, 'before', v_before, 'after', v_after);
END;
$$;

GRANT EXECUTE ON FUNCTION public.edit_purchase_order_line TO authenticated;
```

**2. `get_po_edit_history` — read RPC for the Edit-history pill**

```sql
CREATE OR REPLACE FUNCTION public.get_po_edit_history(p_po_id text)
RETURNS TABLE (
  audit_id    uuid,
  po_line_id  uuid,
  actor_email text,
  changed_at  timestamptz,
  before      jsonb,
  after       jsonb,
  reason      text
)
LANGUAGE sql STABLE SECURITY INVOKER
AS $$
  SELECT
    wal.audit_id,
    wal.row_pk::uuid AS po_line_id,
    up.email AS actor_email,
    wal.changed_at,
    wal.payload -> 'before',
    wal.payload -> 'after',
    wal.payload ->> 'reason'
  FROM write_audit_log wal
  LEFT JOIN user_profiles up ON up.id = wal.actor
  JOIN purchase_orders po ON po.po_line_id = wal.row_pk::uuid
  WHERE wal.table_name = 'purchase_orders'
    AND wal.rpc_name = 'edit_purchase_order_line'
    AND po.po_id = p_po_id
  ORDER BY wal.changed_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_po_edit_history TO authenticated;
```

### FE (Stax)

**1. `/field/orders/page.tsx`** — add Edit button on each PO row for authorised roles. Tap opens an Edit drawer.

**2. New component: `EditPOLineDrawer.tsx`** — for each line of the PO, render three editable fields (qty, price, expiry) + a `Reason` textarea. Save iterates lines that changed and calls `edit_purchase_order_line` once per changed line.

**3. New component: `POEditHistoryPill.tsx`** — small chip rendered next to the PO status badge. Tap opens a bottom-sheet listing every audit row from `get_po_edit_history(p_po_id)` with `before → after` deltas + actor + reason.

**4. Receive flow alert**: `/field/receiving/[poId]/page.tsx` should display a warning banner when the PO has been edited post-receipt (`get_po_edit_history` returns rows newer than `received_date`), so the WH person knows the inventory may need a separate correction.

## Scope

In scope:

- `edit_purchase_order_line` RPC (canonical writer for purchase_orders UPDATE)
- `get_po_edit_history` RPC
- Edit drawer in `/field/orders` (FE)
- Edit history pill in `/field/orders` (FE)
- Post-edit warning banner in `/field/receiving/[poId]` (FE)

Out of scope:

- **Adding or removing PO lines** — explicitly excluded per CS decision. Adding a new product to a submitted PO would re-trigger driver collection and procurement intent; that belongs in a separate "amend PO" flow. Removing a line breaks `po_line_id` references from `driver_tasks` and `inventory_audit_log`.
- **Editing supplier_id or boonz_product_id** — these are immutable once the PO exists. Wrong supplier → cancel + recreate.
- **Auto-cascading post-receipt edits into `warehouse_inventory`** — explicitly NOT in scope. An expiry edit on a received PO will NOT touch the corresponding WH row. The WH row has its own physical reality (see [[feedback_pod_vs_wh_expiry_scope]]). The receive-flow banner surfaces the divergence; WH correction is a separate manager action via the inventory page.
- **Edit notifications to driver** — if the WH manager edits `ordered_qty` on a PO the driver still has to collect, the driver should ideally see the new number. Out of scope for v1; can be a follow-up PRD ([[PRD-002-procurement-driver-edit-notification]]) once edit volumes warrant it.

## Protected entities touched

`purchase_orders` (UPDATE via canonical RPC), `write_audit_log` (INSERT via DEFINER, append-only).

## Acceptance criteria

- [ ] Cody approves `edit_purchase_order_line` against Articles 1, 4, 5, 7, 8.
- [ ] Cody approves `get_po_edit_history` as SECURITY INVOKER read-only helper.
- [ ] Migration applies cleanly to prod with no `daily_sales` or `dispatch` regressions.
- [ ] `RPC_REGISTRY.md` updated with the new writer.
- [ ] `CHANGELOG.md` entry written.
- [ ] FE Edit drawer renders on `/field/orders` for `warehouse | operator_admin | superadmin | manager` and is hidden for `field_staff`.
- [ ] Save with missing reason → blocked at FE; if FE bypassed, RPC rejects with clear error.
- [ ] Save with `ordered_qty < received_qty` → RPC rejects with the exact message.
- [ ] On successful save: `purchase_orders` row reflects the new values; `write_audit_log` has a new row with `before`/`after`/`reason`; Edit history pill on `/field/orders` shows the new entry within 1 refresh.
- [ ] Post-receipt edit produces a banner on `/field/receiving/[poId]` next time anyone opens it.
- [ ] Smoke test: edit ordered_qty up, edit price, edit expiry — all three reflected; total_price_aed recalculated correctly.
- [ ] No direct FE writes to `purchase_orders` introduced (audit FE diff before merge).

## Edge cases

- **Empty save (no field changed):** FE blocks; RPC also rejects if before==after for all three fields (no-op edits pollute the audit log).
- **Concurrent edit by two managers:** `FOR UPDATE` row lock in the RPC serialises; later edit sees the first edit's "after" as its "before". Both rows appear in audit history.
- **`expiry_date` cleared to NULL:** allowed — capture the NULL transition in `after`. Useful when an originally-keyed expiry was wrong and should be re-set at receive.
- **`price_per_unit_aed` cleared to NULL:** allowed — captured in audit. `total_price_aed` becomes NULL too.
- **PO has zero lines:** impossible per `create_purchase_order` contract — no special handling.
- **Edit after the WH row already has the old expiry:** audit captures the PO change; banner in `/field/receiving/[poId]` warns. WH manager must reconcile separately via Inventory page (out of scope here).
- **Edit attempted by `field_staff`:** RPC raises `forbidden for role field_staff`. FE never shows the button.
- **Edit attempted with reason = whitespace:** blocked by `length(trim(p_reason)) < 10`.

## Verification

- [ ] `npx tsc --noEmit`
- [ ] `npm run build`
- [ ] `npm run lint`
- [ ] Manual smoke test as `warehouse@boonz.test`: open a Pending PO, edit qty + reason, confirm audit row + delta.
- [ ] Manual smoke test as `field_staff@boonz.test`: confirm Edit button hidden; confirm direct RPC call returns forbidden.
- [ ] `SELECT * FROM write_audit_log WHERE rpc_name='edit_purchase_order_line' ORDER BY changed_at DESC LIMIT 5` returns the test edits with full before/after/reason.

## Decisions

- **Lock state: always editable, including post-receipt.** CS confirmed. The post-receipt case is rare but real (price discrepancies that surface days later; supplier corrects an expiry on the docket). Rather than force a cancel-and-recreate flow, we permit the edit but make the divergence visible in the receive screen.
- **`ordered_qty` cannot drop below `received_qty`.** This is the one hard guard. Lowering ordered below received is incoherent — it implies the warehouse received units that were never ordered. RPC raises an error directing the user to reverse the receipt first.
- **Expiry edit does NOT touch `warehouse_inventory`.** Direct parallel to the Al Ain incident lesson. The PO and the WH batch are independent physical records. The receive-flow banner is the explicit visibility mechanism; the WH manager corrects the WH row separately if needed.
- **Reason is required, ≥10 characters.** Audit logs with no reason are nearly useless when revisited months later. Forcing 10 chars rules out "fix" / "typo" / single-word noise. Mirrors the audit-quality bar from [[feedback_no_destructive_changes]].
- **Add / remove lines deliberately excluded.** Adds re-trigger procurement intent; removes break FK chains. Both belong in a separate `amend_purchase_order` flow — captured as a future PRD if volume warrants.
- **Two roles + admin can edit.** `warehouse` (primary), `operator_admin` (CS), `superadmin` / `manager` (catch-all). `field_staff` explicitly excluded — drivers report via `driver_tasks.outcome`, never via PO edit.
- **Use `write_audit_log`, not a new table.** Universal audit is the canonical pattern (Article 8). Adding a bespoke `po_edit_audit_log` would fragment the audit story. `get_po_edit_history` does the filtering.
- **No notifications to driver on edit.** Out of scope v1. If edit volume warrants it, add `po_notifications` row in a follow-up.

## Linked memory

- [[feedback_pod_vs_wh_expiry_scope]] — the lesson driving the "expiry edit does not cascade to WH" decision
- [[feedback_no_destructive_changes]] — the audit-quality bar this PRD raises
- [[reference_machine_repurpose_terminal_pattern]] — same shape of audit problem (terminal moves), already solved via a dedicated history table; we follow the universal-log pattern instead because PO edits are higher volume and lower-stakes per row

## Linked PRDs

- _(none yet — this is the first procurement PRD)_

## Rollout plan

1. **Dara** ✅ Done — schema verified, RPC contracts corrected (see Review log).
2. **Cody** ✅ Done — ⚠️ Approve with revisions (see Review log).
3. Apply migration as `phaseF_proc_edit_po_line_audit` via `apply_migration`, verify via `pg_proc` + `pg_policies`.
4. **Stax** implements the FE drawer, history pill, and receive-flow banner. Diff goes to Cody for FE review (Article 3 audit).
5. CS smoke-tests both roles in staging.
6. `CHANGELOG.md` + `RPC_REGISTRY.md` updated. Done.

---

## Review log

### Dara — 2026-05-23 (schema verification + RPC corrections)

Verified live schema before approving the design. **Three corrections to apply before migration:**

1. **`ordered_qty` is `numeric`, not `integer`.** Live column type for both `purchase_orders.ordered_qty` and `purchase_orders.received_qty`. The RPC signature in `## Proposed design` shows `integer` — replace with `numeric` or the coherence check fails on implicit cast.

2. **`write_audit_log` columns are `operation` + `occurred_at`, not `op` + `changed_at`.** The draft INSERT statement and the `get_po_edit_history` SELECT reference column names that don't exist. Use:
   - `operation` (text, NOT NULL)
   - `row_pk` (text, NOT NULL)
   - `actor` (uuid)
   - `actor_role` (text) — **bonus: capture it, the column exists**
   - `via_rpc` (boolean)
   - `rpc_name` (text)
   - `occurred_at` (timestamptz)
   - `payload` (jsonb)

3. **`procurement_events` is the canonical PO audit table — use it ALSO.** The existing convention (`create_purchase_order` writes a `po_created` event) lives there. `procurement_events` has the correct shape, append-only RLS, and `idx_procurement_events_po_id (po_id, created_at DESC)` already serves `get_po_edit_history`. Per Cody's verdict below: dual-write to BOTH `procurement_events` AND `write_audit_log`.

4. **Optional denormalization (recommended).** Add two nullable columns to `purchase_orders`:
   - `last_edited_at timestamptz`
   - `last_edited_by uuid REFERENCES user_profiles(id) ON DELETE SET NULL`
     Cheap "edited 2h ago" rendering in the list view without a join. Update them inside `edit_purchase_order_line` only. **Column COMMENT required** (Cody finding).

5. **No new indexes required.** `idx_procurement_events_po_id` covers the read path.

6. **No new RLS policies required.** `procurement_events` and `write_audit_log` are both already append-only.

### Cody — 2026-05-23 (constitutional verdict)

**Verdict:** ⚠️ Approve with revisions

**Articles checked:** 1, 4, 5, 7, 8, 12, 14

**Findings:**

- Article 1 ✅ — sole canonical writer for the three editable fields. No overlap with `create_purchase_order` (INSERT only) or `receive_purchase_order` (writes `received_date` / `received_qty` only).
- Article 4 ✅ — DEFINER, sets `app.via_rpc` + `app.rpc_name`, validates role via `user_profiles`, validates inputs (reason ≥10 chars, line exists, ordered_qty ≥ received_qty), uses `FOR UPDATE` row lock.
- Article 5 ✅ — `received_date` state column untouched. State machine unaffected.
- Article 7 ✅ — `procurement_events` RLS is correctly append-only (verified `pg_policy`).
- Article 8 ⚠️ — **REQUIRED REVISION:** writing only to `procurement_events` follows precedent but diverges from Article 8's strict "every canonical writer ends with a row in `write_audit_log`." Either:
  - **(chosen)** Dual-write to BOTH `procurement_events` AND `write_audit_log` in the same transaction. Cost: one extra INSERT.
  - Or propose Article 15 amendment recognizing subsystem audit logs. **Open question for CS — see below.**
- Article 12 ✅ — single forward-only migration, `ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE`.
- Article 14 ✅ — no `_v2` or shadow tables.
- **Denormalization concern — REQUIRED REVISION:** `last_edited_at` / `last_edited_by` columns must carry COMMENT warnings naming `edit_purchase_order_line` as the sole writer. Without that, the next PR introducing a different writer creates silent drift.
- **No-op edit guard — RECOMMENDED:** if `v_before = v_after` for all three fields, raise rather than write a noise event.

**Next actions baked into this PRD:**

1. Apply the three Dara corrections + dual-write to `write_audit_log`.
2. Add column COMMENTs on the denormalized fields.
3. Add the no-op guard (recommended).
4. Migration name: **`phaseF_proc_edit_po_line_audit`**.
5. Update `RPC_REGISTRY.md` — add `edit_purchase_order_line` to canonical writers section, `get_po_edit_history` to read-only helpers section.
6. Update `CHANGELOG.md` citing Articles 1, 4, 7, 8.

### Open question for CS

Cody flagged: do you want an **Article 15 amendment** recognizing subsystem audit tables (`procurement_events`, `pod_inventory_audit_log`, `warehouse_inventory_audit_log`) as Article 8-equivalent? If yes, we can later drop the dual-write to `write_audit_log` and rely on `procurement_events` alone. If no, the dual-write becomes the permanent pattern for procurement edits. **Default = dual-write now; amendment can come later.**

---

## Implementation handoff (for Claude Code `/goal`)

Everything below this line is the executable contract. The agent picking this up should:

1. Apply migration `phaseF_proc_edit_po_line_audit` containing:
   - `ALTER TABLE purchase_orders ADD COLUMN IF NOT EXISTS last_edited_at timestamptz, ADD COLUMN IF NOT EXISTS last_edited_by uuid REFERENCES user_profiles(id) ON DELETE SET NULL;`
   - Column COMMENTs on both new columns naming `edit_purchase_order_line` as the sole writer.
   - `CREATE OR REPLACE FUNCTION public.edit_purchase_order_line(...)` with the **Dara-corrected signature** (`numeric` not `integer`) and **Cody-required dual-write** (both `procurement_events` and `write_audit_log`, using `operation` + `occurred_at` column names, capturing `actor_role`).
   - Optional no-op guard at the top of the function body.
   - `CREATE OR REPLACE FUNCTION public.get_po_edit_history(p_po_id text)` reading from `procurement_events` (per Dara — already-indexed access path).
   - `GRANT EXECUTE ... TO authenticated` on both.

2. Verify via `mcp__supabase__execute_sql`:
   - `SELECT proname, prosrc FROM pg_proc WHERE proname IN ('edit_purchase_order_line','get_po_edit_history')`
   - Smoke test: insert a fake PO line, call `edit_purchase_order_line`, assert both `procurement_events` and `write_audit_log` got rows.

3. Update `docs/architecture/RPC_REGISTRY.md` and `docs/architecture/CHANGELOG.md`.

4. Implement FE per the `### FE (Stax)` section above. Hand the diff to Cody for Article 3 review before merge.

5. Mark PRD `status: Done` with a `done_summary` block citing the applied migration name.
