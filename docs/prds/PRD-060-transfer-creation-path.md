# PRD-060 - Transfer creation path: force machine-to-machine moves through the M2M writer

**Status:** Draft. Backend (engine/dispatch guards + receive guard) + FE (a real "Create transfer" action). Cody Articles 1/4/6/8/12.
**Owner:** CS (cyrilsem@gmail.com)
**Created:** 2026-06-24
**Severity:** HIGH (recurring data integrity). Every field transfer is being hand-built as plain Remove + Refill and breaks the warehouse accounting. Recurred NOVO->MINDSHARE (23 Jun, PRD-052) and MC->AMZ (24 Jun).

## 0. The recurring failure (verified 24 Jun, MC-2004 -> AMZ-1029/1038)

A transfer is created as:

- SOURCE: plain `Remove` lines with `[TRUCK-TRANSFER - do not debit WH]` typed in the comment, `is_m2m=false`, `source_kind='unknown'`, no `m2m_transfer_id`, no `from_machine_id`.
- DEST: plain `Refill` lines tagged `[TRUCK-TRANSFER from <machine>]`, `source_origin='warehouse'`, `is_m2m=false`.

Consequences, all live:

1. The `[do not debit WH]` comment is inert text - nothing reads it. The dest Refills debit Central on receive (3 of 5 already `item_added=true`).
2. The source Removes credit Central on receive (sitting `item_added=false` in the returns-approval queue) - the original drain-to-warehouse bug.
3. No conservation: BBQ removed 3 vs received 4; G&H Salt & Pepper received "from MC" with NO source leg.

PRD-052/056 fixed the accounting and the confirm path WHEN a move is flagged `is_m2m`. Nothing forces creation to set it. `flag_remove_with_transfer_intent` only WARNS (writes a monitoring_alert); it does not block or convert.

## 1. The change (decided)

### 1a. A real "Create transfer" operator action (FE + canonical writer)

One affordance (operator/driver): pick SOURCE machine + shelf, DEST machine + shelf, product(s) + qty, then confirm. It calls the canonical M2M writer (`swap_between_machines`, or a thin `create_m2m_transfer` wrapper if a different entry shape is needed) which writes the paired `Remove`(source) + `Add New`(dest), both `is_m2m=true`, shared `m2m_transfer_id`, `from_warehouse_id=NULL`, bidirectionally linked. No `[TRUCK-TRANSFER]` free text, no warehouse debit/credit. This becomes the ONLY way to create a transfer.

### 1b. Promote the warn-only guard to a hard convert/block (backend)

Upgrade `flag_remove_with_transfer_intent`: a `Remove` carrying `[TRUCK-TRANSFER]` (or a `truck_transfer`/transfer intent) with `is_m2m=false` and no partner must NOT be allowed to settle as a warehouse drain. Either (preferred) auto-convert it via `convert_removes_to_m2m_transfer` to a proper M2M leg at write/approve time, or hard-block with a clear error pointing to the Create-transfer action. Keep the monitoring_alert for observability.

### 1c. Receive guard: a transfer-tagged Refill must not debit Central (backend)

Mirror the PRD-054 venue_team pattern in the receive path: a `Refill`/`Add New` whose source is a transfer-in (is_m2m, OR comment `[TRUCK-TRANSFER from ...]`, OR `from_machine_id` set) must be received WITHOUT a warehouse_inventory debit (provenance `transfer_in_no_wh_debit`). So even a legacy-style tagged refill stops double-charging Central.

## 2. Testing rules (mutating tests in BEGIN..ROLLBACK first)

| #   | Test                                                       | Expected                                                                                                                  |
| --- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| T1  | Create-transfer action MC->AMZ for product X qty N         | one paired is_m2m Remove(MC)+Add New(AMZ), shared transfer_id, from_warehouse_id NULL, linked; no `[TRUCK-TRANSFER]` text |
| T2  | conservation                                               | source Remove qty == dest Add New qty; no orphan dest leg possible (dest derived from source)                             |
| T3  | legacy plain Remove with `[TRUCK-TRANSFER]` + is_m2m=false | auto-converted to M2M (or hard-blocked); never settles as a WH credit                                                     |
| T4  | receive a transfer-tagged Refill                           | NO warehouse_inventory debit; provenance `transfer_in_no_wh_debit`; audited                                               |
| T5  | receive an is_m2m source Remove                            | `receive_dispatch_line` M2M-skip (no Central credit) - regression of PRD-052 behaviour                                    |
| T6  | normal (non-transfer) Remove / Refill                      | unchanged: Remove credits WH, Refill debits WH                                                                            |
| T7  | engines untouched                                          | engine_add_pod + engine_swap_pod md5 unchanged; swaps_enabled stays false                                                 |
| T8  | a11y/375px on the Create-transfer screen                   | no h-scroll, targets >=44px, axe clean                                                                                    |

## 3. Phasing / gates

- P1 Dara design (any wrapper RPC + the guard predicates) + Cody review (Articles 1/4/6/8/12).
- P2 Backend: 1b convert/block guard + 1c receive guard. Forward migrations; tests T3-T7 in rolled-back tx; apply.
- P3 Stax FE: the Create-transfer action (1a), browser-verified at 375px; remove/disable any path that lets an operator type a `[TRUCK-TRANSFER]` plain Remove.
- P4 Backfill watch: a monitor that flags any new `is_m2m=false` `[TRUCK-TRANSFER]` line that slips through, until 1b is proven to catch all paths.
- No git push to main without explicit CS go-ahead. engines byte-identical; swaps_enabled untouched.

## 4. Relationship to prior work

- PRD-052 = retro-convert dispatched plain Removes (the remediation RPC `convert_removes_to_m2m_transfer`). Reused by 1b.
- PRD-056 = the packing-side confirm ("Packed & Transferred") for a move already flagged is_m2m.
- PRD-060 (this) = the CREATION side, so moves are flagged is_m2m from birth and never need retro-conversion. Closes the loop the team keeps hitting.
