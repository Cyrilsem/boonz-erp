# PRD-123 — Warehouse return confirmation: expiry and flavour splits

**Owner:** CS
**Written:** Monday 14 September 2026
**Status:** ready to build
**Follows:** PRD-122 (warehouse integrity). Unrelated to the dispatch-button defects logged the same day.

---

## 1. Problem

The Warehouse Confirmations queue accepts **one quantity, one expiry and one outcome per
line, once.** Goods come back from a machine as a mixture of batches and, on a multi-flavour
lane, a mixture of flavours. The screen cannot express that, so the warehouse manager is
forced to either pick one expiry and silently misfile the rest, or not confirm at all.

Simran hit this today and stopped, which is the correct call and the reason it is worth
fixing properly rather than working around.

### 1.1 Today's queue, measured

11 open lines. **Eight of them cannot be confirmed correctly as the screen stands.**

| Machine  | Shelf | Product                                 | System says  | Physically counted                                          | Gap                         |
| -------- | ----- | --------------------------------------- | ------------ | ----------------------------------------------------------- | --------------------------- |
| WPP      | A01   | Evian Regular                           | 3 @ 29/04/27 | **7** across 2@17/10/27, 2@13/10/27, 1@29/04/27, 2@07/06/27 | qty AND 4 expiries          |
| VML-1004 | A15   | Evian Regular                           | 5 @ 07/06/27 | 4@29/04/27, 1@07/06/27                                      | 2 expiries                  |
| VML-1003 | A06   | Freakin Protein Balls Caramel Crunch 3P | 3 @ 07/03/27 | 2@06/04/27, 1@07/03/27                                      | 2 expiries                  |
| USH      | A13   | Hunter Sea Salted                       | 2 @ 28/02/27 | 1@28/02/27, 1@31/03/27                                      | 2 expiries                  |
| USH      | A13   | Hunter Hot Chili                        | 2 @ 04/02/27 | 1@29/03/27, 1@14/03/27                                      | 2 expiries, neither matches |
| USH      | A13   | Hunter Black Truffle                    | 2 @ 25/02/27 | 1@25/02/27, 1@31/01/27                                      | 2 expiries                  |
| NOVO     | A15   | Freakin Roasted Cashew                  | 3            | **2**                                                       | flavour                     |
| NOVO     | A15   | Freakin Roasted Almond                  | 1 + 3 = 4    | **5**                                                       | flavour                     |

The NOVO A15 pair is the flavour case in miniature: totals agree at 7, the split does not.
One unit came off the shelf as Almond that the system had booked as Cashew. There is no way
to say that on this screen.

Note also that the expiry the screen proposes is **the FEFO-pinned batch from the outbound
dispatch**, not what physically returned. On Hunter Hot Chili neither counted batch matches
the proposed one. Confirming as shown would credit stock against a batch that never left.

### 1.2 Why it is stuck

`WarehouseConfirmationsPanel.tsx` holds one `qtyEdit`, one `expiryEdit`, one `outcomeEdit`
and one `disposalEdit` per `line_id`, and calls:

```
wm_confirm_line(p_line_id, p_qty, p_expiry, p_outcome,
                p_target_machine_id, p_disposal_code, p_reason, p_caller, p_dry_run)
```

That RPC is single-shot by construction. It credits **one** `warehouse_inventory` row,
writes **one** `disposition_events` row, then finishes with:

```
UPDATE refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id
 WHERE dispatch_id = p_line_id;
```

Stamping `wh_approved_at` drops the line out of `v_wm_confirmations`, so a second call for
the remaining batches fails with _"is not an open Warehouse Confirmations line"_. Confirming
once is confirming forever. `boonz_product_id` is read from the view and never editable, so
flavour cannot move at all.

The sibling panel `PendingRemoveApprovalsPanel.tsx` already solved both halves of this under
PRD-049 Phase D and the 19-May multi-variant fix. That capability was simply never carried
into the newer WM queue.

### 1.3 A second, quieter defect

`wm_confirm_line` never compares `p_qty` to the line's own quantity. WPP A01 expects 3 and 7
came back. Today that over-count would be accepted in silence. It should be allowed, because
the physical count is the truth, but it should be **recorded as a variance**, not absorbed.

---

## 2. Goals

1. Let the warehouse manager confirm one returned line as **several batches**, each with its
   own quantity, expiry and outcome.
2. Let her **re-attribute flavour** within the line's pod product, so a Cashew booked out and
   an Almond returned lands on the right SKU.
3. Keep the write **atomic**: either every split lands or none does, and `wh_approved_at` is
   stamped exactly once.
4. **Record the variance** when the counted total differs from the planned quantity, instead
   of swallowing it.
5. Change nothing about the single-batch path. Most lines are one batch and must stay one tap.

### Non-goals

- Reworking `PendingRemoveApprovalsPanel`. It already has both splits.
- Changing FEFO or how the outbound pin is chosen.
- Touching the dispatch-completion defects logged separately today.

---

## 3. Requirements

### P1 — `wm_confirm_line_split`

- **R1.1** New RPC `wm_confirm_line_split(p_line_id uuid, p_splits jsonb, p_reason text,
p_caller uuid, p_dry_run boolean DEFAULT true)`.
- **R1.2** Each entry of `p_splits`:

  ```json
  {
    "qty": 2,
    "expiry": "2027-10-17",
    "outcome": "restocked | redeploy_pending | waste",
    "boonz_product_id": null,
    "target_machine_id": null,
    "disposal_code": null
  }
  ```

  `boonz_product_id` null means the line's own product. A non-null value **must** resolve to
  a boonz product carrying an Active `product_mapping` row against the line's
  `pod_product_id`; anything else is rejected by name, not silently coerced.

