/goal PRD-060: force machine-to-machine transfers through the M2M writer so they stop being hand-built as plain Remove+Refill (which double-churns Central). MODE AUTO. Full spec: boonz-erp/docs/prds/PRD-060-transfer-creation-path.md. Backend guards + FE Create-transfer. Dara design, Cody (Articles 1/4/6/8/12). Forward-only. STOP before any push to main / Vercel deploy.

CONTEXT (verified live, MC->AMZ 24 Jun): transfers are created as plain Remove `[TRUCK-TRANSFER - do not debit WH]` (is_m2m=false) on source + Refill `[TRUCK-TRANSFER from X]` (source_origin='warehouse', is_m2m=false) on dest. The comment is inert: dest Refills debit Central, source Removes credit Central, no conservation. flag_remove_with_transfer_intent only WARNS. receive_dispatch_line already M2M-skips when is_m2m=true; convert_removes_to_m2m_transfer (PRD-052) already retro-converts dispatched plain Removes.

PRE: git pull --rebase main; branch feat/prd-060-transfer-creation. Fetch live bodies via pg_get_functiondef before editing.

BUILD (forward migrations):
1b CONVERT/BLOCK: upgrade the transfer-intent path so a Remove carrying `[TRUCK-TRANSFER]` (or transfer intent) with is_m2m=false + no partner cannot settle as a WH drain. Preferred: at approve/push time auto-convert via convert_removes_to_m2m_transfer to a paired is_m2m leg; else hard-block with an error pointing to Create-transfer. Keep the monitoring_alert. Cody Art 1/4/8.
1c RECEIVE guard: in receive_dispatch_line + wh_approve_remove_receipt(+\_multivariant), a Refill/Add New that is a transfer-in (is_m2m OR comment ILIKE '[TRUCK-TRANSFER from %' OR from_machine_id set) is received WITHOUT a warehouse_inventory debit, provenance 'transfer_in_no_wh_debit'. Mirror the PRD-054 venue_team guard. Never write warehouse_inventory.status (Art 6). app.via_rpc + write_audit_log.

FE (Stax, 1a): a Create-transfer action: pick SOURCE machine+shelf, DEST machine+shelf, product(s)+qty, confirm -> calls swap_between_machines (or a thin create_m2m_transfer wrapper) writing paired is_m2m Remove+Add New, shared m2m_transfer_id, from_warehouse_id NULL, bidirectionally linked. No `[TRUCK-TRANSFER]` free text. Disable any path that lets an operator type a plain `[TRUCK-TRANSFER]` Remove. Browser-verify 375px (no h-scroll, >=44px, axe clean) + screenshot.

TEST (BEGIN..ROLLBACK first, then apply backend):

- T1 Create-transfer MC->AMZ qty N -> one paired is_m2m Remove+Add New, shared transfer_id, from_warehouse_id NULL, linked, no `[TRUCK-TRANSFER]` text.
- T2 conservation: source qty == dest qty; no orphan dest leg.
- T3 legacy `[TRUCK-TRANSFER]` plain Remove is_m2m=false -> auto-converted (or blocked); never a WH credit.
- T4 receive a transfer-tagged Refill -> NO warehouse_inventory debit; provenance 'transfer_in_no_wh_debit'; audited.
- T5 receive an is_m2m source Remove -> M2M-skip (no Central credit) - PRD-052 regression.
- T6 normal (non-transfer) Remove/Refill unchanged (Remove credits WH, Refill debits WH).
- T7 engine_add_pod + engine_swap_pod md5 unchanged; swaps_enabled false.
- STOP and report on any failure; do not apply/deploy a failing build.

VERIFY post-apply: replay the MC->AMZ pattern -> now lands as a paired is_m2m transfer with zero WH churn; print before/after.

CLOSE: update CHANGELOG/MIGRATIONS_REGISTRY/RPC_REGISTRY; set PRD-060 status with migration names + commit. STOP and ask before any push to main / Vercel deploy.

HARD SAFETY: forward-only; no warehouse_inventory.status writes; engines byte-identical; swaps_enabled false; no destructive history rewrite; rebase --autostash; do NOT push to main without my explicit go-ahead.
