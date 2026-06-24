# PRD-053 EXECUTION LOG

## Phase A - stitch conservation (2026-06-23) — FILE authored + verified read-only; STOPPED for CS

**Migration FILE (not applied):** `supabase/migrations/20260624000000_prd053_a_stitch_conservation.sql`

### Live bodies fetched (pg_get_functiondef, never guessed)
- `stitch_pod_to_boonz(date,boolean)` — engine v26_multivariant_spread. Leak located in the `remove_lines` CTE: `... ELSE LEAST((FLOOR(pod_qty/variant_count)+remainder)::int, current_stock)::int END AS variant_final`. Exactly **1** `ELSE LEAST(` in the body (confirmed read-only), so the surgical replace is unambiguous; the DO-block RAISEs if the target is not found or the cap survives.
- `write_refill_plan(date,jsonb)` — writes `refill_plan_output` from the stitch lines (carries `quantity`, no expiry). So the leak (6) propagates stitch → refill_plan_output → refill_dispatching; `expiry_date` is assigned downstream in push.
- `push_plan_to_dispatch(date,text)` (v5) — reads `refill_plan_output`, writes one `refill_dispatching` row per line; REMOVE got `expiry_date=NULL` (pin is Refill/Add-only).

### Diff (what changed)
- **stitch_pod_to_boonz:** REMOVE child `... ELSE LEAST((dist)::int, current_stock)::int END` → `(dist)::int` (both internal_transfer and warehouse branches now size from the pod plan total; **no pod_inventory cap**). engine_version → `v27_remove_conservation`.
- **push_plan_to_dispatch:** new REMOVE/M2W branch — split `line.quantity` across the shelf's Active `v_pod_inventory_latest` batches FEFO (`take = LEAST(stock, remaining)`, `expiry_date = batch.expiration_date`), then one NULL-expiry "EXPIRY-TO-CONFIRM" line for the remainder; CONTINUE (skip the single-row insert). New end-of-function assert loops `check_pod_conservation(plan_date)` for this machine → on any row: INSERT `stitch_leakage` + RAISE (stop-ship). `rpc_version` → `v6_prd053_conservation`.
- **NEW:** `stitch_leakage` table; `check_pod_conservation(date)` read-only fn.

### AC verification (read-only against live data; NOTHING applied to prod)
- **AC-A1 — conservation parent = pod plan, not pod_inventory.** ✅ Replicated the new (uncapped) REMOVE distribution on VML-1004 A03 Ice Tea: OLD `LEAST(13,6)` = **6** (the leak); NEW = **13** = `parent_pod_qty`.
- **AC-A2 — REMOVE sized from plan, FEFO across known batches + NULL remainder.** ✅ Push split conserves to 13: with the Active 6-unit batch → 6 @ 2027-04-15 + 7 @ NULL; when that batch is Inactive (live data shifted mid-verify) → 13 @ NULL. Either way SUM(children) = 13. The "known batch" line only materialises when pod_inventory is Active at push time; conservation holds regardless.
- **AC-A3 — publish-time assert + telemetry + stop-ship.** ✅ `check_pod_conservation` run read-only against the current live state returns the leaking instruction: `parent_pod_qty=13, children_sum=6, delta=7`. The push assert RAISEs on this (full rollback = stop-ship) and logs the delta to `stitch_leakage`. After the uncap fix children_sum=13 → delta=0 → checker empty → assert passes.

### Cody verdict (per writer)
- `stitch_pod_to_boonz` (writer, modified): ✅ **Approve.** Art 1 (still builds lines for the canonical write_refill_plan; no new write path), Art 4 (app.via_rpc/rpc_name + operator_admin gate unchanged), Art 12 (forward-only CREATE OR REPLACE via DO-block on the live body, no _v2, guarded), Art 16 (removes a pod_inventory cap; introduces no inline metric re-derivation).
- `push_plan_to_dispatch` (writer, modified): ⚠️ **Approve with note.** Art 1/3 (the canonical plan→dispatch writer; extends its own INSERT, no foreign direct write), Art 4 (gates unchanged), Art 8 (split INSERTs ride the generic write_audit_log trigger via app.via_rpc), Art 12 (forward-only). **Note:** on a stop-ship RAISE the `stitch_leakage` INSERT rolls back with the abort (single-tx), so the persisted telemetry row is best-effort; the delta is durable in the RAISE message + Postgres log, and `check_pod_conservation` lets a monitor/cron persist a row non-blockingly. CS to decide whether to layer a durable autonomous-tx telemetry write.
- `check_pod_conservation` (read-only helper): ✅ **Approve.** SECURITY INVOKER, no writes.
- `stitch_leakage` (new table): ✅ **Approve.** Art 2 (RLS on), Art 7 (append-only — no UPDATE/DELETE policy; DEFINER-only writes). Not a protected entity.

**STOP — awaiting CS review before apply.** Nothing applied to prod; migration is a FILE only.