- **R1.3** Per-entry validation reuses `wm_confirm_line`'s existing rules verbatim: qty > 0,
  outcome in the three allowed values, `2099-12-31` sentinel refused, `disposal_code`
  mandatory and enumerated on waste, `target_machine_id` and `expiry` mandatory on
  `redeploy_pending`.
- **R1.4** One `warehouse_inventory` credit and one `disposition_events` row **per entry**,
  following the same top-up-else-insert logic as today so batches merge where they already
  exist rather than spawning duplicates.
- **R1.5** `wh_approved_at` and `wh_approved_by` are stamped **once**, after the loop.
- **R1.6** The whole call is one transaction. Any rejected entry rolls back every entry.
- **R1.7** Between 1 and 20 entries. Empty array rejected.
- **R1.8** `p_dry_run` defaults **true** and returns the full per-entry preview including each
  resolved `wh_inventory_id`, `credited_mode` and `value_aed`, plus the variance in R2.1.

### P2 — Variance recording

- **R2.1** When the sum of split quantities differs from the line's planned quantity, the
  result carries `variance_qty` and `variance_pct`, and each `disposition_events` row written
  by that call carries the same variance in its reason text. The write is **not** blocked:
  the count is the truth.
- **R2.2** A variance beyond 20% or 3 units raises a `monitoring_alerts` row of type
  `return_count_variance` naming the machine, shelf, product, expected and counted.
- **R2.3** `wm_confirm_line` gets the same variance recording, so the single-batch path is
  not a blind spot.

### P3 — The screen

- **R3.1** Each card in `WarehouseConfirmationsPanel` gets a **Split** toggle. Collapsed is
  today's behaviour, unchanged, still one tap.
- **R3.2** Opened, it shows an editable table of rows: **Qty · Expiry · Flavour · Outcome ·
  Disposal / Target**. Add row, remove row.
- **R3.3** Flavour is a dropdown of the boonz products mapped to this line's pod product,
  defaulting to the line's own. On a single-variant pod the column is hidden, not disabled.
- **R3.4** Expiry accepts a **free date**, not only batches already in CENTRAL. Returned
  goods routinely carry batches the warehouse has never held. Show known batches as
  suggestions, never as the only choice.
- **R3.5** A live counter reads `Counted 7 of 3 planned · variance +4`, in amber past the R2.2
  threshold. It informs, it does not block.
- **R3.6** Confirm is disabled until every row is complete, and calls the RPC once with
  `p_dry_run := false`.
- **R3.7** The dry run fires on open and on every edit, and its preview is shown inline, so
  she sees which batch each row will land on before committing.
- **R3.8** The RPC error surfaces **on the card**. Today `wm_confirm_line` failures land in a
  panel-level banner that scrolls out of view.

### P4 — Proof

- **R4.1** Every guard proven against a real bad payload inside a rolled-back transaction:
  a foreign `boonz_product_id`, the 2099 sentinel, waste with no disposal code,
  `redeploy_pending` with no target, an empty array, 21 entries.
- **R4.2** Replay all eight of today's lines from section 1.1 as dry runs and match the
  expected credits batch by batch.
- **R4.3** No regression: single-batch `wm_confirm_line` behaviour byte-identical apart from
  the new variance fields; `v_wm_confirmations` still returns 11 open lines before any
  confirm; `validate_refill_plan('2026-09-12')` still returns 53 blocking.

---

## 4. Acceptance criteria

| #   | Criterion                                                                                                                                         |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | WPP A01 Evian confirms as 2@17/10/27, 2@13/10/27, 1@29/04/27, 2@07/06/27 in one call, four credits, four disposition events, one `wh_approved_at` |
| A2  | NOVO A15 confirms as Cashew 2 and Almond 5 against the correct SKUs, from two lines that were booked 3 and 4                                      |
| A3  | USH A13 Hunter Hot Chili confirms against 29/03/27 and 14/03/27, neither of which was the proposed batch                                          |
| A4  | A split naming a boonz product not mapped to the line's pod product is rejected by name                                                           |
| A5  | A split whose first entry is valid and second is not writes nothing at all                                                                        |
| A6  | WPP A01 counted 7 against planned 3 records `variance_qty = 4` and raises one `return_count_variance` alert                                       |
| A7  | A single-batch line still confirms in one tap with no split opened                                                                                |
| A8  | Every new function refuses to act on its first call and returns a preview                                                                         |

---

## 5. Not part of this, but found while writing it

- **The queue is behind an inventory-control session.** Quantities stay read-only until
  someone presses **Start Inventory Control**. No session has been opened since 25 August.
  This is working as designed, but the banner reads as an error rather than an instruction,
  and it cost an hour today. Worth a wording pass.
- **`PendingRemoveApprovalsPanel` is buried** under 76 junk dispatch rows dated 2030
  (VOXMCC-1005: Fade Fit Hazelnut, Fade Fit Coconut, Barebells Cookies And Cream, each
  repeated many times). Already PRD-122 R3.4. It makes the returns area hard to work in.
- **One line has been open 485 hours**: IFLYMCC-1024 A05 Pepsi Regular 8 units from
  25 August. Nothing chases an unconfirmed return.

---

## 6. Claude Code prompt

The self-contained `/goal` command is in `PRD-123-goal-command.md`, ready to paste.
