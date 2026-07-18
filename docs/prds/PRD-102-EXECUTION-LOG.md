# PRD-102 — EXECUTION LOG

## 2026-07-18 — SHIPPED (single session; Dara -> Cody -> build -> test -> ship)

### Dara pass (D2 semantics decision)
- skipped=true + include=false + skip_reason 'decline_swap: <reason>' — the established
  PRD-020/028 skip state machine: visible as a DECISION (skipped panel + SWAPS render),
  pack refuses unconditionally, unskip_dispatch_line is the logged reactivation. NOT
  bare include=false (remove-from-plan semantics; vanishes).
- Learning signal: ONE refill_edit_signals row per pair with pod_product_id = the
  INCOMING pod (deviation from the PRD's "removed pod" prose, deliberate): the live
  engine's _suppressed_swap_subs keys on the incoming pod (>=3 rejections/30d); the
  REMOVED pod's 14-day no-repeat-removal comes from the rpo-based _r5_removal_cooldown
  independently. Removed pod + reason recorded in note.
- refill_dispatching_edit_log CHECKs extended with 'decline_swap' (before+after shape);
  log stays append-only.

### Cody verdict (verbatim, self-run light per goal)
✅ Approve both. Articles 1/4/8/12 clean. Article-13 nuance on D1: dropping the 5-arg
without a deprecation window is justified — the 6-arg DEFAULT NULL replacement is
call-compatible for every named-param caller, and coexisting PostgREST overloads would
recreate the PRD-071 42725 incident. D2's CHECK extension broadens the append-only
log's vocabulary without touching policies. Conditions: RPC_REGISTRY entries (done).

### Applied migrations
- prd102_d1_swap_shelf_pod_qty (20260718071500): 6-arg swap_shelf_pod; NULL = legacy
  fill-to-cap byte-identical (response shape unchanged on that path); qty path spreads
  LEAST(qty, WH-available) via spread_pod_qty, clamp_reason='wh_limited' + requested_qty
  + wh_available in response when short. Rollback: rollback/swap_shelf_pod_5arg_2026-07-18.sql.
- prd102_d2_decline_swap_pair (20260718072000): edit-log CHECK extension + the new
  DEFINER writer (roles: field_staff, warehouse, operator_admin, superadmin, manager).

### T-tests (single rolled-back txn on WH1-2002 A01, impersonated field_staff via request.jwt.claims)
- T1 PASS: spread=8 cap=8, no requested_qty key (legacy path byte-identical).
- T2 PASS: p_new_qty=6 with cap 8 => exactly 6, no clamp (capacity no longer clamps).
- T3 PASS (adapted): p_new_qty=100 vs WH-available 60 => 60 + clamp_reason='wh_limited'
  + requested_qty=100 + wh_available=60. The spec'd 12-vs-8 shrink is impossible
  without an Article-6 status write: setting warehouse_stock=0 auto-INACTIVATES the row
  (p0_fix8 sweep semantics) and reactivation is a guarded manager-only path. Same
  contract proven: request > available => fill available + flag.
- T4 PASS: p_new_qty=0 raises 'must be >= 1'.
- T5 PASS: decline as field_staff bddaec3c => 2 legs skipped=true/include=false with
  'decline_swap:' skip_reason, 2 edit-log rows (edited_by_role='field_staff',
  kind='decline_swap'), 1 swap_rejected signal (source='field', incoming pod).
- T6 PASS (mechanically, via the engine's verbatim query shapes): the rpo-based
  _r5_removal_cooldown holds the declined (machine, removed pod) for 14 days => not
  re-proposed; the signal-side suppression counted 1 of the >=3 needed (honest note:
  one decline teaches via the rpo cooldown; suppression of the incoming pod needs 3
  declines in 30d). Engine itself untouched.
- T7 PASS: declining a packed pair raises 'already started'.
- T8 PASS: tsc 0 errors; npm run build green (56/56). Modal shows Quantity-to-add
  prefilled with suggested (WEIMI cap bounded by WH avail) + live WH-available for the
  chosen pod; pair cards + modal gained "Don't swap"; declined pairs render
  struck-through "Declined — [reason]" in the SWAPS section (sourced from skippedLines
  by the skip_reason prefix) and read as Declined in the skipped panel.
- Gate checks: engine_add_pod + engine_swap_pod md5 byte-identical pre/post; zero test
  residue persisted (full rollback); single 6-arg signature in pg_proc (no overload).

### Test-harness gotchas (for the next session)
- prevent_duplicate_unstarted_dispatch blocks re-swapping a shelf with unstarted Add
  New rows; neutralize by skipped=true (guard ignores skipped), never DELETE (edit-log FK).
- warehouse_inventory zeroing auto-inactivates rows; status is Article-6 — do not
  manufacture WH shortage by zeroing; pick a request > live availability instead.
