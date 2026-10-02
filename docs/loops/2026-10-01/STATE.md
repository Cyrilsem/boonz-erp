# LOOP 2026-10-01 night, run state

Window: 22:00-06:00 Dubai (tonight, Sep 30 into Oct 1) for any field-app/WH function change.
Data-only steps may run anytime. No function changes after 05:30 Dubai. Never touch 2026-10-01
dispatch rows (live refill).

Started 23:37 Dubai.

## Plan

- PART 1: classify the 775-row F3 backlog at the 14-day line (2026-09-16), draft/test/apply
  `close_return_backlog`, dry run, report, apply.
- PART 2 Step 1: classify the 380 A9/A10 rows into GHOST_CERTAIN / PLAUSIBLE, write the report
  file, no archiving without explicit CS review.
- PART 2 Step 2: field pilot (plan hook, driver card, report view) for PLAUSIBLE lanes only.
- Gates: overload 0, parity, smoke test, cutoff 05:30 Dubai for function changes.

## Interrupt: live bug, Warehouse Confirmations (2026-10-01)

Fixed and deployed same day, ahead of PART 1/2 work: `wm_confirm_line` only accepts
`p_outcome='acknowledged'` for `refill_return_ack`/`quarantine_batch`, but the FE still offered the
full outcome dropdown for them, causing a 400 that looked like a silent reset. FE-only fix
(`src/components/inventory/WarehouseConfirmationsPanel.tsx`): fixed "Received in warehouse" option
for these two sources, disposal code and the variant-split button (unhandled for these sources,
would have double-credited stock) hidden, per-card error display instead of one shared banner.
Tested live against a real `refill_return_ack` line (Red Bull - Regular, AMZ-1029-3003-O1 / A14):
closed cleanly, warehouse stock unchanged (3077 before and after). Committed `6ce494b`, pushed
`fe2a55d`. No backend change needed.

## PART 1 applied (2026-10-01)

CS context: the >14d historical backlog (730 rows / 2165 units) was already closed that morning
via individual `wm_confirm_line` calls, outside this loop. `close_return_backlog` shipped as the
ongoing forward rule only, with two hard exclusions CS named: quarantine_batch (structural, the
function never touches `warehouse_inventory`) and five specific suspect `refill_return_ack` rows
(double credits/anomalies) needing manual reversal, hard-coded by dispatch_id.

Cody approved (both the original design and the exclusion-list addition). Applied as
`20261001133712_p1_close_return_backlog`. Real dry run and real apply with
`p_before = CURRENT_DATE - 14` (2026-09-17) both reported 4 rows / 7 units / 3 machines / 4
products, matching the rolled-back test exactly. Verified post-apply: `refill_return_ack` dropped
44 -> 40, `quarantine_batch` unchanged at 7, the five excluded rows unchanged (`wh_approved_at`
still null), 0 `bypass_violation_log` rows for this rpc_name, 4 `write_audit_log` rows, overload
gate 0. Registered in `RPC_REGISTRY.md`, `MIGRATIONS_REGISTRY.md`, `CHANGELOG.md`. Committed
`767b3ac`, pushed `de7b883`.

## PART 2 Step 1 (2026-10-02 morning, data-only, re-scanned fresh)

Re-ran the 2026-09-30 night A9/A10 audit methodology fresh (fleet drift re-accumulates, as
expected): 431 mismatched rows now (up from 380 two days ago), 146 lanes, 31 machines, 1863 units.

Classified using `boonz_products.product_family_id` for "same family" (same signal the user's own
Plaay-size example implies): GHOST_CERTAIN = WEIMI lane stock 0, OR different family than the
lane's current label, OR row qty exceeds WEIMI lane stock. PLAUSIBLE = same family AND WEIMI lane
stock > 0.

**Data-quality finding, worth flagging separately from A9/A10 itself:** `product_family_id` is not
fully reliable. Confirmed directly: `7Up - Diet` and `Mountain Dew - Regular` incorrectly share a
family id despite being unrelated brands; two different Barebells flavors (Caramel Cashew, Creamy
Crisp) carry different family ids despite being the same brand. Caught this by spot-checking the
family-id matches against `product_brand` before trusting the classifier, found 2 of the 8
family-id-based PLAUSIBLE rows were false positives (both involve `7Up - Diet` sitting on a lane
WEIMI reads as a different brand: Coca Cola - Diet at AMZ-1038 A13, Mountain Dew - Regular at
USH-1008 A02) and manually reclassified them to GHOST_CERTAIN. Final split: 425 GHOST_CERTAIN
(1856 units) / 6 PLAUSIBLE (19 units). Full detail and the CS decision points:
`docs/loops/2026-10-01/A9_cleanup_list.md`. No writes made. Nothing archived.

Step 2 (plan hook, driver card, report view) is FE + RPC and explicitly scoped to a night window;
not started. It is now well past both the 2026-09-30/10-01 night window and the 2026-10-01/10-02
one (10:07 Dubai, 2026-10-02) -- holding for the next appropriate night window.
