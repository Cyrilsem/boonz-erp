# PRD-049: Packing + Returns FE stabilization

Status: Shipped 2026-06-22 (packing/returns FE A/B/D + edit_transfer_qty RPC, main d25c84b; all 6 issues closed). Doc restored by WS-E salvage.

Owner: CS
Date: 2026-06-22
Surface: FE only (the field packing screen + the inventory returns-approval panel). No new backend: every RPC needed already exists and behaves correctly (verified live 2026-06-22). Cody review ONLY if any RPC body is touched.
Governance: Stax owns the FE. Forward-only. No em dashes. Deploy to a Vercel preview, QA on a phone, then promote. Confirm each phase against the reported symptom before moving on.

## Objective

Fix six field-reported defects in the live refill packing flow and the returns approval, all of which are FE-layer. The backend is sound: `edit_dispatch_qty` persists qty, `skip_dispatch_line` records the skip, the two-mode `confirm_machine_packed(p_final)` gate already counts not_filled AND skipped as resolved, and `receive_dispatch_line` already accepts a per-expiry `p_batch_breakdown`. The problem is the deployed UI losing edited values, mis-gating the Finish button, and not exposing per-variant / per-expiry controls.

## Why (verified live 2026-06-22)

Today's refill (HUAWEI, ALJLT x2, MC-2004, NOOK) shows heavy line fragmentation (HUAWEI = 96 refill lines) and heavy skipping (HUAWEI 60/96, ALJLT-0200 31/50; not_filled = 0), which makes the "every line must be resolved" friction and the qty/skip defects bite on every visit. PRD-044/045 packing fixes are on main and shipped; PRD-047 swap dialog deploy was pending a Vercel rate-limit. These are remaining FE defects, not missing backend.

## Phases (each independently shippable; do A first, it hits every refill)

### Phase A. Packing qty persistence + skip + not_filled gate (issues 1, 2, 3)

- Issue 1 (qty reverts): the packing screen's `packed_qty` is local state that gets overwritten back to `recommended_qty` on merge/refetch (page ~L1220). Persist the edited pick qty (drive the `pack_dispatch_line` picks from the edited value) and do not clobber it on refetch.
- Issue 2 (skip fails -> forced to not_filled): `skip_dispatch_line` requires reason >= 10 chars. The skip dialog composes `skipCategory + skipNote`; a short reason throws and the skip silently fails. Enforce/auto-pad the composed reason to >= 10 chars, and surface the RPC error instead of swallowing it.
- Issue 3 (not_filled on last line disables Finish for earlier items): the backend gate does NOT block on not_filled/skipped. The FE `allResolved` / button-disable state is the bug (marking the last line flips the Finish button off for already-resolved lines). Make the Finish/Save enablement mirror the backend gate exactly: enabled when every included line is packed OR skipped OR not_filled; never disabled by a resolved line. Keep PRD-044 Save and come back available throughout.

Verify: re-pack a real machine from today (e.g. HUAWEI); edit a qty and confirm it persists; skip with a short reason and confirm it processes; mark the last line not_filled and confirm Finish stays enabled for the rest.

### Phase B. Swap per-variant qty + skip + persistence (issue 4)

- For multi-flavor swaps, add per-variant qty edit and a per-variant skip / set-0 (so a flavor not being swapped does not move to pod inventory). Fix the `variantQtys` reset-to-0-after-confirm (same persistence class as issue 1). Confirm the PRD-047 one-tap swap actually deployed (it was rate-limited).

Verify: a multi-flavor swap where one flavor is set to 0 and another edited, both persist after confirm; the 0 flavor does not appear in pod inventory.

### Phase C. Transfer-between-machines with edit (issue 5)

- The M2M transfer path errors when the user edits qty, picks a destination machine, and applies. Trace the edit -> destination -> apply flow (mark_internal_transfer / swap_between_machines / set_dispatch_source), fix the wiring so an edited transfer completes without error. No backend change unless a real RPC bug is found (then Cody).

Verify: create a transfer, edit its qty, select the destination, apply; it completes and both legs (Remove at source, Add New at dest) are correct.

### Phase D. Returns expiry-split (issue 6, Inventory)

- The returns panel only offers Split by variant (multi-flavor). Add a Split by expiry control for a single product returned across multiple expiry dates: the operator adds one row per expiry (qty + expiry), and the panel builds a per-expiry `p_batch_breakdown` and calls the existing receive path (`receive_dispatch_line` / `wh_approve_remove_receipt`). Each batch must be credited to its own WH expiry row. Works inside the existing approval model.

Verify: approve a return like Huawei Ice Tea Peach 7 pcs across 2-3 expiries; each expiry batch is credited separately in `warehouse_inventory`.

## Out of scope

Backend RPC changes (none needed), the engine/stitch silent-0-fill (PRD-035 WS-C), and the field-time batch capture for new purchases (PRD-036 Phase B).

## Notes

Confirm whether PRD-047 B3 actually reached prod (the deploy was rate-limited) before assuming issue 4 is purely new FE work. Phase A is the priority: it affects every refill and is the source of the driver workarounds.
