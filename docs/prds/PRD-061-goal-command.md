# Claude Code /goal Command - PRD-061 (auto-run, idempotent)

Paste into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. This one EXECUTES to completion against prod (it applies real inventory changes via canonical RPCs). It is idempotent and skips + logs gaps. No em dashes.

```
/goal Implement PRD-061 (docs/prds/PRD-061-reconcile-jojo-edits-23-25jun.md); read it first. Apply Jojo's 23-25 Jun off-system machine edits so pod inventory, refill logs, and warehouse inventory match reality. Source: BOONZ BRAIN/Jojo_Machine_Edits_23-25Jun_Actions.xlsx, Sheet 1 (Machine updates) + Sheet 2 (Warehouse). EXCLUDE Sheet 3 (Transfers). Run to completion; skip + log any gap; never double-apply.

HARD RULES
- Canonical RPCs ONLY. No direct INSERT/UPDATE/DELETE on pod_inventory / warehouse_inventory / refill_dispatching. Fetch the live writers first (pg_get_functiondef) and confirm their signatures before calling. If no canonical RPC fits an action -> GAP: skip + log, do NOT raw-write, do NOT invent a writer.
- IDEMPOTENT: before each row, run a detection query to see if the DB already reflects it. If yes -> mark already_done, skip. Never double-credit WH, never duplicate a pod row, never re-remove.
- EXPIRED = WRITE-OFF: expired removals (GRIT VW Antioxidant 9 + Reload 6; Magic Planet VW Reload 2) remove from pod with NO warehouse credit. Returns DO credit WH. NOT-ADDED (shelf full) = item stays in WH, no machine change.
- EXCLUDE Sheet 3 transfers entirely this run.
- AUTO-RUN: process every row top to bottom; never stop on a gap; skip it, log it, continue. Set app.via_rpc on every write.
- GAPS to expect (skip + log the reason): machine cannot be resolved (VOX / Magic Planet / Activate device numbers 0795/0797/0719/0715/0736/0817 - the official_name mapping is unclear), unknown items (Amazon 0735 "not in list" had no items shown), ambiguous qty/expiry, or no canonical writer for the action.

ACTION -> WRITER (fetch + confirm each):
- ADD / refill-not-in-list -> log_manual_refill(machine_name, source_warehouse_id, refill_date, lines jsonb, reason) [debits WH + creates pod]. already_done if pod_inventory has that product Active for the machine created on/after the date or a refill record exists.
- REMOVE / return-to-office -> canonical removal/return (receive_dispatch_line if a dispatch row exists; else log_retroactive_refill_visit or the manual-return writer). already_done if pod already Inactive for that product on the shelf.
- WRITE-OFF (expired) -> pod -> Inactive with NO WH credit (canonical pod-removal/write-off path; never receive into WH). already_done if pod already Inactive/0.
- RETURN (credit WH) -> the canonical return that credits warehouse_inventory. already_done if a WH batch is already credited for that product/qty around the date.
- SWAP -> remove old + add new (GRIT VW->Evian; Activate Evian-regular->330ml).
- SOURCE-CHECK (Aquafina 96, Evian 330ml 21) -> verify WH had/debited the stock; reconcile or log a gap if WH cannot cover it.

PROCESS:
1. Load the two sheets. For each row, resolve the machine to official_name (use the Machine ID column; for the 07xx device-number ones, if you cannot resolve confidently -> GAP skip+log).
2. Detect (already_done?) -> if not, pick the canonical writer -> capture before-state -> apply -> capture after-state.
3. Write docs/prds/PRD-061-EXECUTION-LOG.md: one line per row = applied (RPC + before/after) | already_done (evidence) | skipped (reason). End with a clear INCOMPLETE list (all skipped rows) so CS can close the gaps.

This is a live data run, not a migration file. Execute it. Show me the final EXECUTION-LOG and the INCOMPLETE list when done. If a whole class of action has no canonical writer, stop and tell me before raw-writing.
```

PRD: `boonz-erp/docs/prds/PRD-061-reconcile-jojo-edits-23-25jun.md`. Tracker: `BOONZ BRAIN/Jojo_Machine_Edits_23-25Jun_Actions.xlsx`.
