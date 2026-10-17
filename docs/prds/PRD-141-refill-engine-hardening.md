# PRD-141: refill engine hardening

## Note on provenance of this file

The orchestrating instruction for this loop ("PRD-141 ONE LOOP") asked
for this file to be saved "verbatim" from an external document at
"the Boonz project doc claude/PRD-141-refill-engine-hardening.md," with
the full item-by-item spec appended to that instruction. No such spec
text was actually included in the instruction, and the external document
could not be located by this session: not in this repo, not anywhere on
the local filesystem, and not in the connected Google Drive (confirmed
by a working search that returns real results for other queries). This
session has no tool that can read a claude.ai Project's attached
knowledge files by path.

What follows is therefore NOT the authoritative PRD-141 spec. It is the
condensed outline actually given in the orchestrating instruction,
preserved here so the structure (phase numbers, item ranges, named
problems) is on record, plus the one item this session investigated and
could evaluate independently from first principles. Full detail,
rationale, acceptance criteria, and exact RPC and column designs for
every other item are not available to this session and are not invented
here. See `docs/prds/PRD-141-log.md` for the investigation record and
`docs/prds/PRD-141-REPORT.md` for per-item status.

## Context given in the orchestrating instruction

PRD-139/139b/139c shipped the security items (0 anon-executable definer
functions, route gate, photos bucket, v_po_header, backlog auto-expire).
PRD-140 shipped nothing but the logout hotfixes; two loops took the lock
and stalled. PRD-138 shipped nothing; VOXDFC-1001 and VOXDFC-2006 are
still invisible to P1. The field problems referenced here were harvested
from two weeks of the operations WhatsApp. The one CS repeats most: the
app offers a Swap, the swap never logs the outgoing product as a return,
so the warehouse manager cannot validate it when it comes back.

## Phase and item structure named in the orchestrating instruction

- Phase 1, swap and return integrity: items 0 to 5. Item 0 is the swap/
  return problem named above.
- Phase 2, pack screen stock truth: items 6 to 9.
- Phase 3, mapping adherence: items 10 to 12 (named as night-window only,
  Block D).
- Phase 4, P1 picker: items 13 to 16 (named as night-window only, Block
  D).
- Phase 5, delivery truth: items 17 to 20.
- Phase 6, WEIMI and setup: items 21 to 23.
- Phase 7, operator tooling: items 24 to 27.
- Section 3 of the real spec is described as containing the acceptance
  gates for all of the above; not available to this session.

PRD-139 leftovers the orchestrating instruction said are folded into
this numbering: item 9 (immediate pack write verified on a real phone
flow) maps to PRD-141 item 8; item 7 (per-line save errors verified) maps
to item 20; item 5 (undelivered bags) maps to item 17.

## Item 0 investigation (the only item this session could evaluate)

See `docs/prds/PRD-141-log.md`, section "Deep investigation: the swap/
return complaint," for the full trace. Summary: `swap_shelf_pod` (the
only real Swap entry point, used at Packing time before the driver
leaves) creates a paired `Remove` + `Add New` dispatch line. The `Remove`
leg is mechanically capable of reaching the Warehouse Confirmations queue
through the exact same path as any manually planned Remove line, once
the driver taps "added" (removed) on it at the Dispatch Detail screen and
it has `driver_confirmed_qty > 0`, `picked_up = true`, `wh_approved_at IS
NULL`, and the other standard `v_wm_confirmations` conditions. No
code-level filter was found that excludes a swap-originated Remove line
specifically. This means the real defect, if the complaint is accurate
today, is more likely a UX or process gap (a driver not completing the
Remove leg at Dispatch Detail, or confusing the Packing-stage "Confirm
removed" tick with the real physical confirmation a stage later) than a
missing backend write path, but this session did not implement a change
here: the live, actively-used state of this exact code path during
business hours, combined with no authoritative spec confirming which fix
is intended, made a speculative change to `swap_shelf_pod`,
`pack_dispatch_line`, `driver_confirm_remove`, or `v_wm_confirmations`
too risky to ship blind. See the report for this item's final status.

## What is needed to complete this PRD properly

The actual PRD-141 spec document (all 27+ items, their exact acceptance
criteria, and the RPC/schema designs intended for each), and the actual
PRD-138 document (WS-A's exact migration list, WS-B and WS-C's exact
text), need to be placed in this repo (or pasted directly into a future
loop's instruction, as was done for PRD-140) before Blocks B beyond item
0, C, and D of this loop can be executed with confidence rather than
guesswork.
