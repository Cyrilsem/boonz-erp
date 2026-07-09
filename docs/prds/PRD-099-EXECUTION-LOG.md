# PRD-099 Execution Log — approve_return provenance/source_event fix

Run 2026-07-10, AUTO. **Status: SHIPPED to prod** (function-body only). Cody PASS. Branch
`fix/prd-099-approve-return-provenance`. No schema/constraint/whitelist/data change.

## Root cause
`approve_return` flips `provenance_reason='dispatch_return'` (NOT whitelisted by
`wh_provenance_event_required`) but never supplied `source_event_id`. Pipeline rows carry an
event id (pass); manual/legacy rows (`unknown_pre_migration`, NULL event) fail the constraint.

## Fix (2 additions) + evidence-backed DEVIATION from the PRD's literal code
- Mint `v_event uuid := gen_random_uuid()`; `UPDATE ... SET source_event_id = COALESCE(source_event_id, v_event)`; record `approval_event_id` in `return_approval_log` + the return payload.
- **DEVIATION (Cody-approved):** the PRD said `set_config('app.source_event_id', v_event)`. Tested
  live (rolled back): `set_warehouse_inventory_provenance` fires on UPDATE and UNCONDITIONALLY
  overrides `NEW.source_event_id` from that GUC — so the PRD's line **clobbers pipeline rows'**
  original event id, violating the PRD's own acceptance. Correct fix: set
  `app.source_event_id=''` (empty) so the trigger does NOT override, letting the `COALESCE`
  govern (pipeline keeps original, legacy gets the fresh approval event). Also immunizes against
  GUC leak across statements.

## Verify (live, rolled back)
| Case | Result |
|---|---|
| LEGACY `6cb1b7b2` (unknown_pre_migration, NULL event, qty corrected to 5) | approved; `dispatch_return` + `source_event_id` non-null (= minted approval_event_id) |
| PIPELINE `1305c7be` (has event `b6eb8631`) | approved; `source_event_id` = `b6eb8631` PRESERVED (COALESCE) |
| Article 6 | no status write (unchanged) |

## Reconcile the stopgap — CS DECISION REQUIRED (NOT executed)
The Barebells Hazelnut Nougat units were credited to WH_CENTRAL manually via `adjust_warehouse_stock`
on 2026-07-09. The two pending quarantine rows for the SAME physical units — `6cb1b7b2…`
(exp 2026-12-12) and `8f24dda3…` (exp 2026-12-22), both `unknown_pre_migration` + NULL event —
must NOT be approved now, or the units double-count. **CS to choose:** (a) discard those quarantine
rows, OR (b) reverse the manual credit and let the fixed approval carry them. Left untouched; no
approval executed against them in prod.

## Recommended separate follow-up (PRD's optional belt-and-suspenders)
Make `set_warehouse_inventory_provenance` RAISE when an event-requiring reason arrives with an empty
event id (naming `app.rpc_name`) — turns the next mis-wired writer's opaque constraint error into a
named one. Not part of this fix.

## Status: SHIPPED (prod). Reconcile = CS decision. FE unaffected.
