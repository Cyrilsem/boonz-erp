# PRD-086 — Dispatch board completion counter counts `not_filled` lines as incomplete

**Date:** 2026-07-07
**Status:** DRAFT → ready to ship (FE-only, no DB/migration)
**Owner:** Stax (FE) · reviewed against field report 07/07
**Scope:** `src/app/(app)/refill/DailyDispatchingTab.tsx` only. No backend, no migration, no data change.

---

## Problem

On the **Refill Dispatch** board, the top counters read **PACKED 0/7, PICKED UP 0/7, DISPATCHED 0/7**
even though the drivers packed, picked up, and dispatched every machine. Per-machine bars sit at
54–94% and never reach 100%; a machine's own detail view says "Dispatch Complete" while the board
counts it incomplete.

This is a **false negative** — the data is correct, the counter is wrong.

## Evidence (live, dispatch_date 2026-07-07)

Every machine is fully processed — every line reached a terminal state — yet none is counted:

| Machine    | Include lines | Dispatched | Not-filled | Returned | Resolved | Board says |
| ---------- | ------------- | ---------- | ---------- | -------- | -------- | ---------- |
| AMZ-1029   | 21            | 17         | 4          | 0        | 21/21    | incomplete |
| AMZ-1038   | 30            | 24         | 6          | 0        | 30/30    | incomplete |
| AMZ-1057   | 14            | 12         | 2          | 0        | 14/14    | incomplete |
| AMZ-1068   | 30            | 27         | 3          | 4        | 30/30    | incomplete |
| MC-2004    | 24            | 19         | 5          | 1        | 24/24    | incomplete |
| OMDBB-1020 | 17            | 16         | 1          | 0        | 17/17    | incomplete |
| VOXMM-1013 | 13            | 7          | 6          | 1        | 13/13    | incomplete |

For every machine `packed = picked_up = dispatched` on the fillable lines (the work went all the way
through) and `dispatched + not_filled + returned = include_total`. The only lines not `dispatched=true`
are `not_filled` (no stock — nothing to dispatch) and `returned`.

## Root cause (exact)

In `DailyDispatchingTab.tsx`:

- **Query (~line 176)** selects only `packed, picked_up, dispatched` — it never fetches `pack_outcome`,
  `returned`, or `skipped`, so the FE cannot distinguish a `not_filled`/`returned` line from a pending one.
- **Per-machine rollup (~lines 245–256)**:
  ```ts
  const packedMachines = machines.filter((m) => m.packed_count === m.total);
  const dispatchedMachines = machines.filter(
    (m) => m.dispatched_count === m.total,
  );
  ```
  `m.total` includes `not_filled`/`returned` lines, which can never have `packed`/`dispatched = true`.
  So `*_count === total` is unreachable for any machine that has even one not-filled line → **0/7**.
- **`deriveStage` (~lines 147–150)** and the **progress bar (~lines 567–579)** use the same `m.total`
  denominator, so the bar never reaches 100% and the machine never shows "Complete".

## Fix (FE only)

A line is **terminal-non-fillable** when it will never be dispatched by design:
`pack_outcome === 'not_filled' || returned === true || skipped === true`.
The denominator for "is this machine done" must be the **fillable** lines only.

1. **Fetch the missing fields.** In the `.select(...)` string (~line 176) add
   `pack_outcome, returned, skipped` to the `refill_dispatching` column list. Extend the row type
   (interfaces at ~lines 17–19 and ~74–76) with `pack_outcome: string | null; returned: boolean;
skipped: boolean;`.

2. **Track fillable total per machine.** During aggregation (~lines 96–118 and ~216–232) compute, per
   line, `const nonFillable = l.pack_outcome === 'not_filled' || !!l.returned || !!l.skipped;` and
   accumulate `fillable_total += nonFillable ? 0 : 1;` (also keep `not_filled_count` for display). Keep
   `total`, `packed_count`, `picked_up_count`, `dispatched_count` as-is (actual counts of the fillable work).

3. **Complete on fillable, not total.** Replace `m.total` with `m.fillable_total` in:
   - `deriveStage` (~147–150),
   - `packedMachines` / `pickedUpMachines` / `dispatchedMachines` (~245–256),
   - the progress-bar denominator (`... / (m.fillable_total * 3)`, ~567–579) and `allDone`
     (`m.dispatched_count === m.fillable_total`, ~579).
     Guard the empty case: a machine with `fillable_total === 0` (everything not-filled) counts as complete.

4. **Display.** Change the per-machine chips (~727–733) to read against fillable total, e.g.
   `P {m.packed_count}/{m.fillable_total}` … and, when `not_filled_count > 0`, show a muted
   `· {not_filled_count} not filled` so the operator still sees why the denominator shrank. Do **not**
   flip `not_filled` rows to a green "packed" tick — they were genuinely not filled.

## Acceptance criteria

- With today's data (07/07), the board reads **PACKED 7/7, PICKED UP 7/7, DISPATCHED 7/7**; every
  machine card shows **Complete**; each bar is 100%.
- A machine that is genuinely mid-pack (a fillable line still `packed=false`, not not-filled) still shows
  incomplete.
- No change to any write path, RPC, migration, or the `mark all dispatched → materialize inventory`
  behaviour (line ~304). `not_filled` lines are never silently converted to packed/dispatched.

## Non-goals / follow-up

- This does **not** fix the upstream cause of so many `not_filled` lines — that is the
  "no stock available" packing glitch (see `refill-engine-fe-bugs_2026-07.md`, bugs #2/#4/#8). Fixing that
  reduces how often the denominator shrinks in the first place.

## Rollback

Single-file FE change. Revert the commit and redeploy. No data or schema to undo.
