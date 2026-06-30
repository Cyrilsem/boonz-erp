# PRD-061: Reconcile Jojo's 23-25 Jun machine edits into the live dataset (idempotent auto-run)

Owner: CS
Date: 2026-06-25
Surface: Data reconciliation on prod via EXISTING canonical RPCs (pod_inventory, warehouse_inventory, refill logs). No schema or new-writer changes. If an action has no canonical RPC, that is a GAP: skip it and log it, do not raw-write and do not invent a writer.
Governance: canonical RPCs only (Article 1/3). Forward-only. No em dashes. Idempotent. Auto-run to completion; skip gaps and log them.

## Objective

Apply the off-system edits Jojo made on 23, 24, 25 June 2026 so the dataset is clean: pod inventory, refill logs, and warehouse inventory match what physically happened. Source of truth = `BOONZ BRAIN/Jojo_Machine_Edits_23-25Jun_Actions.xlsx`, Sheet 1 (Machine updates) and Sheet 2 (Warehouse). EXCLUDE Sheet 3 (Transfers) for now. The run must be idempotent (if the DB already reflects a change, do nothing), execute every row it can, and skip + log the rest.

## Hard rules

1. CANONICAL RPCs ONLY. No `INSERT/UPDATE/DELETE` on pod_inventory / warehouse_inventory / refill_dispatching directly. Use the existing writers (fetch them first). If none fits an action, that action is a GAP.
2. IDEMPOTENT. Before applying any row, run a detection query to check if the DB already reflects it. If already applied, mark `already_done` and skip. Never double-apply (no double WH credit, no duplicate pod row, no re-removal).
3. EXPIRED = WRITE-OFF. Expired removals (GRIT VW Antioxidant 9 + Reload 6; Magic Planet VW Reload 2) must remove from pod WITHOUT crediting warehouse_inventory. They are losses, not returns.
4. RETURNS credit the warehouse; NOT-ADDED items (shelf full) stay in WH (no machine change).
5. EXCLUDE transfers (Sheet 3). Do not touch M2M this run.
6. AUTO-RUN. Process every row top to bottom. Never stop on a gap; skip it, log it, continue.
7. GAP = skip + log, with the reason. Gaps include: machine cannot be resolved (the VOX / Magic Planet / Activate 07xx device numbers), unknown item list (Amazon 0735 "not in list" had no items), ambiguous qty/expiry, or no canonical RPC for the action.
8. Capture before/after state for every applied change (for the log). Set `app.via_rpc`.

## Action -> canonical writer (fetch and confirm each before use)

- ADD / refill-not-in-list -> `log_manual_refill(p_machine_name, p_source_warehouse_id, p_refill_date, p_lines jsonb, p_reason)` (debits WH, creates pod). Detect already-done: pod_inventory has that product Active for the machine created on/after the date, OR a refill record already exists.
- REMOVE / return-to-office -> the canonical removal/return path (receive_dispatch_line if a dispatch row exists; else `log_retroactive_refill_visit` or the manual-return writer). Detect: pod already Inactive for that product on the shelf.
- WRITE-OFF (expired) -> remove from pod (Inactive) with NO WH credit (use the canonical pod-removal/write-off path; never receive into WH). Detect: pod already Inactive / 0.
- RETURN credit WH -> the canonical return that credits warehouse_inventory. Detect: a WH batch already credited for that product/qty on/around the date.
- SWAP -> remove old + add new on the shelf (GRIT VW->Evian; Activate Evian-regular->330ml).
- NOT-ADDED (shelf full) -> log only; confirm the units are in WH; no machine change.
- SOURCE-CHECK (Aquafina 96, Evian 330ml 21) -> verify WH had/debited the stock; reconcile or log a gap if WH cannot cover it.

## Output

`docs/prds/PRD-061-EXECUTION-LOG.md` with one line per tracker row: `applied` (with before/after + the RPC used), `already_done` (with the detection evidence), or `skipped` (with the reason). End with a clear INCOMPLETE list (every skipped row) so CS can close the gaps. Also write the same status back into a copy of the tracker if practical.

## Out of scope

Transfers (Sheet 3), the app/workflow flags (Sheet 4, those are PRDs already in flight), and any new RPC (if an action needs one, log the gap; CS decides separately).
