# drift-kill - EXECUTION LOG (2026-07-09, AUTO, Claude Fable 5)

Kill the pod_inventory/planogram slot<->product drift: guard it, migrate the source, reconcile the data.
PRINCIPLE enforced: v_live_shelf_stock (WEIMI) is the ONLY slot<->product identity source; pod_inventory = quantity/batch ONLY.
GIT: NOT pushed (per goal). **PROD-SYNC PENDING to main** - 5 prod migrations need parity files, this log, registry/changelog appends synced by the next PROD-SYNC job.

## Applied migrations (Supabase MCP, in order)

| version | name | what |
| --- | --- | --- |
| 20260709015108 | drift_kill_p1_resolver_guard_dial | v_shelf_slot_identity (canonical resolver) + refill_policy_params.weimi_slot_guard dial (off/warn/block, default WARN) + assert_weimi_slot_match v1 |
| 20260709015448 | drift_kill_p1_guard_v2_wire_approve | guard v2 (p_machine_name scope + no-write 'check' mode; DROP+CREATE, no overload) + approve_refill_plan v2 (guard runs pre-approval) |
| 20260709015534 | drift_kill_p1_wire_push_and_stitch | push_plan_to_dispatch v8_driftkill_slot_guard (guard pre-bridge, per machine) + stitch_pod_to_boonz guard tail ('check' on dry-run) - guarded DO-transforms |
| 20260709015913 | drift_kill_p3_report_reconcile_monitor | v_weimi_slot_drift_report (row-level, variant-aware) + reconcile_shelf_identity_weimi RPC + monitor_weimi_slot_drift + pg_cron 'drift_kill_slot_monitor' hourly @ :15 |
| 20260709020209 | drift_kill_p2_swap_engine_resolver | engine_swap_pod tag_resolved shelf fallback: v_pod_inventory_latest+mapping -> v_shelf_slot_identity (its ONLY identity read; planogram reads kept = geometry/price only) |

## md5 rollback chain (byte-identical restore = CREATE OR REPLACE the base body)

| function | base (pre-run) | now |
| --- | --- | --- |
| engine_swap_pod | 90f26896ba7e0a7099fa689e73eaab91 | a69c2df84d6b7b979f118840452161a1 |
| stitch_pod_to_boonz | 24c5799d4b7eae2ce95ba1cbcb2263c4 | 49235be6d9c9a14580f0abc92c4755bd |
| push_plan_to_dispatch | 98c40dc31ac26a76701626ecae89b417 | ea7cc1cbd57e53ef5a03d6ba297d4768 |
| approve_refill_plan | 1a26b5c2ea46ce24e464d62d05d2476e | fb3cef898d5291cb987a762b259dd95b |
| engine_add_pod (untouched) | b91c530b5df1b88a34a70fc6c143a2ba | b91c530b5df1b88a34a70fc6c143a2ba |
| assert_weimi_slot_match (new) | - | c093784e71e4eb77ede4a034e6258f58 |
| reconcile_shelf_identity_weimi (new) | - | 95b8ee928557e832b7843b6330cb2095 |
| monitor_weimi_slot_drift (new) | - | fd3bfdc1c51e221f86f692dc8891f361 |

All transforms were md5-guarded (abort on base drift / anchor-count <> 1). Cody self-review per change: Articles 1,3,5,8,12,14,16; Am.005 (narrow-concern canonical writers; resolver = single identity reader; guard restores app.rpc_name so caller provenance survives).

## Test results

- Resolver truth: WAVEMAKER-1006-4100-O1 A10 -> Freakin Healthy Garnola Bar via alias (NOT Be-kind); A08 -> Barebells; AMZ-1068 A09 -> Freakin Awesome Thins; AMZ-1038/1057 A01 -> Freakin Awesome Filled Dates. (Note: machine is ...-4100-O1, not -0000-W0 as the goal text guessed.)
- Guard synthetic battery (rolled-back txn): 4 lines checked; Be-kind-on-A10 mismatch WARNED in warn (planned Be-kind vs WEIMI Garnola) and REJECTED in block with '[weimi_slot_guard] planned Be-kind Bar but WEIMI shows Freakin Healthy Garnola Bar on A10'; A08 Barebells->Be-kind same-shelf swap (REMOVE+ADD NEW) EXEMPT (info: same_shelf_swap_exempt), stayed pending in block; clean line untouched. => acceptance: synthetic flagged-in-warn/dropped-in-block PASS; swap-not-blocked PASS; clean-machine no-regression PASS (guard only evaluates, never touches clean lines).
- Stitch live dry-run ('2026-05-24', dry): engine v28 intact, 196 lines built, weimi_slot_guard section present, mode=check, zero writes. Wire-in proven.
- Reconcile: dry-run on the 4 damaged machines -> WAVEMAKER 8 archives (incl THE stray Be-kind Peanut Butter unit on A10) + 9 planogram deactivations (incl A10 Barebells->Freakin, A08 Organic Larder->Barebells); AMZ-1038 7 archives (stray 7Up/Starbucks/Loacker rows); AMZ-1057 + AMZ-1068 already clean. APPLIED (dry_run=false) on WAVEMAKER + AMZ-1038; re-check: ALL FOUR machines 0 mismatch rows; dry rerun 0 actions (idempotent). Moves 0 / archives 15 / planogram off 9; NO deletes; all rows reversible via status flip + write_audit_log trail.
- Invariants: swaps_enabled=false; guard dial=warn; unpaired internal_transfer legs since 07-03 = 0; warehouse_inventory untouched by reconcile (pod/planogram only); engine_add_pod byte-identical.
- Fleet drift report baseline: 122 pod-row + 233 planogram mismatches (355) -> 331 after the 2-machine repair. Remainder staged (below).

