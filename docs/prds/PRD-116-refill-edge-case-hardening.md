# PRD-116 — Refill edge-case hardening

**Date:** 24 Aug 2026 (overnight run) · **Author:** Claude for CS · **Status:** Phase 1 SHIPPED, Phase 2 design queue
**Trigger:** the 23–24 Aug Monday plan hit three separate guard/logic defects in one run; team has zero bandwidth for morning errors.

## Problem statement

The refill pipeline is correct on the happy path but brittle at its edges. Three classes of glitch keep costing
operator time and threaten wrong stock movements:

1. **Rule glitches** — guards firing on rows that are correct by design (conservation counting superseded M2W),
   or refusing correct operator input (capacity clamp keyed to the outgoing product).
2. **Data glitches** — dispatch rows created without their parents' transfer tagging, so downstream classifiers
   see in-machine moves as warehouse returns; pod ledger drifting from WEIMI; expiry typos moving batches ~11 months.
3. **Dead-end UX** — native browser dialogs that block or offer no truthful answer (field-purchase receive).

## Phase 1 — SHIPPED overnight 23→24 Aug (all live in prod, Cody-reviewed, md5-guarded)

| #   | Migration                                      | Defect                                                                                                                                                                          | Fix                                                                                                               |
| --- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| A   | `prd116a_conservation_ignores_superseded`      | PRD-053 conservation guard counted SUPERSEDED pod_refill_plan REMOVE/M2W rows (no approved children by design) → false stop-ship; 3rd occurrence, 5/6 machines blocked on 08-23 | Parent side of the SUM comparison excludes `status='superseded'`                                                  |
| B   | `prd116b_driver_split_inherits_parent_tagging` | `insert_driver_remove_line` children dropped `source_kind`/`source_machine_id`/`is_m2m`/`is_internal_move` → in-machine moves queued as warehouse returns (MPMCC 08-20)         | Child inherits the tagging from the most recent matching parent Remove leg (same machine+shelf+pod+date)          |
| C   | `prd116c_addnew_edit_cap_uses_incoming_facing` | `edit_pod_refill_row` clamped ADD_NEW to the OUTGOING product's lane max (NOVO Krambals 10 refused at 6)                                                                        | ADD_NEW cap = incoming pod product's fleet facing (max WEIMI max_stock, 30d), fallback lane max; REFILL unchanged |

Earlier this weekend, same family: `prd016c` (manager-verified returns land trusted, no double quarantine),
`prd016d` (field purchase received straight into a machine, net-zero WH), `prd113b` (pod-level pairing for
multi-flavour in-machine moves). All five now have git migration files (this commit).

## Phase 2 — designed here, NOT shipped overnight (needs Dara design + Cody, daylight)

| #   | Item                                                                                                                                                                                                         | Why not overnight                                                |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------- |
| D   | **Engine ADD_NEW sizing** — `engine_swap_pod` sizes swap-ins to the outgoing lane max (Sunbites 14 in a Perrier lane). Fix mirrors 116c inside the engine                                                    | Engine version bump; needs fixture run                           |
| E   | **Per-product lane capacity model** — capacity should be (lane geometry × product form factor), not last WEIMI reading                                                                                       | Schema (Dara): product facing dimensions or learned facing table |
| F   | **pod_inventory multi-batch** — unique(machine,shelf,product) forces expiry-key reuse on merge; true batch expiry survives only on WH rows                                                                   | Schema + writer sweep (Dara + Cody)                              |
| G   | **Red Bull Regular 0% global split** + ~15 machine-scoped-only SKUs invisible to procurement                                                                                                                 | Weekly-session mapping decision, affects stitch fleet-wide       |
| H   | **Kill remaining 9 native `window.prompt`/`confirm` sites** (6 on procurement page) + deploy the pending FE (receive-destination modal, uncommitted `page.tsx` changes)                                      | FE deploy needs CS eyes; tsc/lint clean already                  |
| I   | **Expiry entry validation** — day/month transposition moved a batch 11 months (VW Zero Lemon 2027-01-03 vs 2027-12-03). Add a sanity check at receive: expiry < purchase+24m and warn on d/m-swap candidates | Small, but touches receive writers; batch with D                 |
| J   | **Packing swap modal** — shelf picker built from the plan's `lines`, not `shelf_configurations` (WPP showed 3 of 16 live shelves); Remove validated at flavour level against pod-level WEIMI data | UX consequence of F; ship with or after F |
| K   | **Redirect a return to another machine** — a Remove can only go back to the warehouse; JET's Vitamin Well was physically placed in OMDBB and the system still showed a return to the office. Backend (`convert_removes_to_m2m_transfer` + `approve_m2m_transfer`) exists and is correct; it has no front door | FE + Cody; depends on B and J2 |

## Non-goals

No engine version changes overnight; no schema changes overnight; no FE deploy overnight; no mapping split edits overnight.

## Verification (morning of 24 Aug, automated — results reported before team start)

- `preflight_refill_plan('2026-08-24')` = PASS; 86 dispatch rows intact, none packed rows touched.
- Returns-awaiting-approval widget = 0 rows (bar today's legitimate route confirmations).
- Quarantine panel = Healthy Cola write-off rows only.
- Field-addition banner = 0.
- FEFO binding: 64/65 bound; the 1 unbound (JET A02 Pepsi Regular ×1 — WH_CENTRAL has zero) reported to procurement.
- No new `dispatch_bridge_nonok` / `stitch_leakage` rows since the fixes.

## Rollback

Each migration file carries its md5 guard; rollback = re-apply the prior verbatim body (in CHANGELOG). No data was mutated by A–C.
