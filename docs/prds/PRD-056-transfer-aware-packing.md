# PRD-056: Transfer-aware packing (machine-to-machine confirm, dest auto-tag, transferred-add expiry, not-filled linkage)

Owner: CS · Date: 2026-06-23
Surface: Backend (a transfer-confirm writer + a new `pack_outcome` value; reuse of the M2M pairing) and FE (packing/dispatching transfer rows render a single "Packed & Transferred" action; dest leg shows "Transfer from <source>"; transferred adds expose per-expiry split). Touches `refill_dispatching`, `pod_inventory`. Cody review per writer. Forward-only. No em dashes.
Governance: Dara designs any column/CHECK, Cody reviews each writer (name articles), Stax wires FE. `engine_add_pod` + `engine_swap_pod` md5 byte-identical (untouched). `refill_settings.swaps_enabled` stays false.

## Origin (team report "Stock Transfer Workflow & System Glitches", Issues #1/#2/#3)

When a refill REMOVE is converted to a machine-to-machine (M2M) transfer (`convert_removes_to_m2m_transfer`, PRD-052), the dispatch carries two legs: the SOURCE leg (is_m2m, the unit leaves machine A) and the DEST leg (the unit arrives at machine B). Today the packing UI still offers Skip / Not Filled on these legs and provides no one-tap path that lands the transferred unit in the destination machine's `pod_inventory`. Drivers resort to manual notes; the dest leg is not auto-labelled; transferred adds cannot record their expiry; and a Not-Filled refill row that is actually being covered by a transfer is not linked.

## Reuse (do NOT duplicate)

- `convert_removes_to_m2m_transfer` - creates the M2M pairing (source + dest legs, `is_m2m`, `m2m_partner_id`, `m2m_transfer_id`, `from_machine_id`).
- `swap_shelf_pod` - pod-level shelf substitution (do not re-implement slot moves).
- `receive_dispatch_line` (with its M2M-skip branch) - the canonical WH/pod_inventory write; the transfer-confirm writer routes the dest-leg pod_inventory write through the same per-expiry `p_batch_breakdown` path used by PRD-053 Phase B, never a bespoke insert.

## Phase 1. New pack outcome `packed_transferred` (backend, Dara + Cody)

- Forward-only add of `packed_transferred` to the allowed `refill_dispatching.pack_outcome` values. If `pack_outcome` is currently unconstrained (no CHECK), add the canonical CHECK including the existing values plus `packed_transferred` (additive, never removing a value; Article 12 forward-only).
- A transfer leg (`is_m2m = true` OR comment tagged `Transfer from <machine>`) is a transfer row.

## Phase 2. Transfer-confirm writer (backend DEFINER, Cody mandatory)

`confirm_packed_transferred(p_dispatch_id uuid, p_confirmed_by uuid, p_batch_breakdown jsonb DEFAULT NULL)`:

- DEFINER; sets `app.via_rpc` + `app.rpc_name`; hits `write_audit_log`; validates caller role; NEVER touches `warehouse_inventory.status` (Article 6).
- Refuses unless the row is a transfer leg. For a transfer leg the ONLY legal outcome is `packed_transferred` (the writer rejects Skip / Not Filled paths for these rows; the FE simply does not render them).
- On confirm: set `packed = true`, `pack_outcome = 'packed_transferred'`, stamp driver/time; and write the unit into the DEST machine's `pod_inventory` via the M2M pairing - by delegating to `receive_dispatch_line`'s M2M-skip-aware path with the dest leg, reusing PRD-053-B `p_batch_breakdown` so per-expiry splits land each batch in `pod_inventory` with its own date. No manual notes; the audit chain is the RPC + `write_audit_log`.
- Idempotent: a second confirm on the same leg is a no-op (already `packed_transferred`).

## Phase 3. Dest auto-tag (FE, Stax)

- The M2M dest leg renders `Transfer from <source official_name>` in refill/packing (derive from `from_machine_id` / `m2m_partner_id`), with a single one-tap **Packed & Transferred** confirm. No Skip / Not Filled buttons on transfer rows. 375px: no horizontal scroll, tap target >= 44px, axe clean.

## Phase 4. Expiry on transferred adds (FE + reuse of Phase B writer)

- Adding a transferred product in dispatching exposes an expiry field and per-expiry split rows (reuse PRD-053 Phase B `p_batch_breakdown`: SUM(rows) = line total, total locked). On approval each batch writes a `pod_inventory` row with its date (through the same `receive_dispatch_line` path).

## Phase 5. Not-Filled -> transfer link (backend + FE)

- When a Not Filled refill row is matched by a transfer added in dispatching (same machine + pod, covering the shortfall), link them: the transfer overrides the Not Filled state, and the audit chain records refill -> transfer -> dispatch -> pod (via `m2m_transfer_id` / linkage columns + `write_audit_log`). The Not Filled row is no longer counted as a shortfall once linked.

## Edge set that MUST pass (BEGIN..ROLLBACK then apply)

1. A transfer row offers ONLY Packed & Transferred (writer rejects Skip/Not-Filled on `is_m2m`).
2. Dest shows "Transfer from <source>" + one-tap confirm lands the unit in the dest machine's `pod_inventory`.
3. A multi-expiry transferred add splits; each batch lands in `pod_inventory` with its own date.
4. A Not-Filled + transfer pair links with the full audit chain.
5. `engine_add_pod` + `engine_swap_pod` md5 unchanged; `swaps_enabled` stays false.

## Out of scope

The transfer ROUTING decision (which machine receives) - that is the picker/engine, unchanged here. PRD-056 only makes the PACKING of an already-decided transfer correct, labelled, expiry-aware, and audit-linked.
