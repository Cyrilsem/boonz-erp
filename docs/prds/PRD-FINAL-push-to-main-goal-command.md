# FINAL push-to-main /goal - remaining code PRDs + git parity

Paste into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. Main is at 2cdcc96. The data reconciliations (conservation, Sour Cream merge, PRD-066 declines, not_filled) are ALREADY applied to prod via MCP and logged in docs/prds/PRD-066-068-DATA-RECONCILIATION-LOG.md - do NOT redo them. This goal ships the remaining CODE and brings main level with prod.

```
/goal FINAL push-to-main. Repo boonz-erp, Supabase eizcexopcuoycuosittm, main at 2cdcc96. The data fixes in docs/prds/PRD-066-068-DATA-RECONCILIATION-LOG.md are already live via MCP - do NOT re-apply them. Ship the remaining CODE with Cody review, commit everything, push main. Migration FILE first for each; Cody verdict required for every function touching protected entities (Art 1,3,12,16). Idempotent; never re-apply a migration already in prod history. On any gap or unsafe merge conflict, SKIP + log, never force. No em dashes.

STEP 1 - PARITY CHECK (read-only): diff prod migration history vs supabase/migrations vs main. Confirm the 5 parity files from the last run (062, decline_dispatch_return, procurement_proposals_outbox, get_procurement_demand, phaseF_service_priority_shadow) are on main; regenerate any that are missing from the LIVE prod definition. List anything still fileless.

STEP 2 - PRD-068 durable (docs/prds/PRD-068-refill-log-integrity-post-confirm-conservation.md), forward migration + Cody:
- not_filled guard: enforce filled_quantity=0 whenever pack_outcome='not_filled' going forward (trigger or in the confirm/pack RPC).
- post-confirm conservation re-assert: after a driver confirm / field edit changes a REMOVE or M2W line, reconcile pod+plan to driver_confirmed_qty (align child quantity to driver_confirmed_qty, set the pod_refill_plan parent to the resulting sum) so check_pod_conservation cannot drift post-publish. This mirrors the manual pass already applied.
- daily monitor: pg_cron job that runs check_pod_conservation(today) and emails any non-conserving rows + the stitch_leakage day-total.

STEP 3 - PRD-034 (docs/prds/PRD-034-vox-return-no-wh-credit.md): venue_team guard in receive_dispatch_line so VOX-supplied returns never credit Boonz warehouse. Forward migration + Cody.

STEP 4 - PRD-036 backend only (docs/prds/PRD-036-pickable-stock-and-field-batch-capture.md): FEFO-bind from_wh_inventory_id on Refill/Add dispatch lines at pickup so pickup qty + expiry stop reading 0. Backend bind ONLY; FE field-capture excluded. Forward migration + Cody.

STEP 5 - COMMIT + MERGE: commit the new migrations + docs/prds/PRD-066-068-DATA-RECONCILIATION-LOG.md + the PRD-066/067/068/034/036 docs. FLAG + EXCLUDE the large "BOONZ DAILY SALES ENHANCED *.json" data files. Merge feat/prd-053-driver-add-flag into main ONLY if it builds clean and QA passes, else leave + log. Push main.

STEP 6 - VERIFY + REPORT: assert main migration set == prod history for everything this run and the prior run touched (the 742 historical foundation rows are out of scope, note but do not block). Re-run check_pod_conservation for 2026-06-24..30 (must stay zero). Deliver: parity diff, per-PRD Cody verdicts, commit hashes, and the final INCOMPLETE log.
```

Out of scope for this run (separate efforts): the 742-row historical migration drift (Mar-May 2026 foundation), the AMZ M2M / MC->Amazon transfer receive-vs-decline, PRD-061 external data, and the USH VW Antioxidant physical confirm.
