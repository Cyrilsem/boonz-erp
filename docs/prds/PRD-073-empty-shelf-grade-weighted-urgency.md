# PRD-073: Eligibility hardening + grade-weighted empty/low-fill urgency

Status: SHIPPED 2026-07-04 (WS-A + WS-B applied to prod, T1-T5 green; see PRD-073-EXECUTION-LOG.md). Carry-forward CLOSED by PRD-075 (repurpose grace window; the 3 machines grade on merit).
Owner: CS. Mode: AUTO with hard gates. Touches v_machine_priority (picker input) and pick_urgency_params.

## Context / what already happened

Root cause found 2026-07-03: `v_live_shelf_stock.is_eligible_machine` requires `machines.adyen_inventory_in_store = 'Live'`, but 12 Active machines carried the literal string `'true'` (AMZ x4, NOVO, NISSAN, ALJLT, MINDSHARE, ACTIVATE x2, IFLYMCC, MPMCC). Their shelves were filtered out of `v_shelf_sales_identity` BEFORE grading, so the urgency model was blind on a third of the live fleet (grades all zero, urgency floored at 15, P3 forever).

ALREADY DONE from chat (2026-07-03, snapshot in conversation + below): `UPDATE machines SET adyen_inventory_in_store='Live' WHERE adyen_inventory_in_store='true' AND status='Active'` (12 rows). Verified: AMZ-1038 and AMZ-1029 immediately went P1 with correct hero grades. This PRD makes the fix durable and adds the scoring change CS wants.

Rollback snapshot: the 12 machine_ids and prior values are recorded in PRD-073-EXECUTION-LOG.md (copy from the chat snapshot; all were 'true').

## Workstreams

### WS-A: Make eligibility drift impossible

1. Dara: pick the durable shape. Preferred: normalize `adyen_inventory_in_store` to a constrained value set via CHECK constraint (NOT VALID then VALIDATE) covering observed values ('Live', 'Pending Setup', 'false', 'Warehouse Ready', 'Offline - WH Missing Shelves', 'Live - WH Storage', NULL), with 'true' disallowed going forward. Identify and fix the WRITER that produced 'true' (likely an n8n adyen sync flow writing a boolean) so it writes 'Live'/'false'.
2. Add `v_machine_eligibility_drift` monitor view: Active + Online machines whose shelves produce zero rows in v_shelf_sales_identity (any cause). Zero rows expected.
3. Cody review (machines is protected).

### WS-B: Grade-weighted empty + low-fill urgency (CS requirement)

Requirement: P1 must prioritize empty shelves regardless of grade, ranked A > B > C > D, and shelves below 25% fill likewise grade-ranked, both adding real score.

1. Dara design, v_machine_priority v2 (forward migration, PRD-058 single-row params pattern):
   - New per-shelf signals in the shelf_graded CTE (source rows already exist): is_empty = stock = 0 on enabled non-broken shelf; is_low = fill_pct < low_fill_pct_floor AND stock > 0.
   - New machine terms: s_empty = 100 * sum(grade_mult) over empty shelves / greatest(total_enabled_shelves,1); s_lowfill = same over low shelves. grade_mult from new params: empty_wt_a/b/c/d default 1.0/0.7/0.45/0.25 (D still counts, per CS: empty is empty).
   - Blend: urgency = w_runout*s_runout + w_capacity*s_capacity + w_expiry*s_expiry + w_stale*s_stale + w_empty*s_empty + w_lowfill*s_lowfill. New param columns w_empty (suggest 0.9) and w_lowfill (suggest 0.5), low_fill_pct_floor (25). All tunable, no redeploy (PRD-058 dial pattern).
   - New reasons: 'empty_shelves' when s_empty > 0, 'low_fill_sellers' when s_lowfill >= 20.
   - P1 escalation: add OR condition, empty A-or-B graded shelf count >= p1_empty_ab_min (default 1) forces P1 with reason 'hero_shelf_empty'. Keeps CS intent: an empty seller shelf is never P3.
2. Gates: pick_machines_for_refill body untouched (it consumes the view); engines md5 byte-identical; all thresholds and weights live in pick_urgency_params (add columns with defaults, single row updated); BEGIN..ROLLBACK proof.
3. T-tests (record before/after tier tables in the log):
   - T1 AMZ-1038 (A10 Hunter Ridge 0/8, A11 Dubai Popcorn 0/6 currently): stays/goes P1 with 'hero_shelf_empty'.
   - T2 MC-2004 (1 empty shelf of 32): score rises by the empty term; tier changes ONLY if the empty shelf is A/B grade. Verify which and log.
   - T3 No previously-P1 machine drops tier (regression guard).
   - T4 Fleet tier distribution before vs after; flag if P1 count more than doubles (weights too hot, tune down w_empty, do not ship a P1 flood).
   - T5 VOX track unaffected in ordering logic (svc_track separation intact).

### WS-C: Close

Registries (RPC/MIGRATIONS/CHANGELOG + METRICS_REGISTRY entry for the two new terms), execution log, commit to main, push. Board note on PRD-073 status line.

## Acceptance

- No Active+Online machine can be silently ineligible again (constraint + monitor + writer fixed).
- Empty shelves and sub-25% shelves add grade-weighted urgency; empty A/B shelf forces P1; all knobs in pick_urgency_params.
- T1..T5 recorded; engines untouched; main == origin/main after push.

## Rollback

WS-A constraint: drop constraint (forward migration). WS-B: view is versioned; re-apply prior body (kept in migration file as comment or _HELD rollback file, PRD-063 pattern); param columns are additive and inert if w_empty/w_lowfill set to 0.
