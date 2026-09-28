# Night report, 2026-09-28

One loop, tonight. Branch loop/selection-v2-2026-09-25. All times Dubai. Full detail for every
item below is in docs/loops/2026-09-25-selection-v2/STATE.md; this file is the plain-English
summary CS asked for.

## Daytime tasks (D1-D4)

- **D1 backfill two prod-only migrations**: DONE. Two fixes that were applied directly to prod
  earlier (an M2M-plan warehouse-need check, and a mixed-flavour split predicate) are now recorded
  as migration files in the repo, byte-verified against what is actually live.
- **D2 prd131-packing-screen check**: DONE. That branch is pushed but not merged. Deploying its
  FE right now would break the packing screen, because it expects a database column that has not
  been applied yet. Left alone, flagged for CS below.
- **D3 "9 picks for cap 8" report**: INVESTIGATED, no fix. Could not reproduce it against a fresh
  run of the picker (it correctly returns 8). No root cause found. Left as an open item.
- **D4 venue binding guard, drafted**: became W4 below (applied in the window since half of it
  touches a dispatch function).

## Window tasks (W1-W6), all done or resolved without a fix

- **W1 (R1)**: fixed a bug where, if a driver needed to split a delivery into a new flavour but
  the system only ever looked at the single most-recently-added line on that shelf, it could
  refuse a split that was actually fine (it was only looking at 2 units out of 9 really
  available). Now it adds up every real candidate line first. Applied and tested.
- **W2 (R3)**: fixed a bug where removing/returning stock from a machine could get bound to the
  wrong flavour's batch record (whichever expired soonest on the shelf, not the actual product
  being removed) - this affects expiry tracking and warehouse credit accuracy, not physical
  stock counts. Applied and tested.
- **W3 (R5a)**: the driver-side "confirm what I removed" step now requires the driver to type in
  the batch/expiry breakdown when the system's own recorded expiry is missing or about to expire
  within a week - closes a gap where a stale or absent expiry was silently trusted. Applied and
  tested.
- **W3 (R5c)**: proved (no fix needed) that when a warehouse manager splits a driver's mixed-flavour
  return into its real flavours, the warehouse credit correctly lands on the matching batch, or
  creates a new one if none exists.
- **W4 (venue binding guard)**: added a nightly check that flags any machine whose venue-supplied
  product has zero backing stock at its assigned warehouse (this is exactly the condition that
  caused today's earlier manual fix for 3 machines). Also added a quiet, informational note on
  every push for a venue-supplied line, since those lines are never warehouse-pinned by design.
  Currently finds 57 such gaps, mostly on the LevelUp machines and the newly onboarded Dubai
  Festival City VOX machine.
- **W5 (packing screen venue lines)**: found and fixed the actual bug behind "packing not
  showing to the team." A venue-supplied line's planned quantity was silently defaulting to zero
  at save time because the screen only ever looked for real warehouse stock batches, and a venue
  line has none by design. It now shows "Venue - take at site" and defaults to the full planned
  quantity, which the packer can still adjust. The backend already had the right machinery to
  receive this correctly; only the screen needed fixing. Committed to this branch, not deployed.
- **W6 (R7)**: fixed a bug where moving stock between two shelves on the same machine always
  failed outright, because it tried to write a required field as blank. Applied and tested.

## What CS needs to deploy or decide

1. **Deploy decision - FE changes on this branch, not yet live**: two FE-only fixes are sitting
   on loop/selection-v2-2026-09-25 waiting on you: the packing-screen merge-key fix from earlier
   in this loop (R6), and tonight's venue-line fix (W5). Both are safe to ship together whenever
   you're ready; neither has been deployed.
2. **Do not deploy prd131-packing-screen as-is** - it will break the packing screen today. Either
   finish its remaining database migrations and merge, or roll it back. Your call.
3. **Merge loop/selection-v2-2026-09-25 to main**: every database fix on this branch tonight (and
   on prior nights) has already been applied directly to production. Merging this branch is
   mainly about keeping the repo's migration files in sync with what's actually live, plus
   shipping the two pending FE fixes above. No rush from a database standpoint; your call on
   timing.
4. **The "9 picks for cap 8" report (D3)**: unresolved, no root cause found. If it happens again,
   grab the exact plan/date before the next automated run overwrites the evidence - that's what's
   needed to actually diagnose it.
5. **Not started, per your own instruction**: the Remove-flavour derivation fix (R2), the matching
   readable-error fix (R4), and the picker's common-horizon change (F10). All three are ready to
   pick up whenever you ask.

Everything above that needed a database change is live in production. Committing this report and
stopping now.
