# PRD-070 completion + environment close - EXECUTION LOG

Mode: OVERNIGHT AUTO. Branch: feat/prd-070-completion (off origin/main). No em dashes.
Loop per writer: Dara design -> Cody review -> migration FILE -> BEGIN..ROLLBACK dry-run -> apply if green -> verify -> commit.

## Baseline (captured 2026-07-01)

- origin/main: 40eb6e5 (PRD-070 259 + 432 present; extra commits are automated deploy-record CI [skip ci]).
- Engines md5 rollup (must stay byte-identical): `6c3e853730f72115dfa5910da62ec0c0` (6 engine_ fns).
- swaps_enabled (refill_settings): **false**. Gate holds.
- Done-pieces verified live: approve_m2m_transfer=1, m2m_approved_at col=1, idx_rd_m2m_transfer=1, wh_approve_remove_receipt + _multivariant reject is_m2m (from prior session).

## M2M row landscape (refill_dispatching)

is_m2m=true rows (22):

- transfer_id set, Add New, pending: 7 (Gen-2 convert dest legs)
- transfer_id set, Remove, pending: 6 (Gen-2 convert source legs)
- transfer_id set, Remove, item_added: 1 (processed)
- transfer_id NULL, Refill, item_added: 8 (Gen-1 orphans, already processed, no live source partner -> OUT OF SCOPE, skip+log)

source_origin='internal_transfer' rows (the mark_internal_transfer/push path):

- is_m2m already true (Gen-1 subset), transfer_id NULL, item_added: 6
- is_m2m FALSE, transfer_id NULL, Refill: 10 item_added + 2 pending(but cancelled/returned)
- is_m2m FALSE, transfer_id NULL, Remove: 6 item_added + 4 pending(but 2 cancelled/returned)
- Truly live-pending (item_added=false AND cancelled=false AND returned=false): **2 legs**, both Remove, MINDSHARE-1009, dispatch_date 2026-05-20, from_machine_id NULL, source_machine_id -> other machines, is_m2m=false, no transfer_id, NO matching live dest Refill partner.

## D-2 pairing integrity - decisions

- convert_removes_to_m2m_transfer: VERIFIED already sets is_m2m=true + shared m2m_transfer_id + m2m_partner_id + source_machine_id on BOTH legs (source UPDATE, dest INSERT). Compliant. No change.
- mark_internal_transfer: plan-level only. Stamps pod_refill_plan.source_origin='internal_transfer' + from_machine_id. Does NOT (and cannot) set is_m2m/transfer_id (those columns live on refill_dispatching).
- push_plan_to_dispatch(date,text) canonical bridge: carries source_origin='internal_transfer' + from_machine_id onto dispatch legs, but does NOT set is_m2m / m2m_transfer_id / m2m_partner_id / source_machine_id. This is the durable D-2 gap: internal_transfer legs reach dispatch UNFLAGGED, so on approval via the WH path they would credit/draw the warehouse.
- Bridge is per-machine (p_machine_name): source Remove leg and dest Refill leg are created in SEPARATE push calls, so a shared transfer_id cannot be assigned inline. A pairing pass is architecturally required.

Durable mechanism built: `pair_internal_transfer_m2m(p_plan_date, p_caller_id)` (idempotent, DEFINER, role-gated). Flags is_m2m + source_machine_id + source_kind on internal_transfer legs, pairs conserving source<->dest groups, assigns shared m2m_transfer_id + m2m_partner_id. Only acts where pairing is unambiguous AND conserves (sum source out == dest in, same product+date). Ambiguous/unpairable -> skip+log. Serves as the backfill too.

### NEEDS CS (D-2)

- The 2 stale live-pending MINDSHARE-1009 Remove legs (2026-05-20, qty 3 + 5) have no live dest partner and source_machine_id pointing at other machines. Unpairable by the conservation rule -> the pair function skip+logs them. They remain is_m2m=false. Not auto-mutated. CS to decide: cancel them, or supply the intended dest.
- push_plan_to_dispatch inline auto-call of pair_internal_transfer_m2m: NOT wired in this pass. Editing the 11.8KB critical dispatch writer unsupervised overnight is out of risk budget. The pair function is the mechanism; wiring push (or a post-push cron) to call it is a CS decision.

Applied: migration 20260701160000_prd070_d2_pair_internal_transfer_m2m. Dry-run 0 pairs (safe no-op). Engines md5 unchanged. Committed a5eed1d on feat/prd-070-completion.

## D-3 dispatch visibility - decisions

- v_dispatch_pick_list excluded M2M dest legs via its dispatched=false filter. push-created internal_transfer dest legs (dispatched=false) already surface; convert_removes_to_m2m_transfer creates dest Add New legs with dispatched=true, which the pick list dropped.
- Fix: CREATE OR REPLACE VIEW v_dispatch_pick_list, byte-identical columns, WHERE relaxed to allow pending M2M dest legs (is_m2m AND NOT item_added) even when dispatched=true. All other guards preserved (date >= today, include, returned=false, picked_up=false, action <> Remove). Moves no stock, mutates no row.
- Dry-run: old_rows=244, new_rows=244 (removes nothing), newly_surfaced=0, surfaces_1538f35f=0. Post-apply: pick list 244 rows, MINDSHARE rows 0. Engines md5 unchanged.
- Cody PASS (Articles 12, 16). Applied: migration 20260701160500_prd070_d3_pick_list_m2m_dest_visibility.

### NEEDS CS (D-3)

- The 7 pending dest Add New legs of transfer 1538f35f (NOVO-1023 -> MINDSHARE-1009, dispatch_date 2026-06-23) are returned=true AND past-dated, so the view fix intentionally does NOT surface them (goal forbids disturbing / approving 1538f35f). To make them pickable OR approve them, CS must run approve_m2m_transfer('1538f35f...') or re-date/clear returned. Not auto-done.
- convert_removes_to_m2m_transfer stamps dest legs with returned=true (anomaly) + the source dispatch_date (often past). Future convert dest legs will therefore also be blocked by returned/date, not just dispatched. Adjusting convert to create pickable dest legs (returned=false, current date) touches the live-transfer creation path and the returned=true provenance is unclear -> CS decision. The D-3 view fix removes the dispatched blocker so correctly-stated M2M dest legs surface.
