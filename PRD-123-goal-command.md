# PRD-123 — Claude Code prompt

Paste everything below into Claude Code in `boonz-erp`.

---

/goal

You are working on the Boonz ERP. Supabase project `eizcexopcuoycuosittm`. Repo root is the
`boonz-erp` checkout you are in.

Build PRD-123: let the warehouse manager confirm a returned line as several batches, each
with its own quantity, expiry, flavour and outcome. Today she can only confirm one batch,
once, and the line then closes forever.

Work in order. Do not skip ahead. Every destructive function takes `p_dry_run boolean
DEFAULT true`. Use `mcp__supabase__apply_migration` for DDL, never raw DDL through
`execute_sql`. Impersonate Cyril operator_admin `82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d` via
`set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true)`
in the SAME `execute_sql` call as any role-gated RPC. `execute_sql` returns only the LAST
statement's output.

---

## Phase 0 — Read before you write

1. `pg_get_functiondef` on `public.wm_confirm_line`. This is your template. The new function
   reuses its validation and its credit logic verbatim.
2. The view `public.v_wm_confirmations`. Note that `wm_confirm_line` stamps
   `refill_dispatching.wh_approved_at` at the end, which is what drops the line out of the
   view and makes a second confirm impossible.
3. `src/components/inventory/WarehouseConfirmationsPanel.tsx` (372 lines). This is the screen.
4. `src/components/inventory/PendingRemoveApprovalsPanel.tsx` (824 lines). **Read this
   carefully.** It already implements both a variant split and an expiry split under PRD-049
   Phase D. Follow its state shape and its UX so the two panels feel like one product. Do not
   invent a second pattern.

Report what you found before writing anything.

---

## Phase 1 — `wm_confirm_line_split`

Create `public.wm_confirm_line_split(p_line_id uuid, p_splits jsonb, p_reason text,
p_caller uuid, p_dry_run boolean DEFAULT true)`.

Each entry of `p_splits`:

```json
{
  "qty": 2,
  "expiry": "2027-10-17",
  "outcome": "restocked|redeploy_pending|waste",
  "boonz_product_id": null,
  "target_machine_id": null,
  "disposal_code": null
}
```

Rules:

- Role gate identical to `wm_confirm_line`: warehouse, operator_admin, superadmin, manager.
- 1 to 20 entries. Empty or absent array rejected.
- Per entry, reuse `wm_confirm_line`'s validation **exactly**: `qty > 0`; outcome in the three
  allowed values; `expiry = '2099-12-31'` rejected as the sentinel; `disposal_code` required
  and in `('Waste','Returning to supplier','Returned to supplier')` when outcome is waste;
  `target_machine_id` AND `expiry` both required when outcome is `redeploy_pending`;
  `p_reason` required.
- `boonz_product_id` null means the line's own product. A non-null value must resolve to a
  boonz product with an Active `product_mapping` row against the line's `pod_product_id`.
  Reject anything else **by product name**, not with a bare uuid, and never coerce silently.
- Per entry: one `warehouse_inventory` credit using the SAME top-up-else-insert logic as
  `wm_confirm_line` (match on boonz_product_id + warehouse + Active + expiry, oldest first,
  FOR UPDATE; otherwise insert with batch_id `WM-CONFIRM-<line_id>`), and one
  `disposition_events` row.
- Waste entries call `warehouse_expire_writeoff` exactly as today.
- `wh_approved_at` / `wh_approved_by` stamped **once**, after the loop, only when
  `v_line.source = 'dispatch_return'`. For `driver_expiry_check` keep today's
  `superseded_by_event` behaviour, pointing at the FIRST event written.
- One transaction. Any rejected entry rolls back every entry.
- `p_dry_run` returns the full per-entry preview: resolved `wh_inventory_id`,
  `credited_mode`, `value_aed`, plus the variance from Phase 2.

Then add `wm_confirm_line_split` to the `enforce_canonical_dispatch_write` allowlist, and set
`app.via_rpc` / `app.rpc_name` at the top exactly as `wm_confirm_line` does.

---

## Phase 2 — Variance recording

- When the sum of split quantities differs from the line's planned quantity, return
  `variance_qty` and `variance_pct`, and append the variance to the reason text on every
  `disposition_events` row that call writes. **Do not block the write.** The physical count is
  the truth.