## Phase B - field per-expiry split, TOTAL LOCKED (2026-06-23) — FILE authored + verified read-only

**Migration FILE (not applied):** `supabase/migrations/20260624000100_prd053_b_set_dispatch_breakdown.sql`

- **Live body fetched:** `receive_dispatch_line(p_dispatch_id uuid, p_filled_quantity numeric, p_received_by uuid, p_batch_breakdown jsonb)`. Its `p_batch_breakdown` shape = a jsonb array `[{ "qty": <number>, "expiry": "<date>"|null, "wh_inventory_id": <uuid>|null }, ...]` validated as `SUM(qty) = filled_quantity`. `refill_dispatching.driver_confirmed_breakdown` (jsonb) is the store.
- **SQL / diff:** NEW `set_dispatch_line_breakdown(p_dispatch_id, p_batch_breakdown, p_edit_role, p_reason)` — DEFINER, app.via_rpc/rpc_name, role gate. Validates each entry (qty>=0; expiry optional = to-confirm) and enforces `SUM(qty) = refill_dispatching.quantity` (the total is immutable). On pass: `UPDATE refill_dispatching SET driver_confirmed_breakdown = p_batch_breakdown, expiry_date = earliest, edit_count+1`. Never changes quantity/action/status. Locked once item_added/dispatched.
- **AC-B verification (read-only):** the example split `[{qty:6,expiry:2027-04-15},{qty:7,expiry:2027-08-01}]` sums to **13** = the line total (saved); a mismatch (e.g. 11) RAISEs. All written columns exist with correct types (`driver_confirmed_breakdown` jsonb, `last_edited_*`, `edit_count` int) → applies cleanly. A full driver→split→save round-trip is a rolled-back test once applied.
- **Cody:** ✅ **Approve.** Art 1 (an edit writer on refill_dispatching, peer of skip_dispatch_line / edit_transfer_qty — no foreign write), Art 4 (gates + SUM==total validation), Art 5 (no status/action/qty flip — only the expiry distribution), Art 8 (generic write_audit_log trigger + edit_count), Art 12 (forward-only).
- **FE (Stax) follow-up (specified):** add a per-expiry breakdown editor on the driver dispatching/packing line that calls `set_dispatch_line_breakdown` (distinct from the WH returns-approval panel). The total field is read-only (locked); only the per-expiry rows are editable; client also asserts SUM == total before submit.

## Phase C - flagged driver additions to Head Office (2026-06-23) — FILE authored + verified read-only

**Migration FILE (not applied):** `supabase/migrations/20260624000200_prd053_c_flagged_driver_additions.sql`

- **Dara — column/flag design (additive, forward-only) on refill_dispatching:** `needs_review bool default false`, `review_reason text`, `review_status text default 'none'` (none|pending|accepted|rejected), `reviewed_by uuid`, `reviewed_at timestamptz`, + partial index `WHERE needs_review AND review_status='pending'`. RLS already enabled on refill_dispatching (confirmed) → new columns covered, no RLS change.
- **SQL / diff:** (1) `driver_add_flagged_row(...)` — wrapper that COMPOSES the canonical `add_dispatch_row` (12-arg signature confirmed to match) then stamps `needs_review=true / review_reason='driver_addition' / review_status='pending'`; never blocks. A defaulted-param overload of add_dispatch_row was rejected (overload foot-gun, CLAUDE.md), hence a wrapper. (2) `review_driver_addition(dispatch_id, decision, reason)` — operator_admin/superadmin/manager records accepted|rejected (reviewed_by/at); does NOT delete or cut qty (rejection is actioned via the existing skip/cancel writer). (3) `v_driver_addition_review_queue` — the Head Office queue (pending flagged adds).
- **AC-C verification (read-only):** `add_dispatch_row` 12-arg signature matches the wrapper call exactly; `needs_review` absent → clean ALTER; refill_dispatching RLS enabled. By construction: a driver addition is INSERTED by add_dispatch_row (recorded) then flagged (needs_review=true) and appears in `v_driver_addition_review_queue`; nothing blocked. Full "add 2 extra → 15 total → 2 flagged" round-trip is a rolled-back test once applied.
- **Cody:** ✅ **Approve.** Additive columns under existing RLS (Art 2/12); `driver_add_flagged_row` composes the canonical writer (Art 1) + an audited flag stamp (Art 4/8), never blocks; `review_driver_addition` is role-gated (Art 4), records the decision only — no delete, no qty cut.
- **FE (Stax) follow-up (specified):** route the packing-page "Add product" beyond-plan path through `driver_add_flagged_row`; add a Head Office review screen reading `v_driver_addition_review_queue` with Accept/Reject calling `review_driver_addition`.

## CS decisions (2026-06-23) — DURABLE telemetry + APPLY all three + Stax FE

