# PRD-119 — Expiry Management & Smart Inventory — Build Report

Branch: `prd-119`. Build chat execution log against `docs/prds/PRD-119-expiry-management-and-smart-inventory.md`
and `docs/prds/PRD-119-goal-command.md`. Live context at start of build: 2026-09-02, the 2026-09-02
dispatch/packing run was still in progress at loop start (gate query returned 2-3 open rows across
several checks) — this report tracks that gate explicitly wherever it affects sequencing.

Floor: PRD-118 (+ Addenda 1-2). At loop start, confirmed shipped this session: A (goods-receipt
guards, see PRD-118 report text), B (`correct_expiry_v1` + `propagate_expiry_correction`), D (5
migrations), G1 (`warehouse_expire_writeoff` disposal code), G2a (`manually_quarantined` column +
12 direct-reader patches + widened `v_wh_pickable`), G3 (`set_wh_quarantine`), H (4 migrations), K
(K1 Gate-2 expiry guard, K2 nightly `expiry_unvalidated` alert). **G2b** (`pack_dispatch_line` +
`bind_dispatch_fefo` patched for `manually_quarantined`) was **held**, gate still open. **J (pod_inventory
expiry grain) was explicitly NOT shipped** — deliberately deferred to this PRD. No
`_DRAFT_prd118_j_pod_inventory_expiry_grain.sql` file exists anywhere in the repo or git history
(confirmed via research sweep) — the P2 reader audit below is built from scratch using the
goal-command's candidate list plus a live `pg_proc`/`pg_views` scan.

---

## P1 — Warehouse truth

_(in progress)_

## P2 — Shelf

_(not started)_

## P3 — Driver line + single queue + read-only day close

_(not started)_

## P4 — Expiry & waste module

_(not started)_

## P5 — Receipt capture UX

_(only if P1-P4 land with time remaining)_

---

## Live rows changed

_(running list — should end as: nothing outside synthetic/2030 fixture data, the 320-line sweep, and the 8 expiry taps, per the goal's explicit accounting requirement)_