- Beyond 20% or 3 units absolute, raise one `monitoring_alerts` row of type
  `return_count_variance` naming machine, shelf, product, expected and counted.
- Add the same variance recording to `wm_confirm_line` so the single-batch path is not a blind
  spot. Its behaviour must otherwise be byte-identical.

---

## Phase 3 — The screen

Edit `src/components/inventory/WarehouseConfirmationsPanel.tsx` only. Surgical, no refactor.

- A **Split** toggle per card. Collapsed is today's behaviour, unchanged, still one tap. Do
  not regress the single-batch flow.
- Open: an editable row list of **Qty · Expiry · Flavour · Outcome · Disposal / Target**, with
  add row and remove row.
- Flavour is a dropdown of boonz products mapped to this line's `pod_product_id`, defaulting
  to the line's own product. On a single-variant pod, hide the column entirely.
- Expiry accepts a **free date**. Returned goods routinely carry batches CENTRAL has never
  held. Offer known batches as suggestions, never as the only choice.
- A live counter: `Counted 7 of 3 planned · variance +4`, amber past the Phase 2 threshold.
  Informational, never blocking.
- Fire the dry run on open and on every edit and show its preview inline, so she sees which
  batch each row lands on before committing.
- Confirm disabled until every row is complete; calls the RPC once with `p_dry_run := false`.
- **Surface RPC errors on the card**, not in the panel-level banner. Today a
  `wm_confirm_line` failure lands in a banner that scrolls out of view.

---

## Phase 4 — Prove it, then stop

Inside a rolled-back transaction, prove every guard against a real bad payload: a foreign
`boonz_product_id`, the 2099 sentinel, waste with no disposal code, `redeploy_pending` with
no target, an empty array, 21 entries, and a two-entry payload whose second entry is invalid
(must write nothing).

Then dry-run these eight real open lines and show, batch by batch, exactly what each would
credit. These are the live rows as of 14 September 2026:

| Machine           | Shelf | Product                                 | System         | Counted                                                |
| ----------------- | ----- | --------------------------------------- | -------------- | ------------------------------------------------------ |
| WPP-1002-4300-O1  | A01   | Evian Regular                           | 3 @ 2027-04-29 | 2@2027-10-17, 2@2027-10-13, 1@2027-04-29, 2@2027-06-07 |
| VML-1004-0500-O1  | A15   | Evian Regular                           | 5 @ 2027-06-07 | 4@2027-04-29, 1@2027-06-07                             |
| VML-1003-0400-O1  | A06   | Freakin Protein Balls Caramel Crunch 3P | 3 @ 2027-03-07 | 2@2027-04-06, 1@2027-03-07                             |
| USH-1008-0000-W1  | A13   | Hunter Sea Salted                       | 2 @ 2027-02-28 | 1@2027-02-28, 1@2027-03-31                             |
| USH-1008-0000-W1  | A13   | Hunter Hot Chili                        | 2 @ 2027-02-04 | 1@2027-03-29, 1@2027-03-14                             |
| USH-1008-0000-W1  | A13   | Hunter Black Truffle                    | 2 @ 2027-02-25 | 1@2027-02-25, 1@2027-01-31                             |
| NOVO-1023-0000-W0 | A15   | Freakin Roasted Cashew                  | 3              | 2                                                      |
| NOVO-1023-0000-W0 | A15   | Freakin Roasted Almond                  | 1 + 3 = 4      | 5                                                      |

The NOVO pair is the flavour case: totals agree at 7, the split does not. One unit came off
as Almond that the system booked as Cashew. Prove the re-attribution lands on the right SKU.

Regression, all three must hold:

- `wm_confirm_line` single-batch behaviour unchanged apart from the new variance fields.
- `select count(*) from v_wm_confirmations` still returns 11 before any real confirm.
- `validate_refill_plan('2026-09-12')` still returns 53 blocking.

**Commit nothing to those eight lines.** Dry runs only. CS confirms them by hand once the
screen ships.

---

## Report

One page. What you built, the eight dry-run previews batch by batch, the guard proofs, the
three regression numbers, and anything you found that the PRD did not anticipate. Flag
honestly if any part is weaker than specified rather than reporting it as done.