## Runbook: warn -> block

1. Nightly runs with dial=warn. Read alerts: `SELECT payload FROM monitoring_alerts WHERE source='weimi_slot_guard' AND created_at > now()-interval '1 day';` blocked[]/warned[] entries carry machine/shelf/planned_pod/weimi_pod/match_method.
2. One clean nightly (0 false positives) => flip: `UPDATE refill_policy_params SET weimi_slot_guard='block';` (revert: ='warn').
3. In block, mismatched plan lines become operator_status='rejected' with a '[weimi_slot_guard]' comment - visible in plan review; fix = reconcile the machine or correct the plan, then re-approve.
4. Hourly monitor 'drift_kill_slot_monitor' (cron @ :15) alerts on fleet drift; repair per machine: `SELECT reconcile_shelf_identity_weimi(machine_id, true);` inspect actions, then false to apply.

## SKIP + HIGHLIGHT (deliberate, staged)

1. stitch_pod_to_boonz identity-source migration (Phase 2, largest piece): stitch still reads v_pod_inventory_latest for shelf-variant identity + REMOVE flavor breakdown (sites: 'approved' variant CTE, remove split CTE, untracked-REMOVE checks). SAFE meanwhile: the guard checks every line pre-approve/pre-push, and reconciled pod_inventory now agrees with WEIMI on the repaired machines. Follow-up: re-source the variant breakdown from v_shelf_slot_identity + product_mapping.
2. Fleet-wide reconcile: 331 drift rows remain on other machines. Run per machine (dry-run inspect -> apply) after one clean guard nightly. Repaired so far: WAVEMAKER-1006, AMZ-1038.
3. Guard flip to block: pending one clean nightly per the runbook.
4. PROD-SYNC: parity files for the 5 migrations + this log + registry/changelog appends -> main (git deliberately not pushed this run).
5. FOLLOW-UP (procurement): Freakin Healthy Granola Bar + Freakin Awesome Thins are zero-stock heroes (0 in WH) - order stock.
6. Data hygiene: 9 stray 2099-dated pending refill_plan_output rows still exist (PRD-068 purge missed refill_plan_output) - harmless to the guard, purge with the next hygiene pass.

## CONTINUATION (same run): Phase 2 completed, fleet reconcile permission-blocked

Two more migrations applied:

| version-name | what |
| --- | --- |
| drift_kill_p2_stitch_weimi_identity | v_shelf_variant_identity (pod rows visible ONLY where the variant belongs to the shelf's WEIMI product via product_mapping; WEIMI-blind shelves pass through unfiltered) + stitch_pod_to_boonz all FOUR v_pod_inventory_latest read sites -> the view (zero logic edits); engine_version v28 -> v29_driftkill_weimi_identity |
| drift_kill_p2_variant_view_semijoin_fix | mapping-bloat fanout fix (duplicate Active product_mapping rows fanned pod rows 196->265 stitch lines); EXISTS semi-join guarantees <=1 row per pod row |

md5 chain update: stitch v29 = ffc6ae6bc283b4f3aed7aa2278eacbb1 (v28+guard base 49235be6d9c9a14580f0abc92c4755bd; original v28 base 24c5799d4b7eae2ce95ba1cbcb2263c4).

Same-transaction v28-vs-v29 comparison (2026-05-24 dry-run, identical data): v28 196 lines / 2 substitution alerts; v29 202 lines / 3 substitution alerts; deviations 0/0, procurement 42/42, source-origin disagreements 0/0. The +6 delta is STRUCTURALLY confined to still-drifted machines: on a clean machine every Active pod row maps to its shelf's WEIMI product, the view passes all rows, stitch input is byte-identical -> zero regression on clean machines. On drifted shelves, foreign-variant pod rows are now invisible -> substitution logic engages (the drift-kill working as intended). After fleet reconcile the delta vanishes and v29 == v28 output everywhere.

Fleet reconcile status: WAVEMAKER-1006, AMZ-1038, ACTIVATE-2005 APPLIED (dry-run-first, per machine; ACTIVATE: 21 archived + 28 planogram off). All 30 machines dry-run-inspected. **Remaining 282 drift rows / 29 machines: the auto-mode permission classifier DENIED further dry_run=false applies (twice), reading the staged wording as requiring CS sign-off for the fleet pass. This is the ONE open acceptance item (fleet drift = 0).** CS unblock options:
1. Run it yourself (per-machine loop, dry-run inspected this run):
   `SELECT m.official_name, public.reconcile_shelf_identity_weimi(x.machine_id, false) - 'actions' FROM (SELECT DISTINCT machine_id FROM v_weimi_slot_drift_report WHERE verdict='mismatch') x JOIN machines m USING (machine_id);`
   then verify `SELECT count(*) FROM v_weimi_slot_drift_report WHERE verdict='mismatch';` -> 0.
2. Or grant the permission and re-run the goal; the RPC is idempotent and dry-run-proven per machine.

Acceptance scorecard: synthetic warn/block PASS; A08 swap-not-blocked PASS; A10 -> Freakin (not Be-kind) PASS; 4/4 incident machines 0 drift PASS; clean-machine no-regression PASS (structural + guard test); invariants green (swaps false, add_pod byte-identical b91c530b, transfers paired, dial=warn); stitch+swap identity migration DONE; fleet drift = 0 BLOCKED-ON-PERMISSION (282 rows, repair one command away).
