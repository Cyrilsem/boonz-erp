---

Status: Closed 2026-07-03 (PRD-072 sweep). Reason: superseded by PRD-044 confirm/skip/partial + PRD-047/049 packing line. Reopen by deleting this line.
id: PRD-020-refill-pipeline
program: PROGRAM-2026-06-16
title: Complete but Partial packing — let a packer skip an unfulfillable line and still finish the task
status: Proposed
severity: P2
reported: 2026-06-16
source: 2026-06-16 packing screen, NOVO-1023. Pepsi Black (A03 Refill x3) had no warehouse stock to pack. The machine sat at P 11/12 with no way to resolve the last line, so the task could not be marked complete. The operator wants a task to be completable as "Complete but Partial" when a line is legitimately skipped.
routing:
  [
    Stax (FE: per-line Skip action + reason,
    partial progress math,
    Complete-but-Partial banner),
    Dara (none expected; dispatch_pack_confirmation.summary already carries the partial shape),
    Cody (none expected; skip_dispatch_line is the existing canonical writer,
    no new protected writer),
  ]
---

## TL;DR

A packing task today is implicitly all-or-nothing in the UI: every fillable line must be packed before the machine can be confirmed. When a line cannot be fulfilled (no warehouse stock, expired, damaged) the packer has no in-screen way to resolve it, so the machine stalls at "11 of 12" and the task never completes.

The backend already solves this. `confirm_machine_packed` only blocks on lines that are included, non-cancelled, fillable, and neither packed nor skipped nor marked not_filled. `skip_dispatch_line(dispatch_id, reason)` already sets `skipped=true, include=false`, which removes the line from the mandatory set, and the confirmation summary already counts `packed / partial / not_filled / skipped` separately. So a machine can be confirmed complete with a skipped line today, and the partial shape is already recorded.

The only missing piece is the FE: expose a per-line **Skip** action with a reason, count skipped lines as resolved in the progress bar, and let the task finish as **Complete but Partial** with a banner that names what was skipped. This is a front-end PRD with no new RPC and no schema change.

---

## What happens now (2026-06-16, NOVO-1023)

- Pepsi Black, A03, Refill x3, Filled 0/3, not packed. No warehouse stock to pack it.
- Header shows P 11/12, U 11/12, D 11/12, 92 percent. "Mark All Packed" cannot resolve the 12th line because it is genuinely unfulfillable.
- The packer has no per-line control to say "this one cannot be filled, move on." The task is stuck.

If the FE called `confirm_machine_packed` right now it would return `status: blocked` with `unresolved_count: 1` (Pepsi Black), because that line is included, unpacked, and not skipped. The fix is to let the packer skip it first.

---

## Root cause

- **R-1.** The packing screen has no per-line **Skip** (or mark **not filled**) control. `skip_dispatch_line` exists and is role-open to `field_staff` and up, but nothing in the FE calls it.
- **R-2.** The progress math (P x/y) counts only packed lines against the total, so a skipped or unfulfillable line keeps the machine below 100 percent forever. Resolved should equal packed plus skipped plus not_filled.
- **R-3.** There is no **Complete but Partial** terminal state surfaced to the packer. The completion summary distinguishes packed from skipped, but the UI presents completion as binary, so a partial finish either looks like a failure or is impossible to reach.

---

## Acceptance criteria

- **AC-1.** Each packing line has a **Skip** action. Skipping requires a short reason (a small pick list plus free text: out of stock, expired, damaged, wrong product, other). On confirm it calls `skip_dispatch_line(dispatch_id, reason)`. Reason must be >= 10 chars to satisfy the RPC.
- **AC-2.** A skipped line renders distinctly (muted or struck through, with the reason inline) and moves out of the outstanding-to-pack group. The action is reversible via `unskip_dispatch_line` while the line is not yet picked up.
- **AC-3.** Progress is computed as `resolved = packed + skipped + not_filled` over included, non-cancelled, fillable lines. When `resolved = total`, the machine is completable. NOVO with Pepsi Black skipped reads 12 of 12 resolved (11 packed, 1 skipped).
- **AC-4.** "Mark All Packed" / complete calls `confirm_machine_packed` only after every line is resolved (packed or skipped or not_filled). It must never error with `blocked` from the UI happy path, because the UI gates the button on `resolved = total`.
- **AC-5.** The completion banner reflects the returned summary: **Complete** when nothing was skipped, **Complete but Partial** when `skipped > 0` or `not_filled > 0`, showing the count and the skipped product names/reasons. The machine card in any roll-up shows the same partial badge, not a red/incomplete state.
- **AC-6.** Skipped lines are excluded from the driver's pickup/dispatch view for the day (they already are, since `include=false`), so a skip at packing does not surface a phantom line downstream.

## Out of scope

- Auto-reordering or procurement of the skipped product. The skip reason feeds the existing procurement signal; turning a skip into a PO is separate.
- Changing `confirm_machine_packed` or `skip_dispatch_line` logic. They already do the right thing; this PRD only wires the FE to them and fixes the progress math and the completion label.

## Effort

Front-end only (Stax). No migration, no new RPC, no Cody gate. The two RPCs (`skip_dispatch_line`, `unskip_dispatch_line`, `confirm_machine_packed`) are live and canonical.
