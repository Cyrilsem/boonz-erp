# PRD-028: Dispatch Line State Integrity (Skipped Lines Must Be Inert)

**Date:** 2026-06-12
**Status:** Shipped 2026-06-12 (prod + main; EXECUTED (steps 1-3 applied + deployed; battery 1-6 green; one-week monitor open). Execution notes: 2b corrected in flight - eod_auto_release_unpicked pass 1 DOES route through return_dispatch_line (packed=true picked_up=false only), so the return refusal is conditional on nothing-physical (packed=false AND picked_up=false); flagged-but-packed lines stay returnable (Incident-A recovery + sweep contract). New canonical writer `unskip_dispatch_line` added (set_dispatch_include cannot clear skipped). Migrations `phaseF_dispatch_state_guards` (20260612135850) + `phaseF_unskip_dispatch_line` (20260612141205). Commits 290eba1 / 572c361 / 66db25c on main.
**Severity:** ⛔ High. Twice in one day, lines that CS explicitly cancelled were physically actioned or financially booked because nothing downstream respects the skip. Corrupts WH stock silently.
**Owners:** assistant (RPC guards, Cody review) + Stax (driver app + packing FE)

---

## 1. Incidents (both 2026-06-12, both verified in audit logs)

**Incident A, OMDBB packing.** The A07 swap lines were skipped on 06-11 22:47 with reason "CS: cancel OMDBB A07 Plaay swap". The packing FE still displayed them as packable; the WH manager packed 2 of the 4 (Nescafe Add 4u + Plaay Remove 2u) on the morning of 06-12. Recovered via set_dispatch_include(false) + EOD sweep release + physical unpack.

**Incident B, VOXMM "Dispatch Complete" auto-return.** At 13:31, when the driver tapped Dispatch Complete, the app's completion flow fired return_dispatch_line on every un-actioned line of the visit, INCLUDING the 5 skipped lines of the cancelled A03 swap (Popit Cola Add 4 + Tamreem Removes 1/3/3/4). The driver never pressed return. The 4 Tamreem REMOVE returns credited 11 phantom units to WH (+1 Coconut and +3 Sesame at WH_MM, +3 Coconut and +4 Sesame at WH_CENTRAL, batch rows 7a08e44a / c4cce96c / 9d20bf50 / 53fef64f). Audit trail shows `return_dispatch_line ... by: system` ×5 in the 13:31 burst alongside receive_dispatch_line ×7. Recovered same day via apply_inventory_correction ×4 + flag correction (rpc_name manual_cs_correction_unreturn).

**Root cause, common:** `skipped`, `cancelled` and `include=false` are display-level flags. No canonical writer enforces them:

- `pack_dispatch_line`: no check on skipped / cancelled / include (verified: function body contains none of the three words).
- `return_dispatch_line`: same, and it is callable by the app's completion flow without per-line driver confirmation.
- The driver app's Dispatch Complete handler sweeps ALL lines of the visit instead of only lines the driver actually actioned.

## 2. Fix, layer 1: backend guards (canonical writers, Cody mandatory)

**2a. pack_dispatch_line vN+1:** refuse with explicit errors when the target row has `skipped = true`, `cancelled = true`, or `include = false`. Error text must name the flag and the skip_reason so the packer sees WHY ("line was skipped: CS: cancel OMDBB A07 Plaay swap"). No override parameter; un-skipping must be an explicit separate FE action that logs who did it.

**2b. return_dispatch_line vN+1:** same three-flag refusal. Additionally require an actor: reject calls where the effective actor is the system sweep AND the line was never packed or picked up (`packed = false AND picked_up = false`), because there is nothing physical to return. EOD/stale-release flows do not use return_dispatch_line, so they are unaffected (verify in battery).

**2c. Migration:** `phaseF_dispatch_state_guards`, forward-only, both functions in one migration, registries + CHANGELOG. Capture both current functiondefs for rollback.

## 3. Fix, layer 2: driver app + packing FE (Stax)

**3a. Driver app, visit view:** lines with skipped/cancelled/include=false are not rendered at all (not greyed, absent). The summary's shelf totals must exclude them.

**3b. Dispatch Complete handler:** only finalize lines the driver explicitly actioned (confirmed qty entered or per-line done tap). Never auto-return un-actioned lines; un-actioned lines fall to the EOD sweep, which is the designed safety net. A return requires an explicit per-line "Return" tap with a confirm dialog showing qty + destination warehouse.

**3c. Packing FE:** hide or hard-disable skipped/cancelled/excluded lines (consistent with 3a); the 2a guard is the backstop if the FE misses.

## 4. Verification battery

1. pack_dispatch_line on a skipped line → exception naming the skip reason; row unchanged.
2. return_dispatch_line on a skipped, never-packed line → exception; no WH write, no audit row.
3. Legit flow regression: pack → pickup → genuine driver return still works end to end with WH credit.
4. EOD sweep (eod_auto_release_unpicked) and release_stale_unpacked_dispatches still run clean (they bypass return_dispatch_line; assert no call path hits the new guards).
5. Driver app: complete a visit with 1 actioned + 1 skipped + 1 untouched line → only the actioned line finalizes; untouched line released by EOD sweep; skipped line invisible throughout.
6. Replay Incident B inputs against the patched stack → zero WH writes.

## 5. Acceptance criteria

- [x] Guards live (phaseF_dispatch_state_guards), Cody sign-off, registries updated. (2026-06-12)
- [x] Driver app no longer renders or auto-returns skipped lines; explicit-tap returns only. (bulk All-returned removed; per-line confirm with qty + destination WH; Save no longer forces all lines actioned)
- [x] Packing FE cannot pack skipped/cancelled/excluded lines. (fetch filters + un-skip via new logged unskip_dispatch_line)
- [x] Battery 1-6 green. (1-4 and 5-6 in rolled-back txs: refusals name the flag + skip_reason; legit pack->pickup->return 192->190->192; eod sweep failed=0; driver predicate hides 25/25 flagged lines; incident-B replay 5/5 refused, zero WH writes)
- [ ] One week with zero phantom return credits (check inventory_audit_log for return_dispatch_line rows whose dispatch was never packed). Monitor opens 2026-06-12, closes ~2026-06-19.
