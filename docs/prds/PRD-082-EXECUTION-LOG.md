# PRD-082 Execution Log — Planned/filled quantity split (DARK)

Run 2026-07-07 overnight, AUTO. **Status: SHIPPED DARK (qty_split_v1=off).** Cody PASS
(⚠️→revisions applied). Family A md5 `8587be9a` UNCHANGED. pack_dispatch_line is not Family A.

## Shipped (behind qty_split_v1, seeded off)
- `pack_dispatch_line` first-pick UPDATE: `quantity = CASE WHEN refill_qa.flag('qty_split_v1')='on'
  THEN quantity ELSE v_total_picked END`. Flag off ⇒ byte-identical to prior behaviour
  (overwrite). Flag on ⇒ planned quantity preserved; `filled_quantity` carries packed (already
  written). Full resolved body in the migration (Cody: auditable, not a runtime regexp).

## Validation
| Check | Result |
|---|---|
| surgical edit (1 occurrence, no collateral) | PASS |
| dark-path identity (flag off = v_total_picked) | PASS (provable by inspection) |
| Family A md5 byte-identical | PASS (8587be9a) |
| diff_vs_golden | N/A identical — pack is downstream of the plan pipeline; plan output unaffected |
| conservation delta | 0 |
| cody | PASS (full body in migration; enable un-park conditions recorded) |

Note: pack_dispatch_line's happy path could not be exercised synthetically (its PRD-072
FEFO re-bind fail-softs on synthetic batches: bind_fail_reason=quarantined). The dark ship
does not depend on it — dark equivalence is proven by the single-substitution inspection.

## Parked (enable + data + FE — un-park conditions)
1. **Enable qty_split_v1** — needs FE reader-repoint (`quantity`→`filled_quantity`) THEN a
   settlement byte-diff re-check on a sample period (Cody condition). {owner: FE/CS}
2. **Backfill** `quantity=original_quantity` where safe — data mutation on protected
   refill_dispatching; snapshot-then-update, reviewed separately. {owner: CS}
3. **Remove edit_dispatch_qty item_added block** — separate writer change. {owner: Stax+Cody}

## Status: SHIPPED DARK. Enable/backfill/FE parked.
