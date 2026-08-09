# PRD-113 — In-Machine Moves Are Not Returns + Expired Stock Never Auto-Consumed

Branch: `prd-113-internal-moves-expired-guard`
Started 2026-08-10. Report is append-only; each leg adds a section.

---

## Leg 1 — reconnaissance

### The incident, read off live data

`MC-2004-0100-O1`, plan `2026-08-07`. Two shelves swapped contents **inside one machine**:

| shelf       | Add New           | Remove             |
| ----------- | ----------------- | ------------------ |
| `6a0a2954…` | Coca Cola Zero ×8 | Pepsi Black ×1, ×1 |
| `702bca73…` | Pepsi Black ×6    | Coca Cola Zero ×3  |

Pepsi Black left shelf `6a0a…` and landed on `702bca73…`; Coke Zero did the reverse. Both
Remove legs therefore had an **Add New counterpart for the same product, on another shelf of
the same machine, in the same plan** — and both were sitting in the warehouse return queue.
That pairing is the detection rule the PRD asks for, and the live rows confirm it exactly.

The positive control is on the same plan: three `Machine To Warehouse` legs of Freakin
Protein Balls (4 + 3 + 3) with **no** Add New counterpart. Genuine returns; they must keep
queueing. Three other Remove legs (Tamreem Peach/Mango, Nutella Biscuit) likewise have no
counterpart and were correctly approved on 2026-08-07.

The three MC-2004 legs still carry the hand-fix comment
`" | PRD-113 class bug: in-machine move leg wrongly queued as warehouse return"` with
`wh_approved_at = 2026-08-08 15:49:10Z`. That neutralisation is what this PRD retires.

### The queue

`public.v_pending_wh_remove_confirmations` — `action='Remove'`,
`driver_confirmed_at IS NOT NULL`, `wh_approved_at IS NULL`, not `item_added`, not
`returned`, not `is_m2m`. `is_m2m` is the _cross-machine_ exclusion added by PRD-054-A /
PRD-070; there was no _same-machine_ concept at all. `monitor_stuck_remove_dispatches`
(cron 12) reads this same view, so fixing the view fixes the nag for free.
`cron_pending_return_alert` reads `v_pending_return_approvals`, a different
(`warehouse_inventory`) queue — out of scope, untouched.

Three RPCs credit the warehouse for a Remove leg: `wh_approve_remove_receipt`,
`wh_approve_remove_receipt_multivariant`, `approve_stuck_remove`. All three already carry a
PRD-070 `is_m2m` refusal; all three needed the same-machine sibling.

### The decrementer, and its complete call graph

    refresh-stage1 (edge fn v48, step "FIFO decrement... N processed")
      -> run_pod_inventory_decrement()          -- thin counter wrapper
        -> auto_decrement_pod_inventory()       -- the actual FIFO loop

`auto_decrement_pod_inventory` orders candidate batches
`expiration_date ASC NULLS LAST, snapshot_date ASC` with **no expiry filter at all**, so
expired batches are drained first. Verified 2026-08-10 across `cron.job` (48 jobs), the repo
(`src/`, `supabase/functions/`) and `pg_proc`: **no other caller exists**. There is exactly
one implementation, so the PRD's "cron parity — one shared implementation, not two copies"
holds by construction and one edit is the whole fix. `refresh-stage1` needs no redeploy.

### Golden baseline

71 enabled fixtures (P0 9 / P1 10 / P2 13 / P3 22 / P4 17). `golden.run_all` cannot be
driven through the MCP `execute_sql` channel — its statement timeout kills fixture 3
mid-engine-run and the whole `run_all` transaction rolls back, banking nothing. Per the
PRD-110 leg-138 lesson (S-250), fixtures are fired **one at a time** through
`/tmp/prd110_sql.sh` with `SET statement_timeout='600s'`, and adjudicated by reading
`golden.runs` back, never off the response body.

---

## Leg 1 — backend, drafted

Four additive migrations written; **not yet applied — Cody review is the gate.**

| file                                                                | what                                                                                                                               |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `20260810110000_prd113_a1_is_internal_move_column.sql`              | `refill_dispatching.is_internal_move boolean NOT NULL DEFAULT false` + partial pairing index                                       |
| `20260810110500_prd113_a2_internal_move_predicate_and_writer.sql`   | `is_internal_move_dispatch()` (the one definition), `mark_internal_move_legs()`, `tg_mark_internal_move_pair` AFTER INSERT trigger |
| `20260810111000_prd113_a3_return_queue_excludes_internal_moves.sql` | queue view exclusion + refusal in all three `approve` RPCs                                                                         |
| `20260810111500_prd113_a4_fifo_never_consumes_expired.sql`          | FIFO skips batches expired as of the Dubai date; overflow reported, never silent                                                   |

### Design note — why a trigger, not an edit to each writer

The PRD names four writer families. `stitch_pod_to_boonz` alone is 51 KB and
`push_plan_to_dispatch` 24 KB; re-emitting protected engine code to append one `PERFORM`
each is a large diff for no extra coverage. More decisive: **the pair is not knowable when
the Remove leg is inserted** — its Add New counterpart is normally written later in the same
batch. Only a post-insert pass can see both legs. The trigger is the codebase's own
established shape for this (`trg_flag_remove_with_transfer_intent`,
`trg_flag_multivariant_return_without_correction`), and it covers every writer that exists
today and every writer added tomorrow with one implementation.

The stored column is deliberately **not** the safety net. The queue view and all three
`approve` RPCs call the live predicate `is_internal_move_dispatch()`, so a leg the trigger
somehow missed still cannot produce a phantom warehouse credit.

### Design note — the false-positive direction, stated plainly

The pairing rule can misfire: a genuine return of product X could coincide with a
warehouse-sourced Add New of X on another shelf of the same machine, same day. The cost of
that misfire is an **uncredited** warehouse return (WH understated, reversible by clearing
one boolean); the cost of the opposite error is **phantom stock** (WH overstated, silently
wrong, the incident this PRD exists to stop). The asymmetry is chosen deliberately.

To keep it from being silent (LAW 5), every auto-flag lands a `monitoring_alerts` row
(`prd113_internal_move_flagged`) naming the leg, the machine, the product and the writer
that stamped it, with the instruction for reversing it.

### Repair report — 30-day expired consumption

Generated 2026-08-10 from `pod_inventory_audit_log` (`source='sale'`, `delta<0`) joined to
the batch's `expiration_date`. **3 batches, 14 units.** Full table in
`docs/prds/PRD-113-expired-consumption-report.md`. No automatic restoration; CS decides.
