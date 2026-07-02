# Claude Code /goal Command - PRD-053 (condensed)

Paste into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. Phased; STOP per phase for CS. Forward-only. No em dashes. Migration FILES only; apply nothing to prod.

```
/goal Implement PRD-053 (docs/prds/PRD-053-stitch-conservation-field-expiry-flagged-adds.md); read it first. Three rules: (1) NO LEAKAGE - after stitch the boonz lines for a pod instruction must sum to the original pod qty, always; a publish-time check refuses any non-conserving stitch. (2) The driver can split a line across real expiry dates with the TOTAL LOCKED to plan. (3) The driver can ADD beyond plan but every addition is FLAGGED for Head Office (CS) review, never silently changing the books.

RULES
- Fetch live bodies via pg_get_functiondef before editing (especially stitch_pod_to_boonz, push_plan_to_dispatch); base the migration on the live body, never guess.
- Forward-only migrations (ts prefix); no _v2/edit-in-place. DEFINER writers set app.via_rpc+app.rpc_name, validate role+inputs, keep the audit trigger.
- Protected: pod_refill_plan, refill_plan_output, refill_dispatching. Cody verdict per writer. No deletes; no qty cut without a per-row diff. Migration FILES only; apply nothing to prod. Per phase: live body + SQL + diff + Cody verdict, then STOP for CS. Log ACs in PRD-053-EXECUTION-LOG.md.

ROOT CAUSE (verified 2026-06-23, VML-1004-0500-O1 shelf A3 Ice Tea):
- pod_refill_plan REMOVE = 13 (correct, = live WEIMI shelf). refill_dispatching REMOVE = 6 at exp 2027-01-08. pod_inventory = 6 Active (exp 2027-04-15). Stitch re-derived the REMOVE qty from stale pod_inventory (6) instead of conserving the pod plan total (13). 7 leaked. Single-variant (Ice Tea -> 100% Ice Tea Peach), so NOT a flavor split and NOT the engine qty-guard.

PHASE A (conservation invariant - HEADLINE):
1. The conservation PARENT is the pod_refill_plan qty (the original instruction), NOT a qty re-derived from pod_inventory. For every (plan_date, machine_id, shelf_id, pod_product_id, action), SUM(boonz children) MUST equal the pod qty.
2. REMOVE: size from the pod plan total; distribute across known batches/expiries by FEFO; if a remainder cannot be attributed to a known batch, still write a line for it with expiry_date = NULL (expiry-to-confirm) so the total holds. Do NOT cap to pod_inventory.
3. Publish-time assert in stitch (or push_plan_to_dispatch): refuse to write/ship when SUM(children) <> parent_pod_qty for any instruction; emit a stitch_leakage telemetry row (instruction + delta). Non-conserving stitch = stop-ship.
VERIFY (rolled back): re-run the VML5 Ice Tea case -> REMOVE lines sum to 13 (e.g. 6 known + 7 to-confirm), never 6; the assert blocks a deliberately-leaking fixture.

PHASE B (field per-expiry edit, total locked):
- A canonical RPC sets a per-expiry breakdown on a dispatch line (reuse the p_batch_breakdown shape receive_dispatch_line already takes) and enforces SUM(rows) = line total; total immutable, only the expiry distribution changes. Stax wires it onto the driver dispatching/packing line (distinct from the WH returns-approval panel). Cody on the writer.
VERIFY: driver splits 13 into 6 + 7 across two expiries; total stays 13; saved.

PHASE C (flagged additions to Head Office):
- Extend the add path (add_dispatch_row or a wrapper) to stamp needs_review=true / review_reason='driver_addition' on driver additions beyond plan; never block. Stax surfaces a Head Office review queue (list of flagged additions) for CS to accept/reject. Cody on the writer + any column (Dara designs the column/flag).
VERIFY: driver adds 2 extra (15 total); the 2 are recorded AND flagged in the review queue; nothing blocked.

CONFIRM per phase, pass/fail each AC. Start with Phase A. Show the live stitch body + migration file + Cody verdict before applying anything.
```

PRD: `boonz-erp/docs/prds/PRD-053-stitch-conservation-field-expiry-flagged-adds.md`.
