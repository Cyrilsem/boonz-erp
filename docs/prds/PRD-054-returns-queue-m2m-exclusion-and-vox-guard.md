# PRD-054 - Returns-approval queue: exclude M2M transfers + durable VOX (venue_team) receive guard

**Status:** APPLIED 2026-06-23. Migration `prd054_a_returns_queue_exclude_m2m` (`20260624010000_…sql`). Backend (view + receive-path guard, forward migrations). Cody Articles 1/4/6/8/12.

> **Applied result:** (1a) view recreated with `AND COALESCE(rd.is_m2m,false)=false`; queue 21 -> 15, m2m 6 -> 0, all 7 PRD-052 legs excluded (verified live). (1b) venue_team receive guard found ALREADY LIVE in `receive_dispatch_line` (skips WH credit, logs vox_return_log, path `remove_venue_team_no_wh_credit`, item_added=true; covers `wh_approve_remove_receipt`[`_multivariant`] via delegation) — NO function change made. Tests T1-T6 green in BEGIN..ROLLBACK before apply: T3 venue=0 WH credit; T5 boonz-on-VOX-machine credits WH; T6 audited. Not pushed to main (awaiting CS go).

**Owner:** CS (cyrilsem@gmail.com)
**Created:** 2026-06-23
**Severity:** MEDIUM-HIGH. The WH "Returns awaiting approval" queue shows machine-to-machine transfers (noise + risk of wrong approval), and there is no guard preventing venue-owned (VOX) stock from being credited into the Boonz warehouse on receipt.

## 0. Findings (verified 2026-06-23)

- The `/app/inventory` panel `PendingRemoveApprovalsPanel` reads view `v_pending_wh_remove_confirmations`; it is ~41 rows (was "11", has grown + gone stale; oldest ~270h).
- The 7 PRD-052 Vitamin Well rows (now `is_m2m=true`, transfer_id `1538f35f-...`) STILL appear in this queue. They are machine->machine transfers, NOT warehouse returns; the view does not filter `is_m2m`. (Receive is M2M-aware so approving them would not credit WH, but they are noise and an approval foot-gun.)
- VOX check: 0 of the current queue rows are venue_team-sourced on their machine (checked per machine_id + boonz_product_id against product_mapping.source_of_supply). So there is nothing to remove today under the "VOX should not be added" rule - but there is no DURABLE guard stopping a future venue_team return from crediting Boonz WH (matches the known gap: receive has no venue_team check).

## 1. The change (decided)

### 1a. Exclude M2M transfers from the returns-approval queue

Forward migration recreating `v_pending_wh_remove_confirmations` with `AND COALESCE(is_m2m,false) = false` (CREATE OR REPLACE VIEW; no shape change otherwise). Drops the 7 PRD-052 rows cleanly and any future M2M leg. Verify the panel count falls by exactly the current is_m2m row count.

### 1b. Durable VOX (venue_team) receive guard

A return whose product is venue_team-sourced on its machine must NEVER credit Boonz `warehouse_inventory`. Add a guard in the WH receive path (`wh_approve_remove_receipt`, `wh_approve_remove_receipt_multivariant`, and the core `receive_dispatch_line` Remove branch): if `EXISTS (product_mapping pm WHERE pm.machine_id = dispatch.machine_id AND pm.boonz_product_id = dispatch.boonz_product_id AND pm.source_of_supply='venue_team')`, then mark the line received WITHOUT a warehouse credit (no `warehouse_inventory` insert/merge; set the line resolved/`item_added=true` with provenance `venue_owned_no_credit`) instead of crediting Central. Does not touch `warehouse_inventory.status` (Article 6). Audited (Article 8).

## 2. Testing rules (mutating tests in BEGIN..ROLLBACK first)

| #   | Test                              | Expected                                                                                                                           |
| --- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| T1  | view fix                          | `v_pending_wh_remove_confirmations` no longer returns any `is_m2m=true` row; the 7 PRD-052 rows gone; non-m2m rows unchanged       |
| T2  | approve a normal boonz return     | credits Central WH as today (no regression)                                                                                        |
| T3  | receive a venue_team return (sim) | NO warehouse_inventory credit row; line marked resolved with `venue_owned_no_credit` provenance; audited                           |
| T4  | multivariant venue_team return    | same guard applies per variant                                                                                                     |
| T5  | guard scope                       | a boonz product on a VOX machine that is NOT venue_team-mapped still credits WH (guard keys on source_of_supply, not machine name) |
| T6  | audit                             | each receive path still writes write_audit_log                                                                                     |

## 3. Phasing / gates

- P1 Dara design + Cody review (view recreate + receive-guard branch). Forward migrations only.
- P2 Tests T1-T6 in rolled-back tx; then apply.
- P3 Verify queue drops the 7 M2M rows; document. Update CHANGELOG, MIGRATIONS_REGISTRY, RPC_REGISTRY.
- No git push to main without explicit CS go-ahead. Stale legit returns (the ~30 real driver-confirmed ones) are NOT auto-touched here - separate operator triage.
