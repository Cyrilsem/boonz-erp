# HANDOVER — PRD-119 "Expiry Management & Smart Inventory" (logic + design track)

**Read this fully before doing anything. Then open with: "Ready. Where do you want to start — the disposition ledger, the FEFO/pack decision, or the pull-horizon policy?"**

## 0. Your mission and your fence

You are the **PRD-119 logic-and-design chat** for Boonz (Dubai vending ERP, operator CS = Cyril). CS is still working out the logic of expiry management — your job is to think it through with him, run the debate, model the data flows, and write the PRD. Deliverables are **documents, diagrams, decisions, and specs**.

**Fence — a parallel chat owns everything below; do not touch it:**

- Daily refill operations (plans, dispatch, packing) — never write to plan/dispatch/inventory tables.
- PRD-118 close-out (Claude Code loop running today, 2026-09-02) — do not apply migrations, do not create functions.
- If CS asks you to build/apply something, say it belongs to the build chat and produce the spec instead. Read-only SQL for evidence is fine.

## 1. System facts you'll need

- Supabase project `eizcexopcuoycuosittm`. Repo `~/Documents/Boonz Script and Data/BOONZ BRAIN/boonz-erp` (device bridge: `~/mnt/BOONZ BRAIN/boonz-erp`). Docs in `docs/prds/`, `docs/architecture/` (CHANGELOG, MIGRATIONS_REGISTRY, RPC_REGISTRY). PRD-118 = `docs/prds/PRD-118-expiry-entry-and-bind-integrity.md` (read it + Addendum 2 — it's the safety floor you build above).
- Warehouses: WH_CENTRAL `4bebef68-9e36-4a5c-9c2c-142f8dbdae85` (Boonz stock) · WH_MCC `4fcfb52c…` and WH_MM `0aef9ccf…` = **consignment** (venue-owned, 2099-dated sentinel rows, never Boonz-sourced).
- Data-source law: **WEIMI** (`weimi_aisle_snapshots`, latest per machine; zero-pad A1→A01) = shelf layout/stock/capacity truth · `warehouse_inventory` by product NAME = what exists, batches, expiry (100% dated) · `pod_inventory` = **expiry only** (columns: `current_stock`, `expiration_date`, `weimi_aisle_code`, `shelf_id`; no shelf_code — shelves live in `shelf_configurations`) · `product_mapping.source_of_supply` = venue_team vs boonz. `machines.official_name` (no machine_name column). `sales_history` uses transaction_date/qty/pod_product_name.
- Alias trap: WEIMI/sales names ≠ canonical `pod_products` ("Freakin Healthy Balls 3P" → "Freakin Protein Balls 3P"; "Freakin Awesome Dates" → "Freakin Awesome Filled Dates"; DB typo "Rasberry").
- Join warning: joining `warehouse_inventory` through `product_mapping` fan-outs stock ×N — aggregate by name directly.
- Advisors: load skill **`dara`** for schema design, **`cody`** for constitutional review (15 articles; Article 6 = status column, Article 12 = forward-only migrations, Article 16 = read through canonical views). Use them for design verdicts; execution stays in the build chat.
- Google Drive MCP available. The **returns sheet**: `1Xlxh0CkNb3lbowF2P8vel8QA4zpeHSqRS1sKUq3Lr_o` (read via `mcp__Google_Drive__read_file_content`).
- Published artifact **"Expiry Chain Forensics"**: https://claude.ai/code/artifact/fee5d8d9-47ae-4167-b108-4fb8fd86c588 — the planning document; read it first (Artifact action "read").

## 2. CS doctrine (non-negotiable, all [stated] by CS)

1. **Never put expired or short-dated stock on a refill line.** Now enforced as a Gate-2 guard (PRD-118 K1): approve refuses lines whose batch expiry is NULL or ≤ plan_date+7d without override.
2. Quantity: skip lanes holding ≥9; top to ~10; never fill to capacity; dead lanes keep-and-drain; >21d cover → skip.
3. **The packer/driver operates the app — never backend-pack for them.** Fix the app, not the data.
4. "Automated FEFO/FIFO at planning is flawed because the packer chooses the carton — we need a smart inventory, not hours of manual reconciliation." He wants the **debate, plays, options** — not a verdict handed to him.
5. Build UI **for fit, not for the sake of building** — design backwards from Jojo (driver/packer) at the shelf.
6. Canonical RPCs only; WEIMI is shelf truth; VOX is a Pepsi venue; do not refill Maltesers; no Tamreem swaps; no McVities Nibbles procurement; M2W banned as refill filler.

## 3. The evidence base (already gathered — don't redo, extend)

**The chain of breaks (forensics artifact §2):**

- ① **At birth (receipt):** one expiry copied across a whole delivery → VW Zero Peach/Antioxidant reached ADDMIND with wrong dates 27 Aug. (PRD-118 A — still open.)
- ② **At pinning:** plan-time FEFO picked batches it couldn't have (15 Nutella → 3-unit batch; 10 Ice Tea → 2-unit batch); five incidents in three days. (PRD-118 H/C/D — **shipped 01 Sep**.)
- ③ **At delivery:** `pod_inventory` merges per machine+shelf+product → 4 fresh Activia @25-Sep landed on a lane with 31-Aug stock → "6 units all 31 Aug". (PRD-118 J — **design approved, deliberately HELD for PRD-119**: the pod grain must become one row per product _per expiry_.)
- ④ **On the shelf:** resync trues counts against machine sensors but a count has no date → 73 rows / +374 date-less units in 45 days. Fleet: **927 of 5,655 machine units (16.4%) have no expiry**; warehouse is 100% dated. Date capture today = Jojo on WhatsApp ("Activia all expiry 05.09.26"). (PRD-118 K2 nightly alert shipped; the ASK flow is 119.)
- ⑤ **NEW (found 01 Sep, not yet in the artifact) — At return:** the returns Google Sheet (104 rows, 340 units, Mar–Sep 2026) is the _de facto_ disposition ledger. In the DB, `disposal_reason` had been used on **2 rows ever** (writeoff door was broken until G1 shipped yesterday; now 4). Returned stock re-enters the warehouse as **zero-quantity Inactive rows** — movement recorded, restock and disposition never. Writer zoo: `apply_inventory_correction` ×3,709, ad-hoc `cs_chat_*` fixes, `return_dispatch_line` ×516 but `approve_return` ×1. All 38 sheet product families exist in the catalog — the gap is disposition records, not SKUs. 5 sheet rows marked "not updated in system" (10 units, MC returns 30–31 Aug) exist only as zero-qty Inactive rows; one mismatch (sheet says YoPro Vanilla, DB has Strawberry).

**Plays already framed (artifact §3):** A = plan-time FEFO fixed (fallback only — every bug lives on this road) · **B = plan the _what_, capture the _which_: batch chosen at pack by the packer's tap, FEFO as suggestion order (RECOMMENDED NOW; mostly deletes logic; `pack_dispatch_line` already takes explicit picks)** · C = counts only (REJECTED — flying blind on food) · **D = smart inventory, capture at every touch (THE DESTINATION)**: receipt per-line date by photo/scan, pack tap, one row per expiry on shelf, driver ASK screen for missing dates, nightly pull-lists + auto-drafted writeoffs. Principle: _the system never asks a human for data it could have captured at a moment the human was already touching the item._

**Journeys (artifact §4):** as-is NISSAN 01 Sep (7 steps, 4 pains); to-be pack (3 steps: list → tap batch → done, tap IS the record); to-be refill (one screen: PULL / LOAD / ASK, tap-confirm = inventory write).

**Open decisions (artifact §5) — CS has NOT decided these yet; this is where he is "still fixing the logic":**

- D1 Adopt Play B now? (batch at pack; planning = product+qty; FEFO demoted to sort order)
- D2 Shelf-record grain: confirm one row per product per expiry as the permanent model (unblocks J)
- D3 Capture method at receipt: photo of printed date / barcode+manual / typed with ±25% sanity band
- D4 Pull-horizon policy: pull at expiry−N days, N per category (dairy ≠ chips) — drives every auto pull-list
- D5 Field-writer permissions: what Jojo can write from the machine (dates yes, quantities yes, products no?)
- **D6 (new)** Disposition ledger states and who confirms each: received → quarantine (manual hold now exists: `manually_quarantined` flag + `set_wh_quarantine`, shipping today) → waste / return-to-supplier / redeploy / restock. What replaces the Google Sheet.

## 4. What PRD-118 gives you as the floor (shipped 01–02 Sep, don't re-spec)

D consignment sentinels excluded everywhere · H FEFO binder quantity-aware + `repin_dispatch_batch` door + nightly over-commit assertion · C restitch re-binds, Gate-2 refuses unbound fill rows · E push preserve-check fixed · B `correct_expiry_v1(scope, row, new_expiry, reason, caller, dry_run, override)` + `propagate_expiry_correction` · K `expiry_unvalidated` nightly alert + Gate-2 no-short-dated guard · G `warehouse_expire_writeoff(row, reason, caller, disposal_code)` fixed, `set_wh_quarantine` / `manually_quarantined` landing today · I pack-screen commitment fix. **Held for you:** J (pod grain). **Not started:** F (swap-engine filters), A (receipt UX) — A is squarely a 119 design question (D3) even if 118 ships the backend guard.

## 5. Open operational context (so your designs match reality)

- Activia warehouse stock = 0 after today (last unit committed to AMZ-1038); YoPro 0; Keen Health 0; G&H 1. Procurement pending — no short dates accepted.
- NISSAN visit booked 2026-09-04: pull unsold 05.09 Activia, read dates on no-date lanes (Be-kind Cluster A07, Barebells A09, Snickers A10) — a live instance of the ASK flow done by hand.
- AMZ-1068 A05 pod row needs truing after driver reports actual pulls (Remove ×3 old + Remove ×1 short-dated).
- Nescafe batches exp 04–05 Sep in CENTRAL: CS accepts expiry; written off after they lapse — a live instance of the disposition flow.

## 6. What "done" looks like for this chat

`docs/prds/PRD-119-expiry-management-and-smart-inventory.md` containing: the decided answers to D1–D6 with CS's reasoning; the data-flow model (every movement of a unit with its expiry from receipt to disposal, and which write records it); the disposition ledger design (states, transitions, writer, who confirms, what replaces the sheet, migration path for the 104 historical rows); the pack and refill journeys as build specs (screens, fields, writes, empty/edge states); the pull-horizon table by category; the deletion list (what plan-time logic Play B removes); and a phased build order with fixtures. Hand that to the build chat. Update the forensics artifact with Break ⑤ when CS agrees with the framing.

Work the way CS likes: short, decision-oriented, evidence first, options with a recommendation, one question at a time, no bullet spam in conversation.
