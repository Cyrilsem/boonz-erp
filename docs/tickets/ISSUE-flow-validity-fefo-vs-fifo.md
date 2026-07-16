# ISSUE — Flow validity must be established BEFORE we tighten guards (FEFO vs FIFO)

**Logged:** 2026-07-11 · **Raised by:** CS · **Status:** LOGGED — do NOT "fix" by tightening. Validate first.
**Class:** correctness-of-semantics (not a single bug — a trust problem across the stock-mutation flows)

---

## The thesis (CS)

> "I have a problem with the validity of the flows before tightening it. That's the issue. For example in the
> refresh it's still doing FIFO so definitely will miss the FEFO model in this flow."

Adding constraints, guards and provenance checks on top of flows whose **stated semantics do not match their
actual behaviour** does not make the system correct — it _cements_ whatever behaviour happens to be there and
makes it harder to see. Every guard we've shipped recently (provenance, drift-kill, quarantine, slot guard)
assumes the underlying decrement/pick order is right. That assumption has never been validated.

**Rule going forward: no new guard on a flow until that flow's pick/decrement order is proven.**

## What the audit actually found (live catalogue, 2026-07-11)

The headline is NOT "everything is FIFO". It is worse and more insidious: **the labels lie, and one real
FIFO hides among them.**

| Function                               | Actual ORDER BY                                        | Real behaviour                 | What it _says_                                                                                           |
| -------------------------------------- | ------------------------------------------------------ | ------------------------------ | -------------------------------------------------------------------------------------------------------- |
| **`adjust_warehouse_stock`**           | `ORDER BY created_at ASC`                              | **TRUE FIFO — expiry ignored** | (silent)                                                                                                 |
| `auto_decrement_pod_inventory` (sales) | `expiration_date ASC NULLS LAST, snapshot_date ASC`    | FEFO ✔                         | (silent)                                                                                                 |
| `pack_dispatch_line`                   | `expiration_date ASC NULLS LAST, warehouse_stock DESC` | FEFO ✔                         | (silent)                                                                                                 |
| `stitch_pod_to_boonz`                  | `expiration_date NULLS LAST`                           | FEFO ✔                         | (silent)                                                                                                 |
| `transfer_warehouse_stock`             | `expiration_date ASC NULLS LAST, created_at ASC`       | FEFO ✔                         | error text says **"after FIFO pick"**                                                                    |
| `resync_pod_inventory_from_weimi`      | `expiration_date ASC NULLS LAST, created_at ASC`       | FEFO ✔                         | comment says **"trim OLDEST first (FIFO survivors are newest)"**; refresh UI prints **"FIFO decrement"** |

### Finding 1 — one genuine FIFO, in the worst possible place

`adjust_warehouse_stock` selects batches by **`created_at ASC`** — insertion order, **expiry ignored**. This is
the RPC behind manual corrections and the **FE inline qty edit**. So the one path a human reaches for when
inventory looks wrong is the one path that does not respect expiry. (It is also the path that silently zeroed
24 Gatorade units on 11/07 with no offsetting credit — see the 10/07 MCC reconcile.)

### Finding 2 — the labels are lies (the reason nobody can validate anything)

The refresh pipeline prints **"FIFO decrement"**, `transfer_warehouse_stock` raises **"after FIFO pick"**, and
`resync_pod_inventory_from_weimi` is commented **"FIFO survivors are newest"** — while all three actually order
by `expiration_date ASC` (FEFO). The behaviour is right; the words are wrong. This is the same **label ≠ truth**
class as the eligibility-blind picker. It means **you cannot audit these flows by reading them** — and neither
can the team, or an agent. That is precisely CS's objection.

### Finding 3 — FEFO is enforced at _pack_ time but not at _plan_ time

`pack_dispatch_line` / `stitch` are FEFO, but the **planner reads raw `warehouse_inventory`** while pack enforces
`v_wh_pickable` (see `reference_inventory_raw_vs_pickable_divergence`). So the plan can name a batch/expiry that
pack will never issue. This is the mechanical cause of the operator complaints in the refill doc:

- Nissan: "refill is showing Nutella exp 09/09 even though that batch is no longer in inventory"
- Nissan: "Smart Gourmet — refill allocating an expiry (06/04/27) that has 0 stock"
- Amazon: "Activia — we have 27/07 expiry but refill says 02/08; should be FEFO"
  The operator is not seeing a FIFO bug. They are seeing **two different truths** — planner vs executor.

## What "validating the flow" means (the work to do BEFORE any tightening)

1. **Enumerate every stock-mutating path** (pod + warehouse) and, for each, state in one line: _what does it
   pick, in what order, from which source of truth?_ Publish as a table. No path may be "silent".
2. **Make the labels match the behaviour.** Rename the refresh step, the `transfer_warehouse_stock` error text
   and the `resync` comment to FEFO. A flow whose name lies cannot be trusted or reviewed.
3. **Fix the one real FIFO**: `adjust_warehouse_stock` → order by `expiration_date ASC NULLS LAST, created_at ASC`.
   (Careful: callers usually pass an explicit `wh_inventory_id`, so this only bites the fallback path — confirm
   blast radius before changing.)
4. **Collapse planner/executor onto one truth** — planners must read the same pickable view pack enforces
   (`v_wh_available` / `v_wh_pickable`, per the Dara proposal). Until then, FEFO "working" at pack time is
   invisible to the operator and looks like a bug.
5. **Only then** re-tighten guards (slot guard → block, provenance RAISE, etc.).

## Explicitly NOT to do now

- Do not flip `weimi_slot_guard` to `block`.
- Do not add the provenance `RAISE` (PRD-099 belt-and-suspenders).
- Do not add new CHECK constraints on `warehouse_inventory`.
  All of these harden a flow whose semantics are not yet agreed. Ship them after steps 1–4.

## Related

- Dara: `docs/architecture/DARA-warehouse-availability-canonical.md` (planner/executor single truth — step 4)
- PRD-099 (approve_return provenance) — shipped; its optional RAISE is deliberately parked here
- Drift-kill fleet reconcile (2026-07-10) — closed; guard flip parked here
- 10/07 MCC reconcile — the inline-qty-edit stock loss that exposed this