### Durable telemetry — design + Cody
CS asked for durability via an autonomous transaction (pg_background / dblink). On this managed Supabase, **dblink loopback requires a password** (`postgres` is not a superuser: `2F003: Non-superusers must provide a password`), and hard-coding the DB password into a migration/function is unsafe (credential handling is also classifier-denied); **pg_background is not installed**. So an autonomous-tx write is not a safe option here. Instead the conservation gate was moved to a **pre-write GATE in push_plan_to_dispatch**: it compares the approved plan (`refill_plan_output`) to `pod_refill_plan` per REMOVE/M2W instruction BEFORE writing any dispatch; on a leak it INSERTs `stitch_leakage` and **RETURNS `conservation_violation` (no RAISE)** — so the telemetry row COMMITS and survives while **nothing ships** (stop-ship). Durable by construction, no credentials. (dblink probe table + extension created during the test were dropped.)
**Cody (push_plan_to_dispatch durable gate):** ✅ **Approve.** Art 1 (canonical plan→dispatch writer; gate reads refill_plan_output/pod_refill_plan, writes only the telemetry table + dispatch via its own INSERTs), Art 4 (app.via_rpc/rpc_name + role gate), Art 8 (generic write_audit_log trigger), Art 12 (forward-only). Durability achieved without a credentialed autonomous tx.

### APPLIED to prod (2026-06-23) + rolled-back fixtures
- **Phase A** `prd053_a_stitch_conservation` APPLIED. Live re-verify: stitch `v27_remove_conservation` with the `ELSE LEAST(` cap GONE; push `v6_prd053_conservation`; `check_pod_conservation` + `stitch_leakage` live.
  - **AC-A1 (no leakage):** ✅ live uncapped REMOVE distribution on VML-1004 A03 Ice Tea = **13** (= pod plan, was 6). Conserving fixture push → dispatch children **sum = 13**.
  - **AC-A2 (FEFO + NULL remainder):** ✅ push REMOVE split conserves to the plan (Active batch → known + NULL remainder; no Active → all NULL to-confirm).
  - **AC-A3 (assert blocks + durable telemetry + stop-ship):** ✅ rolled-back fixture — a leaking plan (parent 13 / child 6) → push returned `conservation_violation`, **1 stitch_leakage row written**, **0 dispatch rows written**, and **push RETURNED (did not RAISE)** → the telemetry row commits in real use (durable).
- **Phase B** `prd053_b_set_dispatch_breakdown` APPLIED. **AC-B:** ✅ rolled-back fixture — split a qty-13 line into `[{6,2027-04-15},{7,2027-08-01}]` → status ok, breakdown_total 13 = line_total 13, stored in `driver_confirmed_breakdown`; a mismatch (11) RAISEd `breakdown total (11) must equal the line total (13)`.
- **Phase C** `prd053_c_flagged_driver_additions` APPLIED. **AC-C:** ✅ rolled-back fixture — `driver_add_flagged_row` (edit_role `'driver'`) added 2 extra: not blocked, recorded (qty 2), `needs_review=true` / `review_reason='driver_addition'`, present in `v_driver_addition_review_queue` (1); `review_driver_addition(...,'accepted')` cleared the flag and removed it from the queue. (FE must pass `edit_role='driver'` — the `last_edited_role` CHECK allows driver/warehouse_manager/operator_admin/superadmin/manager/system, not field_staff.)

**Backend COMPLETE + verified live.**

## Stax FE — SHIPPED TO PROD (deploy `db21023`)
- **(B)** `ExpiryBreakdownDialog` (per-expiry split, total locked) wired on the packing line; **(C)** `DriverAdditionsReviewPanel` + `/admin/driver-additions` + nav link. FE-only, all writes via RPC. Prod smoke green (review queue loads; 34 "⊟ expiry split" triggers + total-locked dialog).

## Driver-add flagging wired (branch `feat/prd-053-driver-add-flag`, `7bd5882`)
- Packing "Add product" beyond-plan path → `driverAddFlaggedRow` server action → `driver_add_flagged_row` (`p_edit_role='driver'`), so real driver adds auto-populate `/admin/driver-additions`. `tsc`+build green; Vercel preview was build-rate-limited (QA'd locally). Awaiting CS "QA passed" → merge to main.

## Reject-excludes-line fix — APPLIED (`prd053_d_reject_excludes_line`, 2026-06-23)
- `review_driver_addition` v2: a **rejected** decision now takes the line out of dispatch via the canonical writer — `set_dispatch_include(false)` for a pending addition, `cancel_dispatch_line(...)` if already dispatched (WH-unbound). **accepted** leaves it included. No delete, no qty cut. Cody ✅ (Art 1/4/5/8/12).
- **Live fixture (rolled back) PASS:** reject → status `rejected`, taken out via `excluded`, `include=false` → does not ship; accept → status `accepted`, `include=true` → ships. `live_fix_present=true`.

**PRD-053 COMPLETE on prod: backend A/B/C + reject-fix live; FE B/C live; driver-add flagging awaiting the FE merge (QA passed → main).**
